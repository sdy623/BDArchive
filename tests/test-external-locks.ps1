param([Parameter(Mandatory=$true)][string]$Fixture)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$f=Read-Json (Full-Path $Fixture);$c=Load-Config $f.config;$q=(Full-Path $Fixture)+'.'+[guid]::NewGuid().ToString('N')+'.lock-test.json'
Write-Json $q @{config=$f.config;mode='hold';command='import-stage';parameters=@{DiscId=$f.disc_id;Source=$f.root}}
$p=New-Object Diagnostics.Process
$p.StartInfo=New-ArchiveWorkerStartInfo (Get-Process -Id $PID).Path (Full-Path (Join-Path $PSScriptRoot 'concurrency-worker.ps1')) $q $false
$null=$p.Start()
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while (![IO.File]::Exists($q+'.ready')) {if ($p.HasExited -or [DateTime]::UtcNow -gt $deadline) {throw 'Import lock worker failed.'};[Threading.Thread]::Sleep(25)}
    $set=(Get-Disc $c $f.disc_id).archive_set_id
    foreach ($test in @(@{command='prepare';parameters=@{SetId=$set}},@{command='contact-sheet';parameters=@{Output=$f.root}})) {
        $leases=@();$blocked=$false
        try {$leases=Enter-ArchiveOperationLocks $c $test.command $test.parameters} catch {$blocked=$_.Exception.Message -match '资源正在使用'} finally {Exit-ArchiveOperationLocks $leases}
        if (!$blocked) {throw 'Expected same-set or same-output lock rejection.'}
    }
    $leases=Enter-ArchiveOperationLocks $c prepare @{SetId='OTHER-SET'};Exit-ArchiveOperationLocks $leases
} finally {Write-Text ($q+'.release') 'release';$null=$p.WaitForExit(10000);$p.Dispose()}
if ((Read-Json ($q+'.result.json')).status -ne 'PASS') {throw 'Lock helper failed.'}
# The old index-only resume fails before looking at its immutable settings.
$blocked=$false
try {Invoke-Archive prepare @{Config=$f.config;Execute=$true;SetId='MISSING-OLD';Source=(Join-Path $f.root '00_DISC_CATALOG');Scenario='photo';PhotoTier='C'}} catch {$blocked=$_.Exception.Message -match '索引子目录'}
if (!$blocked) {throw 'Old metadata-only resume was not blocked.'}
$unused=@('Z','Y','X','W','V','U','T' | Where-Object {![IO.Directory]::Exists($_+':\')})[0]
$missing=$unused+':\offline\00_DISC_CATALOG'
$blocked=$false
try {Assert-PhotoSourceRoot $missing ([pscustomobject]@{category='I';files=@(@{path='DISC-INFO.json'},@{path='CONTENTS.csv'})})} catch {$blocked=$_.Exception.Message -match '索引子目录'}
if (!$blocked) {throw 'Offline metadata-only evidence was not blocked.'}
Write-Json ((Full-Path $Fixture)+'.lockchecks.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();same_set_exclusive='PASS';same_output_exclusive='PASS';other_set_parallel='PASS';old_metadata_only_resume_blocked='PASS';offline_metadata_only_blocked='PASS';optical_access=$false}
Write-Host 'PASS external output/set locks and old resume guard.'
