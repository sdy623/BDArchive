<#
.SYNOPSIS
BD Archive Toolkit. Default: DRY_RUN. Use -Execute for local work.
.EXAMPLE
.\archive-agent.ps1 -Command scan -SetId PHOTO-2026 -Category I -Source "D:\Cold Data" -Execute
.EXAMPLE
.\archive-agent.ps1 -Command burn -DiscId BD-P-0001 -Simulate -Execute
.NOTES
See README.md and OPERATIONS.md. No physical burn or source deletion by default.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$Config,
    [ValidateSet('import-stage','init','scan','plan','build','stage','burn','verify','register','restore','catalog','verify-dwarfs','split-video','contact-sheet','par2','mount','delete-source','summary','prepare','ids','set-counter','export-index','delete-disc-record','restore-disc-record','rename-disc','rename-set','repair-identity-change','recover-burn','devices','repair-verify')]
    [string]$Command = 'scan',
    [string]$SetId, [string]$DiscId, [string]$NewDiscId, [string]$NewSetId,
    [string]$StartDiscId,[hashtable]$VolumeTemplates,[string]$VolumeLabelTemplate,[ValidateSet('P','G','B','M')][string]$Prefix,[Nullable[int64]]$NextNumber,[string]$Reason,
    [ValidateSet('I','II','III','M')][string]$Category='I',
    [string]$Source, [string]$Output, [string]$Image, [string]$MountPoint,
    [ValidateSet('BD25','BD50')][string]$Media,
    [Nullable[double]]$ParPercent, [double]$TargetGiB,
    [string[]]$MediaRoots, [string]$Drive, [string]$RecorderId, [string]$Location, [string]$Summary='',
    [string]$Device, [string]$SecondCopy, [string]$PasswordStorage, [string]$DiscSetLabel,
    [switch]$RefreshMetadata,
    [ValidateSet('photo','game','backup','core')][string]$Scenario,
    [ValidateSet('A','B','C')][string]$PhotoTier='C',
    [string]$DateRange, [string]$Camera, [string]$Tags, [string]$Game,
    [ValidateSet('existing_highest_quality','encoded_copy_is_master','original_capture')][string]$MasterStatus='existing_highest_quality',
    [ValidateSet('UNKNOWN','KEPT','DELETED')][string]$EarlierOriginalStatus='UNKNOWN',
    [ValidateSet('Console','Dialog')][string]$ConfirmationMode='Console',
    [ValidateSet('IMAPI2','ImgBurn')][string]$Backend,
    [switch]$DetectDuplicates, [switch]$Deduplicate, [switch]$Execute,
    [switch]$DryRun, [switch]$Simulate, [switch]$BurnConfirmed,
    [switch]$MediaReloaded, [switch]$DeepVerifyDwarfs, [switch]$DeleteSourceConfirmed
)
$ErrorActionPreference='Stop'
if (!$Config) { $Config=Join-Path $PSScriptRoot '../archive.config.json' }
Import-Module (Join-Path $PSScriptRoot 'Archive.Core.psm1') -Force -DisableNameChecking
$parameters=@{}
foreach ($key in @('Config','SetId','DiscId','NewDiscId','NewSetId','Category','Source','Output','Image','MountPoint',
    'Media','ParPercent','TargetGiB','MediaRoots','Drive','RecorderId','Location','Summary','Backend',
    'DetectDuplicates','Deduplicate','Execute','DryRun','Simulate','BurnConfirmed',
    'MediaReloaded','DeepVerifyDwarfs','DeleteSourceConfirmed','Device','SecondCopy','PasswordStorage','DiscSetLabel',
    'RefreshMetadata','Scenario','PhotoTier','DateRange','Camera','Tags','Game','MasterStatus','EarlierOriginalStatus','ConfirmationMode','StartDiscId','VolumeTemplates','VolumeLabelTemplate','Prefix','NextNumber','Reason')) { $parameters[$key]=(Get-Variable -Name $key -ValueOnly) }
try { Invoke-Archive -Command 'scan' -Parameters $parameters -WhatIf:$WhatIfPreference }
catch { Write-Error $_; exit 1 }
