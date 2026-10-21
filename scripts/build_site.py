#!/usr/bin/env python3
"""Build the public distribution Worker from an explicit safe-file allowlist."""
import base64,gzip,json,pathlib,re
R=pathlib.Path(__file__).resolve().parents[1];channel=json.loads((R/'updates/stable.json').read_text());D=R/('.local/public-release-'+channel['version'])
release=json.loads((D/'release.json').read_text());assert release['notarized'] and release['gatekeeper_assessed']
zipname='StorageSaver-'+channel['version']+'-macOS-arm64.zip';archive=(D/zipname).read_bytes()
import hashlib
assert hashlib.sha256(archive).hexdigest()==release['sha256']
assets={'/':{'body':re.sub(r'StorageSaver-\d+\.\d+\.\d+-macOS-arm64\.zip',zipname,(R/'site/index.html').read_text()),'type':'text/html; charset=utf-8'},'/style.css':{'body':(R/'site/style.css').read_text(),'type':'text/css; charset=utf-8'},'/release.json':{'body':json.dumps(release,indent=2)+'\n','type':'application/json'},'/updates/stable.xml':{'body':(D/'stable.xml').read_text(),'type':'application/xml; charset=utf-8'},'/licenses':{'body':(R/'LICENSE').read_text()+'\n\n'+(R/'THIRD_PARTY.md').read_text()+'\n\n'+(R/'licenses/Sparkle-LICENSE.txt').read_text(),'type':'text/plain; charset=utf-8'}}
code='const ZIPNAME='+json.dumps(zipname)+';\nconst ASSETS='+json.dumps(assets)+';\nconst ARCHIVE='+json.dumps(base64.b64encode(archive).decode())+';\nconst RELEASE='+json.dumps(release)+';\n'
code+='''
async function handle(request) {
 const u=new URL(request.url);const method=request.method;
 const headers={"X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer","Strict-Transport-Security":"max-age=31536000; includeSubDomains","Content-Security-Policy":"default-src 'none'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'","Cache-Control":"public, max-age=300, no-transform"};
 if(!['GET','HEAD'].includes(method))return new Response('Method not allowed',{status:405,headers:{...headers,Allow:'GET, HEAD'}});
 // Serve both approved hostnames directly; never redirect a working www host into a negatively cached apex.
 // Old shared links redirect to the current release; never silently change versioned archive bytes.
 const requested=u.pathname.match(/^\\/downloads?\\/StorageSaver-(\\d+\\.\\d+\\.\\d+)-macOS-arm64\\.zip$/);
 const previous=requested&&requested[1].split('.').map(Number),current=RELEASE.version.split('.').map(Number);
 const difference=previous?previous.map((v,i)=>v-current[i]).find(v=>v!==0):undefined;
 if(difference<0)return new Response(null,{status:302,headers:{...headers,Location:'/downloads/'+ZIPNAME}});
 if(['/downloads/'+ZIPNAME,'/download/'+ZIPNAME].includes(u.pathname)) {
  Object.assign(headers,{'Content-Type':'application/zip','Content-Disposition':'attachment; filename="'+ZIPNAME+'"','Content-Length':String(RELEASE.bytes),'ETag':'"'+RELEASE.sha256+'"','Cache-Control':'public, max-age=86400, immutable'});
  if(method==='HEAD')return new Response(null,{headers});
  const data=Uint8Array.from(atob(ARCHIVE),c=>c.charCodeAt(0));return new Response(data,{headers});
 }
 const asset=ASSETS[u.pathname];
 if(!asset)return new Response(method==='HEAD'?null:'Not found',{status:404,headers});
 if(u.pathname==='/updates/stable.xml')headers['Cache-Control']='public, max-age=60, no-transform';
 headers['Content-Type']=asset.type;return new Response(method==='HEAD'?null:asset.body,{headers});
}
addEventListener('fetch',event=>event.respondWith(handle(event.request)));
'''
(D/'worker.js').write_text(code)
assert len(gzip.compress(code.encode()))<3*1024*1024,'Exceeds free Worker compressed script limit'
print(json.dumps({'worker_bytes':len(code.encode()),'compressed_bytes':len(gzip.compress(code.encode())),'public_assets':list(assets),'archive_sha256':release['sha256']}))
