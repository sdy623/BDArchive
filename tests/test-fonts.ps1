[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'scripts/Archive.Fonts.ps1')
Initialize-ArchiveFonts
foreach($role in @('Ui','Display','Mono')) {
 $f=New-ArchiveFont -Role $role -Size 12 -Language en
 try {
  $expected=@{Ui='IBM Plex Sans';Display='Barlow Condensed';Mono='IBM Plex Mono'}[$role]
  if($f.FontFamily.Name -cne $expected){throw "Font fallback instead of bundled $role : $($f.FontFamily.Name)"}
  Write-Output "PASS $role : $($f.FontFamily.Name)"
 } finally {$f.Dispose()}
}
$cn=New-ArchiveFont -Role Ui -Size 10 -Language zh-CN
try {if($cn.FontFamily.Name -ne 'Microsoft YaHei UI'){throw 'Chinese font fallback is not the explicit CJK UI family'};Write-Output 'PASS CJK fallback'} finally {$cn.Dispose()}
Initialize-ArchiveFonts
Write-Output 'PASS idempotent process-local loading; no font installation'
