#!/usr/bin/env python3
"""Behavioral crash/retry tests for the actual reconciler with a fake Sofia CLI."""
import importlib.util
from pathlib import Path
import tempfile
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('reconcile', Path(__file__).resolve().parents[1] / 'scripts/reconcile-freeswitch-runtime.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
A, B, C = ['trunk-' + x * 32 for x in 'abc']
ACL = b'<configuration name="acl.conf"><network-lists/></configuration>'


def xml(names, retired=(), proxy='sip.example.invalid'):
    gw = ''.join(f'<gateway name="{name}"><param name="proxy" value="{proxy}"/><param name="register" value="true"/></gateway>' for name in names)
    return (f'<configuration name="sofia.conf"><profiles><profile name="external"><gateways>{gw}</gateways></profile></profiles><mnscloud-retirements>' + ''.join(f'<gateway name="{n}"/>' for n in retired) + '</mnscloud-retirements></configuration>').encode()


class TestReconcile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.state = self.path / 'state'
        self.state.mkdir()
        self.loaded = {}
        self.calls = []
        self.fail_rescan = False
        def cli(command, missing=False):
            self.calls.append(command)
            name = command.split()[-1]
            if command == 'sofia status gateways':
                return '\n'.join(self.loaded)
            if command.startswith('sofia status gateway '):
                return 'State ' + self.loaded[name] if name in self.loaded else 'Invalid Gateway!'
            if ' unregister ' in command:
                self.loaded[name] = 'DOWN'
            elif ' killgw ' in command:
                self.loaded.pop(name, None)
            elif command == 'sofia profile external rescan':
                if self.fail_rescan:
                    raise RuntimeError('Injected activation failure')
                for name in m.gateways((self.path / 'sofia.conf.xml').read_bytes())[1]:
                    self.loaded.setdefault(name, 'REGED')
            elif ' register ' in command:
                self.loaded[name] = 'REGED'
            return '+OK'
        self.reconciler = m.Reconciler(self.path, self.state, cli)

    def previous(self, names, loaded=True):
        (self.path / 'sofia.conf.xml').write_bytes(xml(names))
        if loaded:
            self.loaded.update({name: 'REGED' for name in names})

    def test_two_retirements_and_new_gateway(self):
        self.previous([A, B])
        result = self.reconciler.apply(xml([C], [A, B]), ACL)
        self.assertEqual(self.loaded, {C: 'REGED'})
        self.assertTrue(result['configurationApplied'])
        self.assertTrue(all(r['remoteRemoval'] == 'unconfirmed' for r in result['retirements']))
        self.assertLess(self.calls.index('sofia profile external unregister ' + A), self.calls.index('sofia profile external killgw ' + A))

    def test_initial_install_with_profile_include(self):
        bootstrap = b'<configuration name="sofia.conf"><profiles><X-PRE-PROCESS cmd="include" data="../sip_profiles/*.xml"/></profiles></configuration>'
        (self.path / 'sofia.conf.xml').write_bytes(bootstrap)
        result = self.reconciler.apply(xml([A]), ACL)
        self.assertTrue(result['configurationApplied'])
        self.assertEqual(self.loaded, {A: 'REGED'})

    def test_installer_preserves_snapshot_and_bootstraps_missing_file(self):
        installer = (Path(__file__).resolve().parents[1] / 'scripts/install-freeswitch.sh').read_text()
        function = installer.split('write_sofia_config() {', 1)[1].split('\nwrite_internal_profile()', 1)[0]
        path = self.path / 'sofia.conf.xml'
        function = ('write_sofia_config() {' + function).replace('/etc/freeswitch/autoload_configs/sofia.conf.xml', str(path))
        script = 'set -e; backup_once() { :; }; write_file() { printf "%s" "$2" > "$1"; }; run() { eval "$1"; };\n' + function + '\nwrite_sofia_config'
        self.previous([A])
        before = path.read_bytes()
        subprocess.run(['bash', '-c', script], check=True)
        self.assertEqual(path.read_bytes(), before)
        path.unlink()
        subprocess.run(['bash', '-c', script], check=True)
        self.assertIn(b'X-PRE-PROCESS', path.read_bytes())
        self.reconciler.apply(xml([A]), ACL)
        self.assertEqual(self.loaded, {A: 'REGED'})

    def test_bootstrap_does_not_relax_desired_validation(self):
        bootstrap = b'<configuration name="sofia.conf"><profiles/></configuration>'
        (self.path / 'sofia.conf.xml').write_bytes(bootstrap)
        with self.assertRaises(ValueError):
            self.reconciler.apply(bootstrap, ACL)
        self.assertEqual(self.calls, [])

    def test_bootstrap_loaded_gateway_still_requires_authority(self):
        (self.path / 'sofia.conf.xml').write_bytes(b'<configuration name="sofia.conf"><profiles/></configuration>')
        self.loaded[A] = 'REGED'
        with self.assertRaises(RuntimeError):
            self.reconciler.apply(xml([B]), ACL)
        self.assertEqual(self.loaded, {A: 'REGED'})
        self.assertFalse(any('killgw' in c or 'unregister' in c for c in self.calls))

    def test_absent_retired_gateways_are_idempotent(self):
        self.previous([A, B], loaded=False)
        self.reconciler.apply(xml([C], [A, B]), ACL)
        self.reconciler.apply(xml([C], [A, B]), ACL)
        self.assertFalse(any('killgw' in c or 'unregister' in c for c in self.calls))
        self.assertEqual(self.loaded, {C: 'REGED'})

    def test_unchanged_gateway_is_preserved(self):
        self.previous([A])
        self.reconciler.apply(xml([A, B]), ACL)
        self.assertFalse(any('killgw' in c or 'unregister' in c for c in self.calls))

    def test_changed_gateway_only(self):
        self.previous([A])
        self.reconciler.apply(xml([A], proxy='new.example.invalid'), ACL)
        self.assertIn('sofia profile external killgw ' + A, self.calls)
        self.assertEqual(self.loaded[A], 'REGED')

    def test_activation_failure_resumes(self):
        self.previous([A])
        self.fail_rescan = True
        with self.assertRaises(RuntimeError):
            self.reconciler.apply(xml([A], proxy='new.example.invalid'), ACL)
        self.assertTrue((self.state / 'pending.json').exists())
        self.fail_rescan = False
        self.reconciler.apply(xml([A], proxy='new.example.invalid'), ACL)
        self.assertEqual(self.loaded[A], 'REGED')
        self.assertFalse((self.state / 'pending.json').exists())

    def test_missing_authority_fails_before_mutation(self):
        self.previous([A])
        with self.assertRaises(RuntimeError):
            self.reconciler.apply(xml([B]), ACL)
        self.assertEqual(self.loaded, {A: 'REGED'})
        self.assertFalse(any('killgw' in c or 'unregister' in c for c in self.calls))

    def test_invalid_acl_cannot_remove_gateway(self):
        self.previous([A])
        with self.assertRaises(ValueError):
            self.reconciler.apply(xml([B], [A]), b'<configuration name="wrong"/>')
        self.assertEqual(self.calls, [])

    def test_loaded_orphan_requires_explicit_authority(self):
        self.loaded[A] = 'DOWN'
        self.reconciler.apply(xml([B], [A]), ACL)
        self.assertNotIn(A, self.loaded)
        self.assertNotIn('sofia profile external unregister ' + A, self.calls)


if __name__ == '__main__':
    unittest.main()
