# Sourced only by archive-ui.ps1 -SmokeTest. Rendering test, no worker is started.
$fixture=Read-Json (Full-Path $VerifyTestRequestPath)
if ($fixture.command -ne 'verify' -or !$fixture.parameters.Simulate) {throw 'Only a synthetic verification request is accepted.'}
$script:jobPath=Full-Path ($VerifyTestRequestPath+'.ui');$script:jobCommand='verify';$script:jobStarted=[DateTime]::UtcNow
Write-Text ($script:jobPath+'.log') 'Synthetic GUI progress rendering test; no optical reads.'
$captured=Read-Json ($VerifyTestRequestPath+'.ui-progress.json')
Write-Json ($script:jobPath+'.progress.json') $captured
$script:worker=[Diagnostics.Process]::GetCurrentProcess()
try {
    Update-ArchiveJob;[Windows.Forms.Application]::DoEvents()
    if ($jobProgress.Style -ne 'Continuous' -or $jobProgress.Value -le 0 -or $jobProgress.Value -ge 100 -or $progressDetail.Text -notmatch 'GiB') {throw 'Captured live SHA-256 progress was not displayed.'}
    if ($stopPrepare.Enabled) {throw 'Verification accidentally enabled preparation cancellation.'}
    foreach ($control in @($jobProgress,$progressDetail)) {
        $bounds=$form.RectangleToClient($control.RectangleToScreen($control.ClientRectangle))
        if (!$form.ClientRectangle.Contains($bounds)) {throw 'Verification progress lies outside viewport.'}
    }
    Assert-UiLayout $form
    if ($PreviewPath) {
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Full-Path ($VerifyTestRequestPath+'.sha256.png')))} finally {$bitmap.Dispose()}
    }
    Write-Json ($script:jobPath+'.progress.json') @{message='DwarFS 内部完整性检查（工具不提供百分比）';disc='BD-P-0001';tool_log='';metrics=$null}
    Update-ArchiveJob;[Windows.Forms.Application]::DoEvents()
    if ($jobProgress.Style -ne 'Marquee' -or $progressDetail.Text -ne '' -or $status.Text -notmatch 'DwarFS') {throw 'Internal check displayed stale SHA-256 percent.'}
    if ($deepVerify.Checked) {throw 'Extra DwarFS check must default off.'}
    $stopPrepare.Enabled=$true;$stopPrepare.Text='停止校验';$stopPrepare.PerformClick()
    if (!$script:stopRequested -or $stopPrepare.Enabled -or ![IO.File]::Exists($script:jobPath+'.cancel') -or $status.Text -notmatch '正在停止校验') {throw 'Stop verification button did not request cancellation.'}
    $diagnostics.stop_verification_button='PASS'
    $diagnostics.verification_progress='PASS';$diagnostics.verification_progress_source='captured same-pass synthetic-file hash';$diagnostics.native_verification_indeterminate='PASS'
} finally {$script:worker.Dispose();$script:worker=$null;$script:jobPath=$null}
