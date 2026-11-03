#!/usr/bin/env python3
"""Real conditional HTTP and persistent digest-cache tests; no game or updater."""
from pathlib import Path
import hashlib,http.server,json,os,subprocess,tempfile,threading,time
ROOT=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='nng-update-check-') as directory:
 t=Path(directory);state=t/'state';(state/'compat/mac-client/system').mkdir(parents=True);(state/'client').mkdir()
 (state/'compat/mac-client/system/l2.exe').write_bytes(b'fixture')
 pins={f'assets/{i}.dat':{'size':1,'sha256':'a'*64} for i in range(2000)}
 def set_local():
  (state/'client/.nng-state.json').write_text(json.dumps({name:{'size':p['size'],'sha':p['sha256']} for name,p in pins.items()}))
 set_local();server_state={'etag':'"v1"','body':json.dumps(pins).encode(),'status':200,'delay':0};requests=[]
 class Handler(http.server.BaseHTTPRequestHandler):
  def log_message(self,*args):pass
  def do_HEAD(self):
   tag=self.headers.get('If-None-Match');requests.append(tag)
   time.sleep(server_state['delay'])
   code=304 if tag==server_state['etag'] and server_state['status']==200 else server_state['status']
   self.send_response(code);self.send_header('ETag',server_state['etag']);self.end_headers()
  def do_GET(self):
   tag=self.headers.get('If-None-Match');requests.append(tag)
   time.sleep(server_state['delay'])
   code=304 if tag==server_state['etag'] and server_state['status']==200 else server_state['status']
   self.send_response(code);self.send_header('ETag',server_state['etag']);self.end_headers()
   if code!=304:
    try:self.wfile.write(server_state['body'])
    except (BrokenPipeError,ConnectionResetError):pass
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
 main=t/'main.swift';exe=t/'probe'
 main.write_text('''import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[2])
do {
 if CommandLine.arguments[1]=="http" {
  let result=try clientNeedsUpdate(root:root,base:URL(string:CommandLine.arguments[3])!,timeout:Double(CommandLine.arguments[4])!)
  print(result ? "CHANGED" : "UNCHANGED")
 } else {
  let value=try cachedFileDigest(URL(fileURLWithPath:CommandLine.arguments[3]),root:root)
  flushFileDigestCache(root:root);print("DIGEST "+value)
 }
} catch {print("FAIL \\(error)");exit(1)}
''')
 subprocess.run(['xcrun','swiftc','-O',str(main),str(ROOT/'Sources/UpdateCheck.swift'),'-o',str(exe)],check=True)
 def probe(*args,ok=True):
  p=subprocess.run([str(exe),*map(str,args)],capture_output=True,text=True,timeout=5)
  assert (p.returncode==0)==ok,p.stdout+p.stderr
  return p.stdout
 base=f'http://127.0.0.1:{server.server_port}/files'
 def http(ok=True,timeout=2):return probe('http',state,base,timeout,ok=ok)
 assert 'UNCHANGED' in http() and requests[-1] is None
 assert 'HTTP304' in http() and requests[-1]=='"v1"'
 pins['assets/17.dat']['sha256']='b'*64;server_state.update(etag='"v2"',body=json.dumps(pins).encode())
 assert 'CHANGED' in http();assert 'CHANGED' in http() # unmatched manifest never poisons receipt
 set_local();assert 'UNCHANGED' in http() and requests[-1] is None
 assert 'HTTP304' in http()
 server_state.update(status=503);assert 'FAIL' in http(ok=False)
 server_state.update(status=200,etag='"bad"',body=b'not a manifest');assert 'FAIL' in http(ok=False)
 server_state.update(delay=0.7);began=time.monotonic();http(ok=False,timeout=0.1);assert time.monotonic()-began<1
 f=t/'binary';f.write_bytes(b'aaa');want=hashlib.sha256(b'aaa').hexdigest()
 assert want in probe('digest',state,f)
 assert '0 hashed; 0 bytes read' in probe('digest',state,f)
 before=f.stat();f.write_bytes(b'bbb');os.utime(f,ns=(before.st_atime_ns,before.st_mtime_ns))
 assert hashlib.sha256(b'bbb').hexdigest() in probe('digest',state,f)
 replacement=t/'replacement';replacement.write_bytes(b'ccc');os.utime(replacement,ns=(before.st_atime_ns,before.st_mtime_ns));os.replace(replacement,f)
 assert hashlib.sha256(b'ccc').hexdigest() in probe('digest',state,f)
 (state/'compat/verified-file-hashes-v1.json').write_bytes(b'broken cache')
 assert '1 hashed' in probe('digest',state,f)
 server.shutdown()
 print(json.dumps({'http_200_then_304':True,'changed_manifest_requires_update':True,'unapplied_update_not_cached_as_current':True,'changed_local_state_invalidates_etag':True,'server_error_not_treated_as_current':True,'invalid_manifest_rejected':True,'bounded_timeout':True,'persistent_hash_cache':True,'same_size_edit_with_restored_mtime_detected':True,'atomic_replacement_detected':True,'corrupt_cache_rehashed':True}))
