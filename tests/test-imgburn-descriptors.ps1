# Optional image-only integration test. No device destination, no optical write.
[CmdletBinding()]
param([string]$ImgBurn,[string]$WorkRoot,[string]$Output)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/imgburn-descriptors' }
$dir=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$source=Join-Path $dir '合成 source';Write-Text (Join-Path $source '测试 file.txt') 'Synthetic data only; descriptors are checked separately.'
$d=[pscustomobject]@{disc_id='IPA-042';archive_set_id='SYNTHETIC';position=1;disc_count=2;catalog_id='00000000-0000-0000-0000-000000000014';disc_index=42}
$t=Volume-Templates @{} @{VolumeTemplates=@{volume_set='{set_token}_{set_id}';application='BDARCHIVE 1.4.0';publisher='PUBLISHER_METADATA';data_preparer='PREPARER_METADATA';system='SYSTEM_METADATA'}}
$d | Add-Member NoteProperty authoring_metadata (New-VolumeMetadata $t $d)
$project=Write-ImgBurnProject $d $source (Join-Path $dir 'project.ibb');$iso=Join-Path $dir 'test.iso'
$args='/MODE BUILD /BUILDMODE IMAGEFILE /SRC "'+$project+'" /DEST "'+$iso+'" /FILESYSTEM UDF /UDFREVISION 2.50 /ROOTFOLDER YES /NOIMAGEDETAILS /PORTABLE /SETTINGS "'+(Join-Path $dir 'settings.ini')+'" /NOSAVESETTINGS /LOG "'+(Join-Path $dir 'imgburn.log')+'" /START /CLOSE'
$proc=Start-Process -FilePath $ImgBurn -ArgumentList $args -WindowStyle Hidden -PassThru
if (!$proc.WaitForExit(45000)) { throw "Image-only test pending. Log: $dir" }
if ($proc.ExitCode -ne 0) { throw "ImgBurn image build failed with $($proc.ExitCode): $dir" }
# Read ECMA-167 descriptor fields directly; a tool exit code alone proves little.
function DString([byte[]]$Bytes) {
    $length=[int]$Bytes[$Bytes.Length-1]-1;if ($length -lt 0) { return '' }
    if ($Bytes[0] -eq 8) { return [Text.Encoding]::GetEncoding(28591).GetString($Bytes,1,$length) }
    if ($Bytes[0] -eq 16) { return [Text.Encoding]::BigEndianUnicode.GetString($Bytes,1,$length) }
    throw 'Unexpected UDF dstring encoding.'
}
$data=[IO.File]::ReadAllBytes($iso);$pvd=$null;$lvd=$null
for ($block=0;$block -lt [math]::Min(512,$data.Length/2048);$block++) {
    $offset=$block*2048;$tag=[BitConverter]::ToUInt16($data,$offset)
    if ($tag -notin @(1,6) -or [BitConverter]::ToUInt32($data,$offset+12) -ne $block) { continue }
    if ($tag -eq 1 -and !$pvd) { $pvd=$data[$offset..($offset+511)] }
    if ($tag -eq 6 -and !$lvd) { $lvd=$data[$offset..($offset+511)] }
}
if (!$pvd -or !$lvd) { throw 'UDF descriptors missing.' }
$actual=@{udf=(DString $lvd[84..211]);volume_set=(DString $pvd[72..199]);application=([Text.Encoding]::ASCII.GetString($pvd,345,23).TrimEnd([char]0))}
foreach ($key in @('udf','application')) { if ($actual[$key] -cne $d.authoring_metadata.values.$key) { throw "Descriptor mismatch $key : '$($actual[$key])'" } }
if (!$actual.volume_set -or $actual.volume_set -ceq $d.authoring_metadata.values.volume_set) { throw 'Expected backend-generated UDF Volume Set; revisit the capability mapping for this ImgBurn version.' }
if ([BitConverter]::ToUInt16($lvd,240) -ne 0x250) { throw 'Authored UDF revision is not 2.50.' }
$result=@{status='PASS';imgburn_version=(Get-Item -LiteralPath $ImgBurn).VersionInfo.FileVersion;image_sha256=(File-Hash $iso);actual_descriptors=$actual;volume_set_note='Observed backend-generated value, not the requested metadata. Mapping explicitly reflects this.';project_encoding='UTF-16LE BOM';unicode_source_path=$true;physical_burn=$false}
Write-Json (Join-Path $dir 'result.json') $result;if ($Output) { Write-Json (Full-Path $Output) $result };$result | ConvertTo-Json -Depth 5
