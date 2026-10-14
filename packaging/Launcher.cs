// Standalone desktop window. Never launches a browser, shell URL, or console.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
[assembly: AssemblyTitle("BDArchive")]
[assembly: AssemblyProduct("BDArchive")]
[assembly: AssemblyVersion("0.3.0.0")]
[assembly: AssemblyFileVersion("0.3.0.0")]
[assembly: AssemblyInformationalVersion("0.3.0")]
public static class Launcher {
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    public static string Quote(string value) {
        var b=new StringBuilder("\""); int slashes=0;
        foreach(char ch in value) {
            if(ch=='\\') {slashes++;continue;}
            if(ch=='\"') {b.Append('\\',slashes*2+1);b.Append(ch);slashes=0;continue;}
            b.Append('\\',slashes);slashes=0;b.Append(ch);
        }
        b.Append('\\',slashes*2);b.Append('"');return b.ToString();
    }
    [STAThread]
    public static int Main(string[] args) {
        try {
            try {SetProcessDpiAwarenessContext(new IntPtr(-4));} catch(EntryPointNotFoundException) {}
            Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
            using(var window=new ArchiveWindow(args)) {Application.Run(window);return window.ExitCode;}
        } catch(Exception ex) {
            try {Directory.CreateDirectory(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"work"));File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"work","desktop-host-error.txt"),ex.ToString());} catch {}
            MessageBox.Show("无法启动 / Cannot start: "+ex.Message,"BDArchive",MessageBoxButtons.OK,MessageBoxIcon.Error);
            return 1;
        }
    }
}
public sealed class ArchiveWindow : Form {
    readonly string root=AppDomain.CurrentDomain.BaseDirectory;
    readonly JavaScriptSerializer json=new JavaScriptSerializer();
    readonly WebView2 view=new WebView2();
    readonly Label message=new Label();
    readonly string[] args;
    string session,readyFile,stopFile,origin,smokeReport;
    Process backend;
    StreamWriter output,error;
    bool allowClose,closing,ready,testing,cleaned;
    public int ExitCode {get;private set;}
    public ArchiveWindow(string[] input) {
        Icon=new Icon(Path.Combine(root,"assets","branding","bdarchive.ico"),new Size(64,64));
        args=input; Text="BDArchive";StartPosition=FormStartPosition.CenterScreen;
        ClientSize=new Size(1180,800);MinimumSize=new Size(760,580);AutoScaleMode=AutoScaleMode.Dpi;
        BackColor=Color.FromArgb(18,23,29);view.Dock=DockStyle.Fill;
        message.Dock=DockStyle.Fill;message.ForeColor=Color.White;message.TextAlign=ContentAlignment.MiddleCenter;
        message.Font=new Font("Segoe UI",12);message.Text="正在启动归档工具… / Starting archive toolkit…";
        Controls.Add(view);Controls.Add(message);
        int test=Array.IndexOf(args,"--desktop-smoke-test");
        if(test>=0 && test+1<args.Length) {testing=true;smokeReport=Path.GetFullPath(args[test+1]);ShowInTaskbar=false;Opacity=0;}
        Shown+=async delegate {
            var area=Screen.FromControl(this).WorkingArea;
            int width=Math.Min((int)(area.Width*0.9),1800),height=Math.Min((int)(area.Height*0.9),1200);
            Bounds=new Rectangle(area.Left+(area.Width-width)/2,area.Top+(area.Height-height)/2,width,height);
            await StartAsync();
        };
        FormClosing+=async delegate(object sender,FormClosingEventArgs e) {
            if(allowClose)return; e.Cancel=true;
            if(!closing)await CloseSafelyAsync();
        };
    }
    async Task StartAsync() {
        try {
            // Missing runtime fails locally. No automatic download or external browser fallback.
            string runtimeVersion=CoreWebView2Environment.GetAvailableBrowserVersionString();
            var forward=new List<string>();
            for(int i=0;i<args.Length;i++) {
                if(args[i]=="--desktop-smoke-test") {i++;continue;}
                if(args[i]!="--config" && args[i]!="--language" && args[i]!="--pwsh")throw new ArgumentException("Unsupported option: "+args[i]);
                if(i+1>=args.Length)throw new ArgumentException("Missing option value");
                forward.Add(args[i]);forward.Add(args[++i]);
            }
            session=Path.Combine(root,"work","desktop",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(session);
            readyFile=Path.Combine(session,"ready.json");stopFile=Path.Combine(session,"stop.signal");
            string python=Path.Combine(root,"runtime","python","python.exe");
            string entry=Path.Combine(root,"catalog","desktop_entry.py");
            if(!File.Exists(python)||!File.Exists(entry))throw new FileNotFoundException("请解压完整程序包 / Extract the complete package first.");
            var command=new StringBuilder("-I -B -u -X utf8 "+Launcher.Quote(entry));
            foreach(string value in forward)command.Append(" "+Launcher.Quote(value));
            command.Append(" --no-open --port 0 --ready-file "+Launcher.Quote(readyFile)+" --stop-file "+Launcher.Quote(stopFile));
            var start=new ProcessStartInfo(python,command.ToString());
            start.UseShellExecute=false;start.CreateNoWindow=true;start.WorkingDirectory=root;
            start.RedirectStandardOutput=true;start.RedirectStandardError=true;
            start.StandardOutputEncoding=Encoding.UTF8;start.StandardErrorEncoding=Encoding.UTF8;
            output=new StreamWriter(Path.Combine(session,"backend.stdout.txt"),false,new UTF8Encoding(false));output.AutoFlush=true;
            error=new StreamWriter(Path.Combine(session,"backend.stderr.txt"),false,new UTF8Encoding(false));error.AutoFlush=true;
            backend=new Process();backend.StartInfo=start;
            backend.OutputDataReceived+=delegate(object s,DataReceivedEventArgs e){if(e.Data!=null)lock(output)output.WriteLine(e.Data);};
            backend.ErrorDataReceived+=delegate(object s,DataReceivedEventArgs e){if(e.Data!=null)lock(error)error.WriteLine(e.Data);};
            backend.Start();backend.BeginOutputReadLine();backend.BeginErrorReadLine();
            for(int i=0;i<300&&!File.Exists(readyFile);i++) {
                if(backend.HasExited)throw new InvalidOperationException("Backend stopped. See "+session);
                await Task.Delay(100);
            }
            if(!File.Exists(readyFile))throw new TimeoutException("Backend startup timed out. See "+session);
            if(closing||IsDisposed)return;
            var state=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(readyFile,Encoding.UTF8));
            Uri address=new Uri((string)state["url"]);
            if(address.Scheme!="http"||address.Host!="127.0.0.1")throw new InvalidOperationException("Invalid local backend URL");
            origin=address.GetLeftPart(UriPartial.Authority);ready=true;
            var environment=await CoreWebView2Environment.CreateAsync(null,Path.Combine(root,"work","webview2"));
            await view.EnsureCoreWebView2Async(environment);
            var core=view.CoreWebView2;
            core.Settings.AreDevToolsEnabled=false;core.Settings.AreDefaultContextMenusEnabled=false;
            core.Settings.AreBrowserAcceleratorKeysEnabled=false;core.Settings.IsStatusBarEnabled=false;
            core.Settings.IsWebMessageEnabled=false;core.Settings.AreHostObjectsAllowed=false;
            core.Settings.IsPasswordAutosaveEnabled=false;core.Settings.IsGeneralAutofillEnabled=false;
            core.NavigationStarting+=delegate(object sender,CoreWebView2NavigationStartingEventArgs e) {
                Uri target; if(!Uri.TryCreate(e.Uri,UriKind.Absolute,out target)||target.GetLeftPart(UriPartial.Authority)!=origin)e.Cancel=true;
            };
            core.NewWindowRequested+=delegate(object sender,CoreWebView2NewWindowRequestedEventArgs e){e.Handled=true;};
            core.PermissionRequested+=delegate(object sender,CoreWebView2PermissionRequestedEventArgs e){e.State=CoreWebView2PermissionState.Deny;};
            core.DownloadStarting+=delegate(object sender,CoreWebView2DownloadStartingEventArgs e){e.Cancel=true;};
            core.NavigationCompleted+=async delegate(object sender,CoreWebView2NavigationCompletedEventArgs e) {
                if(!e.IsSuccess) {message.Text="界面加载失败 / UI load failed: "+e.WebErrorStatus;return;}
                message.Visible=false;
                if(testing)await SmokeAsync(runtimeVersion);
            };
            core.Navigate(address.AbsoluteUri);
        } catch(Exception ex) {
            ExitCode=1;message.Text="无法启动 / Startup failed\n"+ex.Message+"\n需要 Microsoft Edge WebView2 Runtime。不会转到外部浏览器。";
            if(testing)WriteReport(new Dictionary<string,object>{{"status","FAIL"},{"error",ex.ToString()}});
        }
        if(ExitCode!=0 && testing) {await StopBackendAsync();allowClose=true;Close();}
    }
    async Task<bool> BackendIdleAsync() {
        if(backend==null||backend.HasExited)return true;
        if(!ready)return false;
        using(var client=new HttpClient(new HttpClientHandler{UseProxy=false})) {
            client.Timeout=TimeSpan.FromSeconds(4);
            string data=await client.GetStringAsync(origin+"/api/jobs");
            var result=json.Deserialize<Dictionary<string,object>>(data);
            var jobs=(System.Collections.IEnumerable)result["jobs"];
            foreach(Dictionary<string,object> job in jobs)if(job["exit_code"]==null)return false;
            return true;
        }
    }
    async Task<bool> StopBackendAsync() {
        if(backend==null||backend.HasExited)return true;
        File.WriteAllText(stopFile,"Desktop requested graceful idle-only shutdown",Encoding.UTF8);
        for(int i=0;i<150;i++) {if(backend.HasExited)return true;await Task.Delay(100);}
        return false; // Never kill workers, optical tools, or another application's server.
    }
    async Task CloseSafelyAsync() {
        closing=true;
        try {
            if(ready && !await BackendIdleAsync()) {
                if(!testing)MessageBox.Show(this,"还有任务在运行。请等待完成，或在任务页停止可取消的任务后再退出。\nTasks are still running. Wait for completion before closing.",Text,MessageBoxButtons.OK,MessageBoxIcon.Information);
                return;
            }
            if(!await StopBackendAsync()) {
                if(!testing)MessageBox.Show(this,"后台尚未安全退出，窗口将保持打开。\nBackend is still active; the window remains open.",Text,MessageBoxButtons.OK,MessageBoxIcon.Warning);
                return;
            }
            allowClose=true;Close();
        } catch(Exception ex) {
            if(!testing)MessageBox.Show(this,"无法确认任务状态；未强制退出。\nCannot confirm job state: "+ex.Message,Text);
        } finally {closing=false;}
    }
    void WriteReport(Dictionary<string,object> report) {
        if(smokeReport!=null)File.WriteAllText(smokeReport,json.Serialize(report),new UTF8Encoding(false));
    }
    async Task<string> PageTaskAsync(string expression) {
        // WebView2 ExecuteScriptAsync serializes a Promise, it does not await it.
        string key="__bdSmoke"+Guid.NewGuid().ToString("N");
        await view.CoreWebView2.ExecuteScriptAsync("window."+key+"=null;("+expression+").then(v=>window."+key+"=v).catch(e=>window."+key+"=JSON.stringify({error:String(e)}));");
        for(int i=0;i<400;i++) {
            string value=await view.CoreWebView2.ExecuteScriptAsync("window."+key);
            if(value!="null") {await view.CoreWebView2.ExecuteScriptAsync("delete window."+key);return json.Deserialize<string>(value);}
            await Task.Delay(50);
        }
        throw new TimeoutException("Embedded UI request timed out");
    }
    async Task SmokeAsync(string version) {
        // Opt-in local synthetic test only. No real archive command is submitted.
        if(!testing)return;testing=false;
        try {
            string dom="{}";
            for(int i=0;i<150;i++) {
                dom=await view.CoreWebView2.ExecuteScriptAsync("JSON.stringify({title:document.title,buttons:document.querySelectorAll('button').length,selects:document.querySelectorAll('select').length,text:document.body.innerText.slice(0,2500),width:innerWidth})");
                string decoded=json.Deserialize<string>(dom);
                var data=json.Deserialize<Dictionary<string,object>>(decoded);
                if(Convert.ToInt32(data["buttons"])>4)break;
                await Task.Delay(100);
            }
            var snapshot=json.Deserialize<Dictionary<string,object>>(json.Deserialize<string>(dom));
            if(Convert.ToInt32(snapshot["buttons"])<=4)throw new InvalidOperationException("React did not render");
            foreach(string language in new[]{"en","zh-CN"}) {
                string welcome=await PageTaskAsync("(async()=>{const lang="+json.Serialize(language)+";const label=lang==='en'?'English':'简体中文';if(document.documentElement.lang!==lang){document.querySelector('.top-actions [role=combobox]').click();await new Promise(r=>setTimeout(r,100));const option=[...document.querySelectorAll('[role=option]')].find(e=>e.textContent===label);if(!option)throw Error('Locale option missing');option.click();}for(let i=0;i<30&&document.documentElement.lang!==lang;i++)await new Promise(r=>setTimeout(r,50));await document.fonts.ready;await new Promise(r=>setTimeout(r,300));if(document.body.innerText.includes('AI-Workspaces')||document.body.innerText.includes('Users\\\\'))throw Error('Private path in public welcome preview');return 'WELCOME_OK';})()");
                if(welcome!="WELCOME_OK")throw new InvalidOperationException(welcome);
                using(var preview=File.Create(smokeReport+".welcome-"+language+".png"))await view.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png,preview);
            }
            string synthetic=Path.Combine(session,"synthetic-source");Directory.CreateDirectory(synthetic);
            string raw=Path.Combine(synthetic,"DESKTOP-SMOKE.CR2");File.WriteAllText(raw,"Synthetic desktop smoke data; preserve unchanged");
            var request=new Dictionary<string,object>{{"command","prepare"},{"parameters",new Dictionary<string,object>{{"Source",synthetic},{"SetId","DESKTOP-SMOKE"},{"Scenario","photo"},{"Execute",false}}}};
            string submit="(async()=>{const b=await (await fetch('/api/bootstrap')).json();const r=await fetch('/api/jobs',{method:'POST',headers:{'Content-Type':'application/json','X-Archive-Token':b.token},body:JSON.stringify("+json.Serialize(request)+")});return JSON.stringify(await r.json());})()";
            string submitted=await PageTaskAsync(submit);
            var job=json.Deserialize<Dictionary<string,object>>(submitted);
            if(!job.ContainsKey("id"))throw new InvalidOperationException("Preview request failed: "+submitted);
            bool busyObserved=!await BackendIdleAsync();
            for(int i=0;i<400;i++) {
                string detail=await PageTaskAsync("(async()=>JSON.stringify(await (await fetch('/api/jobs/"+(string)job["id"]+"')).json()))()");
                job=json.Deserialize<Dictionary<string,object>>(detail);
                if(job["exit_code"]!=null)break;
                await Task.Delay(100);
            }
            if((string)job["state"]!="DRY_RUN"||Convert.ToInt32(job["exit_code"])!=0)throw new InvalidOperationException("Native preview failed: "+json.Serialize(job));
            if(File.ReadAllText(raw)!="Synthetic desktop smoke data; preserve unchanged")throw new InvalidOperationException("Synthetic source changed");
            for(int i=0;i<300&&!await BackendIdleAsync();i++)await Task.Delay(100);
            bool idle=await BackendIdleAsync();if(!idle)throw new TimeoutException("Read-only startup jobs did not finish");
            bool libraryConnected=false;
            // Extend the explicit smoke test only with a config beside its report.
            // Never change an arbitrary user config for this synthetic UI check.
            var readyState=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(readyFile,Encoding.UTF8));
            string testConfig=(string)readyState["config"];
            if(Path.GetDirectoryName(Path.GetFullPath(testConfig))==Path.GetDirectoryName(smokeReport)) {
                string fixture=Path.Combine(session,"Synthetic 库 & spaces");Directory.CreateDirectory(fixture);
                string fixtureJson=Path.Combine(fixture,"catalog.json");
                var discs=new List<object>();
                for(int n=1;n<=25;n++)discs.Add(new Dictionary<string,object>{{"disc_id",n==1?"BD-P-0042":"BD-P-"+(100+n).ToString("D4")},{"archive_set_id","SYNTHETIC-LIBRARY"},{"disc_index",n},{"status",n%2==1?"VERIFIED":"BURNED_UNVERIFIED"},{"position",n},{"disc_count",25},{"media_type","BD25"},{"category","I"},{"stage",new Dictionary<string,object>{{"receipt",new Dictionary<string,object>{{"files",new object[]{new Dictionary<string,object>{{"path","data/2025-01-17_Trip/DEMO_FILE_"+n.ToString("D3")+".CR2"},{"bytes",1234567},{"mtime","2025-01-17T12:00:00Z"}}}}}}}}});
                var archive=new Dictionary<string,object>{{"schema_version",1},{"sequences",new Dictionary<string,object>{{"P",130},{"G",7},{"B",24},{"M",0}}},{"disc_index_sequence",72},{"sets",new object[]{new Dictionary<string,object>{{"archive_set_id","SYNTHETIC-LIBRARY"},{"category","I"},{"summary","Synthetic trip photo collection"}}}},{"discs",discs}};
                File.WriteAllText(fixtureJson,json.Serialize(archive),new UTF8Encoding(false));
                string result=await PageTaskAsync("(async()=>{const wait=ms=>new Promise(r=>setTimeout(r,ms));document.querySelector('button[title=\"光盘库\"],button[title=\"Disc library\"]').click();await wait(100);if(!document.querySelector('[data-testid=\"library-path\"]')){document.querySelector('[data-testid=\"library-settings\"]').click();}for(let i=0;i<40&&!document.querySelector('[data-testid=\"library-path\"]');i++)await wait(100);const el=document.querySelector('[data-testid=\"library-path\"]');if(!el)throw Error('Library path input missing');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,"+json.Serialize(fixtureJson)+");el.dispatchEvent(new Event('input',{bubbles:true}));await wait(200);document.querySelector('[data-testid=\"library-connect\"]').click();for(let i=0;i<100;i++){await wait(100);const b=await(await fetch('/api/bootstrap')).json();if(b.library.mode==='JSON'&&b.catalog.discs.some(d=>d.disc_id==='BD-P-0042')&&document.body.innerText.includes('BD-P-0042')){document.querySelector('button[title=\"工具与设置\"],button[title=\"Tools & settings\"]').click();await wait(200);if(!document.querySelector('[data-testid=\"library-path\"]'))throw Error('Library settings missing');document.querySelector('button[title=\"光盘库\"],button[title=\"Disc library\"]').click();return 'CONNECTED_UI';}}throw Error('Library connection was not rendered');})()");
                if(result!="CONNECTED_UI")throw new InvalidOperationException(result);
                string browseTest=await PageTaskAsync("(async()=>{const wait=ms=>new Promise(r=>setTimeout(r,ms));const until=async f=>{for(let i=0;i<100;i++){if(f())return;await wait(100);}throw Error('Catalog UI condition timed out');};await until(()=>document.querySelector('[data-disc-id=\"BD-P-0042\"]'));document.querySelector('[data-disc-id=\"BD-P-0042\"]').click();await until(()=>document.querySelector('.content-table')?.innerText.includes('DEMO_FILE_001.CR2'));const green=getComputedStyle(document.querySelector('.library-detail-header .verified')).color;if(green!=='rgb(116, 231, 174)')throw Error('Verified is not green: '+green);const noScroll=document.documentElement.scrollHeight<=innerHeight+2&&document.documentElement.scrollWidth<=innerWidth+2;if(!noScroll)throw Error('Whole-page overflow');document.querySelector('[aria-label=\"下一页光盘\"],[aria-label=\"Next disc page\"]').click();await until(()=>document.querySelector('[data-disc-id=\"BD-P-0111\"]'));const field=document.querySelector('[data-testid=\"disc-query\"]');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(field,'DEMO_FILE_025');field.dispatchEvent(new Event('input',{bubbles:true}));await until(()=>document.querySelectorAll('[data-disc-id]').length===1&&document.querySelector('[data-disc-id=\"BD-P-0125\"]'));document.querySelector('[data-disc-id=\"BD-P-0125\"]').click();await until(()=>document.querySelector('.content-table')?.innerText.includes('DEMO_FILE_025.CR2'));document.querySelector('[aria-label=\"状态筛选\"],[aria-label=\"Status filter\"]').click();await until(()=>document.querySelector('[role=\"listbox\"]'));const option=Array.from(document.querySelectorAll('[role=\"option\"]')).find(e=>e.textContent==='BURNED_UNVERIFIED');option.click();await until(()=>document.querySelectorAll('[data-disc-id]').length===0);document.querySelector('[aria-label=\"状态筛选\"],[aria-label=\"Status filter\"]').click();await until(()=>document.querySelector('[role=\"listbox\"]'));Array.from(document.querySelectorAll('[role=\"option\"]')).find(e=>e.textContent==='VERIFIED').click();await until(()=>document.querySelector('[data-disc-id=\"BD-P-0125\"]'));return JSON.stringify({status:'PASS',verified_color:green,whole_page_overflow:false,pagination:true,filename_search:true,status_filter:true,disc_content:true});})()");
                if(!browseTest.Contains("PASS"))throw new InvalidOperationException(browseTest);
                File.WriteAllText(smokeReport+".browse.json",browseTest,new UTF8Encoding(false));
                string fixtureBefore=File.ReadAllText(fixtureJson,Encoding.UTF8);
                string idTest=await PageTaskAsync("(async()=>{const wait=ms=>new Promise(r=>setTimeout(r,ms));const until=async f=>{for(let i=0;i<160;i++){if(f())return;await wait(100);}throw Error('Identifier UI condition timed out');};document.querySelector('button[title=\"编号管理\"],button[title=\"Identifiers\"]').click();await until(()=>document.querySelector('[data-testid=\"actual-next-id\"]')?.textContent==='BD-P-0131'&&!document.querySelector('[data-testid=\"reload-identifiers\"]').disabled);if(document.querySelector('[data-testid=\"next-number\"]').value!=='131')throw Error('Automatic P successor was not populated');if(document.querySelector('[data-testid=\"next-global-index\"]').textContent!=='73')throw Error('Global index not loaded');const observed={P:'BD-P-0131'};for(const [prefix,id,number] of [['B','BD-B-0025','25'],['G','BD-G-0008','8'],['M','BD-M-0001','1']]){document.querySelector('[data-testid=\"counter-'+prefix+'\"]').closest('button').click();await until(()=>document.querySelector('[data-testid=\"actual-next-id\"]')?.textContent===id);if(document.querySelector('[data-testid=\"next-number\"]').value!==number)throw Error('Category successor not populated: '+prefix);observed[prefix]=id;}document.querySelector('[data-testid=\"counter-B\"]').closest('button').click();await until(()=>document.querySelector('[data-testid=\"next-number\"]').value==='25');const input=document.querySelector('[data-testid=\"next-number\"]');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,'99');input.dispatchEvent(new Event('input',{bubbles:true}));await until(()=>document.querySelector('[data-testid=\"counter-draft\"]'));if(document.querySelector('[data-testid=\"actual-next-id\"]').textContent!=='BD-B-0025')throw Error('Draft overwrote saved successor');if(document.querySelector('[role=\"checkbox\"]').getAttribute('aria-checked')!=='false')throw Error('Write default is on');document.querySelector('[data-testid=\"apply-counter\"]').click();await until(()=>document.querySelector('[data-testid=\"counter-result\"]')?.textContent.includes('BD-B-0099'));const jobs=await(await fetch('/api/jobs')).json();const change=jobs.jobs.filter(j=>j.command==='set-counter').at(-1);if(change.state!=='DRY_RUN'||change.result.result.status!=='DRY_RUN')throw Error('Counter preview wrote or failed');document.querySelector('[data-testid=\"reload-identifiers\"]').click();await until(()=>document.querySelector('[data-testid=\"next-number\"]').value==='25'&&!document.querySelector('[data-testid=\"reload-identifiers\"]').disabled);if(document.querySelector('[data-testid=\"counter-draft\"]'))throw Error('Refresh did not clear custom draft');document.querySelector('[data-testid=\"counter-P\"]').closest('button').click();await until(()=>document.querySelector('[data-testid=\"actual-next-id\"]').textContent==='BD-P-0131');return JSON.stringify({status:'PASS',auto_loaded:true,prefix_successors:observed,global_next_index:73,custom_draft:true,preview_only:true,refresh_refilled:true});})()");
                if(!idTest.Contains("PASS"))throw new InvalidOperationException(idTest);
                if(File.ReadAllText(fixtureJson,Encoding.UTF8)!=fixtureBefore)throw new InvalidOperationException("Read or preview changed catalog bytes");
                File.WriteAllText(smokeReport+".identifiers.json",idTest,new UTF8Encoding(false));
                libraryConnected=true;
            }
            await Task.Delay(2400);
            await PageTaskAsync("(async()=>{await document.fonts.ready;return 'READY';})()");
            await view.CoreWebView2.CallDevToolsProtocolMethodAsync("DOM.enable","{}");
            await view.CoreWebView2.CallDevToolsProtocolMethodAsync("CSS.enable","{}");
            var doc=json.Deserialize<Dictionary<string,object>>(await view.CoreWebView2.CallDevToolsProtocolMethodAsync("DOM.getDocument","{}"));
            var rootNode=(Dictionary<string,object>)doc["root"];
            var fontNodes=new List<object>();
            foreach(string selector in new[]{"body","h1",".nav-item.active",".counter-card small",".counter-card strong",".identifiers-panel>.muted",".counter-source",".id-preview"}) {
                var found=json.Deserialize<Dictionary<string,object>>(await view.CoreWebView2.CallDevToolsProtocolMethodAsync("DOM.querySelector",json.Serialize(new Dictionary<string,object>{{"nodeId",rootNode["nodeId"]},{"selector",selector}})));
                var fonts=json.DeserializeObject(await view.CoreWebView2.CallDevToolsProtocolMethodAsync("CSS.getPlatformFontsForNode",json.Serialize(new Dictionary<string,object>{{"nodeId",found["nodeId"]}})));
                fontNodes.Add(new Dictionary<string,object>{{"selector",selector},{"fonts",fonts}});
            }
            string computed=await PageTaskAsync("(async()=>JSON.stringify({lang:document.documentElement.lang,fonts:[...document.fonts].map(f=>({family:f.family,status:f.status,weight:f.weight})),nodes:[...document.querySelectorAll('h1,.nav-item.active,.counter-card strong,.counter-card small,.identifiers-panel>.muted,.id-preview')].map(e=>({text:e.textContent.slice(0,70),font:getComputedStyle(e).fontFamily,weight:getComputedStyle(e).fontWeight}))}))()");
            File.WriteAllText(smokeReport+".fonts.json",json.Serialize(new Dictionary<string,object>{{"platform",fontNodes},{"computed",json.DeserializeObject(computed)}}),new UTF8Encoding(false));
            string renderedFonts=json.Serialize(fontNodes);
            if(renderedFonts.Contains("NSimSun")||renderedFonts.Contains("SimSun"))throw new InvalidOperationException("Unexpected serif fallback in typography regression");
            if(!renderedFonts.Contains("IBMPlexMono-SemiBold"))throw new InvalidOperationException("Identifier semibold face did not render");
            using(var nativeIcon=Icon.ToBitmap())nativeIcon.Save(smokeReport+".window-icon.png",System.Drawing.Imaging.ImageFormat.Png);
            using(var exeIcon=System.Drawing.Icon.ExtractAssociatedIcon(Path.Combine(root,"BDArchive.exe")))
            using(var bitmap=exeIcon.ToBitmap())bitmap.Save(smokeReport+".exe-icon.png",System.Drawing.Imaging.ImageFormat.Png);

