# Font resources are scoped to this process (FR_PRIVATE). No installation,
# system settings, font registry writes, network downloads or CDN requests.
$script:ArchiveFontCollection=$null
function Initialize-ArchiveFonts {
    if($script:ArchiveFontCollection){return}
    Add-Type -AssemblyName System.Drawing
    if(!('ArchivePrivateFonts' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ArchivePrivateFonts {
 [DllImport("gdi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern int AddFontResourceEx(string path, uint flags, IntPtr reserved);
}
"@
    }
    $fonts=New-Object Drawing.Text.PrivateFontCollection
    $fontRoot=Join-Path (Split-Path $PSScriptRoot) 'assets/fonts'
    foreach($name in @('barlow-condensed-400.ttf','barlow-condensed-600.ttf','ibm-plex-sans-400.ttf','ibm-plex-sans-600.ttf','ibm-plex-mono-400.ttf','ibm-plex-mono-600.ttf')) {
        $path=Join-Path $fontRoot $name
        if(![IO.File]::Exists($path)){continue}
        $fonts.AddFontFile($path)
        # WinForms uses GDI for text rendering; GDI+ collection alone is not enough.
        if([ArchivePrivateFonts]::AddFontResourceEx($path,0x10,[IntPtr]::Zero) -eq 0) {throw "Cannot load private font: $name"}
    }
    $script:ArchiveFontCollection=$fonts
}
function New-ArchiveFont {
    param([ValidateSet('Ui','Display','Mono')][string]$Role='Ui',[single]$Size=10,[string]$Language=$env:BD_ARCHIVE_LANGUAGE,[switch]$Bold)
    Initialize-ArchiveFonts
    if($Role -eq 'Ui' -and $Language -match '^zh') {
        return New-Object Drawing.Font('Microsoft YaHei UI',$Size,$(if($Bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}))
    }
    $names=@{Ui='IBM Plex Sans';Display='Barlow Condensed';Mono='IBM Plex Mono'}
    $name=$names[$Role]
    if($Bold){$name=@{Ui='IBM Plex Sans SemiBold SemiBold';Display='Barlow Condensed SemiBold';Mono='IBM Plex Mono SemiBold'}[$Role]}
    $family=@($script:ArchiveFontCollection.Families|Where-Object {$_.Name -ceq $name})
    if($family.Count){return New-Object Drawing.Font($family[0],$Size,[Drawing.FontStyle]::Regular)}
    $fallback=@{Ui='Segoe UI';Display='Arial Narrow';Mono='Consolas'}[$Role]
    return New-Object Drawing.Font($fallback,$Size,$(if($Bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}))
}
