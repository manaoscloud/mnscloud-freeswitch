#!/usr/bin/env python3
"""Engine log settings (server Logs tab) applied on a MNSCloud runtime node.

Shared, identical copy in every engine repository (FreeSWITCH, Asterisk, Kamailio Softswitch,
OpenSIPS SBC, Media). Each engine script supplies how to translate the normalized level and which
files to keep; this module owns the API pull, rotation, retention, disk guard and local state.

Contract (API `.../log-config`): logEnabled, logLevel (error|warning|notice|info|debug),
logRetentionDays (1-90) and logDebugUntil. A disabled log keeps errors and security events, so it
is applied as level `error`. When the API is unreachable the last applied settings stay in force.
Logs carry SIP identities and numbers: archives stay 0640 and never leave the host.
"""
from datetime import datetime
import fcntl
import gzip
import json
import os
from pathlib import Path
import shutil
import sys
import urllib.parse
import urllib.request

LEVELS = ('error', 'warning', 'notice', 'info', 'debug')
DEFAULTS = {'logEnabled': True, 'logLevel': 'notice', 'logRetentionDays': 7}
MAX_BYTES = 512 * 1024 * 1024
MIN_FREE_RATIO = 0.15
STATE_ROOT = Path('/var/lib/mnscloud/engine-logs')
RESPONSE_LIMIT = 64 * 1024


def read_identity(directory, token_name, base_name='api.base', node_name='node.uuid'):
    directory = Path(directory)
    base = (directory / base_name).read_text().strip().rstrip('/')
    node = (directory / node_name).read_text().strip()
    token = (directory / token_name).read_text().strip()
    if not base.startswith('https://') or not node or not token:
        raise RuntimeError('Invalid runtime identity')
    return base, node, token


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_settings(base, path, node, token, query=None, headers=None):
    """POSTs the authenticated node identity and returns the validated settings."""
    if not base.startswith('https://'):
        raise RuntimeError('Runtime API must use HTTPS')
    base = base.rstrip('/')
    if base.endswith('/api/v1'):
        base = base[:-len('/api/v1')]
    params = urllib.parse.urlencode({'node_uuid': node, **(query or {})})
    request = urllib.request.Request(
        f'{base}/api/v1/{path.lstrip("/")}?{params}', data=b'{}', method='POST',
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                 'Accept': 'application/json', **(headers or {})})
    with urllib.request.build_opener(_NoRedirect()).open(request, timeout=20) as response:
        body = response.read(RESPONSE_LIMIT + 1)
    if len(body) > RESPONSE_LIMIT:
        raise RuntimeError('Log settings response exceeds size budget')
    return validate(json.loads(body).get('data') or {})


def validate(data):
    level = str(data.get('logLevel', '')).lower()
    days = data.get('logRetentionDays')
    if level not in LEVELS or type(days) is not int or not 1 <= days <= 90:
        raise RuntimeError('Invalid log settings')
    return {'managed': data.get('managed') is not False, 'logEnabled': data.get('logEnabled') is not False,
            'logLevel': level, 'logRetentionDays': days, 'logDebugUntil': data.get('logDebugUntil')}


def effective_level(settings, low_disk=False):
    """Level the engine applies: disabled keeps only errors, a low disk caps debug/info at notice."""
    level = settings['logLevel'] if settings['logEnabled'] else 'error'
    if low_disk and LEVELS.index(level) > LEVELS.index('notice'):
        return 'notice'
    return level


def low_disk(path):
    usage = shutil.disk_usage(path)
    return usage.total > 0 and usage.free / usage.total < MIN_FREE_RATIO


def protect(path, mode, owner=None):
    if owner:
        os.chown(path, *owner, follow_symlinks=False)
    os.chmod(path, mode, follow_symlinks=False)


def rotate(log, state, owner=None, now=None, native=None, max_bytes=MAX_BYTES, mode=0o640):
    """Rotates `log` once a day or above `max_bytes`; returns the archive path, 'skipped:low-disk' or None.

    `mode` is kept on the live log (a writer outside the engine may need group write);
    archives are always 0640. `native()` asks the engine to rotate itself (rename + reopen) and returns the file it produced;
    without it the file is copied and truncated, as logrotate's copytruncate does. When the disk
    cannot hold the compressed copy nothing is changed.
    """
    log, state, now = Path(log), Path(state), now or datetime.now()
    if not log.is_file() or log.is_symlink():
        return None
    size, today = log.stat().st_size, now.strftime('%Y-%m-%d')
    last = state.read_text().strip() if state.is_file() else ''
    if not size or (last == today and size <= max_bytes):
        protect(log, mode, owner)
        return None
    if shutil.disk_usage(log.parent).free < size // 4 + 64 * 1024 * 1024:
        # No room for the compressed copy: leave the log untouched (the level is already capped at
        # notice on a low disk) and report it; freeing space is an operator decision.
        return 'skipped:low-disk'
    archive = log.with_name(f'{log.name}-{now:%Y%m%d-%H%M%S}.gz')
    pending = archive.with_name('.' + archive.name + '.tmp')
    source = native() if native else None
    if source is not None and Path(source).is_file():
        with Path(source).open('rb') as data, gzip.open(pending, 'wb') as target:
            shutil.copyfileobj(data, target)
        Path(source).unlink()
    else:
        with log.open('rb') as data, gzip.open(pending, 'wb') as target:
            shutil.copyfileobj(data, target)
        os.truncate(log, 0)
    protect(pending, 0o640, owner)
    pending.replace(archive)
    state.write_text(today + '\n')
    if log.exists():
        protect(log, mode, owner)
    return archive


