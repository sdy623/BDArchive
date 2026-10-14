. "$PSScriptRoot/Archive.Fonts.ps1"
# Shared by the main GUI and the physical-burn confirmation worker.
# No global display settings, registry compatibility flags or host config edits.
function Initialize-ArchiveDpi {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Initialize-ArchiveFonts
    if (!('ArchiveNativeDpi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ArchiveNativeDpi {
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] public static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
    [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
}
'@
    }
    $modern=([Windows.Forms.Application].GetMethods().Name -contains 'SetHighDpiMode')
    $set=$false
    if ($modern) { $set=[Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::PerMonitorV2) }
    # PowerShell's executable may already set process awareness in its manifest.
    # Override this dedicated STA GUI thread before creating ANY control HWND.
    $previous=[ArchiveNativeDpi]::SetThreadDpiAwarenessContext([IntPtr](-4))
    if ($previous -eq [IntPtr]::Zero) { throw 'Cannot enable Per-Monitor V2 for the GUI thread. Windows 10 1703+ is required.' }
    [Windows.Forms.Application]::EnableVisualStyles()
    [Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    [pscustomobject]@{previous_context=$previous;modern_winforms=$modern;process_mode_set=$set;thread_per_monitor_v2=[ArchiveNativeDpi]::AreDpiAwarenessContextsEqual([ArchiveNativeDpi]::GetThreadDpiAwarenessContext(),[IntPtr](-4))}
}
function Restore-ArchiveDpi($State) {
    if ($State) { $null=[ArchiveNativeDpi]::SetThreadDpiAwarenessContext($State.previous_context) }
}
function New-ArchiveWorkerStartInfo([string]$Engine,[string]$Runner,[string]$RequestPath,[bool]$InteractiveReview) {
    # No user values become executable PowerShell code. Paths are passed to
    # -File; Windows filenames cannot contain an embedded double quote.
    foreach ($path in @($Engine,$Runner,$RequestPath)) { if (!$path -or $path -match '["\r\n]') { throw 'Invalid worker path.' } }
    $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$Engine
    $start.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "'+$Runner+'" -RequestPath "'+$RequestPath+'"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    # CreateNoWindow hides the console. STARTUPINFO WindowStyle=Hidden also
    # suppresses the first WinForms dialog, leaving a real burn waiting unseen.
    # The user needs this one interactive review window to confirm or cancel.
    $start.WindowStyle=if ($InteractiveReview) {'Normal'} else {'Hidden'}
    $start
}
function Fit-ArchiveWindow($Window) {
    $area=[Windows.Forms.Screen]::FromHandle($Window.Handle).WorkingArea
    $Window.MinimumSize=New-Object Drawing.Size([Math]::Min($Window.MinimumSize.Width,$area.Width),[Math]::Min($Window.MinimumSize.Height,$area.Height))
    $Window.Size=New-Object Drawing.Size([Math]::Min($Window.Width,$area.Width),[Math]::Min($Window.Height,$area.Height))
    $Window.Location=New-Object Drawing.Point([Math]::Max($area.Left,[Math]::Min($Window.Left,$area.Right-$Window.Width)),[Math]::Max($area.Top,[Math]::Min($Window.Top,$area.Bottom-$Window.Height)))
}
function New-ArchiveForm($Title,[int]$Width=1020,[int]$Height=800) {
    $w=New-Object Windows.Forms.Form;$w.SuspendLayout()
    $w.Text=$Title;$w.AutoScaleMode='Dpi';$w.AutoScaleDimensions=New-Object Drawing.SizeF(96,96)
    $w.Font=New-ArchiveFont -Role Ui -Size 10
    $w.ClientSize=New-Object Drawing.Size($Width,$Height);$w.MinimumSize=New-Object Drawing.Size(640,440)
    $w.StartPosition='CenterScreen';$w.BackColor=ConvertTo-ArchiveColor (Get-ArchiveTheme).Canvas;$w.ForeColor=ConvertTo-ArchiveColor (Get-ArchiveTheme).Ink
    $w.Add_Shown({ Fit-ArchiveWindow $this })
    $w.Add_DpiChanged({ $window=$this;$later={ Fit-ArchiveWindow $window }.GetNewClosure();$this.BeginInvoke([Action]$later) | Out-Null })
    $w
}
function New-UiTable([int]$Columns=1) {
    $t=New-Object Windows.Forms.TableLayoutPanel;$t.ColumnCount=$Columns;$t.RowCount=0;$t.GrowStyle='AddRows'
    $t.Dock='Top';$t.AutoSize=$true;$t.AutoSizeMode='GrowAndShrink';$t.Margin=New-Object Windows.Forms.Padding(0)
    for ($i=0;$i -lt $Columns;$i++) { $null=$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,(100.0/$Columns)))) }
    $t
}
function Add-UiRow($Table,[object[]]$Controls) {
    $r=$Table.RowCount;$Table.RowCount=$r+1;$null=$Table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    for ($i=0;$i -lt $Controls.Count;$i++) { $Table.Controls.Add($Controls[$i],$i,$r) }
    if ($Controls.Count -eq 1 -and $Table.ColumnCount -gt 1) { $Table.SetColumnSpan($Controls[0],$Table.ColumnCount) }
}
function New-UiLabel([string]$Text) {
    $v=New-Object Windows.Forms.Label;$v.Text=$Text;$v.AutoSize=$true;$v.Dock='Fill';$v.TextAlign='MiddleLeft'
    $v.Margin=New-Object Windows.Forms.Padding(4,7,12,7);Set-ArchiveControlStyle $v;$v
}
function New-UiField([string]$Text='') {
    $v=New-Object Windows.Forms.TextBox;$v.Text=$Text;$v.Dock='Fill';$v.Margin=New-Object Windows.Forms.Padding(4,5,4,5);Set-ArchiveControlStyle $v;$v
}
function New-UiButton([string]$Text) {
    $v=New-Object Windows.Forms.Button;$v.Text=$Text;$v.AutoSize=$true;$v.AutoSizeMode='GrowAndShrink'
    $v.Padding=New-Object Windows.Forms.Padding(12,6,12,6);$v.Margin=New-Object Windows.Forms.Padding(4,4,8,4);Set-ArchiveButtonStyle $v;$v
}
function New-UiCheck([string]$Text) {
    $v=New-Object Windows.Forms.CheckBox;$v.Text=$Text;$v.AutoSize=$true;$v.Margin=New-Object Windows.Forms.Padding(4,7,16,7);Set-ArchiveControlStyle $v;$v
}
function New-UiChoice([object[]]$Items) {
    $v=New-Object Windows.Forms.ComboBox;$v.DropDownStyle='DropDownList';$v.Dock='Fill';$v.Margin=New-Object Windows.Forms.Padding(4,6,4,6)
    $v.Items.AddRange($Items);$v.SelectedIndex=0;Set-ArchiveControlStyle $v;$v
}
function New-UiFlow([object[]]$Controls) {
    $v=New-Object Windows.Forms.FlowLayoutPanel;$v.Dock='Fill';$v.AutoSize=$true;$v.AutoSizeMode='GrowAndShrink';$v.WrapContents=$true
    $v.Margin=New-Object Windows.Forms.Padding(0);foreach ($c in $Controls) { $v.Controls.Add($c) };$v
}
function New-UiPicker($Field,$Button) {
    $t=New-UiTable 2;$t.Dock='Fill';$t.ColumnStyles.Clear()
    $null=$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $null=$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    Add-UiRow $t @($Field,$Button);$t
}
function Add-UiSetting($Table,$Caption,$Control) { $label=New-UiLabel $Caption;$label.MaximumSize=New-Object Drawing.Size(210,0);Add-UiRow $Table @($label,$Control) }
function New-UiPage($Tabs,$Title) {
    $page=New-Object Windows.Forms.TabPage;$page.Text=$Title;$page.Padding=New-Object Windows.Forms.Padding(0)
    $page.AutoScroll=$false;$Tabs.Controls.Add($page)
    $frame=New-UiTable 1;$frame.Dock='Fill';$frame.AutoSize=$false
    $viewport=New-Object Windows.Forms.Panel;$viewport.Dock='Fill';$viewport.AutoScroll=$true;$viewport.Margin=New-Object Windows.Forms.Padding(0)
    $table=New-UiTable 2;$table.ColumnStyles.Clear()
    $null=$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    $null=$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $viewport.Controls.Add($table)
    $actions=New-UiFlow @();$actions.Visible=$false;$actions.Padding=New-Object Windows.Forms.Padding(10,8,10,8)
    $actions.BackColor=ConvertTo-ArchiveColor (Get-ArchiveTheme).Input
    Add-UiRow $frame @($viewport);Add-UiRow $frame @($actions)
    $frame.RowStyles[0].SizeType='Percent';$frame.RowStyles[0].Height=100;$page.Controls.Add($frame)
    [pscustomobject]@{page=$page;table=$table;viewport=$viewport;actions=$actions}
}
function Add-UiActionBar($Page,[object[]]$Controls) {
    foreach($control in $Controls){
        if($control.Parent){$control.Parent.Controls.Remove($control)}
        $control.Dock='None';$Page.actions.Controls.Add($control)
    }
    $Page.actions.Visible=($Page.actions.Controls.Count -gt 0)
}
function Show-UiControl($Control) {
    $ancestor=$Control.Parent
    while($ancestor){
        if($ancestor -is [Windows.Forms.ScrollableControl] -and $ancestor.AutoScroll){$ancestor.ScrollControlIntoView($Control)}
        $ancestor=$ancestor.Parent
    }
    [Windows.Forms.Application]::DoEvents()
}
function New-BurnConfirmationForm([string]$Review,[string]$Expected) {
    $dialog=New-ArchiveForm (Get-ArchiveText 'burn.confirmTitle') 740 550;$dialog.TopMost=$true
    $body=New-UiTable 1;$body.Dock='Fill';$body.AutoSize=$false;$body.Padding=New-Object Windows.Forms.Padding(12)
    $dialog.Controls.Add($body)
    $details=New-UiField $Review;$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical'
    Add-UiRow $body @($details);$body.RowStyles[0].SizeType='Percent';$body.RowStyles[0].Height=100
    Add-UiRow $body @((New-UiLabel (Get-ArchiveText 'burn.typePhrase' -Arguments @(($Expected)))))
    $answer=New-UiField;$ok=New-UiButton (Get-ArchiveText 'burn.confirm');$ok.DialogResult='OK'
    $cancel=New-UiButton (Get-ArchiveText 'action.cancel');$cancel.DialogResult='Cancel';$dialog.CancelButton=$cancel
    Add-UiRow $body @($answer);Add-UiRow $body @((New-UiFlow @($ok,$cancel)))
    Set-ArchiveButtonStyle $ok Danger
    $dialog.ResumeLayout($true)
    [pscustomobject]@{form=$dialog;answer=$answer;confirm=$ok;cancel=$cancel}
}

. (Join-Path $PSScriptRoot 'Archive.Theme.ps1')
