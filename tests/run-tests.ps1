[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/tests'),[string]$Python,[string]$DwarfsBin,[switch]$LiveDwarfs)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($run) | Out-Null
$script:results=New-Object 'System.Collections.Generic.List[object]'
function Assert($Condition,$Message='Assertion failed') { if (!$Condition) { throw $Message } }
function Reject([scriptblock]$Body,$Pattern='.*') {
    $failed=$false
    try { & $Body | Out-Null } catch { $failed=$true; if ($_.Exception.Message -notmatch $Pattern) { throw "Wrong rejection: $($_.Exception.Message)" } }
    Assert $failed 'Expected rejection, operation unexpectedly succeeded'
}
function Case($Name,[scriptblock]$Body) {
    try { & $Body; $script:results.Add(@{name=$Name;status='PASS'}); Write-Host "PASS $Name" }
    catch { $script:results.Add(@{name=$Name;status='FAIL';error=$_.Exception.Message}); Write-Host "FAIL $Name : $_"; throw }
}
$config=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.json'))
$config.dwarfs.build_profile='verified';$config.dwarfs.skip_roundtrip=$false
$config.archive_root=Join-Path $run 'archive';$config.catalog_path=Join-Path $run 'catalog.sqlite';$config.tools.python=$Python
$config.media.BD25.capacity_bytes=12MB;$config.media.BD25.payload_gib=0.002;$config.media.BD25.dwarfs_payload_gib=0.002
$config.planning.reserve_mib=1;$config.planning.dwarfs_overhead_mib=0.1;$config.planning.per_file_overhead_bytes=128
if ($DwarfsBin) { $config.tools.dwarfs_bin=$DwarfsBin }
$configPath=Join-Path $run 'test.config.json';Write-Json $configPath $config
function Run-ArchiveTest($Command,$Extra=@{}) {
    $p=@{Config=$configPath;Execute=$true;Category='I';Summary='Synthetic test fixture'}
    foreach ($key in $Extra.Keys) { $p[$key]=$Extra[$key] }
    Invoke-Archive -Command $Command -Parameters $p
}
try {
    Case 'dry-run creates no archive or tool log' {
        $null=Invoke-Archive -Command init -Parameters @{Config=$configPath}
        Assert (!(Test-Path -LiteralPath $config.archive_root))
        $null=Invoke-Archive -Command init -Parameters @{Config=$configPath;Execute=$true} -WhatIf
        Assert (!(Test-Path -LiteralPath $config.archive_root))
    }
    Case 'capacity arithmetic reserves PAR2 and image overhead' {
        $real=Load-Config (Join-Path $PSScriptRoot '../archive.config.json')
        $b=Disc-Budget $real 'BD25' 5 'III'
        Assert ($b.input_limit_bytes -lt $b.payload_limit_bytes)
        Assert ($b.payload_limit_bytes*1.05+$b.reserve_bytes -le $b.capacity_bytes)
        $dl=Disc-Budget $real 'BD50' 5 'III'
        Assert ($dl.payload_limit_bytes -ge 43GB -and $dl.payload_limit_bytes -le 45GB)
        Reject { Disc-Budget $real 'BD25' -1 'I' } 'percent'
    }
    Case 'monotonic global disc IDs including 10000' {
        $c=[pscustomobject]@{sequences=[pscustomobject]@{P=9998;G=0;B=0;M=0}}
        Assert ((Next-DiscId $c P) -eq 'BD-P-9999');Assert ((Next-DiscId $c P) -eq 'BD-P-10000')
        Assert ((Next-DiscId $c B) -eq 'BD-B-0001')
    }
    Case 'directory packing, exact boundary, oversize fail' {
        $f=@([pscustomobject]@{path='a/1';size=4},[pscustomobject]@{path='a/2';size=4},[pscustomobject]@{path='b/1';size=7})
        $bins=@(Pack-Files $f 10 1);Assert ($bins.Count -eq 2)
        Assert (@($bins[0].files).Count -eq 2)
        Reject { Pack-Files @([pscustomobject]@{path='big';size=11}) 10 } 'Oversize'
    }
    Case 'reject traversal and absolute manifest paths' {
        Reject { Safe-Join $run '../escape' } 'Unsafe'
        Reject { Safe-Join $run 'C:/escape' } 'Unsafe'
        Reject { Safe-Join $run 'data/file:stream' } 'Unsafe'
        Reject { Assert-Separate $run (Join-Path $run 'child') } 'overlap'
    }
    Case 'DwarFS universal and standalone dispatch modes' {
        $alternate=Read-Json $configPath
        $alternate.tools.dwarfs_bin=''; $alternate.tools.dwarfs='C:/Tools/dwarfs-universal.exe'
        # Resolve the configured universal form without executing it.
        $alternate.tools.dwarfs=(Get-Command powershell.exe).Source
        $tool=Resolve-Dwarfs $alternate 'dwarfsck'
        Assert ($tool.prefix[0] -eq '--tool=dwarfsck')
        if ($DwarfsBin) { $tool=Resolve-Dwarfs $config 'mkdwarfs';Assert (@($tool.prefix).Count -eq 0) }
    }
    Case 'alternate streams are rejected without deleting them' {
        $streamFile=Join-Path $run 'stream-fixture.txt';Write-Text $streamFile 'main data'
        Set-Content -LiteralPath $streamFile -Stream 'archive-test-stream' -Value 'important extra data'
        Reject { Assert-PlainFile $streamFile } 'Alternate data stream'
        Assert ((Get-Content -LiteralPath $streamFile -Stream 'archive-test-stream') -eq 'important extra data')
    }
    $source=Join-Path $run 'source unicode 空格';[IO.Directory]::CreateDirectory((Join-Path $source 'RAW 子目录')) | Out-Null
    $rng=New-Object Random(53)
    foreach ($i in 1..4) { $bytes=New-Object byte[] (700KB);$rng.NextBytes($bytes);[IO.File]::WriteAllBytes((Join-Path $source "RAW 子目录/$i.raw"),$bytes) }
    [IO.File]::Copy((Join-Path $source 'RAW 子目录/1.raw'),(Join-Path $source 'duplicate.raw'))
    [IO.Directory]::CreateDirectory((Join-Path $source 'empty 空目录')) | Out-Null
    Write-Text (Join-Path $source 'zero.txt') ''
    [IO.File]::SetAttributes((Join-Path $source 'zero.txt'),[IO.FileAttributes]::Hidden)
    Case 'ingest hashes hidden/Unicode files and byte-checks duplicates' {
        $null=Run-ArchiveTest init
        $null=Run-ArchiveTest scan @{SetId='TEST-PHOTO';Source=$source;DetectDuplicates=$true}
        $ing=Load-Ingest $config 'TEST-PHOTO'
        Assert ($ing.file_count -eq 6)
        Assert (@($ing.files | Where-Object alias_of).Count -eq 1)
        Assert ($ing.directories -contains 'empty 空目录')
    }
    Case 'multi-disc plan retains alias mapping and unique IDs' {
        $null=Run-ArchiveTest plan @{SetId='TEST-PHOTO';Deduplicate=$true}
        $plan=Load-Plan $config 'TEST-PHOTO'
        Assert ($plan.discs.Count -eq 2)
        Assert (@($plan.discs | ForEach-Object files).Count -eq 5)
        Reject { Run-ArchiveTest plan @{SetId='TEST-PHOTO'} } 'immutable'
    }
    Case 'stage, simulate, verify and register two discs' {
        foreach ($d in (Load-Plan $config 'TEST-PHOTO').discs) {
            $null=Run-ArchiveTest stage @{DiscId=$d.disc_id}
            $null=Run-ArchiveTest burn @{DiscId=$d.disc_id;Simulate=$true}
            $v=Run-ArchiveTest verify @{DiscId=$d.disc_id;Simulate=$true};Assert ($v.status -eq 'PASS')
            $null=Run-ArchiveTest register @{DiscId=$d.disc_id;Location='TEST / binder 1'}
            Assert ((Get-Disc $config $d.disc_id).status -eq 'SIMULATED_PASS')
        }
    }
    Case 'sequential multi-disc restore recreates duplicates and empty dirs' {
        $plan=Load-Plan $config 'TEST-PHOTO';$dest=Join-Path $run 'restored photo'
        $r=Run-ArchiveTest restore @{SetId='TEST-PHOTO';Output=$dest;MediaRoots=@((Get-Disc $config $plan.discs[0].disc_id).burn.root)}
        Assert ($r.status -eq 'PARTIAL')
        $r=Run-ArchiveTest restore @{SetId='TEST-PHOTO';Output=$dest;MediaRoots=@((Get-Disc $config $plan.discs[1].disc_id).burn.root)}
        Assert ($r.status -eq 'PASS')
        Assert (@(Tree-Files $dest).Count -eq 6)
        Assert (Test-Path -LiteralPath (Join-Path $dest 'empty 空目录'))
    }
    Case 'simulation cannot authorize source deletion or physical verify' {
        Reject { Run-ArchiveTest delete-source @{SetId='TEST-PHOTO';DeleteSourceConfirmed=$true} } 'physical verification'
        Assert (@(Tree-Files $source).Count -eq 6)
        Reject { Run-ArchiveTest verify @{DiscId='BD-P-0001';Drive='Z:';MediaReloaded=$true} } 'cannot be mixed'
    }
    Case 'corruption and extra files fail optical-tree checks' {
        $rec=Get-Disc $config 'BD-P-0001'
        Write-Text (Join-Path $rec.burn.root 'unexpected.txt') 'unexpected'
        Reject { Run-ArchiveTest verify @{DiscId='BD-P-0001';Simulate=$true} } 'Unexpected file count'
        Assert ((Get-Disc $config 'BD-P-0001').status -eq 'VERIFY_FAILED')
        $rec=Get-Disc $config 'BD-P-0002'
        [IO.File]::AppendAllText((Join-Path $rec.burn.root 'RESTORE.md'),'corruption')
        Reject { Run-ArchiveTest verify @{DiscId='BD-P-0002';Simulate=$true} } 'SHA-256 FAIL'
    }
    Case 'metadata replicated into every independent backup shard' {
        $backup=Join-Path $run 'backup';[IO.Directory]::CreateDirectory($backup) | Out-Null
        foreach ($i in 1..3) { $bytes=New-Object byte[] (900KB);$rng.NextBytes($bytes);[IO.File]::WriteAllBytes((Join-Path $backup "$i.bin"),$bytes) }
        Write-Text (Join-Path $backup 'Manifest.db') 'synthetic SQLite placeholder, not a real iPhone database'
        Write-Text (Join-Path $backup 'Info.plist') '<plist>synthetic</plist>'
        $null=Run-ArchiveTest scan @{SetId='TEST-BACKUP';Source=$backup;Category='III'}
        $null=Run-ArchiveTest plan @{SetId='TEST-BACKUP'}
        $plan=Load-Plan $config 'TEST-BACKUP';Assert ($plan.discs.Count -ge 2)
        foreach ($d in $plan.discs) { Assert (@($d.files | Where-Object path -eq 'Manifest.db').Count -eq 1);Assert (@($d.files | Where-Object path -eq 'Info.plist').Count -eq 1) }
    }
    if ($LiveDwarfs) {
        Case 'LIVE DwarFS 0.15.7 build/check/extract/stage/restore' {
            $roots=@()
            foreach ($d in (Load-Plan $config 'TEST-BACKUP').discs) {
                $built=Run-ArchiveTest build @{DiscId=$d.disc_id};Assert ($built.verification.exit_code -eq 0);Assert ($built.roundtrip -eq 'PASS')
                $null=Run-ArchiveTest stage @{DiscId=$d.disc_id};$null=Run-ArchiveTest burn @{DiscId=$d.disc_id;Simulate=$true};$null=Run-ArchiveTest verify @{DiscId=$d.disc_id;Simulate=$true}
                $roots+=,(Get-Disc $config $d.disc_id).burn.root
            }
            $r=Run-ArchiveTest restore @{SetId='TEST-BACKUP';Output=(Join-Path $run 'backup restored');MediaRoots=$roots}
            Assert ($r.status -eq 'PASS')
        }
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Case 'Unicode and paths longer than 260 characters' {
            $deep=Join-Path $run 'long-source'
            $rel=(('子目录 long name/'*16)+'sample.txt')
            $path=Safe-Join $deep $rel;Write-Text $path 'long-path fixture'
            Assert ($path.Length -gt 260)
            $null=Run-ArchiveTest scan @{SetId='LONG-PATH';Source=$deep}
            $null=Run-ArchiveTest plan @{SetId='LONG-PATH'}
            $d=(Load-Plan $config 'LONG-PATH').discs[0]
            $null=Run-ArchiveTest stage @{DiscId=$d.disc_id}
            Assert (Test-Path -LiteralPath (Safe-Join (Join-Path (Get-Disc $config $d.disc_id).stage.path 'data') $rel))
        }
    }
} finally {
    Write-Json (Join-Path $run 'test-results.json') @{powershell=$PSVersionTable.PSVersion.ToString();live_dwarfs=[bool]$LiveDwarfs;results=$script:results.ToArray();run=$run}
    Write-Host "Test artifacts retained: $run"
}
