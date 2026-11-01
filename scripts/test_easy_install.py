#!/usr/bin/env python3
"""Check prepared Easy installation, repair, settings and hidden D3D9 rendering.

Requires an already seeded/downloaded local/easy-clean-install and a separately
built windows/386 D3D9 smoke probe. Never uses or terminates an owner's prefix.
"""
from pathlib import Path
import argparse,fcntl,hashlib,json,os,subprocess
ROOT=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--probe-exe',type=Path,required=True);args=p.parse_args()
app=ROOT/'build/NNG Mac Easy.app';state=ROOT/'local/easy-clean-install';exe=app/'Contents/MacOS/nng'
assert state.is_relative_to(ROOT/'local') and not (state/'compat/game-session.json').exists()
env=os.environ.copy();env['NNG_STATE_ROOT']=str(state)
logs=ROOT/'local/easy-checks';logs.mkdir(parents=True,exist_ok=True)
def run(name,arguments,timeout=180):
 with (logs/(name+'.log')).open('wb') as out:
  return subprocess.run([str(x) for x in arguments],env=env,stdout=out,stderr=subprocess.STDOUT,timeout=timeout,check=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
result={}
# A ready installation must be a complete 2031-file, hash-verified setup.
run('initial-verify',[exe,'--verify-client']);result['all_client_hashes']=True
client=state/'client';game=state/'compat/mac-client/system';user=game/'User.ini';original=user.read_bytes()
stock_user_sha=sha(client/'system/User.ini')
try:
 # A sentinel in the disposable game's own INI must survive an updater rerun.
 user.write_bytes(original+b'\n; isolated integration test sentinel\n')
 want=sha(user)
 run('repeat-setup',[exe,'--setup-only'])
 assert sha(user)==want and sha(client/'system/User.ini')==stock_user_sha
 assert (state/'compat/easy-ready.json').exists()
 result['repeat_setup_preserves_user_settings']=True
finally:user.write_bytes(original)
# Corrupt just a tiny, known stock file in the disposable cache. Same updater
# must repair it from the live server, without redownloading the full client.
records=json.loads((client/'.nng-state.json').read_text())
name=min((name for name in records if name.startswith('system/') and name.lower().endswith('.ini')),key=lambda name:records[name]['size'])
target=client/name;original=target.read_bytes()
try:
 target.write_bytes(b'NNG disposable corrupt cache fixture\n')
 run('repair',[exe,'--setup-only'])
 assert sha(target)==records[name]['sha'];result['updater_repairs_corrupt_file_from_server']=name
finally:
 if sha(target)!=records[name]['sha']:target.write_bytes(original)
# Second setup cannot run while another launcher owns the session lock.
with (state/'.launch.lock').open('a+b') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 run('lock-check',[exe,'--setup-only'],10)
 assert 'already running' in (logs/'lock-check.log').read_text();result['session_lock']=True
runtime=state/'compat/cx26-x87';prefix=state/'compat/prefix-cx26-x87'
probe=args.probe_exe.resolve();assert probe.read_bytes()[:2]==b'MZ'
graphics_env=env.copy();graphics_env.update(WINEPREFIX=str(prefix),ROSETTA_X87_PATH=str(runtime/'x87sidecar'),WINEMSYNC='1',WINEDEBUG='-all',WINEDLLOVERRIDES='d3d9=b;mscoree,mshtml=')
for key in ('DYLD_INSERT_LIBRARIES','DYLD_FALLBACK_LIBRARY_PATH','WINELOADERNOEXEC','X87_DISABLE_HOOK'):graphics_env.pop(key,None)
try:
 with (logs/'graphics.stdout').open('wb') as out,(logs/'graphics.stderr').open('wb') as err:
  subprocess.run([str(runtime/'wine/bin/wine'),str(probe)],env=graphics_env,cwd=game,stdout=out,stderr=err,check=True,timeout=30)
 graphics=json.loads((logs/'graphics.stdout').read_text())
 assert graphics.get('pass') and graphics.get('presented_frames')==12
 assert 'd3d9 = mtld3d' in (logs/'graphics.stderr').read_text()
 result['hidden_d3d9_present_frames']=12;result['mtld3d_selected']=True
 registry=(prefix/'user.reg').read_text(errors='replace')
 assert '"AllowSetGamma"="N"' in registry and '"UsePreciseScrolling"="n"' in registry
 result['gamma_policy']=True
finally:
 subprocess.run([str(runtime/'wine/bin/wineserver'),'-k'],env=graphics_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
result.update(complete_game_download_from_empty=False,game_login_test=False,rosetta_install_test=False,isolated_prefix=True)
(ROOT/'local/easy-test-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
