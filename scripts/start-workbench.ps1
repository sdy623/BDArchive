<# React workbench launcher: localhost only, no archive operation on startup. #>
[CmdletBinding()]
param([string]$Config,[ValidateSet('en','zh-CN','')][string]$Language='',
 [ValidateRange(1024,65535)][int]$Port=18765,[switch]$NoOpen)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!(Test-Path -LiteralPath (Join-Path $root 'ui/dist/index.html'))) {
 throw 'Frontend is not built. In ui run: npm ci; npm run build. Or use the ready-to-run release ZIP.'
}
if (!$Config) {
 $Config=Join-Path $root 'archive.config.json'
 if (!(Test-Path -LiteralPath $Config)) {Copy-Item -LiteralPath (Join-Path $root 'archive.config.example.json') -Destination $Config}
}
$Config=(Resolve-Path -LiteralPath $Config).Path
$python=Get-Command python.exe -ErrorAction SilentlyContinue
$pythonArgs=@()
if (!$python) {$python=Get-Command py.exe -ErrorAction SilentlyContinue;$pythonArgs=@('-3')}
if (!$python) {throw 'Python 3.10+ is required. Install Python and make python.exe or py.exe available.'}
$pwsh=(Get-Process -Id $PID).Path
$arguments=@((Join-Path $root 'catalog/workbench.py'),'--config',$Config,'--port',"$Port",'--pwsh',$pwsh)
if ($NoOpen) {$arguments+='--no-open'}
if ($Language) {$arguments+=@('--language',$Language)}
Write-Host "BD Archive Workbench: http://127.0.0.1:$Port (Ctrl+C stops the local UI server)."
& $python.Source @pythonArgs @arguments
if ($LASTEXITCODE -ne 0) {throw "Workbench exited with code $LASTEXITCODE"}
