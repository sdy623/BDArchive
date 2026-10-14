# Only preparation payloads call this helper. Restore/simulation always Copy-Checked.
function Stage-Payload($Source,$Target,$Expected,[switch]$SealWillVerify) {
    # Fast DwarFS staging defers hash checks to mandatory Seal-Stage.
    # Never use this switch for a standalone copy or a restore.
    Assert-PreparationRunning;Assert-NoLinks $Source;Assert-NoLinks $Target
    if (!$SealWillVerify -and (File-Hash $Source) -ne $Expected) { throw "Source changed: $Source" }
    if (Test-Path -LiteralPath $Target) { throw "Payload destination already exists: $Target" }
    if (!('ArchiveFileLinks' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Archive.FileLinks.cs') }
    $parent=Split-Path (Full-Path $Target)
    while (!(Test-Path -LiteralPath $parent)) { $parent=Split-Path $parent }
    $sourceVolume=[ArchiveFileLinks]::Volume((Full-Path $Source));$targetVolume=[ArchiveFileLinks]::Volume($parent)
    $mode='COPY'
    if ($sourceVolume -eq $targetVolume) {
        Set-PreparationProgress "同卷免复制：$([IO.Path]::GetFileName($Source))" '' -Force
        [IO.Directory]::CreateDirectory((Split-Path $Target)) | Out-Null
        Assert-PreparationRunning
        # A hard link shares data and attributes. Never set timestamps/read-only
        # flags or write through this target; that would change the original.
        try { [ArchiveFileLinks]::Create((Full-Path $Source),(Full-Path $Target)) }
        catch { throw "Same-volume hard link failed; no fallback copy was made. Use a local volume supporting hard links. $($_.Exception.Message)" }
        if ([ArchiveFileLinks]::Identity((Full-Path $Source)) -ne [ArchiveFileLinks]::Identity((Full-Path $Target))) { throw 'Hard-link identity verification failed.' }
        if (!$SealWillVerify -and (File-Hash $Target) -ne $Expected) { throw "Source changed while linking: $Source" }
        $mode='HARDLINK'
    } else { Copy-Checked $Source $Target $Expected }
    @{mode=$mode;bytes=[int64](Get-Item -LiteralPath $Target -Force).Length}
}

function Open-StageReadGuards($Root) {
    $handles=New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($f in (Tree-Files $Root)) {
            # Lock the underlying file, including all its hard-link names, against
            # writes/deletion until authoring returns. Existing writers reject us.
            $handles.Add([IO.File]::Open($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
        }
        [pscustomobject]@{handles=$handles.ToArray()}
    } catch { foreach ($handle in $handles) { $handle.Dispose() };throw }
}
function Close-StageReadGuards($Guards) { if ($Guards) { foreach ($handle in $Guards.handles) { $handle.Dispose() } } }
function Assert-StageReadGuardMembership($Root,$Guards) {
    # Existing bytes/names remain locked. Re-enumeration catches additions
    # during the user's review without hashing the payload a second time.
    $expected=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($handle in $Guards.handles) { $null=$expected.Add((Full-Path $handle.Name)) }
    foreach ($file in (Tree-Files $Root)) { if (!$expected.Remove((Full-Path $file.FullName))) { throw 'Staging file list changed during confirmation; review the staging directory before retrying.' } }
    if ($expected.Count) { throw 'A guarded staging file disappeared.' }
}
