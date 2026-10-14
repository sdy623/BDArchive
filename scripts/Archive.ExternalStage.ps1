# Photo link directories are ordinary files. Adopt the whole prepared disc root
# in place; do not copy its payload, compress it or allocate replacement IDs.
function Assert-PhotoSourceRoot($Source,$Ingest=$null) {
    $sourcePath=(Full-Path $Source).TrimEnd('\','/')
    if ([IO.Path]::GetFileName($sourcePath) -ine '00_DISC_CATALOG') {return}
    # Use .NET paths: PowerShell Join-Path rejects an unplugged drive before
    # saved metadata evidence can explain the actual problem.
    $parent=[IO.Path]::GetDirectoryName($sourcePath)
    $savedIndex=$Ingest -and $Ingest.category -eq 'I' -and
        @($Ingest.files.path) -icontains 'DISC-INFO.json' -and @($Ingest.files.path) -icontains 'CONTENTS.csv'
    $liveIndex=[IO.File]::Exists([IO.Path]::Combine($sourcePath,'DISC-INFO.json')) -and
        [IO.Directory]::Exists([IO.Path]::Combine($parent,'data'))
    if ($savedIndex -or $liveIndex) {
        throw "这里只是照片索引子目录，照片没有包含在内。请选择整张盘目录：$parent。已有盘号请用[接入现成照片盘]，不要重新扫描索引。"
    }
}
function External-PhotoRoot($Source) {
    $root=(Full-Path $Source).TrimEnd('\','/')
    if ((Split-Path $root -Leaf) -ieq '00_DISC_CATALOG') {$root=Split-Path $root}
    Assert-NoLinks $root
    if (![IO.Directory]::Exists((Join-Path $root 'data')) -or ![IO.File]::Exists((Join-Path $root '00_DISC_CATALOG/CONTENTS.csv'))) {throw '选择包含 data 和 00_DISC_CATALOG 的整张照片盘目录。'}
    $root
}
function Assert-ExternalPhotoRecord($Record) {
    if ($Record.burn_date -or $Record.registered -or $Record.original_deleted -or (Optional-Field $Record 'catalog_deleted') -or
        ($Record.burn -and !$Record.burn.simulation) -or ($Record.verification -and !(Optional-Field $Record.verification 'simulation')) -or
        $Record.status -notin @('PLANNED','BUILT','STAGED','SIMULATED','SIMULATED_PASS')) {throw '只能接入尚未实际写盘、登记或删除源的照片记录；已写盘记录不会重绑定。'}
    foreach ($b in @(Optional-Field $Record 'burn_history')) {if ($b -and !$b.simulation -and $b.result -notin @('NOT_STARTED','CANCELLED_BEFORE_WRITE')) {throw '历史中有未解决的实际写入，不能重绑定目录。'}}
}
function Get-ExternalPhotoContext($C,$P) {
    $root=External-PhotoRoot $P.Source;Assert-Separate $root $C.archive_root
    $record=Get-Disc $C $P.DiscId
    $plan=Load-Plan $C $record.archive_set_id;$ing=Load-Ingest $C $record.archive_set_id
    if ($plan.category -ne 'I') {throw '此入口只接入 I 类照片记录；请选择照片盘记录。'}
    # An external photo root represents one physical disc, while its archive
    # plan may contain several discs. Select the plan entry by disc identity
    # instead of assuming the first entry is the one being imported.
    $planDisc=@($plan.discs | Where-Object {$_.disc_id -ceq $record.disc_id})
    if ($planDisc.Count -ne 1 -or $planDisc[0].dwarfs) {throw '所选照片盘在计划中不存在或不是直接文件盘。'}
    Assert-ExternalPhotoRecord $record
    $cat=Read-Json (Catalog-Path $C);$set=@($cat.sets | Where-Object archive_set_id -eq $record.archive_set_id)[0]
    if ($set.original_deleted) {throw 'Original-deleted sets cannot change content.'}
    $info=Read-Json (Join-Path $root '00_DISC_CATALOG/DISC-INFO.json')
    if ($info.disc_id -cne $record.disc_id) {throw '现成目录的盘号与所选记录不一致。'}
    if ((File-Hash (Join-Path (Set-Dir $C $record.archive_set_id) 'ingest.json')) -cne $plan.ingest_sha256 -or $plan.ingest_sha256 -cne $set.ingest_sha256) {throw 'Plan and catalog ingest evidence differs.'}
    $rows=@(Import-Csv -LiteralPath (Join-Path $root '00_DISC_CATALOG/CONTENTS.csv') -Encoding UTF8)
    $expected=@{};$files=New-Object 'System.Collections.Generic.List[object]';$bytes=[int64]0
    if (!('ArchiveFileLinks' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'Archive.FileLinks.cs')}
    foreach ($row in $rows) {
        Assert-PreparationRunning
        $path=[string]$row.archive_path
        if (!$path.StartsWith('data/',[StringComparison]::Ordinal) -or $row.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $expected.ContainsKey($path)) {throw '照片清单路径、哈希或重复条目无效。'}
        $full=Safe-Join $root $path;$stamp=[ArchiveFileLinks]::Stamp($full)
        if ($stamp.Bytes -ne [int64]$row.bytes) {throw "照片大小与原清单不符：$path"}
        Assert-PlainFile $full
        $expected[$path]=$row.sha256;$bytes+=$stamp.Bytes
        $files.Add([pscustomobject]@{path=$path.Substring(5);size=$stamp.Bytes;sha256=$row.sha256;mtime_utc=([DateTime]::new($stamp.MtimeTicks,[DateTimeKind]::Utc)).ToString('o');alias_of=$null})
    }
    $actual=@(Tree-Files (Join-Path $root 'data'))
    if ($actual.Count -ne $rows.Count -or $rows.Count -ne $info.photo_files -or $bytes -ne $info.logical_payload_bytes) {throw 'data 文件数量/容量与照片清单不一致。'}
    foreach ($f in $actual) {if (!$expected.ContainsKey((Relative-Path $root $f.FullName))) {throw 'data 中存在清单外文件。'}}
    $d=$planDisc[0]
    if ($bytes -gt $d.budget.payload_limit_bytes -or $d.budget.par2_percent -ne 0) {throw '现成照片盘超出 payload 上限或计划要求 PAR2；此接入入口仅支持已分好的无 PAR2 单盘。'}
    @{root=$root;record=$record;set=$set;ingest=$ing;plan=$plan;disc=$d;files=$files.ToArray();bytes=$bytes;expected=$expected;info=$info;csv_hash=(File-Hash (Join-Path $root '00_DISC_CATALOG/CONTENTS.csv'))}
}
function External-PhotoPreview($C,$P) {
    $x=Get-ExternalPhotoContext $C $P
    @{status='DRY_RUN';disc_id=$x.record.disc_id;archive_set_id=$x.record.archive_set_id;root=$x.root;photo_files=$x.files.Count;photo_bytes=$x.bytes;payload_copy_bytes=0;dwarfs=$false;note='整目录接入。首次封包按原 CSV 哈希逐文件核对一次；不复制照片，不刻碟。'}
}
function Import-ExternalPhotoStage($C,$P) {
    $x=Get-ExternalPhotoContext $C $P;$root=$x.root;$r=$x.record
    if ((Optional-Field $r 'external_stage') -and $r.stage.path -ieq $root) {
        $guards=Open-StageReadGuards $root
        try {$null=Confirm-StageForBurn $C $r} finally {Close-StageReadGuards $guards}
        return @{status='STAGED';disc_id=$r.disc_id;root=$root;reused=$true}
    }
    $pending=Safe-Join $C.archive_root ('external-imports/'+$r.disc_id+'/pending.json')
    $job=$null
    if ([IO.File]::Exists($pending)) {
        $job=Read-Json $pending
        if ($job.root -ine $root -or $job.csv_hash -cne $x.csv_hash -or $job.previous_ingest -cne $x.plan.ingest_sha256) {throw '未完成的接入与当前目录/计划不一致；保留原记录，请先检查 external-imports。'}
    } else {
        # Reject foreign root files; only our checkpoint permits resume writes.
        $foreign=@(Get-ChildItem -LiteralPath $root -Force | Where-Object Name -notin @('data','00_DISC_CATALOG'))
        if ($foreign.Count) {throw '现成目录含额外根文件或已封包，请先检查；不会覆盖它们。'}
        $token=[guid]::NewGuid().ToString('N')
        $revision='sets/'+$r.archive_set_id+'/revisions/'+$token
        $rev=Safe-Join $C.archive_root $revision
        Write-Json (Join-Path $rev 'previous-record.json') $r
        $ing=$x.ingest;$ing.source_root=Join-Path $root 'data';$ing.files=@($x.files);$ing.file_count=$x.files.Count;$ing.total_bytes=$x.bytes
        $ing.directories=@(Get-ChildItem -LiteralPath $ing.source_root -Directory -Recurse -Force | ForEach-Object {Relative-Path $ing.source_root $_.FullName})
        $ing | Add-Member NoteProperty imported_from $x.info.archive_set_id -Force
        Write-Json (Join-Path $rev 'ingest.json') $ing
        $ing.files | Export-Csv -LiteralPath (Join-Path $rev 'ingest.csv') -NoTypeInformation -Encoding UTF8
        $plan=$x.plan;$plan.ingest_sha256=File-Hash (Join-Path $rev 'ingest.json');$plan.deduplicated=$false
        $d=@($plan.discs | Where-Object {$_.disc_id -ceq $r.disc_id})[0]
        if ($null -eq $d) {throw '现成照片盘在版本化计划中不存在。'}
        $d.files=@($x.files);$d.input_bytes=$x.bytes
        $plan | Add-Member NoteProperty content_revision $token -Force
        Write-Json (Join-Path $rev 'plan.json') $plan
        $meta=Join-Path $rev 'disc-metadata'
        $portable=Read-Json (Join-Path $rev 'ingest.json');$portable.PSObject.Properties.Remove('source_root')
        Write-Json (Join-Path $meta 'SET-MANIFEST.json') @{schema_version=1;ingest=$portable;plan=$plan}
        $identity=Disc-Identity $d
        $disc=@{schema_version=1;disc_id=$d.disc_id;archive_set_id=$d.archive_set_id;position=$d.position;disc_count=$d.disc_count;media_type=$d.media_type;category='I';udf_revision='2.50';dwarfs=$false;nfc_url=$r.nfc_url;authoring_metadata=(Disc-VolumeMetadata $d)}
        foreach ($f in $identity.PSObject.Properties) {$disc[$f.Name]=$f.Value}
        Write-Json (Join-Path $meta 'DISC.json') $disc
        Write-Json (Join-Path $meta 'TOOLKIT-IMPORT.json') @{schema_version=1;content_revision=$token;external_archive_set_id=$x.info.archive_set_id;archive_set_id=$r.archive_set_id;disc_id=$r.disc_id;photo_files=$x.files.Count;photo_bytes=$x.bytes;payload_copied=$false;dwarfs=$false;note='00_DISC_CATALOG is the original planner catalog. Toolkit sealing is recorded in the external catalog and SHA256SUMS.'}
        Write-Text (Join-Path $meta 'RESTORE.md') "# Restore $($r.disc_id)`nUDF 2.50 photo data disc. Copy data/ preserving relative paths. Open 00_DISC_CATALOG/CONTENTS.html to browse photos. SHA256SUMS covers photos and all root/catalog files. No DwarFS is used. Original source deletion is disabled for imported link directories.`n"
        Write-Text (Join-Path $meta 'ARCHIVE-SUMMARY.txt') "Archive ID: $($r.archive_set_id)`nDisc ID: $($r.disc_id)`nPhoto files: $($x.files.Count)`nPhoto bytes: $($x.bytes)`nMode: existing photo link directory, UDF 2.50, no DwarFS`n"
        $metadata=@(Tree-Files $meta | ForEach-Object {@{path=$_.Name;sha256=(File-Hash $_.FullName)}})
        $job=@{schema_version=1;root=$root;revision=$revision;previous_ingest=$x.plan.ingest_sha256;csv_hash=$x.csv_hash;metadata=$metadata;disc_id=$r.disc_id;plan_hash=(File-Hash (Join-Path $rev 'plan.json'));ingest_hash=$plan.ingest_sha256}
        # x.plan was revised in memory; bind checkpoint to the untouched old set.
        $job.previous_ingest=(Load-Plan $C $r.archive_set_id).ingest_sha256
        Write-Json $pending $job
    }
    $prefix='sets/'+$r.archive_set_id+'/revisions/'
    if ($job.schema_version -ne 1 -or $job.disc_id -cne $r.disc_id -or $job.revision -cnotmatch ('^'+[regex]::Escape($prefix)+'[0-9a-f]{32}$')) {throw 'Import checkpoint identity or revision path is invalid.'}
    $rev=Safe-Join $C.archive_root $job.revision
    if ((File-Hash (Join-Path $rev 'plan.json')) -cne $job.plan_hash -or (File-Hash (Join-Path $rev 'ingest.json')) -cne $job.ingest_hash) {throw 'Import revision manifest changed; no revision activated.'}
    $plan=Read-Json (Join-Path $rev 'plan.json');$ing=Read-Json (Join-Path $rev 'ingest.json')
    foreach ($f in $job.metadata) {
        $src=Safe-Join (Join-Path $rev 'disc-metadata') $f.path;$dest=Safe-Join $root $f.path
        if ((File-Hash $src) -cne $f.sha256) {throw 'Import metadata checkpoint changed.'}
        if ([IO.File]::Exists($dest)) {if ((File-Hash $dest) -cne $f.sha256) {throw '已有根 metadata 已变化，不覆盖。'}}
        else {[IO.File]::Copy($src,$dest,$false)}
    }
    $allowed=@{'SHA256SUMS'=$true};foreach ($f in $job.metadata) {$allowed[$f.path]=$true}
    $hashes=New-Object 'System.Collections.Generic.List[string]';$total=[int64]0
    foreach ($f in (Tree-Files $root | Sort-Object FullName)) {
        $rel=Relative-Path $root $f.FullName
        if ($rel -eq 'SHA256SUMS') {continue}
        if ($x.expected.ContainsKey($rel)) {$h=$x.expected[$rel]}
        elseif ($allowed.ContainsKey($rel) -or $rel.StartsWith('00_DISC_CATALOG/')) {$h=File-Hash $f.FullName}
        else {throw "接入期间出现额外文件：$rel"}
        $hashes.Add("$h  $rel");$total+=$f.Length
    }
    $sums=Join-Path $root 'SHA256SUMS';$text=($hashes.ToArray() -join "`n")+"`n"
    if ([IO.File]::Exists($sums)) {if ([IO.File]::ReadAllText($sums,$script:Utf8) -cne $text) {throw 'Existing SHA256SUMS differs from import checkpoint.'}}
    else {Write-Text $sums $text}
    $total+=(Get-Item -LiteralPath $sums).Length
    $estimated=$total+([int64]$hashes.Count+1)*$C.planning.per_file_overhead_bytes
    $selectedDisc=@($plan.discs | Where-Object {$_.disc_id -ceq $r.disc_id})[0]
    if ($null -eq $selectedDisc) {throw '现成照片盘在接入版本中不存在。'}
    if ($estimated -gt ($selectedDisc.budget.capacity_bytes-$selectedDisc.budget.reserve_bytes)) {throw '完整现成目录超出介质容量/保留余量。'}
    $seal=[pscustomobject]@{path=$root;bytes=$total;estimated_bytes=$estimated;hash=(File-Hash $sums);disc_json_hash=(File-Hash (Join-Path $root 'DISC.json'));time=[DateTime]::UtcNow.ToString('o')}
    $verifyRecord=[pscustomobject]@{stage=$seal}
    $guards=Open-StageReadGuards $root
    try {
        if ((File-Hash (Join-Path $root '00_DISC_CATALOG/CONTENTS.csv')) -cne $job.csv_hash) {throw 'Original photo catalog changed during import.'}
        Write-Host "首次封包：核对 $($x.files.Count) 个照片文件，共 $([Math]::Round($x.bytes/1GB,2)) GiB；直接读取现成链接目录，不复制。"
        $null=Check-DiscTree $C $root $verifyRecord
        $seal.time=[DateTime]::UtcNow.ToString('o');$seal | Add-Member NoteProperty receipt (New-StageReceipt $seal @(Get-StageStamps $root))
        Assert-PreparationRunning
        # One catalog replacement activates the new versioned manifests and seal.
        # Old plan/ingest/staging remain intact; a cancelled import activates none.
        $lease=Enter-CatalogLock $C
        try {
            $cat=Read-Json (Catalog-Path $C);$current=@($cat.discs | Where-Object disc_id -eq $r.disc_id)[0]
            Assert-ExternalPhotoRecord $current
            $set=@($cat.sets | Where-Object archive_set_id -eq $r.archive_set_id)[0]
            if ($set.ingest_sha256 -cne $job.previous_ingest) {throw 'Archive changed during import; no revision activated.'}
            $current | Add-Member NoteProperty stage_history (@(Optional-Field $current 'stage_history')+@($current.stage) | Where-Object {$null -ne $_}) -Force
            if ($current.burn) {$current | Add-Member NoteProperty burn_history (@(Optional-Field $current 'burn_history')+@($current.burn) | Where-Object {$null -ne $_}) -Force}
            $current.burn=$null;$current.verification=$null;$current.burn_date=$null
            $current.stage=$seal;$current.hash=$seal.hash;$current.status='STAGED'
            $current | Add-Member NoteProperty simulation_revision $plan.content_revision -Force
            $current | Add-Member NoteProperty external_stage $true -Force
            $set | Add-Member NoteProperty manifest_directory $job.revision -Force
            $set | Add-Member NoteProperty source_deletion_disabled 'EXTERNAL_LINK_DIRECTORY' -Force
            $set.ingest_sha256=$plan.ingest_sha256;$set.file_count=$x.files.Count;$set.total_bytes=$x.bytes;$set.restore_test=$null
            $cat.updated_at=[DateTime]::UtcNow.ToString('o');Write-Json (Catalog-Path $C) $cat
        } finally {Exit-ArchiveLock $lease}
    } finally {Close-StageReadGuards $guards}
    Event $C 'import-external-photo-stage' @{disc_id=$r.disc_id;files=$x.files.Count;bytes=$x.bytes;root=$root;revision=$job.revision;payload_copy_bytes=0}
    @{status='STAGED';disc_id=$r.disc_id;photo_files=$x.files.Count;photo_bytes=$x.bytes;root=$root;payload_copy_bytes=0;dwarfs=$false}
}
