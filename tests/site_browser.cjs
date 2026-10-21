"use strict";
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const out=path.resolve(process.env.QA_OUT||'.local/site-qa');fs.mkdirSync(out,{recursive:true});
const expected=process.env.STORAGE_SAVER_RELEASE_SHA256||JSON.parse(fs.readFileSync(path.resolve(__dirname,'../.local/public-release-0.3.1/release.json'))).sha256;assert.match(expected,/^[a-f0-9]{64}$/);
(async()=>{let browser;const checks=[],errors=[],foreign=[];try{
 browser=await chromium.launch({headless:true,args:['--disable-gpu','--disable-dev-shm-usage']});
 const context=await browser.newContext({acceptDownloads:true,viewport:{width:1440,height:1000}});const page=await context.newPage();
 page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(new URL(r.url()).hostname!=='www.storagesaver.app')foreign.push(r.url())});
 const r=await page.goto('https://www.storagesaver.app/',{waitUntil:'networkidle',timeout:45000});assert.equal(r.status(),200);assert.match(await page.title(),/Storage Saver/);checks.push('public HTTPS page');
 const css=await page.locator('html').evaluate(el=>getComputedStyle(el).backgroundColor);assert.equal(css,'rgb(246, 246, 239)');checks.push('actual stylesheet loaded under CSP');
 await page.screenshot({path:path.join(out,'desktop.png'),fullPage:true});
 await page.getByRole('link',{name:'Install',exact:true}).click();assert.equal(await page.evaluate(()=>location.hash),'#install');checks.push('installation navigation');
 await page.getByText('Beta limitations & safety',{exact:true}).click();assert.equal(await page.locator('details').getAttribute('open'),'');checks.push('limitations disclosure');
 const pending=page.waitForEvent('download');await page.getByRole('link',{name:'Get Storage Saver',exact:false}).click();const download=await pending;assert.equal(download.suggestedFilename(),'StorageSaver-0.3.1-macOS-arm64.zip');const file=path.join(out,'download.zip');await download.saveAs(file);assert.equal(crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'),expected);checks.push('visible download control delivers exact notarized bytes');
 for(const width of [320,390,768,1440]){await page.setViewportSize({width,height:900});await page.goto('https://www.storagesaver.app/',{waitUntil:'networkidle'});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'overflow at '+width);if(width===390)await page.screenshot({path:path.join(out,'mobile.png'),fullPage:true});checks.push('no overflow '+width)}
 await page.setViewportSize({width:390,height:900});await page.evaluate(()=>document.documentElement.style.fontSize='200%');assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));checks.push('200 percent text scale');
 await page.keyboard.press('Tab');assert.notEqual(await page.evaluate(()=>document.activeElement.tagName),'BODY');checks.push('keyboard reachability');
 for(const route of ['/api/status','/api/browse','/.env']){const response=await page.goto('https://www.storagesaver.app'+route,{waitUntil:'domcontentloaded'});assert.equal(response.status(),404)}checks.push('private APIs absent publicly');
 const post=require('node:child_process').execFileSync('curl',['-sS','--max-time','15','-o','/dev/null','-w','%{http_code}','-X','POST','https://www.storagesaver.app/'],{encoding:'utf8'});assert.equal(post,'405');checks.push('public writes refused');
 assert.deepEqual(errors,[]);const unexpected=foreign.filter(u=>!u.startsWith('https://static.cloudflareinsights.com/beacon.min.js/'));assert.deepEqual(unexpected,[]);checks.push('no script errors or unexpected external requests');
 await context.close();await browser.close();browser=null;const receipt={passed:true,ordinary_dns_no_override:true,host:'www.storagesaver.app',checks,errors,foreign_requests:foreign,hosting_beacon_observed:foreign.length>0,privacy_followup_required:foreign.length>0,browser_closed:true,download_sha256:expected};fs.writeFileSync(path.join(out,'result.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt,null,2));
 }finally{if(browser)await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
