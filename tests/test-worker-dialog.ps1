[CmdletBinding()]
param([string]$Engine,[string]$WorkRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$Engine) { $Engine=(Get-Process -Id $PID).Path }
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/worker-dialog' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'));$results=@()
foreach ($interactive in @($false,$true)) {
    $name=if ($interactive) {'interactive'} else {'hidden-regression'}
    $req=Join-Path $run ($name+'.json');$out=Join-Path $run ($name+'.result.json')
    # Hidden first-window behavior differs by host/runtime; record baseline.
    # Interactive review must always produce a natively visible window.
    Write-Json $req @{expected_visible=$(if ($interactive) {$true} else {$null});output=$out}
    $start=New-ArchiveWorkerStartInfo $Engine (Full-Path (Join-Path $PSScriptRoot 'burn-dialog-fixture.ps1')) $req $interactive
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    if (!$start.CreateNoWindow -or $start.UseShellExecute) { throw 'Console suppression or structured invocation changed.' }
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    try {
        $null=$process.Start()
        if (!$process.WaitForExit(20000)) { $process.Kill();throw 'Owned synthetic dialog fixture timed out.' }
        if ($process.ExitCode -ne 0) { throw ('Synthetic dialog fixture failed: '+$process.StandardError.ReadToEnd()+$process.StandardOutput.ReadToEnd()) }
        $r=Read-Json $out
        if ($r.status -ne 'PASS' -or ($interactive -and !$r.window_visible) -or !$r.cancelled) { throw 'Dialog visibility or cancellation failed.' }
        $results+=$r;Write-Host "PASS $name"
    } finally { $process.Dispose() }
}
Write-Json (Join-Path $run 'worker-dialog-results.json') @{status='PASS';results=$results;engine=$Engine;console_suppressed=$true;physical_burn=$false}
