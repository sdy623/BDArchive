function Get-MmcDiscInformation($Drive) {
    if (!('ArchiveDiscInformation' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Archive.DiscInformation.cs') }
    [ArchiveDiscInformation]::Read($Drive)
}
function Resolve-DiscFinalization($ImapiState,$Mmc=$null) {
    $result=[ordered]@{finalized=$null;source='UNKNOWN';imapi_state=$ImapiState;mmc_disc_status=$null;mmc_last_session_status=$null;error=$null}
    # 0x8000 means unsupported by this writing interface, not "unfinalized".
    # No flag / null is also unknown. Never cast null into a negative fact.
    if ($null -ne $ImapiState -and ([int]$ImapiState -band 0x4000) -ne 0 -and ([int]$ImapiState -band 0x1400) -eq 0) {
        $result.finalized=$true;$result.source='IMAPI2';return [pscustomobject]$result
    }
    if ($null -ne $Mmc) {
        $result.source='MMC_READ_DISC_INFORMATION';$result.mmc_disc_status=$Mmc.DiscStatus;$result.mmc_last_session_status=$Mmc.LastSessionStatus
        if ($Mmc.DiscStatus -eq 2 -and $Mmc.LastSessionStatus -eq 3) { $result.finalized=$true }
        elseif ($Mmc.DiscStatus -in @(0,1) -or $Mmc.LastSessionStatus -in @(0,1,2)) { $result.finalized=$false }
    }
    [pscustomobject]$result
}
function Read-DiscFinalization($Drive,$Recorder) {
    $format=$null;$state=$null;$imapiError=$null
    try { $format=New-BurnWriter $Recorder;$state=$format.CurrentMediaStatus }
    catch { $imapiError=$_.Exception.Message }
    finally { Release-OpticalCom $format }
    $result=Resolve-DiscFinalization $state
    if ($result.finalized -eq $true) { return $result }
    try { $result=Resolve-DiscFinalization $state (Get-MmcDiscInformation $Drive) }
    catch { $result.error=$_.Exception.Message }
    if ($imapiError) { $result | Add-Member NoteProperty imapi_error $imapiError }
    $result
}
function Get-OpticalReadbackMedia($Drive,$Record,$RecorderId) {
    $root=Full-Path ($Drive.TrimEnd('\','/')+'\')
    $info=New-Object IO.DriveInfo($root)
    if ($info.DriveType -ne [IO.DriveType]::CDRom -or !$info.IsReady) { throw 'Verification root is not ready optical media.' }
    $logical=Get-CimInstance Win32_LogicalDisk | Where-Object DeviceID -eq $Drive.Substring(0,2)
    if (!$logical -or $logical.VolumeName -cne (Disc-Identity $Record).volume_label -or $logical.FileSystem -ne 'UDF') { throw 'Optical volume label or UDF filesystem mismatch.' }
    $rec=$null
    try { $rec=Get-Recorder $Drive $RecorderId;$state=Read-DiscFinalization $Drive $rec }
    finally { Release-OpticalCom $rec }
    @{root=$root;volume_name=$logical.VolumeName;volume_serial=$logical.VolumeSerialNumber;filesystem=$logical.FileSystem;drive_type='CDROM';finalized=$state.finalized;finalization=$state;reloaded_acknowledged=$false}
}
function Repair-VerificationPreflight($C,$P) {
    $r=Get-Disc $C $P.DiscId;$old=$r.verification
    if ($r.status -eq 'BURNED_UNVERIFIED' -and !$old) { return @{status=$r.status;disc_id=$r.disc_id;note='No failed verification to correct.'} }
    if ($r.status -ne 'VERIFY_FAILED' -or !$old -or $old.simulation -or $old.status -ne 'FAIL' -or !$r.burn -or $r.burn.simulation -or $r.burn.result -ne 'WRITTEN') { throw 'This operation only corrects a legacy finalization preflight error on a written disc.' }
    if ((File-Hash $old.report) -cne $old.report_sha256) { throw 'Old verification report changed.' }
    $failure=Read-Json $old.report
    if ($failure.error -cne 'Media is not reported finalized. Do not delete originals.' -or $failure.root -or $failure.media -or $failure.disc_id -cne $r.disc_id -or $failure.manifest_sha256 -cne $r.hash) { throw 'This was not the known preflight-only error; content failures cannot be cleared.' }
    $media=Get-OpticalReadbackMedia $P.Drive $r $P.RecorderId
    if ($media.finalized -ne $true) { throw 'The inserted disc is not confirmed finalized.' }
    if ((File-Hash (Join-Path $media.root 'SHA256SUMS')) -cne $r.stage.hash -or (File-Hash (Join-Path $media.root 'DISC.json')) -cne $r.stage.disc_json_hash) { throw 'Inserted disc identity does not match the sealed record.' }
    $path=Join-Path $C.archive_root ('reports/'+$r.disc_id+'-corrected-preflight-'+[guid]::NewGuid().ToString('N')+'.json')
    $diagnostic=@{schema_version=1;disc_id=$r.disc_id;time=[DateTime]::UtcNow.ToString('o');status='NOT_RUN';phase='MEDIA_PREFLIGHT';scope='MEDIA_PREFLIGHT_ONLY';simulation=$false;media=$media;manifest_sha256=$r.hash;original_report=$old.report;original_report_sha256=$old.report_sha256;note='Corrected legacy IMAPI unsupported-state interpretation. No payload readback performed.'}
    Write-Json $path $diagnostic
    $history=@(Optional-Field $r 'verification_history' | Where-Object {$null -ne $_})+@($old)
    $r | Add-Member NoteProperty verification_history $history -Force
    $r.verification=$null;$r.status='BURNED_UNVERIFIED'
    $r | Add-Member NoteProperty last_verification_attempt ([pscustomobject]@{status='NOT_RUN';phase='MEDIA_PREFLIGHT';simulation=$false;report=$path;report_sha256=(File-Hash $path);manifest_sha256=$r.hash;time=$diagnostic.time;media=$media}) -Force
    Update-Disc $C $r;Event $C 'correct-finalization-preflight-error' @{disc_id=$r.disc_id;old_report=$old.report;diagnostic=$path}
    @{disc_id=$r.disc_id;status=$r.status;finalized=$media.finalized;content_verification='NOT_RUN';old_report_preserved=$true;report=$path}
}
