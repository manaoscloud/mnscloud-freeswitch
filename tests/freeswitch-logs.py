#!/usr/bin/env python3
"""FreeSWITCH translation of the PABX server Logs tab, with a fake fs_cli."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('fslogs', ROOT / 'scripts/freeswitch-logs.py')
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)
BASE = {'managed': True, 'logEnabled': True, 'logLevel': 'notice', 'logRetentionDays': 7,
        'logDebugUntil': None}


class FreeswitchLogs(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.calls = []
        self.pid = '100'
        patches = [
            mock.patch.object(fs, 'CONFIG', self.dir / 'logfile.conf.xml'),
            mock.patch.object(fs, 'LOG_DIR', self.dir),
            mock.patch.object(fs, 'cli', side_effect=lambda command: self.calls.append(command) or '+OK'),
            mock.patch.object(fs, 'main_pid', side_effect=lambda: self.pid),
            mock.patch.object(fs, 'owner', return_value=None),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_every_level_renders_valid_xml_with_cumulative_maps(self):
        previous = set()
        for level in ('error', 'warning', 'notice', 'info', 'debug'):
            root = ET.fromstring(fs.render(level))
            self.assertEqual(root.get('name'), 'logfile.conf')
            self.assertEqual(root.find('./settings/param').get('name'), 'rotate-on-hup')
            levels = set(root.find('./profiles/profile/mappings/map').get('value').split(','))
            self.assertTrue(previous < levels, level)
            previous = levels

    def test_apply_runs_live_commands_only_on_change_or_restart(self):
        marker = fs.apply(dict(BASE, logLevel='debug'), None)
        self.assertEqual(marker, {'pid': '100', 'level': 'debug'})
        self.assertEqual(self.calls, ['reload mod_logfile', 'fsctl loglevel debug',
                                      'sofia loglevel all 9', 'sofia global siptrace on'])
        self.calls.clear()
        self.assertEqual(fs.apply(dict(BASE, logLevel='debug'), marker), marker)
        self.assertEqual(self.calls, [], 'unchanged settings are not re-applied')
        self.pid = '200'
        fs.apply(dict(BASE, logLevel='debug'), marker)
        self.assertIn('fsctl loglevel debug', self.calls, 'a restart re-applies the live level')

    def test_disabled_log_keeps_errors_and_turns_trace_off(self):
        marker = fs.apply(dict(BASE, logEnabled=False, logLevel='debug'), None)
        self.assertEqual(marker['level'], 'error')
        self.assertIn('fsctl loglevel err', self.calls)
        self.assertIn('sofia global siptrace off', self.calls)
        self.assertIn('console,alert,crit,err"', (self.dir / 'logfile.conf.xml').read_text())

    def test_stopped_engine_is_applied_on_the_next_refresh(self):
        self.pid = '0'
        self.assertEqual(fs.apply(BASE, None), {'pid': '0', 'level': None})
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
