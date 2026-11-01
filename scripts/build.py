#!/usr/bin/env python3
"""Build the community app without any game files, Wine binary, or user state."""
from pathlib import Path
import argparse,hashlib,json,os,plistlib,shutil,subprocess,sys,urllib.request,zipfile
ROOT=Path(__file__).resolve().parent.parent
BUILD=ROOT/'build';CACHE=ROOT/'local/cache';DIST=ROOT/'dist'
VERSION='1.3.4';TAG='v1.3.4-preview.1'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(args,**kw):return subprocess.run([str(x) for x in args],check=True,**kw)
def fetch(url,path,want):
 if path.exists() and sha(path)==want:return path
 temp=path.with_suffix(path.suffix+'.partial');path.parent.mkdir(parents=True,exist_ok=True)
 with urllib.request.urlopen(url,timeout=60) as response,temp.open('wb') as out:shutil.copyfileobj(response,out)
 if sha(temp)!=want:temp.unlink();raise RuntimeError('Dependency checksum mismatch: '+path.name)
 temp.replace(path);return path
def unpack(archive,destination,strip=False):
 if destination.exists():shutil.rmtree(destination)
 destination.mkdir(parents=True)
 run(['/usr/bin/tar','-xf',archive,'-C',destination]+(['--strip-components','1'] if strip else []))
