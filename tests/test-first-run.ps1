[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/first-run'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($run)|Out-Null
foreach($dir in @('scripts','catalog','locales','tests')) {
    [IO.Directory]::CreateDirectory((Join-Path $run $dir))|Out-Null
    if(Test-Path (Join-Path $root $dir)) {Get-ChildItem -LiteralPath (Join-Path $root $dir) -File | Copy-Item -Destination (Join-Path $run $dir)}
}
Copy-Item -LiteralPath (Join-Path $root 'archive.config.example.json') -Destination $run
$exampleHash=(Get-FileHash -LiteralPath (Join-Path $run 'archive.config.example.json')).Hash
$engine=(Get-Process -Id $PID).Path
& $engine -NoProfile -STA -File (Join-Path $run 'scripts/archive-ui.ps1') -SmokeTest 1> (Join-Path $run 'stdout.txt') 2> (Join-Path $run 'stderr.txt')
if($LASTEXITCODE -ne 0){Get-Content (Join-Path $run 'stderr.txt');throw 'Fresh public checkout cannot open UI without private config'}
if(!(Test-Path -LiteralPath (Join-Path $run 'archive.config.json'))){throw 'Fresh checkout has no local config'}
if((Get-FileHash -LiteralPath (Join-Path $run 'archive.config.example.json')).Hash -ne $exampleHash){throw 'First run modified tracked example'}
if(Test-Path -LiteralPath (Join-Path $run 'archive')){throw 'First-run preview created archive data'}
Write-Output 'PASS first-run local config created, example preserved, no archive created'
