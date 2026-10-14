# BDArchive 0.3.0 — 独立桌面版 / Desktop edition

## 启动
解压整个 ZIP，双击 **BDArchive.exe**。程序在自己的桌面窗口内显示新版界面，不会打开外部浏览器，不显示控制台。不要只复制 EXE；保留同目录的 runtime、scripts、catalog、ui、assets 和 WebView2 DLL。

- Windows 10/11 x64，.NET Framework 4.7.2+，Microsoft Edge WebView2 Runtime。
- 已内置 Python 和编译好的 React 界面，不需要安装 Python 或 Node。
- 使用 WebView2 内嵌渲染，不是 Chrome/Edge 浏览器页面或地址栏窗口，也不是旧版原生控件 UI。
- PowerShell 7 推荐用于长路径，基础操作可使用 Windows PowerShell 5.1。
- DwarFS、ImgBurn、PAR2、MKVToolNix、ffmpeg、WinFsp 按场景配置，没有自动下载或安装。
- 初次启动只生成安全默认配置；不自动连接旧 catalog、不扫描、刻盘或删除原件。

## 退出与安全
后台有任务时，关闭按钮会阻止退出，避免误停正在写盘的任务。先在任务页停止可取消的任务或等待完成，再关闭窗口。无法确认状态时也不会强杀进程。
无任务时关闭窗口会安全停止本程序的本地服务，不关闭其他软件。服务仅绑定 127.0.0.1，端口自动选择。不会自动弹出其他网页。
应用缓存和后台日志位于程序目录的 work；请解压到有写入权限的位置，建议 D 盘，不要在 Program Files 里直接使用便携版。
真实刻录仍须用户逐盘确认。入口 EXE 尚未商业签名，可能提示未知发布者，不需要管理员权限。
如果系统缺少 WebView2 Runtime，会显示本地错误而不是回退打开浏览器。官方运行时：https://developer.microsoft.com/microsoft-edge/webview2/

## English
Extract the entire folder and double-click **BDArchive.exe**. The redesigned UI runs inside a dedicated WebView2 desktop window, not an external browser. No console window is launched. Keep all accompanying files.
Python and compiled UI assets are included. Requires Windows 10/11 x64, .NET Framework 4.7.2+ and Microsoft Edge WebView2 Runtime. PowerShell 7 is recommended; 5.1 supports basic operations. Third-party archive tools remain external.
Closing is refused while jobs run or job state is unknown. When idle, the application stops only its own backend. Per-disc physical burn confirmation remains mandatory. No private catalog/configuration is bundled.

## Advanced launch
`BDArchive.exe --language en`
`BDArchive.exe --config "D:\my archive\archive.config.json"`
Existing configurations are not overwritten on launch.

## Rebuild
Build ui/dist, then run packaging/build-portable.py with --python-zip, --webview-zip and a fresh --output directory. It pins both packages by SHA-256, verifies official Python signatures, compiles a Windows GUI-subsystem EXE and includes Microsoft SDK license text.
Python: https://www.python.org/downloads/windows/
WebView2 SDK: https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.4258.31
