# Run the potentially slow hardware query in a separate read-only worker.
$script:deviceWorker=$null;$script:deviceJob=$null
function Show-OpticalSelection {
    $item=$drive.SelectedItem
    if (!$item -or !$item.recorder_id) { $mediaInfo.Text=(Get-ArchiveText 'legacy.5e48f68fbf31');return }
    $blank=if ($null -eq $item.blank) {(Get-ArchiveText 'legacy.4d8c1c5b4283')} elseif ($item.blank) {(Get-ArchiveText 'legacy.f0bf4574ce25')} else {(Get-ArchiveText 'legacy.be8518096970')}
    $free=if ($null -ne $item.free_bytes) {(Get-ArchiveText 'legacy.6df265166a47')+([math]::Round($item.free_bytes/1GB,2))+' GiB'} else {''}
    $speeds=if (@($item.speeds_x).Count) {(Get-ArchiveText 'legacy.3fec073ec04d')+($item.speeds_x -join 'x / ')+'x'} else {''}
    $mediaInfo.Text="$($item.media) · $blank$free$speeds"
    if ($item.error) { $mediaInfo.Text+=" · $($item.error)" }
}
function Set-OpticalChoices($Items) {
    $previous=if ($drive.SelectedItem) {$drive.SelectedItem.recorder_id} else {''}
    $drive.Items.Clear()
    foreach ($item in @($Items)) { if ($item.drive) { $null=$drive.Items.Add($item) } }
    $drive.Enabled=($drive.Items.Count -gt 0)
    if ($drive.Items.Count) {
        $drive.SelectedIndex=0
        for ($i=0;$i -lt $drive.Items.Count;$i++) { if ($drive.Items[$i].recorder_id -ceq $previous) { $drive.SelectedIndex=$i;break } }
    }
    Show-OpticalSelection
}
function Selected-OpticalDrive([switch]$Optional) {
    if (!$drive.SelectedItem -or !$drive.SelectedItem.drive) { if ($Optional) { return '' };throw (Get-ArchiveText 'legacy.12d30348f501') }
    [string]$drive.SelectedItem.drive
}
function Refresh-OpticalDevices {
    if ($SmokeTest) {
        $items=if ($OpticalTestFixture) {@(Read-Json $OpticalTestFixture)} else {@()}
        Set-OpticalChoices $items;return
    }
    if ($script:deviceWorker -and !$script:deviceWorker.HasExited) { return }
    $jobRoot=Full-Path (Join-Path $PSScriptRoot '../work/ui-jobs')
    $script:deviceJob=Join-Path $jobRoot ('devices-'+[guid]::NewGuid().ToString('N')+'.json')
    Write-Json $script:deviceJob @{command='devices';parameters=@{Config=(Full-Path $configBox.Text)}}
    $start=New-ArchiveWorkerStartInfo (Get-Process -Id $PID).Path (Join-Path $PSScriptRoot 'run-request.ps1') $script:deviceJob $false
    $script:deviceWorker=New-Object Diagnostics.Process;$script:deviceWorker.StartInfo=$start;$null=$script:deviceWorker.Start()
    $refreshDrives.Enabled=$false;$mediaInfo.Text=(Get-ArchiveText 'legacy.075c914d72b9')
}
$drive.Add_SelectedIndexChanged({ Show-OpticalSelection })
$refreshDrives.Add_Click({ try { Refresh-OpticalDevices } catch { Show-Error $_ } })
$deviceTimer=New-Object Windows.Forms.Timer;$deviceTimer.Interval=300
$deviceTimer.Add_Tick({
    if ($script:deviceWorker -and $script:deviceWorker.HasExited) {
        try {
            $result=Read-Json ($script:deviceJob+'.result.json')
            if ($result.status -ne 'PASS') { throw $result.error }
            Set-OpticalChoices @($result.result)
        } catch { Set-OpticalChoices @();$mediaInfo.Text=(Get-ArchiveText 'legacy.f7293a061e9a')+$_.Exception.Message }
        finally { $script:deviceWorker.Dispose();$script:deviceWorker=$null;$refreshDrives.Enabled=$true }
    }
});$deviceTimer.Start()
