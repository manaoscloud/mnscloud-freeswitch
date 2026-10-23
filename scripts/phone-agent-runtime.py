#!/usr/bin/env python3
"""Local ESL event bridge and control-plane-managed contact-center members.

Only managed agent-* members are changed. Credentials are read on the host and never logged.
The API owns identity, tenant/queue authorization, pause policy and after-call work.
"""
import xml.etree.ElementTree as ET
import csv
import io
import json
from pathlib import Path
import re
import socket
import signal
import time
import threading
import urllib.error
import urllib.request

UUID = re.compile(r'^[0-9a-fA-F-]{32,36}$')
STATE_LOCK = threading.RLock()
SOCKET_LOCK = threading.RLock()
BLOCKED = set()
SHUTDOWN = threading.Event()
LAST_SYNC_AT = 0.0
STATE = Path('/var/lib/mnscloud-freeswitch-phone-agent/state.json')


def save_state(known, pending):
    with STATE_LOCK:
        STATE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = STATE.with_suffix('.tmp')
        # The path is fixed; engine/API data is serialized only as file contents.
        with temporary.open('w', encoding='utf-8') as stream:
            temporary.chmod(0o600)
            json.dump({'known': known, 'pending': pending, 'syncedAt': LAST_SYNC_AT}, stream)
        temporary.replace(STATE)

def load_state():
    try:
        data = json.loads(STATE.read_text())
        return data['known'], data['pending']
    except FileNotFoundError:
        return {}, []


SAFE = re.compile(r'^[a-zA-Z0-9_./@:-]+$')


def api(body=None):
    root = Path('/etc/mnscloud/pabx')
    base = (root / 'api.base').read_text().strip().rstrip('/')
    if not base.startswith('https://'):
        raise ValueError('HTTPS control plane required')
    url = base + ('' if base.endswith('/api/v1') else '/api/v1') + '/pabx/runtime/agents'
    headers = {'Authorization': 'Bearer ' + (root / 'runtime.token').read_text().strip(),
               'X-PABX-Node-UUID': (root / 'node.uuid').read_text().strip()}
    data = None if body is None else json.dumps(body).encode()
    if data is not None:
        headers['Content-Type'] = 'application/json'
    # Never follow a redirect with the node credential.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    with urllib.request.build_opener(NoRedirect).open(urllib.request.Request(url, data=data, headers=headers), timeout=10) as response:
        return json.load(response)['data']['items']


def fields(raw):
    pairs = (line.split(': ', 1) for line in raw.replace('\r', '').split('\n') if ': ' in line)
    return {key: value for key, value in pairs}


def event_payload(event):
    kind = {'bridge-agent-start': 'connected', 'bridge-agent-end': 'ended'}.get(event.get('CC-Action'))
    agent = event.get('CC-Agent', '').removeprefix('agent-')
    queue = event.get('CC-Queue', '').removeprefix('mnscloud-')
    call = event.get('CC-Member-Session-UUID') or event.get('CC-Member-UUID')
    if kind and UUID.fullmatch(agent) and UUID.fullmatch(queue) and call:
        return {'agentUUID': agent, 'queueUUID': queue, 'callKey': call, 'kind': kind}
    return None


def command(sock, text):
    if '\n' in text or '\r' in text:
        raise ValueError('Invalid ESL command')
    with SOCKET_LOCK:
        sock.sendall((text + '\n\n').encode())