def purge(directory, patterns, days, now=None, keep_newest=0):
    """Deletes regular files matching `patterns` older than `days`; returns how many were removed."""
    directory, now = Path(directory), now or datetime.now()
    if not directory.is_dir() or directory.is_symlink():
        return 0
    cutoff, deleted = now.timestamp() - days * 86400, 0
    candidates = sorted({p for pattern in patterns for p in directory.glob(pattern)
                         if p.is_file() and not p.is_symlink()}, key=lambda p: p.stat().st_mtime)
    for old in candidates[:max(0, len(candidates) - keep_newest)]:
        if old.stat().st_mtime < cutoff:
            old.unlink()
            deleted += 1
    return deleted


def maintain_install_log(days, log=Path('/var/log/mnscloud-install.log')):
    """The shared installer log of every module grows with each update: rotate and purge it too."""
    rotated = rotate(log, STATE_ROOT / 'install-log-rotated')
    return rotated, purge(log.parent, [log.name + '-*.gz'], days)


def journald_retention(days, path=Path('/etc/systemd/journald.conf.d/60-mnscloud-engine-logs.conf')):
    """Caps the journal of a node whose engine logs to journald; True when the file changed."""
    content = ('# Managed by MNSCloud engine log settings (server Logs tab).\n'
               f'[Journal]\nMaxRetentionSec={days}day\nSystemMaxUse=2G\n')
    if path.is_file() and path.read_text() == content:
        return False
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    temporary = path.with_name('.' + path.name + '.tmp')
    temporary.write_text(content)
    os.chmod(temporary, 0o640)  # read by systemd-journald (root) only
    temporary.replace(path)
    return True


def write_if_changed(path, content, mode=0o640, owner=None):
    path = Path(path)
    data = content.encode() if isinstance(content, str) else content
    if path.is_file() and path.read_bytes() == data:
        return False
    temporary = path.with_name('.' + path.name + '.tmp')
    temporary.write_bytes(data)
    protect(temporary, mode, owner)
    temporary.replace(path)
    return True


def run(engine, fetch, apply, maintain, state_root=STATE_ROOT):
    """Runs one refresh: fetch (or reuse the last) settings, apply them, then housekeeping.

    `apply(settings, level, previous)` returns the applied marker stored for the next run (for
    example the engine PID and level) so unchanged settings are not re-applied every minute.
    `maintain(settings)` rotates and purges; a failure there never blocks the level.
    """
    if os.geteuid() != 0:
        raise RuntimeError('Run as root')
    os.umask(0o027)
    state_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    state_file = state_root / f'{engine}.json'
    with (state_root / f'{engine}.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = json.loads(state_file.read_text()) if state_file.is_file() else {}
        try:
            settings = fetch()
            source = 'api'
        except Exception as error:  # noqa: BLE001 - keep the last applied settings in force
            settings = state.get('settings') or dict(DEFAULTS, managed=True, logDebugUntil=None)
            source = 'cached:' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__)
        result = {'engine': engine, 'source': source, 'level': None, 'maintenance': None, 'error': None}
        if settings.get('managed', True):
            try:
                marker = apply(settings, state.get('applied'))
                result['level'] = marker.get('level') if isinstance(marker, dict) else None
                state['applied'] = marker
            except Exception as error:  # noqa: BLE001 - housekeeping still runs; retried next minute
                result['error'] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
                state['applied'] = None
        try:
            result['maintenance'] = maintain(settings)
        except OSError as error:
            result['maintenance'] = 'failed:' + type(error).__name__
        state['settings'] = settings
        state['updatedAt'] = datetime.now().isoformat(timespec='seconds')
        temporary = state_file.with_name('.' + state_file.name + '.tmp')
        temporary.write_text(json.dumps(state, sort_keys=True))
        os.chmod(temporary, 0o600)
        temporary.replace(state_file)
        return result


def main(engine, fetch, apply, maintain):
    try:
        result = run(engine, fetch, apply, maintain)
        print(json.dumps(result, sort_keys=True))
        if result['error']:
            raise SystemExit(1)
    except BlockingIOError:
        print(f'[{engine}-logs] another refresh is running')
    except Exception as error:  # noqa: BLE001 - never print tokens or response bodies
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f'[{engine}-logs] ERROR: {detail}', file=sys.stderr)
        raise SystemExit(1)
