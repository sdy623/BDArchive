# The selected task retains the existing UI variables. Background tasks retain
# their own process, log, progress, cancellation request and completion text.
$script:archiveJobs=New-Object 'System.Collections.Generic.List[object]'
$script:selectedArchiveJob=-1;$script:selectingArchiveJob=$false
function Test-AnyArchiveJobRunning {
    if ($script:worker -and !$script:worker.HasExited) {return $true}
    foreach ($job in $script:archiveJobs) {if ($job.worker -and !$job.worker.HasExited) {return $true}}
    return $false
}
function Save-SelectedArchiveJob {
    if ($script:selectedArchiveJob -lt 0) {return}
    $job=$script:archiveJobs[$script:selectedArchiveJob]
    $job.worker=$script:worker;$job.path=$script:jobPath;$job.command=$script:jobCommand
    $job.started=$script:jobStarted;$job.stop_requested=$script:stopRequested
    $job.status=$status.Text;$job.log=$log.Text;$job.detail=$progressDetail.Text
    $job.value=$jobProgress.Value;$job.style=$jobProgress.Style
}
function Refresh-ArchiveJobChoices {
    $jobChoice.Visible=($script:archiveJobs.Count -gt 1)
    $jobProgress.Visible=($script:archiveJobs.Count -gt 0)
    $stopPrepare.Visible=($script:archiveJobs.Count -gt 0)
    $script:selectingArchiveJob=$true
    try {
        for ($i=0;$i -lt $script:archiveJobs.Count;$i++) {
            $j=$script:archiveJobs[$i]
            $state=if ($j.worker) {(Get-ArchiveText 'legacy.1f0eb99b7ed0')} else {(Get-ArchiveText 'legacy.d79b1d0e5c61')}
            $label="$($i+1) · $($j.command) · $($j.scope.set_id) $($j.disc_id) · $state"
            if ($jobChoice.Items.Count -le $i) {$null=$jobChoice.Items.Add($label)}
            elseif ([string]$jobChoice.Items[$i] -ne $label) {$jobChoice.Items[$i]=$label}
        }
        $jobChoice.SelectedIndex=$script:selectedArchiveJob
    } finally {$script:selectingArchiveJob=$false}
}
function Select-ArchiveJob([int]$Index) {
    if ($Index -lt 0 -or $Index -ge $script:archiveJobs.Count) {return}
    Save-SelectedArchiveJob;$script:selectedArchiveJob=$Index;$j=$script:archiveJobs[$Index]
    $script:worker=$j.worker;$script:jobPath=$j.path;$script:jobCommand=$j.command
    $script:jobStarted=$j.started;$script:stopRequested=$j.stop_requested
    $status.Text=$j.status;$log.Text=$j.log;$progressDetail.Text=$j.detail
    $jobProgress.Style=$j.style;$jobProgress.Value=$j.value
    $stopPrepare.Enabled=($j.worker -and !$j.worker.HasExited -and $j.command -in @('prepare','verify','import-stage') -and !$j.stop_requested -and $j.execute)
    $stopPrepare.Text=if ($j.stop_requested) {(Get-ArchiveText 'legacy.8a99be840844')} elseif ($j.command -eq 'verify') {(Get-ArchiveText 'action.stopVerification')} else {(Get-ArchiveText 'action.stopPreparation')}
    Refresh-ArchiveJobChoices
}
function Add-CurrentArchiveJob($Command,$Params) {
    $scope=$script:pendingArchiveJobScope
    $script:archiveJobs.Add(@{worker=$script:worker;path=$script:jobPath;command=$Command;started=$script:jobStarted;stop_requested=$false;
        scope=$scope;disc_id=$Params.DiscId;execute=([bool]$Params.Execute -and !$Params.DryRun);drive=$Params.Drive;simulation=[bool]$Params.Simulate;
        status=$status.Text;log=$log.Text;detail='';value=0;style=$jobProgress.Style})
    $script:selectedArchiveJob=$script:archiveJobs.Count-1;Refresh-ArchiveJobChoices
}
function Assert-UiJobAvailable($Command,$Params) {
    $c=Load-Config $configBox.Text
    $scope=if ($Params.Execute -and !$Params.DryRun) {Get-ArchiveOperationScope $c $Command $Params} else {@{archive_root=$c.archive_root;set_id=$Params.SetId;maintenance=$false}}
    $script:pendingArchiveJobScope=$scope
    if (!$Params.Execute -or $Params.DryRun) {return}
    foreach ($j in $script:archiveJobs) {
        if (!$j.worker -or $j.worker.HasExited -or !$j.execute) {continue}
        if ($scope.archive_root -ieq $j.scope.archive_root) {
            if ($scope.maintenance -or $j.scope.maintenance) {throw (Get-ArchiveText 'legacy.edfacd0ca7f7')}
            if ($scope.set_id -and $scope.set_id -ieq $j.scope.set_id) {throw (Get-ArchiveText 'legacy.2568b23c7614' -Arguments @(($($scope.set_id)), ($($j.command))))}
        }
        if ($Command -in @('burn','verify','repair-verify') -and !$Params.Simulate -and !$j.simulation -and $j.command -in @('burn','verify','repair-verify') -and $Params.Drive -and $Params.Drive.TrimEnd('\','/') -ieq $j.drive.TrimEnd('\','/')) {throw (Get-ArchiveText 'legacy.6404842ba014')}
    }
}
function Update-ArchiveJob {
    # Reap completed background jobs even while a long prepare is selected.
    # Save/restore the selected display; never mix another job's cancel path.
    Save-SelectedArchiveJob
    $selected=$script:selectedArchiveJob
    for ($i=0;$i -lt $script:archiveJobs.Count;$i++) {
        $j=$script:archiveJobs[$i]
        if ($i -ne $selected -and $j.worker -and $j.worker.HasExited) {
            Select-ArchiveJob $i;Update-SelectedArchiveJob;Save-SelectedArchiveJob
        }
    }
    if ($selected -ge 0 -and $selected -ne $script:selectedArchiveJob) {Select-ArchiveJob $selected}
    Update-SelectedArchiveJob;Save-SelectedArchiveJob;Refresh-ArchiveJobChoices
}
$jobChoice.Add_SelectedIndexChanged({
    if (!$script:selectingArchiveJob) {Select-ArchiveJob $jobChoice.SelectedIndex;Update-ArchiveJob}
})
