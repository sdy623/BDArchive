# Catalog identity is separate from optical filesystem identifiers.
# Set mutations hold their set lock; counter allocation uses a catalog transaction.
function Empty-Catalog {
    [pscustomobject]@{schema_version=1;updated_at=[DateTime]::UtcNow.ToString('o');sequences=[pscustomobject]@{P=0;G=0;B=0;M=0};sets=@();discs=@()}
}
function Catalog-Snapshot($C) {
    if (Test-Path -LiteralPath (Catalog-Path $C)) { return Read-Json (Catalog-Path $C) }
    Empty-Catalog
}
function Disc-Number([string]$Id) {
    # Safe, externally assigned prefixes are welcome. Keep the numeric suffix
    # and its padding, so IPA-001 -> IPA-002 and ARCHIVE42 -> ARCHIVE43.
    if ($Id -cmatch '^(COM[1-9]|LPT[1-9])$') { throw "Invalid disc ID: $Id is a reserved Windows device name." }
    if ($Id.Length -gt 32 -or $Id -cnotmatch '^([A-Z][A-Z0-9_-]*?)([0-9]+)$') { throw "Invalid physical disc ID: $Id. Use uppercase letters/digits/_/-, with a numeric suffix, at most 32 characters (e.g. IPA-001)." }
    $stem=$Matches[1];$width=$Matches[2].Length
    $n=[int64]$Matches[2]
    if ($n -lt 1 -or $n -gt 2147483647) { throw 'Disc number must be 1..2147483647.' }
    $prefix=$stem.TrimEnd('-','_');if ($stem -cmatch '^BD-([PGBM])-$') { $prefix=$Matches[1] }
    [pscustomobject]@{prefix=$prefix;number=$n;stem=$stem;width=$width;standard=($stem -cmatch '^BD-[PGBM]-$')}
}
function Counter-Value($Cat,[string]$Prefix) {
    if ($Prefix -cnotmatch '^[PGBM]$') { throw 'Prefix must be P, G, B or M.' }
    $high=[int64]$Cat.sequences.$Prefix
    if ($high -lt 0) { throw 'Counter must not be negative.' }
    foreach ($d in @(Optional-Field $Cat 'discs')) {
        if (!$d) { continue }
        $parts=Disc-Number $d.disc_id
        if ($parts.standard -and $parts.prefix -eq $Prefix) { $high=[math]::Max($high,$parts.number) }
    }
    $high
}
function Global-IndexValue($Cat) {
    $high=[int64](Optional-Field $Cat 'disc_index_sequence')
    foreach ($d in $Cat.discs) { $high=[math]::Max($high,[int64](Optional-Field $d 'disc_index')) }
    $high
}
function Next-DiscId($Catalog,$Prefix) {
    $next=(Counter-Value $Catalog $Prefix)+1
    if ($next -gt 2147483647) { throw 'Disc counter exhausted; no ID allocated.' }
    $Catalog.sequences.$Prefix=$next
    'BD-{0}-{1:D4}' -f $Prefix,$next
}
function Batch-DiscId([string]$StartId,[int]$Offset=0) {
    $parts=Disc-Number $StartId;$n=$parts.number+$Offset
    if ($Offset -lt 0 -or $n -gt 2147483647) { throw 'Batch disc number is outside 1..2147483647.' }
    $id=$parts.stem+$n.ToString('D'+$parts.width,[Globalization.CultureInfo]::InvariantCulture)
    $null=Disc-Number $id;$id
}
function Assert-DiscIdAvailable($C,$Cat,[string]$Id) {
    $null=Disc-Number $Id
    if (@($Cat.discs | Where-Object disc_id -eq $Id).Count) { throw "Disc ID already exists: $Id (including deleted records). Restore that record or choose an unused ID." }
    if (@((Optional-Field $Cat 'disc_aliases') | Where-Object { $_ -and $_.old_id -eq $Id }).Count) { throw "Disc ID is reserved by rename history: $Id" }
    foreach ($folder in @('staging','build','simulated')) {
        if (Test-Path -LiteralPath (Safe-Join $C.archive_root "$folder/$Id")) { throw "Disc ID has existing $folder files: $Id. Choose another unused ID." }
    }
}
function Disc-Identity($D) {
    $parts=Disc-Number $D.disc_id
    $label=Optional-Field $D 'volume_label';if (!$label) { $label=$D.disc_id }
    $volume=Optional-Field $D 'volume_id';if (!$volume) { $volume='{0}-V{1:D4}' -f $D.archive_set_id,[int]$D.position }
    $serial=$null;$media=Optional-Field (Optional-Field $D 'verification') 'media'
    if ($media -and !(Optional-Field $D.verification 'simulation')) { $serial=Optional-Field $media 'volume_serial' }
    $origin=Optional-Field $D 'identity_origin';if (!$origin) { $origin='derived_legacy' }
    [pscustomobject][ordered]@{
        disc_id=$D.disc_id;disc_index=(Optional-Field $D 'disc_index');disc_prefix=$parts.prefix;disc_number=$parts.number
        catalog_id=(Optional-Field $D 'catalog_id');archive_set_id=$D.archive_set_id
        volume_id=$volume;volume_index=[int]$D.position;volume_count=[int]$D.disc_count;volume_label=$label
        filesystem_serial=$serial;identity_origin=$origin
    }
}
function Ensure-CatalogIdentity($Cat) {
    # Migration enriches catalog only. Never rewrite old plan/staged/burned bytes.
    if (!(Optional-Field $Cat 'catalog_id')) { $Cat | Add-Member NoteProperty catalog_id ([guid]::NewGuid().ToString()) -Force }
    $high=Global-IndexValue $Cat
    $seen=@{};$ids=@{};$volumes=@{};$labels=@{}
    foreach ($d in $Cat.discs) {
        if ($ids.ContainsKey($d.disc_id)) { throw 'Duplicate disc ID in catalog.' };$ids[$d.disc_id]=$true
        $index=Optional-Field $d 'disc_index'
        if (!$index) { $high++;$index=$high;$d | Add-Member NoteProperty disc_index $index -Force }
        if ([int64]$index -le 0 -or $seen.ContainsKey([string]$index)) { throw 'Invalid/duplicate catalog disc index.' };$seen[[string]$index]=$true
        $identity=Disc-Identity $d
        if ($volumes.ContainsKey($identity.volume_id) -or $labels.ContainsKey($identity.volume_label)) { throw 'Duplicate volume ID or label in catalog.' }
        $volumes[$identity.volume_id]=$true;$labels[$identity.volume_label]=$true
        if (!(Optional-Field $d 'identity_origin')) { $d | Add-Member NoteProperty identity_origin 'catalog_backfill' }
        foreach ($key in @('volume_id','volume_label','volume_index','volume_count','disc_prefix','disc_number')) {
            if ($null -eq (Optional-Field $d $key)) { $d | Add-Member NoteProperty $key $identity.$key -Force }
        }
        if (!(Optional-Field $d 'catalog_id')) { $d | Add-Member NoteProperty catalog_id $Cat.catalog_id -Force }
        elseif ($d.catalog_id -cne $Cat.catalog_id) { throw 'Disc belongs to a different catalog identity.' }
    }
    foreach ($prefix in @('P','G','B','M')) { $Cat.sequences.$prefix=Counter-Value $Cat $prefix }
    $Cat | Add-Member NoteProperty disc_index_sequence $high -Force
    if ($null -eq (Optional-Field $Cat 'counter_history')) { $Cat | Add-Member NoteProperty counter_history @() -Force }
}
function Volume-LabelTemplate($C,$P) {
    $template=Optional-Field $P 'VolumeLabelTemplate'
    if (!$template) { $template=Optional-Field (Optional-Field $C 'numbering') 'volume_label_template' }
    if (!$template) { $template='{disc_id}' }
    $template
}
function Format-VolumeLabel([string]$Template,$D) {
    try { $result=Expand-ArchiveTemplate $Template $D } catch { throw "Volume label: $($_.Exception.Message)" }
    # Toolkit compatibility policy, not the maximum allowed by the UDF spec.
    # Never silently truncate, strip Unicode or change case to fit a label.
    if ($result -cnotmatch '^[A-Z0-9][A-Z0-9_-]{0,31}$') { throw 'Volume label must be 1..32 uppercase ASCII letters, digits, _ or -. Check unknown tokens and length. Use {disc_id} for a portable label.' }
    $result
}
function New-DiscIdentity($Cat,$Disc,[string]$Template) {
    $index=(Global-IndexValue $Cat)+1
    $Cat.disc_index_sequence=$index
    $Disc | Add-Member NoteProperty disc_index $index -Force
    $Disc | Add-Member NoteProperty catalog_id $Cat.catalog_id -Force
    $label=Format-VolumeLabel $Template $Disc
    foreach ($other in $Cat.discs) { if ((Disc-Identity $other).volume_label -ieq $label) { throw "Volume label is already allocated: $label. Use a unique template." } }
    $Disc | Add-Member NoteProperty volume_label $label -Force
    $Disc | Add-Member NoteProperty identity_origin 'planned' -Force
    $identity=Disc-Identity $Disc
    foreach ($key in @('volume_id','volume_index','volume_count','disc_prefix','disc_number')) { $Disc | Add-Member NoteProperty $key $identity.$key -Force }
}
function Archive-IndexRows($Cat) {
    foreach ($d in $Cat.discs) {
        $r=Disc-Identity $d
        foreach ($key in @('media_type','status','location','nfc_url','hash','catalog_deleted','catalog_deleted_at','catalog_delete_reason','authoring_metadata')) { $r | Add-Member NoteProperty $key (Optional-Field $d $key) }
        $r | Add-Member NoteProperty previous_disc_ids @((Optional-Field $Cat 'disc_aliases') | Where-Object { $_ -and $_.new_id -eq $d.disc_id } | Select-Object -ExpandProperty old_id)
        $r | Add-Member NoteProperty previous_set_ids @((Optional-Field $Cat 'set_aliases') | Where-Object { $_ -and $_.new_id -eq $d.archive_set_id } | Select-Object -ExpandProperty old_id)
        $r
    }
}
function Get-ArchiveIds($C) {
    $cat=Catalog-Snapshot $C;$rows=@(Archive-IndexRows $cat)
    $counters=foreach ($prefix in @('P','G','B','M')) {
        $high=Counter-Value $cat $prefix
        [pscustomobject]@{prefix=$prefix;last_number=$high;next_number=($high+1);next_disc_id=('BD-{0}-{1:D4}' -f $prefix,($high+1));allocated_discs=@($rows | Where-Object { $_.disc_id -cmatch ('^BD-'+$prefix+'-[0-9]+$') }).Count}
    }
    $legacy=@($rows | Where-Object { !$_.disc_index }).Count
    [pscustomobject]@{status='READ_ONLY';archive_root=$C.archive_root;catalog_id=(Optional-Field $cat 'catalog_id');disc_index_last=(Global-IndexValue $cat);disc_index_next=((Global-IndexValue $cat)+$legacy+1);legacy_unindexed=$legacy;counters=@($counters);discs=@($rows | Where-Object { !$_.catalog_deleted });deleted_discs=@($rows | Where-Object catalog_deleted);history=@(Optional-Field $cat 'counter_history' | Where-Object { $null -ne $_ });note='Automatic counters belong to this archive_root. A batch may start at any unused ID, including numbers below the automatic counter. Preview does not reserve IDs.'}
}
function Counter-ChangePreview($C,$P) {
    if ($P.Prefix -cnotmatch '^[PGBM]$' -or $null -eq $P.NextNumber) { throw 'Specify -Prefix P/G/B/M and -NextNumber.' }
    $next=[int64]$P.NextNumber
    if ($next -lt 1 -or $next -gt 2147483647) { throw 'NextNumber must be 1..2147483647.' }
    $cat=Catalog-Snapshot $C;$previous=(Counter-Value $cat $P.Prefix)+1
    $rollback=($next -lt $previous)
    if ($rollback -and !$P.AllowCounterRollback) { throw "Counter rollback/reuse is forbidden. Next number must be at least $previous; use -AllowCounterRollback only after removing unfinished records." }
    if ($rollback) {
        $blocked=@($cat.discs | Where-Object {
            $parts=Disc-Number $_.disc_id
            $parts.standard -and $parts.prefix -eq $P.Prefix -and $parts.number -ge $next
        })
        if ($blocked.Count) { throw "Cannot roll back $($P.Prefix) counter: catalog still contains $($blocked.Count) disc record(s) at or above $next)." }
        $aliases=@((Optional-Field $cat 'disc_aliases') | Where-Object {
            $_ -and ((Disc-Number $_.old_id).standard -and (Disc-Number $_.old_id).prefix -eq $P.Prefix -and (Disc-Number $_.old_id).number -ge $next) -or
            ($_ -and (Disc-Number $_.new_id).standard -and (Disc-Number $_.new_id).prefix -eq $P.Prefix -and (Disc-Number $_.new_id).number -ge $next)
        })
        if ($aliases.Count) { throw "Cannot roll back $($P.Prefix) counter: rename history reserves an ID at or above $next." }
    }
    [pscustomobject]@{status='DRY_RUN';prefix=$P.Prefix;previous_next=$previous;requested_next=$next;next_disc_id=('BD-{0}-{1:D4}' -f $P.Prefix,$next);skipped_count=($next-$previous);rollback=$rollback;note=$(if ($rollback) {'Explicit rollback of an unused high-water mark; existing records, aliases and sealed files were checked first.'} else {'Changes only future allocations; existing IDs, labels and sealed files remain intact.'})}
}
function Set-ArchiveCounter($C,$P) {
    $catalogLease=Enter-CatalogLock $C
    try {
    $preview=Counter-ChangePreview $C $P
    $cat=Catalog-Snapshot $C;Ensure-CatalogIdentity $cat
    $cat.sequences.($P.Prefix)=[int64]$P.NextNumber-1
    $entry=[pscustomobject]@{time=[DateTime]::UtcNow.ToString('o');prefix=$P.Prefix;previous_next=$preview.previous_next;requested_next=$preview.requested_next;rollback=[bool]$preview.rollback;reason=(Summary-Value $P.Reason)}
    $cat.counter_history+=,$entry;$cat.updated_at=$entry.time
    Write-Json (Catalog-Path $C) $cat;Event $C 'set-counter' $entry
    $preview.status='COUNTER_UPDATED';$preview
    } finally {Exit-ArchiveLock $catalogLease}
}
function Export-ArchiveIndex($C) {
    $catalogLease=Enter-ArchiveFileLock (Join-Path $C.archive_root 'locks/index.lock') '目录索引发布' -WaitMilliseconds 30000
    try {
    $snapshot=Get-ArchiveIds $C
    $json=Join-Path $C.archive_root 'disc-index.json';$csv=Join-Path $C.archive_root 'disc-index.csv'
    Write-Json $json $snapshot
    $columns=@('disc_id','disc_index','catalog_id','archive_set_id','volume_id','volume_index','volume_count','volume_label','filesystem_serial','status','location','nfc_url')
    $lines=@($snapshot.discs | Select-Object $columns | ConvertTo-Csv -NoTypeInformation)
    if (!$lines.Count) { $lines=@('"'+($columns -join '","')+'"') }
    Write-Text $csv (($lines -join "`r`n")+"`r`n")
    Write-Text (Join-Path $C.archive_root 'disc-labels.csv') (($lines -join "`r`n")+"`r`n")
    [pscustomobject]@{status='EXPORTED';json=$json;csv=$csv;discs=$snapshot.discs.Count;deleted_discs=$snapshot.deleted_discs.Count}
    } finally {Exit-ArchiveLock $catalogLease}
}
function Disc-RecordChangePreview($C,$P,[bool]$Restore) {
    $d=Get-Disc $C $P.DiscId -IncludeDeleted
    $deleted=[bool](Optional-Field $d 'catalog_deleted')
    if ($Restore -and !$deleted) { throw 'Disc record is already active.' }
    if (!$Restore -and $deleted) { throw 'Disc record is already deleted.' }
    [pscustomobject]@{status='DRY_RUN';action=if ($Restore) {'restore-disc-record'} else {'delete-disc-record'};disc_id=$d.disc_id;archive_set_id=$d.archive_set_id;previous_status=$d.status;location=$d.location;reason=$P.Reason;note='Catalog record only. No source, staging, plan, verification evidence or physical disc is erased. Deleted records can be restored; their old IDs remain associated with their evidence.'}
}
function Change-DiscRecord($C,$P,[bool]$Restore) {
    $preview=Disc-RecordChangePreview $C $P $Restore
    $d=Get-Disc $C $P.DiscId -IncludeDeleted;$time=[DateTime]::UtcNow.ToString('o')
    $d | Add-Member NoteProperty catalog_deleted (!$Restore) -Force
    if (!$Restore) {
        $d | Add-Member NoteProperty catalog_deleted_at $time -Force
        $d | Add-Member NoteProperty catalog_delete_reason (Summary-Value $P.Reason) -Force
    } else { $d | Add-Member NoteProperty catalog_restored_at $time -Force }
    Update-Disc $C $d
    Event $C $preview.action @{disc_id=$d.disc_id;reason=$P.Reason;time=$time}
    $preview.status=if ($Restore) {'RECORD_RESTORED'} else {'RECORD_DELETED'};$preview
}
function Orphan-SetChangePreview($C,$P) {
    Assert-Id $P.SetId
    $cat=Read-Json (Catalog-Path $C)
    $sets=@($cat.sets | Where-Object archive_set_id -ceq $P.SetId)
    if ($sets.Count -ne 1) { throw "Unknown or non-unique Archive ID: $($P.SetId)" }
    $set=$sets[0]
    if ([bool](Optional-Field $set 'original_deleted')) { throw 'Original source was deleted; an orphan set cannot be purged.' }
    $discs=@($cat.discs | Where-Object archive_set_id -ceq $P.SetId)
    if ($discs.Count) { throw "Archive set still has $($discs.Count) disc record(s). Delete/resolve those records first; orphan-set cleanup will not touch them." }
    $aliases=@((Optional-Field $cat 'set_aliases') | Where-Object { $_ -and (($_.old_id -ceq $P.SetId) -or ($_.new_id -ceq $P.SetId)) })
    if ($aliases.Count) { throw 'Archive set is referenced by set-rename history; do not reuse this ID.' }
    $setDir=Set-Dir $C $P.SetId
    if (Test-Path -LiteralPath $setDir) { throw "Archive set directory still exists: $setDir. Inspect it before cleanup." }
    [pscustomobject]@{
        status='DRY_RUN'; action='delete-orphan-set'; archive_set_id=$P.SetId
        category=$set.category; summary=$set.summary; file_count=$set.file_count; total_bytes=$set.total_bytes
        previous_original_deleted=[bool](Optional-Field $set 'original_deleted')
        disc_count=0; set_directory=$setDir; reason=$P.Reason
        note='Only the orphan set metadata will be removed. Source files, physical media, staging/build evidence and high-water disc counters are untouched.'
    }
}
function Delete-OrphanSet($C,$P) {
    $preview=Orphan-SetChangePreview $C $P
    $lease=Enter-CatalogLock $C
    try {
        # Re-read and re-check while holding the catalog lease so a concurrent
        # plan or stage cannot race this destructive metadata cleanup.
        $cat=Read-Json (Catalog-Path $C)
        $sets=@($cat.sets | Where-Object archive_set_id -ceq $P.SetId)
        $discs=@($cat.discs | Where-Object archive_set_id -ceq $P.SetId)
        if ($sets.Count -ne 1 -or $discs.Count) { throw 'Archive set changed while preparing orphan cleanup; no metadata was removed.' }
        $set=$sets[0]
        if ([bool](Optional-Field $set 'original_deleted')) { throw 'Original source was deleted; aborting orphan cleanup.' }
        $setDir=Set-Dir $C $P.SetId
        if (Test-Path -LiteralPath $setDir) { throw "Archive set directory appeared during cleanup: $setDir" }
        $time=[DateTime]::UtcNow.ToString('o')
        $receiptDir=Join-Path $C.archive_root 'maintenance/orphan-set-removal'
        [IO.Directory]::CreateDirectory($receiptDir) | Out-Null
        $receiptPath=Join-Path $receiptDir ("{0}-{1}.json" -f $P.SetId,$time.Replace(':','').Replace('.',''))
        $receipt=[ordered]@{
            schema_version=1; action='delete-orphan-set'; time=$time
            archive_set_id=$P.SetId; reason=(Summary-Value $P.Reason)
            precondition=[ordered]@{disc_count=0;set_directory_present=$false;original_deleted=[bool](Optional-Field $set 'original_deleted')}
            set_record_before=$set; receipt=$receiptPath
            note='Source files and physical media were not deleted. The set record was orphan metadata left by an interrupted ingest/plan.'
        }
        Write-Json $receiptPath $receipt
        $cat.sets=@($cat.sets | Where-Object archive_set_id -cne $P.SetId)
        $cat.updated_at=$time
        Write-Json (Catalog-Path $C) $cat
        Event $C 'delete-orphan-set' @{archive_set_id=$P.SetId;reason=$P.Reason;receipt=$receiptPath;time=$time}
        $preview | Add-Member NoteProperty status 'SET_RECORD_DELETED' -Force
        $preview | Add-Member NoteProperty receipt $receiptPath -Force
        $preview | Add-Member NoteProperty time $time -Force
        $preview
    } finally { Exit-ArchiveLock $lease }
}
function Unburned-PlanChangePreview($C,$P) {
    Assert-Id $P.SetId
    $cat=Read-Json (Catalog-Path $C)
    $sets=@($cat.sets | Where-Object archive_set_id -ceq $P.SetId)
    if ($sets.Count -ne 1) { throw "Unknown or non-unique Archive ID: $($P.SetId)" }
    $set=$sets[0]
    if ([bool](Optional-Field $set 'original_deleted')) { throw 'Original source was deleted; an unburned plan cannot be discarded.' }
    $discs=@($cat.discs | Where-Object archive_set_id -ceq $P.SetId)
    if (!$discs.Count) { throw 'Archive set has no disc plan records. Use delete-orphan-set for an ingest-only orphan.' }
    $unsafe=@($discs | Where-Object {
        $realBurn=$_.burn -and !(Optional-Field $_.burn 'simulation')
        $realVerify=$_.verification -and !(Optional-Field $_.verification 'simulation')
        $realBurn -or $realVerify -or $_.status -in @('WRITTEN','BURNED_UNVERIFIED','VERIFIED','REGISTERED') -or $_.registered -or $_.original_deleted
    })
    if ($unsafe.Count) { throw "Archive set has written, verified or registered disc records: $($unsafe.disc_id -join ', '). Nothing was removed." }
    $setDir=Set-Dir $C $P.SetId
    $paths=New-Object 'System.Collections.Generic.List[object]'
    foreach ($relative in @("sets/$($P.SetId)/plan.json","sets/$($P.SetId)/plan.csv","sets/$($P.SetId)/ARCHIVE-SUMMARY.json","sets/$($P.SetId)/ARCHIVE-SUMMARY.txt")) {
        $paths.Add([pscustomobject]@{relative=$relative;path=(Safe-Join $C.archive_root $relative);kind='file'})
    }
    foreach ($d in $discs) {
        foreach ($folder in @('build','staging','simulated')) {
            $relative="$folder/$($d.disc_id)"
            $paths.Add([pscustomobject]@{relative=$relative;path=(Safe-Join $C.archive_root $relative);kind='directory'})
        }
        $imageRoot=Join-Path $C.archive_root 'images'
        if (Test-Path -LiteralPath $imageRoot) {
            $imageDirs=@(Get-ChildItem -LiteralPath $imageRoot -Directory -Force -ErrorAction Stop | Where-Object Name -like "$($d.disc_id)-*")
            if ($imageDirs.Count) { throw "Disc $($d.disc_id) has an image directory; preserve it and inspect burn evidence before cleanup." }
        }
    }
    [pscustomobject]@{
        status='DRY_RUN';action='discard-unburned-plan';archive_set_id=$P.SetId
        disc_ids=@($discs | Select-Object -ExpandProperty disc_id);disc_count=$discs.Count
        set_directory=$setDir;remove_paths=@($paths | Select-Object relative,path,kind)
        reason=$P.Reason
        note='Removes only unfinished plan/build/staging outputs and disc records. ingest.json/ingest.csv, source files, logs, receipts and the B counter remain until an explicit counter reset.'
    }
}
function Discard-UnburnedPlan($C,$P) {
    $preview=Unburned-PlanChangePreview $C $P
    $lease=Enter-CatalogLock $C
    try {
        $cat=Read-Json (Catalog-Path $C)
        $sets=@($cat.sets | Where-Object archive_set_id -ceq $P.SetId)
        $discs=@($cat.discs | Where-Object archive_set_id -ceq $P.SetId)
        if ($sets.Count -ne 1 -or !$discs.Count) { throw 'Archive set changed while preparing unfinished-plan cleanup; no metadata was removed.' }
        $unsafe=@($discs | Where-Object {
            ($_.burn -and !(Optional-Field $_.burn 'simulation')) -or
            ($_.verification -and !(Optional-Field $_.verification 'simulation')) -or
            $_.status -in @('WRITTEN','BURNED_UNVERIFIED','VERIFIED','REGISTERED') -or $_.registered -or $_.original_deleted
        })
        if ($unsafe.Count) { throw 'A disc became written/verified/registered while cleanup was waiting; no metadata was removed.' }
        $time=[DateTime]::UtcNow.ToString('o')
        $receiptDir=Join-Path $C.archive_root 'maintenance/discarded-plans'
        [IO.Directory]::CreateDirectory($receiptDir) | Out-Null
        $receiptPath=Join-Path $receiptDir ("{0}-{1}.json" -f $P.SetId,$time.Replace(':','').Replace('.',''))
        $paths=@($preview.remove_paths)
        $receipt=[ordered]@{
            schema_version=1;action='discard-unburned-plan';status='PREPARED';time=$time
            archive_set_id=$P.SetId;reason=(Summary-Value $P.Reason)
            set_record_before=$sets[0];disc_records_before=$discs
            remove_paths=$paths;receipt=$receiptPath
            note='Source files and ingest.json/ingest.csv were retained. No physical media was written.'
        }
        Write-Json $receiptPath $receipt
        foreach ($item in $paths) {
            if (Test-Path -LiteralPath $item.path) {
                Assert-NoLinks $item.path
                if ($item.kind -eq 'directory') { Remove-Item -LiteralPath $item.path -Recurse -Force -ErrorAction Stop }
                else { Remove-Item -LiteralPath $item.path -Force -ErrorAction Stop }
            }
        }
        $cat.discs=@($cat.discs | Where-Object archive_set_id -cne $P.SetId)
        $cat.updated_at=$time
        Write-Json (Catalog-Path $C) $cat
        Event $C 'discard-unburned-plan' @{archive_set_id=$P.SetId;disc_ids=@($discs|Select-Object -ExpandProperty disc_id);reason=$P.Reason;receipt=$receiptPath;time=$time}
        $receipt.status='COMPLETED';$receipt.completed_at=[DateTime]::UtcNow.ToString('o')
        Write-Json $receiptPath $receipt
        $preview | Add-Member NoteProperty status 'PLAN_DISCARDED' -Force
        $preview | Add-Member NoteProperty receipt $receiptPath -Force
        $preview | Add-Member NoteProperty time $time -Force
        $preview
    } finally { Exit-ArchiveLock $lease }
}
function Assert-SealedIdentity($C,$D,$Record) {
    $sealed=Read-Json (Join-Path $Record.stage.path 'DISC.json')
    foreach ($key in @('disc_id','archive_set_id','position','disc_count')) { if ($sealed.$key -cne $D.$key) { throw "Sealed disc identity mismatch: $key" } }
    $expected=Disc-Identity $D;$written=Disc-Identity $sealed
    if ($written.volume_label -cne $expected.volume_label) { throw 'Sealed volume label differs from plan. Never rename a staged disc.' }
    $left=Disc-VolumeMetadata $D;$right=Disc-VolumeMetadata $sealed
    foreach ($key in @('udf','iso9660','joliet','system','volume_set','publisher','data_preparer','application')) {
        if ([string]$left.values.$key -cne [string]$right.values.$key) { throw "Sealed volume metadata differs from plan: $key" }
    }
    foreach ($key in @('catalog_id','disc_index','volume_id')) {
        $value=Optional-Field $sealed $key
        if ($null -ne $value -and $value -cne $expected.$key) { throw "Sealed disc identity differs from plan: $key" }
    }
    $written
}
