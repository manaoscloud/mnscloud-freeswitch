#!/usr/bin/env python3
"""Contract tests for the shared engine log settings core (server Logs tab)."""
from datetime import datetime, timedelta
import gzip
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('core', ROOT / 'scripts/mnscloud_engine_logs.py')
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)

SETTINGS = {'managed': True, 'logEnabled': True, 'logLevel': 'info', 'logRetentionDays': 7,
            'logDebugUntil': None}


class EngineLogsCore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.log = self.dir / 'engine.log'
        self.state = self.dir / 'rotated'

    def test_validate_rejects_unknown_values(self):
        self.assertEqual(core.validate({'logLevel': 'DEBUG', 'logRetentionDays': 3, 'logEnabled': True})['logLevel'], 'debug')
        for bad in ({'logLevel': 'trace', 'logRetentionDays': 7}, {'logLevel': 'info', 'logRetentionDays': 0},
                    {'logLevel': 'info', 'logRetentionDays': 91}, {'logLevel': 'info', 'logRetentionDays': '7'}):
            with self.assertRaises(RuntimeError):
                core.validate(bad)

    def test_effective_level_keeps_errors_and_caps_on_low_disk(self):
        self.assertEqual(core.effective_level(dict(SETTINGS, logEnabled=False)), 'error')
        self.assertEqual(core.effective_level(dict(SETTINGS, logLevel='debug'), low_disk=True), 'notice')
        self.assertEqual(core.effective_level(dict(SETTINGS, logLevel='warning'), low_disk=True), 'warning')

    def test_daily_copytruncate_rotation_and_retention(self):
        self.log.write_bytes(b'line\n' * 100)
        now = datetime(2026, 10, 15, 12, 0, 0)
        archive = core.rotate(self.log, self.state, now=now)
        self.assertEqual(archive.name, 'engine.log-20261015-120000.gz')
        self.assertEqual(gzip.decompress(archive.read_bytes()), b'line\n' * 100)
        self.assertEqual(self.log.stat().st_size, 0)
        self.assertEqual(oct(archive.stat().st_mode & 0o777), '0o640')
        self.log.write_bytes(b'more\n')
        self.assertIsNone(core.rotate(self.log, self.state, now=now + timedelta(hours=1)), 'once a day')
        self.assertIsNotNone(core.rotate(self.log, self.state, now=now + timedelta(days=1)))
        old = self.dir / 'engine.log-20260901-000000.gz'
        old.write_bytes(b'x')
        os.utime(old, (now.timestamp() - 10 * 86400,) * 2)
        legacy = self.dir / 'engine.log.1'
        legacy.write_bytes(b'x')
        os.utime(legacy, (now.timestamp() - 30 * 86400,) * 2)
        self.assertEqual(core.purge(self.dir, ['engine.log-*.gz', 'engine.log.[0-9]*'], 7, now=now), 2)
        self.assertTrue(archive.exists())

    def test_size_cap_and_native_rotation(self):
        self.log.write_bytes(b'a' * 2048)
        now = datetime(2026, 10, 15)
        self.state.write_text('2026-10-15\n')
        native = self.dir / 'engine.log.2026-10-15-00-00-00.1'
        def rename():
            self.log.replace(native)
            self.log.write_bytes(b'')
            return native
        archive = core.rotate(self.log, self.state, now=now, native=rename, max_bytes=1024)
        self.assertEqual(gzip.decompress(archive.read_bytes()), b'a' * 2048)
        self.assertFalse(native.exists(), 'the native file is compressed and removed')

    def test_full_disk_leaves_the_log_untouched(self):
        self.log.write_bytes(b'a' * 4096)
        with mock.patch.object(core.shutil, 'disk_usage', return_value=mock.Mock(free=0, total=100)):
            self.assertEqual(core.rotate(self.log, self.state, now=datetime(2026, 10, 15)), 'skipped:low-disk')
        self.assertEqual(self.log.stat().st_size, 4096)
        self.assertEqual(list(self.dir.glob('*.gz')), [])

    def test_run_reuses_last_settings_when_api_fails(self):
        applied = []
        def apply(settings, previous):
            applied.append((settings['logLevel'], previous))
            return {'level': settings['logLevel']}
        with mock.patch.object(core.os, 'geteuid', return_value=0):
            first = core.run('test', lambda: dict(SETTINGS, logLevel='warning'), apply, lambda s: 'ok', self.dir)
            def broken():
                raise OSError('unreachable')
            second = core.run('test', broken, apply, lambda s: 'ok', self.dir)
            unmanaged = core.run('test', lambda: dict(SETTINGS, managed=False), apply, lambda s: 'ok', self.dir)
        self.assertEqual(first['source'], 'api')
        self.assertEqual(second['source'], 'cached:OSError')
        self.assertEqual(applied, [('warning', None), ('warning', {'level': 'warning'})])
        self.assertIsNone(unmanaged['level'])
        state = json.loads((self.dir / 'test.json').read_text())
        self.assertNotIn('token', json.dumps(state))
        self.assertEqual(oct((self.dir / 'test.json').stat().st_mode & 0o777), '0o600')

    def test_apply_failure_still_runs_housekeeping_and_retries(self):
        maintained = []
        def failing(settings, previous):
            raise RuntimeError('Engine command failed: logger')
        with mock.patch.object(core.os, 'geteuid', return_value=0):
            result = core.run('test', lambda: SETTINGS, failing, maintained.append, self.dir)
        self.assertEqual(result['error'], 'Engine command failed: logger')
        self.assertEqual(len(maintained), 1)
        self.assertIsNone(json.loads((self.dir / 'test.json').read_text())['applied'])

    def test_journald_retention_is_idempotent(self):
        path = self.dir / 'journald.conf.d' / '60-mnscloud-engine-logs.conf'
        self.assertTrue(core.journald_retention(7, path))
        self.assertFalse(core.journald_retention(7, path))
        self.assertIn('MaxRetentionSec=7day', path.read_text())
        self.assertTrue(core.journald_retention(30, path))

    def test_fetch_requires_https(self):
        with self.assertRaises(RuntimeError):
            core.fetch_settings('http://api.example.invalid', 'x/log-config', 'node', 'token')


if __name__ == '__main__':
    unittest.main()
