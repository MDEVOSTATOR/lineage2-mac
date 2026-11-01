#!/usr/bin/env python3
"""Archive deferred LOCAL files only after no process has them open. No deletion."""
from pathlib import Path
import argparse,json,subprocess
root=Path(__file__).resolve().parent.parent;receipt=root/'local/cleanup.json'
if not receipt.exists():raise SystemExit('No local cleanup receipt; nothing to move.')
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--apply',action='store_true');args=p.parse_args()
data=json.loads(receipt.read_text());archive=Path(data['archive'])
assert archive.is_absolute() and archive.is_dir() and not archive.is_relative_to(root)
result=subprocess.run(['lsof','-nP','-Fn'],capture_output=True,text=True)
open_paths=[line[1:] for line in result.stdout.splitlines() if line.startswith('n')]
rows=[]
for key in ('retained_for_live_worker','retained_for_stuck_test'):
 remaining=[]
 for relative in data.get(key,[]):
  path=root/relative;assert path.is_relative_to(root) and '..' not in Path(relative).parts
  if not path.exists():continue
  busy=any(s==str(path) or s.startswith(str(path)+'/') for s in open_paths)
  rows.append({'path':relative,'busy':busy,'moved':False})
  if args.apply and not busy:
   target=archive/relative;target.parent.mkdir(parents=True,exist_ok=True)
   assert not target.exists();path.rename(target);rows[-1]['moved']=True
  else:remaining.append(relative)
 data[key]=remaining
if args.apply:receipt.write_text(json.dumps(data,indent=2)+'\n')
print(json.dumps(rows,indent=2))
