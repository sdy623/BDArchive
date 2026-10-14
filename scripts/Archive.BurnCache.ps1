# A recent seal is a reuse policy, not a new readback or proof against bit rot.
function Convert-ArchiveUtcTime($Value) {
    # PS 7.5+ JSON dates can already be DateTime; reparsing loses the UTC Kind.
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    [DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Get-StageStamps($Root) {
    if (!('ArchiveFileLinks' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Archive.FileLinks.cs') }
    @(Tree-Files $Root | Sort-Object FullName | ForEach-Object {
        $stamp=[ArchiveFileLinks]::Stamp($_.FullName)
        [pscustomobject]@{path=(Relative-Path $Root $_.FullName);bytes=$stamp.Bytes;mtime=$stamp.MtimeTicks.ToString()}
    })
}
function New-StageReceipt($Stage,$Stamps,[string]$Basis='SEALED_HASHES',[DateTime]$Time=[DateTime]::UtcNow) {
    [pscustomobject]@{version=1;time=$Time.ToUniversalTime().ToString('o');basis=$Basis;manifest_sha256=$Stage.hash;disc_json_sha256=$Stage.disc_json_hash;files=@($Stamps)}
}
function Test-RecentStage($Record,[DateTime]$Now=[DateTime]::UtcNow) {
    $s=$Record.stage;$receipt=Optional-Field $s 'receipt'
    $time=if ($receipt) { Convert-ArchiveUtcTime $receipt.time } else { Convert-ArchiveUtcTime $s.time }
    if ($Now -lt $time -or ($Now-$time).TotalDays -gt 7) { return @{reuse=$false;reason='封包校验已超过 7 天或时间无效'} }
    if ($Record.hash -cne $s.hash) { throw 'Catalog and staging seal disagree.' }
    # Only these small authoritative records are hashed; payloads are not read.
    if ((File-Hash (Join-Path $s.path 'SHA256SUMS')) -cne $s.hash -or (File-Hash (Join-Path $s.path 'DISC.json')) -cne $s.disc_json_hash) { throw 'Final output records changed; recreate the staging directory.' }
    foreach($ref in @(Optional-Field $s 'reference_manifests')) { if($ref -and (File-Hash (Safe-Join $s.path $ref.path)) -cne $ref.sha256){throw 'Reference manifest changed'} }
    $current=@(Get-StageStamps $s.path)
    if ($receipt) {
        if ($receipt.version -ne 1 -or $receipt.manifest_sha256 -cne $s.hash -or $receipt.disc_json_sha256 -cne $s.disc_json_hash) { return @{reuse=$false;reason='封存凭据不匹配'} }
        $previous=@{};foreach ($f in $receipt.files) { if ($previous.ContainsKey($f.path)) { throw 'Duplicate receipt path.' };$previous[$f.path]=$f }
        if ($previous.Count -ne $current.Count) { return @{reuse=$false;reason='文件数量变化'} }
        foreach ($f in $current) {
            if (!$previous.ContainsKey($f.path) -or $previous[$f.path].bytes -ne $f.bytes -or $previous[$f.path].mtime -cne $f.mtime) { return @{reuse=$false;reason="文件大小或修改时间变化：$($f.path)"} }
        }
        return @{reuse=$true;basis=$receipt.basis;time=$receipt.time;receipt=$receipt}
    }
    # Upgrade old seals without reading tens of GB again. This is explicitly a
    # metadata-only migration: no historic per-file mtime snapshot exists.
    # Require an intact manifest, exact membership/total size, and every file
    # last written no later than the original seal. Preserve that expiry time.
    $expected=@{'SHA256SUMS'=$true};$bytes=[int64]0
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $s.path 'SHA256SUMS'),$script:Utf8)) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$' -or $expected.ContainsKey($Matches[2])) { throw 'Invalid sealed checksum manifest.' }
        $expected[$Matches[2]]=$true
    }
    if ($expected.Count -ne $current.Count) { return @{reuse=$false;reason='旧封包文件数量变化'} }
    foreach ($f in $current) {
        if (!$expected.ContainsKey($f.path) -or [int64]$f.mtime -gt $time.Ticks) { return @{reuse=$false;reason='旧封包文件有后续修改'} }
        $bytes+=$f.bytes
    }
    if ($bytes -ne $s.bytes) { return @{reuse=$false;reason='旧封包总大小变化'} }
    $receipt=New-StageReceipt $s $current 'LEGACY_METADATA_REUSE' $time
    @{reuse=$true;basis=$receipt.basis;time=$receipt.time;receipt=$receipt}
}
function Confirm-StageForBurn($C,$Record) {
    $check=Test-RecentStage $Record
    if ($check.reuse) {
        Write-Host '复用 7 天内封包校验：仅检查文件列表、大小、修改时间和最终记录；不重读 payload。'
        if ($check.basis -eq 'LEGACY_METADATA_REUSE') { Write-Host '旧版封包采用元数据兼容复用，未重新执行内容校验。' }
        $receipt=$check.receipt
    } else {
        Write-Host "需要重新校验：$($check.reason)；正在读取 SHA-256 / DwarFS integrity。"
        $null=Check-DiscTree $C $Record.stage.path $Record -Integrity
        $receipt=New-StageReceipt $Record.stage @(Get-StageStamps $Record.stage.path) 'FULL_RECHECK'
    }
    $Record.stage | Add-Member NoteProperty receipt $receipt -Force
    Update-Disc $C $Record
    @{reused=[bool]$check.reuse;basis=$receipt.basis;checked_at=$receipt.time;optical_readback=$false}
}
