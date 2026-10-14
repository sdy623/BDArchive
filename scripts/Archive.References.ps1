# Explicit, file-only references. Directory links and unlisted links stay forbidden.
function Resolve-ArchiveFileReference([string]$Path) {
    $full=Full-Path $Path
    Assert-NoLinks (Split-Path $full)
    $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if(!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $full}
    if($item.PSIsContainer -or $item.LinkType -ne 'SymbolicLink'){throw 'Only explicitly listed file symbolic links are supported.'}
    $target=[string]$item.Target
    if($target -notmatch '^[A-Za-z]:[\\/]' -or $target -match '[\r\n|]'){throw 'Reference target must be an absolute local file.'}
    $target=Full-Path $target
    Assert-NoLinks $target
    if(!(Test-Path -LiteralPath $target -PathType Leaf)){throw "Reference target missing: $target"}
    $parent=Split-Path $full;$matched=$false
    while($parent){
        $manifest=Join-Path $parent 'ARCHIVE-REFERENCES.json'
        if(Test-Path -LiteralPath $manifest -PathType Leaf){
            Assert-NoLinks $manifest
            $map=Read-Json $manifest
            if($map.schema_version -ne 1){throw 'Unsupported reference manifest'}
            $relative=Relative-Path $parent $full
            $entries=@($map.files | Where-Object path -CEQ $relative)
            # The outer stage manifest is authoritative over the copied input
            # manifest; a verified alternate source may keep the same payload hash.
            $matched=($entries.Count -eq 1 -and (Full-Path $entries[0].target) -ceq $target)
        }
        $next=Split-Path $parent
        if($next -eq $parent){break};$parent=$next
    }
    if(!$matched){throw "Unlisted or redirected file reference: $full"}
    $target
}
function Archive-ReferenceSource($C,$File) {
    $source=[string]$File.reference_target
    $overrides=Optional-Field $C 'reference_overrides'
    $alternate=Optional-Field $overrides $File.path
    if($alternate){$source=[string]$alternate}
    if($source -notmatch '^[A-Za-z]:[\\/]'){throw 'Reference source must be an absolute local file'}
    Assert-NoLinks $source
    if(!(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Reference source missing'}
    Full-Path $source
}
function Archive-FileInfo([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force
    if(!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $item}
    $target=Resolve-ArchiveFileReference $Path
    $info=Get-Item -LiteralPath $target -Force
    [pscustomobject]@{FullName=$item.FullName;Name=$item.Name;DirectoryName=$item.DirectoryName;Length=$info.Length;LastWriteTimeUtc=$info.LastWriteTimeUtc;PSIsContainer=$false;Attributes=$item.Attributes;ReferenceTarget=$target}
}
function New-ArchiveFileReference($Source,$Target) {
    Assert-NoLinks $Source;Assert-NoLinks $Target
    if(Test-Path -LiteralPath $Target){throw 'Reference destination exists'}
    [IO.Directory]::CreateDirectory((Split-Path $Target))|Out-Null
    New-Item -ItemType SymbolicLink -Path $Target -Target (Full-Path $Source) -ErrorAction Stop|Out-Null
    $null=Resolve-ArchiveFileReference $Target
    @{mode='FILE_REFERENCE';bytes=[int64](Get-Item -LiteralPath $Source).Length}
}
