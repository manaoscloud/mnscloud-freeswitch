#!/usr/bin/env python3
"""Apply the PABX server Logs tab on FreeSWITCH and keep /var/log/freeswitch bounded.

Run every minute by mnscloud-freeswitch-logs.timer. The level is applied live (fsctl loglevel,
reload mod_logfile, Sofia log level and SIP trace only in debug) and re-applied after a restart;
rotation is native (rotate-on-hup + fsctl send_sighup) and archives older than the retention are
deleted. json_cdr/ is never touched: failed CDR posts are billing data, not logs.
"""
import grp
import importlib.util
import os
from pathlib import Path
import pwd
import re
import subprocess
import time

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('mnscloud_engine_logs', HERE / 'mnscloud_engine_logs.py')
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)

IDENTITY = Path('/etc/mnscloud/pabx')
LOG_DIR = Path('/var/log/freeswitch')
LOG_FILE = LOG_DIR / 'freeswitch.log'
CONFIG = Path('/etc/freeswitch/autoload_configs/logfile.conf.xml')
STATE = core.STATE_ROOT / 'freeswitch-rotated'

# Every FreeSWITCH log level at or above the normalized one goes to the file.
MAPS = {
    'error': 'console,alert,crit,err',
    'warning': 'console,alert,crit,err,warning',
    'notice': 'console,alert,crit,err,warning,notice',
    'info': 'console,alert,crit,err,warning,notice,info',
    'debug': 'console,alert,crit,err,warning,notice,info,debug',
}
CORE_LEVEL = {'error': 'err', 'warning': 'warning', 'notice': 'notice', 'info': 'info', 'debug': 'debug'}


def render(level):
    return f'''<configuration name="logfile.conf" description="File Logging">
  <!-- Managed by MNSCloud (PABX server Logs tab); rewritten by freeswitch-logs.py. -->
  <settings>
    <param name="rotate-on-hup" value="true"/>
  </settings>
  <profiles>
    <profile name="default">
      <settings>
        <!-- Safety net only: freeswitch-logs.py rotates daily or above 512 MiB. -->
        <param name="rollover" value="1073741824"/>
        <param name="uuid" value="true"/>
      </settings>
      <mappings>
        <map name="all" value="{MAPS[level]}"/>
      </mappings>
    </profile>
  </profiles>
</configuration>
'''


def owner():
    try:
        return pwd.getpwnam('freeswitch').pw_uid, grp.getgrnam('freeswitch').gr_gid
    except KeyError:
        return None


def cli(command):
    result = subprocess.run(['fs_cli', '-x', command], capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    if result.returncode or re.search(r'(?im)^\s*(?:-ERR|ERROR|FAILED)\b', output):
        raise RuntimeError('FreeSWITCH command failed: ' + command.split()[0])
    return output


def main_pid():
    result = subprocess.run(['systemctl', 'show', '-p', 'MainPID', '--value', 'freeswitch'],
                            capture_output=True, text=True, timeout=10)
    return result.stdout.strip() or '0'


def apply(settings, previous):
    level = core.effective_level(settings, core.low_disk(LOG_DIR))
    changed = core.write_if_changed(CONFIG, render(level), 0o640, owner())
    marker = {'pid': main_pid(), 'level': level}
    if marker['pid'] == '0':
        return {'pid': '0', 'level': None}  # Not running: apply on the next refresh.
    if changed or marker != previous:
        cli('reload mod_logfile')
        cli('fsctl loglevel ' + CORE_LEVEL[level])
        cli('sofia loglevel all ' + ('9' if level == 'debug' else '0'))
        cli('sofia global siptrace ' + ('on' if level == 'debug' else 'off'))
    return marker


def native_rotation():
    before = set(LOG_DIR.glob('freeswitch.log.*'))
    cli('fsctl send_sighup')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        produced = [p for p in set(LOG_DIR.glob('freeswitch.log.*')) - before if not p.name.endswith('.gz')]
        if produced:
            time.sleep(0.5)  # let mod_logfile finish the rename and reopen
            return max(produced, key=lambda p: p.stat().st_mtime)
        time.sleep(0.25)
    return None


def maintain(settings):
    days = settings['logRetentionDays']
    rotated = core.rotate(LOG_FILE, STATE, owner(),
                          native=native_rotation if main_pid() != '0' else None)
    deleted = core.purge(LOG_DIR, ['freeswitch.log-*.gz', 'freeswitch.log.[0-9]*'], days)
    deleted += core.purge(LOG_DIR / 'xml_curl', ['*'], days)
    core.maintain_install_log(days)
    return {'rotated': str(rotated) if rotated else None, 'deleted': deleted}


def fetch():
    base, node, token = core.read_identity(IDENTITY, 'runtime.token')
    return core.fetch_settings(base, 'pabx/runtime/log-config', node, token,
                               headers={'X-PABX-Node-UUID': node})


if __name__ == '__main__':
    os.environ.setdefault('LC_ALL', 'C')
    core.main('freeswitch', fetch, apply, maintain)
