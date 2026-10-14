param([string]$RequestPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$q=Read-Json $RequestPath;$c=Load-Config $q.config;$leases=@()
function Wait-Signal($Path) {
    $deadline=[DateTime]::UtcNow.AddSeconds(40)
    while (![IO.File]::Exists($Path)) {if ([DateTime]::UtcNow -gt $deadline) {throw 'Fixture signal timed out.'};[Threading.Thread]::Sleep(25)}
}
try {
    switch ($q.mode) {
        'hold' {
            $p=@{};foreach ($prop in $q.parameters.PSObject.Properties) {$p[$prop.Name]=$prop.Value}
            $leases=Enter-ArchiveOperationLocks $c $q.command $p
            Write-Text ($RequestPath+'.ready') 'LOCK_HELD';Wait-Signal ($RequestPath+'.release')
        }
        'legacy' {
            $legacy=[IO.File]::Open((Join-Path $c.archive_root 'archive.lock'),'OpenOrCreate','ReadWrite','None')
            try {Write-Text ($RequestPath+'.ready') 'LEGACY_HELD';Wait-Signal ($RequestPath+'.release')} finally {$legacy.Dispose()}
        }
        'plan' {Wait-Signal $q.start;$null=Invoke-Archive plan @{Config=$q.config;SetId=$q.set_id;Execute=$true;ParPercent=0}}
        'readers' {
            Wait-Signal $q.start
            for ($i=0;$i -lt 300;$i++) {
                $snapshot=Read-Json (Catalog-Path $c)
                if ($snapshot.discs.Count -ne 6 -or @($snapshot.discs.disc_id | Select-Object -Unique).Count -ne 6) {throw 'Reader saw an incomplete catalog snapshot.'}
                [Threading.Thread]::Sleep(1)
            }
        }
        'updates' {
            Wait-Signal $q.start
            $leases=Enter-ArchiveOperationLocks $c 'register' @{DiscId=$q.disc_id}
            for ($i=0;$i -lt 25;$i++) {
                $r=Get-Disc $c $q.disc_id;$r.location=$q.disc_id+'-'+$i;Update-Disc $c $r
                Event $c 'concurrency-fixture' @{disc_id=$q.disc_id;sequence=$i}
            }
            $null=Export-ArchiveIndex $c;Sync-ArchiveCatalog $c
        }
        'summary-pause' {
            & (Get-Module Archive.Core) {
                param($Path)
                $script:summaryBarrier=$Path
                function script:Extract-BackupMetadata($C,$Ingest) {
                    Write-Text ($script:summaryBarrier+'.ready') 'STALE_SNAPSHOT_READ'
                    $deadline=[DateTime]::UtcNow.AddSeconds(30)
                    while (![IO.File]::Exists($script:summaryBarrier+'.release')) {if ([DateTime]::UtcNow -gt $deadline) {throw 'Barrier timed out.'};[Threading.Thread]::Sleep(25)}
                    return $null
                }
            } $RequestPath
            $null=Invoke-Archive summary @{Config=$q.config;SetId=$q.set_id;Execute=$true;RefreshMetadata=$true}
        }
        default {throw 'Unsupported synthetic worker mode.'}
    }
    Write-Json ($RequestPath+'.result.json') @{status='PASS'}
} catch {Write-Json ($RequestPath+'.result.json') @{status='FAIL';error=$_.Exception.Message};exit 1}
finally {Exit-ArchiveOperationLocks $leases}
