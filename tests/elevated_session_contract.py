"""Regression: authorization belongs to grant creation, never individual requests."""
from pathlib import Path
r = Path(__file__).resolve().parents[1]
s = (r / 'native/main.swift').read_text()
request_route = s[s.index('func serveClient('):s.index('func agentClientProof(')]
assert 'NSAlert()' not in request_route, 'BUG: every elevated request opens another native approval'
assert 'with administrator privileges' not in request_route, 'BUG: every action relaunches administrator authentication'
assert '--privileged-session' in s, 'Missing bounded session helper entrypoint'
assert 'startElevatedSession' in s[s.index('func grant('):s.index('func manage(')], 'Authenticate once when granting access'
print('PASS: no per-request prompt or authentication launch; session established at grant creation')
