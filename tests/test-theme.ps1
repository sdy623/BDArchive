[CmdletBinding()]
param([string]$PreviewPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$theme=Join-Path $PSScriptRoot '../scripts/Archive.Theme.ps1'
if (!(Test-Path -LiteralPath $theme)) { throw 'FAIL: visual shell not implemented; existing tab content has no responsive navigation.' }
. (Join-Path $PSScriptRoot '../scripts/Archive.Ui.ps1')
$tokens=Get-ArchiveTheme
if($tokens.Canvas -ne '#020408' -or $tokens.Accent -ne '#00A8E0'){throw 'FAIL: theme does not carry the requested KSP Mission Display source palette.'}
$dpi=Initialize-ArchiveDpi
$form=$null
try {
    $form=New-ArchiveForm 'Theme integration fixture' 1220 850
    $root=New-UiTable 1;$root.Dock='Fill';$root.AutoSize=$false;$form.Controls.Add($root)
    $tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';Add-UiRow $root @($tabs)
    $root.RowStyles[0].SizeType='Percent';$root.RowStyles[0].Height=75
    foreach($name in @('1  Prepare','2  Discs & restore','3  Video','4  Tools','5  Identity','6  Labels')) {
        $page=New-UiPage $tabs $name
        $nativeInput=New-UiField 'HgMpj0123';Add-UiSetting $page.table 'Archive ID' $nativeInput
        Add-UiSetting $page.table 'Source folder' (New-UiField 'D:\Archive\Source')
    }
    if(!$page.viewport -or !$page.actions){throw 'FAIL: page lacks a scrollable content viewport and a separate fixed action bar.'}
    $pageAction=New-UiButton 'Confirm local preparation';Add-UiActionBar -Page $page -Controls @($pageAction)
    for($row=0;$row -lt 30;$row++){Add-UiSetting $page.table ('Field '+$row) (New-UiField 'Synthetic value')}
    $primary=New-UiButton 'Prepare archive';$danger=New-UiButton 'Burn disc...'
    Add-UiRow $root @((New-UiFlow @($primary,$danger)))
    $log=New-UiField 'No archive operation is running.';$log.Multiline=$true;Add-UiRow $root @($log)
    $root.RowStyles[2].SizeType='Percent';$root.RowStyles[2].Height=25
    $shell=New-ArchiveShell -Form $form -Root $root -Tabs $tabs -Log $log -PrimaryButtons @($primary) -DangerButtons @($danger) -Language en
    $lateChoice=New-UiChoice @('English','简体中文');$shell.HeaderActions.Controls.Add($lateChoice)
    if($lateChoice.BackColor.GetBrightness() -gt 0.2){throw 'FAIL: controls added after shell styling escape the dark design system.'}
    $form.ResumeLayout($true);$form.Show();[Windows.Forms.Application]::DoEvents()
    $comboPixels=New-Object Drawing.Bitmap($lateChoice.Width,$lateChoice.Height);try{$lateChoice.DrawToBitmap($comboPixels,(New-Object Drawing.Rectangle(0,0,$lateChoice.Width,$lateChoice.Height)));if($comboPixels.GetPixel(([Math]::Max(5,$lateChoice.Width-40)),([int]($lateChoice.Height/2))).GetBrightness() -gt 0.3){throw 'FAIL: native combo selection still paints a white surface.'}}finally{$comboPixels.Dispose()}
    $tabs.SelectedIndex=5;[Windows.Forms.Application]::DoEvents()
    if(!('ArchiveFontTestProbe' -as [type])){Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ArchiveFontTestProbe {
    [DllImport("gdi32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetObjectW(IntPtr handle, int size, IntPtr buffer);
}
"@}
    $hfont=[ArchiveEditFontNative]::SendMessageW($nativeInput.Handle,0x31,[IntPtr]::Zero,[IntPtr]::Zero)
    $fontBuffer=[Runtime.InteropServices.Marshal]::AllocHGlobal(92)
    try{
        if([ArchiveFontTestProbe]::GetObjectW($hfont,92,$fontBuffer) -ne 92){throw 'FAIL: native Edit font could not be inspected.'}
        $nativeHeight=[Runtime.InteropServices.Marshal]::ReadInt32($fontBuffer)
        $expectedHeight=-[int][Math]::Round($nativeInput.Font.SizeInPoints*$nativeInput.DeviceDpi/72.0)
        if($nativeHeight -ne $expectedHeight){throw "FAIL: native Edit HFONT is $nativeHeight px; expected $expectedHeight at actual monitor DPI."}
        Write-Output "Native Edit: $($nativeInput.Font.Name), $($nativeInput.Font.SizeInPoints) pt, DPI $($nativeInput.DeviceDpi), HFONT $nativeHeight px."
    }finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($fontBuffer)}
    $nativePixels=New-Object Drawing.Bitmap($nativeInput.Width,$nativeInput.Height)
    try{
        $nativeInput.DrawToBitmap($nativePixels,(New-Object Drawing.Rectangle(0,0,$nativeInput.Width,$nativeInput.Height)))
        $inkRows=0
        for($y=2;$y -lt $nativeInput.Height-2;$y++){
            $ink=0;for($x=3;$x -lt [Math]::Min(190,$nativeInput.Width-3);$x++){if($nativePixels.GetPixel($x,$y).GetBrightness() -gt 0.7){$ink++}}
            if($ink -ge 3){$inkRows++}
        }
        $minimumInkRows=[int][Math]::Ceiling(9*$form.DeviceDpi/96.0)
        if($inkRows -lt $minimumInkRows){throw "FAIL: native Edit font is visually too small ($inkRows ink rows, need $minimumInkRows)."}
    }finally{$nativePixels.Dispose()}
    if ($shell.NavigationButtons.Count -ne 6) { throw 'FAIL: a workflow page is missing from navigation.' }
    $shell.NavigationButtons[4].PerformClick();[Windows.Forms.Application]::DoEvents()
    if ($tabs.SelectedIndex -ne 4) { throw 'FAIL: navigation does not activate the existing identity page.' }
    $tabs.SelectedIndex=2;[Windows.Forms.Application]::DoEvents()
    if ($shell.NavigationButtons[2].AccessibleDescription -notmatch 'selected') { throw 'FAIL: keyboard tab changes are not reflected in accessible navigation.' }
    $tabs.TabPages[2].Text='3  Video preparation'
    if ($shell.NavigationButtons[2].Text -notmatch 'Video preparation') { throw 'FAIL: translated page text is not reflected in navigation.' }
    if ($primary.BackColor.ToArgb() -eq $danger.BackColor.ToArgb()) { throw 'FAIL: dangerous burn action is visually indistinguishable from preparation.' }
    Set-ArchiveShellLanguage -Shell $shell -Language zh-CN
    if ($shell.Subtitle.Text -notmatch '归档') { throw 'FAIL: Chinese shell localization is absent.' }
    Set-ArchiveShellLanguage -Shell $shell -Language en
    if ($shell.Subtitle.Text -match '[\u4e00-\u9fff]') { throw 'FAIL: English shell retains untranslated Chinese chrome.' }
    $form.ClientSize=New-Object Drawing.Size(760,660);[Windows.Forms.Application]::DoEvents()
    if ($shell.LayoutMode -ne 'compact') { throw 'FAIL: narrow window keeps a fixed-width navigation rail.' }
    if (!$shell.RoutePicker -or !$shell.RoutePicker.Visible -or $shell.RoutePicker.Items.Count -ne 6) {throw 'FAIL: compact navigation needs one accessible picker rather than consuming two task rows.'}
    $shell.RoutePicker.SelectedIndex=5;[Windows.Forms.Application]::DoEvents()
    $actionBefore=$pageAction.RectangleToScreen($pageAction.ClientRectangle);$page.viewport.AutoScrollPosition=New-Object Drawing.Point(0,900);[Windows.Forms.Application]::DoEvents()
    if($actionBefore -ne $pageAction.RectangleToScreen($pageAction.ClientRectangle)){throw 'FAIL: primary action scrolls away with settings.'}
    Show-UiControl $pageAction
    if ($tabs.SelectedIndex -ne 5) {throw 'FAIL: compact route picker did not open the existing Labels page.'}
    if($shell.LogCard.Visible){throw 'FAIL: compact layout sacrifices task viewport to a large output pane.'}
    if(!$shell.ActivityButton.Visible){throw 'FAIL: collapsed activity log has no accessible disclosure.'}
    $shell.ActivityButton.PerformClick();[Windows.Forms.Application]::DoEvents()
    $snapshot=@($form.OwnedForms | Where-Object {$_.Text -eq 'Activity snapshot'})
    if($snapshot.Count -ne 1){throw 'FAIL: Activity did not open the clearly labeled output snapshot.'}
    try{
        $snapshotText=@($snapshot[0].Controls | Where-Object {$_ -is [Windows.Forms.TextBox]})[0]
        if(!$snapshotText.ReadOnly -or $snapshotText.Text -ne $log.Text){throw 'FAIL: Activity snapshot is not read-only exact worker output.'}
    }finally{$snapshot[0].Close()}
    if ($shell.Navigation.Height -gt 90) {throw 'FAIL: compact navigation consumes excessive height.'}
    $form.ClientSize=New-Object Drawing.Size(1220,850);[Windows.Forms.Application]::DoEvents()
    if ($shell.LayoutMode -ne 'tabs') { throw 'FAIL: spacious window did not restore the KMD route tabs.' }
    if($shell.Header.Height -gt (100*$form.DeviceDpi/96)){throw 'FAIL: mission header consumes marketing-hero height.'}
    if($log.BackColor.GetBrightness() -gt 0.2 -or $tabs.SelectedTab.BackColor.GetBrightness() -gt 0.2){throw 'FAIL: evidence and task surfaces do not use the KMD dark engineering panel system.'}
    foreach($button in $shell.NavigationButtons){if($button.Width -lt $button.GetPreferredSize([Drawing.Size]::Empty).Width){throw ('FAIL: rail navigation clips '+$button.Text)}}
    if ($PreviewPath) {
        $image=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try {$form.DrawToBitmap($image,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$image.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)} finally {$image.Dispose()}
    }
    Write-Output 'PASS: six workflow routes, active state, translated page updates, dangerous-action contrast, en/zh chrome, compact/tabs navigation, KMD surfaces, fixed actions and dark combo rendering.'
} finally {if($form){$form.Dispose()};Restore-ArchiveDpi $dpi}