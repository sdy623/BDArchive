"""Build a Windows x64 portable EXE with official embedded Python; no global install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT=Path(__file__).resolve().parents[1]
PYTHON_URL='https://www.python.org/ftp/python/3.14.8/python-3.14.8-embed-amd64.zip'
PYTHON_SHA256='a93abe456ab01bd96d7a085b3cdb6566b3063f4241360d114142fbdb07f0a310'
WEBVIEW_SHA256='56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9'

def build(python_zip, output, compiler, webview_zip):
    python_zip=Path(python_zip).resolve();output=Path(output).resolve()
    webview_zip=Path(webview_zip).resolve()
    if hashlib.sha256(webview_zip.read_bytes()).hexdigest()!=WEBVIEW_SHA256:raise ValueError('WebView2 SDK hash mismatch')
    if output.exists():raise FileExistsError('Use a fresh output directory; user files are never overwritten: '+str(output))
    if hashlib.sha256(python_zip.read_bytes()).hexdigest()!=PYTHON_SHA256:raise ValueError('Embedded Python download hash mismatch')
    if not (ROOT/'ui/dist/index.html').is_file():raise FileNotFoundError('Build ui/dist first')
    output.mkdir(parents=True)
    # Explicit source allowlist: never private configs, archives, logs, tests or caches.
    for name in ('scripts','catalog','locales','assets','examples','packaging'):
        shutil.copytree(ROOT/name,output/name,ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.log','*.tmp'))
    shutil.copytree(ROOT/'ui/dist',output/'ui/dist')
    for doc in list(ROOT.glob('*.md'))+list(ROOT.glob('*.bat')):
        shutil.copy2(doc,output/doc.name)
    shutil.copytree(ROOT/'docs',output/'docs')
    for name in ('LICENSE','VERSION','archive.config.example.json'):
        if (ROOT/name).is_file():shutil.copy2(ROOT/name,output/name)
    shutil.copy2(ROOT/'ui/THIRD_PARTY_LICENSES.txt',output/'FRONTEND-LICENSES.txt')
    shutil.copy2(ROOT/'packaging/PORTABLE.md',output/'START-HERE.md')
    runtime=output/'runtime/python';runtime.mkdir(parents=True)
    with zipfile.ZipFile(python_zip) as z:
        assert z.testzip() is None
        for member in z.infolist():
            target=(runtime/member.filename).resolve()
            if not target.is_relative_to(runtime):raise ValueError('Unsafe ZIP entry')
        z.extractall(runtime)
    sig_script="foreach($p in @('python.exe','python314.dll')) {$s=Get-AuthenticodeSignature -LiteralPath (Join-Path $args[0] $p); if($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'Python Software Foundation'){throw ('Runtime signature invalid: '+$p)}; Write-Output ($p+': '+$s.Status)}"
    # Prefer PowerShell 7 for Authenticode checks; fall back to the Windows host.
    verify=[str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-NonInteractive']
    # A script file preserves Unicode and spaces without command-string interpolation.
    check=output/'check-runtime-signatures.ps1';check.write_text(sig_script,encoding='utf-8-sig')
    verify=verify[:3]+['-File',str(check),str(runtime)]
    verify[0]=shutil.which('pwsh.exe') or shutil.which('pwsh') or verify[0]
    env=os.environ.copy();env.pop('PSModulePath',None)
    result=subprocess.run(verify,capture_output=True,text=True,env=env)
    if result.returncode:raise RuntimeError(result.stdout+result.stderr)
    print(result.stdout,end='');check.unlink()
    with zipfile.ZipFile(webview_zip) as z:
        assert z.testzip() is None
        for source,name in [('lib/net462/Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.Core.dll'),('lib/net462/Microsoft.Web.WebView2.WinForms.dll','Microsoft.Web.WebView2.WinForms.dll'),('runtimes/win-x64/native/WebView2Loader.dll','WebView2Loader.dll'),('LICENSE.txt','WEBVIEW2-LICENSE.txt')]:
            (output/name).write_bytes(z.read(source))
    cmd=[str(compiler),'/nologo','/target:winexe','/platform:x64','/optimize+','/utf8output','/win32manifest:'+str(ROOT/'packaging/app.manifest'),'/win32icon:'+str(ROOT/'assets/branding/bdarchive.ico'),'/out:'+str(output/'BDArchive.exe'),'/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Net.Http.dll','/reference:System.Web.Extensions.dll','/reference:'+str(output/'Microsoft.Web.WebView2.Core.dll'),'/reference:'+str(output/'Microsoft.Web.WebView2.WinForms.dll'),str(ROOT/'packaging/Launcher.cs')]
    subprocess.run(cmd,check=True)
    source={'application_version':(ROOT/'VERSION').read_text(encoding='utf-8').strip(),'python_url':PYTHON_URL,'python_zip_sha256':PYTHON_SHA256,'python_signature':'Valid / Python Software Foundation','launcher_signed':False,'ui':'Standalone WebView2 desktop window (no external browser)','webview2_sdk':'1.0.4258.31','webview2_package_sha256':WEBVIEW_SHA256,'requires':'Windows 10/11 x64, built-in .NET Framework; PowerShell 7 recommended; 5.1 fallback','third_party_archive_tools':'Not bundled'}
    (output/'RUNTIME-SOURCES.json').write_text(json.dumps(source,indent=2)+'\n',encoding='utf-8')
    print('BUILD',output/'BDArchive.exe')
    return output

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--python-zip',required=True);p.add_argument('--output',required=True);p.add_argument('--webview-zip',required=True);p.add_argument('--compiler',default=r'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe')
    a=p.parse_args();build(a.python_zip,a.output,a.compiler,a.webview_zip)