def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--easy',action='store_true',help='Build automatic NNG installer');parser.add_argument('--bridge-exe',type=Path);parser.add_argument('--reuse-x87-build',action='store_true');args=parser.parse_args()
 for path in (BUILD,CACHE,DIST):path.mkdir(parents=True,exist_ok=True)
 dep=json.loads((ROOT/'resources/dependencies.json').read_text())
 archive=fetch(dep['mtld3d']['url'],CACHE/'mtld3d.tar.xz',dep['mtld3d']['sha256']);unpack(archive,BUILD/'mtld3d')
 source=fetch(dep['x87sidecar']['archive_url'],CACHE/'x87sidecar.tar.gz',dep['x87sidecar']['sha256']);unpack(source,CACHE/'x87-source',True)
 if args.reuse_x87_build:
  prior=json.loads((BUILD/'x87-build.json').read_text());assert prior['commit']==dep['x87sidecar']['commit'] and sha(BUILD/'x87/x87sidecar')==prior['sha256']
 else:run([sys.executable,ROOT/'scripts/build_x87.py'])
 bridge=BUILD/'nng-input.exe'
 if args.bridge_exe:
  bridge.write_bytes(args.bridge_exe.read_bytes())
 else:
  env=os.environ.copy();env.update(GOOS='windows',GOARCH='386',CGO_ENABLED='0',GO111MODULE='off')
  run(['go','vet',ROOT/'Sources/WineInputBridge.go'],env=env)
  run(['go','build','-trimpath','-ldflags=-s -w','-o',bridge,ROOT/'Sources/WineInputBridge.go'],env=env)
 assert bridge.read_bytes()[:2]==b'MZ'
 tag='v1.4.0-preview.1' if args.easy else TAG
 app=BUILD/('NNG Mac Easy.app' if args.easy else 'NNG Mac Community.app')
 if app.exists():shutil.rmtree(app)
 res=app/'Contents/Resources';helper=app/'Contents/Helpers/NNG Trackpad.app';hres=helper/'Contents/Resources/input-bridge'
 for d in (res,hres,app/'Contents/MacOS',helper/'Contents/MacOS',res/'acceleration/overlay',res/'Licenses'):d.mkdir(parents=True,exist_ok=True)
 overlay=res/'acceleration/overlay'
 manifest=json.loads((ROOT/'resources/runtime.json').read_text())
 for arch in ('i386-windows','x86_64-windows','x86_64-unix'):
  for name in (('mtld3d.so',) if arch=='x86_64-unix' else ('d3d9.dll','mtld3d.dll')):
   src=BUILD/'mtld3d/wine'/arch/name;rel='wine/lib/wine/d3d9/mtld3d/'+arch+'/'+name
   target=overlay/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,target)
   if arch=='i386-windows' and name=='d3d9.dll':run([sys.executable,ROOT/'patches/patch_resize_renderer.py',src,target,'--safe-present'])
   assert sha(target)==manifest['files'][rel],rel
 shutil.copy2(BUILD/'x87/x87sidecar',overlay/'x87sidecar');manifest['files']['x87sidecar']=sha(overlay/'x87sidecar')
 (res/'acceleration/runtime.json').write_text(json.dumps(manifest,indent=2)+'\n')
 if args.easy:
  config=json.loads((ROOT/'resources/easy-install.json').read_text())
  (res/'mac-binaries.json').write_text(json.dumps({x['name']:{'size':x['size'],'sha256':x['sha256']} for x in config['modules']},indent=2)+'\n')
  for name in ('easy-install.json','settings-patches.json'):shutil.copy2(ROOT/'resources'/name,res/name)
 else:(res/'mac-binaries.json').write_text('{}\n')
 shutil.copy2(ROOT/'resources/AppIcon.icns',res/'NNGMac.icns')
 for p in (ROOT/'licenses').iterdir():shutil.copy2(p,res/'Licenses'/p.name)
 for name in ('THIRD-PARTY.md','LICENSE','README.md'):shutil.copy2(ROOT/name,res/name)
 for name in ('main.swift','ClientImport.swift','EasyInstall.swift','Trackpad.swift','WineInputBridge.go'):
  d=res/'Sources';d.mkdir(exist_ok=True);shutil.copy2(ROOT/'Sources'/name,d/name)
 for name in ('patch_resize_renderer.py','mtld3d-0.15.1-lineage2.patch'):shutil.copy2(ROOT/'patches'/name,res/'Sources'/name)
 main=app/'Contents/MacOS/nng';native=helper/'Contents/MacOS/nng-trackpad'
 source_dir=BUILD/('easy-sources' if args.easy else 'community-sources');source_dir.mkdir(exist_ok=True)
 for name in ('main.swift','Trackpad.swift'):
  source=(ROOT/'Sources'/name).read_text()
  if args.easy:source=source.replace('ru.nng.macclient.community','ru.nng.macclient.easy').replace('ru.nng.community.trackpad.show','ru.nng.easy.trackpad.show').replace('Library/Application Support/NNG Mac Community','Library/Application Support/NNG Mac Easy')
  (source_dir/name).write_text(source)
 run(['xcrun','swiftc','-O','-target','arm64-apple-macos15.0','-file-prefix-map',str(ROOT)+'=.','-debug-prefix-map',str(ROOT)+'=.',source_dir/'main.swift',ROOT/'Sources/ClientImport.swift',ROOT/'Sources/EasyInstall.swift','-o',main])
 run(['xcrun','swiftc','-O','-target','arm64-apple-macos15.0','-file-prefix-map',str(ROOT)+'=.','-debug-prefix-map',str(ROOT)+'=.',source_dir/'Trackpad.swift','-o',native])
 run([native,'--self-test'])
 shutil.copy2(bridge,hres/'nng-input.exe');(hres/'sha256').write_text(sha(bridge)+'\n')
 for bundle,identifier,exe,title in [(helper,'ru.nng.macclient.community.trackpad','nng-trackpad','Тачпад NNG Mac'),(app,'ru.nng.macclient.community','nng','NNG Mac Community')]:
  if args.easy:identifier=identifier.replace('.community','.easy');title='NNG Mac Easy' if bundle==app else title
  info=dict(CFBundleIdentifier=identifier,CFBundleName=title,CFBundleDisplayName=title,CFBundleExecutable=exe,CFBundlePackageType='APPL',CFBundleShortVersionString='1.4.0' if args.easy else VERSION,CFBundleVersion='1',LSMinimumSystemVersion='15.0',NSHighResolutionCapable=True,LSMultipleInstancesProhibited=True)
  if bundle==app:
   info['CFBundleIconFile']='NNGMac.icns'
   if args.easy:info.update(NNGEasyInstaller=True,CFBundleShortVersionString='1.4.0')
  else:info['LSUIElement']=True
  (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
  run(['codesign','--force','--sign','-','--identifier',identifier,bundle])
 run(['codesign','--verify','--deep','--strict',app])
 archive_path=DIST/(('NNG-Mac-Easy-' if args.easy else 'NNG-Mac-Community-')+tag+'-arm64.zip')
 if archive_path.exists():archive_path.unlink()
 with zipfile.ZipFile(archive_path,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
  for file in sorted(app.rglob('*')):
   if file.is_file():archive.write(file,file.relative_to(app.parent))
 (DIST/('SHA256SUMS-easy' if args.easy else 'SHA256SUMS')).write_text(sha(archive_path)+'  '+archive_path.name+'\n')
 (BUILD/'build-report.json').write_text(json.dumps({'tag':tag,'app':app.name,'architecture':'arm64','zip_sha256':sha(archive_path),'contains_game_files':False,'contains_wine_archive':False,'signing':'ad hoc, not notarized','x87_commit':dep['x87sidecar']['commit'],'runtime':manifest},indent=2)+'\n')
 print('Built '+str(archive_path),flush=True)
if __name__=='__main__':main()
