"""Portable EXE entry: bundled Python, installed/built-in PowerShell, loopback only."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]

def ensure_config(root, explicit=None):
    root = Path(root).resolve()
    if explicit:
        path = Path(explicit).resolve()
        if not path.is_file(): raise FileNotFoundError('Configuration not found: ' + str(path))
        return path
    path = root/'archive.config.json'
    if path.is_file(): return path
    runtime = root/'runtime/python/python.exe'
    if not runtime.is_file(): raise FileNotFoundError('Keep the complete portable folder: ' + str(runtime))
    data = json.loads((root/'archive.config.example.json').read_text(encoding='utf-8-sig'))
    data['tools']['python'] = './runtime/python/python.exe'
    # Never overwrite an existing user config, even if another startup races us.
    try:
        with path.open('x',encoding='utf-8') as f: json.dump(data,f,ensure_ascii=False,indent=2)
    except FileExistsError: pass
    return path

def find_powershell(explicit=None):
    if explicit:
        p = Path(explicit).resolve()
        if not p.is_file(): raise FileNotFoundError('PowerShell not found: '+str(p))
        return str(p)
    candidates = [Path(os.environ.get('ProgramFiles','C:/Program Files'))/'PowerShell/7/pwsh.exe']
    found = shutil.which('pwsh.exe') or shutil.which('pwsh')
    if found: candidates.append(Path(found))
    candidates.append(Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe')
    for p in candidates:
        if p.is_file(): return str(p)
    raise FileNotFoundError('PowerShell is unavailable. Install PowerShell 7 or enable Windows PowerShell 5.1.')

def load_bridge(root=ROOT):
    spec = importlib.util.spec_from_file_location('bd_workbench',Path(__file__).with_name('workbench.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    module.ROOT = Path(root).resolve()
    return module

def open_server(bridge,manager,port):
    class PortableServer(bridge.ThreadingHTTPServer):
        allow_reuse_address = False
        def server_bind(self):
            if hasattr(socket,'SO_EXCLUSIVEADDRUSE'):
                self.socket.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
            super().server_bind()
    def create(number):
        server=PortableServer(('127.0.0.1',number),bridge.Handler)
        server.manager=manager
        return server
    try: return create(port)
    except OSError as e:
        # Windows exclusive bind may return WSAEACCES when another server uses SO_REUSEADDR.
        if port and (e.errno in (13,48,98,10013,10048) or getattr(e,'winerror',None) in (10013,10048)):
            return create(0)
        raise

def is_idle(manager):
    return all(j['process'].poll() is not None for j in list(manager.jobs.values()))

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config'); parser.add_argument('--pwsh')
    parser.add_argument('--port',type=int,default=18765)
    parser.add_argument('--language',choices=['en','zh-CN'],default='zh-CN')
    parser.add_argument('--no-open',action='store_true')
    parser.add_argument('--self-test',action='store_true',help='Read-only runtime diagnostic; no server or archive creation')
    parser.add_argument('--ready-file',help='Optional readiness JSON for unattended testing')
    parser.add_argument('--stop-file',help='Exit when this file exists and all workers are idle')
    args=parser.parse_args(argv)
    if not 0 <= args.port <= 65535: parser.error('port must be between 0 and 65535')
    os.chdir(ROOT)
    os.environ['PATH']=str(ROOT/'runtime/python')+os.pathsep+os.environ.get('PATH','')
    os.environ['PYTHONUTF8']='1'
    pwsh=find_powershell(args.pwsh)
    if args.self_test:
        import sqlite3, ssl, plistlib, tarfile
        assert (ROOT/'ui/dist/index.html').is_file(), 'Missing compiled frontend'
        assert (ROOT/'scripts/run-web-request.ps1').is_file(), 'Missing PowerShell worker'
        sqlite3.connect(':memory:').close()
        print(json.dumps({'status':'PASS','python':sys.version.split()[0],'runtime':sys.executable,'root':str(ROOT),'pwsh':pwsh,'default_execute':False,'archive_created':False},ensure_ascii=False),flush=True)
        return 0
    config=ensure_config(ROOT,args.config)
    bridge=load_bridge(); manager=bridge.JobManager(config,pwsh=pwsh)
    server=open_server(bridge,manager,args.port)
    url=f'http://127.0.0.1:{server.server_port}/?lang={args.language}'
    stopped=threading.Event()
    if args.stop_file:
        def watch():
            while not stopped.wait(0.25):
                with manager.lock:
                    stop_requested=Path(args.stop_file).exists() and is_idle(manager)
                    if stop_requested: manager.closing=True
                if stop_requested:
                    server.shutdown();return
        threading.Thread(target=watch,daemon=True).start()
    if args.ready_file:
        bridge.atomic_json(Path(args.ready_file),{'url':url,'pid':os.getpid(),'config':str(config),'pwsh':pwsh})
    print('BD Archive Toolkit / Portable EXE\n'+url,flush=True)
    print('Desktop backend ready; no external browser will be opened.',flush=True)
    try:server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:pass
    finally:
        stopped.set();server.server_close();manager.close()
    return 0

if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,AssertionError) as e:
        print('Startup failed: '+str(e),file=sys.stderr,flush=True);sys.exit(1)
