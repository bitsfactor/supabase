#!/usr/bin/env python3
"""Patroni 本地门禁；例：python3 -B scripts/patroni-check.py --staged。"""
import ast
from collections import Counter
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest

import yaml


def run(arguments, **options):
    return subprocess.run(arguments, check=True, capture_output=True, text=True, **options).stdout


def relevant(path):
    return '__pycache__' not in Path(path).parts and (
        path.startswith(('docker/patroni/', 'scripts/')) or path == '.deploy.patroni.yaml')


def source_paths(root):
    paths = run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).split('\0')
    return sorted({path for path in paths if relevant(path) and (root / path).is_file()})


def oosp_findings(path, source):
    """返回可定位的规则/源码行；只检查自有 Python 和所有源文件里的图形符号。"""
    findings = set()
    lines = source.splitlines()
    for number, line in enumerate(lines, 1):
        if re.search('[\U0001f000-\U0001faff\u2600-\u27bf\u2b00-\u2bff]', line):
            findings.add(('emoji', number, line.strip()))
    if path.startswith('docker/patroni/') and path.endswith('.py'):
        tree = ast.parse(source, filename=path)
        imports = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update((entry.asname or entry.name.split('.')[0],
                                entry.name if entry.asname else entry.name.split('.')[0]) for entry in node.names)
            elif isinstance(node, ast.ImportFrom):
                imports.update((entry.asname or entry.name, (node.module or '') + '.' + entry.name)
                               for entry in node.names)

        def qualified_name(node):
            if isinstance(node, ast.Name):
                return imports.get(node.id, node.id)
            if isinstance(node, ast.Attribute):
                return qualified_name(node.value) + '.' + node.attr
            return ''

        for node in ast.walk(tree):
            rule = None
            if isinstance(node, ast.Call):
                name = qualified_name(node.func)
                if name in {'time.time', 'time.monotonic', 'time.perf_counter',
                            'datetime.now', 'datetime.datetime.now', 'datetime.datetime.utcnow',
                            'datetime.date.today'} or name.startswith(('random.', 'secrets.')):
                    rule = 'clock-random'
            if isinstance(node, ast.ExceptHandler) and all(
                    isinstance(statement, ast.Pass) or (isinstance(statement, ast.Expr) and
                    isinstance(statement.value, ast.Constant) and statement.value.value is Ellipsis)
                    for statement in node.body):
                rule = 'empty-except'
            if isinstance(node, (ast.Name, ast.arg)):
                name = node.id if isinstance(node, ast.Name) else node.arg
                if name in {'req', 'res', 'tmp', 'cfg', 'usr', 'ctx', 'val', 'tbl', 'hdr', 'mgr'}:
                    rule = 'abbreviation'
                if (isinstance(node, ast.arg) or isinstance(node.ctx, ast.Store)) and name in {
                        'timeout', 'interval', 'delay', 'size', 'balance'}:
                    rule = 'unit'
            if rule:
                findings.add((rule, node.lineno, lines[node.lineno - 1].strip()))
    if path.endswith('.sql'):
        for number, line in enumerate(lines, 1):
            if re.match(r'\s*(CREATE|ALTER)\s', line, re.I) and not re.search(
                    r'IF\s+(NOT\s+)?EXISTS|CREATE\s+OR\s+REPLACE', line, re.I):
                findings.add(('migration', number, line.strip()))
    return sorted(findings)


def unapproved(findings, baseline):
    """存量按具体行和次数冻结；重复复制同一违规也不能放行。"""
    remaining = Counter({(item['path'], item['rule'], item['source']): item['count'] for item in baseline})
    failures = []
    for path, rule, number, source in findings:
        key = (path, rule, source)
        if remaining[key] > 0:
            remaining[key] -= 1
        else:
            failures.append(f'{path}:{number}: [{rule}] {source}')
    return failures


