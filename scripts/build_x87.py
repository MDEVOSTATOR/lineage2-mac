#!/usr/bin/env python3
"""Build a pinned, isolated x87 acceleration candidate; does not install anything."""
from pathlib import Path
import subprocess,concurrent.futures,hashlib,json
b=Path(__file__).resolve().parent.parent;r=b/'local/cache/x87-source';build=b/'build/x87';build.mkdir(parents=True,exist_ok=True)
commit='499e0f7e60d2961d379df459dd96bc79ecfe59fd' # archive checked by build.py
assert commit=='499e0f7e60d2961d379df459dd96bc79ecfe59fd'
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip();loader=r/'rosetta_loader/src';core=r/'rosetta_core'
subprocess.run(['xcrun','mig','-arch','arm64','-isysroot',sdk,'-server',str(build/'mach_excServer.c'),'-sheader',str(build/'mach_excServer.h'),'-user','/dev/null','-header','/dev/null',sdk+'/usr/include/mach/mach_exc.defs'],check=True)
sources=list((core/'src').glob('*.cpp'))+list(loader.glob('*.cpp'))+[build/'mach_excServer.c']
def compile(src):
 out=build/(src.stem+'.o');cmd=['xcrun','clang++' if src.suffix=='.cpp' else 'clang','-arch','arm64','-O2','-mmacosx-version-min=15.0','-ffile-prefix-map='+str(b)+'=.','-fdebug-prefix-map='+str(b)+'=.','-I'+str(loader),'-I'+str(core/'include'),'-I'+str(build)]
 if src.suffix=='.cpp':cmd+=['-std=c++23']
 cmd+=['-c',str(src),'-o',str(out)];p=subprocess.run(cmd,capture_output=True,text=True)
 if p.returncode:raise RuntimeError(src.name+': '+p.stderr[-4000:])
 print('Built '+src.name,flush=True);return out
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:objects=list(pool.map(compile,sources))
exe=build/'x87sidecar';subprocess.run(['xcrun','clang++','-arch','arm64','-O2','-mmacosx-version-min=15.0',*[str(o) for o in objects],'-framework','Security','-o',str(exe)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(exe)],check=True)
p=subprocess.run([str(exe),'--probe'],capture_output=True,text=True);(build/'probe.txt').write_text(p.stdout+p.stderr);print(p.stdout,p.stderr,flush=True)
(b/'build/x87-build.json').write_text(json.dumps({'commit':commit,'source':'https://github.com/athei/x87sidecar','license':'MIT','sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'probe_code':p.returncode,'installed':False},indent=2)+'\n')
raise SystemExit(p.returncode)
