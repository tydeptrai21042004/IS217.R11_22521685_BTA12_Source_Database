#!/usr/bin/env python3
from __future__ import annotations
import argparse, codecs, csv, hashlib, io, json, sys, time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
DATASET_ID='erm2-nwe9'; BASE=f'https://data.cityofnewyork.us/resource/{DATASET_ID}.json'
FIELDS=['unique_key','created_date','closed_date','agency','agency_name','complaint_type','descriptor','location_type','incident_zip','city','borough','status','latitude','longitude']
HEADER=['UniqueKey','CreatedDate','ClosedDate','Agency','AgencyName','ComplaintType','Descriptor','LocationType','IncidentZip','City','Borough','Status','Latitude','Longitude']; UA='UIT-IS217-BTA12/2.0'
def parse():
 p=argparse.ArgumentParser(); p.add_argument('--start-date',default='2025-01-15'); p.add_argument('--lookback-days',type=int,default=60); p.add_argument('--max-bytes',type=int,default=50_000_000); p.add_argument('--page-size',type=int,default=5000); p.add_argument('--output',required=True); p.add_argument('--manifest',required=True); return p.parse_args()
def get(params,retries=5):
 url=BASE+'?'+urlencode(params)
 for i in range(retries):
  try:
   with urlopen(Request(url,headers={'User-Agent':UA}),timeout=120) as r: return json.loads(r.read().decode())
  except (HTTPError,URLError,TimeoutError):
   if i==retries-1: raise
   time.sleep(min(2**i,12))
def wh(d):
 a=d.isoformat()+'T00:00:00.000'; b=(d+timedelta(days=1)).isoformat()+'T00:00:00.000'; return f"created_date >= '{a}' AND created_date < '{b}'"
def count(d): return int(get({'$select':'count(*) as n','$where':wh(d)})[0]['n'])
def page(d,limit,offset): return get({'$select':','.join(FIELDS),'$where':wh(d),'$order':'unique_key ASC','$limit':str(limit),'$offset':str(offset)})
def rowbytes(vals):
 s=io.StringIO(newline=''); csv.writer(s,lineterminator='\n').writerow(vals); return s.getvalue().encode()
def norm(r): return ['' if r.get(k) is None else str(r.get(k,'')).strip() for k in FIELDS]
def estimate(d,n):
 rows=page(d,min(300,n),0)
 if not rows:return 0
 avg=sum(len(rowbytes(norm(r))) for r in rows)/len(rows); return int(3+len(rowbytes(HEADER))+avg*n*1.20)
def attempt(d,n,out,cap,pg):
 tmp=out.with_suffix(out.suffix+'.partial'); tmp.unlink(missing_ok=True); out.unlink(missing_ok=True); seen=set(); written=0; total=0
 try:
  with tmp.open('wb') as f:
   for blob in (codecs.BOM_UTF8,rowbytes(HEADER)):
    if total+len(blob)>cap:return None
    f.write(blob); total+=len(blob)
   off=0
   while written<n:
    rows=page(d,min(pg,n-written),off)
    if not rows:break
    for r in rows:
     key=str(r.get('unique_key','')).strip()
     if not key: raise RuntimeError('missing unique_key')
     if key in seen: raise RuntimeError(f'duplicate unique_key {key}')
     seen.add(key); blob=rowbytes(norm(r))
     if total+len(blob)>cap: print(f'[SKIP] {d}: exact CSV exceeds hard cap'); return None
     f.write(blob); total+=len(blob); written+=1
    off+=len(rows); print(f'[INFO] {d} rows={written:,}/{n:,} bytes={total:,}/{cap:,}')
  if written!=n: raise RuntimeError(f'incomplete download expected={n} got={written}')
  tmp.replace(out); return total
 finally:
  tmp.unlink(missing_ok=True)
def verify(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''): h.update(b)
 with p.open('r',encoding='utf-8-sig',newline='') as f:
  r=csv.reader(f); hdr=next(r); c=sum(1 for _ in r)
 if hdr!=HEADER: raise RuntimeError('bad header')
 return c,h.hexdigest(),p.stat().st_size
def main():
 a=parse(); start=date.fromisoformat(a.start_date); out=Path(a.output).resolve(); man=Path(a.manifest).resolve(); out.parent.mkdir(parents=True,exist_ok=True); man.parent.mkdir(parents=True,exist_ok=True)
 if a.max_bytes>50_000_000: raise RuntimeError('max-bytes cannot exceed 50,000,000')
 cand=[]; print(f'[INFO] Scanning {a.lookback_days} days; hard cap={a.max_bytes:,} bytes')
 for i in range(a.lookback_days):
  d=start-timedelta(days=i)
  try:
   n=count(d)
   if n<=0:continue
   est=estimate(d,n); print(f'[SCAN] {d} rows={n:,} estimate={est:,}')
   if est<=a.max_bytes: cand.append((n,d,est))
  except Exception as e: print(f'[WARN] {d}: {e}')
 if not cand: raise RuntimeError('No complete-day candidate estimated under hard cap')
 cand.sort(reverse=True,key=lambda x:x[0]); chosen=None
 for n,d,est in cand:
  print(f'[TRY] {d} complete day ({n:,} rows)'); size=attempt(d,n,out,a.max_bytes,a.page_size)
  if size is not None:
   c,sha,actual=verify(out)
   if c!=n or actual>a.max_bytes: raise RuntimeError('verification invariant failed')
   chosen=(d,n,actual,sha); break
 if not chosen: raise RuntimeError('All candidates exceeded exact cap; no truncated file retained')
 d,n,actual,sha=chosen; m={'source':'NYC Open Data','dataset_id':DATASET_ID,'selected_complete_day':str(d),'sampling':False,'truncation':False,'rows_expected':n,'rows_verified':n,'hard_cap_bytes':a.max_bytes,'file_size_bytes':actual,'file_size_mb_decimal':round(actual/1_000_000,4),'sha256':sha,'file':str(out),'columns':HEADER,'generated_at_utc':datetime.now(timezone.utc).replace(microsecond=0).isoformat()}; man.write_text(json.dumps(m,indent=2)); print('[PASS] Complete real dataset selected.'); print(json.dumps(m,indent=2))
if __name__=='__main__':
 try: main()
 except Exception as e: print(f'[FAIL] {e}',file=sys.stderr); raise
