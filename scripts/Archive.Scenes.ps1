function Photo-Kind([string]$Path) {
    switch -Regex ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '^\.(arw|srf|sr2|cr2|cr3|crw|nef|nrw|raf|rw2|orf|pef|dng|raw|3fr|iiq|rwl|srw|x3f)$' { return 'RAW' }
        '^\.(jpg|jpeg|heic|heif|png)$' { return 'PREVIEW' }
        '^\.(tif|tiff|psd|psb)$' { return 'MASTER' }
        '^\.(xmp|dop|pp3|aae)$' { return 'SIDECAR' }
        default { return 'OTHER' }
    }
}
function Photo-Family([string]$Path) {
    # Same-directory IMG.ARW, IMG.JPG, IMG.XMP and IMG.ARW.XMP stay together.
    # This is filename association, never aesthetic selection or visual dedup.
    $stem=[IO.Path]::ChangeExtension($Path,[NullString]::Value)
    if ((Photo-Kind $Path) -eq 'SIDECAR' -and (Photo-Kind $stem) -ne 'OTHER') { $stem=[IO.Path]::ChangeExtension($stem,[NullString]::Value) }
    if ((Photo-Kind $Path) -eq 'OTHER') { return "OTHER:$Path" }
    $stem.Replace('\','/').ToLowerInvariant()
}
function New-ArchiveProfile($P) {
    $scene=$P.Scenario
    if (!$scene) { $scene=@{I='photo';II='game';III='backup';M='core'}[$P.Category] }
    if ($scene -notin @('photo','game','backup','core')) { throw 'Select photo, game or backup (core is an advanced category).' }
    $tier=$null
    if ($scene -eq 'photo') { $tier=$P.PhotoTier; if (!$tier) { $tier='C' }; if ($tier -notin @('A','B','C')) { throw 'PhotoTier must be A, B or C.' } }
    $category=@{photo='I';game='II';backup='III';core='M'}[$scene]
    if ($scene -eq 'photo' -and $tier -eq 'A') { $category='M' }
    [pscustomobject]@{scenario=$scene;category=$category;photo_tier=$tier;date_range=$P.DateRange;camera=$P.Camera;tags=$P.Tags;game=$P.Game;master_status=$P.MasterStatus;earlier_original_status=$P.EarlierOriginalStatus;annotation_source='user supplied; dates are not inferred from file modification time'}
}
function Scene-Details($Ingest) {
    $profile=Optional-Field $Ingest 'profile'
    if (!$profile) { return $null }
    $result=[ordered]@{scenario=$profile.scenario}
    if ($profile.scenario -eq 'photo') {
        $result.photo_tier=$profile.photo_tier
        $result.date_range=$profile.date_range; $result.camera=$profile.camera; $result.tags=$profile.tags
        foreach ($kind in @('RAW','PREVIEW','MASTER','SIDECAR','OTHER')) { $result[($kind.ToLowerInvariant()+'_files')]=@($Ingest.files | Where-Object { (Photo-Kind $_.path) -eq $kind }).Count }
        $result.photo_families=@($Ingest.files | Where-Object { (Photo-Kind $_.path) -ne 'OTHER' } | Group-Object { Photo-Family $_.path }).Count
        $result.photo_policy=if ($profile.photo_tier -eq 'C') { 'Cold rejected/unselected RAW; direct files; source deletion needs verified optical readback and explicit confirmation.' } else { 'Keep HDD/another copy. This toolkit does not delete Tier A/B photo sources.' }
        $result.metadata_note='Counts use extensions; family links use names. Date range/camera/tags are user notes, not extracted EXIF.'
    } elseif ($profile.scenario -eq 'game') {
        $result.game=$profile.game; $result.date_range=$profile.date_range; $result.tags=$profile.tags
        $result.master_status=$profile.master_status; $result.earlier_original_status=$profile.earlier_original_status
        $result.video_files=@($Ingest.files | Where-Object { $_.path -match '(?i)\.(mkv|mp4|mov|avi|webm|m2ts|ts)$' }).Count
        $result.metadata_note='Events are user reviewed. Earlier original status refers to a historical source, separate from deletion of this ingest.'
    } else { return $null }
    [pscustomobject]$result
}
function Export-PhotoCatalog($C,$Ingest,$Destination,$DiscId) {
    $profile=Optional-Field $Ingest 'profile'; if (!$profile -or $profile.scenario -ne 'photo') { return }
    $planPath=Join-Path (Set-Dir $C $Ingest.archive_set_id) 'plan.json'; $assignment=@{}
    if (Test-Path -LiteralPath $planPath) {
        foreach ($d in (Read-Json $planPath).discs) { foreach ($f in $d.files) { $assignment[$f.path]=$d.disc_id } }
    }
    $rows=foreach ($f in $Ingest.files) {
        $disc=$assignment[$f.path]
        if (!$disc -and $f.alias_of) { $disc=$assignment[$f.alias_of] }
        if ($DiscId -and $disc -ne $DiscId) { continue }
        [pscustomobject]@{path=$f.path;kind=(Photo-Kind $f.path);family=(Photo-Family $f.path);bytes=$f.size;sha256=$f.sha256;disc_id=$disc;alias_of=$f.alias_of}
    }
    $rows | Export-Csv -LiteralPath $Destination -NoTypeInformation -Encoding UTF8
}
function Prepare-Archive($C,$P) {
    Assert-NoPendingIdentityChange $C
    # Compose the existing entry points; no burn or deletion occurs here.
    Assert-Id $P.SetId; $profile=New-ArchiveProfile $P
    if (!$P.Source) { throw 'Select the source folder before preparation.' }
    Assert-PhotoSourceRoot $P.Source
    $P.Category=$profile.category
    if (!(Test-Path -LiteralPath (Catalog-Path $C))) { $null=Invoke-Archive init $P }
    $dir=Set-Dir $C $P.SetId
    if (!(Test-Path -LiteralPath (Join-Path $dir 'ingest.json'))) {
        $null=Invoke-Archive scan $P
    } else {
        $ing=Load-Ingest $C $P.SetId; $old=Optional-Field $ing 'profile'
        Assert-PhotoSourceRoot $ing.source_root $ing
        if ((Full-Path $P.Source) -ne $ing.source_root -or $ing.category -ne $profile.category -or ($old -and ($old.scenario -ne $profile.scenario -or $old.photo_tier -ne $profile.photo_tier))) { throw 'Existing set belongs to a different source/scenario/tier. Use a new SetId.' }
        Write-Host 'Resume: keeping the existing immutable ingest and plan.'
    }
    if (!(Test-Path -LiteralPath (Join-Path $dir 'plan.json'))) { $null=Invoke-Archive plan $P }
    else {
        $saved=Load-Plan $C $P.SetId
        if ($P.StartDiscId -and $P.StartDiscId -cne $saved.discs[0].disc_id) { throw 'Starting disc ID differs from immutable plan. Use a new SetId.' }
        $requested=Volume-Templates $C $P
        $oldVolume=Optional-Field $saved 'volume_templates'
        if (!$oldVolume) { $oldVolume=[pscustomobject]@{iso9660='';joliet='';system='';volume_set='';publisher='';data_preparer='';application=''} }
        foreach ($key in @('iso9660','joliet','system','volume_set','publisher','data_preparer','application')) {
            if ([string]$oldVolume.$key -cne [string]$requested.$key) { throw "Volume metadata template differs from immutable plan: $key. 在制作页输入原 Archive ID，点击[载入原计划设置]后再准备；不要修改 plan.json。" }
        }
        $oldTemplate=Optional-Field $saved 'volume_label_template';if (!$oldTemplate) { $oldTemplate='{disc_id}' }
        if ($oldTemplate -cne (Volume-LabelTemplate $C $P)) { throw 'Volume label template differs from immutable plan. Use the original template or a new SetId.' }
        if (($P.Media -and $saved.discs[0].media_type -ne $P.Media) -or ($null -ne $P.ParPercent -and $saved.discs[0].budget.par2_percent -ne $P.ParPercent) -or [bool]$saved.deduplicated -ne [bool]$P.Deduplicate) { throw 'Preparation options differ from the immutable plan. 点击[载入原计划设置]恢复原介质、PAR2 和去重选项。' }
    }
    foreach ($d in (Load-Plan $C $P.SetId).discs) {
        Assert-PreparationRunning;Set-PreparationDisc $d
        $one=$P.Clone();$one.DiscId=$d.disc_id
        # Decide from recorded completion BEFORE looking for cleaned build files.
        $rec=Get-Disc $C $d.disc_id
        if ($rec.burn -and !$rec.burn.simulation) {
            if ((Optional-Field $rec.burn 'result') -ne 'WRITTEN') {throw "已有尚未确认结果的刻录尝试：$($d.disc_id)。先处理刻录记录，再继续制作；不会重编或占用新盘号。"}
            Write-Host "跳过已写入光盘 $($d.disc_id)；无需本地制作文件，保留原校验状态。"
            continue
        }
        if ($rec.stage) {
            Write-Host "复用已制作目录 $($d.disc_id) ($($d.position)/$($d.disc_count))"
            $guards=Open-StageReadGuards $rec.stage.path
            try {$null=Confirm-StageForBurn $C $rec} finally {Close-StageReadGuards $guards}
            continue
        }
        Write-Host "Preparing $($d.disc_id) ($($d.position)/$($d.disc_count))"
        if ($d.dwarfs -and !(Test-Path -LiteralPath (Safe-Join $C.archive_root "build/$($d.disc_id)/build.json"))) { $null=Invoke-Archive build $one }
        $null=Invoke-Archive stage $one
    }
    Assert-PreparationRunning
    $summary=Invoke-Archive summary $P
    Assert-PreparationRunning
    @{status='READY_FOR_REVIEW';archive_set_id=$P.SetId;summary=$summary.txt;discs=@((Load-Plan $C $P.SetId).discs | Select-Object disc_id,disc_index,volume_id,volume_label,position,disc_count,media_type);note='Preparation stops before burning. Each real disc requires user confirmation.'}
}
function Burn-ReviewText($D,$Record,$Drive,$Backend,$FreeBytes,[string]$RequestedSpeed='') {
    @"
REAL BD-R BURN / 真实刻碟
Disc: $($D.disc_id)  [$($D.position)/$($D.disc_count)]
Archive set: $($D.archive_set_id)
Catalog index: $((Disc-Identity $D).disc_index)
Volume ID: $((Disc-Identity $D).volume_id)
Volume label: $((Disc-Identity $D).volume_label)
Volume metadata: $((Disc-VolumeMetadata $D).values | ConvertTo-Json -Compress)
Source files on disc: $(@($D.files).Count)
Payload: $($Record.stage.bytes) bytes
Target drive: $Drive
Media: $($D.media_type) / BD-R / $FreeBytes free bytes
Backend: $Backend
Requested speed: $RequestedSpeed
Filesystem: UDF 2.50 / single session / finalize
Staging: $($Record.stage.path)
SHA256SUMS SHA-256: $($Record.stage.hash)

Only this disc is authorized. A replacement disc needs fresh confirmation.
本步骤将不可逆地写入空白光盘。取消或关闭窗口不会刻碟。
"@
}
function Confirm-PhysicalBurn($C,$D,$Record,$P,$Backend,$FreeBytes) {
    $requestedSpeed=if ($Backend -eq 'ImgBurn') { ImgBurn-RequestedSpeed $C } else { 'selected by IMAPI2' }
    $review=Burn-ReviewText $D $Record $P.Drive $Backend $FreeBytes $requestedSpeed
    $readback=if ($Backend -eq 'ImgBurn' -and [bool](Optional-Field $C.burn 'verify_after_write')) {'Enabled / 已启用'} else {'Off / 不自动回读'}
    $review+="`r`nPost-burn readback: $readback`r`n"
    $expected="BURN $($D.disc_id)"; $answer='';$method='interactive exact-disc phrase'
    if ($P.ConfirmationMode -eq 'Typed') {
        # The browser bridge authenticates Origin/token and records a one-use
        # review. This core gate independently binds the literal user entry to
        # the current plan, target drive and sealed staging manifest. Context is
        # a freshness check, not a substitute for bridge authentication.
        if ($P.Execute -isnot [bool] -or !$P.Execute -or $P.BurnConfirmed -isnot [bool] -or !$P.BurnConfirmed) {
            throw 'Typed physical burn requires explicit boolean Execute and BurnConfirmed.'
        }
        $context=$P.ConfirmationContext
        if ($null -eq $context -or ($context -isnot [Collections.IDictionary] -and $context -isnot [pscustomobject])) {
            throw 'Physical burn cancelled: confirmation context is missing or invalid.'
        }
        $current=@{disc_id=$D.disc_id;drive=$P.Drive;manifest_sha256=$Record.stage.hash}
        foreach ($field in @('disc_id','drive','manifest_sha256')) {
            $confirmed=Optional-Field $context $field;$actual=$current[$field]
            if ($confirmed -isnot [string] -or [string]::IsNullOrWhiteSpace($confirmed) -or
                $actual -isnot [string] -or [string]::IsNullOrWhiteSpace($actual) -or $confirmed -cne $actual) {
                throw "Physical burn cancelled: confirmation context differs from current $field. Review this disc again."
            }
        }
        if ($P.ConfirmationText -isnot [string]) {
            throw 'Physical burn cancelled: explicit user confirmation must be a literal string.'
        }
        # Never trim, case-fold, infer or generate the user's confirmation text.
        $answer=$P.ConfirmationText;$method='typed exact-disc phrase with stage context'
    } elseif ($P.ConfirmationMode -eq 'Dialog') {
        Write-Host "等待用户确认：请在 [确认刻碟 / Confirm disc] 窗口检查 $($D.disc_id) → $($P.Drive)，亲自确认或取消。"
        $dpiState=Initialize-ArchiveDpi
        $popup=New-BurnConfirmationForm $review $expected
        try { if ($popup.form.ShowDialog() -eq 'OK') { $answer=$popup.answer.Text } }
        finally { $popup.form.Dispose();Restore-ArchiveDpi $dpiState }
    } else {
        Write-Host $review
        $answer=Read-Host "USER: type $expected to write this disc (anything else cancels)"
    }
    if ($answer -cne $expected) { throw 'Physical burn cancelled: explicit user confirmation did not match the disc ID.' }
    $receipt=[pscustomobject]@{disc_id=$D.disc_id;archive_set_id=$D.archive_set_id;drive=$P.Drive;backend=$Backend;manifest_sha256=$Record.stage.hash;time=[DateTime]::UtcNow.ToString('o');method=$method;scope='this single burn attempt'}
    Event $C 'user-burn-confirmed' $receipt
    $receipt
}
function Get-SavedPreparationSettings($C,$SetId) {
    Assert-Id $SetId
    $dir=Set-Dir $C $SetId
    if (!(Test-Path -LiteralPath (Join-Path $dir 'ingest.json'))) { throw "原计划或扫描清单不存在。当前库中找不到 $SetId 的扫描清单，请检查 Archive ID 和工具与目录中的归档目录。" }
    if (!(Test-Path -LiteralPath (Join-Path $dir 'plan.json'))) { throw "扫描清单存在，但尚未生成分盘计划：$SetId。请查看上次准备失败的日志；修复后以相同设置继续准备即可使用已完成扫描，不要删除清单或重扫。" }
    $plan=Load-Plan $C $SetId;$ing=Load-Ingest $C $SetId
    if ($plan.archive_set_id -cne $SetId -or $ing.archive_set_id -cne $SetId -or !$plan.discs.Count) { throw 'Invalid saved archive set.' }
    if ((File-Hash (Join-Path (Set-Dir $C $SetId) 'ingest.json')) -ne $plan.ingest_sha256) { throw 'Ingest manifest has changed since planning.' }
    $profile=Optional-Field $ing 'profile'
    $scene=Optional-Field $profile 'scenario';if (!$scene) { $scene=@{I='photo';II='game';III='backup';M='core'}[$ing.category] }
    $tier=Optional-Field $profile 'photo_tier';if ($scene -eq 'photo' -and !$tier) { $tier='C' }
    $volume=@{};$saved=Optional-Field $plan 'volume_templates'
    foreach ($key in @('iso9660','joliet','system','volume_set','publisher','data_preparer','application')) { $volume[$key]=[string](Optional-Field $saved $key) }
    $label=Optional-Field $plan 'volume_label_template';if (!$label) { $label='{disc_id}' }
    $first=$plan.discs[0]
    $params=@{SetId=$SetId;Source=$ing.source_root;Scenario=$scene;Category=$ing.category;PhotoTier=$tier;StartDiscId=$first.disc_id;Media=$first.media_type;ParPercent=[double]$first.budget.par2_percent;Deduplicate=[bool]$plan.deduplicated;DetectDuplicates=[bool]$plan.deduplicated;VolumeLabelTemplate=$label;VolumeTemplates=$volume}
    foreach ($pair in @(@('DateRange','date_range'),@('Camera','camera'),@('Game','game'),@('MasterStatus','master_status'))) { $params[$pair[0]]=Optional-Field $profile $pair[1] }
    $cat=Read-Json (Catalog-Path $C);$set=@($cat.sets | Where-Object archive_set_id -eq $SetId)
    if ($set.Count -ne 1) { throw 'Saved set is missing from catalog.' }
    $params.Summary=$set[0].summary
    $annotations=Optional-Field $set[0] 'summary_annotations'
    $params.SecondCopy=Optional-Field $annotations 'second_copy';$params.PasswordStorage=Optional-Field $annotations 'password_storage'
    @{parameters=$params;disc_count=$plan.discs.Count;first_disc=$first;status='LOADED_READ_ONLY'}
}

