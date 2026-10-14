function Initialize-Archive($C) {
    $catalogLease=Enter-CatalogLock $C
    try {
    foreach ($name in @('sets','staging','build','logs','reports','simulated','images')) { [IO.Directory]::CreateDirectory((Join-Path $C.archive_root $name)) | Out-Null }
    $cat=Catalog-Snapshot $C;Ensure-CatalogIdentity $cat
    Write-Json (Catalog-Path $C) $cat
    Event $C 'init' @{root=$C.archive_root}
    @{archive_root=$C.archive_root;catalog=(Catalog-Path $C);status='INITIALIZED'}
    } finally {Exit-ArchiveLock $catalogLease}
}
function Ingest-Archive($C,$P) {
    Assert-Id $P.SetId; $source=Full-Path $P.Source
    Assert-PhotoSourceRoot $source
    $profile=New-ArchiveProfile $P; $P.Category=$profile.category
    Assert-Separate $source $C.archive_root
    if (!(Test-Path -LiteralPath $source -PathType Container)) { throw 'Source directory does not exist.' }
    $dir=Set-Dir $C $P.SetId
    $existing=Read-Json (Catalog-Path $C)
    $existingSet=@($existing.sets | Where-Object archive_set_id -eq $P.SetId)
    if ($existingSet.Count) {
        $existingDiscs=@($existing.discs | Where-Object archive_set_id -eq $P.SetId)
        if ($existingSet.Count -eq 1 -and !$existingDiscs.Count -and !(Optional-Field $existingSet[0] 'original_deleted') -and !(Test-Path -LiteralPath $dir)) {
            throw "Archive ID is an orphan ingest record with no plan or disc record. Run archive-agent.ps1 -Command delete-orphan-set -SetId '$($P.SetId)' -Execute after reviewing the maintenance preview, then scan again."
        }
        throw 'Archive ID already exists in catalog. 已有归档记录；若已删除原计划目录，请换一个新的 Archive ID，不能在残留记录上重新扫描。'
    }
    Assert-SetIdAvailable $C $existing $P.SetId
    $files=New-Object 'System.Collections.Generic.List[object]'; $groups=@{}; $size=[int64]0
    Write-Host 'Scanning source and calculating SHA-256...'
    foreach ($item in (Tree-Files $source | Sort-Object FullName)) {
        Assert-PlainFile $item.FullName
        $rel=Relative-Path $source $item.FullName; $null=Safe-Join $source $rel
        $before=Archive-FileInfo $item.FullName; $length=$before.Length; $mtime=$before.LastWriteTimeUtc.Ticks
        $hash=File-Hash $item.FullName
        $after=Archive-FileInfo $item.FullName
        if ($length -ne $after.Length -or $mtime -ne $after.LastWriteTimeUtc.Ticks) { throw "File changed while hashing: $rel" }
        $f=[pscustomobject]@{path=$rel;size=[int64]$length;sha256=$hash;mtime_utc=$after.LastWriteTimeUtc.ToString('o');alias_of=$null}
        if ($null -ne (Optional-Field $item 'ReferenceTarget')) { $f | Add-Member NoteProperty reference_target $item.ReferenceTarget }
        if ($P.DetectDuplicates) {
            $key="$length/$hash"
            if ($groups.ContainsKey($key) -and (Same-Bytes (Safe-Join $source $groups[$key]) $item.FullName)) { $f.alias_of=$groups[$key] }
            else { $groups[$key]=$rel }
        }
        $files.Add($f); $size+=$length
        if ($files.Count % 500 -eq 0) { Write-Host "Scanned $($files.Count) files / $size bytes" }
    }
    if (!$files.Count) { throw 'Empty input is not an archive set.' }
    $directories=@(Get-ChildItem -LiteralPath $source -Directory -Recurse -Force | ForEach-Object { Relative-Path $source $_.FullName } | Sort-Object)
    $manifest=@{schema_version=1;archive_set_id=$P.SetId;category=$P.Category;profile=$profile;source_root=$source;created_at=[DateTime]::UtcNow.ToString('o');file_count=$files.Count;total_bytes=$size;directories=$directories;files=$files.ToArray()}
    Assert-PreparationRunning
    # Publish the snapshot and catalog together before honoring the next stop.
    $catalogLease=Enter-CatalogLock $C
    try {
    Write-Json (Join-Path $dir 'ingest.json') $manifest
    $files | Export-Csv -LiteralPath (Join-Path $dir 'ingest.csv') -NoTypeInformation -Encoding UTF8
    $cat=Read-Json (Catalog-Path $C)
    $cat.sets+= [pscustomobject]@{archive_set_id=$P.SetId;category=$P.Category;summary=$P.Summary;file_count=$files.Count;total_bytes=$size;original_deleted=$false;restore_test=$null;ingest_sha256=((Get-FileHash -LiteralPath (Join-Path $dir 'ingest.json') -Algorithm SHA256).Hash.ToLowerInvariant())}
    Write-Json (Catalog-Path $C) $cat
    } finally {Exit-ArchiveLock $catalogLease}
    Event $C 'ingest' @{set=$P.SetId;files=$files.Count;bytes=$size}
    $manifest | Select-Object archive_set_id,file_count,total_bytes
}
function Plan-Archive($C,$P) {
    $ing=Load-Ingest $C $P.SetId; $dir=Set-Dir $C $P.SetId
    if (Test-Path -LiteralPath (Join-Path $dir 'plan.json')) { throw 'Plan is immutable. Reuse it or ingest under a new SetId.' }
    $media=$P.Media; if (!$media) { $media=$C.planning.default_media }
    $profile=Optional-Field $ing 'profile';$photo=($profile -and $profile.scenario -eq 'photo')
    # Photos are direct-file optical archives.  Keep their default free of
    # PAR2; backup sets retain the configured default (currently 10%).  An
    # explicit -ParPercent still wins for either scenario.
    if ($null -ne $P.ParPercent) { $par=[double]$P.ParPercent }
    elseif ($photo) { $par=0 }
    else { $par=$C.planning.par2_percent }
    $budget=Disc-Budget $C $media $par $ing.category
    $repeat=New-Object 'System.Collections.Generic.List[object]'; $normal=New-Object 'System.Collections.Generic.List[object]'; $repeatCost=[int64]0
    $metadataRoots=@{''=$true}
    if ($ing.category -eq 'III') { foreach ($root in (Backup-MetadataRoots $ing)) { $metadataRoots[$root]=$true } }
    $protected=@{}
    if ($photo) {
        foreach ($family in ($ing.files | Group-Object { Photo-Family $_.path })) {
            # Preserve a local RAW with its XMP/JPEG even if a duplicate RAW
            # exists elsewhere; dedup must not separate usable photo families.
            if ($family.Count -gt 1) { foreach ($f in $family.Group) { $protected[$f.path]=$true } }
        }
    }
    foreach ($f in $ing.files) {
        $isRootMetadata=$false
        $leaf=[IO.Path]::GetFileName($f.path);$parent=$f.path.Substring(0,$f.path.Length-$leaf.Length)
        if ($ing.category -eq 'III' -and $metadataRoots.ContainsKey($parent)) {
            foreach ($pattern in $C.planning.repeat_root_metadata) { if ($leaf -like $pattern) { $isRootMetadata=$true } }
        }
        if ($isRootMetadata) { $repeat.Add($f); $repeatCost+=$f.size+$C.planning.per_file_overhead_bytes }
        elseif ($P.Deduplicate -and $ing.category -eq 'I' -and $f.alias_of -and !$protected.ContainsKey($f.path)) { continue }
        else { $normal.Add($f) }
    }
    if ($P.Deduplicate -and $ing.category -ne 'I') { throw 'Physical deduplication is restricted to category I.' }
    $available=$budget.input_limit_bytes-$repeatCost
    if ($available -le 0) { throw 'Repeated root metadata exceeds shard capacity.' }
    $bins=@(Pack-Files $normal $available $C.planning.per_file_overhead_bytes -PhotoFamilies:$photo)
    if (!$bins.Count) { $bins=@(@{files=@();size=0}) }
    $prefix=@{I='P';II='G';III='B';M='M'}[$ing.category]
    $ingestHash=File-Hash (Join-Path $dir 'ingest.json')
    $catalogLease=Enter-CatalogLock $C
    try {
    $cat=Read-Json (Catalog-Path $C);Ensure-CatalogIdentity $cat; $discs=@(); $position=0
    $labelTemplate=Volume-LabelTemplate $C $P
    $volumeTemplates=Volume-Templates $C $P
    $startId=Optional-Field $P 'StartDiscId'
    foreach ($bin in $bins) {
        $position++
        $discId=if ($startId) { Batch-DiscId $startId ($position-1) } else { Next-DiscId $cat $prefix }
        Assert-DiscIdAvailable $C $cat $discId
        $disc=[pscustomobject]@{disc_id=$discId;archive_set_id=$P.SetId;position=$position;disc_count=$bins.Count;media_type=$media;category=$ing.category;budget=$budget;input_bytes=($bin.size+$repeatCost);files=$repeat.ToArray()+@($bin.files);dwarfs=($ing.category -eq 'III')}
        New-DiscIdentity $cat $disc $labelTemplate
        $disc | Add-Member NoteProperty authoring_metadata (New-VolumeMetadata $volumeTemplates $disc)
        $discs+=,$disc
        $record=[pscustomobject]@{disc_id=$discId;archive_set_id=$P.SetId;position=$position;disc_count=$bins.Count;media_type=$media;status='PLANNED';location='';nfc_url=($C.nfc_base_url.TrimEnd('/')+'/disc/'+$discId);burn_date=$null;hash=$null;stage=$null;burn=$null;verification=$null;registered=$false;original_deleted=$false}
        foreach ($field in (Disc-Identity $disc).PSObject.Properties) { $record | Add-Member NoteProperty $field.Name $field.Value -Force }
        $record | Add-Member NoteProperty authoring_metadata $disc.authoring_metadata
        $cat.discs+=,$record
    }
    # Explicit starts may fill an unused lower range. Keep automatic high-water
    # counters intact; imported/custom prefixes do not consume P/G/B/M counters.
    foreach ($key in @('P','G','B','M')) { $cat.sequences.$key=Counter-Value $cat $key }
    # Reserve monotonically increasing IDs before writing the plan; a crash may
    # leave a gap, but can never reuse a physical disc identifier.
    $plan=@{schema_version=1;archive_set_id=$P.SetId;category=$ing.category;ingest_sha256=$ingestHash;created_at=[DateTime]::UtcNow.ToString('o');deduplicated=[bool]$P.Deduplicate;volume_label_template=$labelTemplate;volume_templates=$volumeTemplates;start_disc_id=$startId;catalog_id=$cat.catalog_id;discs=$discs}
    Assert-PreparationRunning
    Write-Json (Catalog-Path $C) $cat
    Write-Json (Join-Path $dir 'plan.json') $plan
    } finally {Exit-ArchiveLock $catalogLease}
    $rows=foreach ($d in $discs) { foreach ($f in $d.files) { [pscustomobject]@{disc_id=$d.disc_id;disc_index=$d.disc_index;volume_id=$d.volume_id;volume_label=$d.volume_label;position=$d.position;disc_count=$d.disc_count;path=$f.path;bytes=$f.size;sha256=$f.sha256} } }
    $rows | Export-Csv -LiteralPath (Join-Path $dir 'plan.csv') -NoTypeInformation -Encoding UTF8
    Event $C 'plan' @{set=$P.SetId;disc_count=$discs.Count;budget=$budget}
    $discs | Select-Object disc_id,disc_index,volume_id,volume_label,position,disc_count,media_type,input_bytes
}
function Selected-PlanDisc($C,$P) {
    $record=Get-Disc $C $P.DiscId; $plan=Load-Plan $C $record.archive_set_id
    $ingestPath=Join-Path (Set-Dir $C $record.archive_set_id) 'ingest.json'
    if ((File-Hash $ingestPath) -ne $plan.ingest_sha256) { throw 'Ingest manifest has changed since planning.' }
    $d=@($plan.discs | Where-Object disc_id -eq $P.DiscId)
    if ($d.Count -ne 1) { throw 'Disc missing from plan.' }
    # An old immutable plan has no identity fields. Use its catalog backfill in
    # memory when staging it; never rewrite the existing plan to add columns.
    foreach ($key in @('catalog_id','disc_index','volume_id','volume_label','volume_index','volume_count','disc_prefix','disc_number','identity_origin','authoring_metadata')) {
        if ($null -eq (Optional-Field $d[0] $key) -and $null -ne (Optional-Field $record $key)) { $d[0] | Add-Member NoteProperty $key $record.$key -Force }
    }
    $d[0]
}
function Dwarfs-BuildProfile($C) {
    $profile=Optional-Field $C.dwarfs 'build_profile'
    if (!$profile) { return 'verified' } # Preserve behavior of older configs.
    if ($profile -notin @('fast','verified')) { throw 'dwarfs.build_profile must be fast or verified.' }
    $profile
}
function Verify-DwarfsImage($C,$Image,[string]$VerifiedSha256='', [int]$Workers=0) {
    # Only a caller that just checked these bytes may supply this digest.
    if ($VerifiedSha256 -and $VerifiedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid verified digest.' }
    $version=Dwarfs-Version $C 'dwarfsck'
    $checkArgs=@('--check-integrity','-i',$Image)
    if ($Workers -gt 0) { $checkArgs+=@('--num-workers',[string]$Workers) }
    $result=Dwarfs-Run $C 'dwarfsck' $checkArgs 'dwarfsck'
    $report=@{schema_version=1;image=(Full-Path $Image);status='PASS';exit_code=$result.exit_code;sha256=$(if ($VerifiedSha256) {$VerifiedSha256} else {File-Hash $Image});version=$version;log=$result.log;time=[DateTime]::UtcNow.ToString('o')}
    Write-Json (Join-Path $C.archive_root ("reports/dwarfs-"+[guid]::NewGuid().ToString('N')+'.json')) $report
    $report
}
function Build-ArchiveDwarfs($C,$P) {
    $d=Selected-PlanDisc $C $P; if (!$d.dwarfs) { throw 'Only category III uses this build step.' }
    $ing=Load-Ingest $C $d.archive_set_id
    $profile=Dwarfs-BuildProfile $C;$fast=($profile -eq 'fast')
    $dir=Safe-Join $C.archive_root "build/$($d.disc_id)"
    $image=Join-Path $dir ($d.disc_id+'.dwarfs'); $inputList=Join-Path $dir 'input-files.txt'
    if (Test-Path -LiteralPath $image) { throw 'Image already exists; verify it or use a new plan. Partial builds are retained for inspection.' }
    if ($fast) {
        if (!('ArchiveFileLinks' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Archive.FileLinks.cs') }
        $free=[ArchiveFileLinks]::AvailableBytes($C.archive_root)
        if ($free -lt [int64]$d.input_bytes) { throw "Insufficient workspace space for uncompressed build: need approximately $($d.input_bytes) bytes, available $free. No source hashing or build started." }
    }
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    foreach ($f in $d.files) {
        Assert-PreparationRunning
        $sourcePath=Safe-Join $ing.source_root $f.path
        if ($fast) {
            $info=Get-Item -LiteralPath $sourcePath -Force
            $savedTime=if ($f.mtime_utc -is [DateTime]) {$f.mtime_utc} else {[DateTime]::Parse($f.mtime_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)}
            if ($info.Length -ne $f.size -or $info.LastWriteTimeUtc.Ticks -ne $savedTime.ToUniversalTime().Ticks) { throw "Source size/time changed: $($f.path)" }
        } elseif ((File-Hash $sourcePath) -ne $f.sha256) { throw "Source changed: $($f.path)" }
    }
    Write-Host "Build profile: $profile"
    Write-Text $inputList ((@($d.files | ForEach-Object { $_.path }) -join "`n")+"`n")
    Write-Host "DwarFS reads this shard directly from the source using input-files.txt; no input copy."
    # The complete directory list lives in SET-MANIFEST; empty directories are
    # recreated on full-set restore without replicating them into every shard.
    $version=Dwarfs-Version $C 'mkdwarfs'
    $level=if ($fast) {0} else {$C.dwarfs.compression_level}
    $args=@('-i',$ing.source_root,'--input-list',$inputList,'-o',$image,'-l',"$level",'-N',"$($C.dwarfs.workers)",'-L',$C.dwarfs.memory_limit,'--keep-all-times','--progress','simple')
    # v0.15.7 -H: level 0 = null data/schema/history/metadata compression,
    # no similarity ordering/segment matching. No internal file dedup hash.
    if ($fast) { $args+=@('--file-hash','none','--order','none') }
    $result=Dwarfs-Run $C 'mkdwarfs' $args 'mkdwarfs'
    if ((Get-Item -LiteralPath $image).Length -gt $d.budget.payload_limit_bytes) { throw 'Built image exceeds payload limit. Keep source; make a new smaller shard plan.' }
    $check=Verify-DwarfsImage $C $image
    $skip=Optional-Field $C.dwarfs 'skip_roundtrip'
    if ($null -eq $skip) { $skip=$fast }
    $roundtripStatus='SKIPPED_FAST';$roundtripMode='SKIP'
    if (!$skip) {
        $roundtripMode='STREAM'
        $expected=Join-Path $dir 'stream-expected.json';Write-Json $expected @($d.files)
        $tool=Resolve-Dwarfs $C 'dwarfsextract';$python=Resolve-Tool $C 'python'
        $extractArgs=@($tool.prefix)+@('-i',$image,'-f','pax','-o','-','-s','64m')
        $null=Run-Tool $C $python @((Join-Path $PSScriptRoot '../catalog/verify_tar_stream.py'),'--expected',$expected) 'build-stream-check' -InputExe $tool.exe -InputArguments $extractArgs
        $roundtripStatus='PASS'
    }
    $summary=@($result.output -split "[\r\n]+" | Where-Object { $_ -match '(?i)original (filesystem )?size|compressed block size|\d+ inodes|compressed filesystem|compressed .* to ' } | Select-Object -Last 24)
    $rawBytes=[int64]0; foreach ($f in $d.files) { $rawBytes += [int64]$f.size }
    $parsed=@{original_size_text=$null;compressed_size_text=$null;inode_count=$null}
    $sizes=[regex]::Matches($result.output,'original (?:filesystem )?size: ([^,\r\n]+)')
    if ($sizes.Count) { $parsed.original_size_text=$sizes[$sizes.Count-1].Groups[1].Value }
    $sizes=[regex]::Matches($result.output,'compressed filesystem: \d+ blocks/([^\r\n]+?) written')
    if ($sizes.Count) { $parsed.compressed_size_text=$sizes[$sizes.Count-1].Groups[1].Value }
    if ($result.output -match '(?<![\d,])([\d,]+) inodes\)') { $parsed.inode_count=[int64]($Matches[1].Replace(',','')) }
    $report=@{build_profile=$profile;source_precheck=$(if ($fast) {'SIZE_MTIME_ONLY'} else {'SHA256'});content_matches_ingest=$(if ($skip) {'NOT_CHECKED'} else {'PASS'});input_mode='SOURCE_LIST';input_list=$inputList;disc_id=$d.disc_id;image=$image;version=$version;arguments=$args;exit_code=$result.exit_code;log=$result.log;summary_lines=$summary;parsed_summary=$parsed;original_bytes=$rawBytes;image_bytes=(Get-Item -LiteralPath $image).Length;verification=$check;roundtrip=$roundtripStatus;roundtrip_mode=$roundtripMode}
    Write-Json (Join-Path $dir 'build.json') $report
    $report
}
function Generate-Parity($C,$Root,[double]$Percent) {
    if ($Percent -le 0) { return @{status='DISABLED';percent=0} }
    $exe=Resolve-Tool $C 'par2'
    $isPar2j=([IO.Path]::GetFileName($exe) -match '(?i)par2j')
    # One PAR2 set per payload file avoids command-line length limits and
    # recursive wildcard ambiguities with hundreds of thousands of files.
    $results=@(); $counter=0
    foreach ($f in @(Tree-Files (Join-Path $Root 'data') | Sort-Object FullName)) {
        $counter++; $out=Join-Path $Root ('parity/{0:D6}.par2' -f $counter)
        [IO.Directory]::CreateDirectory((Split-Path $out)) | Out-Null
        if ($f.Length -eq 0) { continue }
        if ($isPar2j) {
            $r=Run-Tool $C $exe @('c',"/rr$Percent",'/sn2000','/up','/uo',"/d$Root",$out,$f.FullName) 'par2j-create'
            $v=Run-Tool $C $exe @('v','/uo',"/d$Root",$out,$f.FullName) 'par2j-verify'
        } else {
            $r=Run-Tool $C $exe @('c',"-r$Percent",'-b2000',"-B$Root",$out,$f.FullName) 'par2-create'
            $v=Run-Tool $C $exe @('v',"-B$Root",$out,$f.FullName) 'par2-verify'
        }
        $results+=@{source=(Relative-Path $Root $f.FullName);index=(Relative-Path $Root $out);exit_code=$r.exit_code;verify_exit_code=$v.exit_code}
    }
    @{status='PASS';percent=$Percent;sets=$results}
}
function Seal-Stage($C,$D,$Root) {
    # Shared source data may change during staging. Bind each payload to the
    # immutable ingest/build hash, not merely to its current observed bytes.
    $expectedPayload=@{}
    if ($D.dwarfs) {
        $build=Read-Json (Safe-Join $C.archive_root "build/$($D.disc_id)/build.json")
        $expectedPayload["data/$($D.disc_id).dwarfs"]=$build.verification.sha256
    } else { foreach ($item in $D.files) { $expectedPayload[('data/'+$item.path)]=$item.sha256 } }
    $sealGuards=Open-StageReadGuards $Root
    try {
    $hashes=New-Object 'System.Collections.Generic.List[string]'
    $total=[int64]0
    foreach ($f in (Tree-Files $Root | Sort-Object FullName)) {
        if ($f.Name -eq 'SHA256SUMS' -and $f.DirectoryName -eq $Root) { continue }
        $rel=Relative-Path $Root $f.FullName
        $actual=File-Hash $f.FullName
        if ($expectedPayload.ContainsKey($rel) -and $actual -ne $expectedPayload[$rel]) { throw "Payload differs from ingest/build; source changed during staging: $rel" }
        $hashes.Add("$actual  $rel"); $total+=$f.Length
    }
    Write-Text (Join-Path $Root 'SHA256SUMS') (($hashes.ToArray() -join "`n")+"`n")
    $total+=(Get-Item -LiteralPath (Join-Path $Root 'SHA256SUMS')).Length
    $estimated=$total+[int64](@(Tree-Files $Root).Count*$C.planning.per_file_overhead_bytes)
    if ($estimated -gt ($D.budget.capacity_bytes-$D.budget.reserve_bytes)) { throw 'Actual staging + PAR2 + metadata exceeds disc budget. No burn is allowed.' }
    $seal=@{path=$Root;bytes=$total;estimated_bytes=$estimated;hash=(File-Hash (Join-Path $Root 'SHA256SUMS'));disc_json_hash=(File-Hash (Join-Path $Root 'DISC.json'));time=[DateTime]::UtcNow.ToString('o')}
    $seal.reference_manifests=@(Tree-Files $Root | Where-Object Name -eq 'ARCHIVE-REFERENCES.json' | ForEach-Object { @{path=(Relative-Path $Root $_.FullName);sha256=(File-Hash $_.FullName)} })
    $seal.receipt=New-StageReceipt ([pscustomobject]$seal) @(Get-StageStamps $Root)
    $seal
    } finally { Close-StageReadGuards $sealGuards }
}
function Stage-Archive($C,$P) {
    $d=Selected-PlanDisc $C $P; $record=Get-Disc $C $P.DiscId
    if (Optional-Field $record 'external_stage') {
        $guards=Open-StageReadGuards $record.stage.path
        try {$null=Confirm-StageForBurn $C $record} finally {Close-StageReadGuards $guards}
        return $record.stage
    }
    $ing=Load-Ingest $C $d.archive_set_id; $plan=Load-Plan $C $d.archive_set_id
    $stageBase=Optional-Field $C 'staging_root'
    if ($stageBase) {
        if (![IO.Path]::IsPathRooted($stageBase)) { throw 'Custom staging_root must be absolute.' }
        $stageBase=Full-Path $stageBase
        Assert-NoLinks $stageBase
        Assert-Separate $stageBase $ing.source_root
        Assert-Separate $stageBase $C.archive_root
        $root=Safe-Join $stageBase $d.disc_id
    } else { $root=Safe-Join $C.archive_root "staging/$($d.disc_id)" }
    if (Test-Path -LiteralPath $root) { throw 'Stage already exists (or a previous stage failed). Never silently overwrite a sealed stage.' }
    [IO.Directory]::CreateDirectory((Join-Path $root 'data')) | Out-Null
    $refs=@($d.files | Where-Object {Optional-Field $_ 'reference_target'} | ForEach-Object { @{path=('data/'+$_.path);target=(Archive-ReferenceSource $C $_)} })
    if($refs.Count){Write-Json (Join-Path $root 'ARCHIVE-REFERENCES.json') @{schema_version=1;files=$refs}}
    $storage=New-Object 'System.Collections.Generic.List[object]'
    if ($d.dwarfs) {
        $build=Read-Json (Safe-Join $C.archive_root "build/$($d.disc_id)/build.json")
        $fastBuild=((Optional-Field $build 'build_profile') -eq 'fast' -and $build.roundtrip -eq 'SKIPPED_FAST' -and (Optional-Field $build 'content_matches_ingest') -eq 'NOT_CHECKED')
        if (($build.roundtrip -ne 'PASS' -and !($fastBuild -and (Dwarfs-BuildProfile $C) -eq 'fast')) -or $build.verification.status -ne 'PASS' -or $build.verification.exit_code -ne 0) { throw 'DwarFS build does not meet the selected verification profile.' }
        $fastStage=((Dwarfs-BuildProfile $C) -eq 'fast')
        $transfer=Stage-Payload $build.image (Join-Path $root "data/$($d.disc_id).dwarfs") $build.verification.sha256 -SealWillVerify:$fastStage
        $storage.Add(@{path="data/$($d.disc_id).dwarfs";mode=$transfer.mode;bytes=$transfer.bytes})
        Write-Json (Join-Path $root 'BUILD.json') @{build_profile=(Optional-Field $build 'build_profile');content_matches_ingest=(Optional-Field $build 'content_matches_ingest');disc_id=$d.disc_id;version=$build.version;exit_code=$build.exit_code;summary_lines=$build.summary_lines;parsed_summary=$build.parsed_summary;original_bytes=$build.original_bytes;image_bytes=$build.image_bytes;image_sha256=$build.verification.sha256;integrity_exit_code=$build.verification.exit_code;roundtrip=$build.roundtrip;roundtrip_mode=(Optional-Field $build 'roundtrip_mode')}
    } else {
        foreach ($f in $d.files) {
            if (Optional-Field $f 'reference_target') {
                $transfer=New-ArchiveFileReference (Archive-ReferenceSource $C $f) (Safe-Join (Join-Path $root 'data') $f.path)
            } else { $transfer=Stage-Payload (Safe-Join $ing.source_root $f.path) (Safe-Join (Join-Path $root 'data') $f.path) $f.sha256 }
            $storage.Add(@{path=('data/'+$f.path);mode=$transfer.mode;bytes=$transfer.bytes})
        }
    }
    Write-Json (Join-Path $root 'PAYLOAD-STORAGE.json') @{schema_version=1;files=$storage.ToArray();note='HARDLINK shares HDD data with its source; it is not an independent backup. Do not edit staged payloads.'}
    Write-Host ("Payload staging: {0} same-volume hard links; {1} cross-volume copies." -f @($storage | Where-Object mode -eq 'HARDLINK').Count,@($storage | Where-Object mode -eq 'COPY').Count)
    # Do not publish the user's absolute source_root on NFC or optical media.
    $portable=Read-Json (Join-Path (Set-Dir $C $d.archive_set_id) 'ingest.json')
    $portable.PSObject.Properties.Remove('source_root')
    Write-Json (Join-Path $root 'SET-MANIFEST.json') @{schema_version=1;ingest=$portable;plan=$plan}
    $discMetadata=@{schema_version=1;disc_id=$d.disc_id;archive_set_id=$d.archive_set_id;position=$d.position;disc_count=$d.disc_count;media_type=$d.media_type;category=$d.category;udf_revision='2.50';dwarfs=$d.dwarfs;nfc_url=$record.nfc_url;created_at=[DateTime]::UtcNow.ToString('o')}
    foreach ($field in (Disc-Identity $d).PSObject.Properties) { $discMetadata[$field.Name]=$field.Value }
    $discMetadata.authoring_metadata=Disc-VolumeMetadata $d
    Write-Json (Join-Path $root 'DISC.json') $discMetadata
    $volumeNotes=@('Volume metadata / 卷描述','Filesystem: UDF 2.50','')
    foreach ($field in $discMetadata.authoring_metadata.values.PSObject.Properties) { $volumeNotes+="$($field.Name): $($field.Value) [$($discMetadata.authoring_metadata.targets.($field.Name))]" }
    Write-Text (Join-Path $root 'VOLUME-METADATA.txt') (($volumeNotes -join "`r`n")+"`r`n")
    Write-Text (Join-Path $root 'RESTORE.md') @"
# Restore $($d.archive_set_id) / $($d.disc_id)
Disc $($d.position) of $($d.disc_count). UDF 2.50 data disc.
Volume ID: $((Disc-Identity $d).volume_id). Label: $((Disc-Identity $d).volume_label).
Catalog disc index: $((Disc-Identity $d).disc_index).
Volume ID/index are logical catalog values; filesystem serial is recorded after physical verification.
Verify every SHA256SUMS entry before restore. SHA256SUMS does not hash itself;
its trusted SHA-256 is held in the external catalog and disc label CSV.
SET-MANIFEST.json contains the full file hashes, paths, directory list and disc order.
I / II / M: copy data/ into the destination preserving relative paths.
III: use DwarFS 0.15.7: dwarfsck --check-integrity -i data/$($d.disc_id).dwarfs
then dwarfsextract -i data/$($d.disc_id).dwarfs -o EMPTY_DIRECTORY.
Universal exe: prepend --tool=dwarfsck or --tool=dwarfsextract.
Extract each shard separately, merge identical root metadata, reject conflicts.
Full-set restore recreates duplicate aliases and empty directories from the manifest.
An iPhone backup requires ALL shards and its original encryption password if encrypted.
PAR2: verify/repair copies on HDD, never modify the original optical disc.
Keep the independent catalog, toolkit and tool versions with a core-data backup.
"@
    $parity=Generate-Parity $C $root $d.budget.par2_percent
    Write-Json (Join-Path $root 'PAR2.json') $parity
    $summaryParams=$P.Clone();$summaryParams.SetId=$d.archive_set_id
    $summary=Export-ArchiveSummary $C $summaryParams
    Copy-Checked $summary.txt (Join-Path $root 'ARCHIVE-SUMMARY.txt') (File-Hash $summary.txt)
    Copy-Checked $summary.json (Join-Path $root 'ARCHIVE-SUMMARY.json') (File-Hash $summary.json)
    Export-PhotoCatalog $C $ing (Join-Path $root 'PHOTO-CATALOG.csv') $d.disc_id
    $seal=Seal-Stage $C $d $root
    $record.stage=[pscustomobject]$seal; $record.hash=$seal.hash; $record.status='STAGED'; Update-Disc $C $record
    Event $C 'stage' @{disc_id=$d.disc_id;seal=$seal}; $seal
}
function Check-DiscTree($C,$Root,$Record,[switch]$Integrity,[int]$IntegrityWorkers=0) {
    Set-PreparationProgress '校验清单与光盘身份' -Force
    Assert-NoLinks $Root
    if (!$Record.stage) { throw 'Trusted stage seal is missing.' }
    $sums=Join-Path $Root 'SHA256SUMS'
    if ((File-Hash $sums) -ne $Record.stage.hash) { throw 'SHA256SUMS differs from trusted catalog.' }
    if ((File-Hash (Join-Path $Root 'DISC.json')) -ne $Record.stage.disc_json_hash) { throw 'Disc identity differs from trusted catalog.' }
    $seen=@{}; $count=0;$entries=New-Object 'System.Collections.Generic.List[object]';$total=[int64]0
    Set-PreparationProgress '统计清单文件容量（只读取文件属性）' -Force
    foreach ($line in [IO.File]::ReadAllLines($sums,$script:Utf8)) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw 'Malformed SHA256SUMS entry.' }
        $hash=$Matches[1]; $relative=$Matches[2]
        if ($seen.ContainsKey($relative) -or $relative -eq 'SHA256SUMS') { throw 'Duplicate/self-referential checksum entry.' }
        $seen[$relative]=$true; $path=Safe-Join $Root $relative
        $size=(Get-Item -LiteralPath $path -Force).Length
        $entries.Add(@{path=$path;relative=$relative;hash=$hash;size=$size});$total+=$size
    }
    # The denominator uses directory metadata only. Each payload is hashed once;
    # DwarFS receives that digest and retains its separate internal block check.
    $previousScope=$script:HashProgressScope
    $script:HashProgressScope=@{path='';total_bytes=$total;completed_bytes=[int64]0;index=0;count=$entries.Count}
    Write-Host ("SHA-256 校验：{0} 个文件，{1:N2} GiB" -f $entries.Count,($total/1GB))
    try {
        foreach ($entry in $entries) {
            $script:HashProgressScope.path=$entry.path;$script:HashProgressScope.index++
            if ((File-Hash $entry.path) -ne $entry.hash) { throw "SHA-256 FAIL: $($entry.relative)" }
            $script:HashProgressScope.completed_bytes+=$entry.size
            if ($Integrity -and $entry.relative.EndsWith('.dwarfs',[StringComparison]::OrdinalIgnoreCase)) {
                Write-Progress -Id 31 -Activity 'SHA-256 校验' -Completed
                $null=Verify-DwarfsImage $C $entry.path -VerifiedSha256 $entry.hash -Workers $IntegrityWorkers
            }
            $count++
        }
        Set-PreparationProgress '文件校验完成，核对文件数量' -Force
    } finally {
        $script:HashProgressScope=$previousScope
        Write-Progress -Id 31 -Activity 'SHA-256 校验' -Completed
    }
    if ($count -lt 4 -or @(Tree-Files $Root).Count -ne ($count+1)) { throw 'Unexpected file count, missing or additional disc files.' }
    @{file_count=$count;manifest_sha256=$Record.stage.hash;status='PASS'}
}
