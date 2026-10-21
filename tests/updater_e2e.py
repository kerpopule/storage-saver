#!/usr/bin/env python3
"""Exercise real Sparkle against disposable apps. Run under hermes-resource.
Never link the automatic-confirmation driver into the shipped product.
"""
import argparse,hashlib,http.server,json,pathlib,plistlib,shutil,subprocess,threading,time,uuid
R=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--pre-signing',action='store_true');p.add_argument('--public',action='store_true');args=p.parse_args()
D=R/('.local/updater-e2e-'+uuid.uuid4().hex[:12]);D.mkdir(parents=True)
BASE=R/'.local/public-release-0.2.99/Storage Saver.app';NEW=R/'.local/public-release-0.3.1'
H=D/'Harness.app';M=H/'Contents/MacOS';M.mkdir(parents=True)
framework=H/'Contents/Frameworks/Sparkle.framework';shutil.copytree(NEW/'Storage Saver.app/Contents/Frameworks/Sparkle.framework',framework,symlinks=True)
(H/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.storage-atlas.updater.fixture.'+D.name.split('-')[-1],'CFBundleName':'Storage Saver disposable updater QA','CFBundleExecutable':'Harness','CFBundlePackageType':'APPL','CFBundleVersion':'1','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}))
subprocess.run(['xcrun','swiftc','-swift-version','5','-F',str(framework.parent),'-framework','Sparkle','-framework','AppKit','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',str(R/'tests/UpdateHarness.swift'),'-o',str(M/'Harness')],check=True)
identity='Developer ID Application: Stephen Darlow (2D4KQ5RBVQ)'
for path in [M/'Harness',H]:subprocess.run(['codesign','--force','--options','runtime','--timestamp','--sign',identity,str(path)],check=True,capture_output=True)
# A synthetic local catalog and ordinary settings sit outside the app bundle.
state=D/'Application Support/StorageAtlas';state.mkdir(parents=True)
(state/'index.sqlite').write_bytes(b'disposable synthetic inventory identity\x00')
(state/'settings.json').write_text('{"scope":"synthetic fixture only"}\n')
original={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in state.iterdir()}
requests=[];payloads={}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path);body=payloads.get(self.path)
        self.send_response(200 if body is not None else 404);self.send_header('Content-Type','application/xml' if self.path.endswith('.xml') else 'application/zip');self.end_headers()
        if body is not None:self.wfile.write(body)
    def log_message(self,*unused):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();origin='http://127.0.0.1:'+str(server.server_port)
results=[]
def exercise(name,feed,success=False,current=False):
    folder=D/name;folder.mkdir();app=folder/'Storage Saver.app';shutil.copytree(NEW/'Storage Saver.app' if current else BASE,app,symlinks=True)
    before=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleVersion']
    output=folder/'result.json'
    with (folder/'driver.log').open('w') as log:subprocess.run([str(M/'Harness'),str(app),str(output),feed],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=200)
    result=json.loads(output.read_text());assert result['passed']==success,result
    after=plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleVersion']
    assert after==(plistlib.loads((NEW/'Storage Saver.app/Contents/Info.plist').read_bytes())['CFBundleVersion'] if success else before),(name,before,after)
    assert original=={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in state.iterdir()}
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
    result.update({'case':name,'before_build':before,'after_build':after,'state_preserved':True});results.append(result)
    (D/'proof.json').write_text(json.dumps(results,indent=2)+'\n')
try:
    # No signing key is needed to demonstrate feed validation and offline safety.
    unsigned=b'<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Unsigned QA feed</title><item><title>Untrusted</title><sparkle:version>999</sparkle:version><enclosure url="'+(origin+'/must-not-download.zip').encode()+b'" length="4" type="application/octet-stream" sparkle:edSignature="AAAA" /></item></channel></rss>'
    payloads['/unsigned.xml']=unsigned
    exercise('unsigned-feed',origin+'/unsigned.xml')
    assert '/must-not-download.zip' not in requests
    exercise('offline-feed','http://127.0.0.1:1/offline.xml')
    if not args.pre_signing:
        release=json.loads((NEW/'release.json').read_text());feed=(NEW/'stable.xml').read_bytes()
        signedLocal=D/'local-stable.xml'
        signedLocal.write_text(feed.decode().replace('https://www.storagesaver.app/downloads/StorageSaver-0.3.1-macOS-arm64.zip',origin+'/release.zip'))
        subprocess.run([str(R/'.local/sparkle-2.10.0/bin/sign_update'),'--account','org.storage-atlas.app.updates',str(signedLocal)],check=True,capture_output=True,timeout=90)
        payloads['/stable.xml']=signedLocal.read_bytes();payloads['/release.zip']=(NEW/'StorageSaver-0.3.1-macOS-arm64.zip').read_bytes()
        updateFeed='https://www.storagesaver.app/updates/stable.xml' if args.public else origin+'/stable.xml'
        exercise('public-update' if args.public else 'signed-local-update',updateFeed,success=True)
        exercise('already-current',updateFeed,current=True)
        # Re-sign a deliberately bad payload URL, while preserving the authentic archive signature.
        local=feed.decode().replace('https://www.storagesaver.app/downloads/StorageSaver-0.3.1-macOS-arm64.zip',origin+'/corrupt.zip')
        bad=D/'bad-payload.xml';bad.write_text(local)
        subprocess.run([str(R/'.local/sparkle-2.10.0/bin/sign_update'),'--account','org.storage-atlas.app.updates',str(bad)],check=True,capture_output=True,timeout=90)
        payloads['/bad-payload.xml']=bad.read_bytes()
        corrupt=bytearray((NEW/'StorageSaver-0.3.1-macOS-arm64.zip').read_bytes());corrupt[1024]^=1;payloads['/corrupt.zip']=bytes(corrupt)
        exercise('bad-payload',origin+'/bad-payload.xml')
        assert '/corrupt.zip' in requests
    print(json.dumps({'passed':True,'cases':len(results),'proof':str(D/'proof.json'),'mode':'pre-signing' if args.pre_signing else 'full'}))
finally:
    server.shutdown();server.server_close();thread.join(timeout=5)
