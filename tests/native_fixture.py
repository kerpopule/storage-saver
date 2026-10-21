#!/usr/bin/env python3
"""Exercise the real native app and CLI broker with disposable selected folders."""
import json,os,pathlib,subprocess,time
R=pathlib.Path(__file__).resolve().parent.parent
D=R/'.local'/('nf-'+str(int(time.time())));root=D/'files';data=D/'state';root.mkdir(parents=True);data.mkdir()
(root/'synthetic.txt').write_text('Native Storage Saver fixture only')
proof=D/'native-proof.json';log=D/'native.log';exe=pathlib.Path(os.environ.get('STORAGE_SAVER_TEST_APP',str(R/'target/macos/StorageSaver.app')))/'Contents/MacOS/StorageSaver'
env=os.environ.copy();env.update(STORAGE_SAVER_DATA=str(data),STORAGE_SAVER_FIXTURE_ROOT=str(root),STORAGE_SAVER_NATIVE_PROOF=str(proof),STORAGE_SAVER_PORT='43129')
with log.open('wb') as out:
 p=subprocess.Popen([str(exe)],env=env,stdout=out,stderr=subprocess.STDOUT)
 try:p.wait(timeout=75)
 finally:
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=8)
   except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)
assert proof.exists(),f'No native proof; inspect {log}'
v=json.loads(proof.read_text());assert v['passed'] and v['agent_broker']['cli_to_unix_socket']
assert pathlib.Path(str(proof)+'.png').exists(),'Native screenshot missing'
assert not (data/'agent.sock').exists(),'Native app did not close its owned broker'
print(json.dumps(v,indent=2));print('Evidence: '+str(D))
