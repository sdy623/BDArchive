function Invoke-Archive {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Command,[hashtable]$Parameters)
    $p=$Parameters.Clone()
    foreach ($key in @('Execute','DryRun','Simulate','BurnConfirmed','DeleteSourceConfirmed','MediaReloaded','AllowCounterRollback',
        'SetId','DiscId','NewDiscId','NewSetId','Category','Source','Output','Image','MountPoint','Media','ParPercent','TargetGiB',
        'DeepVerifyDwarfs','MediaRoots','Drive','RecorderId','Location','Summary','Backend','DetectDuplicates','Deduplicate',
        'Device','SecondCopy','PasswordStorage','DiscSetLabel','RefreshMetadata',
        'Scenario','PhotoTier','DateRange','Camera','Tags','Game','MasterStatus','EarlierOriginalStatus','ConfirmationMode','ConfirmationText','ConfirmationContext','VolumeLabelTemplate','Prefix','NextNumber','Reason','StartDiscId','VolumeTemplates')) {
        if (!$p.ContainsKey($key)) { $p[$key]=$null }
    }
    $configPath=Full-Path $p.Config
    $c=if ($script:ArchiveOperationConfig -and $script:ArchiveOperationConfig.path -eq $configPath) {$script:ArchiveOperationConfig.value} else {Load-Config $configPath}
    if ($Command -eq 'rename-disc' -and (!$p.Execute -or $p.DryRun -or $WhatIfPreference)) { return Disc-RenamePreview $c $p }
    if ($Command -eq 'rename-set' -and (!$p.Execute -or $p.DryRun -or $WhatIfPreference)) { return Set-RenamePreview $c $p }
    if ($Command -eq 'import-stage' -and (!$p.Execute -or $p.DryRun -or $WhatIfPreference)) {return External-PhotoPreview $c $p}
    if ($Command -eq 'devices') { return @(Get-OpticalInventory) }
    if ($Command -eq 'ids') { return Get-ArchiveIds $c }
    if ($Command -eq 'set-counter' -and (!$p.Execute -or $p.DryRun -or $WhatIfPreference)) { return Counter-ChangePreview $c $p }
    if ($Command -in @('delete-disc-record','restore-disc-record') -and (!$p.Execute -or $p.DryRun -or $WhatIfPreference)) { return Disc-RecordChangePreview $c $p ($Command -eq 'restore-disc-record') }
    if ($Command -eq 'delete-orphan-set' -and (!$p.Execute -or $p.DryRun -or $WhatIfPreference)) { return Orphan-SetChangePreview $c $p }
    if ($Command -eq 'discard-unburned-plan' -and (!$p.Execute -or $p.DryRun -or $WhatIfPreference)) { return Unburned-PlanChangePreview $c $p }
    if ($Command -eq 'clear-simulation' -and (!$p.Execute -or $p.DryRun -or $WhatIfPreference)) { return Simulation-ClearPreview $c $p }
    if (!$p.Execute -or $p.DryRun -or $WhatIfPreference) {
        # This branch does not create a lock, DB, log, output directory or call
        # external tools. All production actions are opt-in via -Execute.
        return [pscustomobject]@{status='DRY_RUN';command=$Command;archive_root=$c.archive_root;parameters=$p;note='No files or media changed. Add -Execute for local work; physical burn also needs -BurnConfirmed and user entry of the exact disc phrase, deletion needs -DeleteSourceConfirmed.'}
    }
    if (!$PSCmdlet.ShouldProcess($c.archive_root,$Command)) { return }
    Assert-NoLinks $c.archive_root
    if ($Command -notin @('init','set-counter','prepare') -and !(Test-Path -LiteralPath (Catalog-Path $c))) { throw 'Initialize the archive first: init-archive.ps1 -Execute.' }
    [IO.Directory]::CreateDirectory($c.archive_root) | Out-Null
    $locks=@();$previousConfig=$script:ArchiveOperationConfig
    try {
        $locks=Enter-ArchiveOperationLocks $c $Command $p
        $script:ArchiveOperationConfig=@{path=$configPath;value=$c}
        if ($Command -ne 'repair-identity-change') { Assert-NoPendingIdentityChange $c }
        if ($Command -eq 'set-counter') {
            $null=Counter-ChangePreview $c $p
            if (!(Test-Path -LiteralPath (Catalog-Path $c))) { $null=Initialize-Archive $c }
        }
        Assert-PreparationRunning
        if ($Command -eq 'prepare') {return Prepare-Archive $c $p}
        if ($Command -in @('build','stage')) { Resume-InterruptedOutput $c $(if ($Command -eq 'build') {'build'} else {'staging'}) $p.DiscId }
        Set-PreparationProgress $Command '' -Force
        switch ($Command) {
            'import-stage' {Import-ExternalPhotoStage $c $p}
            'rename-disc' { Rename-ArchiveDisc $c $p }
            'rename-set' { Rename-ArchiveSet $c $p }
            'repair-identity-change' { Repair-PendingIdentityChange $c }
            'init' { Initialize-Archive $c }
            'scan' { Ingest-Archive $c $p }
            'plan' { Plan-Archive $c $p }
            'build' { Build-ArchiveDwarfs $c $p }
            'verify-dwarfs' { Verify-DwarfsImage $c (Full-Path $p.Image) }
            'split-video' { Split-ArchiveVideo $c $p }
            'contact-sheet' { Contact-Sheet $c $p }
            'stage' { Stage-Archive $c $p }
            'par2' {
                # PAR2 is sealed atomically with staging. Never add recovery
                # files to an already sealed/burned disc and invalidate hashes.
                $d=Selected-PlanDisc $c $p
                if ($d.budget.par2_percent -le 0) { throw 'Plan with -ParPercent 5 first.' }
                Stage-Archive $c $p
            }
            'burn' { Burn-Archive $c $p }
            'recover-burn' { Recover-UnwrittenBurn $c $p }
            'clear-simulation' { Clear-ArchiveSimulation $c $p }
            'verify' { Verify-ArchiveDisc $c $p }
            'repair-verify' { Repair-VerificationPreflight $c $p }
            'register' { Register-ArchiveDisc $c $p }
            'restore' { Restore-ArchiveSet $c $p }
            'mount' { Mount-ArchiveDwarfs $c $p }
            'delete-source' { Delete-ArchiveSource $c $p }
            'catalog' { Read-Json (Catalog-Path $c) }
            'summary' { Export-ArchiveSummary $c $p }
            'set-counter' { Set-ArchiveCounter $c $p }
            'export-index' { Export-ArchiveIndex $c }
            'delete-disc-record' { Change-DiscRecord $c $p $false }
            'restore-disc-record' { Change-DiscRecord $c $p $true }
            'delete-orphan-set' { Delete-OrphanSet $c $p }
            'discard-unburned-plan' { Discard-UnburnedPlan $c $p }
            default { throw "Unknown command: $Command" }
        }
        if ($Command -in @('import-stage','scan','plan','stage','par2','burn','recover-burn','clear-simulation','verify','repair-verify','register','restore','delete-source','delete-disc-record','restore-disc-record')) {
            $summarySet=$p.SetId
            if (!$summarySet -and $p.DiscId) { $summarySet=(Get-Disc $c $p.DiscId -IncludeDeleted).archive_set_id }
            if ($summarySet) {
                $summaryParams=$p.Clone();$summaryParams.SetId=$summarySet
                $null=Export-ArchiveSummary $c $summaryParams
            }
        }
        if ($Command -in @('import-stage','init','set-counter','plan','stage','burn','recover-burn','clear-simulation','verify','repair-verify','register','delete-disc-record','restore-disc-record','delete-orphan-set','discard-unburned-plan')) { $null=Export-ArchiveIndex $c }
        if ($Command -in @('import-stage','init','set-counter','scan','plan','stage','burn','recover-burn','clear-simulation','register','verify','repair-verify','restore','delete-source','summary','delete-disc-record','restore-disc-record','delete-orphan-set','discard-unburned-plan','rename-disc','rename-set','repair-identity-change')) {
            # JSON is the authoritative catalog. SQLite is a rebuildable index;
            # failure to sync must never falsify archive verification status.
            try {
                Sync-ArchiveCatalog $c
            } catch { if (Is-PreparationCancellation $_) { throw };Write-Warning "JSON catalog saved. SQLite sync unavailable: $($_.Exception.Message)" }
        }
    } catch {
        # Preserve any incomplete build/stage output after a tool failure, not
        # only an explicit user cancellation.  This makes PAR2/tool errors
        # resumable without deleting a valid DwarFS build or leaving a stage
        # directory that blocks the next attempt.
        if ($locks.Count -and $Command -in @('build','stage')) {
            Mark-InterruptedOutput $c $(if ($Command -eq 'build') {'build'} else {'staging'}) $p.DiscId
        }
        if ($locks.Count) { Event $c 'command-failed' @{command=$Command;error=$_.Exception.Message} }
        throw
    } finally { $script:ArchiveOperationConfig=$previousConfig;Exit-ArchiveOperationLocks $locks }
}
