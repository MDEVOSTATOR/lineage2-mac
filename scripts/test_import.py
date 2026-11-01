#!/usr/bin/env python3
"""Exercise real app CLI import/integrity paths using disposable client fixtures."""
from pathlib import Path
import fcntl,json,os,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
EXE=ROOT/'build/NNG Mac Community.app/Contents/MacOS/nng'
with tempfile.TemporaryDirectory(prefix='nng-import-test-') as temporary:
 t=Path(temporary);source=t/'client';system=source/'system';system.mkdir(parents=True);state=t/'state'
 (system/'l2.exe').write_bytes(b'fixture-only-client');(system/'Engine.dll').write_bytes(b'fixture-engine')
 (system/'User.ini').write_text('owner-settings');(source/'textures').mkdir();(source/'textures/a.utx').write_bytes(b'asset')
 env=os.environ.copy();env['NNG_STATE_ROOT']=str(state)
 def run(*args,ok=True):
  p=subprocess.run([str(EXE),*map(str,args)],env=env,capture_output=True,text=True,timeout=20)
  assert (p.returncode==0)==ok,p.stderr+p.stdout
  return p
 original=(system/'Engine.dll').read_bytes()
 run('--import-client',source);run('--verify-client')
 assert (system/'Engine.dll').read_bytes()==original
 assert (state/'compat/mac-client/textures/a.utx').read_bytes()==b'asset'
 assert (state/'compat/mac-client/system/User.ini').read_text()=='owner-settings'
 (system/'User.ini').write_text('new-owner-settings');run('--verify-client')
 assert (state/'compat/mac-client/system/User.ini').read_text()=='owner-settings'
 (system/'Engine.dll').write_bytes(b'updated-by-vendor');run('--verify-client',ok=False)
 with (state/'.launch.lock').open('r+') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);run('--import-client',source,ok=False)
 assert (state/'compat/mac-client/system/Engine.dll').read_bytes()==original
 run('--import-client',source);run('--verify-client')
 assert any((state/'compat/import-backups').iterdir())
 (system/'escape.dll').symlink_to(t/'outside');(t/'outside').write_text('not-a-game-file')
 run('--import-client',source,ok=False)
 assert (state/'compat/mac-client/system/Engine.dll').read_bytes()==b'updated-by-vendor'
 run('--import-client',state/'compat/mac-client',ok=False)
 print(json.dumps({'import':'pass','source_preserved':True,'assets_linked':True,'mutable_settings_preserved':True,'changed_engine_rejected':True,'active_game_lock_respected':True,'backup_retained':True,'system_symlink_rejected':True,'recursive_state_import_rejected':True}))