def check_sources(root, paths):
    findings = []
    for path in paths:
        if Path(path).suffix not in {'.py', '.sh', '.yml', '.yaml', '.sql'} and path != 'scripts/pre-commit':
            continue
        source = (root / path).read_text()
        if path.endswith('.py'):
            compile(source, path, 'exec')
        if path.endswith(('.yml', '.yaml')):
            # Compose 的 !reset / !override 标签只由 Compose 解释；此处验证 YAML 语法。
            yaml.compose(source)
        if path.endswith('.sh') or path == 'scripts/pre-commit':
            interpreter = 'bash' if 'bash' in source.splitlines()[0] else 'sh'
            run([interpreter, '-n', path], cwd=root)
            result = subprocess.run(['shellcheck', '--format=json', path], cwd=root,
                                    capture_output=True, text=True)
            if result.returncode not in (0, 1):
                raise RuntimeError(result.stderr or result.stdout)
            for item in json.loads(result.stdout):
                findings.append((path, 'SC' + str(item['code']), item['line'],
                                 source.splitlines()[item['line'] - 1].strip()))
        findings.extend((path, rule, number, line) for rule, number, line in oosp_findings(path, source))
    baseline = json.loads((root / 'scripts/oosp-baseline.json').read_text())
    failures = unapproved(findings, baseline)
    if failures:
        raise RuntimeError('\n'.join(failures))


def check_compose(root):
    # 清空宿主环境并显式指定测试变量，不读取本机 .env 或生产证书。
    environment = {'PATH': os.environ.get('PATH', os.defpath)}
    arguments = ['docker', 'compose', '--env-file', str(root / 'scripts/tests/compose.env'),
                 '--profile', '*', '-f', 'docker/patroni/service/docker-compose.yml']
    run(arguments + ['config', '--quiet'], cwd=root, env=environment)
    run(arguments + ['-f', 'docker/patroni/service/sandbox/override.yml', 'config', '--quiet'],
        cwd=root, env=environment)


def main(arguments):
    root = Path(run(['git', 'rev-parse', '--show-toplevel']).strip())
    if any(argument not in {'--full', '--staged'} for argument in arguments):
        raise ValueError('用法：scripts/oosp-lint.sh [--staged|--full]')
    full = os.environ.get('LINT_SCOPE') == 'full' or '--full' in arguments or '--staged' not in arguments
    if not full:
        changed = run(['git', 'diff', '--cached', '--no-renames', '--name-only', '-z']).split('\0')
        if not any(relevant(path) for path in changed):
            print('Patroni：本次提交未涉及后端，跳过')
            return
        # 测试原地运行；禁止工作区和提交内容不同造成假绿（也覆盖删除、重命名和未跟踪依赖）。
        unstaged = run(['git', 'diff', '--no-renames', '--name-only', '-z']).split('\0')
        untracked = run(['git', 'ls-files', '--others', '--exclude-standard', '-z']).split('\0')
        differences = [path for path in unstaged + untracked if relevant(path)]
        if differences:
            raise RuntimeError('后端文件与暂存区不一致，请先暂存完整被测版本：\n' + '\n'.join(differences))
    for tool in ('shellcheck', 'docker'):
        if shutil.which(tool) is None:
            raise RuntimeError(f'缺少 {tool}；安装说明见 docker/patroni/README.md')
    paths = source_paths(root)
    check_sources(root, paths)
    python_paths = [path for path in paths if path.endswith('.py')]
    run([sys.executable, '-m', 'ruff', 'check', '--no-cache', '--isolated', '--select', 'F,E9', *python_paths], cwd=root)
    print(f'Patroni：语法、ShellCheck、OOSP 检查通过（{len(paths)} 个文件）', flush=True)
    check_compose(root)
    print('Patroni：生产配置与沙箱叠加 Compose 校验通过', flush=True)
    suite = unittest.defaultTestLoader.discover(str(root / 'scripts/tests'))
    if suite.countTestCases() == 0:
        raise RuntimeError('未发现离线测试，拒绝空测试放行')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise RuntimeError('Patroni 离线测试失败')
    print('Patroni 后端门禁：通过')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, SyntaxError, RuntimeError, yaml.YAMLError, subprocess.CalledProcessError) as error:
        print(f'Patroni 后端门禁：失败\n{error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr or error.stdout, file=sys.stderr)
        sys.exit(1)