            snapshot=json.Deserialize<Dictionary<string,object>>(json.Deserialize<string>(await view.CoreWebView2.ExecuteScriptAsync("JSON.stringify({title:document.title,buttons:document.querySelectorAll('button').length,text:document.body.innerText.slice(0,2500),width:innerWidth,devicePixelRatio:devicePixelRatio})")));
            using(var image=File.Create(smokeReport+".png"))await view.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png,image);
            bool stopped=await StopBackendAsync();if(!stopped)throw new InvalidOperationException("Backend did not exit cleanly");
            WriteReport(new Dictionary<string,object>{{"status","PASS"},{"window_title",Text},{"window_handle",Handle.ToInt64()},{"webview2",version},{"dom",snapshot},{"backend_exit",backend.ExitCode},{"backend_pid",backend.Id},{"backend_no_console",backend.StartInfo.CreateNoWindow},{"external_browser_opened",false},{"backend_stopped",stopped},{"library_connected_ui",libraryConnected},{"worker_preview",job["state"]},{"worker_exit",job["exit_code"]},{"close_gate_observed_busy",busyObserved},{"session",session}});
            ExitCode=0;
        } catch(Exception ex) {ExitCode=1;WriteReport(new Dictionary<string,object>{{"status","FAIL"},{"error",ex.ToString()}});}
        await StopBackendAsync();allowClose=true;Close();
    }
    protected override void Dispose(bool disposing) {
        if(disposing && !cleaned) {
            cleaned=true;view.Dispose();
            if(backend!=null && backend.HasExited) {backend.WaitForExit();if(output!=null)output.Dispose();if(error!=null)error.Dispose();backend.Dispose();backend=null;}
        }
        base.Dispose(disposing);
    }
}
