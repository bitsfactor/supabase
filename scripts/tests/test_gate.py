"""门禁回归：新增违规、复制存量及配置错误必须失败。"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
SPECIFICATION = importlib.util.spec_from_file_location('patroni_check', ROOT / 'scripts/patroni-check.py')
CHECK = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(CHECK)


class GateTests(unittest.TestCase):
    def test_new_oosp_violations(self):
        examples = {
            'clock-random': 'import time\nnow_seconds = time.time()\n',
            'empty-except': 'try:\n    action()\nexcept ValueError:\n    pass\n',
            'abbreviation': 'cfg = {}\n',
            'unit': 'timeout = 3\n',
            'emoji': 'label = "' + chr(0x1f600) + '"\n',
            'migration': 'CREATE TABLE fixture (id integer);\n',
        }
        for rule, source in examples.items():
            with self.subTest(rule=rule):
                suffix = '.sql' if rule == 'migration' else '.py'
                findings = CHECK.oosp_findings('docker/patroni/fixture' + suffix, source)
                self.assertIn(rule, [item[0] for item in findings])

    def test_baseline_does_not_allow_new_copy_or_changed_line(self):
        baseline = [{'path': 'fixture.py', 'rule': 'abbreviation', 'source': 'cfg = {}', 'count': 1}]
        original = ('fixture.py', 'abbreviation', 1, 'cfg = {}')
        self.assertEqual(CHECK.unapproved([original], baseline), [])
        self.assertEqual(len(CHECK.unapproved([original, original], baseline)), 1)
        self.assertEqual(len(CHECK.unapproved([('fixture.py', 'abbreviation', 1, 'cfg = []')], baseline)), 1)

    def test_standard_clock_imports_parameters_and_empty_handlers(self):
        examples = [
            ('clock-random', 'import datetime\nx = datetime.datetime.now()\n'),
            ('clock-random', 'from datetime import datetime as clock\nx = clock.now()\n'),
            ('clock-random', 'from time import time as clock\nx = clock()\n'),
            ('clock-random', 'import random as generator\nx = generator.choice([1])\n'),
            ('unit', 'def wait(timeout=3):\n    return timeout\n'),
            ('abbreviation', 'def handle(req):\n    return req\n'),
            ('empty-except', 'try:\n    action()\nexcept ValueError:\n    ...\n'),
        ]
        for rule, source in examples:
            with self.subTest(source=source):
                self.assertIn(rule, [item[0] for item in CHECK.oosp_findings('docker/patroni/fixture.py', source)])

    def test_invalid_python_shell_yaml_and_lint(self):
        examples = [
            ('fixture.py', 'def broken(\n'),
            ('fixture.sh', '#!/bin/sh\nif then\n'),
            ('fixture.sh', '#!/bin/sh\necho $unknown\n'),
            ('fixture.yml', 'services: [\n'),
        ]
        for filename, source in examples:
            with self.subTest(filename=filename, source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'scripts').mkdir()
                (root / 'scripts/oosp-baseline.json').write_text(json.dumps([]))
                (root / filename).write_text(source)
                with self.assertRaises((SyntaxError, subprocess.CalledProcessError, RuntimeError, yaml.YAMLError)):
                    CHECK.check_sources(root, [filename])

    def test_installer_refuses_shared_hook_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            hook = Path(directory) / 'pre-commit'
            hook.write_text('shared hook sentinel')
            environment = {**os.environ, 'GIT_CONFIG_COUNT': '1',
                           'GIT_CONFIG_KEY_0': 'core.hooksPath', 'GIT_CONFIG_VALUE_0': directory}
            result = subprocess.run(['bash', str(ROOT / 'scripts/install-hooks.sh')], cwd=ROOT,
                                    env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('core.hooksPath', result.stderr)
            self.assertEqual(hook.read_text(), 'shared hook sentinel')

    def test_scope_includes_deploy_templates_and_hook_changes(self):
        for path in ['.deploy.patroni.yaml', 'docker/patroni/patroni.yml',
                     'docker/patroni/service/sandbox/override.yml', 'scripts/tests/compose.env',
                     'scripts/pre-commit']:
            self.assertTrue(CHECK.relevant(path), path)
        self.assertFalse(CHECK.relevant('docker/volumes/db/data/file'))
        self.assertFalse(CHECK.relevant('docker/patroni/__pycache__/render.pyc'))
