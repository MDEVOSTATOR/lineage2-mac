#!/usr/bin/env python3
"""Check only the explicit public file set and generated app, never local caches."""
from pathlib import Path
import json,re,subprocess,zipfile
ROOT=Path(__file__).resolve().parent.parent
DIRECTORIES={'Sources','scripts','patches','resources','licenses','docs','.github'}
FILES={'README.md','LICENSE','THIRD-PARTY.md','.gitignore'}
patterns=[('credential',rb'(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'),('personal_path',rb'/Users/(?!runner/)[A-Za-z0-9_.-]+/'),('private_ipv4',rb'\b(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|100\.(?:[6-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3})\b')]
files=[]
for folder in DIRECTORIES:
 if (ROOT/folder).exists():files += [p for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.suffix!='.pyc']
files += [ROOT/p for p in FILES if (ROOT/p).exists()]
errors=[]
for p in files:
 if p.is_symlink():errors.append(str(p.relative_to(ROOT))+': symlink not allowed');continue
 for name,pattern in patterns:
  if re.search(pattern,p.read_bytes()):errors.append(str(p.relative_to(ROOT))+': '+name)
 if p.stat().st_size>5*1024*1024:errors.append(str(p.relative_to(ROOT))+': unexpected large file')
apps=[ROOT/'build/NNG Mac Community.app',ROOT/'build/NNG Mac Easy.app']
for p in [file for app in apps if app.exists() for file in app.rglob('*')]:
 if not p.is_file():continue
 if p.name.lower() in {'l2.exe','engine.dll','core.dll','nwindow.dll','user.ini','l2.ini','option.ini','system.reg','user.reg'}:errors.append('app contains game or user state: '+p.name)
 if p.name.startswith('wine-cx-') and p.name.endswith('.tar.xz'):errors.append('Wine archive must be fetched upstream, not bundled')
 if re.search(rb'/Users/(?!runner/)[A-Za-z0-9_.-]+/',p.read_bytes()):errors.append('app personal path: '+str(p.relative_to(ROOT/'build')))
# Verify staged Git content too, if there is a repository yet.
r=subprocess.run(['git','-C',str(ROOT),'rev-parse','--show-toplevel'],capture_output=True,text=True)
if r.returncode==0 and Path(r.stdout.strip())==ROOT:
 tracked=subprocess.check_output(['git','-C',str(ROOT),'ls-files','-z']).decode().split('\0')
 for path in filter(None,tracked):
  if Path(path).parts[0] not in DIRECTORIES and path not in FILES:errors.append('unexpected tracked path: '+path)
if errors:
 print(json.dumps({'pass':False,'issues':errors},indent=2));raise SystemExit(1)
print(json.dumps({'pass':True,'public_files':len(files),'apps_checked':[p.name for p in apps if p.exists()],'checks':['credentials','personal paths','private IPv4','game binaries','prefix/account data','public allowlist']},indent=2))
