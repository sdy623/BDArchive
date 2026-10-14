# KSP Mission Display visual-language port. Presentation only: never modifies
# an archive, selects physical media, authorizes burning, or deletes source data.
function Get-ArchiveTheme {
    @{
        Canvas='#020408';Surface='#0A1420';Input='#07101A';Ink='#F2F6FB';Muted='#8290A3';Line='#293440'
        Rail='#020408';RailText='#B9C5D2';RailActive='#062B3A';Accent='#00A8E0';AccentHover='#36BDE9'
        AccentPale='#062B3A';AccentInk='#00131D';Warning='#F2A900';WarningPale='#2B210B'
        Danger='#E8312A';DangerPale='#2A1015';Success='#39D98A';Font='IBM Plex Sans';CjkFont='Microsoft YaHei UI'
        Display='Barlow Condensed';BodySize=10;Mono='IBM Plex Mono'
    }
}
function ConvertTo-ArchiveColor([string]$Value) { [Drawing.ColorTranslator]::FromHtml($Value) }
function Set-ArchiveButtonStyle($Button,[ValidateSet('Secondary','Primary','Danger')][string]$Kind='Secondary') {
    $t=Get-ArchiveTheme
    $Button.FlatStyle='Flat';$Button.FlatAppearance.BorderSize=1;$Button.UseVisualStyleBackColor=$false
    $Button.UseMnemonic=$false;$Button.BackColor=ConvertTo-ArchiveColor $t.Input;$Button.ForeColor=ConvertTo-ArchiveColor $t.Ink
    $Button.FlatAppearance.BorderColor=ConvertTo-ArchiveColor $t.Line
    $Button.FlatAppearance.MouseOverBackColor=ConvertTo-ArchiveColor $t.Surface
    if($Kind -eq 'Primary'){
        $Button.BackColor=ConvertTo-ArchiveColor $t.Accent;$Button.ForeColor=ConvertTo-ArchiveColor $t.AccentInk
        $Button.FlatAppearance.BorderColor=$Button.BackColor;$Button.FlatAppearance.MouseOverBackColor=ConvertTo-ArchiveColor $t.AccentHover
    }elseif($Kind -eq 'Danger'){
        $Button.BackColor=ConvertTo-ArchiveColor $t.DangerPale;$Button.ForeColor=ConvertTo-ArchiveColor '#FF7772'
        $Button.FlatAppearance.BorderColor=ConvertTo-ArchiveColor $t.Danger;$Button.FlatAppearance.MouseOverBackColor=ConvertTo-ArchiveColor '#44191D'
    }
}
function Set-ArchiveComboStyle($Combo) {
    $t=Get-ArchiveTheme;$Combo.FlatStyle='Flat';$Combo.DrawMode='OwnerDrawFixed'
    $Combo.BackColor=ConvertTo-ArchiveColor $t.Input;$Combo.ForeColor=ConvertTo-ArchiveColor $t.Ink
    $Combo.ItemHeight=[Math]::Max(24,$Combo.Font.Height+6)
    if(!$Combo.PSObject.Properties['ArchiveThemeDrawBound']){
        $Combo | Add-Member NoteProperty ArchiveThemeDrawBound $true
        $Combo.Add_FontChanged({$this.ItemHeight=[Math]::Max(24,$this.Font.Height+6)})
        $Combo.Add_DrawItem({
            param($sender,$e)
            $selected=($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
            $back=ConvertTo-ArchiveColor $(if($selected){'#062B3A'}else{'#07101A'})
            $ink=ConvertTo-ArchiveColor $(if($sender.Enabled){'#F2F6FB'}else{'#8290A3'})
            $brush=New-Object Drawing.SolidBrush($back)
            try{$e.Graphics.FillRectangle($brush,$e.Bounds)}finally{$brush.Dispose()}
            $text=if($e.Index -ge 0){$sender.GetItemText($sender.Items[$e.Index])}else{$sender.Text}
            $rect=New-Object Drawing.Rectangle(($e.Bounds.X+6),$e.Bounds.Y,([Math]::Max(1,$e.Bounds.Width-12)),$e.Bounds.Height)
            $flags=[Windows.Forms.TextFormatFlags]::NoPrefix -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis
            [Windows.Forms.TextRenderer]::DrawText($e.Graphics,$text,$sender.Font,$rect,$ink,$flags)
            if(($e.State -band [Windows.Forms.DrawItemState]::Focus) -ne 0){$e.DrawFocusRectangle()}
        })
    }
}
# WinForms can create native Edit HFONTs at 96 DPI while the window is at 144+
# DPI. Keep the managed logical point size for layout, but give Edit an explicit
# per-monitor HFONT. Each control owns exactly one handle and releases it on
# handle destruction; no system font installation or global DPI setting occurs.
function Set-ArchiveNativeEditFont($Control) {
    if(!('ArchiveEditFontNative' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ArchiveEditFontNative {
    [DllImport("gdi32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFontW(int height, int width, int escapement,
        int orientation, int weight, uint italic, uint underline, uint strikeOut,
        uint charSet, uint outPrecision, uint clipPrecision, uint quality,
        uint pitchAndFamily, string faceName);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DeleteObject(IntPtr handle);
}
"@
    }
    if(!$Control.PSObject.Properties['ArchiveNativeFontHandle']) {
        $Control | Add-Member NoteProperty ArchiveNativeFontHandle ([IntPtr]::Zero)
        $Control.Add_HandleCreated({Set-ArchiveNativeEditFont $this})
        $Control.Add_FontChanged({Set-ArchiveNativeEditFont $this})
        $Control.Add_DpiChangedAfterParent({Set-ArchiveNativeEditFont $this})
        $Control.Add_HandleDestroyed({
            if($this.ArchiveNativeFontHandle -ne [IntPtr]::Zero){
                $null=[ArchiveEditFontNative]::DeleteObject($this.ArchiveNativeFontHandle)
                $this.ArchiveNativeFontHandle=[IntPtr]::Zero
            }
        })
    }
    if(!$Control.IsHandleCreated -or $Control.IsDisposed){return}
    $height=-[int][Math]::Round($Control.Font.SizeInPoints*$Control.DeviceDpi/72.0)
    $weight=if($Control.Font.Bold){700}else{400}
    $font=[ArchiveEditFontNative]::CreateFontW($height,0,0,0,$weight,0,0,0,1,0,0,5,0,$Control.Font.Name)
    if($font -eq [IntPtr]::Zero){throw 'Unable to create readable native input font.'}
    $old=$Control.ArchiveNativeFontHandle
    $Control.ArchiveNativeFontHandle=$font
    $null=[ArchiveEditFontNative]::SendMessageW($Control.Handle,0x30,$font,[IntPtr]1)
    if($old -ne [IntPtr]::Zero){$null=[ArchiveEditFontNative]::DeleteObject($old)}
}
function Show-ArchiveLogSnapshot($Shell) {
    $zh=$Shell.Language -match '^zh'
    $caption=if($zh){'任务记录快照'}else{'Activity snapshot'}
    $window=New-ArchiveForm $caption 840 560
    $window.Padding=New-Object Windows.Forms.Padding(16)
    $text=New-UiField $Shell.Log.Text;$text.Multiline=$true;$text.ReadOnly=$true
    $text.WordWrap=$false;$text.ScrollBars='Both';$text.Dock='Fill'
    $text.Font=New-Object Drawing.Font('Consolas',9)
    $text.AccessibleName=$caption;$window.Controls.Add($text)
    $window.Add_FormClosed({$this.Dispose()})
    $window.Show($Shell.Form)
}
function Set-ArchiveControlStyle($Control) {
    $t=Get-ArchiveTheme
    if($Control -is [Windows.Forms.Button]){Set-ArchiveButtonStyle $Control}
    elseif($Control -is [Windows.Forms.TextBox]){
        $Control.BorderStyle='FixedSingle';$Control.BackColor=ConvertTo-ArchiveColor $t.Input;$Control.ForeColor=ConvertTo-ArchiveColor $t.Ink
        # Native Win32 Edit rendering needs an installed GDI family. The private
        # Plex font otherwise falls back to a tiny stock font despite valid metrics.
        $nativeFamily=if($env:BD_ARCHIVE_LANGUAGE -match '^zh'){'Microsoft YaHei UI'}else{'Segoe UI'}
        $Control.Font=New-Object Drawing.Font($nativeFamily,10);Set-ArchiveNativeEditFont $Control
    }elseif($Control -is [Windows.Forms.ComboBox]){
        Set-ArchiveComboStyle $Control
    }elseif($Control -is [Windows.Forms.CheckBox]){$Control.ForeColor=ConvertTo-ArchiveColor $t.Ink}
    elseif($Control -is [Windows.Forms.DataGridView]){
        $Control.BackgroundColor=ConvertTo-ArchiveColor $t.Surface;$Control.BorderStyle='None';$Control.EnableHeadersVisualStyles=$false
        $Control.RowHeadersVisible=$false;$Control.CellBorderStyle='SingleHorizontal';$Control.GridColor=ConvertTo-ArchiveColor $t.Line
        $Control.ColumnHeadersBorderStyle='None';$Control.ColumnHeadersDefaultCellStyle.BackColor=ConvertTo-ArchiveColor $t.Input
        $Control.ColumnHeadersDefaultCellStyle.ForeColor=ConvertTo-ArchiveColor $t.Muted
        $Control.ColumnHeadersDefaultCellStyle.Padding=New-Object Windows.Forms.Padding(6,7,6,7)
        $Control.DefaultCellStyle.Padding=New-Object Windows.Forms.Padding(6,4,6,4)
        $Control.DefaultCellStyle.BackColor=ConvertTo-ArchiveColor $t.Surface;$Control.DefaultCellStyle.ForeColor=ConvertTo-ArchiveColor $t.Ink
        $Control.DefaultCellStyle.SelectionBackColor=ConvertTo-ArchiveColor $t.RailActive;$Control.DefaultCellStyle.SelectionForeColor=ConvertTo-ArchiveColor '#65D8FF'
        $Control.AlternatingRowsDefaultCellStyle.BackColor=ConvertTo-ArchiveColor $t.Input
    }elseif($Control -is [Windows.Forms.TabPage]){
        $Control.UseVisualStyleBackColor=$false;$Control.BackColor=ConvertTo-ArchiveColor $t.Surface;$Control.ForeColor=ConvertTo-ArchiveColor $t.Ink
        $Control.Padding=New-Object Windows.Forms.Padding(16,12,16,12)
    }elseif($Control -is [Windows.Forms.Label]){$Control.ForeColor=ConvertTo-ArchiveColor $t.Muted}
    foreach($child in $Control.Controls){Set-ArchiveControlStyle $child}
}
function Sync-ArchiveShellSelection($Shell) {
    $t=Get-ArchiveTheme
    if($Shell.RoutePicker.SelectedIndex -ne $Shell.Tabs.SelectedIndex){$Shell.RoutePicker.SelectedIndex=$Shell.Tabs.SelectedIndex}
    for($i=0;$i -lt $Shell.NavigationButtons.Count;$i++){
        $b=$Shell.NavigationButtons[$i];$selected=($Shell.Tabs.SelectedIndex -eq $i)
        $b.BackColor=ConvertTo-ArchiveColor $(if($selected){$t.RailActive}else{$t.Rail})
        $b.ForeColor=ConvertTo-ArchiveColor $(if($selected){'#65D8FF'}else{$t.RailText})
        $b.AccessibleDescription=if($selected){'selected'}else{'not active'}
        $b.FlatAppearance.BorderColor=ConvertTo-ArchiveColor $(if($selected){$t.Accent}else{$t.Rail})
        $b.FlatAppearance.BorderSize=1 # Both states reserve border space.
    }
}
function Set-ArchiveNativeInputFonts($Control,[string]$Language,$Log) {
    if($Control -is [Windows.Forms.TextBox]){
        $size=$Control.Font.SizeInPoints
        $family=if($Control -eq $Log){'Consolas'}elseif($Language -match '^zh'){'Microsoft YaHei UI'}else{'Segoe UI'}
        $Control.Font=New-Object Drawing.Font($family,$size);Set-ArchiveNativeEditFont $Control
    }
    foreach($child in $Control.Controls){Set-ArchiveNativeInputFonts $child $Language $Log}
}
function Set-ArchiveShellLanguage($Shell,[string]$Language='en') {
    $Shell.Language=$Language;$Shell.ActivityButton.Text=if($Language -match '^zh'){'任务记录'}else{'Activity'};
    $zh=$Language -match '^zh';$t=Get-ArchiveTheme;$font=if($zh){$t.CjkFont}else{$t.Font}
    $Shell.Form.Font=New-ArchiveFont -Role Ui -Size $Shell.Form.Font.Size -Language $Language
    foreach($c in @($Shell.Subtitle,$Shell.Mode,$Shell.NavigationLabel,$Shell.RoutePicker,$Shell.LogLabel)){
        $c.Font=New-ArchiveFont -Role Ui -Size $c.Font.Size -Language $Language
    }
    foreach($b in $Shell.NavigationButtons){$b.Font=New-ArchiveFont -Role Ui -Size 10 -Language $Language}
    $Shell.Title.Text='BD ARCHIVE';$Shell.Eyebrow.Text='OPTICAL STORAGE SYSTEMS'
    $Shell.Subtitle.Text=if($zh){'照片 / 录像 / 备份归档'}else{'PHOTOS / RECORDINGS / BACKUPS'}
    $Shell.Mode.Text=if($zh){'预览优先 / 刻录需确认'}else{'PREVIEW FIRST / CONFIRM TO BURN'}
    $Shell.NavigationLabel.Text=if($zh){'工作区'}else{'WORKSPACE'}
    $Shell.LogLabel.Text=if($zh){'任务记录 / 原始输出'}else{'ACTIVITY / RAW OUTPUT'}
    $Shell.Navigation.AccessibleName=if($zh){'工作流程导航'}else{'Workflow navigation'}
    $Shell.Form.AccessibleDescription=if($zh){'本地归档。实际写入光盘仍需逐盘确认。'}else{'Local archiving. Physical disc writes require explicit per-disc confirmation.'}
    Set-ArchiveNativeInputFonts $Shell.Form $Language $Shell.Log
    Update-ArchiveShellLayout $Shell
}
function Update-ArchiveShellLayout($Shell) {
    if($Shell.Updating){return};$Shell.Updating=$true
    try{
        $scale=[Math]::Max(1.0,$Shell.Form.Font.Size/10.0)
        $needed=40
        foreach($b in $Shell.NavigationButtons){$needed+=$b.GetPreferredSize([Drawing.Size]::Empty).Width+8}
        $compact=$Shell.Form.ClientSize.Width -lt [Math]::Max((900*$scale),$needed)
        $mode=if($compact){'compact'}else{'tabs'}
        if($Shell.LayoutMode -eq $mode -and $Shell.LayoutWidth -eq $Shell.Form.ClientSize.Width -and $Shell.NavPreferred -eq $needed){return}
        $Shell.Navigation.SuspendLayout()
        $Shell.NavigationLabel.Visible=$compact;$Shell.RoutePicker.Visible=$compact
        $Shell.RoutePicker.Width=[Math]::Max(180,[Math]::Min(440,$Shell.Form.ClientSize.Width-190))
        foreach($b in $Shell.NavigationButtons){$b.Visible=!$compact;$b.AutoSize=$true}
        $Shell.Mode.Visible=!$compact;$Shell.ActivityButton.Visible=$compact
        # Retain task and cancellation space; the full evidence log returns on widening.
        # Worker output is still collected and written while this pane is collapsed.
        $Shell.LogCard.Visible=!$compact
        $Shell.Root.RowStyles[2].SizeType=if($compact){'Absolute'}else{'Percent'}
        $Shell.Root.RowStyles[2].Height=if($compact){0}else{22}
        $Shell.Header.Padding=New-Object Windows.Forms.Padding(20,10,20,10)
        # A nested AutoSize FlowLayoutPanel can retain a pre-wrap height when its
        # Dock=Fill parent narrows. Measure the two header columns at their actual
        # widths, rather than donating a stale extra row to empty header space.
        $headerWidth=if($Shell.Header.ClientSize.Width -gt 40){$Shell.Header.ClientSize.Width}else{$Shell.Form.ClientSize.Width}
        $columnWidth=[Math]::Max(1,[int](($headerWidth-$Shell.Header.Padding.Horizontal)/2))
        $constraint=New-Object Drawing.Size($columnWidth,0)
        $headerHeight=[Math]::Max($Shell.Branding.GetPreferredSize($constraint).Height,$Shell.HeaderActions.GetPreferredSize($constraint).Height)+$Shell.Header.Padding.Vertical
        if($compact){$Shell.Outer.RowStyles[0].SizeType='Absolute';$Shell.Outer.RowStyles[0].Height=$headerHeight}
        else{$Shell.Outer.RowStyles[0].SizeType='AutoSize'}
        $Shell.LayoutMode=$mode;$Shell.LayoutWidth=$Shell.Form.ClientSize.Width;$Shell.NavPreferred=$needed
        $Shell.Navigation.ResumeLayout($true)
    }finally{$Shell.Updating=$false}
}
function New-ArchiveShell {
    param($Form,$Root,$Tabs,$Log,[object[]]$PrimaryButtons=@(),[object[]]$DangerButtons=@(),[string]$Language='en')
    $t=Get-ArchiveTheme;$Form.SuspendLayout();$Form.BackColor=ConvertTo-ArchiveColor $t.Canvas;$Form.ForeColor=ConvertTo-ArchiveColor $t.Ink
    Set-ArchiveControlStyle $Root
    foreach($b in $PrimaryButtons){Set-ArchiveButtonStyle $b Primary};foreach($b in $DangerButtons){Set-ArchiveButtonStyle $b Danger}
    $Root.Padding=New-Object Windows.Forms.Padding(20,10,20,14);$Root.Margin=New-Object Windows.Forms.Padding(0);$Root.BackColor=$Form.BackColor
    $Tabs.Appearance='FlatButtons';$Tabs.SizeMode='Fixed';$Tabs.ItemSize=New-Object Drawing.Size(1,1);$Tabs.Multiline=$false
    $Tabs.DrawMode='OwnerDrawFixed';$Tabs.Add_DrawItem({});$Tabs.Padding=New-Object Drawing.Point(0,0);$Tabs.Margin=New-Object Windows.Forms.Padding(0,0,0,10)
    $tabParent=$Tabs.Parent;$tabPosition=$tabParent.GetPositionFromControl($Tabs);$tabParent.Controls.Remove($Tabs)
    $tabHost=New-Object Windows.Forms.Panel;$tabHost.Dock='Fill';$tabHost.Margin=New-Object Windows.Forms.Padding(0,0,0,10)
    $tabHost.BackColor=ConvertTo-ArchiveColor $t.Surface;$tabHost.Controls.Add($Tabs);$Tabs.Dock='None'
    $cropTabs=$Tabs;$cropHost=$tabHost
    $resizeTabFrame={
        $edge=[int][Math]::Ceiling(4*$cropHost.DeviceDpi/96.0);$top=[int][Math]::Ceiling(8*$cropHost.DeviceDpi/96.0)
        $cropTabs.Location=New-Object Drawing.Point(-$edge,-$top)
        $cropTabs.Size=New-Object Drawing.Size(($cropHost.ClientSize.Width+2*$edge),($cropHost.ClientSize.Height+$top+$edge))
    }.GetNewClosure()
    $tabHost.Add_Resize($resizeTabFrame);$tabParent.Controls.Add($tabHost,$tabPosition.Column,$tabPosition.Row)
    & $resizeTabFrame
    $Log.BackColor=ConvertTo-ArchiveColor $t.Input;$Log.ForeColor=ConvertTo-ArchiveColor '#A9C0D3';$Log.BorderStyle='None'
    $Log.Font=New-Object Drawing.Font('Consolas',9)
    $Log.Margin=New-Object Windows.Forms.Padding(12,4,12,10)
    $logParent=$Log.Parent;$logPosition=$logParent.GetPositionFromControl($Log);$logParent.Controls.Remove($Log)
    $logCard=New-UiTable 1;$logCard.Dock='Fill';$logCard.AutoSize=$false;$logCard.BackColor=$Log.BackColor
    $logLabel=New-UiLabel '';$logLabel.ForeColor=ConvertTo-ArchiveColor $t.Muted;$logLabel.Font=New-ArchiveFont -Role Mono -Size 8
    $logLabel.Margin=New-Object Windows.Forms.Padding(12,8,12,2);Add-UiRow $logCard @($logLabel);Add-UiRow $logCard @($Log)
    $logCard.RowStyles[1].SizeType='Percent';$logCard.RowStyles[1].Height=100;$logParent.Controls.Add($logCard,$logPosition.Column,$logPosition.Row)
    $Form.Controls.Remove($Root)
    $outer=New-UiTable 1;$outer.Dock='Fill';$outer.AutoSize=$false
    $header=New-UiTable 2;$header.Dock='Fill';$header.BackColor=ConvertTo-ArchiveColor $t.Canvas
    $header.Padding=New-Object Windows.Forms.Padding(20,10,20,10);$header.ColumnStyles[0].Width=50;$header.ColumnStyles[1].Width=50
    $branding=New-UiTable 2;$branding.ColumnStyles.Clear()
    $null=$branding.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    $null=$branding.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $mark=New-UiLabel 'B';$mark.AutoSize=$false;$mark.Size=New-Object Drawing.Size(38,44);$mark.Dock='None';$mark.TextAlign='MiddleCenter'
    $mark.Font=New-ArchiveFont -Role Display -Size 22 -Bold;$mark.BackColor=ConvertTo-ArchiveColor $t.Accent;$mark.ForeColor=ConvertTo-ArchiveColor $t.AccentInk
    $mark.Margin=New-Object Windows.Forms.Padding(0,2,12,0)
    $brandText=New-UiTable 1
    $title=New-UiLabel '';$title.Font=New-ArchiveFont -Role Display -Size 20 -Bold;$title.ForeColor=ConvertTo-ArchiveColor $t.Ink;$title.Margin=New-Object Windows.Forms.Padding(0)
    $subtitle=New-UiLabel '';$subtitle.Font=New-ArchiveFont -Role Mono -Size 8;$subtitle.ForeColor=ConvertTo-ArchiveColor $t.Muted;$subtitle.Margin=New-Object Windows.Forms.Padding(0,2,0,0)
    $eyebrow=New-UiLabel '';$eyebrow.Visible=$false
    Add-UiRow $brandText @($title);Add-UiRow $brandText @($subtitle);Add-UiRow $branding @($mark,$brandText)
    $actions=New-UiFlow @();$actions.FlowDirection='RightToLeft';$actions.WrapContents=$true;$actions.Padding=New-Object Windows.Forms.Padding(0,8,0,0)
    $mode=New-UiLabel '';$mode.Font=New-ArchiveFont -Role Mono -Size 8;$mode.BackColor=ConvertTo-ArchiveColor $t.WarningPale;$mode.ForeColor=ConvertTo-ArchiveColor $t.Warning
    $mode.Padding=New-Object Windows.Forms.Padding(10,7,10,7);$mode.Margin=New-Object Windows.Forms.Padding(8,0,0,0);$actions.Controls.Add($mode)
    $activity=New-UiButton 'Activity';$activity.Margin=New-Object Windows.Forms.Padding(8,0,0,0);$actions.Controls.Add($activity)
    Add-UiRow $header @($branding,$actions)
    $nav=New-Object Windows.Forms.FlowLayoutPanel;$nav.Dock='Fill';$nav.AutoSize=$true;$nav.AutoSizeMode='GrowAndShrink';$nav.WrapContents=$false
    $nav.FlowDirection='LeftToRight';$nav.Padding=New-Object Windows.Forms.Padding(20,0,20,8);$nav.Margin=New-Object Windows.Forms.Padding(0);$nav.BackColor=$Form.BackColor
    $navLabel=New-UiLabel '';$navLabel.Dock='None';$navLabel.Font=New-ArchiveFont -Role Mono -Size 8;$navLabel.Margin=New-Object Windows.Forms.Padding(0,10,16,0);$nav.Controls.Add($navLabel)
    $routePicker=New-Object Windows.Forms.ComboBox;$routePicker.DropDownStyle='DropDownList';$routePicker.FlatStyle='Flat';$routePicker.AccessibleName='Workflow / 工作流程'
    $routePicker.Margin=New-Object Windows.Forms.Padding(0,4,0,4);$routePicker.BackColor=ConvertTo-ArchiveColor $t.Surface;$routePicker.ForeColor=ConvertTo-ArchiveColor $t.Ink;$nav.Controls.Add($routePicker)
    Set-ArchiveComboStyle $routePicker
    $routeTabs=$Tabs;$routePicker.Add_SelectedIndexChanged({if($this.SelectedIndex -ge 0){$routeTabs.SelectedIndex=$this.SelectedIndex}}.GetNewClosure())
    $buttons=New-Object 'System.Collections.Generic.List[object]'
    foreach($page in $Tabs.TabPages){
        $caption=$page.Text -replace '^\d+\s*','';$null=$routePicker.Items.Add($caption)
        $b=New-UiButton $caption;$b.Padding=New-Object Windows.Forms.Padding(14,7,14,7);$b.Margin=New-Object Windows.Forms.Padding(0,0,6,0)
        $b.AutoSize=$true;$b.FlatAppearance.MouseOverBackColor=ConvertTo-ArchiveColor $t.RailActive;$b.AccessibleName=$caption
        $targetTabs=$Tabs;$targetPage=$page;$b.Add_Click({$targetTabs.SelectedTab=$targetPage}.GetNewClosure())
        $nav.Controls.Add($b);$buttons.Add($b)
    }
    $body=New-UiTable 1;$body.AutoSize=$false;$body.Dock='Fill';Add-UiRow $body @($Root);$body.RowStyles[0].SizeType='Percent';$body.RowStyles[0].Height=100
    Add-UiRow $outer @($header);Add-UiRow $outer @($nav);Add-UiRow $outer @($body);$outer.RowStyles[2].SizeType='Percent';$outer.RowStyles[2].Height=100;$Form.Controls.Add($outer)
    $shell=[pscustomobject]@{Language=$Language;ActivityButton=$activity;Form=$Form;Root=$Root;Tabs=$Tabs;Outer=$outer;Header=$header;HeaderActions=$actions;Body=$body;Branding=$branding;Navigation=$nav;NavigationButtons=$buttons;NavigationLabel=$navLabel;RoutePicker=$routePicker;Eyebrow=$eyebrow;Title=$title;Subtitle=$subtitle;Mode=$mode;LogLabel=$logLabel;Log=$Log;LogCard=$logCard;LayoutMode='';LayoutWidth=0;NavPreferred=0;Updating=$false}
    Set-ArchiveShellLanguage $shell $Language;Sync-ArchiveShellSelection $shell
    $captured=$shell;$activity.Add_Click({Show-ArchiveLogSnapshot $captured}.GetNewClosure());$Tabs.Add_SelectedIndexChanged({Sync-ArchiveShellSelection $captured}.GetNewClosure())
    $Form.Add_Resize({Update-ArchiveShellLayout $captured}.GetNewClosure())
    foreach($page in $Tabs.TabPages){$page.Add_TextChanged({$i=$captured.Tabs.TabPages.IndexOf($this);$text=$this.Text -replace '^\d+\s*','';$captured.NavigationButtons[$i].Text=$text;$captured.NavigationButtons[$i].AccessibleName=$text;$captured.RoutePicker.Items[$i]=$text;Update-ArchiveShellLayout $captured}.GetNewClosure())}
    $Form.ResumeLayout($true);$shell
}