def desired(sock, rows, known):
    current = {}
    for row in rows:
        if row.get('agentUUID') in BLOCKED:
            row = {**row, 'state': 'PAUSED'}
        name, queue, contact = row['agentName'], row['queueName'], row['contact']
        if not contact or not all(SAFE.fullmatch(v) for v in (name, queue)) or not name.startswith('agent-') or re.search(r'\s', contact):
            continue
        key = queue + '|' + name
        if row['state'] == 'LOGGED_OUT':
            command(sock, f'api callcenter_config agent set status {name} Logged Out')
            continue
        current[key] = row
        command(sock, f'api callcenter_config agent add {name} callback')
        command(sock, f'api callcenter_config agent set contact {name} {contact}')
        command(sock, f'api callcenter_config tier add {queue} {name} {int(row["penalty"])+1} 1')
        status = 'Available' if row['state'] == 'AVAILABLE' else 'On Break'
        command(sock, f'api callcenter_config agent set status {name} {status}')
    for key, row in known.items():
        if key not in current:
            command(sock, f'api callcenter_config agent set status {row["agentName"]} Logged Out')
            command(sock, f'api callcenter_config tier del {row["queueName"]} {row["agentName"]}')
    return current


def queue_counters(text, queues, now):
    result = {queue: {'waiting': 0, 'longestWait': 0} for queue in queues}
    for row in csv.DictReader(io.StringIO(text), delimiter='|'):
        queue = row.get('queue')
        if queue in result and row.get('state') in ('Waiting', 'Trying'):
            result[queue]['waiting'] += 1
            wait = max(0, now - int(row.get('joined_epoch', now)))
            result[queue]['longestWait'] = max(result[queue]['longestWait'], min(wait, 604800))
    return result


def observe_queues(params, queues):
    # A separate local ESL connection keeps command replies away from the event stream.
    host = params.get('listen-ip', '127.0.0.1')
    if host in ('::', '0.0.0.0'):
        host = '127.0.0.1'
    with socket.create_connection((host, int(params.get('listen-port', 8021))), timeout=5) as sock:
        stream = sock.makefile('rb')
        def frame():
            header = b''
            while not header.endswith(b'\n\n'):
                line = stream.readline(65536)
                if not line or len(header) + len(line) > 1048576:
                    raise ConnectionError('ESL frame unavailable')
                header += line
            meta = fields(header.decode())
            length = int(meta.get('Content-Length', 0))
            if length > 1048576:
                raise ValueError('ESL reply too large')
            return meta, stream.read(length).decode()
        frame()
        command(sock, 'auth ' + params['password'])
        meta, _ = frame()
        if not meta.get('Reply-Text', '').startswith('+OK accepted'):
            raise ConnectionError('ESL authentication refused')
        command(sock, 'api callcenter_config queue list members')
        _, body = frame()
        if body.startswith('-ERR'):
            raise ValueError('Queue observation unavailable')
        return queue_counters(body, queues, int(time.time()))


