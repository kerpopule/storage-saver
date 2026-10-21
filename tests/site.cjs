/* Exercise the exact Worker without any listener or live private data. */
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const path=require('node:path');const dir=path.resolve(__dirname,'../.local/public-release-0.3.1');
let callback;const context={Request,Response,URL,Uint8Array,atob,addEventListener:(name,fn)=>{assert.equal(name,'fetch');callback=fn;}};
vm.runInNewContext(fs.readFileSync(path.join(dir,'worker.js'),'utf8'),context);
async function read(route,options={}){let result;callback({request:new Request('https://storagesaver.app'+route,options),respondWith:p=>result=p});return result;}
(async()=>{
 const checks=[];
 for(const route of ['/','/style.css','/release.json','/licenses']){const r=await read(route);assert.equal(r.status,200);assert.ok((await r.text()).length>10);checks.push(route);}
 const feed=await read('/updates/stable.xml');assert.equal(feed.status,200);assert.match(feed.headers.get('content-type'),/application\/xml/);assert.match(feed.headers.get('cache-control'),/max-age=60, no-transform/);assert.equal(await feed.text(),fs.readFileSync(path.join(dir,'stable.xml'),'utf8'));checks.push('signed stable feed served unchanged with short cache');
 const a=await read('/downloads/StorageSaver-0.3.1-macOS-arm64.zip');const bytes=Buffer.from(await a.arrayBuffer());const rel=JSON.parse(fs.readFileSync(path.join(dir,'release.json')));assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),rel.sha256);assert.equal(bytes.length,rel.bytes);checks.push('download matches notarized release');
 const h=await read('/downloads/StorageSaver-0.3.1-macOS-arm64.zip',{method:'HEAD'});assert.equal((await h.arrayBuffer()).byteLength,0);assert.equal(h.headers.get('content-length'),String(bytes.length));checks.push('HEAD');
 for(const route of ['/api/status','/api/browse','/.env','/not-found'])assert.equal((await read(route)).status,404);checks.push('private endpoints absent');
 for(const host of ['storagesaver.app','www.storagesaver.app']){let result;callback({request:new Request('https://'+host+'/'),respondWith:p=>result=p});const r=await result;assert.equal(r.status,200);assert.equal(r.headers.get('location'),null);assert.match(r.headers.get('cache-control'),/no-transform/);}checks.push('both hosts serve directly without redirect');
 const alias=await read('/download/StorageSaver-0.3.1-macOS-arm64.zip');assert.equal(alias.status,200);assert.equal(crypto.createHash('sha256').update(Buffer.from(await alias.arrayBuffer())).digest('hex'),rel.sha256);checks.push('chat download alias matches signed archive');
 assert.equal((await read('/',{method:'POST',body:'no'})).status,405);checks.push('writes refused');
 console.log(JSON.stringify({passed:true,checks},null,2));
})().catch(e=>{console.error(e);process.exitCode=1});
