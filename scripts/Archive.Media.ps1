function Get-Recorder($Drive,$RecorderId) {
    if ($Drive -notmatch '^[A-Za-z]:[\\/]?$') { throw 'Specify an optical drive letter such as E:.' }
    $letter=$Drive.Substring(0,2).ToUpperInvariant()
    $master=New-Object -ComObject IMAPI2.MsftDiscMaster2
    foreach ($id in $master) {
        $rec=New-Object -ComObject IMAPI2.MsftDiscRecorder2; $rec.InitializeDiscRecorder($id)
        foreach ($path in $rec.VolumePathNames) { if ($path.Substring(0,2).ToUpperInvariant() -eq $letter) {
            if ($RecorderId -and $RecorderId -cne $id) { throw 'The selected drive now refers to another device. Refresh and select again.' }
            return $rec
        } }
    }
    throw "No IMAPI2 recorder matches $letter"
}
function ImgBurn-RequestedSpeed($C) {
    $speed=[string]$C.burn.speed
    if ($speed -ceq 'MAX') { return $speed }
    if ($speed -cnotmatch '^[0-9]{1,2}([.,][0-9])?x$' -or [double]::Parse($speed.TrimEnd('x').Replace(',','.'),[Globalization.CultureInfo]::InvariantCulture) -le 0) { throw 'ImgBurn speed must be MAX or a positive speed shown by ImgBurn, for example 4x or 6x.' }
    $speed
}
function New-BurnWriter($Recorder) {
    $writer=New-Object -ComObject IMAPI2.MsftDiscFormat2Data
    $writer.Recorder=$Recorder;$writer.ClientName='BD Archive Toolkit';$writer.ForceMediaToBeClosed=$true
    $writer
}
function Burn-Archive($C,$P) {
    $d=Selected-PlanDisc $C $P; $record=Get-Disc $C $P.DiscId
    $sourceIngest=Load-Ingest $C $d.archive_set_id
    Assert-PhotoSourceRoot $sourceIngest.source_root $sourceIngest
    $replaceSimulation=$false
    if ($record.burn) {
        if ([bool](Optional-Field $record.burn 'simulation')) {
            if ($P.Simulate) { throw '此盘已有模拟写入。可先点“清除模拟写入”，再重新模拟。' }
            $replaceSimulation=$true
        } else {
            Import-LegacyBurnEvidence $C $record
            $outcome=Read-BurnOutcome $record.burn
            if (!$P.Simulate -and $outcome.retry_allowed) { Reset-UnwrittenBurn $C $record $outcome }
            else { throw '此盘已有实体写入记录。未写入的取消可用“恢复取消的待刻记录”；已写入或结果不明的记录须先检查日志。' }
        }
    }
    if (!$record.stage) { throw '请先准备待刻目录；ID 修改后需重新载入归档设置并准备，已编译镜像会复用。' }
    Write-Host "检查待刻目录 $($d.disc_id)…"
    # Hold the same read guards through verification, user review and writing.
    # Confirmation cannot invalidate checked bytes, so a second full read is
    # unnecessary. The outer finally also releases guards on preflight failure.
    $readGuards=Open-StageReadGuards $record.stage.path
    try {
        $preflight=Confirm-StageForBurn $C $record
        $identity=Assert-SealedIdentity $C $d $record
        if ($P.Simulate) {
            $simulationSuffix=Optional-Field $record 'simulation_revision'
            $simulationName=$d.disc_id+$(if ($simulationSuffix) {'-'+$simulationSuffix} else {''})
            $root=Safe-Join $C.archive_root ('simulated/'+$simulationName)
            if (Test-Path -LiteralPath $root) { throw 'Simulation destination already exists.' }
            [IO.Directory]::CreateDirectory($root) | Out-Null
            foreach ($f in (Tree-Files $record.stage.path)) { Copy-Checked $f.FullName (Safe-Join $root (Relative-Path $record.stage.path $f.FullName)) (File-Hash $f.FullName) }
            $record.burn=[pscustomobject]@{simulation=$true;root=$root;time=[DateTime]::UtcNow.ToString('o');backend='SIMULATION'}
            $record.status='SIMULATED'; Update-Disc $C $record; return $record.burn
        }
        if (!$P.BurnConfirmed) { throw 'Physical writing requires both -Execute and -BurnConfirmed; use -Simulate for an HDD mock.' }
        $backend=$C.burn.backend; if ($P.Backend) { $backend=$P.Backend }
        Assert-VolumeBackend $d $backend
        if($backend -ne 'ImgBurn' -and (Test-Path -LiteralPath (Join-Path $record.stage.path 'ARCHIVE-REFERENCES.json'))){throw 'File references require the validated ImgBurn advanced-project backend.'}
        $rec=Get-Recorder $P.Drive $P.RecorderId
        $writer=New-BurnWriter $rec
        if (!$writer.IsCurrentMediaSupported($rec) -or !$writer.MediaPhysicallyBlank) { throw 'A supported, physically blank BD-R is required. Erase/append is never enabled.' }
        if ([int]$writer.CurrentPhysicalMediaType -ne 18) { throw 'Only write-once BD-R is accepted; BD-RE/DVD/CD are rejected.' }
        $free=[int64]$writer.FreeSectorsOnMedia*2048
        if ($record.stage.estimated_bytes -gt $free) { throw 'Actual inserted medium has insufficient capacity.' }
        if ($d.media_type -eq 'BD50' -and $free -lt 45000000000) { throw 'Plan requires 50GB DL media.' }
        if ($replaceSimulation) {
            # A simulation is an HDD copy, not physical-write evidence. Only after
            # the staged payload and selected blank medium pass preflight do we
            # discard that derived copy and transition to a physical attempt.
            $null=Clear-ArchiveSimulation $C @{DiscId=$record.disc_id;Reason='SWITCH_TO_PHYSICAL_BURN'}
            $record=Get-Disc $C $record.disc_id
        }
        $record.burn=[pscustomobject]@{simulation=$false;drive=$P.Drive;time=[DateTime]::UtcNow.ToString('o');backend=$backend;free_bytes=$free;finalize_requested=$true;udf_revision='2.50';result='STARTED'}
        $record.burn | Add-Member -MemberType NoteProperty -Name user_confirmation -Value $null
        $record.burn | Add-Member NoteProperty preflight $preflight
        $postVerify=[bool](Optional-Field $C.burn 'verify_after_write')
        try {
            if ($backend -eq 'IMAPI2') {
                # Native Windows authoring, no Nero API and no intermediary ISO.
                # Query UDF 2.50 support and fail instead of downgrading silently.
                $fsi=New-Object -ComObject IMAPI2FS.MsftFileSystemImage
                $fsi.ChooseImageDefaults($rec)
                if (@($fsi.UDFRevisionsSupported) -notcontains 0x250) { throw 'This IMAPI2 installation cannot author UDF 2.50. Use the ImgBurn backend.' }
                $fsi.FileSystemsToCreate=4; $fsi.UDFRevision=0x250
                $fsi.VolumeName=$identity.volume_label; $fsi.StrictFileSystemCompliance=$true
                $fsi.FreeMediaBlocks=[int]$writer.FreeSectorsOnMedia
                $fsi.Root.AddTree($record.stage.path,$false)
                $image=$fsi.CreateResultImage()
                if ([int64]$image.TotalBlocks*2048 -gt [math]::Min($free,$d.budget.capacity_bytes-$d.budget.reserve_bytes)) { throw 'Authored UDF image exceeds capacity/reserve.' }
                # ForceMediaToBeClosed is an explicit single-session finalization.
                $record.burn.user_confirmation=Confirm-PhysicalBurn $C $d $record $P $backend $free
                Assert-StageReadGuardMembership $record.stage.path $readGuards
                if (!$writer.MediaPhysicallyBlank -or [int64]$writer.FreeSectorsOnMedia*2048 -ne $free) { throw 'Inserted media changed after confirmation; restart and confirm again.' }
                $record.status='BURNING'; Update-Disc $C $record
                $writer.Write($image.ImageStream)
                $rec.EjectMedia()
            } elseif ($backend -eq 'ImgBurn') {
                $exe=Resolve-Tool $C 'imgburn'
                $job=Safe-Join $C.archive_root ('images/'+$d.disc_id+'-'+[guid]::NewGuid().ToString('N'))
                $project=Write-ImgBurnProject $d $record.stage.path (Join-Path $job 'disc.ibb') -OutputMode DEVICE
                $nativeLog=Join-Path $job 'ImgBurn.log'
                $record.burn | Add-Member NoteProperty project $project
                $record.burn | Add-Member NoteProperty native_log $nativeLog
                $record.burn | Add-Member NoteProperty exit_code $null
                # Post-write readback is opt-in; never label a write as hash PASS.
                $args=@('/MODE','BUILD','/BUILDMODE','DEVICE','/SRC',$project,'/DEST',$P.Drive,
                    '/PORTABLE','/SETTINGS',(Join-Path $job 'settings.ini'),'/NOSAVESETTINGS',
                    '/FILESYSTEM','UDF','/UDFREVISION','2.50','/VOLUMELABEL',$identity.volume_label,
                    '/ROOTFOLDER','YES','/PRESERVEFULLPATHNAMES','NO','/RECURSESUBDIRECTORIES','YES',
                    '/INCLUDEHIDDENFILES','YES','/INCLUDESYSTEMFILES','YES','/INCLUDEARCHIVEFILESONLY','NO',
                    '/CLEARARCHIVEATTRIBUTE','NO','/DELETESOURCE','NO','/DELETEIMAGE','NO','/OVERWRITE','NO',
                    '/TESTMODE','NO','/VERIFY',$(if ($postVerify) {'YES'} else {'NO'}),'/EJECT','YES','/LOG',$nativeLog,'/LOGHEADER','/LANGID','0x0809','/SPEED',(ImgBurn-RequestedSpeed $C),'/START','/CLOSE')
                $record.burn.user_confirmation=Confirm-PhysicalBurn $C $d $record $P $backend $free
                Assert-StageReadGuardMembership $record.stage.path $readGuards
                if (!$writer.MediaPhysicallyBlank -or [int64]$writer.FreeSectorsOnMedia*2048 -ne $free) { throw 'Inserted media changed after confirmation; restart and confirm again.' }
                $record.status='BURNING'; Update-Disc $C $record
                Write-Host "确认已收到，正在启动 ImgBurn；请求速度 $(ImgBurn-RequestedSpeed $C)。"
                $toolResult=Run-Tool $C $exe $args 'imgburn' @(0,1,2,3,4,5)
                $record.burn.exit_code=$toolResult.exit_code
                if (Test-Path -LiteralPath $nativeLog) { $record.burn | Add-Member NoteProperty native_log_sha256 (File-Hash $nativeLog) -Force }
                Update-Disc $C $record
                $outcome=Read-BurnOutcome $record.burn
                $record.burn | Add-Member NoteProperty outcome $outcome -Force
                if ($outcome.retry_allowed) {
                    Reset-UnwrittenBurn $C $record $outcome
                    return @{status='CANCELLED';disc_id=$d.disc_id;retry_allowed=$true;outcome=$outcome}
                }
                if ($outcome.result -ne 'WRITTEN') { throw "刻录结果无法确认：$($outcome.reason)。日志：$nativeLog" }
            } else { throw 'Backend must be IMAPI2 or ImgBurn.' }
            $record.burn.result='WRITTEN'; $record.status='BURNED_UNVERIFIED'; $record.burn_date=[DateTime]::UtcNow.ToString('o')
        } catch {
            if ($record.status -ne 'BURNING') {
                # Cancelling before the write does not consume the staged disc ID.
                $record.burn=$null; Update-Disc $C $record
            } else { $record.burn.result='UNKNOWN'; $record.status='BURN_NEEDS_REVIEW'; Update-Disc $C $record }
            Event $C 'burn-failed' @{disc_id=$d.disc_id;error=$_.Exception.Message}; throw
        }
        Update-Disc $C $record; Event $C 'burn-returned' $record.burn; $record.burn
    } finally { Close-StageReadGuards $readGuards }
}
function Verify-ArchiveDisc($C,$P) {
    $record=Get-Disc $C $P.DiscId
    Set-PreparationDisc $record
    Set-PreparationProgress '检查光盘身份、文件系统和封盘状态' -Force
    if (!$record.burn) { throw 'No burn/simulation record exists.' }
    $simulation=[bool]$P.Simulate
    if ($simulation -ne [bool]$record.burn.simulation) { throw 'Simulation and physical burn records cannot be mixed.' }
    $deep=[bool](Optional-Field $P 'DeepVerifyDwarfs')
    $report=@{schema_version=1;method=$(if ($deep) {'SHA256_AND_DWARFS_INTEGRITY'} else {'SHA256'});disc_id=$P.DiscId;status='NOT_RUN';phase='MEDIA_PREFLIGHT';simulation=$simulation;manifest_sha256=$record.hash;time=[DateTime]::UtcNow.ToString('o');root=$null;media=$null;error=$null}
    try {
        if ($simulation) { $root=$record.burn.root }
        else {
            if (!$P.MediaReloaded) { throw 'Eject and reinsert the written disc, then pass -MediaReloaded to acknowledge fresh optical enumeration.' }
            $report.media=Get-OpticalReadbackMedia $P.Drive $record $P.RecorderId
            $report.media.reloaded_acknowledged=$true
            $root=$report.media.root
            if ($null -eq $report.media.finalized) { throw '无法确认封盘状态，内容校验尚未开始。请查看报告中的设备返回值。' }
            if (!$report.media.finalized) { throw '盘片直接报告为空白、未完成或会话不完整，内容校验尚未开始。' }
        }
        $report.root=$root
        $report.phase='CONTENT';$report.status='FAIL'
        $result=Check-DiscTree $C $root $record -Integrity:$deep -IntegrityWorkers 1
        $report.status='PASS'; $report.file_count=$result.file_count
    } catch {
        $report.error=$_.Exception.Message
        if (Is-PreparationCancellation $_) {
            $report.status='CANCELLED'
            # Stop the read loop first, then persist its outcome; report hashing
            # must not re-enter the already acknowledged cancellation request.
            $script:VerificationJob=$null
        }
    }
    $reportPath=Join-Path $C.archive_root ("reports/$($P.DiscId)-"+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')+'.json')
    Write-Json $reportPath $report
    $attempt=[pscustomobject]@{status=$report.status;phase=$report.phase;simulation=$simulation;report=$reportPath;report_sha256=(File-Hash $reportPath);manifest_sha256=$record.hash;time=$report.time;media=$report.media}
    $record | Add-Member NoteProperty last_verification_attempt $attempt -Force
    if ($report.status -in @('PASS','FAIL')) { $record.verification=$attempt }
    if ($report.status -eq 'FAIL') { $record.status='VERIFY_FAILED' }
    elseif ($report.status -eq 'PASS' -and $simulation) { $record.status='SIMULATED_PASS' }
    elseif ($report.status -eq 'PASS') { $record.status='VERIFIED' }
    Update-Disc $C $record; Event $C 'verify-disc' $report
    Set-PreparationProgress ("校验结果："+$report.status) -Force
    if ($report.status -eq 'CANCELLED') { throw [OperationCanceledException]::new("Verification cancelled; no new PASS. Report: $reportPath") }
    if ($report.status -eq 'FAIL') { throw "Disc verify FAIL: $($report.error). Report: $reportPath" }
    if ($report.status -eq 'NOT_RUN') { throw "Disc verify NOT_RUN: $($report.error). Report: $reportPath" }
    $report
}
function Register-ArchiveDisc($C,$P) {
    $record=Get-Disc $C $P.DiscId
    if (!$record.burn -or $record.status -notin @('BURNED_UNVERIFIED','VERIFIED','SIMULATED_PASS')) { throw 'Register requires a completed write or verified simulation.' }
    if ($record.verification -and (File-Hash $record.verification.report) -ne $record.verification.report_sha256) { throw 'Verification report has changed.' }
    if (!$P.Location) { throw 'Provide -Location, for example P-01 / Page 37 / A.' }
    $record.location=$P.Location; $record.registered=$true; Update-Disc $C $record
    Event $C 'register' @{disc_id=$record.disc_id;location=$P.Location}
    $null=Export-ArchiveIndex $C
    $record | Select-Object disc_id,status,location,nfc_url
}
function Split-ArchiveVideo($C,$P) {
    $exe=Resolve-Tool $C 'mkvmerge'; $source=Full-Path $P.Source; $out=Full-Path $P.Output
    if (Test-Path -LiteralPath $out) { throw 'Video output must be a new directory.' }
    [IO.Directory]::CreateDirectory($out) | Out-Null
    $target=$C.video.target_gib; if ($P.TargetGiB) { $target=$P.TargetGiB }
    if ($target -le 0 -or $target -gt $C.video.maximum_gib) { throw 'Invalid video target size.' }
    $before=File-Hash $source
    $identify=Run-Tool $C $exe @('-J',$source) 'mkvmerge-identify'
    Write-Text (Join-Path $out 'SOURCE-MEDIA.json') $identify.output
    $version=Run-Tool $C $exe @('--version') 'mkvmerge-version'
    $args=@('-o',(Join-Path $out 'segment.mkv'),'--split',('size:'+([int64][math]::Floor($target*1GB)).ToString()),$source)
    # No codec options, re-encoding, linking or dropping tracks. mkvmerge keeps
    # supported tracks/tags/chapters; independent segments use local timestamps.
    $r=Run-Tool $C $exe $args 'mkvmerge-split' @(0,1)
    if ($r.exit_code -eq 1) { throw "mkvmerge returned warnings; inspect $($r.log) before accepting segments." }
    if ((File-Hash $source) -ne $before) { throw 'Video source changed during split.' }
    $segments=@(Get-ChildItem -LiteralPath $out -Filter '*.mkv' | Sort-Object Name)
    if (!$segments.Count) { throw 'No MKV segments produced.' }
    $offset=[double]0; $manifest=@()
    foreach ($f in $segments) {
        if ($f.Length -gt $C.video.maximum_gib*1GB) { throw 'Keyframe overshoot: segment exceeds maximum. Retry in a NEW output directory with a lower TargetGiB.' }
        $meta=Run-Tool $C $exe @('-J',$f.FullName) 'segment-identify'
        $j=ConvertFrom-Json $meta.output; $duration=[double]$j.container.properties.duration/1e9
        $manifest+=@{file=$f.Name;size=$f.Length;sha256=(File-Hash $f.FullName);estimated_start_seconds=$offset;duration_seconds=$duration;timestamp_note='Cumulative container duration; not an exact original packet timestamp map.'}
        $offset+=$duration
    }
    Write-Json (Join-Path $out 'VIDEO-MANIFEST.json') @{source_name=[IO.Path]::GetFileName($source);source_sha256=$before;source_size=(Get-Item -LiteralPath $source).Length;tool_version=$version.output;segments=$manifest;reencoded=$false;byte_identical_to_original=$false;event_summary=$P.Summary}
    Write-Text (Join-Path $out 'EVENTS.md') "# Recording events`n`n$($P.Summary)`n`nAdd reviewed timestamps and event descriptions here. No events have been inferred automatically.`n"
    $manifest
}
function Contact-Sheet($C,$P) {
    $exe=Resolve-Tool $C 'ffmpeg'; $source=Full-Path $P.Source; $out=Full-Path $P.Output
    if (Test-Path -LiteralPath $out) { throw 'Contact sheet output already exists.' }
    $interval=[int]$C.video.thumbnail_interval_seconds
    if ($interval -le 0) { throw 'Thumbnail interval must be positive.' }
    [IO.Directory]::CreateDirectory((Split-Path $out)) | Out-Null
    $filter="fps=1/$interval,scale=320:-1,tile=5x4:padding=4:margin=4"
    $r=Run-Tool $C $exe @('-nostdin','-n','-i',$source,'-vf',$filter,'-frames:v','1',$out) 'contact-sheet'
    if (!(Test-Path -LiteralPath $out)) { throw 'ffmpeg did not produce a sheet.' }
    Write-Json "$out.json" @{source=[IO.Path]::GetFileName($source);source_sha256=(File-Hash $source);interval_seconds=$interval;columns=5;rows=4;note='First 20 sampled frames. For longer videos create a sheet per segment; this is not full event analysis.';log=$r.log}
    @{output=$out;sha256=(File-Hash $out)}
}
function Mount-ArchiveDwarfs($C,$P) {
    $null=Verify-DwarfsImage $C (Full-Path $P.Image)
    if (!(Test-Path -LiteralPath $C.tools.winfsp)) { throw 'WinFsp is required only for mounting; install/configure it separately.' }
    # Foreground mount: Ctrl+C unmounts. No driver installation is performed.
    $tool=Resolve-Dwarfs $C 'dwarfs'
    $winfspBin=Join-Path $C.tools.winfsp 'bin'
    if (!(Test-Path -LiteralPath (Join-Path $winfspBin 'winfsp-x64.dll'))) { throw 'WinFsp x64 runtime DLL is missing; check tools.winfsp.' }
    # DwarFS 0.15.7 searches for winfsp-x64.dll. Scope the DLL search path
    # to this foreground mount process; do not edit the machine/user PATH.
    $mountOldPath=$env:PATH
    try {
        $env:PATH=$winfspBin+[IO.Path]::PathSeparator+$mountOldPath
        & $tool.exe @($tool.prefix) (Full-Path $P.Image) $P.MountPoint '-f' '-o' 'readonly'
        $code=$LASTEXITCODE
    } finally { $env:PATH=$mountOldPath }
    if ($code -ne 0) { throw "Mount exited with $code" }
}
