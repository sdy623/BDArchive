"""Local React bridge. No eval, shell command strings, source deletion, or LAN binding."""
from __future__ import annotations
import importlib.util
import argparse, copy, hashlib, json, mimetypes, os, secrets, sqlite3, subprocess, threading, time, urllib.parse, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
_spec=importlib.util.spec_from_file_location('bd_disc_browser',Path(__file__).with_name('disc_browser.py'))
_browser=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(_browser)
COMMANDS = {'prepare','scan','plan','build','stage','devices','tools','ids','burn','verify','register','restore','summary','init','rename-disc','rename-set','set-counter','split-video','contact-sheet'}
BOOLS = {'Execute','DryRun','Simulate','DetectDuplicates','Deduplicate','MediaReloaded','DeepVerifyDwarfs'}
STRINGS = {'Source','SetId','DiscId','NewDiscId','NewSetId','Scenario','Category','PhotoTier','StartDiscId','Media','Drive','RecorderId','Backend','Location','Summary','Output','Game','Camera','DateRange','Device','SecondCopy','PasswordStorage','VolumeLabelTemplate','Prefix','Reason'}
NUMBERS = {'ParPercent','TargetGiB','NextNumber'}
CONFIG_FIELDS = {'archive_root':str,'nfc_base_url':str,'tools':{'dwarfs':str,'dwarfs_bin':str,'winfsp':str,'imgburn':str,'ffmpeg':str,'mkvmerge':str,'par2':str,'python':str},'planning':{'default_media':str,'par2_percent':float,'reserve_mib':float},'dwarfs':{'build_profile':str,'compression_level':int,'workers':int,'memory_limit':str,'skip_roundtrip':bool},'burn':{'backend':str,'speed':str,'verify_after_write':bool},'numbering':{'volume_label_template':str,'volume_templates':dict},'ui':{'language':str}}
class ApiError(Exception):
    def __init__(self, message, status=400, code='invalid_request'):
        super().__init__(message); self.status=status; self.code=code

def read_json(path, default=None):
    try: return json.loads(Path(path).read_text(encoding='utf-8-sig'))
    except FileNotFoundError: return default

def atomic_json(path, data):
    path=Path(path); temp=path.with_name(path.name+'.'+secrets.token_hex(6)+'.tmp')
    try:
        temp.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8'); os.replace(temp,path)
    finally:
        if temp.exists(): temp.unlink()

def library_paths(config_path, config):
    base=Path(config_path).resolve().parent
    root=Path(config['archive_root'])
    if not root.is_absolute(): root=base/root
    sql=Path(config.get('catalog_path') or str(root/'catalog.sqlite'))
    if not sql.is_absolute(): sql=base/sql
    return root.resolve(), sql.resolve()


