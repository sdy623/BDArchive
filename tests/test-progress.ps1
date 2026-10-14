[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/progress'),[string]$Python,[string]$DwarfsBin,[switch]$Gui)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($run) | Out-Null
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert($Value,$Message) { if (!$Value) { throw $Message } }
function Pass($Name) { $results.Add(@{name=$Name;status='PASS'});Write-Host "PASS $Name" }
$exe=$Python;$fixtureScript=Full-Path (Join-Path $PSScriptRoot 'progress_fixture.py')
if (!$DwarfsBin) { throw 'This cancellation test requires installed DwarFS 0.15.7.' }
$c=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.example.json'))
$c.dwarfs.build_profile='verified';$c.dwarfs.skip_roundtrip=$false
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
$c.tools.dwarfs_bin=$DwarfsBin;$c.tools.dwarfs=''
$c.dwarfs.compression_level=9;$c.dwarfs.workers=1
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$null=Invoke-Archive init @{Config=$cfg;Execute=$true}
$values=@('', '空格 中文 path', 'a"b', 'C:\trailing slash\', 'slash\\"quote', '$(never-execute)')
$r=Run-Tool $c $exe (@($fixtureScript,'echo')+$values) 'argument-test'
$decoded=@($r.output.TrimEnd("`r","`n") -split '\r?\n' | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
Assert ($decoded.Count -eq $values.Count) 'Argument count changed'
for ($i=0;$i -lt $values.Count;$i++) { Assert ($decoded[$i] -ceq $values[$i]) 'Native argument changed' }
Pass 'native literal Unicode, empty, quote and trailing slash arguments'
$r=Run-Tool $c $exe @($fixtureScript,'fail') 'expected-failure' @(7)
Assert ($r.exit_code -eq 7 -and $r.output -match 'expected failure') 'Lost native exit code or stderr'
Pass 'native stderr and exit code'
$source=Join-Path $run 'source 备份';[IO.Directory]::CreateDirectory($source) | Out-Null
$bytes=New-Object byte[] 67108864;$random=[Security.Cryptography.RandomNumberGenerator]::Create()
try { $random.GetBytes($bytes);[IO.File]::WriteAllBytes((Join-Path $source 'data.txt'),$bytes) } finally { $random.Dispose() };$bytes=$null
$original=File-Hash (Join-Path $source 'data.txt')
$request=Join-Path $run 'prepare.json'
$p=@{Config=$cfg;SetId='BACKUP-PROGRESS';Source=$source;Scenario='backup';Media='BD25';ParPercent=0;Execute=$true}
Write-Json $request @{command='prepare';parameters=$p}
$worker=$null;$unrelated=$null
try {
    $unrelated=New-Object ArchiveStreamingProcess($exe,[string[]]@($fixtureScript,'idle'),(Join-Path $run 'unrelated.log'))
    if ($Gui) {
        & (Join-Path $PSScriptRoot '../scripts/archive-ui.ps1') -Config $cfg -SmokeTest -ExercisePreparationStop -StopTestRequestPath $request -DiagnosticsPath (Join-Path $run 'gui.json') -PreviewPath (Join-Path $run 'gui.png') -TestNarrowWindow -TestScale 1.33333

        $guiResult=Read-Json (Join-Path $run 'gui.json');$request=$guiResult.stop_test_request
        Assert ($guiResult.preparation_stop_button -eq 'PASS') 'Stop button did not execute'
        Pass 'visible stop button and real-time GUI output before native exit'
    } else {
        $runner=Join-Path $PSScriptRoot '../scripts/run-request.ps1'
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File '+[ArchiveStreamingProcess]::Quote($runner)+' -RequestPath '+[ArchiveStreamingProcess]::Quote($request)
        $worker=New-Object Diagnostics.Process;$worker.StartInfo=$info;$null=$worker.Start()
        $deadline=[DateTime]::UtcNow.AddSeconds(35);$live=''
        while (!$worker.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath ($request+'.progress.json')) {
                $progress=Read-Json ($request+'.progress.json')
                if ($progress.tool_log) { $live=Read-ArchiveLogTail $progress.tool_log }
                if ($live -match '==>') { break }
            }
            [Threading.Thread]::Sleep(100)
        }
        Assert (!$worker.HasExited -and $live -match '==>') 'No real-time progress before process exit'
        Pass 'native carriage-return progress reaches a readable log before exit'
        Write-Text ($request+'.cancel') 'test user cancellation'
        Assert ($worker.WaitForExit(12000)) 'Cooperative cancellation timed out'
        Assert ($worker.ExitCode -eq 2) 'Worker did not return cancellation code'
    }
    $result=Read-Json ($request+'.result.json')
    Assert ($result.status -eq 'CANCELLED') 'Cancelled preparation reported success or failure'
    Assert (!$unrelated.Process.HasExited) 'Cancellation affected another process'
    $cat=Read-Json (Catalog-Path $c);$id=$cat.discs[0].disc_id
    $build=Join-Path $c.archive_root "build/$id"
    Assert (Test-Path -LiteralPath (Join-Path $build 'PREPARATION-CANCELLED.json')) 'Partial build lacks retry marker'
    Assert (!(Test-Path -LiteralPath (Join-Path $build 'build.json'))) 'Partial image was marked built'
    Assert (!$cat.discs[0].stage -and !$cat.discs[0].burn) 'Cancelled work became staged or burned'
    Assert ((File-Hash (Join-Path $source 'data.txt')) -eq $original) 'Source changed'
    $lock=[IO.File]::Open((Join-Path $c.archive_root 'archive.lock'),'Open','ReadWrite','None');$lock.Dispose()
    $nativeLog=Get-ChildItem -LiteralPath (Join-Path $c.archive_root 'logs') -Filter '*-mkdwarfs-*.log' | Where-Object { $_.Name -notmatch 'help' } | Select-Object -Last 1
    $nativeText=Read-ArchiveLogTail $nativeLog.FullName
    $progress=Read-Json ($request+'.progress.json');$ownedId=[int]$progress.tool_pid
    Assert ($ownedId -gt 0) 'Missing owned PID evidence'
    Assert (!(Get-Process -Id $ownedId -ErrorAction SilentlyContinue)) 'Owned tool was left running'
    Pass 'cancel result, released lock, owned process only, preserved source and partial image'
    if ($DwarfsBin) {
        $c.dwarfs.compression_level=1;Write-Json $cfg $c
        $resume=Join-Path $run 'resume.json';Write-Json $resume @{command='prepare';parameters=$p}
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../scripts/run-request.ps1') -RequestPath $resume
        Assert ($LASTEXITCODE -eq 0) 'Resume failed'
        $res=Read-Json ($resume+'.result.json');Assert ($res.result.status -eq 'READY_FOR_REVIEW') 'Resume not ready'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $c.archive_root 'interrupted') -Directory).Count -eq 1) 'Interrupted output not retained'
        $cat=Read-Json (Catalog-Path $c);Assert ($cat.discs.Count -eq 1 -and $cat.discs[0].disc_id -eq $id -and $cat.discs[0].stage -and !$cat.discs[0].burn) 'Resume changed IDs or burned a disc'
        $report=Read-Json (Join-Path $build 'build.json');Assert ($report.roundtrip -eq 'PASS' -and $report.verification.exit_code -eq 0) 'Resumed DwarFS did not validate'
        Pass 'real DwarFS retry preserves partials and IDs; integrity plus extraction PASS'
    }
    $report=@{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();results=@($results.ToArray());physical_burn=$false;source_deletion=$false}
    Write-Json (Join-Path $run 'progress-results.json') $report
    Write-Host "Results: $run"
} finally {
    if ($worker) {
        if (!$worker.HasExited) { Write-Text ($request+'.cancel') 'test cleanup';$null=$worker.WaitForExit(12000) }
        $worker.Dispose()
    }
    if ($unrelated) { $unrelated.StopOwnedProcess();$null=$unrelated.Finish();$unrelated.Dispose() }
}
