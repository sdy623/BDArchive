function Restore-ArchiveSet($C,$P) {
    $ing=Load-Ingest $C $P.SetId; $plan=Load-Plan $C $P.SetId
    $output=Full-Path $P.Output
    Assert-Separate $output $C.archive_root; Assert-Separate $output $ing.source_root; Assert-NoLinks $output
    if (!$P.MediaRoots -or !$P.MediaRoots.Count) { throw 'Provide -MediaRoots with mounted disc roots or saved disc copies. Repeat the command for sequential discs.' }
    [IO.Directory]::CreateDirectory($output) | Out-Null
    $receiptPath=Join-Path (Set-Dir $C $P.SetId) ('restore-'+(File-Hash (Join-Path (Set-Dir $C $P.SetId) 'plan.json')).Substring(0,12)+'.json')
    $receipt=@{output=$output;discs=@();status='PARTIAL';time=[DateTime]::UtcNow.ToString('o')}
    if (Test-Path -LiteralPath $receiptPath) {
        $previous=Read-Json $receiptPath
        if ($previous.output -eq $output) { $receipt.discs=@($previous.discs) }
    }
    foreach ($mediaRoot in $P.MediaRoots) {
        $root=Full-Path $mediaRoot; Assert-NoLinks $root
        $identity=Read-Json (Join-Path $root 'DISC.json')
        if ($identity.archive_set_id -ne $P.SetId) { throw 'Wrong archive set inserted.' }
        $record=Get-Disc $C $identity.disc_id
        $null=Check-DiscTree $C $root $record -Integrity
        $disc=@($plan.discs | Where-Object disc_id -eq $identity.disc_id)
        if ($disc.Count -ne 1) { throw 'Unexpected disc in restore set.' }; $disc=$disc[0]
        $readRoot=Join-Path $root 'data'
        if ($disc.dwarfs) {
            $readRoot=Safe-Join $C.archive_root ('build/restore-'+$disc.disc_id+'-'+[guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($readRoot) | Out-Null
            $null=Dwarfs-Run $C 'dwarfsextract' @('-i',(Join-Path $root "data/$($disc.disc_id).dwarfs"),'-o',$readRoot) 'restore-extract'
        }
        foreach ($f in $disc.files) {
            Copy-Checked (Safe-Join $readRoot $f.path) (Safe-Join $output $f.path) $f.sha256
            [IO.File]::SetLastWriteTimeUtc((Safe-Join $output $f.path),[DateTime]::Parse($f.mtime_utc).ToUniversalTime())
        }
        $receipt.discs=@($receipt.discs | Where-Object disc_id -ne $disc.disc_id)+@(@{disc_id=$disc.disc_id;manifest_sha256=$record.hash})
        Write-Json $receiptPath $receipt
    }
    # Restore aliases only after their canonical file is available, including
    # aliases whose canonical object lives on a different physical disc.
    if ($plan.deduplicated) {
        foreach ($f in $ing.files) {
            if ($f.alias_of) {
                $canonical=Safe-Join $output $f.alias_of
                if (Test-Path -LiteralPath $canonical) {
                    Copy-Checked $canonical (Safe-Join $output $f.path) $f.sha256
                    [IO.File]::SetLastWriteTimeUtc((Safe-Join $output $f.path),[DateTime]::Parse($f.mtime_utc).ToUniversalTime())
                }
            }
        }
    }
    foreach ($dir in $ing.directories) { [IO.Directory]::CreateDirectory((Safe-Join $output $dir)) | Out-Null }
    $missing=@()
    foreach ($f in $ing.files) {
        $path=Safe-Join $output $f.path
        if (!(Test-Path -LiteralPath $path)) { $missing+=,$f.path }
        elseif ((File-Hash $path) -ne $f.sha256) { throw "Restored file hash mismatch: $($f.path)" }
    }
    if (!$missing.Count -and @($receipt.discs).Count -eq @($plan.discs).Count) {
        if (@(Tree-Files $output).Count -ne @($ing.files).Count) { throw 'Restore destination contains extra files. Use a dedicated destination.' }
        $receipt.status='PASS'; $receipt.time=[DateTime]::UtcNow.ToString('o')
        Write-Json $receiptPath $receipt
        $catalogLease=Enter-CatalogLock $C
        try {
        $cat=Read-Json (Catalog-Path $C)
        foreach ($s in $cat.sets) { if ($s.archive_set_id -eq $P.SetId) { $s.restore_test=[pscustomobject]@{status='PASS';report=$receiptPath;report_sha256=(File-Hash $receiptPath);output=$output;time=$receipt.time} } }
        Write-Json (Catalog-Path $C) $cat
        } finally {Exit-ArchiveLock $catalogLease}
    }
    Event $C 'restore' @{set=$P.SetId;status=$receipt.status;missing_files=$missing.Count}
    @{status=$receipt.status;missing_files=$missing.Count;discs_read=@($receipt.discs).Count;discs_total=@($plan.discs).Count;output=$output;receipt=$receiptPath}
}
function Delete-ArchiveSource($C,$P) {
    $setRecord=@((Read-Json (Catalog-Path $C)).sets | Where-Object archive_set_id -eq $P.SetId)
    if ($setRecord.Count -eq 1 -and (Optional-Field $setRecord[0] 'source_deletion_disabled')) {throw '接入的链接目录不是原始来源；此归档禁用自动源删除。'}
    if (!$P.DeleteSourceConfirmed) { throw 'Source deletion requires -Execute -DeleteSourceConfirmed.' }
    $ing=Load-Ingest $C $P.SetId; $plan=Load-Plan $C $P.SetId
    $cat=Read-Json (Catalog-Path $C)
    $set=@($cat.sets | Where-Object archive_set_id -eq $P.SetId)[0]
    if ($set.original_deleted) { throw 'Source deletion is already recorded.' }
    $profile=Optional-Field $ing 'profile'
    if (($profile -and $profile.scenario -eq 'photo' -and $profile.photo_tier -in @('A','B')) -or $ing.category -eq 'M') {
        throw 'Tier A/B photos and core archives retain their source/other copies. Source deletion is not provided for these profiles.'
    }
    foreach ($d in $plan.discs) {
        $r=Get-Disc $C $d.disc_id
        if (!$r.registered -or $r.status -ne 'VERIFIED' -or !$r.verification -or $r.verification.simulation -or $r.verification.status -ne 'PASS' -or $r.verification.manifest_sha256 -ne $r.hash) { throw "Deletion blocked: $($d.disc_id) lacks registered physical verification." }
        if ((File-Hash $r.verification.report) -ne $r.verification.report_sha256) { throw 'Verification report changed.' }
        $v=Read-Json $r.verification.report
        if ($v.simulation -or $v.status -ne 'PASS' -or $v.disc_id -ne $d.disc_id -or !$v.media.finalized -or $v.manifest_sha256 -ne $r.hash) { throw 'Invalid physical verification evidence.' }
    }
    if ($C.safety.require_restore_test_before_delete -or $ing.category -eq 'III') {
        if (!$set.restore_test -or $set.restore_test.status -ne 'PASS') { throw 'Complete a full-set restore and hash check before deletion.' }
        if ((File-Hash $set.restore_test.report) -ne $set.restore_test.report_sha256) { throw 'Restore receipt changed.' }
    }
    if(@($ing.files | Where-Object {Optional-Field $_ 'reference_target'}).Count){throw 'Reference-based inputs require separate explicit source cleanup; delete-source is disabled.'}
    Assert-NoLinks $ing.source_root; Assert-Separate $ing.source_root $C.archive_root
    if ((File-Hash (Join-Path (Set-Dir $C $P.SetId) 'ingest.json')) -ne $plan.ingest_sha256) { throw 'Ingest evidence changed.' }
    # All-file preflight before any deletion; remove only recorded files, never
    # a computed directory recursively. Unrecorded additions block the action.
    if (@(Tree-Files $ing.source_root).Count -ne @($ing.files).Count) { throw 'Source tree file count changed; deletion is blocked.' }
    foreach ($f in $ing.files) {
        Assert-PlainFile (Safe-Join $ing.source_root $f.path)
        if ((File-Hash (Safe-Join $ing.source_root $f.path)) -ne $f.sha256) { throw "Source changed; deletion blocked: $($f.path)" }
    }
    Event $C 'delete-start' @{set=$P.SetId;source=$ing.source_root;files=$ing.files.Count}
    foreach ($f in $ing.files) {
        $path=Safe-Join $ing.source_root $f.path
        Assert-PlainFile $path
        # Recheck immediately before deleting each literal file. If interrupted,
        # stop and use events.jsonl to identify the deleted subset.
        if ((File-Hash $path) -ne $f.sha256) { throw 'Source changed during deletion; stopped.' }
        [IO.File]::Delete($path)
        Event $C 'deleted-file' @{set=$P.SetId;path=$f.path;sha256=$f.sha256}
    }
    $set.original_deleted=$true
    foreach ($r in $cat.discs) { if ($r.archive_set_id -eq $P.SetId) { $r.original_deleted=$true } }
    Write-Json (Catalog-Path $C) $cat
    @{status='SOURCE_FILES_DELETED';empty_directories_retained=$true;archive_set_id=$P.SetId}
}
