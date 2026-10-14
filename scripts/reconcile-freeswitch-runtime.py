#!/usr/bin/env python3
"""Reconcile only API-authorized Sofia gateways; never infer remote SIP removal."""
import base64
import fcntl
import grp
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET

NAME = re.compile(r"trunk-[0-9a-f]{32}\Z")


def gateways(data, require_external=True):
    root = ET.fromstring(data)
    if root.tag != 'configuration' or root.get('name') != 'sofia.conf':
        raise ValueError('Invalid Sofia configuration')
    if require_external and root.find("./profiles/profile[@name='external']") is None:
        raise ValueError('External profile is missing')
    result = {}
    for node in root.findall('./profiles/profile/gateways/gateway'):
        name = node.get('name', '')
        if not NAME.fullmatch(name) or name in result:
            raise ValueError('Invalid or duplicate managed gateway')
        result[name] = node
    return root, result


def signature(node):
    # Compare locally only: neither credentials nor their digests leave the host.
    return (node.tag, tuple(sorted(node.attrib.items())),
            tuple(sorted(signature(child) for child in node)))


def atomic_write(path, data, mode=0o640):
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            os.fchmod(output.fileno(), mode)
            if path.exists():
                st = path.stat()
                os.fchown(output.fileno(), st.st_uid, st.st_gid)
            elif mode == 0o640:
                try:
                    os.fchown(output.fileno(), 0, grp.getgrnam('freeswitch').gr_gid)
                except KeyError:
                    pass  # Unit tests have no FreeSWITCH service identity.
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Reconciler:
    def __init__(self, directory, state, cli, deadline=None):
        self.directory, self.state = directory, state
        deadline = time.monotonic() + 150 if deadline is None else deadline
        def bounded_cli(command, **kwargs):
            if time.monotonic() >= deadline:
                raise RuntimeError('Reconciliation deadline exceeded; next attempt will resume')
            return cli(command, **kwargs)
        self.cli = bounded_cli

    def status(self, name):
        output = self.cli('sofia status gateway ' + name, missing=True)
        if 'Invalid Gateway!' in output:
            return None
        match = re.search(r'^\s*State\s+(\S+)', output, re.M)
        if not match:
            raise RuntimeError('Gateway state unavailable: ' + name)
        return match[1].upper()

    def stop(self, name):
        state = self.status(name)
        if state is None:
            return 'absent'
        if state not in ('DOWN', 'NOREG'):
            self.cli('sofia profile external unregister ' + name)
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline:
                state = self.status(name)
                if state is None or state in ('DOWN', 'NOREG'):
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError('Local unregistration timed out: ' + name)
        if state is not None:
            self.cli('sofia profile external killgw ' + name)
            deadline = time.monotonic() + 10
            while self.status(name) is not None:
                if time.monotonic() >= deadline:
                    raise RuntimeError('Gateway removal timed out: ' + name)
                time.sleep(0.25)
        return 'removed'

    def apply(self, sofia, acl):
        root, desired = gateways(sofia)
        acl_root = ET.fromstring(acl)
        if acl_root.tag != 'configuration' or acl_root.get('name') != 'acl.conf':
            raise ValueError('Invalid ACL configuration')
        retirements = {n.get('name') for n in root.findall('./mnscloud-retirements/gateway')}
        if any(not NAME.fullmatch(n or '') for n in retirements) or retirements & desired.keys():
            raise ValueError('Invalid retirement authorization')
        target = self.directory / 'sofia.conf.xml'
        previous = target.read_bytes() if target.exists() else None
        # A first installation has only the packaged profile include. The API
        # snapshot still requires an explicit external profile; loaded gateways
        # remain subject to the same authoritative retirement checks below.
        old = gateways(previous, require_external=False)[1] if previous else {}
        # Runtime inventory is authoritative for loaded gateways; a crash may leave
        # the disk and process at different phases. Do not inspect SIP credentials.
        output = self.cli('sofia status gateways')
        loaded = set(re.findall(r'\btrunk-[0-9a-f]{32}\b', output))
        removed = (old.keys() | loaded) - desired.keys()
        if removed - retirements:
            raise RuntimeError('Retirement authorization missing for managed gateway')
        changed = {n for n in old.keys() & desired.keys() if signature(old[n]) != signature(desired[n])}
        changed |= (loaded & desired.keys()) - old.keys()
        pending = self.state / 'pending.json'
        recovering = pending.exists()
        if recovering:
            journal = json.loads(pending.read_text())
            # Only reapply identities still authorized in this fresh API snapshot.
            changed |= set(journal.get('replace', [])) & desired.keys()
        plan = {'replace': sorted(changed), 'remove': sorted(removed), 'phase': 'prepared'}
        atomic_write(pending, json.dumps(plan).encode(), 0o600)
        observations = []
        # Stop affected registrations while their old handles still exist.
        for name in sorted(removed | changed):
            observations.append({'runtimeName': name, 'localRemoval': self.stop(name),
                                 'remoteRemoval': 'unconfirmed'})
        # Persist both validated documents before activating either. The journal
        # survives interruption; replay completes the latest authorized snapshot.
        if previous != sofia:
            atomic_write(target, sofia)
        acl_target = self.directory / 'acl.conf.xml'
        acl_changed = not acl_target.exists() or acl_target.read_bytes() != acl
        if acl_changed:
            atomic_write(acl_target, acl)
        if previous != sofia or changed or removed or desired.keys() - loaded or recovering or acl_changed:
            self.cli('reloadxml')
            self.cli('reloadacl')
            self.cli('sofia profile external rescan')
        for name in desired:
            deadline = time.monotonic() + 15
            while self.status(name) is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError('Desired gateway is not loaded: ' + name)
                time.sleep(0.25)
        for name, node in desired.items():
            registering = any(p.get('name') == 'register' and p.get('value') == 'true' for p in node.findall('param'))
            if registering and self.status(name) == 'DOWN':
                self.cli('sofia profile external register ' + name)
        for name in removed:
            if self.status(name) is not None:
                raise RuntimeError('Retired gateway remains loaded: ' + name)
        pending.unlink()
        return {'configurationApplied': True, 'gateways': len(desired), 'desiredGatewayNames': sorted(desired), 'retirements': observations}