def sqlite_snapshot(path):
    # Never call catalog.sync/connect(write) here: selecting a library is read-only.
    con=sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=2)
    try:
        con.row_factory=sqlite3.Row;con.execute('PRAGMA query_only=ON');con.execute('BEGIN')
        tables={r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not {'discs','archive_sets'}<=tables: raise ValueError('Not a BDArchive SQLite catalog')
        discs=[dict(r) for r in con.execute('SELECT * FROM discs')]
        sets=[dict(r) for r in con.execute('SELECT * FROM archive_sets')]
        for table in ('disc_identity','disc_lifecycle'):
            if table in tables:
                extra={r['disc_id']:dict(r) for r in con.execute('SELECT * FROM '+table)}
                for d in discs:d.update(extra.get(d['disc_id'],{}))
        if 'set_details' in tables:
            extra={r['archive_set_id']:json.loads(r['details_json']) for r in con.execute('SELECT * FROM set_details')}
            for a in sets:a['summary_details']=extra.get(a['archive_set_id'],{})
        return {'discs':discs,'sets':sets}
    finally:con.close()


def library_snapshot(config_path, config):
    root,sql=library_paths(config_path,config);source=root/'catalog.json'
    info={'archive_root':str(root),'json_path':str(source),'sqlite_path':str(sql),
          'json_exists':source.is_file(),'sqlite_exists':sql.is_file(),
          'mode':'EMPTY','disc_count':0,'set_count':0,'warnings':[],
          'sqlite_disc_count':None,'sqlite_set_count':None,'index_matches':None}
    data={'discs':[],'sets':[]}
    try:
        indexed=None
        if sql.is_file():
            try:
                indexed=sqlite_snapshot(sql)
                info.update(sqlite_disc_count=len(indexed['discs']),sqlite_set_count=len(indexed['sets']))
            except (OSError,ValueError,KeyError,sqlite3.Error) as e:
                if not source.is_file():raise
                info['warnings'].append('SQLite index unreadable: '+str(e))
        if source.is_file():
            content=read_json(source)
            if not isinstance(content,dict) or content.get('schema_version',1)!=1:raise ValueError('Unsupported JSON catalog schema')
            for collection,key in (('discs','disc_id'),('sets','archive_set_id')):
                rows=content.get(collection)
                if not isinstance(rows,list) or any(not isinstance(d,dict) or not isinstance(d.get(key),str) for d in rows):
                    raise ValueError('Invalid JSON catalog collection: '+collection)
            data={k:content[k] for k in ('discs','sets')};info['mode']='JSON'
            if indexed is not None:
                info['index_matches']=({d['disc_id']:d.get('status') for d in data['discs']}=={d['disc_id']:d.get('status') for d in indexed['discs']} and {d['archive_set_id'] for d in data['sets']}=={d['archive_set_id'] for d in indexed['sets']})
                if not info['index_matches']:info['warnings'].append('JSON and SQLite IDs/status differ; JSON is authoritative. No automatic synchronization performed.')
        elif indexed is not None:
            data=indexed;info['mode']='SQLITE_READ_ONLY'
        info.update(disc_count=len(data['discs']),set_count=len(data['sets']))
    except (OSError,ValueError,TypeError,KeyError,sqlite3.Error) as e:
        info.update(mode='ERROR',error=str(e));data={'discs':[],'sets':[]}
    return data, info


class JobManager:
    def __init__(self, config_path, ui_root=None, pwsh='pwsh', launcher=subprocess.Popen, state_dir=None):
        self.config_path=Path(config_path).resolve(); self.ui_root=Path(ui_root or ROOT/'ui/dist').resolve()
        self.pwsh=pwsh; self.launcher=launcher; self.token=secrets.token_urlsafe(32)
        self.state_dir=Path(state_dir or self.config_path.parent/'work/web-ui').resolve()
        self.jobs={}; self.inventory={}; self.reviews={}; self.lock=threading.RLock(); self.closing=False
    def config(self): return read_json(self.config_path)
    def public_config(self):
        c=self.config(); return {k:c[k] for k in ('archive_root','catalog_path','media','planning','dwarfs','burn','video','numbering','safety','tools','ui') if k in c}
    def catalog(self):
        return library_snapshot(self.config_path,self.config())[0]
    def connect_library(self, body, preview=False):
        with self.lock:
            if self.closing:raise ApiError('Desktop is closing',409)
            if not isinstance(body,dict) or set(body)!={'path'} or not isinstance(body['path'],str):raise ApiError('Provide a library directory, catalog.json or catalog.sqlite')
            raw=body['path'].strip().strip('"')
            if not raw or '\0' in raw or len(raw)>32768:raise ApiError('Invalid library path')
            chosen=Path(raw).expanduser()
            if not chosen.is_absolute():chosen=self.config_path.parent/chosen
            chosen=chosen.resolve()
            c=self.config()
            if chosen.is_file():
                if chosen.name.lower()=='catalog.json':root=chosen.parent;sql=root/'catalog.sqlite'
                elif chosen.suffix.lower() in ('.sqlite','.sqlite3','.db'):root=chosen.parent;sql=chosen
                else:raise ApiError('Select catalog.json or an existing SQLite catalog')
            elif chosen.is_dir():root=chosen;sql=root/'catalog.sqlite'
            else:raise ApiError('Library path does not exist. No catalog was created.')
            c['archive_root']=str(root);c['catalog_path']=str(sql)
            data,info=library_snapshot(self.config_path,c)
            if info['mode'] in ('EMPTY','ERROR'):raise ApiError(info.get('error','No catalog.json or catalog.sqlite in this directory. Nothing was created.'))
            if not preview:
                if any(j['command'] not in ('devices','tools') and j['process'].poll() is None for j in self.jobs.values()):raise ApiError('Wait for archive jobs to finish before switching libraries',409)
                atomic_json(self.config_path,c);self.reviews.clear()
            return {'status':'PREVIEW' if preview else 'CONNECTED','library':info,'catalog':data,'config':self.public_config()}
    def browse_discs(self, args, ident=None):
        catalog=self.catalog();_,sql=library_paths(self.config_path,self.config())
        try:
            if ident is None:return _browser.disc_index(catalog,sql,args)
            rows=[d for d in catalog['discs'] if d['disc_id']==ident]
            if len(rows)!=1:raise ApiError('Disc not found',404)
            archive=next((s for s in catalog['sets'] if s['archive_set_id']==rows[0]['archive_set_id']),{})
            return _browser.disc_contents(rows[0],archive,sql,args)
        except (ValueError,TypeError,sqlite3.Error) as e:raise ApiError(str(e))
    def close(self):
        # Never kill an optical writer on HTTP shutdown. Running jobs retain logs.
        for j in self.jobs.values():
            h=j.get('output_handle')
            if h: h.close()
    def start(self, body):
        with self.lock:
            if self.closing: raise ApiError('Desktop is closing; no new jobs accepted',409)
            if not isinstance(body,dict) or set(body)-{'command','parameters','language','confirmation','review_id'}: raise ApiError('Unsupported request fields')
            command=body.get('command'); p=copy.deepcopy(body.get('parameters',{}))
            if command not in COMMANDS or not isinstance(p,dict): raise ApiError('Unsupported command')
            for k,v in p.items():
                if k in BOOLS:
                    if type(v) is not bool: raise ApiError(k+' must be boolean')
                elif k in STRINGS:
                    if not isinstance(v,str) or len(v)>32768 or '\0' in v: raise ApiError('Invalid '+k)
                elif k in NUMBERS:
                    if type(v) not in (int,float) or not 0<=v<=10000000: raise ApiError('Invalid '+k)
                elif k=='VolumeTemplates':
                    if not isinstance(v,dict) or set(v)-{'iso9660','joliet','system','volume_set','publisher','data_preparer','application'} or any(not isinstance(x,str) for x in v.values()): raise ApiError('Invalid templates')
                else: raise ApiError('Unsupported parameter: '+k)
            if command not in ('devices','tools'):
                _,library=library_snapshot(self.config_path,self.config())
                if library['mode'] in ('SQLITE_READ_ONLY','ERROR'):
                    raise ApiError('Library is read-only or damaged. Restore the complete catalog.json before archive operations; no catalog was initialized.',409)
            p.setdefault('Execute',False)
            if command=='burn' and p['Execute'] and not p.get('DryRun') and not p.get('Simulate'):
                self.authorize_burn(body,p)
            p['Config']=str(self.config_path)
            ident=secrets.token_hex(12); self.state_dir.mkdir(parents=True,exist_ok=True)
            path=self.state_dir/(ident+'.request.json'); atomic_json(path,{'command':command,'parameters':p})
            args=[self.pwsh,'-NoLogo','-NoProfile','-NonInteractive','-File',str(ROOT/'scripts/run-web-request.ps1'),'-RequestPath',str(path)]
            handle=open(str(path)+'.host.log','wb')
            try: proc=self.launcher(args,cwd=str(ROOT),stdin=subprocess.DEVNULL,stdout=handle,stderr=subprocess.STDOUT,shell=False,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            except Exception:
                handle.close(); raise
            self.jobs[ident]={'id':ident,'command':command,'parameters':p,'path':path,'process':proc,'output_handle':handle,'started':time.time(),'cancel_requested':False}
            return self.detail(ident)
    def detail(self, ident):
        j=self.jobs.get(ident)
        if not j: raise ApiError('Job not found',404)
        path=str(j['path']); code=j['process'].poll(); result=read_json(path+'.result.json'); progress=read_json(path+'.progress.json')
        state='CANCEL_REQUESTED' if j['cancel_requested'] else 'RUNNING'
        if code is not None:
            state='FAIL'
            if result and code==0: state='DRY_RUN' if isinstance(result.get('result'),dict) and result['result'].get('status')=='DRY_RUN' else result.get('status','FAIL')
            elif result and code==2: state='CANCELLED'
        def tail(file):
            try:
                with open(file,'rb') as f: f.seek(max(0,os.fstat(f.fileno()).st_size-131072)); return f.read().decode('utf-8-sig',errors='replace')
            except FileNotFoundError:return ''
        log=tail(path+'.log') or tail(path+'.host.log')
        # Tool progress is generated by the trusted worker, never a browser path.
        if progress and progress.get('tool_log'):
            log+='\n'+tail(progress['tool_log'])
        return {'id':ident,'command':j['command'],'state':state,'log':log,'progress':progress,'result':result,'exit_code':code,'started':j['started'],'cancellable':code is None and j['command'] in ('prepare','verify')}
    def cancel(self, ident):
        with self.lock:
            d=self.detail(ident)
            if not d['cancellable']:raise ApiError('This job cannot be safely cancelled',409)
            j=self.jobs[ident]; Path(str(j['path'])+'.cancel').write_text('user requested stop',encoding='utf-8');j['cancel_requested']=True
            return self.detail(ident)
    def bootstrap(self):
        with self.lock:
            for name in ('devices','tools'):
                if name not in self.inventory:self.inventory[name]=self.start({'command':name,'parameters':{}})['id']
            statuses={name:self.detail(ident) for name,ident in self.inventory.items()}
            def values(name):
                d=statuses[name]
                if d['state']!='PASS':return []
                r=(d['result'] or {}).get('result'); return r if isinstance(r,list) else ([r] if r else [])
            catalog,library=library_snapshot(self.config_path,self.config())
            return {'token':self.token,'config':self.public_config(),'library':library,'catalog':catalog,'devices':values('devices'),'tools':values('tools'),'inventory_status':{k:{'id':d['id'],'state':d['state']} for k,d in statuses.items()},'locales':['en','zh-CN'],'capabilities':{'physical_burn':True,'source_delete':False,'catalog_cleanup':False}}
    def burn_review(self, body):
        with self.lock:
            if not isinstance(body,dict) or set(body)-{'DiscId','Drive','RecorderId','Backend'}: raise ApiError('Invalid burn review')
            rows=[x for x in self.catalog()['discs'] if x.get('disc_id')==body.get('DiscId')]
            if len(rows)!=1 or not rows[0].get('stage'):raise ApiError('Select a staged disc first',409)
            devices=self.bootstrap()['devices']
            chosen=[x for x in devices if x.get('drive')==body.get('Drive') and x.get('recorder_id')==body.get('RecorderId')]
            if len(chosen)!=1:raise ApiError('Refresh devices and select the recorder again',409)
            disc=rows[0];stage=disc['stage'];backend=body.get('Backend') or self.config()['burn']['backend']
            if backend not in ('ImgBurn','IMAPI2'):raise ApiError('Unsupported backend')
            bound={'DiscId':body['DiscId'],'Drive':body['Drive'],'RecorderId':body['RecorderId'],'Backend':backend}
            context={'disc_id':body['DiscId'],'drive':body['Drive'],'manifest_sha256':stage.get('hash')}
            if not isinstance(context['manifest_sha256'],str) or len(context['manifest_sha256'])!=64:raise ApiError('Stage is not sealed',409)
            rid=secrets.token_urlsafe(24);self.reviews={k:v for k,v in self.reviews.items() if v['expires']>time.time()}
            self.reviews[rid]={'parameters':bound,'context':context,'expires':time.time()+120,'config_hash':hashlib.sha256(self.config_path.read_bytes()).hexdigest()}
            return {'review_id':rid,'expires_in':120,'disc_id':disc['disc_id'],'archive_set_id':disc.get('archive_set_id'),'drive':bound['Drive'],'backend':backend,'stage':stage,'device':chosen[0],'expected_phrase':'BURN '+disc['disc_id'],'warning':'Irreversible physical write. Exact phrase authorizes this single disc and attempt only.'}
    def authorize_burn(self, body, p):
        review=self.reviews.pop(body.get('review_id',''),None)
        if not review or review['expires']<=time.time():raise ApiError('Fresh burn review required',409,'burn_review_required')
        if any(p.get(k)!=v for k,v in review['parameters'].items()):raise ApiError('Disc or recorder changed. Review again.',409)
        if body.get('confirmation')!='BURN '+p.get('DiscId',''):raise ApiError('Exact user confirmation did not match',409)
        if hashlib.sha256(self.config_path.read_bytes()).hexdigest()!=review['config_hash']:raise ApiError('Settings changed. Review again.',409)
        rows=[d for d in self.catalog()['discs'] if d.get('disc_id')==p['DiscId']]
        if len(rows)!=1 or (rows[0].get('stage') or {}).get('hash')!=review['context']['manifest_sha256']:raise ApiError('Stage changed. Review again.',409)
        p.update(BurnConfirmed=True,ConfirmationMode='Typed',ConfirmationText=body['confirmation'],ConfirmationContext=review['context'])
    def save_config(self, body):
        with self.lock:
            if any(self.detail(k)['exit_code'] is None for k in self.jobs):raise ApiError('Wait for running jobs before saving settings',409)
            if not isinstance(body,dict) or set(body)!={'config'} or not isinstance(body['config'],dict):raise ApiError('Invalid configuration request')
            c=self.config()
            def merge(target,update,schema):
                for key,val in update.items():
                    if key not in schema:raise ApiError('Setting not editable: '+key)
                    rule=schema[key]
                    if isinstance(rule,dict):
                        if not isinstance(val,dict):raise ApiError('Expected object: '+key)
                        target.setdefault(key,{});merge(target[key],val,rule)
                    else:
                        valid=type(val) is rule or rule is float and type(val) in (int,float)
                        if not valid:raise ApiError('Invalid setting type: '+key)
                        if isinstance(val,str) and ('\0' in val or len(val)>32768):raise ApiError('Invalid setting: '+key)
                        if type(val) in (int,float) and not 0<=val<=1000000:raise ApiError('Setting outside allowed range: '+key)
                        if key=='volume_templates' and (set(val)-{'iso9660','joliet','system','volume_set','publisher','data_preparer','application'} or any(not isinstance(x,str) for x in val.values())):raise ApiError('Invalid templates')
                        target[key]=val
            merge(c,body['config'],CONFIG_FIELDS)
            if c['planning']['par2_percent']>100 or c['planning']['default_media'] not in ('BD25','BD50'):raise ApiError('Invalid media/PAR2 settings')
            if c['burn']['backend'] not in ('IMAPI2','ImgBurn'):raise ApiError('Invalid backend')
            if c.get('ui',{}).get('language','en') not in ('en','zh-CN'):raise ApiError('Invalid language')
            if not c['archive_root'].strip():raise ApiError('Archive directory is required')
            if 'archive_root' in body['config'] and c['archive_root']!=self.config()['archive_root']:
                new_root=Path(c['archive_root'])
                if not new_root.is_absolute():new_root=self.config_path.parent/new_root
                if new_root.is_file() or new_root.suffix.lower() in ('.json','.sqlite','.db'):raise ApiError('Use Connect existing library for catalog files, not Archive work directory')
                c['archive_root']=str(new_root.resolve());c['catalog_path']=str(new_root.resolve()/'catalog.sqlite')
            if c['dwarfs']['build_profile'] not in ('fast','verified'):raise ApiError('Invalid DwarFS profile')
            atomic_json(self.config_path,c);self.reviews.clear();self.inventory.clear()
            return {'config':self.public_config(),'status':'SAVED'}

class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,format,*args): pass
    @property
    def manager(self):return self.server.manager
    def headers_for(self,kind,length):
        self.send_header('Content-Type',kind);self.send_header('Content-Length',str(length));self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff');self.send_header('Referrer-Policy','no-referrer')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
    def respond(self,data,status=200):
        raw=json.dumps(data,ensure_ascii=False).encode('utf-8');self.send_response(status);self.headers_for('application/json; charset=utf-8',len(raw));self.wfile.write(raw)
    def guard(self,mutation=False):
        host='127.0.0.1:'+str(self.server.server_port); origin='http://'+host
        if self.headers.get('Host')!=host or self.headers.get('Sec-Fetch-Site')=='cross-site':raise ApiError('Loopback same-origin access only',403)
        sent=self.headers.get('Origin')
        if sent is not None and sent!=origin:raise ApiError('Origin rejected',403)
        if mutation and (sent!=origin or not secrets.compare_digest(self.headers.get('X-Archive-Token',''),self.manager.token)):raise ApiError('Session authorization required',403)
    def do_GET(self):
        try:
            self.guard();path=urllib.parse.urlsplit(self.path).path
            if path=='/api/bootstrap':return self.respond(self.manager.bootstrap())
            if path=='/api/discs' or path.startswith('/api/discs/'):
                args={k:v[-1] for k,v in urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).items()}
                if path=='/api/discs':return self.respond(self.manager.browse_discs(args))
                parts=path.split('/')
                if len(parts)!=5 or parts[4]!='contents':raise ApiError('Not found',404)
                return self.respond(self.manager.browse_discs(args,urllib.parse.unquote(parts[3])))
            if path=='/api/jobs':return self.respond({'jobs':[self.manager.detail(k) for k in list(self.manager.jobs)]})
            if path.startswith('/api/jobs/'):return self.respond(self.manager.detail(path.rsplit('/',1)[-1]))
            if path.startswith('/api/'):raise ApiError('Not found',404)
            decoded=urllib.parse.unquote(path)
            if '%' in decoded or '\\' in decoded or '..' in Path(decoded).parts:raise ApiError('Not found',404)
            if decoded.startswith('/assets/fonts/'):
                base=(ROOT/'assets/fonts').resolve();target=(base/decoded.removeprefix('/assets/fonts/')).resolve()
            else:
                base=self.manager.ui_root;target=(base/('index.html' if decoded=='/' else decoded.lstrip('/'))).resolve()
            if not target.is_relative_to(base) or not target.is_file():raise ApiError('Not found',404)
            data=target.read_bytes();kind=mimetypes.guess_type(target)[0] or 'application/octet-stream'
            if target.suffix in ('.js','.mjs'):kind='text/javascript'
            self.send_response(200);self.headers_for(kind,len(data));self.wfile.write(data)
        except ApiError as e:self.respond({'error':str(e),'code':e.code},e.status)
        except (OSError,ValueError,TypeError,KeyError) as e:self.respond({'error':str(e),'code':'read_failed'},500)
    def do_POST(self):
        try:
            self.guard(True)
            if self.headers.get_content_type()!='application/json':raise ApiError('JSON required',415)
            size=int(self.headers.get('Content-Length','0'))
            if size<0 or size>65536:raise ApiError('Request too large',413)
            body=json.loads(self.rfile.read(size));path=urllib.parse.urlsplit(self.path).path
            if path=='/api/jobs':return self.respond(self.manager.start(body),202)
            if path.startswith('/api/jobs/') and path.endswith('/cancel'):return self.respond(self.manager.cancel(path.split('/')[-2]),202)
            if path=='/api/library/preview':return self.respond(self.manager.connect_library(body,preview=True))
            if path=='/api/library/connect':return self.respond(self.manager.connect_library(body))
            if path=='/api/config':return self.respond(self.manager.save_config(body))
            if path=='/api/burn-review':return self.respond(self.manager.burn_review(body))
            if path=='/api/refresh-inventory':
                with self.manager.lock:self.manager.inventory.clear()
                return self.respond(self.manager.bootstrap())
            raise ApiError('Not found',404)
        except ApiError as e:self.respond({'error':str(e),'code':e.code},e.status)
        except (ValueError,TypeError,KeyError) as e:self.respond({'error':str(e),'code':'invalid_request'},400)
        except OSError as e:self.respond({'error':str(e),'code':'execution_error'},500)

def make_server(manager,port=18765):
    server=ThreadingHTTPServer(('127.0.0.1',port),Handler);server.manager=manager;return server

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--config',required=True);parser.add_argument('--port',type=int,default=18765);parser.add_argument('--pwsh',default='pwsh');parser.add_argument('--no-open',action='store_true');parser.add_argument('--language',choices=['en','zh-CN'],default='zh-CN');parser.add_argument('--state-dir')
    args=parser.parse_args();manager=JobManager(args.config,pwsh=args.pwsh,state_dir=args.state_dir)
    if not (manager.ui_root/'index.html').is_file():raise SystemExit('Build the frontend first: cd ui && npm ci && npm run build')
    server=make_server(manager,args.port);url=f'http://127.0.0.1:{server.server_port}/?lang={args.language}';print(url,flush=True)
    if not args.no_open:webbrowser.open(url)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close();manager.close()
if __name__=='__main__':main()
