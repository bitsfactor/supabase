"""Patroni 离线安全契约；运行：python3 -m unittest discover -s scripts/tests。"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
PATRONI = ROOT / 'docker/patroni'


def load_module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class PatroniTests(unittest.TestCase):
    def test_migration_hba_preserves_the_original_postgres_replication_account(self):
        configuration = yaml.safe_load((PATRONI / 'patroni.yml').read_text())
        for rules in [configuration['bootstrap']['pg_hba'], configuration['bootstrap']['dcs']['postgresql']['pg_hba']]:
            self.assertIn('host replication postgres 0.0.0.0/0 scram-sha-256', rules)
            self.assertIn('host replication postgres ::/0 scram-sha-256', rules)

    def test_entry_closes_legacy_sessions_when_new_primary_is_ready(self):
        template = (PATRONI / 'confd/templates/haproxy.tmpl').read_text()
        defaults = next(line for line in template.splitlines() if line.strip().startswith('default-server '))
        self.assertIn('on-marked-up shutdown-backup-sessions', defaults)
        self.assertIn('on-marked-down shutdown-sessions', defaults)
        self.assertIn('check-ssl verify required', defaults)
        self.assertIn('server legacy {{getenv "ENTRY_BACKUP"}} backup', template)

    def test_service_configuration_isolates_rehearsal_with_unchanged_defaults(self):
        manifest = yaml.safe_load((ROOT / '.deploy.patroni.yaml').read_text())
        fields = {item['key']: item for item in manifest['config_schema']}
        self.assertEqual(fields['PT_DATA_DIR']['default'], '/opt/supabase/docker/volumes/db/data')
        self.assertEqual(fields['PT_SYNC']['default'], '')
        self.assertEqual(fields['ETCD_INITIAL_CLUSTER_STATE']['default'], 'new')
        self.assertEqual(fields['PT_NETWORK_SUBNET']['default'], '10.254.240.0/28')
        self.assertEqual(fields['PT_MIGRATION_SLOTS']['default'], '')
        network = yaml.safe_load((PATRONI / 'service/docker-compose.yml').read_text())['networks']['default']
        self.assertEqual(network['name'], 'patroni-fixed')
        self.assertEqual(network['ipam']['config'], [{'subnet': '${PT_NETWORK_SUBNET:-10.254.240.0/28}'}])
        compose = (PATRONI / 'service/docker-compose.yml').read_text()
        self.assertIn('--initial-cluster-state=${ETCD_INITIAL_CLUSTER_STATE:-new}', compose)
        for name, reference in [('PT_SUPERUSER_PASSWORD', 'system_config:supabase_postgres.password')]:
            self.assertEqual(fields[name]['default'], reference)
            self.assertEqual(fields[name]['type'], 'password')
            self.assertTrue(fields[name]['required'])
            self.assertFalse(any(item['env'] == name for item in manifest.get('secrets', [])))
        self.assertEqual(fields['PT_PGSODIUM_ROOT_KEY']['default'], '')
        self.assertFalse(fields['PT_PGSODIUM_ROOT_KEY'].get('required', False))

    def test_render(self):
        environment = {
            'PT_NAME': 'fixture', 'PT_HOST': '192.0.2.1',
            'PT_PG_PORT': '5433', 'PT_REST_PORT': '8008',
            'PT_ETCD_HOSTS': '192.0.2.2:2379',
            'PT_REST_PASSWORD': 'fixture', 'PT_SUPERUSER_PASSWORD': 'fixture',
            'PT_REPL_PASSWORD': 'fixture', 'PT_MAX_CONNECTIONS': '100',
            'PT_MAX_WAL_SENDERS': '10', 'PT_MAX_REPLICATION_SLOTS': '10',
            'PT_MAX_WORKER_PROCESSES': '8', 'PT_MAX_LOCKS_PER_TRANSACTION': '64',
            'PT_MAX_PREPARED_TRANSACTIONS': '0',
        }
        for extra, expected in [({}, 'quorum'), ({'PT_STANDBY_HOST': '192.0.2.3'}, False),
                                ({'PT_MIGRATION_SLOTS': 'old_cascade_slot'}, 'quorum'),
                                ({'PT_SYNC': 'false'}, False)]:
            with self.subTest(extra=extra):
                result = subprocess.run([sys.executable, str(PATRONI / 'render.py'),
                                         str(PATRONI / 'patroni.yml')], env={**environment, **extra},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                configuration = yaml.safe_load(result.stdout)
                if extra.get('PT_MIGRATION_SLOTS'):
                    self.assertEqual(configuration['bootstrap']['dcs']['slots'], {'old_cascade_slot': {'type': 'physical'}})
                self.assertEqual(configuration['bootstrap']['dcs']['synchronous_mode'], expected)
                self.assertEqual(configuration['restapi']['verify_client'], 'required')
                self.assertEqual(configuration['bootstrap']['dcs']['postgresql']['parameters']['wal_level'], 'logical')
                if extra.get('PT_STANDBY_HOST'):
                    self.assertEqual(configuration['bootstrap']['dcs']['standby_cluster'],
                                     {'host': '192.0.2.3', 'port': 5433})
        result = subprocess.run([sys.executable, str(PATRONI / 'render.py'),
                                 str(PATRONI / 'patroni.yml')], env={}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('is required', result.stderr)
        result = subprocess.run([sys.executable, str(PATRONI / 'render.py'), str(PATRONI / 'patroni.yml')],
                                env={**environment, 'PT_MIGRATION_SLOTS': 'bad-slot'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid physical slot name', result.stderr)

    def test_key_install_preserves_unmanaged_files_and_refuses_explicit_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'root.key'
            environment = {'PATH': os.defpath, 'PGSODIUM_KEY_FILE': str(path), 'PGSODIUM_SKIP_CHOWN': '1'}
            def run(key):
                return subprocess.run(['bash', str(PATRONI / 'pgsodium-key.sh')],
                                      env={**environment, 'PT_PGSODIUM_ROOT_KEY': key},
                                      capture_output=True, text=True)
            self.assertEqual(run('').returncode, 0)
            self.assertFalse(path.exists())
            self.assertEqual(run('invalid').returncode, 79)
            self.assertFalse(path.exists())
            self.assertEqual(run('a' * 64).returncode, 0)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(run('a' * 64).returncode, 0)
            self.assertEqual(run('').returncode, 0)
            self.assertEqual(run('b' * 64).returncode, 79)
            self.assertEqual(path.read_text(), 'a' * 64)
            path.write_text('legacy-key-not-validated-when-unmanaged')
            path.chmod(0o640)
            before = path.stat()
            self.assertEqual(run('').returncode, 0)
            after = path.stat()
            self.assertEqual(path.read_text(), 'legacy-key-not-validated-when-unmanaged')
            self.assertEqual((after.st_ino, after.st_mode, after.st_mtime_ns),
                             (before.st_ino, before.st_mode, before.st_mtime_ns))

    def test_guard_state_and_failed_stop(self):
        guard = load_module('patroni_guard', PATRONI / 'guard.py')
        with tempfile.TemporaryDirectory() as directory, patch.object(guard, 'STATE', str(Path(directory) / 'state.json')), \
                patch.object(guard, 'LOCK', str(Path(directory) / 'state.lock')):
            self.assertEqual(guard.load(), {'targets': {}})
            with self.assertRaises(FileNotFoundError):
                guard.load(required=True)
            guard.update(lambda state: state['targets'].update(fixture={'probe': 'fixture', 'ssh': 'fixture'}))
            with patch.object(guard, 'reachable', return_value=False), patch.object(guard, 'stop_remote') as stop:
                guard.tick()
                stop.assert_not_called()
            with patch.object(guard, 'reachable', return_value=True), \
                    patch.object(guard.time, 'time', return_value=100), \
                    patch.object(guard, 'stop_remote', side_effect=OSError('fixture')):
                guard.tick()
            target = guard.load()['targets']['fixture']
            self.assertFalse(target['stopped'])
            self.assertEqual(target['attempts'], 1)
            with patch.object(guard, 'reachable', return_value=True), \
                    patch.object(guard.time, 'time', return_value=101), patch.object(guard, 'stop_remote') as stop:
                guard.tick()
                stop.assert_not_called()
            Path(guard.STATE).write_text(json.dumps({'targets': []}))
            with self.assertRaises(ValueError):
                guard.load()
