#!/usr/bin/env python3
"""Native migration rollback and idempotence using an isolated fake Wine."""
from pathlib import Path
import hashlib,json,os,subprocess,tempfile,fcntl
ROOT=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='nng-xml-test-') as directory:
 t=Path(directory);main=t/'main.swift';exe=t/'native-probe'
 main.write_text('''import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1])
var env=ProcessInfo.processInfo.environment;env["WINEPREFIX"]=root.appendingPathComponent("prefix").path
 do {
 try ensureNativeXMLRuntime(root:root,wine:root.appendingPathComponent("wine"),prefix:root.appendingPathComponent("prefix"),environment:env,resources:root.appendingPathComponent("resources"))
 print("PASS")
 } catch {print("FAIL \\(error)");exit(1)}
''')
 subprocess.run(['xcrun','swiftc','-O',str(main),str(ROOT/'Sources/XMLRuntime.swift'),'-o',str(exe)],check=True)
 fake=r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
p=Path(os.environ['WINEPREFIX']);state=p/'state.json';s=json.loads(state.read_text()) if state.exists() else {}
a=sys.argv[1:]
if a[0].lower().endswith(('l2.exe','l2.bin')):
 provider=s.get('provider','C:\\windows\\system32\\msxml3.dll')
 print(json.dumps({'class':'DOMDocument40','hresult':'00000000','nonnull':True,'provider':provider}))
 print(json.dumps({'get_url_hr':'00000000' if 'provider' in s else '80004001','loaded':0,'url_nonnull':'provider' in s}))
 print(json.dumps({'class':'DOMDocument60','hresult':'00000000','nonnull':True}))
elif 'regsvr32' in a[0].lower():
 s['provider']=a[-1];state.write_text(json.dumps(s))
 # Simulate a registry change before a later command fails.
 with (p/'system.reg').open('w') as f:f.write('\n[Software\\\\Classes\\\\Wow6432Node\\\\CLSID\\\\{88D969C0-F192-11D4-A65F-0040963251E5}\\\\InprocServer32] 1\n@='+json.dumps(a[-1])+'\n')
 (p/'userdef.reg').write_text('changed by registration')
elif a[0]=='reg':
 app=a[2].split('\\')[-2]
 if app=='L2.bin' and (p/'fail-registration').exists():
  if (p/'fail-rollback-wait').exists():(p/'server-now-fails').touch()
  sys.exit(17)
 with (p/'user.reg').open('a') as f:f.write('\n[Software\\\\Wine\\\\AppDefaults\\\\'+app+'\\\\DllOverrides] 1\n"msxml4"="native"\n')
'''
 def fixture(name):
  root=t/name;(root/'prefix/drive_c/windows/syswow64').mkdir(parents=True);(root/'compat/mac-client/system').mkdir(parents=True);(root/'resources/xml-runtime').mkdir(parents=True)
  for n in ['system.reg','user.reg','userdef.reg']:(root/'prefix'/n).write_text('original '+n+'\n')
  (root/'prefix/drive_c/windows/syswow64/regsvr32.exe').touch()
  (root/'wine').write_text(fake);(root/'wine').chmod(0o755)
  (root/'wineserver').write_text('#!/bin/sh\nexit 0\n');(root/'wineserver').chmod(0o755)
  pins={}
  for n in ['msxml4.dll','msxml4a.dll','msxml4r.dll']:
   b=('fixture '+n).encode();(root/'compat/mac-client/system'/n).write_bytes(b);pins[n]=hashlib.sha256(b).hexdigest()
  b=b'own fixture probe';(root/'resources/xml-runtime/msxml_probe.exe').write_bytes(b)
  (root/'resources/xml-runtime.json').write_text(json.dumps({'version':1,'files':pins,'probeSHA256':hashlib.sha256(b).hexdigest()}))
  return root
 def run(root,ok=True):
  r=subprocess.run([str(exe),str(root)],capture_output=True,text=True,timeout=15)
  assert (r.returncode==0)==ok,r.stdout+r.stderr
  return r.stdout
 bad=fixture('rollback');(bad/'prefix/fail-registration').touch()
 original={n:(bad/'prefix'/n).read_bytes() for n in ['system.reg','user.reg','userdef.reg']}
 run(bad,ok=False)
 assert all((bad/'prefix'/n).read_bytes()==b for n,b in original.items())
 assert not (bad/'prefix/.nng-msxml4-v1.json').exists()
 checkpoint=next((bad/'prefix').glob('nng-msxml-backup-*'))
 assert json.loads((checkpoint/'receipt.json').read_text())['state']=='rolled-back'
 for n in original:assert (checkpoint/n).stat().st_mode&0o077==0
 good=fixture('migration');assert 'both game-name probes passed' in run(good)
 assert 'migration not needed' in run(good)
 with (good/'prefix/.nng-msxml-repair.lock').open('a+b') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  assert 'Другая проверка XML' in run(good,ok=False)
 count=len(list((good/'prefix').glob('nng-msxml-backup-*')))
 # Missing AppDefaults must invalidate the marker and rebuild registration.
 (good/'prefix/user.reg').write_text('removed overrides\n')
 assert 'both game-name probes passed' in run(good)
 assert len(list((good/'prefix').glob('nng-msxml-backup-*')))==count+1
 # Wrong source/probe pins refuse changes before any registry registration.
 tamper=fixture('tampered');(tamper/'resources/xml-runtime/msxml_probe.exe').write_bytes(b'tampered')
 run(tamper,ok=False);assert not list((tamper/'prefix').glob('nng-msxml-backup-*'))
 busy=fixture('busy');(busy/'wineserver').write_text('#!/bin/sh\nexit 4\n')
 run(busy,ok=False);assert not list((busy/'prefix').glob('nng-msxml-backup-*'))
 recovery=fixture('recovery');(recovery/'prefix/fail-registration').touch();(recovery/'prefix/fail-rollback-wait').touch()
 (recovery/'wineserver').write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nimport os,sys\nsys.exit(4 if (Path(os.environ['WINEPREFIX'])/'server-now-fails').exists() else 0)\n")
 run(recovery,ok=False)
 report=next((recovery/'prefix').glob('nng-msxml-backup-*/receipt.json'))
 assert json.loads(report.read_text())['state']=='recovery-required'
 before_count=len(list((recovery/'prefix').glob('nng-msxml-backup-*')))
 assert 'Автоматический повтор остановлен' in run(recovery,ok=False)
 assert len(list((recovery/'prefix').glob('nng-msxml-backup-*')))==before_count
 print(json.dumps({'partial_registration_rollback':True,'private_backup_permissions':True,'first_migration':True,'existing_prefix_marker_does_not_skip_migration':True,'repeat_fast_path':True,'prefix_lock_covers_fast_path':True,'lost_registry_override_invalidates_marker':True,'tampered_probe_rejected':True,'server_wait_failure_refused':True,'failed_rollback_stops_automatic_retries':True}))
