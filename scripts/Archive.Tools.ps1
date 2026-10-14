function Get-ArchiveToolInventory($C) {
    # Read-only: files/PATH/installation registry only. No installers, no CLI
    # launches, no optical access. FOUND means a file exists, not runtime PASS.
    $records=New-Object 'System.Collections.Generic.List[object]'
    $programRoots=@($env:ProgramFiles,${env:ProgramFiles(x86)},(Join-Path $env:LOCALAPPDATA 'Programs')) | Where-Object { $_ }
    $uninstall=@(Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue)
    foreach ($spec in @(
        @{key='dwarfs_bin';name='DwarFS (standalone)';exe='mkdwarfs';sub=@('dwarfs-0.15.7-Windows-AMD64/bin/mkdwarfs.exe');match='DwarFS';note='Build/check/extract; required version 0.15.7'},
        @{key='python';name='Python';exe='python';sub=@('Python313/python.exe','Python312/python.exe','Python/Python313/python.exe','Python/Python312/python.exe');match='Python';note='SQLite / iPhone metadata; Store alias is excluded'},
        @{key='ffmpeg';name='ffmpeg';exe='ffmpeg';sub=@('ffmpeg/bin/ffmpeg.exe');match='ffmpeg';note='Video contact sheets'},
        @{key='mkvmerge';name='MKVToolNix';exe='mkvmerge';sub=@('MKVToolNix/mkvmerge.exe');match='MKVTool';note='Required for video splitting'},
        @{key='par2';name='PAR2 / MultiPar';exe='par2';sub=@('MultiPar/par2j64.exe','MultiPar/par2j.exe','par2/par2.exe');match='MultiPar|PAR2';note='Only needed when PAR2 is enabled'},
        @{key='imgburn';name='ImgBurn';exe='ImgBurn';sub=@('ImgBurn/ImgBurn.exe');match='ImgBurn';note='Optional: native IMAPI2 backend is also provided'},
        @{key='winfsp';name='WinFsp';exe='';sub=@('WinFsp/bin/winfsp-x64.dll');match='WinFsp';note='Mount only; not required for build/check/extract'}
    )) {
        $configured=$C.tools.($spec.key);$configuredFile=$configured
        if ($configured -and $spec.key -eq 'dwarfs_bin') { $configuredFile=Join-Path $configured 'mkdwarfs.exe' }
        if ($configured -and $spec.key -eq 'winfsp') { $configuredFile=Join-Path $configured 'bin/winfsp-x64.dll' }
        $candidates=New-Object 'System.Collections.Generic.List[string]'
        if ($configuredFile) { $candidates.Add($configuredFile) }
        if ($spec.exe) {
            foreach ($cmd in @(Get-Command ($spec.exe+'.exe') -ErrorAction SilentlyContinue)) { $candidates.Add($cmd.Source) }
        }
        if ($spec.key -eq 'par2') { foreach ($name in @('par2j64.exe','par2j.exe')) { $cmd=Get-Command $name -ErrorAction SilentlyContinue;if ($cmd) { $candidates.Add($cmd.Source) } } }
        foreach ($base in $programRoots) { foreach ($sub in $spec.sub) { $candidates.Add((Join-Path $base $sub)) } }
        foreach ($install in $uninstall) {
            if ($install.PSObject.Properties['DisplayName'] -and $install.DisplayName -match $spec.match -and $install.PSObject.Properties['InstallLocation'] -and $install.InstallLocation -and $spec.exe) { $candidates.Add((Join-Path $install.InstallLocation ($spec.exe+'.exe'))) }
        }
        if ($spec.key -eq 'python') {
            $fallback=Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe';$candidates.Add($fallback)
            foreach ($key in @(Get-ChildItem 'HKCU:\Software\Python\PythonCore','HKLM:\Software\Python\PythonCore' -ErrorAction SilentlyContinue)) {
                $entry=Get-Item -LiteralPath (Join-Path $key.PSPath 'InstallPath') -ErrorAction SilentlyContinue
                if ($entry) { $path=$entry.GetValue('ExecutablePath');if ($path) { $candidates.Add($path) } }
            }
        }
        $found=$null
        foreach ($candidate in $candidates) {
            if ($spec.key -eq 'python' -and $candidate -match '[/\\]WindowsApps[/\\]') { continue }
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found=Full-Path $candidate;break }
        }
        $state='MISSING';$selected=$null;$version=$null
        if ($found) {
            $state='FOUND';$selected=$found;$version=(Get-Item -LiteralPath $found).VersionInfo.FileVersion
            if ($spec.key -eq 'dwarfs_bin') {
                $selected=Split-Path $found
                foreach ($required in @('dwarfsck.exe','dwarfsextract.exe')) { if (!(Test-Path -LiteralPath (Join-Path $selected $required))) { $state='INCOMPLETE' } }
            }
            if ($spec.key -eq 'winfsp') { $selected=Split-Path (Split-Path $found) }
        }
        if ($configuredFile -and !(Test-Path -LiteralPath $configuredFile -PathType Leaf)) { $state='CONFIGURED_MISSING' }
        $records.Add([pscustomobject]@{key=$spec.key;tool=$spec.name;state=$state;configured=$configured;detected=$selected;version=$version;note=$spec.note})
    }
    if ($C.tools.dwarfs) {
        $state=if (Test-Path -LiteralPath $C.tools.dwarfs -PathType Leaf) { 'FOUND' } else { 'CONFIGURED_MISSING' }
        $records.Add([pscustomobject]@{key='dwarfs';tool='DwarFS universal';state=$state;configured=$C.tools.dwarfs;detected=$C.tools.dwarfs;version=$null;note='Configured universal EXE; --tool dispatch is checked when building'})
    }
    $native=[type]::GetTypeFromProgID('IMAPI2.MsftDiscFormat2Data')
    $records.Add([pscustomobject]@{key='imapi2';tool='Windows IMAPI2';state=if ($native) { 'BUILT_IN' } else { 'MISSING' };configured=$null;detected=$null;version=$null;note='Windows COM registration; no recorder was opened or tested'})
    $records.ToArray()
}
