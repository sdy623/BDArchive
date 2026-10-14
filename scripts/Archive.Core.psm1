# PowerShell 5.1-compatible syntax. PowerShell 7 is required for long-path workloads.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:HashBuffer = New-Object byte[] 1048576
. "$PSScriptRoot/Archive.Localization.ps1"
. "$PSScriptRoot/Archive.Progress.ps1"
. "$PSScriptRoot/Archive.Locking.ps1"

function Read-Json($Path) {
    # Atomic writers replace the directory entry. Share Delete so an open reader
    # can finish its old, complete snapshot without blocking the new catalog.
    # ReplaceFile may briefly deny a handle or expose a rename gap on Windows.
    # Bound those retries to 500 ms; malformed JSON and access denial fail at once.
    $stream=$null;$reader=$null
    for ($attempt=0;;$attempt++) {
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            break
        } catch {
            $code=$_.Exception.GetBaseException().HResult -band 0xffff
            if ($code -notin @(2,3,32,33) -or $attempt -ge 20) {throw}
            [Threading.Thread]::Sleep(25)
        }
    }
    try {$reader=New-Object IO.StreamReader($stream,$script:Utf8,$true);$json=$reader.ReadToEnd()}
    finally {if ($reader) {$reader.Dispose()} elseif ($stream) {$stream.Dispose()}}
    ConvertFrom-Json $json
}
function Write-Json($Path, $Value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 100), $script:Utf8)
    if ([IO.File]::Exists($Path)) {
        # Windows indexers/readers may briefly deny replacement. Retry only
        # transient sharing/removal errors; never delete the old catalog first.
        for ($attempt=0;;$attempt++) {
            try { [IO.File]::Replace($temp,$Path,[NullString]::Value);break }
            catch {
                $errorCode=$_.Exception.GetBaseException().HResult -band 0xffff
                if ($attempt -ge 5 -or $errorCode -notin @(5,32,33,1175) -or ![IO.File]::Exists($temp) -or ![IO.File]::Exists($Path)) { throw }
                [Threading.Thread]::Sleep(100)
            }
        }
    }
    else { [IO.File]::Move($temp, $Path) }
}
function Write-Text($Path, [string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}
function Full-Path([string]$Path, [string]$Base = (Get-Location).Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A non-empty path is required.' }
    if (![IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Base $Path }
    [IO.Path]::GetFullPath($Path)
}
function Assert-Id([string]$Id) {
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw "Invalid identifier: $Id" }
}
function Assert-NoLinks([string]$Path) {
    $current = Full-Path $Path
    while ($current) {
        # Keep every ancestor check, without invoking two providers per level.
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] { $attributes = 0 }
        catch [IO.DirectoryNotFoundException] { $attributes = 0 }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not allowed: $current" }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd('\','/'))
        if ($parent -eq $current) { break }; $current = $parent
    }
}
function Safe-Join([string]$Root, [string]$Relative) {
    if (!$Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[/\\])\.\.([/\\]|$)|[:\r\n]') { throw "Unsafe relative path: $Relative" }
    $base = (Full-Path $Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $target = Full-Path (Join-Path $base $Relative)
    if (!$target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes root: $Relative" }
    if ($PSVersionTable.PSVersion.Major -lt 7 -and $target.Length -gt 240) { throw 'Long paths require PowerShell 7; no files have been silently skipped.' }
    if ([IO.File]::Exists($target) -and ([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReparsePoint)) { $null=Resolve-ArchiveFileReference $target } else { Assert-NoLinks $target }
    $target
}
function Assert-Separate($A, $B) {
    $a1 = (Full-Path $A).TrimEnd('\','/') + '\'; $b1 = (Full-Path $B).TrimEnd('\','/') + '\'
    if ($a1.StartsWith($b1,[StringComparison]::OrdinalIgnoreCase) -or $b1.StartsWith($a1,[StringComparison]::OrdinalIgnoreCase)) { throw 'Source, archive and restore trees must not overlap.' }
}
function Relative-Path($Root,$Path) { (Full-Path $Path).Substring((Full-Path $Root).TrimEnd('\','/').Length + 1).Replace('\','/') }
function Tree-Files($Root) {
    Assert-NoLinks $Root
    $stack = New-Object 'System.Collections.Generic.Stack[string]'; $stack.Push((Full-Path $Root))
    while ($stack.Count) {
        Assert-PreparationRunning
        foreach ($item in (Get-ChildItem -LiteralPath $stack.Pop() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Archive-FileInfo $item.FullName;continue }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            else { $item }
        }
    }
}
function File-Hash($Path) {
    Assert-PreparationRunning
    if (!$script:ArchiveProgressJob -and !$script:HashProgressScope) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $stream=[IO.File]::OpenRead($Path);$hash=[Security.Cryptography.SHA256]::Create()
    try {
        # This module runs serially in one worker. Reuse a bounded buffer instead
        # of allocating 4 MiB for each of hundreds of thousands of tiny files.
        $length=$stream.Length # Cache the size; do not query optical file attributes per block.
        $buffer=$script:HashBuffer;$done=[int64]0;$clock=[Diagnostics.Stopwatch]::StartNew()
        Set-HashProgress $Path 0 $length $clock -Force:($length -ge 1MB)
        while (($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            Assert-PreparationRunning;$null=$hash.TransformBlock($buffer,0,$n,$buffer,0)
            $done+=$n;Set-HashProgress $Path $done $length $clock
        }
        Assert-PreparationRunning;$null=$hash.TransformFinalBlock($buffer,0,0)
        Set-HashProgress $Path $done $length $clock -Force:($length -ge 1MB)
        ([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant()
    } finally { $hash.Dispose();$stream.Dispose() }
}
function Assert-PlainFile($Path) {
    # Additional NTFS streams would otherwise be omitted from the manifest and
    # lost on deleting the original. Refuse that input instead of silently
    # accepting an incomplete archive (including Zone.Identifier streams).
    if ($env:OS -eq 'Windows_NT') {
        $streamPath=Full-Path $Path
        if ($streamPath.Length -gt 240 -and !$streamPath.StartsWith('\\?\')) {
            if ($streamPath.StartsWith('\\')) { $streamPath='\\?\UNC\'+$streamPath.Substring(2) }
            else { $streamPath='\\?\'+$streamPath }
        }
        foreach ($stream in @(Get-Item -LiteralPath $streamPath -Force -Stream * -ErrorAction Stop)) {
            if ($stream.Stream -notin @(':$DATA','::$DATA','$DATA')) { throw "Alternate data stream requires a stream-preserving backup first: $Path / $($stream.Stream)" }
        }
    }
}
function Copy-Checked($Source,$Target,$Expected) {
    Assert-NoLinks $Source; Assert-NoLinks $Target
    if ([IO.File]::Exists($Target)) {
        if ((File-Hash $Target) -ne $Expected) { throw "Restore/copy conflict: $Target" }
        return
    }
    if ((File-Hash $Source) -ne $Expected) { throw "Source changed: $Source" }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Target)) | Out-Null
    if ($script:PreparationJob) {
        Set-PreparationProgress "复制：$([IO.Path]::GetFileName($Source))"
        $partial=$Target+'.partial-'+[guid]::NewGuid().ToString('N')
        $input=[IO.File]::OpenRead($Source);$output=$null
        try {
            $output=[IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $buffer=New-Object byte[] 4194304
            while (($n=$input.Read($buffer,0,$buffer.Length)) -gt 0) { Assert-PreparationRunning;Set-PreparationProgress "复制：$([IO.Path]::GetFileName($Source))";$output.Write($buffer,0,$n) }
        } finally { if ($output) { $output.Dispose() };$input.Dispose() }
        if ((File-Hash $partial) -ne $Expected) { throw "Copy verification failed: $partial" }
        Assert-PreparationRunning;[IO.File]::Move($partial,$Target)
    } else { [IO.File]::Copy($Source,$Target,$false) }
    if (!$script:PreparationJob -and (File-Hash $Target) -ne $Expected) { throw "Copy verification failed: $Target" }
    [IO.File]::SetLastWriteTimeUtc($Target,[IO.File]::GetLastWriteTimeUtc($Source))
}
function Same-Bytes($A,$B) {
    $left=[IO.File]::OpenRead($A); $right=[IO.File]::OpenRead($B)
    try {
        if ($left.Length -ne $right.Length) { return $false }
        $x=New-Object byte[] 1048576; $y=New-Object byte[] 1048576
        while (($n=$left.Read($x,0,$x.Length)) -gt 0) {
            Assert-PreparationRunning
            $offset=0
            while ($offset -lt $n) { $m=$right.Read($y,$offset,$n-$offset); if (!$m) { return $false }; $offset += $m }
            # Compare blocks in native .NET, avoiding a per-byte PowerShell loop.
            if ([Convert]::ToBase64String($x,0,$n) -cne [Convert]::ToBase64String($y,0,$n)) { return $false }
        }
        return $true
    } finally { $left.Dispose(); $right.Dispose() }
}
function Load-Config($Path) {
    $configPath=Full-Path $Path; $c=Read-Json $configPath; $base=Split-Path $configPath
    $c.archive_root=Full-Path $c.archive_root $base; $c.catalog_path=Full-Path $c.catalog_path $base
    foreach ($prop in $c.tools.PSObject.Properties) {
        if ($prop.Value -and ($prop.Value -match '[/\\]')) { $prop.Value=Full-Path $prop.Value $base }
    }
    if ($c.schema_version -ne 1) { throw 'Unsupported config schema.' }
    $c
}
function Catalog-Path($C) { Join-Path $C.archive_root 'catalog.json' }
function Set-Dir($C,$Id) {
    Assert-Id $Id
    if ([IO.File]::Exists((Catalog-Path $C))) {
        $set=@((Read-Json (Catalog-Path $C)).sets | Where-Object archive_set_id -eq $Id)
        if ($set.Count -eq 1) {
            $revision=Optional-Field $set[0] 'manifest_directory'
            if ($revision) {
                if ($revision -notmatch ('^sets/'+[regex]::Escape($Id)+'/revisions/[0-9a-f]{32}$')) {throw 'Invalid manifest revision path.'}
                return Safe-Join $C.archive_root $revision
            }
        }
    }
    Safe-Join $C.archive_root "sets/$Id"
}
function Load-Ingest($C,$Id) { Read-Json (Join-Path (Set-Dir $C $Id) 'ingest.json') }
function Load-Plan($C,$Id) { Read-Json (Join-Path (Set-Dir $C $Id) 'plan.json') }
function Get-Disc($C,$Id,[switch]$IncludeDeleted) {
    $null=Disc-Number $Id
    $cat=Read-Json (Catalog-Path $C); $d=@($cat.discs | Where-Object disc_id -eq $Id)
    if ($d.Count -ne 1) { throw "Unknown disc: $Id" }
    if ((Optional-Field $d[0] 'catalog_deleted') -and !$IncludeDeleted) { throw "Disc record $Id is deleted from the catalog. Restore the record before archive operations." }
    $d[0]
}
function Update-Disc($C,$Disc) {
    $catalogLease=Enter-CatalogLock $C
    try {
    $cat=Read-Json (Catalog-Path $C)
    if (@($cat.discs | Where-Object disc_id -eq $Disc.disc_id).Count -ne 1) {throw 'Disc disappeared during catalog update.'}
    $cat.discs=@($cat.discs | ForEach-Object { if ($_.disc_id -eq $Disc.disc_id) { $Disc } else { $_ } })
    $cat.updated_at=[DateTime]::UtcNow.ToString('o'); Write-Json (Catalog-Path $C) $cat
    } finally {Exit-ArchiveLock $catalogLease}
}
function Event($C,$Action,$Detail) {
    $catalogLease=Enter-ArchiveFileLock (Join-Path $C.archive_root 'locks/events.lock') '事件日志' -WaitMilliseconds 30000
    try {
    $entry=@{time=[DateTime]::UtcNow.ToString('o'); action=$Action; detail=$Detail}
    [IO.File]::AppendAllText((Join-Path $C.archive_root 'events.jsonl'),((ConvertTo-Json $entry -Depth 20 -Compress)+"`n"),$script:Utf8)
    } finally {Exit-ArchiveLock $catalogLease}
}
function Resolve-Tool($C,$Name) {
    $path=$C.tools.$Name
    if ($path) { if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Configured tool missing: $path" }; return $path }
    $command=Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if (!$command) { throw "Configure tools.$Name in archive.config.json." }
    if ($Name -eq 'python' -and $command.Source -match 'WindowsApps') { throw 'Windows Store Python alias is not a runtime. Configure tools.python with a real Python 3.10+ executable.' }
    $command.Source
}
function Resolve-Dwarfs($C,$Tool) {
    if ($C.tools.dwarfs_bin) {
        $path=Join-Path $C.tools.dwarfs_bin "$Tool.exe"
        if (Test-Path -LiteralPath $path) { return @{exe=$path; prefix=@()} }
    }
    if ($C.tools.dwarfs) { return @{exe=(Resolve-Tool $C 'dwarfs'); prefix=@("--tool=$Tool")} }
    $cmd=Get-Command "$Tool.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return @{exe=$cmd.Source;prefix=@()} }
    $uni=Get-Command 'dwarfs-universal.exe' -ErrorAction SilentlyContinue
    if ($uni) { return @{exe=$uni.Source;prefix=@("--tool=$Tool")} }
    throw "DwarFS tool missing: $Tool; configure dwarfs_bin or universal executable tools.dwarfs."
}
function Run-Tool($C,$Exe,[string[]]$Arguments,$Label,[int[]]$Allowed=@(0),[string]$InputExe="",[string[]]$InputArguments=@()) {
    Assert-PreparationRunning
    if (!('ArchiveStreamingProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Archive.Process.cs') }
    $log=Join-Path $C.archive_root ("logs/{0}-{1}-{2}.log" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff'),$Label,[guid]::NewGuid().ToString('N').Substring(0,6))
    [IO.Directory]::CreateDirectory((Split-Path $log)) | Out-Null
    Write-Host "External tool: $Label | live log: $log"
    $progressMessage=switch ($Label) { 'dwarfsck' {'DwarFS 内部完整性检查（工具不提供百分比）'} 'dwarfsck-help' {'读取 DwarFS 工具版本'} default {"工具：$Label"} }
    Set-PreparationProgress $progressMessage $log -Force
    $process=$null;$code=$null;$cancelled=$false
    try {
        $process=if ($InputExe) { New-Object ArchiveStreamingProcess($Exe,$Arguments,$log,$InputExe,$InputArguments) } else { New-Object ArchiveStreamingProcess($Exe,$Arguments,$log) }
        Set-PreparationProgress $progressMessage $log -Force -ToolPid $process.Process.Id
        while (!$process.Process.WaitForExit(100)) { Assert-PreparationRunning;Set-PreparationProgress $progressMessage $log -ToolPid $process.Process.Id }
        $code=$process.Finish();$global:LASTEXITCODE=$code
        Assert-PreparationRunning
    } catch {
        $cancelled=Is-PreparationCancellation $_
        if ($cancelled -and $process) { $process.StopOwnedProcess();$code=$process.Finish();$global:LASTEXITCODE=$code }
        Write-Json "$log.json" @{exe=$Exe;arguments=@($Arguments);exit_code=$code;status=$(if ($cancelled) {'CANCELLED'} else {'FAIL'});error=$_.Exception.Message;log=$log}
        throw
    } finally { if ($process) { $process.Dispose() } }
    $output=[regex]::Replace([IO.File]::ReadAllText($log,$script:Utf8),"$([char]27)\[[0-?]*[ -/]*[@-~]",'')
    $result=@{exe=$Exe;arguments=@($Arguments);exit_code=$code;log=$log;time=[DateTime]::UtcNow.ToString('o')}
    Write-Json "$log.json" $result;Event $C 'tool' $result
    if ($Allowed -notcontains $code) { throw "Tool failed ($code): $Exe. See $log" }
    $result.output=$output;$result
}

function Dwarfs-Run($C,$Tool,[string[]]$Arguments,$Label) {
    $t=Resolve-Dwarfs $C $Tool
    Run-Tool $C $t.exe (@($t.prefix)+$Arguments) $Label
}
function Dwarfs-Version($C,$Tool) {
    # v0.15.7 standalone tools expose the version in --help, not --version.
    $r=Dwarfs-Run $C $Tool @('--help') "$Tool-help"
    if ($r.output -notmatch [regex]::Escape($C.dwarfs.required_version)) { throw "Expected DwarFS $($C.dwarfs.required_version); inspect $($r.log)" }
    ($r.output -split "`n" | Select-Object -First 6) -join "`n"
}
function Disc-Budget($C,$Media,[double]$ParPercent,[string]$Category) {
    if ($ParPercent -lt 0 -or $ParPercent -gt 100) { throw 'PAR2 percent must be 0..100.' }
    $m=$C.media.$Media; $reserve=[int64]($C.planning.reserve_mib*1MB)
    $limit=[int64][math]::Floor(($m.capacity_bytes-$reserve)/(1+$ParPercent/100))
    $target=$m.payload_gib; if ($Category -eq 'III') { $target=$m.dwarfs_payload_gib }
    $payload=[int64][math]::Min($limit,[math]::Floor($target*1GB))
    $input=$payload; if ($Category -eq 'III') { $input-=[int64]($C.planning.dwarfs_overhead_mib*1MB) }
    if ($input -le 0 -or $reserve -le 0) { throw 'Invalid capacity or reserve.' }
    @{capacity_bytes=[int64]$m.capacity_bytes;reserve_bytes=$reserve;payload_limit_bytes=$payload;input_limit_bytes=$input;par2_percent=$ParPercent}
}
function Pack-Files($Files,[int64]$Limit,[int64]$Overhead=0,[switch]$PhotoFamilies) {
    # Keep whole directory subtrees together whenever they fit. Split large
    # directory units recursively, never split a file or a completed DwarFS.
    $units=New-Object 'System.Collections.Generic.List[object]'
    function Add-Unit($Group,[int]$Depth) {
        Assert-PreparationRunning
        $size=[int64]0; foreach ($f in $Group) { $size += [int64]$f.size+$Overhead }
        if ($size -le $Limit) { $units.Add(@{files=@($Group);size=$size}); return }
        foreach ($g in ($Group | Group-Object { $parts=$_.path -split '/'; if ($parts.Length -le $Depth+1) { if ($PhotoFamilies) { "FILE:$(Photo-Family $_.path)" } else { "FILE:$($_.path)" } } else { $parts[0..$Depth] -join '/' } } | Sort-Object Name)) {
            if ($g.Name.StartsWith('FILE:') -and [int64](($g.Group | Measure-Object size -Sum).Sum + $g.Count*$Overhead) -gt $Limit) { throw "Oversize file/photo family: $($g.Group[0].path). Split video before ingest, or choose larger media; photo sidecars stay with their image." }
            Add-Unit @($g.Group) ($Depth+1)
        }
    }
    foreach ($g in ($Files | Group-Object { if ($PhotoFamilies -and $_.path -notmatch '/') { Photo-Family $_.path } else { ($_.path -split '/')[0] } } | Sort-Object Name)) { Add-Unit @($g.Group) 0 }
    $bins=New-Object 'System.Collections.Generic.List[object]'
    foreach ($unit in ($units | Sort-Object @{Expression='size';Descending=$true},@{Expression={$_.files[0].path}})) {
        Assert-PreparationRunning
        $bin=$null
        foreach ($candidate in $bins) { if ($candidate.size+$unit.size -le $Limit) { $bin=$candidate; break } }
        if ($null -eq $bin) { $bin=@{files=@();size=[int64]0}; $bins.Add($bin) }
        $bin.files=@($bin.files)+@($unit.files); $bin.size+=$unit.size
    }
    $bins.ToArray()
}
. "$PSScriptRoot/Archive.References.ps1"
. "$PSScriptRoot/Archive.Storage.ps1"
. "$PSScriptRoot/Archive.Operations.ps1"
. "$PSScriptRoot/Archive.BurnCache.ps1"
. "$PSScriptRoot/Archive.BurnOutcome.ps1"
. "$PSScriptRoot/Archive.Optical.ps1"
. "$PSScriptRoot/Archive.Finalization.ps1"
. "$PSScriptRoot/Archive.Media.ps1"
. "$PSScriptRoot/Archive.Restore.ps1"
. "$PSScriptRoot/Archive.Summary.ps1"
. "$PSScriptRoot/Archive.Scenes.ps1"
. "$PSScriptRoot/Archive.Ui.ps1"
. "$PSScriptRoot/Archive.Tools.ps1"
. "$PSScriptRoot/Archive.Identity.ps1"
. "$PSScriptRoot/Archive.Volume.ps1"
. "$PSScriptRoot/Archive.Rename.ps1"
. "$PSScriptRoot/Archive.ExternalStage.ps1"
. "$PSScriptRoot/Archive.Dispatch.ps1"
Export-ModuleMember -Function *
