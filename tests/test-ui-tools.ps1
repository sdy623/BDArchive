[CmdletBinding()]
param([string]$Output)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'ui-layout-assertions.ps1')
function Assert($Value,$Message) { if (!$Value) { throw $Message } }
$c=Load-Config (Join-Path $PSScriptRoot '../archive.config.json')
$before=$c | ConvertTo-Json -Depth 12
$items=@(Get-ArchiveToolInventory $c)
Assert ($items.Count -ge 8) 'Tool inventory missing expected records'
Assert (($c | ConvertTo-Json -Depth 12) -eq $before) 'Read-only inventory changed configuration'
$python=@($items | Where-Object { $_.key -eq 'python' })[0]
Assert ($python.detected -notmatch '[/\\]WindowsApps[/\\]') 'Store alias accepted as Python'
$c.tools.python=Join-Path $env:TEMP ([guid]::NewGuid().ToString('N')+'.missing.exe')
$invalid=@(Get-ArchiveToolInventory $c | Where-Object { $_.key -eq 'python' })[0]
Assert ($invalid.state -eq 'CONFIGURED_MISSING') 'Invalid config silently replaced by discovery'
Assert ($invalid.configured -eq $c.tools.python) 'Configured path was overwritten'
$state=Initialize-ArchiveDpi
try {
    $popup=New-BurnConfirmationForm (('SYNTHETIC REVIEW / 合成测试，未连接光驱。'+[Environment]::NewLine)*40) 'BURN BD-P-TEST'
    try {
        $popup.form.Font=New-Object Drawing.Font('Microsoft YaHei UI',16)
        $popup.form.Show();[Windows.Forms.Application]::DoEvents()
        $popup.form.Size=$popup.form.MinimumSize;[Windows.Forms.Application]::DoEvents()
        Assert-UiLayout $popup.form
        $ctx=[ArchiveNativeDpi]::GetWindowDpiAwarenessContext($popup.form.Handle)
        Assert ([ArchiveNativeDpi]::AreDpiAwarenessContextsEqual($ctx,[IntPtr](-4))) 'Burn dialog is not PMv2 aware'
        Assert ($popup.answer.Text -eq '') 'Burn confirmation answer must be empty'
        Assert ($null -eq $popup.form.AcceptButton) 'No default confirm-on-Enter is allowed'
        foreach ($control in @($popup.answer,$popup.confirm,$popup.cancel)) {
            $r=$popup.form.RectangleToClient($control.RectangleToScreen($control.ClientRectangle))
            Assert ($popup.form.ClientRectangle.Contains($r)) 'Burn confirmation field/buttons not visible'
        }
        $dpi=[ArchiveNativeDpi]::GetDpiForWindow($popup.form.Handle)
        # Cancel the synthetic dialog; never call real burn or accept a phrase.
        $popup.cancel.PerformClick();[Windows.Forms.Application]::DoEvents()
        Assert ($popup.form.DialogResult -eq 'Cancel') 'Cancel button did not cancel'
    } finally { $popup.form.Dispose() }
} finally { Restore-ArchiveDpi $state }
$result=[ordered]@{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();tool_discovery_read_only='PASS';store_alias_excluded='PASS';invalid_config_preserved='PASS';burn_dialog_layout='PASS';burn_dialog_dpi=$dpi;burn_dialog_per_monitor_v2=$true;burn_dialog_cancel='PASS';physical_burn_executed=$false;software_installed=$false}
if ($Output) { Write-Json (Full-Path $Output) $result }
$result | ConvertTo-Json
