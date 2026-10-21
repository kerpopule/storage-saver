#!/usr/bin/env python3
"""Install this new, private per-user app. Refuse unrelated existing targets."""
import argparse
import json
import os
import pathlib
import plistlib
import shlex
import shutil
import subprocess
import sys
from make_icon import make_icon

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=pathlib.Path, required=True)
p.add_argument('--native-binary', type=pathlib.Path, default=pathlib.Path('target/macos/StorageSaver.app/Contents/MacOS/StorageSaver'), help='Native desktop executable from build_macos.py')
p.add_argument('--interval', type=int, default=21600)
p.add_argument('--elevated-scan', action='store_true', help='Use existing non-interactive sudo for scan-only children. Never changes sudoers.')
p.add_argument('--no-start', action='store_true', help='Install without loading the new user service.')
a = p.parse_args()
if sys.platform != 'darwin':
    sys.exit('macOS only. On Linux, run storage-atlas serve under your own user service.')
if a.interval < 60:
    sys.exit('Refresh interval must be at least 60 seconds.')
if a.elevated_scan:
    subprocess.run(['/usr/bin/sudo', '-n', '/usr/bin/true'], check=True)
binary = a.binary.resolve(strict=True)
native_binary = a.native_binary.resolve(strict=True)
home = pathlib.Path.home()
label = 'org.storage-atlas.local'
data = home / 'Library/Application Support/StorageAtlas'
cli = home / 'bin/storage-saver'
legacy_cli = home / 'bin/storage-atlas'
app = home / 'Applications/Storage Saver.app'
dest = app / 'Contents/MacOS/storage-atlas'
plist = home / 'Library/LaunchAgents' / f'{label}.plist'
for target in [cli, legacy_cli, app, plist]:
    if target.exists() or target.is_symlink():
        sys.exit(f'Refusing existing target: {target}. Inspect it before reinstalling.')
for d in [data, cli.parent, dest.parent, plist.parent]:
    d.mkdir(parents=True, exist_ok=True)
os.chmod(data, 0o700)
shutil.copy2(binary, dest)
shutil.copy2(native_binary, dest.parent / 'StorageSaver')
(dest.parent / 'StorageSaver').chmod(0o700)
dest.chmod(0o700)
icon = make_icon(app / 'Contents/Resources')
info = {'CFBundleIdentifier': 'org.storage-atlas.app', 'CFBundleName': 'Storage Saver', 'CFBundleDisplayName': 'Storage Saver', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1.0', 'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'StorageSaver', 'CFBundleIconFile': icon, 'LSUIElement': False, 'NSHighResolutionCapable': True, 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}
template = native_binary.parent.parent / 'Info.plist'
if template.exists():
    info = plistlib.loads(template.read_bytes())
    info['CFBundleIconFile'] = icon
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
# Ad-hoc local identity only. Not Developer ID signing or notarization.
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'org.storage-atlas.app', str(app)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
cli.write_text('#!/bin/sh\nexec ' + shlex.quote(str(dest)) + ' --data ' + shlex.quote(str(data)) + ' "$@"\n')
cli.chmod(0o700)
legacy_cli.symlink_to(cli.name)
args = [str(dest), '--data', str(data), 'serve', '--interval', str(a.interval)]
if a.elevated_scan:
    args.append('--elevated-scan')
config = {'Label': label, 'ProgramArguments': args, 'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 60, 'Nice': 10, 'LowPriorityIO': True, 'ProcessType': 'Background', 'StandardOutPath': str(data / 'service.log'), 'StandardErrorPath': str(data / 'service-error.log')}
plist.write_bytes(plistlib.dumps(config))
plist.chmod(0o600)
receipt = {'app': str(app), 'cli': str(cli), 'legacy_cli': str(legacy_cli), 'binary': str(dest), 'data': str(data), 'label': label, 'url': 'http://127.0.0.1:43127', 'interval_seconds': a.interval, 'elevated_scan': a.elevated_scan, 'signature': 'ad-hoc, not notarized', 'full_disk_access': 'requires a separate macOS System Settings grant to this exact app', 'started': False, 'start_command': f'launchctl bootstrap gui/{os.getuid()} {shlex.quote(str(plist))}', 'stop_command': f'launchctl bootout gui/{os.getuid()}/{label}'}
(data / 'installation.json').write_text(json.dumps(receipt, indent=2) + '\n')
if not a.no_start:
    subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(plist)], check=True)
    receipt['started'] = True
    (data / 'installation.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
