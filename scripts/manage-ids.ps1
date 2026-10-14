<# Read-only counters by default. set-counter/export-index require -Execute.
Examples:
  .\manage-ids.ps1
  .\manage-ids.ps1 -Command set-counter -Prefix B -NextNumber 13
  .\manage-ids.ps1 -Command set-counter -Prefix B -NextNumber 13 -Execute
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$Config,[ValidateSet('ids','set-counter','export-index','init','delete-disc-record','restore-disc-record','delete-orphan-set','discard-unburned-plan','rename-disc','rename-set','repair-identity-change')][string]$Command='ids',
    [ValidateSet('P','G','B','M')][string]$Prefix,[Nullable[int64]]$NextNumber,[string]$Reason,[string]$DiscId,[string]$NewDiscId,[string]$SetId,[string]$NewSetId,
    [switch]$Execute,[switch]$DryRun,[switch]$AllowCounterRollback)
$ErrorActionPreference='Stop'
if (!$Config) { $Config=Join-Path $PSScriptRoot '../archive.config.json' }
Import-Module (Join-Path $PSScriptRoot 'Archive.Core.psm1') -Force -DisableNameChecking
try {
    $p=@{Config=$Config;DiscId=$DiscId;NewDiscId=$NewDiscId;SetId=$SetId;NewSetId=$NewSetId;Prefix=$Prefix;NextNumber=$NextNumber;Reason=$Reason;Execute=$Execute;DryRun=$DryRun;AllowCounterRollback=$AllowCounterRollback}
    Invoke-Archive $Command $p -WhatIf:$WhatIfPreference | ConvertTo-Json -Depth 12
} catch { Write-Error $_;exit 1 }
