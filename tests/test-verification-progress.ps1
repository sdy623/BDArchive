[CmdletBinding()]
param([string]$WorkRoot,[string]$Python,[string]$DwarfsBin,[switch]$Gui)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/verification-progress' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
function Assert($Value,$Message) { if (!$Value) { throw $Message } }
$results=New-Object 'System.Collections.Generic.List[object]'
function Pass($Name) { $results.Add(@{name=$Name;status='PASS'});Write-Host "PASS $Name" }
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json')
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
if ($DwarfsBin) { $c.tools.dwarfs_bin=$DwarfsBin }
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c;$null=Initialize-Archive $c
$root=Join-Path $run 'synthetic 光盘'
Write-Text (Join-Path $root 'DISC.json') '{}';Write-Text (Join-Path $root 'RESTORE.md') 'Synthetic only'
Write-Text (Join-Path $root 'SET-MANIFEST.json') '{}';Write-Text (Join-Path $root 'empty.txt') ''
$payload=Join-Path $root '大文件 sample.bin'
$buffer=New-Object byte[] 1048576;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
try {$rng.GetBytes($buffer)} finally {$rng.Dispose()}
$stream=[IO.File]::Create($payload);try {for ($i=0;$i -lt 64;$i++) {$stream.Write($buffer,0,$buffer.Length)}} finally {$stream.Dispose()}
$reference=(Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
function Seal-Fixture {
    $lines=@(Get-ChildItem -LiteralPath $root -File | Where-Object {$_.Name -ne 'SHA256SUMS'} | Sort-Object Name | ForEach-Object {(File-Hash $_.FullName)+'  '+$_.Name})
    Write-Text (Join-Path $root 'SHA256SUMS') (($lines -join "`n")+"`n")
    $script:record=[pscustomobject]@{disc_id='BD-P-0001';archive_set_id='PROGRESS';position=1;disc_count=1;status='SIMULATED_PASS';burn=[pscustomobject]@{simulation=$true;root=$root};verification=$null;
        hash=(File-Hash (Join-Path $root 'SHA256SUMS'));stage=[pscustomobject]@{hash=(File-Hash (Join-Path $root 'SHA256SUMS'));disc_json_hash=(File-Hash (Join-Path $root 'DISC.json'))}}
}
Seal-Fixture
$request=Join-Path $run 'verify.json';Write-Json $request @{command='verify';parameters=@{Config=$cfg;DiscId=$record.disc_id;Execute=$true;Simulate=$true}}
Start-ArchiveProgressContext $request 'Synthetic verification'
Write-Text ($request+'.cancel') 'A progress-only context must ignore preparation cancellation.'
Assert-PreparationRunning
Assert ($null -eq (& (Get-Module Archive.Core) {$script:PreparationJob})) 'Reporting enabled preparation copy/cancel policy.'
Pass 'verification reporting is isolated from preparation cancellation and copy policy'
[IO.File]::Delete($request+'.cancel')
foreach ($totalBytes in @([int64]3GB,[int64]21GB,[int64]45GB,[int64]50000000000)) {
    Set-HashProgress $payload 1MB $totalBytes ([pscustomobject]@{Elapsed=[TimeSpan]::FromSeconds(1)}) -Force
    $large=Read-Json ($request+'.progress.json')
    Assert ($large.metrics.total_bytes -eq $totalBytes -and $large.metrics.eta_seconds -gt 0 -and $large.metrics.completed_bytes -eq 1MB) 'Large-media ETA arithmetic overflowed or swallowed progress.'
    $largeView=Get-ArchiveProgressView $large
    Assert ($largeView.determinate -and $largeView.value -eq 0) 'Large-media percentage rendering failed.'
}
Pass '3, 21, 45 GiB and 50 GB counters avoid Int32 overloads without large fixture I/O'
& (Get-Module Archive.Core) {
    $script:beforeTelemetryCore=${function:Set-HashProgressCore}
    function script:Set-HashProgressCore {throw 'Synthetic telemetry failure'}
}
try {Assert ((File-Hash $payload) -ceq $reference) 'A progress-only exception interrupted the content hash.'}
finally {& (Get-Module Archive.Core) {Set-Item Function:script:Set-HashProgressCore $script:beforeTelemetryCore}}
Pass 'progress reporting error cannot become content verification FAIL'

# Observe intermediate records from the real 1 MiB streaming loop. The observer
# forces only reporting frequency, not I/O, hashing, verification or return codes.
& (Get-Module Archive.Core) {
    $script:originalHashProgress=${function:Set-HashProgress};$script:observed=New-Object 'System.Collections.Generic.List[object]'
    function script:Set-HashProgress($Path,[int64]$Bytes,[int64]$Length,$Clock,[switch]$Force) {
        if ($Length -ge 1MB -and $Bytes -gt 0 -and $Bytes -lt $Length -and $Bytes%8MB -eq 0) {$Force=$true}
        & $script:originalHashProgress $Path $Bytes $Length $Clock -Force:$Force
        if ($Force -and $Length -ge 1MB) { $script:observed.Add((Read-Json ($script:ArchiveProgressJob.request+'.progress.json'))) }
    }
}
Assert ((File-Hash $payload) -ceq $reference) 'Streaming SHA-256 differs from Get-FileHash.'
$snapshots=@(& (Get-Module Archive.Core) {$script:observed.ToArray()})
$middle=@($snapshots | Where-Object {$_.metrics.percent -gt 0 -and $_.metrics.percent -lt 100})
Assert ($middle.Count -ge 2 -and $middle[0].metrics.rate_mib_s -ge 0) 'No progress published while a single large file was still being read.'
$view=Get-ArchiveProgressView $middle[0]
Assert ($view.determinate -and $view.value -gt 0 -and $view.value -lt 100 -and $view.detail -match 'GiB') 'Numeric UI view missing byte progress.'
Pass 'same-pass streaming hash matches reference and publishes intermediate byte progress'
$null=Check-DiscTree $c $root $record
$snapshots=@(& (Get-Module Archive.Core) {$script:observed.ToArray()})
$batch=@($snapshots | Where-Object {$_.metrics.file_count -eq 5})
Assert ($batch.Count -gt 1) 'Multi-file verification has no aggregate progress.'
$expected=(@(Get-ChildItem -LiteralPath $root -File | Where-Object {$_.Name -ne 'SHA256SUMS'}) | Measure-Object Length -Sum).Sum
Assert ($batch[0].metrics.total_bytes -eq $expected) 'Aggregate includes extra bytes or misses zero/small files.'
Assert ($batch[-1].metrics.completed_bytes -le $expected -and $batch[-1].metrics.file_index -le 5) 'Progress exceeds manifest totals.'
Assert ($null -eq (& (Get-Module Archive.Core) {$script:HashProgressScope})) 'Hash scope leaked after successful verification.'
Pass 'manifest-wide bytes and file counters include Unicode and zero-length files'
$bad=[IO.File]::Open($payload,'Open','Write','Read');try {$bad.WriteByte($buffer[0] -bxor 1)} finally {$bad.Dispose()}
$failed=$false;try {$null=Check-DiscTree $c $root $record} catch {$failed=$_.Exception.Message -match 'SHA-256 FAIL'}
Assert ($failed -and $null -eq (& (Get-Module Archive.Core) {$script:HashProgressScope})) 'Real mismatch passed or leaked progress state.'
$bad=[IO.File]::Open($payload,'Open','Write','Read');try {$bad.WriteByte($buffer[0])} finally {$bad.Dispose()}
Pass 'content mismatch still fails and cleans up progress scope'
Set-PreparationProgress 'DwarFS 内部完整性检查（工具不提供百分比）' -ToolLog 'synthetic.log' -ToolPid 123 -Force
$native=Read-Json ($request+'.progress.json');$view=Get-ArchiveProgressView $native
Assert (!$view.determinate -and $view.detail -eq '' -and $null -eq $native.metrics) 'DwarFS check inherited a false SHA-256 percentage.'
Assert (!(Get-ArchiveProgressView ([pscustomobject]@{message='old worker';tool_log=''})).determinate) 'Old progress format rejected.'
Pass 'native/legacy stages use indeterminate progress without stale hash percentages'
& (Get-Module Archive.Core) {Set-Item Function:script:Set-HashProgress $script:originalHashProgress}
if ($DwarfsBin) {
    $image=Join-Path $root 'small.dwarfs';$input=Join-Path $run 'small source';Write-Text (Join-Path $input 'unicode 备份.txt') ('real data'*2000)
    $null=Dwarfs-Run $c mkdwarfs @('-i',$input,'-o',$image,'-l','0') 'mkdwarfs'
    Seal-Fixture
    & (Get-Module Archive.Core) {
        $script:originalFileHash=${function:File-Hash};$script:imageHashCalls=0
        function script:File-Hash($Path) {if ($Path.EndsWith('.dwarfs')) {$script:imageHashCalls++};& $script:originalFileHash $Path}
    }
    try {
        $null=Check-DiscTree $c $root $record -Integrity
        Assert ((& (Get-Module Archive.Core) {$script:imageHashCalls}) -eq 1) 'DwarFS payload was hashed twice.'
        $reports=@(Get-ChildItem -LiteralPath (Join-Path $c.archive_root 'reports') -Filter 'dwarfs-*.json')
        Assert ($reports.Count -gt 0 -and (Read-Json $reports[-1].FullName).exit_code -eq 0) 'Real dwarfsck result missing.'
    } finally { & (Get-Module Archive.Core) {Set-Item Function:script:File-Hash $script:originalFileHash} }
    Pass 'real DwarFS 0.15.7 integrity and exit code, image SHA-256 read only once'
}
$null=Invoke-Archive scan @{Config=$cfg;Execute=$true;SetId='WORKER';Category='I';Source=$root}
$null=Invoke-Archive plan @{Config=$cfg;Execute=$true;SetId='WORKER';ParPercent=0}
$workerDisc=(Load-Plan $c 'WORKER').discs[0].disc_id
$null=Invoke-Archive stage @{Config=$cfg;Execute=$true;DiscId=$workerDisc}
$null=Invoke-Archive burn @{Config=$cfg;Execute=$true;DiscId=$workerDisc;Simulate=$true}
Write-Json $request @{command='verify';parameters=@{Config=$cfg;DiscId=$workerDisc;Execute=$true;Simulate=$true}}
# Exercise the actual GUI worker, not a test replacement of its dispatch.
$engine=(Get-Process -Id $PID).Path;$runner=Full-Path (Join-Path $PSScriptRoot '../scripts/run-request.ps1')
$info=New-ArchiveWorkerStartInfo $engine $runner $request $false
$nativeBefore=@(Get-ChildItem -LiteralPath (Join-Path $c.archive_root 'logs') -Filter '*-dwarfsck-*.log').Count
$proc=New-Object Diagnostics.Process;$proc.StartInfo=$info;$null=$proc.Start()
try {
    Assert ($proc.WaitForExit(45000)) 'Simulation verification worker timed out.'
    $out=Read-Json ($request+'.result.json')
    Assert ($proc.ExitCode -eq 0 -and $out.result.status -eq 'PASS' -and $out.result.simulation) 'Structured verification worker failed.'
    Assert ($out.result.method -eq 'SHA256' -and @(Get-ChildItem -LiteralPath (Join-Path $c.archive_root 'logs') -Filter '*-dwarfsck-*.log').Count -eq $nativeBefore) 'Default readback redundantly ran dwarfsck.'
    Assert ([IO.File]::Exists($request+'.progress.json')) 'Verification worker did not start reporting.'
} finally {$proc.Dispose()}
Pass 'actual structured verify worker emits progress and completes simulated PASS'
$prior=(Get-Disc $c $workerDisc).verification.report
$cancelRequest=Join-Path $run 'cancel-verify.json'
Start-VerificationContext $cancelRequest
& (Get-Module Archive.Core) {
    $script:beforeCancelHashProgress=${function:Set-HashProgress}
    function script:Set-HashProgress($Path,[int64]$Bytes,[int64]$Length,$Clock,[switch]$Force) {
        & $script:beforeCancelHashProgress $Path $Bytes $Length $Clock -Force:$Force
        if ($Bytes -ge 8MB -and $Length -gt 8MB) { Write-Text ($script:VerificationJob.request+'.cancel') 'Synthetic mid-read user cancellation' }
    }
}
try {
    $wasCancelled=$false
    try {$null=Invoke-Archive verify @{Config=$cfg;Execute=$true;DiscId=$workerDisc;Simulate=$true}} catch {$wasCancelled=Is-PreparationCancellation $_}
    $cancelRecord=Get-Disc $c $workerDisc
    Assert ($wasCancelled -and $cancelRecord.last_verification_attempt.status -eq 'CANCELLED' -and $cancelRecord.verification.report -eq $prior) 'Cancellation became FAIL/PASS or erased prior evidence.'
    Assert ((Read-Json $cancelRecord.last_verification_attempt.report).status -eq 'CANCELLED') 'Cancellation report missing.'
    $lock=[IO.File]::Open((Join-Path $c.archive_root 'archive.lock'),'Open','ReadWrite','None');$lock.Dispose()
} finally {& (Get-Module Archive.Core) {Set-Item Function:script:Set-HashProgress $script:beforeCancelHashProgress}}
Pass 'mid-read cancellation records CANCELLED without a new PASS and releases archive lock'
if ($DwarfsBin) {
    Start-ArchiveProgressContext (Join-Path $run 'deep-verify.json') 'Synthetic opt-in deep check'
    $deep=Invoke-Archive verify @{Config=$cfg;Execute=$true;DiscId=$workerDisc;Simulate=$true;DeepVerifyDwarfs=$true}
    Assert ($deep.status -eq 'PASS' -and $deep.method -eq 'SHA256_AND_DWARFS_INTEGRITY') 'Opt-in deep check failed.'
    $last=Get-ChildItem -LiteralPath (Join-Path $c.archive_root 'logs') -Filter '*-dwarfsck-*.log.json' | Sort-Object LastWriteTime | Select-Object -Last 1
    $argsUsed=(Read-Json $last.FullName).arguments
    Assert ($argsUsed[-2] -eq '--num-workers' -and $argsUsed[-1] -eq '1') 'Optical deep check did not limit worker count.'
    Pass 'extra DwarFS check is explicit and uses one reader worker'
}
if ($Gui) {
    # Use captured same-pass progress for a deterministic GUI rendering fixture;
    # a 64 MiB SSD read may finish between two 700 ms GUI timer ticks.
    Write-Json ($request+'.ui-progress.json') $middle[0]
    & (Join-Path $PSScriptRoot '../scripts/archive-ui.ps1') -Config $cfg -SmokeTest -ExerciseVerificationProgress -VerifyTestRequestPath $request -DiagnosticsPath (Join-Path $run 'gui.json') -PreviewPath (Join-Path $run 'gui.png') -TestNarrowWindow
    $guiResult=Read-Json (Join-Path $run 'gui.json');Assert ($guiResult.verification_progress -eq 'PASS') 'GUI progress fixture failed.'
    Pass 'HiDPI narrow GUI renders captured bytes and switches to native indeterminate state'
}
Write-Json (Join-Path $run 'verification-progress-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();results=$results.ToArray();physical_disc_read=$false}
Write-Host "Results: $run"
