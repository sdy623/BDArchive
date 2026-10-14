# Creates a tiny in-memory UDF image. No recorder, writer, blank disc or burn.
[CmdletBinding()]
param([string]$WorkRoot,[string]$Output)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/volume-authoring' }
$dir=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
Write-Text (Join-Path $dir 'index.txt') 'SYNTHETIC UDF label verification, no physical media.'
$d=[pscustomobject]@{disc_id='BD-B-0042';archive_set_id='SYNTHETIC';position=1;disc_count=1;disc_index=42}
$label=Format-VolumeLabel 'BACKUP_{number}_V{volume_index}' $d
$fsi=$null
try {
    $fsi=New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.ChooseImageDefaultsForMediaType(18)
    $fsi.FileSystemsToCreate=4;$fsi.UDFRevision=0x250;$fsi.VolumeName=$label;$fsi.StrictFileSystemCompliance=$true
    $fsi.FreeMediaBlocks=100000;$fsi.Root.AddTree($dir,$false)
    $image=$fsi.CreateResultImage()
    if ($fsi.VolumeNameUDF -cne $label -or $image.TotalBlocks -le 0) { throw 'UDF image label differs from requested label.' }
    $result=@{status='PASS';requested_label=$label;authored_udf_label=$fsi.VolumeNameUDF;udf_revision='2.50';blocks=$image.TotalBlocks;physical_recorder_opened=$false;physical_burn_executed=$false}
    if ($Output) { Write-Json (Full-Path $Output) $result }
    $result | ConvertTo-Json
} finally { if ($fsi) { $null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($fsi) } }
