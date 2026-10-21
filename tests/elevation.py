#!/usr/bin/env python3
"""Opt-in real sudo scanner test, using ONLY a newly created synthetic directory."""
import argparse, json, os, pathlib, subprocess, tempfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary',type=pathlib.Path,required=True)
p.add_argument('--sudo',action='store_true',required=True)
a=p.parse_args(); binary=str(a.binary.resolve(strict=True))
subprocess.run(['sudo','-n','true'],check=True)
t=pathlib.Path(tempfile.mkdtemp(prefix='storage-atlas-elevation-'))
root=t/'root';private=root/'protected';private.mkdir(parents=True)
(private/'synthetic-file').write_bytes(b'fixture only, no credentials')
data=t/'index';uid=os.getuid();gid=os.getgid()
def run(elevated,*args):
    return subprocess.run((['sudo','-n'] if elevated else [])+[binary,'--data',str(data),'--root',str(root),*args,'--json'],capture_output=True,text=True,check=False)
try:
    subprocess.run(['sudo','-n','chown','0:0',str(private)],check=True)
    subprocess.run(['sudo','-n','chmod','700',str(private)],check=True)
    normal=run(False,'scan');assert normal.returncode==0,normal.stderr
    baseline=json.loads(normal.stdout);assert baseline['errors']>=1
    elevated=run(True,'scan');assert elevated.returncode==0,elevated.stderr
    proof=json.loads(elevated.stdout);assert proof['privileged'] and proof['errors']==0 and proof['files']==1
    status=run(False,'status');assert status.returncode==0,status.stderr
    for name in ['index.sqlite','history.sqlite','progress.json','scan.lock']:
        assert (data/name).stat().st_uid==uid,(name,'wrong owner')
    root_http=run(True,'serve','--port','43129');assert root_http.returncode!=0 and 'Refusing to run the HTTP dashboard as root' in root_http.stderr
    print(json.dumps({'passed':True,'ordinary_scan_gaps':baseline['errors'],'elevated_scan_gaps':proof['errors'],'unprivileged_reader_verified':True,'generated_files_owned_by_caller':True,'root_http_refused':True,'fixture':str(t)},indent=2))
finally:
    subprocess.run(['sudo','-n','chown',f'{uid}:{gid}',str(private)],check=True)
    # Retain the tiny synthetic receipt/fixture for local inspection; never touch other data.
