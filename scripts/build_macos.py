#!/usr/bin/env python3
"""Build a self-contained macOS application with a pinned Sparkle updater."""
import argparse,pathlib,plistlib,re,shutil,subprocess,hashlib,urllib.request,json
from make_icon import make_icon
R=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--engine',type=pathlib.Path,default=R/'target/release/storage-atlas')
p.add_argument('--out',type=pathlib.Path,default=R/'target/macos/StorageSaver.app')
channel=json.loads((R/'updates/stable.json').read_text())
p.add_argument('--version',default=channel['version']);p.add_argument('--build-number',default=channel['build']);a=p.parse_args()
assert re.fullmatch(r'\d+\.\d+\.\d+',a.version) and a.build_number.isdigit()
engine=a.engine.resolve(strict=True);app=a.out.resolve();dest=app/'Contents/MacOS';dest.mkdir(parents=True,exist_ok=True)
vendor=R/'.local/sparkle-2.10.0';archive=vendor/'Sparkle.zip';vendor.mkdir(parents=True,exist_ok=True)
if not archive.exists():
    with urllib.request.urlopen('https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip',timeout=60) as response:archive.write_bytes(response.read())
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959'
if not (vendor/'Sparkle.xcframework').exists():subprocess.run(['ditto','-x','-k',str(archive),str(vendor)],check=True)
framework=app/'Contents/Frameworks/Sparkle.framework'
if not framework.exists():shutil.copytree(vendor/'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework',framework,symlinks=True)
# This product currently ships arm64 only. Thin only our task-owned framework copy.
magic={b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}
for f in framework.rglob('*'):
    if f.is_symlink() or not f.is_file():continue
    with f.open('rb') as source:header=source.read(4)
    if header not in magic:continue
    arch=subprocess.check_output(['lipo','-archs',str(f)],text=True).split()
    if len(arch)>1:subprocess.run(['lipo',str(f),'-thin','arm64','-output',str(f)],check=True)
    subprocess.run(['codesign','--force','--preserve-metadata=entitlements','--sign','-',str(f)],check=True,capture_output=True)
for bundle in sorted([x for x in framework.rglob('*') if not x.is_symlink() and x.suffix in ['.app','.xpc']],key=lambda x:len(x.parts),reverse=True):
    subprocess.run(['codesign','--force','--preserve-metadata=entitlements','--sign','-',str(bundle)],check=True,capture_output=True)
subprocess.run(['codesign','--force','--preserve-metadata=entitlements','--sign','-',str(framework)],check=True,capture_output=True)
subprocess.run(['xcrun','swiftc','-swift-version','5','-O','-F',str(framework.parent),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks','-framework','AppKit','-framework','WebKit','-framework','CryptoKit','native/GrantBroker.swift','native/ElevatedSession.swift','native/SessionTests.swift','native/BrokerTests.swift','native/Updates.swift','native/main.swift','-o',str(dest/'StorageSaver')],cwd=R,check=True)
shutil.copy2(engine,dest/'storage-atlas');(dest/'storage-atlas').chmod(0o700)
icon=make_icon(app/'Contents/Resources')
shutil.copy2(R/'licenses/Sparkle-LICENSE.txt',app/'Contents/Resources/Sparkle-LICENSE.txt')
shutil.copy2(R/'THIRD_PARTY.md',app/'Contents/Resources/THIRD_PARTY.md')
public=(R/'updates/public-ed25519.txt').read_text().strip();assert len(public)==44
info={'CFBundleIdentifier':'org.storage-atlas.app','CFBundleName':'Storage Saver','CFBundleDisplayName':'Storage Saver','CFBundleVersion':a.build_number,'CFBundleShortVersionString':a.version,'CFBundlePackageType':'APPL','CFBundleExecutable':'StorageSaver','CFBundleIconFile':icon,'NSHighResolutionCapable':True,'LSUIElement':False,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},'SUFeedURL':channel['feed'],'SUPublicEDKey':public,'SUEnableAutomaticChecks':True,'SUScheduledCheckInterval':86400,'SUAutomaticallyUpdate':False,'SUEnableSystemProfiling':False,'SUSendProfileInfo':False,'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,'NSAppleMusicUsageDescription':'Only access media-library files when you explicitly select and authorize them in Storage Saver.','NSDocumentsFolderUsageDescription':'Inspect or manage only the folders you explicitly authorize.','NSDesktopFolderUsageDescription':'Inspect or manage only the folders you explicitly authorize.','NSDownloadsFolderUsageDescription':'Inspect or manage only the folders you explicitly authorize.'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--preserve-metadata=entitlements','--sign','-','--identifier','org.storage-atlas.app',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print(app)
