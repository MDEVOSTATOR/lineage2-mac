#!/usr/bin/env python3
"""XML migration in a new, owned Wine prefix; never uses the owner's state."""
from pathlib import Path
import json,os,shutil,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parent.parent;app=ROOT/'build/NNG Mac Easy.app';source=ROOT/'local/easy-clean-install';logs=ROOT/'local/xml-fresh-checks';logs.mkdir(parents=True,exist_ok=True)
assert (source/'compat/cx26-x87/wine/bin/wine').exists(),'Prepare the isolated Easy installation first'
with tempfile.TemporaryDirectory(prefix='xml-fresh-',dir=ROOT/'local') as temporary:
 root=Path(temporary);(root/'compat/mac-client/system').mkdir(parents=True)
 (root/'compat/cx26-x87').symlink_to(source/'compat/cx26-x87',target_is_directory=True)
 for name in ['msxml4.dll','msxml4a.dll','msxml4r.dll']:shutil.copyfile(source/'compat/mac-client/system'/name,root/'compat/mac-client/system'/name)
 env=os.environ.copy();env['NNG_STATE_ROOT']=str(root);env['WINEPREFIX']=str(root/'compat/prefix-cx26-x87')
 for k in ['DYLD_INSERT_LIBRARIES','DYLD_FALLBACK_LIBRARY_PATH','WINELOADERNOEXEC','X87_DISABLE_HOOK','X87_LOGS','X87_SAMPLE']:env.pop(k,None)
 def run(label,arg,timeout):
  start=time.monotonic()
  with (logs/(label+'.log')).open('wb') as out:subprocess.run([str(app/'Contents/MacOS/nng'),arg],env=env,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=timeout)
  return round((time.monotonic()-start)*1000)
 try:
  boot=run('boot','--prepare-runtime',150)
  repair=run('migration','--repair-xml',150)
  repeat=run('repeat','--repair-xml',15)
  assert 'both game-name probes passed' in (logs/'migration.log').read_text()
  assert 'migration not needed' in (logs/'repeat.log').read_text()
  prefix=root/'compat/prefix-cx26-x87'
  assert (prefix/'.nng-msxml4-v1.json').exists()
  assert len(list(prefix.glob('nng-msxml-backup-*')))==1
  result={'fresh_prefix':True,'native_xml_self_test_both_game_names':True,'one_checkpoint':True,'repeat_fast_path':True,'boot_ms':boot,'first_migration_ms':repair,'repeat_ms':repeat,'owner_state_used':False}
  (ROOT/'local/xml-fresh-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
 finally:
  env['ROSETTA_X87_PATH']=str(root/'compat/cx26-x87/x87sidecar')
  subprocess.run([str(root/'compat/cx26-x87/wine/bin/wineserver'),'-k'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