def main():
    deadline = time.monotonic() + 150
    if os.geteuid() != 0:
        raise RuntimeError('Run as root')
    state = Path('/var/lib/mnscloud/freeswitch-reconcile')
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state, 0o700)
    with (state / 'lock').open('a') as lock:
        # A concurrent job cannot preempt a local executor on lease expiry.
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        identity = Path('/etc/mnscloud/pabx')
        base = (identity / 'api.base').read_text().strip().rstrip('/')
        node = (identity / 'node.uuid').read_text().strip()
        token = (identity / 'runtime.token').read_text().strip()
        if not base.startswith('https://') or not token:
            raise RuntimeError('Invalid runtime identity')
        def fetch(key):
            import urllib.parse
            data = urllib.parse.urlencode({'node_uuid': node, 'section': 'configuration',
                                           'key_value': key, 'materialize': '1'}).encode()
            request = urllib.request.Request(base + '/api/v1/pabx/freeswitch', data=data,
                headers={'Authorization': 'Basic ' + base64.b64encode(('mnscloud:' + token).encode()).decode(),
                         'Content-Type': 'application/x-www-form-urlencoded'})
            class NoRedirect(urllib.request.HTTPRedirectHandler):
                def redirect_request(self, req, fp, code, msg, headers, newurl):
                    return None
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
                body = response.read(4 * 1024 * 1024 + 1)
                if len(body) > 4 * 1024 * 1024:
                    raise RuntimeError('Runtime configuration exceeds size budget')
                return body
        def cli(command, missing=False):
            result = subprocess.run(['fs_cli', '-x', command], capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            if result.returncode or re.search(r'(?im)^\s*(?:-ERR|ERROR|FAILED)\b', output):
                raise RuntimeError('FreeSWITCH command failed: ' + command.split()[0])
            if 'Invalid Gateway!' in output and not missing:
                raise RuntimeError('Gateway unavailable')
            return output
        # Fetch and validate both before the first runtime mutation.
        result = Reconciler(Path('/etc/freeswitch/autoload_configs'), state, cli, deadline).apply(
            fetch('sofia.conf'), fetch('acl.conf'))
        print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # HTTP exceptions and XML may contain private values; report categories only.
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print('[sync-freeswitch-runtime] ERROR: ' + detail)
        raise SystemExit(1)
