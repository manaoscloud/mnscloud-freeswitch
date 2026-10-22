#!/usr/bin/env python3
"""Validate event identity, routing fail-closed states and durable replay without a PBX."""
import importlib.util
from pathlib import Path
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bridge', root / 'scripts/phone-agent-runtime.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
class Socket:
    def __init__(self): self.data = b''
    def sendall(self, value): self.data += value
agent = '00000000-0000-4000-8000-000000000001'
queue = '00000000-0000-4000-8000-000000000002'
row = {'agentUUID': agent, 'agentName': 'agent-'+agent, 'queueName': 'mnscloud-'+queue,
       'interface': 'PJSIP/test', 'contact': 'user/100@example.invalid', 'penalty': 0, 'state': 'AVAILABLE'}
sock = Socket()
known = b.desired(sock, [row], {})
assert len(known) == 1
row = {**row, 'state': 'PAUSED'}
sock = Socket()
b.desired(sock, [row], known)
assert b'On Break' in sock.data or b'Paused: true' in sock.data
sock = Socket()
assert not b.desired(sock, [], known)
assert b'tier del' in sock.data or b'QueueRemove' in sock.data
row = {**row, 'state': 'LOGGED_OUT'}
assert not b.desired(Socket(), [row], {})
assert b.event_payload({}) is None
if hasattr(b, 'action'):
    event = {'Event': 'AgentConnect', 'MemberName': 'agent-'+agent, 'Queue': 'mnscloud-'+queue, 'DestUniqueid': '123.1'}
else:
    event = {'CC-Action': 'bridge-agent-start', 'CC-Agent': 'agent-'+agent, 'CC-Queue': 'mnscloud-'+queue, 'CC-Member-Session-UUID': '123.1'}
payload = b.event_payload(event)
assert payload == {'agentUUID': agent, 'queueUUID': queue, 'callKey': '123.1', 'kind': 'connected'}
with tempfile.TemporaryDirectory() as tmp:
    b.STATE = Path(tmp) / 'state.json'
    b.save_state(known, [payload])
    assert b.load_state() == (known, [payload])
    assert b.STATE.stat().st_mode & 0o777 == 0o600
print('Phone agent event bridge: OK')

assert b.queue_counters('queue|state|joined_epoch\nmnscloud-test|Waiting|90\nmnscloud-test|Answered|10\n', {'mnscloud-test'}, 100) == {'mnscloud-test': {'waiting': 1, 'longestWait': 10}}

# A local contact event fences a stale AVAILABLE response until the event is acknowledged.
b.BLOCKED.add(agent)
sock = Socket()
b.desired(sock, [{**row, 'state': 'AVAILABLE'}], {})
assert b'Paused: false' not in sock.data and b' Available' not in sock.data
assert b'Paused: true' in sock.data or b'On Break' in sock.data
b.BLOCKED.clear()

# A contact arriving during the desired-state request fences its stale AVAILABLE result.
with tempfile.TemporaryDirectory() as tmp:
    b.STATE = Path(tmp) / 'state.json'
    sock = Socket()
    bridge = b.Bridge(sock)
    bridge.observe = lambda rows: None
    original_api = b.api
    delivered = []
    def fake_api(body=None):
        if body is not None:
            delivered.append(body)
            return []
        if not delivered:
            bridge.record_event(payload)
        return [{**row, 'state': 'AVAILABLE' if not delivered else 'ON_CALL'}]
    b.api = fake_api
    try:
        bridge.sync_once()
        assert bridge.pending == [payload]
        assert b'Paused: false' not in sock.data and b' Available' not in sock.data
        bridge.sync_once()
        assert delivered == [payload] and not bridge.pending
        assert b.load_state()[1] == []
        assert agent not in b.BLOCKED
    finally:
        b.api = original_api
print('Concurrent contact fencing and acknowledgement: OK')
