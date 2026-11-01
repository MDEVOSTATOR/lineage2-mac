#!/usr/bin/env python3
"""Bounded hidden-window graphics smoke test in an owned local prefix; no game."""
from pathlib import Path
import argparse,json,os,shutil,subprocess
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--probe-exe',type=Path);args=p.parse_args()
app=ROOT/'build/NNG Mac Community.app';state=ROOT/'local/runtime-smoke';runtime=state/'compat/cx26-x87';prefix=state/'compat/prefix-cx26-x87'
assert state.is_relative_to(ROOT/'local')
session=state/'compat/game-session.json'
if session.exists():raise SystemExit('A game session receipt exists; refusing this test.')
probe=args.probe_exe or ROOT/'build/d3d9-smoke.exe'
if not args.probe_exe:
 env=os.environ.copy();env.update(GOOS='windows',GOARCH='386',CGO_ENABLED='0',GO111MODULE='off')
 subprocess.run(['go','build','-trimpath','-o',str(probe),str(ROOT/'scripts/diagnostics/d3d9_smoke.go')],env=env,check=True)
assert probe.read_bytes()[:2]==b'MZ'
cache=state/'compat/downloads';cache.mkdir(parents=True,exist_ok=True)
manifest=json.loads((app/'Contents/Resources/acceleration/runtime.json').read_text());name=manifest['archive']['name']
if (ROOT/'local/cache'/name).exists() and not (cache/name).exists():subprocess.run(['/bin/cp','-c',str(ROOT/'local/cache'/name),str(cache/name)],check=True)
env=os.environ.copy();env['NNG_STATE_ROOT']=str(state)
for key in ('DYLD_INSERT_LIBRARIES','DYLD_FALLBACK_LIBRARY_PATH','WINELOADERNOEXEC','X87_SAMPLE','X87_LOGS','X87_DISABLE_HOOK'):env.pop(key,None)
try:
 with (ROOT/'local/runtime-prepare.log').open('wb') as log:
  subprocess.run([str(app/'Contents/MacOS/nng'),'--prepare-runtime'],env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
 env.update(WINEPREFIX=str(prefix),ROSETTA_X87_PATH=str(runtime/'x87sidecar'),WINEMSYNC='1',WINEDEBUG='-all',WINEDLLOVERRIDES='d3d9=b;mscoree,mshtml=')
 with (ROOT/'local/d3d9-smoke.stdout').open('wb') as out,(ROOT/'local/d3d9-smoke.stderr').open('wb') as err:
  subprocess.run([str(runtime/'wine/bin/wine'),str(probe.resolve())],env=env,cwd=state/'compat/mac-client/system',stdout=out,stderr=err,check=True,timeout=30)
 result=json.loads((ROOT/'local/d3d9-smoke.stdout').read_text())
 assert result.get('pass') is True and result.get('presented_frames')==12,result
 assert 'd3d9 = mtld3d' in (ROOT/'local/d3d9-smoke.stderr').read_text()
 result.update(prefix_isolated=True,mtld3d_selected=True,game_launched=False)
 (ROOT/'local/runtime-smoke-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
finally:
 if (runtime/'wine/bin/wineserver').exists():
  env['WINEPREFIX']=str(prefix)
  subprocess.run([str(runtime/'wine/bin/wineserver'),'-k'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
