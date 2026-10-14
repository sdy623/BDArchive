function Optional-Field($Object,$Name) {
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}
function Summary-Value($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'UNKNOWN / not recorded' }
    # Single-line field rendering prevents multiline annotations from looking
    # like trusted fields or verification results in a printed summary.
    ([string]$Value -replace '[\r\n\t]+',' ').Trim()
}
function Backup-MetadataRoots($Ingest) {
    # Locate backup roots from the immutable inventory, including wrapper
    # directories. A random payload named Manifest.db is not enough.
    $names=@{};foreach ($f in $Ingest.files) { $names[$f.path]=$true }
    foreach ($f in $Ingest.files) {
        if ([IO.Path]::GetFileName($f.path) -notin @('Manifest.db','Manifest.mbdb')) { continue }
        $prefix=$f.path.Substring(0,$f.path.Length-[IO.Path]::GetFileName($f.path).Length)
        if ($names.ContainsKey($prefix+'Info.plist') -and $names.ContainsKey($prefix+'Manifest.plist')) { $prefix }
    }
}
function Extract-BackupMetadata($C,$Ingest) {
    $roots=@(Backup-MetadataRoots $Ingest | Select-Object -Unique)
    if ($roots.Count -gt 1) { return $null } # Never label multiple devices as one.
    $prefix=if ($roots.Count) { [string]$roots[0] } else { '' }
    $candidates=@($Ingest.files | Where-Object { $_.path -in @(($prefix+'Info.plist'),($prefix+'Manifest.plist'),($prefix+'Status.plist')) })
    if ($Ingest.category -ne 'III' -or !$candidates.Count) { return $null }
    try {
        foreach ($f in $candidates) {
            if ((File-Hash (Safe-Join $Ingest.source_root $f.path)) -ne $f.sha256) { throw 'Metadata differs from the ingest snapshot.' }
        }
        $python=Resolve-Tool $C 'python'
        $metadataRoot=if ($prefix) { Safe-Join $Ingest.source_root $prefix.TrimEnd('/') } else { $Ingest.source_root }
        $r=Run-Tool $C $python @((Join-Path $PSScriptRoot '../catalog/iphone_metadata.py'),'--source',$metadataRoot) 'iphone-metadata'
        $meta=ConvertFrom-Json $r.output
        # Bind the parser's actual bytes to the immutable ingest hash as well.
        foreach ($f in $meta.metadata_files) {
            $f.file=$prefix+$f.file
            $expected=@($candidates | Where-Object path -eq $f.file)
            if ($expected.Count -ne 1 -or $expected[0].sha256 -ne $f.sha256) { throw 'Parsed metadata differs from ingest.' }
        }
        return $meta
    } catch {
        if (Is-PreparationCancellation $_) { throw }
        # Summary enrichment cannot turn a valid file archive into a false
        # failed ingest; retain explicit unknowns, no filesystem-date guesses.
        return [pscustomobject]@{kind='iphone_backup';device=$null;product_type=$null;backup_date=$null;encrypted=$null;ios=$null;backup_folder_id='***';provenance=@{};metadata_files=@();warnings=@('Automatic metadata extraction unavailable; configure Python and use -RefreshMetadata. See archive logs.')}
    }
}
function Export-ArchiveSummary($C,$P) {
    $id=$P.SetId;Assert-Id $id
    $dir=Set-Dir $C $id;$ing=Load-Ingest $C $id
    $cat=Read-Json (Catalog-Path $C);$set=@($cat.sets | Where-Object archive_set_id -eq $id)[0]
    if ((File-Hash (Join-Path $dir 'ingest.json')) -ne $set.ingest_sha256) { throw 'Cannot summarize an altered ingest manifest.' }
    $meta=Optional-Field $set 'backup_metadata'
    if (($null -eq $meta -or $P.RefreshMetadata) -and !(Optional-Field $P 'NoSourceRead')) {
        $fresh=Extract-BackupMetadata $C $ing
        if ($meta -and $P.RefreshMetadata -and (!$fresh -or !$fresh.metadata_files.Count)) { throw 'Cannot validate source metadata for refresh; previously saved summary is unchanged.' }
        $meta=$fresh
        $set | Add-Member -MemberType NoteProperty -Name backup_metadata -Value $meta -Force
    }
    $annotations=Optional-Field $set 'summary_annotations'
    if (!$annotations) { $annotations=[pscustomobject]@{device=$null;second_copy=$null;password_storage=$null;disc_set_label=$null} }
    foreach ($pair in @(@('Device','device'),@('SecondCopy','second_copy'),@('PasswordStorage','password_storage'),@('DiscSetLabel','disc_set_label'))) {
        if ($P[$pair[0]]) { $annotations.($pair[1])=Summary-Value $P[$pair[0]] }
    }
    $set | Add-Member -MemberType NoteProperty -Name summary_annotations -Value $annotations -Force
    $discs=@($cat.discs | Where-Object archive_set_id -eq $id | Sort-Object position)
    $device=Optional-Field $meta 'device';$deviceSource='metadata'
    if ($annotations.device) { $device=$annotations.device;$deviceSource='user supplied' }
    $encrypted=Optional-Field $meta 'encrypted'
    $encryptionText='UNKNOWN';if ($null -ne $encrypted) { if ($encrypted) { $encryptionText='YES' } else { $encryptionText='NO' } }
    $date=Optional-Field $meta 'backup_date';$ios=Optional-Field $meta 'ios'
    # PowerShell 7 may deserialize ISO JSON dates into DateTime automatically;
    # keep the printable date independent of the Windows locale.
    if ($date -is [DateTime]) { $date=$date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture) }
    $folder=Optional-Field $meta 'backup_folder_id'
    $details=[pscustomobject]@{device=$device;device_source=$deviceSource;backup_date=$date;encrypted=$encryptionText;ios=$ios;backup_folder_id=$folder;disc_set_label=$annotations.disc_set_label;second_copy=$annotations.second_copy;password_storage=$annotations.password_storage}
    $scene=Scene-Details $ing
    if ($scene) {
        $details=$scene
        $details | Add-Member NoteProperty disc_set_label $annotations.disc_set_label
        $details | Add-Member NoteProperty second_copy $annotations.second_copy
    } elseif ($null -eq $meta -and !$annotations.device) {
        $details=[pscustomobject]@{scenario=(Optional-Field (Optional-Field $ing 'profile') 'scenario');disc_set_label=$annotations.disc_set_label;second_copy=$annotations.second_copy}
    }
    $set | Add-Member -MemberType NoteProperty -Name summary_details -Value $details -Force
    Update-ArchiveSet $C $set
    $data=[ordered]@{schema_version=1;archive_set_id=$id;category=$ing.category;summary=$set.summary;file_count=$ing.file_count;total_bytes=$ing.total_bytes;details=$details;metadata=$meta;original_deleted=$set.original_deleted;snapshot_utc=[DateTime]::UtcNow.ToString('o');disc_set=@($discs | Select-Object disc_id,disc_index,volume_id,volume_label,position,disc_count,media_type,status,location,catalog_deleted,authoring_metadata);annotation_note='Second copy and password storage are user notes, not verification of another copy or access to a password.'}
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("Archive ID: $id")
    if ($ing.category -eq 'III' -and ($null -ne $meta -or $annotations.device)) {
        $lines.Add("Device: $(Summary-Value $device)")
        $lines.Add("Backup date: $(Summary-Value $date)")
        $lines.Add("Encrypted: $encryptionText")
        $lines.Add("iOS: $(Summary-Value $ios)")
        $lines.Add('Backup folder ID: ***')
    }
    if ($scene) {
        foreach ($field in $scene.PSObject.Properties) { $lines.Add("$($field.Name): $(Summary-Value $field.Value)") }
    }
    $lines.Add("Summary: $(Summary-Value $set.summary)")
    $lines.Add('Disc set:')
    if ($annotations.disc_set_label) { $lines.Add("  $($annotations.disc_set_label) (label)") }
    if (!$discs.Count) { $lines.Add('  Not planned') }
    foreach ($d in $discs) {
        $identity=Disc-Identity $d
        $deletedNote=if (Optional-Field $d 'catalog_deleted') {'; RECORD DELETED / 已从目录删除'} else {''}
        $lines.Add("  $($d.disc_id) [$($d.position)/$($d.disc_count); $($d.status)$deletedNote]")
        $lines.Add("    Volume ID: $($identity.volume_id) | Label: $($identity.volume_label) | Catalog index: $(Summary-Value $identity.disc_index)")
    }
    $lines.Add('');$lines.Add('Second copy:');$lines.Add("  $(Summary-Value $annotations.second_copy)")
    if ($ing.category -eq 'III' -and ($meta -or $annotations.device -or $annotations.password_storage)) {
    $lines.Add('');$lines.Add('Encryption password:')
    $pw='UNKNOWN / storage location not recorded'
    if ($annotations.password_storage) { $pw='stored in '+$annotations.password_storage }
    $lines.Add("  $pw")
    }
    $lines.Add('');$lines.Add("Category: $($ing.category)");$lines.Add("Files: $($ing.file_count)")
    $lines.Add("Size: $($ing.total_bytes) bytes")
    $lines.Add("Original deleted: $($set.original_deleted)")
    $lines.Add("Summary snapshot (UTC): $($data.snapshot_utc)")
    if ($ing.category -eq 'III') { $lines.Add('Notes: Second copy/password storage are user-supplied references. No password is stored by this feature.') }
    else { $lines.Add('Notes: Second copy is a user-supplied reference, not a verification result.') }
    Export-PhotoCatalog $C $ing (Join-Path $dir 'PHOTO-CATALOG.csv') $null
    $txt=Join-Path $dir 'ARCHIVE-SUMMARY.txt';$json=Join-Path $dir 'ARCHIVE-SUMMARY.json'
    Write-Text $txt (($lines.ToArray() -join "`r`n")+"`r`n");Write-Json $json $data
    @{archive_set_id=$id;txt=$txt;json=$json;device=$device;encrypted=$encryptionText}
}
