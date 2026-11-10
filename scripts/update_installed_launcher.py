#!/usr/bin/env python3
"""Build a launcher-only update for an existing full NNG Mac installation.

Preserves the installed helper, bridge, Wine, renderer and game data. --apply
requires the launcher GUI to be closed; a game worker may remain alive.
"""
from pathlib import Path
import argparse,hashlib,json,os,plistlib,shutil,subprocess,datetime
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--app',type=Path,default=Path('/Applications/NNG Mac.app'));p.add_argument('--xml-probe-exe',type=Path);p.add_argument('--apply',action='store_true');args=p.parse_args()
app=args.app.resolve();candidate=ROOT/'build/NNG Mac Updated.app';source=ROOT/'build/legacy-sources/main.swift'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
helper='Contents/Helpers/NNG Trackpad.app/Contents/MacOS/nng-trackpad'
bridge='Contents/Helpers/NNG Trackpad.app/Contents/Resources/input-bridge/nng-input.exe'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
original={name:sha(app/name) for name in [helper,bridge,'Contents/Resources/acceleration/runtime.json']}
if not args.apply:
 if candidate.exists():shutil.rmtree(candidate)
 subprocess.run(['/bin/cp','-cR',str(app),str(candidate)],check=True)
 source.parent.mkdir(parents=True,exist_ok=True);source.write_bytes((ROOT/'Sources/LegacyLauncher.swift').read_bytes())
 target=candidate/'Contents/MacOS/nng';target.unlink()
 subprocess.run(['xcrun','swiftc','-O','-target','arm64-apple-macos15.0','-file-prefix-map',str(ROOT)+'=.','-debug-prefix-map',str(ROOT)+'=.',str(source),str(ROOT/'Sources/UpdateCheck.swift'),str(ROOT/'Sources/LauncherUpdate.swift'),str(ROOT/'Sources/XMLRuntime.swift'),'-o',str(target)],check=True)
 for name in ['LegacyLauncher.swift','UpdateCheck.swift','LauncherUpdate.swift','XMLRuntime.swift','MSXMLProbe.go']:
  destination=candidate/'Contents/Resources/Sources'/('NNGLauncher.swift' if name.startswith('Legacy') else name);destination.write_bytes((ROOT/'Sources'/name).read_bytes())
 probe=args.xml_probe_exe or ROOT/'build/msxml_probe.exe'
 if not probe.exists():raise SystemExit('Build the Easy app XML probe first or pass --xml-probe-exe')
 xml_folder=candidate/'Contents/Resources/xml-runtime';xml_folder.mkdir(exist_ok=True)
 shutil.copy2(probe,xml_folder/'msxml_probe.exe')
 xml=json.loads((ROOT/'resources/xml-runtime.json').read_text());xml['probeSHA256']=sha(probe)
 (candidate/'Contents/Resources/xml-runtime.json').write_text(json.dumps(xml,indent=2)+'\n')
 shutil.copy2(ROOT/'resources/launcher-update-public-key.txt',candidate/'Contents/Resources/launcher-update-public-key.txt')
 info=candidate/'Contents/Info.plist';data=plistlib.loads(info.read_bytes());data.update(CFBundleShortVersionString='1.3.6',CFBundleVersion='1.3.6');info.write_bytes(plistlib.dumps(data))
 subprocess.run(['codesign','--force','--sign','-','--identifier',data['CFBundleIdentifier'],str(candidate)],check=True)
else:
 # Scope the process check to this app. Do not terminate any game or helper.
 lines=subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
 for line in lines:
  fields=line.strip().split(None,1)
  if len(fields)==2 and fields[1]==str(app/'Contents/MacOS/nng'):
   command=subprocess.check_output(['ps','-p',fields[0],'-o','args='],text=True)
   if '--game-worker' not in command and '--update-and-game-worker' not in command:raise SystemExit('Close only the launcher GUI before applying; game can stay open.')
 subprocess.run(['codesign','--verify','--deep','--strict',str(candidate)],check=True)
 assert all(sha(candidate/name)==value for name,value in original.items()),'Helper/runtime would change'
 stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S');backup=ROOT/'local/launcher-backups'/stamp;backup.mkdir(parents=True)
 # Keep the original app directory/Dock target. Preserve the old Contents inode
 # in the backup for workers and helpers that are still running from it.
 os.rename(app/'Contents',backup/'Contents')
 try:os.rename(candidate/'Contents',app/'Contents')
 except Exception:os.rename(backup/'Contents',app/'Contents');raise
 report={'backup':str(backup),'app':str(app),'version':'1.3.6','helper_bridge_runtime_unchanged':original,'new_launcher_sha256':sha(app/'Contents/MacOS/nng')}
 (ROOT/'local/launcher-1.3.6-install.json').write_text(json.dumps(report,indent=2)+'\n')
 assert all(sha(app/name)==value for name,value in original.items())
 subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
 print(json.dumps(report,indent=2))
if not args.apply:
 subprocess.run(['codesign','--verify','--deep','--strict',str(candidate)],check=True)
 assert all(sha(candidate/name)==value for name,value in original.items())
 print('Prepared launcher 1.3.6; helper, bridge and accelerated runtime unchanged')
