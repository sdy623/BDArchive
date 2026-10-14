# This UI exercise runs a real synthetic prepare and a DIRECTORY simulation.
# It never starts the physical burning backend or confirms a burn dialog.
$fixture=Read-Json (Full-Path $ConcurrentTestFixture)
$prep=@{};foreach ($prop in $fixture.prepare.PSObject.Properties) {$prep[$prop.Name]=$prop.Value}
$burnParams=@{};foreach ($prop in $fixture.burn.PSObject.Properties) {$burnParams[$prop.Name]=$prop.Value}
if (!$burnParams.Simulate -or !$burnParams.Execute -or !$prep.Execute) {throw 'Only actual preparation plus directory simulation is allowed in this fixture.'}
try {
Start-ArchiveJob prepare $prep
$first=$script:worker;$deadline=[DateTime]::UtcNow.AddSeconds(35)
while (!$first.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    Update-ArchiveJob;[Windows.Forms.Application]::DoEvents()
    if ($log.Text -match '==>') {break};[Threading.Thread]::Sleep(80)
}
if ($first.HasExited -or $log.Text -notmatch '==>') {throw 'Synthetic preparation did not reach native progress.'}
Start-ArchiveJob burn $burnParams
if ($script:archiveJobs.Count -ne 2 -or $first.HasExited -or !$script:worker -or $script:worker.HasExited) {throw 'Two UI jobs did not overlap.'}
$second=$script:worker;$firstPath=$script:archiveJobs[0].path;$secondPath=$script:archiveJobs[1].path
if ($firstPath -eq $secondPath -or $stopPrepare.Enabled) {throw 'Jobs share a request path or burn exposes a preparation stop button.'}
$beforeCount=$script:archiveJobs.Count;$blocked=$false
try {Start-ArchiveJob prepare $prep} catch {$blocked=$_.Exception.Message -match '归档.*正在执行'}
if (!$blocked -or $script:archiveJobs.Count -ne $beforeCount) {throw 'Duplicate same-set UI job was started.'}
$deadline=[DateTime]::UtcNow.AddSeconds(20)
while ($script:archiveJobs[1].worker -and [DateTime]::UtcNow -lt $deadline) {Update-ArchiveJob;[Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(80)}
$sim=Read-Json ($secondPath+'.result.json')
if ($sim.status -ne 'PASS' -or !$sim.result.simulation) {throw 'Concurrent directory simulation failed.'}
# A selected, completed B must not permit saving settings while A still runs.
if (!$first.HasExited) {
    $tabs.SelectedIndex=3;[Windows.Forms.Application]::DoEvents()
    $configBefore=File-Hash $configBox.Text;$blocked=$false
    try {$saveConfig.PerformClick()} catch {$blocked=$_.Exception.Message -match '任务运行时不能更改配置'}
    if (!$blocked -or (File-Hash $configBox.Text) -ne $configBefore) {throw 'Settings changed while a background preparation was active.'}
    $tabs.SelectedIndex=0;[Windows.Forms.Application]::DoEvents()
}
# Switch to prepare, then cancel exactly that task; the completed simulation
# keeps its own log/result, with no cancellation file beside its request.
$jobChoice.SelectedIndex=0;[Windows.Forms.Application]::DoEvents();Update-ArchiveJob
if ($script:worker -and !$script:worker.HasExited) {
    if (!$stopPrepare.Enabled -or $script:jobPath -ne $firstPath) {throw 'Switching tasks did not switch the stop target.'}
    $stopPrepare.PerformClick()
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while ($script:worker -and [DateTime]::UtcNow -lt $deadline) {Update-ArchiveJob;[Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(80)}
    if ($script:worker -or (Read-Json ($firstPath+'.result.json')).status -ne 'CANCELLED') {throw 'Selected preparation did not cancel.'}
}
if ([IO.File]::Exists($secondPath+'.cancel') -or (Read-Json ($secondPath+'.result.json')).status -ne 'PASS') {throw 'Cancellation crossed task boundaries.'}
Update-ArchiveJob
if (Test-AnyArchiveJobRunning) {throw 'Finished background process was not reaped.'}
Assert-UiLayout $form
$diagnostics.concurrent_prepare_and_simulated_burn='PASS';$diagnostics.same_set_rejected='PASS';$diagnostics.independent_cancel_paths='PASS';$diagnostics.physical_burn_started=$false

} finally {
    # Fixture-only cleanup on failed assertions: cooperate with our own prepare.
    foreach ($j in $script:archiveJobs) {
        if ($j.worker -and !$j.worker.HasExited -and $j.command -eq 'prepare') {
            Write-Text ($j.path+'.cancel') 'Synthetic UI fixture cleanup'
            $null=$j.worker.WaitForExit(15000)
        }
    }
}