class Bridge:
    def __init__(self, sock, params=None):
        self.sock = sock
        self.params = params
        self.known, self.pending = load_state()
        BLOCKED.clear()
        BLOCKED.update(event['agentUUID'] for event in self.pending)
        self.ready = False
        self.ready_by = time.monotonic() + 15
        self.stopped = threading.Event()
        self.wakeup = threading.Event()
        self.buffer = b''
        self.metrics = {}
        self.snapshot = {}

    def active(self):
        return not self.stopped.is_set() and not SHUTDOWN.is_set()

    def replay(self):
        while self.pending and self.active():
            try:
                api(self.pending[0])
            except urllib.error.HTTPError as error:
                # Deleted memberships and superseded stations cannot be replayed.
                if error.code != 409:
                    raise
            with SOCKET_LOCK:
                self.pending.pop(0)
                save_state(self.known, self.pending)

    def report_counters(self, counters):
        for queue, values in counters.items():
            if not self.active():
                return
            api({'kind': 'queue', 'queueUUID': queue.removeprefix('mnscloud-'), **values})

    def sync_once(self):
        global LAST_SYNC_AT
        self.replay()
        if not self.active():
            return
        rows = api()
        with SOCKET_LOCK:
            BLOCKED.intersection_update(event['agentUUID'] for event in self.pending)
            self.known = desired(self.sock, rows, self.known)
        self.observe(rows)
        LAST_SYNC_AT = time.time()
        with SOCKET_LOCK:
            save_state(self.known, self.pending)

    def synchronize(self):
        try:
            while self.active():
                if not self.ready:
                    self.wakeup.wait(0.2)
                    continue
                try:
                    self.sync_once()
                except (OSError, ValueError, KeyError):
                    self.pause_all()
                self.wakeup.wait(5)
                self.wakeup.clear()
        finally:
            self.stopped.set()

    def record_event(self, event):
        if not event:
            return
        with SOCKET_LOCK:
            BLOCKED.add(event['agentUUID'])
            self.pause_agent(event['agentUUID'])
            self.pending.append(event)
            save_state(self.known, self.pending)
            self.wakeup.set()
            if len(self.pending) > 1000:
                raise ValueError('Event backlog requires recovery')

    def receive(self):
        if not self.ready and time.monotonic() > self.ready_by:
            raise ConnectionError('Event subscription unavailable')
        data = self.sock.recv(65536)
        if not data:
            raise ConnectionError('Event socket closed')
        self.buffer += data
        if len(self.buffer) > 1048576:
            raise ValueError('Event frame too large')
        self.parse_frames()

    def run(self):
        worker = threading.Thread(target=self.synchronize, daemon=True)
        worker.start()
        try:
            while self.active():
                try:
                    self.receive()
                except socket.timeout:
                    pass
        finally:
            self.stopped.set()
            self.wakeup.set()
            worker.join()
            if SHUTDOWN.is_set():
                self.known = desired(self.sock, [], self.known)
                save_state(self.known, self.pending)

    def pause_all(self):
        with SOCKET_LOCK:
            for row in self.known.values():
                command(self.sock, f'api callcenter_config agent set status {row["agentName"]} On Break')

    def pause_agent(self, agent):
        command(self.sock, 'api callcenter_config agent set status agent-' + agent + ' On Break')

    def observe(self, rows):
        queues = {row['queueName'] for row in rows if SAFE.fullmatch(row['queueName'])}
        try:
            self.report_counters(observe_queues(self.params, queues))
        except (OSError, ValueError, KeyError):
            pass  # Counter expiry is visible; it never changes routing presence.

    def handle_frame(self, meta, payload):
        reply = meta.get('Reply-Text', '')
        if reply.startswith('-ERR'):
            raise ConnectionError('ESL authentication or subscription refused')
        if reply.startswith('+OK accepted'):
            self.ready = True
        if meta.get('Content-Type') == 'text/event-json':
            self.record_event(event_payload(json.loads(payload)))

    def parse_frames(self):
        while b'\n\n' in self.buffer:
            header, rest = self.buffer.split(b'\n\n', 1)
            meta = fields(header.decode())
            length = int(meta.get('Content-Length', 0))
            if length < 0 or length > 1048576:
                raise ValueError('ESL frame too large')
            if len(rest) < length:
                return
            payload, self.buffer = rest[:length], rest[length:]
            self.handle_frame(meta, payload)


def run():
    params = {node.attrib['name']: node.attrib['value'] for node in ET.parse('/etc/freeswitch/autoload_configs/event_socket.conf.xml').iter('param')}
    host = params.get('listen-ip', '127.0.0.1')
    if host in ('::', '0.0.0.0'):
        host = '127.0.0.1'
    with socket.create_connection((host, int(params.get('listen-port', 8021))), timeout=10) as sock:
        sock.settimeout(1)
        command(sock, 'auth ' + params['password'])
        command(sock, 'event json CUSTOM callcenter::info')
        Bridge(sock, params).run()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: SHUTDOWN.set())
    signal.signal(signal.SIGINT, lambda *_: SHUTDOWN.set())
    while not SHUTDOWN.is_set():
        try:
            run()
        except Exception:
            print('Phone agent bridge disconnected; retrying.', flush=True)
            time.sleep(5)
