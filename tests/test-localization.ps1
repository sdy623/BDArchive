[CmdletBinding()]
param([switch]$SkipWinForms)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$passed=0
function Assert-True($Condition,$Name) { if (!$Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
$module=Join-Path $root 'scripts/Archive.Localization.ps1'
Assert-True (Test-Path -LiteralPath $module) 'localization implementation exists'
. $module
Initialize-ArchiveLocale -Language en
Assert-True ((Get-ArchiveText 'app.title') -eq 'BD Archive / Photos, recordings and backups') 'English selection resolves a semantic key'
Assert-True ((Get-ArchiveText 'burn.typePhrase' -Arguments @('BURN BD-P-0009')) -eq 'Type this yourself: BURN BD-P-0009') 'confirmation phrase is unchanged by formatting'
Assert-True ((Translate-ArchiveText '准备归档') -eq 'Prepare archive') 'legacy caption resolves in English'
Assert-True ((Translate-ArchiveText 'F:\照片\原片.CR2') -eq 'F:\照片\原片.CR2') 'unknown user path is preserved exactly'
Assert-True ((Get-ArchiveText 'unknown.key') -eq 'unknown.key') 'unknown semantic key has a visible fallback'
Assert-True ((Get-ArchiveText 'unknown.key' -Fallback 'safe fallback') -eq 'safe fallback') 'caller can supply explicit fallback'
Assert-True ($env:BD_ARCHIVE_LANGUAGE -eq 'en') 'worker language is propagated without protocol changes'
Initialize-ArchiveLocale -Language zh-CN
Assert-True ((Get-ArchiveText 'burn.typePhrase' -Arguments @('BURN BD-P-0009')) -eq '请亲自输入：BURN BD-P-0009') 'Chinese confirmation preserves the exact BURN token'
Assert-True ((Translate-ArchiveText 'Prepare archive') -eq '准备归档') 'English caption can switch back to Chinese'
$dynamicKey=Get-ArchiveLocaleKey '运行中：{0}。完成后刷新盘目录。'
$dynamic=Get-ArchiveText $dynamicKey -Arguments @('F:\相片\{RAW}.CR2')
Initialize-ArchiveLocale -Language en
Assert-True ((Translate-ArchiveText $dynamic) -eq 'Running: F:\相片\{RAW}.CR2. The disc catalog will refresh when finished.') 'dynamic caption switches language without parsing or translating its arguments'
Initialize-ArchiveLocale -Language xx-INVALID
Assert-True ((Get-ArchiveText 'action.prepare') -eq 'Prepare archive') 'unsupported language falls back to English'
Initialize-ArchiveLocale -Language zh-CN
$en=Get-Content -LiteralPath (Join-Path $root 'locales/en.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$zh=Get-Content -LiteralPath (Join-Path $root 'locales/zh-CN.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ek=@($en.PSObject.Properties.Name | Sort-Object);$zk=@($zh.PSObject.Properties.Name | Sort-Object)
Assert-True (($ek -join '|') -ceq ($zk -join '|')) 'English and Chinese keys are identical'
foreach($key in $ek) {
    $a=@([regex]::Matches([string]$en.$key,'\{[a-zA-Z0-9_]+\}') | ForEach-Object Value | Sort-Object)
    $b=@([regex]::Matches([string]$zh.$key,'\{[a-zA-Z0-9_]+\}') | ForEach-Object Value | Sort-Object)
    Assert-True (($a -join '|') -ceq ($b -join '|')) "placeholder parity: $key"
}
if (!$SkipWinForms) {
    Add-Type -AssemblyName System.Windows.Forms
    $form=New-Object Windows.Forms.Form
    try {
        $button=New-Object Windows.Forms.Button;$button.Text='准备归档';$form.Controls.Add($button)
        $box=New-Object Windows.Forms.TextBox;$box.Text='准备归档';$form.Controls.Add($box)
        $combo=New-Object Windows.Forms.ComboBox;$combo.DropDownStyle='DropDownList';$combo.Items.AddRange(@('不生成 PAR2','5% PAR2','10% PAR2'));$combo.SelectedIndex=2;$form.Controls.Add($combo)
        $grid=New-Object Windows.Forms.DataGridView;$null=$grid.Columns.Add('disc_id','盘号');$form.Controls.Add($grid)
        Initialize-ArchiveLocale -Language en;Update-ArchiveControlLocale $form
        Assert-True ($button.Text -eq 'Prepare archive') 'live control caption translated'
        Assert-True ($box.Text -eq '准备归档') 'editable textbox never translated even when text matches a caption'
        Assert-True ($combo.SelectedIndex -eq 2) 'choice semantic index survives locale switch'
        Assert-True ($combo.Items[0] -eq 'No PAR2') 'choice display translated without changing ordering'
        Assert-True ($grid.Columns[0].HeaderText -eq 'Disc ID' -and $grid.Columns[0].Name -eq 'disc_id') 'grid heading translated while data key is preserved'
        Initialize-ArchiveLocale -Language zh-CN;Update-ArchiveControlLocale $form
        $combo.SelectedIndex=0;$script:selectionChanges=0
        $combo.Add_SelectedIndexChanged({$script:selectionChanges++})
        Initialize-ArchiveLocale -Language en;Update-ArchiveControlLocale $form
        Assert-True ($combo.Text -eq 'No PAR2') 'selected choice caption refreshes visibly'
        Assert-True ($script:selectionChanges -eq 0) 'locale switch does not fire a semantic selection change'
        Initialize-ArchiveLocale -Language zh-CN;Update-ArchiveControlLocale $form
        Assert-True ($combo.Text -eq '不生成 PAR2') 'selected caption visibly restores Chinese'
        $combo.SelectedIndex=2
        Assert-True ($button.Text -eq '准备归档' -and $combo.SelectedIndex -eq 2) 'Chinese switch restores captions and preserves input selection'
    } finally { $form.Dispose() }
}
Write-Output "LOCALIZATION PASS: $passed checks"
