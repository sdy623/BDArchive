<# Synthetic UI process only: no catalog, recorder, media or burn API. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$request=Read-Json $RequestPath;$dpi=Initialize-ArchiveDpi
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SyntheticReviewWindow {
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@
$popup=New-BurnConfirmationForm 'TEST ONLY / 合成界面测试。未连接光驱，不会刻录。窗口会自动取消。' 'BURN SYNTHETIC-TEST'
$popup.form.Text='TEST ONLY — 确认窗口显示测试'
$timer=New-Object Windows.Forms.Timer;$timer.Interval=500
$script:fixtureError=$null;$script:fixtureData=$null
$timer.Add_Tick({
    $timer.Stop()
    try {
        $visible=[SyntheticReviewWindow]::IsWindowVisible($popup.form.Handle)
        if ($popup.answer.Text -ne '' -or $null -ne $popup.form.AcceptButton) { throw 'Synthetic confirmation must start empty, without a default accept action.' }
        $script:fixtureData=@{status='PASS';window_visible=$visible;expected_visible=$request.expected_visible;answer_empty=$true;physical_burn=$false;pid=$PID;powershell=$PSVersionTable.PSVersion.ToString()}
        if ($null -ne $request.expected_visible -and $visible -ne [bool]$request.expected_visible) { throw 'Native dialog visibility differs from the requested startup mode.' }
    } catch { $script:fixtureError=$_ }
    finally {
        # This fixture owns its synthetic form. No production dialog is touched.
        $popup.form.DialogResult='Cancel';$popup.form.Close()
    }
})
try {
    $timer.Start();$result=$popup.form.ShowDialog()
    if ($script:fixtureError) { throw $script:fixtureError }
    if ($result -ne 'Cancel') { throw 'Synthetic dialog was not cancelled.' }
    $script:fixtureData.cancelled=$true;Write-Json $request.output $script:fixtureData
} finally { $timer.Dispose();$popup.form.Dispose();Restore-ArchiveDpi $dpi }
