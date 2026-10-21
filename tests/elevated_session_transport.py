"""Actual privileged helper rejects wrong peer PID and oversized frames."""
import base64,json,os,pathlib,socket,struct,subprocess,tempfile,time
R=pathlib.Path(__file__).resolve().parents[1]
exe=R/'target/macos/StorageSaver.app/Contents/MacOS/StorageSaver'
d=pathlib.Path(tempfile.mkdtemp(prefix='ss-neg-'));os.chmod(d,0o700)
root=d/'scope';root.mkdir();s=root.stat()
base=dict(uid=os.getuid(),parent=os.getpid(),roots=[str(root)],identities={str(root):[s.st_dev,s.st_ino]},edit=False,expires=time.time()+30)
checks=[]
for case in ['wrong_parent','oversized_frame']:
    path=d/case
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(path));listener.listen(1);listener.settimeout(5)
        payload=dict(base,socket=str(path))
        if case=='wrong_parent':payload['parent']=os.getppid()
        encoded=base64.b64encode(json.dumps(payload).encode()).decode()
        p=subprocess.Popen(['sudo','-n',str(exe),'--privileged-session',encoded],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
        try:
            conn,_=listener.accept()
            with conn:
                conn.settimeout(5)
                if case=='oversized_frame':
                    header=conn.recv(4);assert len(header)==4
                    size=struct.unpack('!I',header)[0];data=b''
                    while len(data)<size:data+=conn.recv(size-len(data))
                    assert json.loads(data)['ok']
                    conn.sendall(struct.pack('!I',131073))
                    # Keep the peer open so POLLHUP cannot mask frame validation.
                    _,error=p.communicate(timeout=5)
                else:assert conn.recv(4)==b'', 'Wrong parent was accepted'
            if case=='wrong_parent':
                _,error=p.communicate(timeout=5)
                assert p.returncode!=0 and 'identity rejected' in error,error
            else:
                assert p.returncode == 1 and 'Invalid session frame size' in error, (p.returncode,error)
                assert not any(root.iterdir()), 'Malformed request changed the synthetic scope'
            checks.append(case)
        finally:
            if p.poll() is None:p.terminate();p.wait(timeout=5)
print(json.dumps(dict(passed=True,checks=checks,synthetic_only=True)))
