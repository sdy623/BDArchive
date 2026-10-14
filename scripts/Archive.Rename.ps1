# Explicit, revisioned ID changes for unburned archive sets. Payload bytes are
# never copied/rehashed/recompiled. Every mutation runs under archive.lock.
function Assert-RenameableRecord($R) {
    if ((Optional-Field $R 'catalog_deleted') -or $R.burn -or $R.burn_date -or $R.verification -or $R.registered -or $R.original_deleted -or $R.status -notin @('PLANNED','BUILT','STAGED')) { throw "Set contains written/verified media, deleted records or an unsupported state: $($R.disc_id). Physical disc identities cannot be rewritten." }
}
function Assert-SetIdAvailable($C,$Cat,[string]$Id) {
    Assert-Id $Id
    if (@($Cat.sets | Where-Object archive_set_id -eq $Id).Count -or @((Optional-Field $Cat 'set_aliases') | Where-Object { $_ -and $_.old_id -eq $Id }).Count) { throw "Archive ID already exists or is reserved by rename history: $Id" }
    if (Test-Path -LiteralPath (Set-Dir $C $Id)) { throw "Archive ID has existing files: $Id" }
}
function Get-SetRenameContext($C,$P) {
    Assert-NoPendingIdentityChange $C;Assert-Id $P.SetId;Assert-Id $P.NewSetId
    $cat=Read-Json (Catalog-Path $C);Ensure-CatalogIdentity $cat
    Assert-SetIdAvailable $C $cat $P.NewSetId
    $set=@($cat.sets | Where-Object archive_set_id -ceq $P.SetId)
    if ($set.Count -ne 1 -or $set[0].original_deleted) { throw 'Archive set is missing or its original was deleted.' };$set=$set[0]
    if (Optional-Field $set 'manifest_directory') {throw '已接入的外部目录不支持改归档 ID。'}
    $plan=Load-Plan $C $P.SetId;$ing=Load-Ingest $C $P.SetId
    if ($plan.archive_set_id -cne $P.SetId -or $ing.archive_set_id -cne $P.SetId -or (File-Hash (Join-Path (Set-Dir $C $P.SetId) 'ingest.json')) -ne $plan.ingest_sha256 -or $plan.ingest_sha256 -ne $set.ingest_sha256) { throw 'Ingest manifest/plan/catalog identity differs.' }
    $records=@($cat.discs | Where-Object archive_set_id -ceq $P.SetId)
    if (!$records.Count -or $records.Count -ne $plan.discs.Count) { throw 'Plan/catalog disc membership differs.' }
    $stages=New-Object 'System.Collections.Generic.List[object]';$labels=@{}
    $templates=[ordered]@{udf=(Optional-Field $plan 'volume_label_template');iso9660='';joliet='';system='';volume_set='';publisher='';data_preparer='';application=''}
    if (!$templates.udf) { $templates.udf='{disc_id}' }
    foreach ($key in @('iso9660','joliet','system','volume_set','publisher','data_preparer','application')) { $templates[$key]=[string](Optional-Field (Optional-Field $plan 'volume_templates') $key) }
    foreach ($r in $records) {
        Assert-RenameableRecord $r
        $d=@($plan.discs | Where-Object disc_id -ceq $r.disc_id)
        if ($d.Count -ne 1) { throw 'Plan/catalog disc membership differs.' };$d=$d[0]
        foreach ($key in @('catalog_id','disc_index','volume_id','volume_label','volume_index','volume_count','identity_origin')) {
            if ($null -eq (Optional-Field $d $key)) { $d | Add-Member NoteProperty $key $r.$key -Force }
        }
        $stage=Safe-Join $C.archive_root ('staging/'+$r.disc_id)
        if ($r.stage -and (Full-Path $r.stage.path) -cne $stage) { throw 'External staging path cannot be renamed.' }
        if (Test-Path -LiteralPath $stage) { $stages.Add($r.disc_id) }
        elseif ($r.stage) { throw "Saved staging is missing: $($r.disc_id)" }
        $d.archive_set_id=$P.NewSetId
        $label=Format-VolumeLabel $templates.udf $d
        if ($labels.ContainsKey($label) -or @($cat.discs | Where-Object { $_.archive_set_id -cne $P.SetId -and (Disc-Identity $_).volume_label -ieq $label }).Count) { throw "New volume label is already allocated: $label" }
        $labels[$label]=$true;$d | Add-Member NoteProperty volume_label $label -Force
        $d | Add-Member NoteProperty authoring_metadata (New-VolumeMetadata ([pscustomobject]$templates) $d) -Force
    }
    @{catalog=$cat;set=$set;plan=$plan;ingest=$ing;stages=$stages.ToArray()}
}
function Set-RenamePreview($C,$P) {
    $x=Get-SetRenameContext $C $P
    @{status='DRY_RUN';action='rename-set';old_set_id=$P.SetId;new_set_id=$P.NewSetId;discs=@($x.plan.discs | Select-Object disc_id,disc_index,volume_id,volume_label);staging_to_reprepare=@($x.stages);payload_recompiled=$false;payload_rehashed=$false;old_url_redirects=$true;note='Disc IDs, catalog indices and logical Volume IDs stay stable. All saved templates are re-expanded. Existing staging is preserved in history and must be prepared again.'}
}
function Rename-ArchiveSet($C,$P) {
    $x=Get-SetRenameContext $C $P
    $transaction='identity-history/rename-'+[guid]::NewGuid().ToString('N');$dir=Safe-Join $C.archive_root $transaction
    $moves=New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in $x.stages) { $moves.Add(@{from=('staging/'+$id);to=($transaction+'/staging/'+$id)}) }
    $moves.Add(@{from=('sets/'+$P.SetId);to=('sets/'+$P.NewSetId)})
    $paths=@('catalog.json','disc-index.json','disc-index.csv','disc-labels.csv')
    foreach ($name in @('ingest.json','plan.json','plan.csv','ARCHIVE-SUMMARY.json','ARCHIVE-SUMMARY.txt','PHOTO-CATALOG.csv')) { $paths+=('sets/'+$P.SetId+'/'+$name) }
    $files=New-Object 'System.Collections.Generic.List[object]';$i=0
    [IO.Directory]::CreateDirectory((Join-Path $dir 'before'))|Out-Null
    foreach ($path in $paths) {
        $original=Safe-Join $C.archive_root $path;$exists=[IO.File]::Exists($original);$backup='before/'+$i+'.bin';$hash=$null
        if ($exists) { [IO.File]::Copy($original,(Safe-Join $dir $backup),$false);$hash=File-Hash (Safe-Join $dir $backup) }
        $files.Add(@{path=$path;existed=$exists;backup=$backup;sha256=$hash});$i++
    }
    Write-Json (Join-Path $dir 'journal.json') @{action='rename-set';transaction=$transaction;old_id=$P.SetId;new_id=$P.NewSetId;set_id=$P.SetId;moves=$moves.ToArray();files=$files.ToArray()}
    Write-Json (Join-Path $C.archive_root 'pending-identity-change.json') @{transaction=$transaction}
    try {
        foreach ($m in $moves) { Move-IdentityArtifact $C $m.from $m.to }
        $time=[DateTime]::UtcNow.ToString('o');$cat=$x.catalog;$newDir=Set-Dir $C $P.NewSetId
        $x.ingest.archive_set_id=$P.NewSetId
        $x.ingest | Add-Member NoteProperty identity_revision ([int](Optional-Field $x.ingest 'identity_revision')+1) -Force
        Write-Json (Join-Path $newDir 'ingest.json') $x.ingest
        $newIngestHash=File-Hash (Join-Path $newDir 'ingest.json')
        $x.plan.archive_set_id=$P.NewSetId;$x.plan.ingest_sha256=$newIngestHash
        $x.plan | Add-Member NoteProperty identity_revision ([int](Optional-Field $x.plan 'identity_revision')+1) -Force
        $x.plan | Add-Member NoteProperty identity_revision_at $time -Force
        $x.set.archive_set_id=$P.NewSetId;$x.set.ingest_sha256=$newIngestHash;$x.set.restore_test=$null
        foreach ($r in $cat.discs) {
            if ($r.archive_set_id -ceq $P.SetId) {
                $d=@($x.plan.discs | Where-Object disc_id -ceq $r.disc_id)[0]
                $r.archive_set_id=$P.NewSetId;$r.stage=$null;$r.hash=$null;$r.status='PLANNED'
                foreach ($key in @('volume_label','authoring_metadata')) { $r | Add-Member NoteProperty $key $d.$key -Force }
            }
        }
        $aliases=@(Optional-Field $cat 'set_aliases' | Where-Object { $null -ne $_ })
        foreach ($alias in $aliases) { if ($alias.new_id -ceq $P.SetId) { $alias.new_id=$P.NewSetId } }
        $aliases+=@{old_id=$P.SetId;new_id=$P.NewSetId;time=$time};$cat | Add-Member NoteProperty set_aliases $aliases -Force
        $cat.updated_at=$time;Ensure-CatalogIdentity $cat
        Write-Json (Join-Path $newDir 'plan.json') $x.plan;Write-Json (Catalog-Path $C) $cat
        Export-RenamedPlanCsv $C $x.plan
        $null=Export-ArchiveSummary $C @{SetId=$P.NewSetId;RefreshMetadata=$false;NoSourceRead=$true};$null=Export-ArchiveIndex $C
        Write-Json (Join-Path $dir 'COMMITTED.json') @{time=$time;old_set_id=$P.SetId;new_set_id=$P.NewSetId}
        [IO.File]::Delete((Join-Path $C.archive_root 'pending-identity-change.json'))
    } catch {
        $failure=$_
        try { $null=Repair-PendingIdentityChange $C } catch { throw "ID change failed; recovery journal retained at $dir. $($_.Exception.Message)" }
        throw $failure
    }
    Event $C 'rename-set' @{old_set_id=$P.SetId;new_set_id=$P.NewSetId;history=$dir;reason=$P.Reason}
    @{status='RENAMED';old_set_id=$P.SetId;new_set_id=$P.NewSetId;discs=@($x.plan.discs | Select-Object disc_id,disc_index,volume_id,volume_label);image_recompiled=$false;payload_rehashed=$false;staging_to_reprepare=@($x.stages);history=$dir}
}
function Assert-NoPendingIdentityChange($C) {
    if (Test-Path -LiteralPath (Join-Path $C.archive_root 'pending-identity-change.json')) { throw 'An interrupted ID change needs recovery: manage-ids.ps1 -Command repair-identity-change -Execute' }
}
function Get-DiscRenameContext($C,$P) {
    Assert-NoPendingIdentityChange $C
    $null=Disc-Number $P.DiscId;$null=Disc-Number $P.NewDiscId
    if ($P.DiscId -ceq $P.NewDiscId) { throw 'The new disc ID is unchanged.' }
    $cat=Read-Json (Catalog-Path $C);Ensure-CatalogIdentity $cat
    $null=Get-Disc $C $P.DiscId
    $record=@($cat.discs | Where-Object disc_id -ceq $P.DiscId)[0]
    Assert-DiscIdAvailable $C $cat $P.NewDiscId
    $set=@($cat.sets | Where-Object archive_set_id -eq $record.archive_set_id)
    if ($set.Count -ne 1 -or $set[0].original_deleted) { throw 'Archive set is missing or its original was deleted.' }
    if (Optional-Field $set[0] 'manifest_directory') {throw '已接入的外部目录不支持改盘号。'}
    $plan=Load-Plan $C $record.archive_set_id
    if ($plan.archive_set_id -cne $record.archive_set_id -or (File-Hash (Join-Path (Set-Dir $C $record.archive_set_id) 'ingest.json')) -ne $plan.ingest_sha256 -or $plan.ingest_sha256 -ne $set[0].ingest_sha256) { throw 'Ingest manifest differs from the saved plan/catalog.' }
    $disc=@($plan.discs | Where-Object disc_id -ceq $P.DiscId)
    if ($disc.Count -ne 1) { throw 'Disc is not uniquely present in the saved plan.' };$disc=$disc[0]
    foreach ($key in @('catalog_id','disc_index','volume_id','volume_label','volume_index','volume_count','identity_origin')) {
        if ($null -eq (Optional-Field $disc $key)) { $disc | Add-Member NoteProperty $key $record.$key -Force }
    }
    $records=@($cat.discs | Where-Object archive_set_id -eq $record.archive_set_id)
    if ($records.Count -ne $plan.discs.Count) { throw 'Plan/catalog disc membership differs.' }
    $stages=New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $records) {
        Assert-RenameableRecord $r
        $planDisc=@($plan.discs | Where-Object disc_id -ceq $r.disc_id)
        if ($planDisc.Count -ne 1) { throw 'Plan/catalog disc membership differs.' }
        # Legacy plans may have been written before catalog identity fields
        # (disc_index, volume_id, and label) were persisted in plan.json.
        # Rename commits export the complete plan.csv, so backfill every plan
        # disc from the identity-enriched catalog snapshot, not only the disc
        # selected for the rename.
        foreach ($key in @('catalog_id','disc_index','volume_id','volume_label','volume_index','volume_count','identity_origin')) {
            if ($null -eq (Optional-Field $planDisc[0] $key)) { $planDisc[0] | Add-Member NoteProperty $key $r.$key -Force }
        }
        $stage=Safe-Join $C.archive_root ('staging/'+$r.disc_id)
        if ($r.stage -and (Full-Path $r.stage.path) -cne $stage) { throw 'External staging path cannot be renamed.' }
        if (Test-Path -LiteralPath $stage) { $stages.Add($r.disc_id) }
        elseif ($r.stage) { throw "Saved staging is missing: $($r.disc_id)" }
    }
    $oldBuild=Safe-Join $C.archive_root ('build/'+$P.DiscId);$build=$null
    if (Test-Path -LiteralPath $oldBuild) {
        $report=Join-Path $oldBuild 'build.json'
        if (!(Test-Path -LiteralPath $report)) { throw 'Incomplete build must be resolved before changing its ID.' }
        $build=Read-Json $report
        if ($build.disc_id -cne $P.DiscId -or (Full-Path $build.image) -cne (Join-Path $oldBuild ($P.DiscId+'.dwarfs'))) { throw 'Build report identity/path differs from the selected disc.' }
        Assert-NoLinks $build.image
        if (!(Test-Path -LiteralPath $build.image) -or (Get-Item -LiteralPath $build.image).Length -ne $build.image_bytes -or $build.verification.status -ne 'PASS' -or $build.verification.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Completed image/report is missing or inconsistent.' }
    }
    $labelTemplate=Optional-Field $plan 'volume_label_template';if (!$labelTemplate) {$labelTemplate='{disc_id}'}
    $disc.disc_id=$P.NewDiscId
    $label=Format-VolumeLabel $labelTemplate $disc
    foreach ($r in $cat.discs) { if ($r.disc_id -cne $P.DiscId -and (Disc-Identity $r).volume_label -ieq $label) { throw "New volume label is already allocated: $label" } }
    $disc | Add-Member NoteProperty volume_label $label -Force
    foreach ($field in @('disc_prefix','disc_number')) { $disc | Add-Member NoteProperty $field (Disc-Identity $disc).$field -Force }
    $templates=[ordered]@{udf=$labelTemplate;iso9660='';joliet='';system='';volume_set='';publisher='';data_preparer='';application=''}
    foreach ($key in @('iso9660','joliet','system','volume_set','publisher','data_preparer','application')) { $templates[$key]=[string](Optional-Field (Optional-Field $plan 'volume_templates') $key) }
    $disc | Add-Member NoteProperty authoring_metadata (New-VolumeMetadata ([pscustomobject]$templates) $disc) -Force
    @{catalog=$cat;record=$record;plan=$plan;disc=$disc;set=$set[0];records=$records;stages=$stages.ToArray();build=$build;old_build=$oldBuild}
}
function Disc-RenamePreview($C,$P) {
    $x=Get-DiscRenameContext $C $P
    [pscustomobject]@{status='DRY_RUN';action='rename-disc';archive_set_id=$x.record.archive_set_id;old_disc_id=$P.DiscId;new_disc_id=$P.NewDiscId;disc_index=$x.disc.disc_index;volume_id=$x.disc.volume_id;old_volume_label=$x.record.volume_label;new_volume_label=$x.disc.volume_label;compiled_image_preserved=[bool]$x.build;payload_recompiled=$false;payload_rehashed=$false;staging_to_reprepare=@($x.stages);old_url_redirects=$true;note='ID change keeps the same catalog index and Volume ID. Existing staging for this whole set is preserved in history and must be prepared again because its full set manifest changes.'}
}
function Move-IdentityArtifact($C,$From,$To) {
    $source=Safe-Join $C.archive_root $From;$target=Safe-Join $C.archive_root $To
    if (!(Test-Path -LiteralPath $source) -or (Test-Path -LiteralPath $target)) { throw "ID change move conflict: $From -> $To" }
    [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
    # Both resolved paths are constrained to this archive; no other shell is used.
    if ([IO.Directory]::Exists($source)) { [IO.Directory]::Move($source,$target) }
    else { [IO.File]::Move($source,$target) }
}
function Read-IdentityJournal($C) {
    $pointer=Read-Json (Join-Path $C.archive_root 'pending-identity-change.json')
    if ($pointer.transaction -cnotmatch '^identity-history/rename-[0-9a-f]{32}$') { throw 'Invalid identity recovery path.' }
    $dir=Safe-Join $C.archive_root $pointer.transaction;$j=Read-Json (Join-Path $dir 'journal.json')
    if ($j.transaction -cne $pointer.transaction -or $j.action -notin @('rename-disc','rename-set')) { throw 'Invalid identity recovery journal.' }
    if ($j.action -eq 'rename-disc') { $null=Disc-Number $j.old_id;$null=Disc-Number $j.new_id }
    else { Assert-Id $j.old_id;Assert-Id $j.new_id }
    Assert-Id $j.set_id
    foreach ($m in $j.moves) { $null=Safe-Join $C.archive_root $m.from;$null=Safe-Join $C.archive_root $m.to }
    foreach ($f in $j.files) {
        if ($f.path -notmatch '^(catalog\.json|disc-(index\.(json|csv)|labels\.csv)|sets/[A-Za-z0-9_-]+/(ingest\.json|plan\.(json|csv)|ARCHIVE-SUMMARY\.(json|txt)|PHOTO-CATALOG\.csv)|build/[A-Z0-9_-]+/build\.json)$') { throw 'Unexpected metadata recovery target.' }
        $null=Safe-Join $C.archive_root $f.path
        if ($f.existed) {
            if ($f.backup -cnotmatch '^before/[0-9]+\.bin$' -or (File-Hash (Safe-Join $dir $f.backup)) -ne $f.sha256) { throw 'Identity recovery backup was changed.' }
        }
    }
    $j
}
function Repair-PendingIdentityChange($C) {
    $pending=Join-Path $C.archive_root 'pending-identity-change.json'
    if (!(Test-Path -LiteralPath $pending)) { return @{status='NO_PENDING_CHANGE'} }
    $j=Read-IdentityJournal $C;$dir=Safe-Join $C.archive_root $j.transaction
    if (Test-Path -LiteralPath (Join-Path $dir 'COMMITTED.json')) {
        [IO.File]::Delete($pending);return @{status='ALREADY_COMMITTED';action=$j.action;new_id=$j.new_id}
    }
    for ($i=$j.moves.Count-1;$i -ge 0;$i--) {
        $m=$j.moves[$i];$from=Safe-Join $C.archive_root $m.from;$to=Safe-Join $C.archive_root $m.to
        if ((Test-Path -LiteralPath $to) -and !(Test-Path -LiteralPath $from)) { Move-IdentityArtifact $C $m.to $m.from }
        elseif (Test-Path -LiteralPath $to) { throw "Both ID-change paths exist; manual recovery required: $($m.from)" }
    }
    foreach ($f in $j.files) {
        $target=Safe-Join $C.archive_root $f.path
        if ($f.existed) { [IO.Directory]::CreateDirectory((Split-Path $target))|Out-Null;[IO.File]::Copy((Safe-Join $dir $f.backup),$target,$true) }
        elseif ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
    }
    Write-Json (Join-Path $dir 'ROLLED-BACK.json') @{time=[DateTime]::UtcNow.ToString('o');old_disc_id=$j.old_id}
    [IO.File]::Delete($pending)
    @{status='ROLLED_BACK';action=$j.action;old_id=$j.old_id;history=$dir}
}
function Export-RenamedPlanCsv($C,$Plan) {
    $rows=foreach ($d in $Plan.discs) { foreach ($f in $d.files) { [pscustomobject]@{disc_id=$d.disc_id;disc_index=$d.disc_index;volume_id=$d.volume_id;volume_label=$d.volume_label;position=$d.position;disc_count=$d.disc_count;path=$f.path;bytes=$f.size;sha256=$f.sha256} } }
    $rows | Export-Csv -LiteralPath (Join-Path (Set-Dir $C $Plan.archive_set_id) 'plan.csv') -NoTypeInformation -Encoding UTF8
}
function Rename-ArchiveDisc($C,$P) {
    $x=Get-DiscRenameContext $C $P
    $transaction='identity-history/rename-'+[guid]::NewGuid().ToString('N');$dir=Safe-Join $C.archive_root $transaction
    $moves=New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in $x.stages) { $moves.Add(@{from=('staging/'+$id);to=($transaction+'/staging/'+$id)}) }
    if ($x.build) {
        $moves.Add(@{from=('build/'+$P.DiscId);to=('build/'+$P.NewDiscId)})
        $moves.Add(@{from=('build/'+$P.NewDiscId+'/'+$P.DiscId+'.dwarfs');to=('build/'+$P.NewDiscId+'/'+$P.NewDiscId+'.dwarfs')})
    }
    $paths=@('catalog.json','disc-index.json','disc-index.csv','disc-labels.csv')
    foreach ($name in @('plan.json','plan.csv','ARCHIVE-SUMMARY.json','ARCHIVE-SUMMARY.txt','PHOTO-CATALOG.csv')) { $paths+=('sets/'+$x.record.archive_set_id+'/'+$name) }
    if ($x.build) { $paths+=('build/'+$P.DiscId+'/build.json') }
    $files=New-Object 'System.Collections.Generic.List[object]';$i=0
    [IO.Directory]::CreateDirectory((Join-Path $dir 'before'))|Out-Null
    foreach ($path in $paths) {
        $original=Safe-Join $C.archive_root $path;$exists=[IO.File]::Exists($original);$backup='before/'+$i+'.bin';$hash=$null
        if ($exists) { [IO.File]::Copy($original,(Safe-Join $dir $backup),$false);$hash=File-Hash (Safe-Join $dir $backup) }
        $files.Add(@{path=$path;existed=$exists;backup=$backup;sha256=$hash});$i++
    }
    $j=@{action='rename-disc';transaction=$transaction;old_id=$P.DiscId;new_id=$P.NewDiscId;set_id=$x.record.archive_set_id;moves=$moves.ToArray();files=$files.ToArray()}
    Write-Json (Join-Path $dir 'journal.json') $j
    Write-Json (Join-Path $C.archive_root 'pending-identity-change.json') @{transaction=$transaction}
    try {
        foreach ($m in $moves) { Move-IdentityArtifact $C $m.from $m.to }
        $time=[DateTime]::UtcNow.ToString('o')
        if ($x.build) {
            $newBuild=Safe-Join $C.archive_root ('build/'+$P.NewDiscId)
            $x.build.disc_id=$P.NewDiscId;$x.build.image=Join-Path $newBuild ($P.NewDiscId+'.dwarfs');$x.build.input_list=Join-Path $newBuild 'input-files.txt'
            $x.build.verification.image=$x.build.image
            $x.build | Add-Member NoteProperty identity_renamed_at $time -Force
            # arguments/log remain the actual historical invocation; no new
            # integrity or SHA256 PASS is claimed merely from renaming a file.
            Write-Json (Join-Path $newBuild 'build.json') $x.build
        }
        $cat=$x.catalog;$record=@($cat.discs | Where-Object disc_id -ceq $P.DiscId)[0]
        $record.disc_id=$P.NewDiscId
        foreach ($key in @('volume_label','disc_prefix','disc_number','authoring_metadata')) { $record | Add-Member NoteProperty $key $x.disc.$key -Force }
        $record.nfc_url=$C.nfc_base_url.TrimEnd('/')+'/disc/'+$P.NewDiscId
        $aliases=@(Optional-Field $cat 'disc_aliases' | Where-Object { $null -ne $_ })
        foreach ($alias in $aliases) { if ($alias.new_id -ceq $P.DiscId) { $alias.new_id=$P.NewDiscId } }
        $aliases+=@{old_id=$P.DiscId;new_id=$P.NewDiscId;time=$time}
        $cat | Add-Member NoteProperty disc_aliases $aliases -Force
        foreach ($r in $cat.discs) {
            if ($r.archive_set_id -eq $x.record.archive_set_id) { $r.stage=$null;$r.hash=$null;$r.status='PLANNED' }
        }
        $set=@($cat.sets | Where-Object archive_set_id -eq $x.record.archive_set_id)[0];$set.restore_test=$null
        $cat.updated_at=$time;Ensure-CatalogIdentity $cat
        $x.plan | Add-Member NoteProperty identity_revision ([int](Optional-Field $x.plan 'identity_revision')+1) -Force
        $x.plan | Add-Member NoteProperty identity_revision_at $time -Force
        if ((Optional-Field $x.plan 'start_disc_id') -ceq $P.DiscId) { $x.plan.start_disc_id=$x.plan.discs[0].disc_id }
        Write-Json (Join-Path (Set-Dir $C $x.record.archive_set_id) 'plan.json') $x.plan
        Write-Json (Catalog-Path $C) $cat
        Export-RenamedPlanCsv $C $x.plan
        $sp=@{SetId=$x.record.archive_set_id;RefreshMetadata=$false;NoSourceRead=$true}
        # Summary consumes saved metadata; it does not rebuild the archive.
        $null=Export-ArchiveSummary $C $sp;$null=Export-ArchiveIndex $C
        Write-Json (Join-Path $dir 'COMMITTED.json') @{time=$time;old_disc_id=$P.DiscId;new_disc_id=$P.NewDiscId}
        [IO.File]::Delete((Join-Path $C.archive_root 'pending-identity-change.json'))
    } catch {
        $failure=$_
        try { $null=Repair-PendingIdentityChange $C } catch { throw "ID change failed; recovery journal retained at $dir. $($_.Exception.Message)" }
        throw $failure
    }
    Event $C 'rename-disc' @{old_disc_id=$P.DiscId;new_disc_id=$P.NewDiscId;history=$dir;reason=$P.Reason}
    @{status='RENAMED';old_disc_id=$P.DiscId;new_disc_id=$P.NewDiscId;archive_set_id=$x.record.archive_set_id;disc_index=$x.disc.disc_index;volume_id=$x.disc.volume_id;volume_label=$x.disc.volume_label;image_recompiled=$false;payload_rehashed=$false;staging_to_reprepare=@($x.stages);history=$dir}
}
