"""Read-only catalog browsing. Never opens source payloads or initializes a DB."""
from pathlib import Path, PurePosixPath
from datetime import datetime, timezone, date
from collections import Counter
import json
import re
import sqlite3

DATE=re.compile(r'(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)')

def sql_content(path, disc_id=None):
    files={};events={}
    if not path.is_file():return files,events
    con=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=2)
    try:
        con.row_factory=sqlite3.Row;con.execute('PRAGMA query_only=ON');con.execute('BEGIN')
        tables={r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        for table,dest in (('content_files',files),('content_events',events)):
            if table not in tables:continue
            rows=con.execute('SELECT * FROM '+table+(' WHERE disc_id=?' if disc_id else ''),(disc_id,) if disc_id else ())
            for row in rows:dest.setdefault(row['disc_id'],[]).append(dict(row))
        return files,events
    finally:con.close()

def stored_time(value):
    if value is None:return None
    s=str(value)
    if s.isdigit():
        try:return datetime.fromtimestamp(int(s)/10000000-62135596800,tz=timezone.utc).isoformat()
        except (ValueError,OverflowError,OSError):return s
    return s

def receipt_files(disc):
    rows=((disc.get('stage') or {}).get('receipt') or {}).get('files')
    if not isinstance(rows,list):return None
    return [{'path':str(f['path']),'bytes':f.get('bytes',f.get('size')),'mtime':stored_time(f.get('mtime',f.get('mtime_utc'))),'sha256':f.get('sha256')} for f in rows if isinstance(f,dict) and isinstance(f.get('path'),str)]

def payload_dates(files):
    dates=[]
    for f in files or []:
        # Directory labels, not EXIF acquisition times. Keep the evidence distinction.
        dates+=DATE.findall(f['path'])
    return sorted(set(dates))

def summary_row(disc, archive, indexed=None, events=None):
    details=archive.get('summary_details') or {};files=receipt_files(disc)
    if files is None and indexed:files=[{'path':f['filename'],'bytes':f.get('bytes')} for f in indexed]
    dates=payload_dates(files)
    date_basis='directory_labels'
    if not dates:
        dates=sorted(set(DATE.findall(str(details.get('date_range') or details.get('backup_date') or ''))));date_basis='archive_metadata'
    category=disc.get('category') or archive.get('category') or {'P':'I','G':'II','B':'III','M':'M'}.get(str(disc.get('disc_prefix','')),'')
    if not category:
        category=next((v for k,v in {'BD-P-':'I','BD-G-':'II','BD-B-':'III','BD-M-':'M'}.items() if disc['disc_id'].startswith(k)),'')
    row={k:disc.get(k) for k in ('disc_id','archive_set_id','disc_index','position','disc_count','volume_label','volume_id','status','location','burn_date','media_type','original_deleted')}
    row.update(category=category,summary=archive.get('summary') or '',metadata=details,
        content_date_from=dates[0] if dates else None,content_date_to=dates[-1] if dates else None,date_basis=date_basis,
        indexed_files=len(files) if files is not None else None,bytes=(disc.get('stage') or {}).get('bytes'),
        search_text=' '.join([str(x) for x in row.values()]+[str(archive.get('summary','')),json.dumps(details,ensure_ascii=False)]+[x['path'] for x in files or []]+[str(e.get('title',''))+' '+str(e.get('description','')) for e in events or []]).casefold())
    return row

def page_args(args,default=10,maximum=100):
    page=int(args.get('page','1'));size=int(args.get('page_size',str(default)))
    if page<1 or not 1<=size<=maximum:raise ValueError('Invalid page/page_size')
    return page,size

def date_arg(raw):
    if not raw:return None
    if len(raw)!=10:raise ValueError('Use YYYY-MM-DD')
    return date.fromisoformat(raw).isoformat()

def disc_index(catalog,sql_path,args):
    page,size=page_args(args);q=args.get('q','').strip().casefold()
    if len(q)>512:raise ValueError('Search is too long')
    status=args.get('status','');category=args.get('category','');sort=args.get('sort','index')
    statuses=sorted({str(d.get('status','')) for d in catalog['discs']})
    if status and status not in statuses:raise ValueError('Unknown status')
    if category and category not in ('I','II','III','M'):raise ValueError('Unknown category')
    if sort not in ('index','index_desc','date_desc','burn_desc'):raise ValueError('Invalid sort')
    lower=date_arg(args.get('date_from'));upper=date_arg(args.get('date_to'));kind=args.get('date_kind','content')
    if kind not in ('content','burn'):raise ValueError('Invalid date kind')
    if lower and upper and lower>upper:raise ValueError('Date range reversed')
    sets={s['archive_set_id']:s for s in catalog['sets']};warning=[]
    try:files,events=sql_content(sql_path)
    except (OSError,ValueError,sqlite3.Error) as e:files={};events={};warning.append(str(e))
    selected=[]
    for d in catalog['discs']:
        if d.get('catalog_deleted'):continue
        r=summary_row(d,sets.get(d['archive_set_id'],{}),files.get(d['disc_id']),events.get(d['disc_id']))
        if status and r['status']!=status or category and r['category']!=category:continue
        if q and not all(term in r['search_text'] for term in q.split()):continue
        start,end=((r.get('burn_date') or '')[:10],(r.get('burn_date') or '')[:10]) if kind=='burn' else (r['content_date_from'],r['content_date_to'])
        if (lower and (not end or end<lower)) or (upper and (not start or start>upper)):continue
        r.pop('search_text');selected.append(r)
    selected.sort(key=lambda r:(r.get('disc_index') or 0,r['disc_id']))
    if sort=='index_desc':selected.reverse()
    elif sort in ('date_desc','burn_desc'):selected.sort(key=lambda r:r.get('content_date_to' if sort=='date_desc' else 'burn_date') or '',reverse=True)
    total=len(selected);pages=max(1,(total+size-1)//size);page=min(page,pages)
    return {'items':selected[(page-1)*size:page*size],'total':total,'page':page,'page_size':size,'pages':pages,'statuses':statuses,'warnings':warning}

def disc_contents(disc,archive,sql_path,args):
    page,size=page_args(args,25,100);q=args.get('q','').strip().casefold();folder=args.get('folder','')
    if len(q)>512 or len(folder)>32768:raise ValueError('Search is too long')
    files=receipt_files(disc);source='catalog_receipt' if files is not None else 'unavailable';warnings=[];events=[]
    try:
        indexed,event_map=sql_content(sql_path,disc['disc_id']);events=event_map.get(disc['disc_id'],[])
        if files is None and indexed.get(disc['disc_id']):
            files=[{'path':f['filename'],'bytes':f.get('bytes'),'sha256':f.get('sha256'),'mtime':None} for f in indexed[disc['disc_id']]];source='sqlite_content_files'
    except (OSError,ValueError,sqlite3.Error) as e:warnings.append(str(e))
    if files is None:
        # Small sealed text manifest only; never mount DwarFS, read payloads or scan sources.
        stage=disc.get('stage') or {};path=Path(stage['path'])/'SHA256SUMS' if stage.get('path') else None
        if path and path.is_file() and path.stat().st_size<=8*1024*1024:
            files=[]
            for line in path.read_text(encoding='utf-8-sig').splitlines():
                m=re.fullmatch(r'([a-fA-F0-9]{64})  (.+)',line)
                if m:files.append({'path':m[2],'bytes':None,'sha256':m[1],'mtime':None})
            source='staging_manifest'
        else:warnings.append('No retained per-disc file index. This does not mean the disc is empty. Reinsert the disc or restore its metadata index; no payload scan was performed.')
    all_files=files or [];folders=Counter()
    for f in all_files:
        parent=str(PurePosixPath(f['path'].replace('\\','/')).parent)
        folders[parent]+=1
    matches=[f for f in all_files if (not q or all(term in f['path'].casefold() for term in q.split())) and (not folder or str(PurePosixPath(f['path'].replace('\\','/')).parent)==folder)]
    matches.sort(key=lambda f:f['path'].casefold());total=len(matches);pages=max(1,(total+size-1)//size);page=min(page,pages)
    summary=summary_row(disc,archive);summary.pop('search_text')
    return {'disc':summary,'scope':'disc','archive_summary':archive.get('summary') or '', 'metadata':archive.get('summary_details') or {},'metadata_scope':'archive_set','source':source,'indexed_files':len(all_files) if files is not None else None,'indexed_bytes':sum(f.get('bytes') or 0 for f in all_files) if all(f.get('bytes') is not None for f in all_files) else None,'files':matches[(page-1)*size:page*size],'total':total,'page':page,'page_size':size,'pages':pages,'folders':[{'path':p,'count':n} for p,n in sorted(folders.items())], 'events':events,'warnings':warnings,'note':'Stored metadata only, not a new optical verification. Times are stored file mtimes; directory dates are labels, not EXIF. DwarFS is listed as a container, not extracted.'}
