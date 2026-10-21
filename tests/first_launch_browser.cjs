/* Reproduce first launch with no database, then retry to a real completed map. */
'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process'),assert=require('node:assert/strict');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');const R=path.resolve(__dirname,'..'),D=path.join(R,'.local','fresh-browser-'+Date.now()),root=path.join(D,'files'),data=path.join(D,'Library','Application Support','StorageAtlas');fs.mkdirSync(root,{recursive:true});fs.mkdirSync(data,{recursive:true});fs.writeFileSync(path.join(root,'new-mac.txt'),'Synthetic clean installation');
const bin=process.env.STORAGE_ATLAS_BIN||path.join(R,'target/release/storage-atlas'),url='http://127.0.0.1:43130';let holder,server,browser;
(async()=>{try{
 holder=cp.spawn('/usr/bin/python3',['-u','-c','import fcntl,sys; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); print("ready",flush=True); sys.stdin.read()',path.join(data,'scan.lock')],{stdio:['pipe','pipe','inherit']});await new Promise((resolve,reject)=>{holder.stdout.once('data',resolve);holder.once('error',reject)});
 server=cp.spawn(bin,['--root',root,'--data',data,'serve','--port','43130'],{stdio:['ignore',fs.openSync(path.join(D,'engine.log'),'w'),'ignore']});let status;
 for(let i=0;i<100;i++){try{let r=await fetch(url+'/api/status');if(r.ok){status=await r.json();if(status.progress.state==='error')break}}catch{}await new Promise(r=>setTimeout(r,100));}
 assert.equal(status.index_ready,false);assert.equal(status.scan,null);assert.equal(status.progress.state,'error');assert.ok(!fs.existsSync(path.join(data,'index.sqlite')));
 browser=await chromium.launch({headless:true});const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(url);await page.getByRole('heading',{name:'Welcome to Storage Saver'}).waitFor();assert.ok(!/unable to open database|Run storage-atlas scan first/.test(await page.locator('body').innerText()));
 await page.screenshot({path:path.join(D,'fresh.png')});holder.stdin.end();await new Promise(r=>holder.once('exit',r));holder=null;
 await page.getByRole('button',{name:'Retry first scan',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#file-count').textContent==='1'&&document.querySelector('#heading').textContent==='A little room to breathe.',{},{timeout:20000});
 status=await (await fetch(url+'/api/status')).json();assert.equal(status.scan.files,1);assert.equal(status.scan.errors,0);assert.deepEqual(errors,[]);await page.screenshot({path:path.join(D,'complete.png')});
 console.log(JSON.stringify({passed:true,clean_data_directory:true,first_status_200:true,no_database_error_ui:true,retry_from_app:true,real_scan_files:status.scan.files,automatic_map_transition:true,evidence:D}));
 }finally{if(browser)await browser.close();if(holder){holder.stdin.end();holder.kill('SIGTERM')}if(server){server.kill('SIGTERM');await new Promise(r=>server.once('exit',r))}}})().catch(e=>{console.error(e);process.exitCode=1});
