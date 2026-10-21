"""Opt-in root helper fixture. No existing user files or OS prompts."""
import argparse,base64,json,os,pathlib,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--sudo',action='store_true');a=p.parse_args()
if not a.sudo:raise SystemExit('Use --sudo only for authorized disposable fixture testing')
R=pathlib.Path(__file__).resolve().parent.parent
D=R/'.local'/('root-helper-'+str(time.time_ns()));D.mkdir()
f=D/'private-fixture';seed=D/'seed';seed.write_text('synthetic root-only fixture')
subprocess.run(['sudo','-n','/usr/bin/install','-m','600',str(seed),str(f)],check=True)
try:f.read_bytes();raise AssertionError('Ordinary read unexpectedly permitted')
except PermissionError:pass
s=D.stat();exe=R/'target/macos/StorageSaver.app/Contents/MacOS/StorageSaver'
def call(action,edit=False,**fields):
 q=dict(action=action,path=str(f),roots=[str(D)],identities={str(D):[s.st_dev,s.st_ino]},expires=time.time()+1800,edit=edit,**fields)
 encoded=base64.b64encode(json.dumps(q).encode()).decode()
 r=subprocess.run(['sudo','-n',str(exe),'--privileged-op',encoded],capture_output=True,text=True,timeout=55)
 return json.loads(r.stdout)
r=call('read');assert r['ok'] and base64.b64decode(r['data_base64'])==seed.read_bytes()
assert not call('write_new',text='denied')['ok']
r=call('copy',edit=True,destination=str(D/'copied'));assert r['ok'] and r['verified']
assert not call('delete',edit=True)['ok']
proof=dict(passed=True,ordinary_denied=True,elevated_read=True,view_edit_denied=True,copy_verified=True,delete_denied=True,native_auth_prompt_tested=False,disposable_fixture=True)
(D/'proof.json').write_text(json.dumps(proof,indent=2));print(json.dumps(proof))
