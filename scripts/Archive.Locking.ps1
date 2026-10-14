# OS-owned handles, not PID files: crashes release locks, filenames may remain.
$script:ArchiveHeldLocks=@{}
$script:ArchiveOperationConfig=$null
function Lock-Key([string]$Value) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.ToUpperInvariant())))).Replace('-','').ToLowerInvariant() }
    finally {$sha.Dispose()}
}
function Enter-ArchiveFileLock($Path,[string]$Description,[switch]$Shared,[int]$WaitMilliseconds=0) {
    $path=Full-Path $Path;Assert-NoLinks $path;$key=$path.ToUpperInvariant()
    if ($script:ArchiveHeldLocks.ContainsKey($key)) {
        $held=$script:ArchiveHeldLocks[$key]
        if (!$Shared -and $held.shared) {throw 'Cannot upgrade a shared archive gate inside a running operation.'}
        $held.count++;return @{key=$key;kind='file'}
    }
    [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
    $share=if ($Shared) {[IO.FileShare]::ReadWrite} else {[IO.FileShare]::None}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $stream=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,$share)
            $script:ArchiveHeldLocks[$key]=@{stream=$stream;shared=[bool]$Shared;count=1}
            return @{key=$key;kind='file'}
        } catch {
            $code=$_.Exception.GetBaseException().HResult -band 0xffff
            if ($code -notin @(32,33)) {throw}
            if ($clock.ElapsedMilliseconds -ge $WaitMilliseconds) {throw "资源正在使用：$Description。请等待该资源的任务完成；其他归档可以并行。"}
            [Threading.Thread]::Sleep(40)
        }
    }
}
function Enter-ArchiveMutex([string]$Resource,[string]$Description) {
    # Shared across archive roots in this interactive Windows session.
    $mutex=New-Object Threading.Mutex($false,('Local\BDArchive-'+(Lock-Key $Resource)))
    $acquired=$false
    try {
        try {$acquired=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$acquired=$true}
        if (!$acquired) {throw "资源正在使用：$Description。此设备/输出正被另一任务使用。"}
        @{kind='mutex';mutex=$mutex}
    } catch {$mutex.Dispose();throw}
}
function Exit-ArchiveLock($Lease) {
    if (!$Lease) {return}
    if ($Lease.kind -eq 'mutex') {try {$Lease.mutex.ReleaseMutex()} finally {$Lease.mutex.Dispose()};return}
    $held=$script:ArchiveHeldLocks[$Lease.key];$held.count--
    if ($held.count -eq 0) {$held.stream.Dispose();$script:ArchiveHeldLocks.Remove($Lease.key)}
}
function Exit-ArchiveOperationLocks($Leases) {
    for ($i=$Leases.Count-1;$i -ge 0;$i--) {Exit-ArchiveLock $Leases[$i]}
}
function Enter-CatalogLock($C) {
    Enter-ArchiveFileLock (Join-Path $C.archive_root 'locks/catalog.lock') 'catalog 更新/盘号分配' -WaitMilliseconds 30000
}
function Update-ArchiveSet($C,$Set) {
    $lease=Enter-CatalogLock $C
    try {
        $cat=Read-Json (Catalog-Path $C)
        if (@($cat.sets | Where-Object archive_set_id -eq $Set.archive_set_id).Count -ne 1) {throw 'Set disappeared during catalog update.'}
        $cat.sets=@($cat.sets | ForEach-Object {if ($_.archive_set_id -eq $Set.archive_set_id) {$Set} else {$_}})
        $cat.updated_at=[DateTime]::UtcNow.ToString('o');Write-Json (Catalog-Path $C) $cat
    } finally {Exit-ArchiveLock $lease}
}
function Get-ArchiveOperationScope($C,$Command,$P) {
    # Legacy identity recovery journals snapshot the entire catalog. Keep these
    # rare administrative transactions exclusive until the journal is redesigned.
    $maintenance=$Command -in @('rename-disc','rename-set','repair-identity-change','delete-source','delete-orphan-set','discard-unburned-plan')
    $setId=[string](Optional-Field $P 'SetId')
    $discId=Optional-Field $P 'DiscId'
    if ($discId) {
        $disc=Get-Disc $C $discId -IncludeDeleted
        if ($setId -and $setId -ine $disc.archive_set_id) {throw 'DiscId and Archive Set do not match.'}
        $setId=$disc.archive_set_id
    }
    if ($setId) {Assert-Id $setId}
    if ($Command -in @('import-stage','prepare','scan','plan','build','stage','par2','burn','verify','register','summary','restore','delete-disc-record','restore-disc-record','recover-burn','clear-simulation','repair-verify','delete-source','delete-orphan-set','discard-unburned-plan') -and !$setId) {throw 'This operation requires an Archive Set or DiscId.'}
    @{archive_root=$C.archive_root;set_id=$setId;maintenance=$maintenance}
}
function Enter-ArchiveOperationLocks($C,$Command,$P) {
    $leases=New-Object 'System.Collections.Generic.List[object]'
    try {
        $maintenance=$Command -in @('rename-disc','rename-set','repair-identity-change','delete-source','delete-orphan-set','discard-unburned-plan')
        # Shared compatibility gate: all new jobs coexist; an old version holding
        # archive.lock exclusively still blocks us, and vice versa. Never unlink it.
        $leases.Add((Enter-ArchiveFileLock (Join-Path $C.archive_root 'archive.lock') '旧版任务或全库维护' -Shared:(!$maintenance)))
        $scope=Get-ArchiveOperationScope $C $Command $P
        if ($scope.set_id) {
            $leases.Add((Enter-ArchiveFileLock (Join-Path $C.archive_root ('locks/set-'+(Lock-Key $scope.set_id)+'.lock')) ("归档 "+$scope.set_id)))
        }
        if ($Command -in @('burn','verify','repair-verify') -and !(Optional-Field $P 'Simulate')) {
            $drive=[string](Optional-Field $P 'Drive')
            if ($drive -notmatch '^[A-Za-z]:[\\/]?$') {throw 'Select an optical drive before starting.'}
            $leases.Add((Enter-ArchiveMutex ('optical:'+($drive.Substring(0,2).ToUpperInvariant())) ("光驱 "+$drive)))
        }
        if ($Command -eq 'import-stage') {$leases.Add((Enter-ArchiveMutex ('output:'+(External-PhotoRoot $P.Source)) '现成照片盘目录'))}
        foreach ($key in @('Output','MountPoint')) {
            $value=Optional-Field $P $key
            if ($value -and $Command -in @('restore','split-video','contact-sheet','mount')) {
                $leases.Add((Enter-ArchiveMutex ('output:'+(Full-Path $value).TrimEnd('\','/')) '输出目录'))
            }
        }
        # Restore/read-only standalone image tools also respect an optical writer.
        if ($Command -in @('restore','verify-dwarfs','mount')) {
            $roots=@(Optional-Field $P 'MediaRoots')+@(Optional-Field $P 'Image')
            $drives=@{}
            foreach ($path in $roots) {
                if (!$path) {continue};$root=[IO.Path]::GetPathRoot((Full-Path $path))
                $info=New-Object IO.DriveInfo($root)
                if ($info.DriveType -eq [IO.DriveType]::CDRom) {$drives[$root.Substring(0,2).ToUpperInvariant()]=$true}
            }
            foreach ($drive in ($drives.Keys | Sort-Object)) {$leases.Add((Enter-ArchiveMutex ('optical:'+$drive) ("光驱 "+$drive)))}
        }
        return ,$leases.ToArray()
    } catch {Exit-ArchiveOperationLocks $leases;throw}
}
function Sync-ArchiveCatalog($C) {
    # Serialize publishers, reading the latest atomic catalog only AFTER entry.
    # Long-running build/burn jobs never retain this publication lock.
    $lease=Enter-ArchiveFileLock (Join-Path $C.archive_root 'locks/index.lock') '目录索引发布' -WaitMilliseconds 30000
    $catalogLease=$null
    try {
        # Python's reader is outside this module: protect its small catalog
        # snapshot from Windows ReplaceFile gaps during this index publication.
        $catalogLease=Enter-CatalogLock $C
        $python=Resolve-Tool $C 'python'
        $null=Run-Tool $C $python @((Join-Path $PSScriptRoot '../catalog/catalog.py'),'sync','--json',(Catalog-Path $C),'--db',$C.catalog_path) 'catalog-sync'
    } finally {Exit-ArchiveLock $catalogLease;Exit-ArchiveLock $lease}
}
