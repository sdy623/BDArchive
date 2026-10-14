# Cancellation is enabled only by the structured worker for a prepare request.
$script:PreparationJob=$null
$script:VerificationJob=$null
$script:ArchiveProgressJob=$null
$script:HashProgressScope=$null
$script:HashProgressLastWrite=[DateTime]::MinValue
$script:ProgressWarningShown=$false
function Start-ArchiveProgressContext($RequestPath,[string]$Message='开始任务') {
    # Reporting does not enable preparation cancellation or change copy policy.
    $script:ArchiveProgressJob=@{request=(Full-Path $RequestPath);started=[DateTime]::UtcNow.ToString('o');disc='';last_write=[DateTime]::MinValue}
    Set-PreparationProgress $Message -Force
}
function Start-VerificationContext($RequestPath) {
    Start-ArchiveProgressContext $RequestPath '准备校验光盘'
    $script:VerificationJob=$script:ArchiveProgressJob
}
function Start-PreparationContext($RequestPath) {
    Start-ArchiveProgressContext $RequestPath '准备归档'
    $script:PreparationJob=$script:ArchiveProgressJob
    Set-PreparationProgress '准备归档' '' -Force
}
function Assert-PreparationRunning {
    if ($script:VerificationJob -and [IO.File]::Exists(($script:VerificationJob.request+'.cancel'))) {
        throw [OperationCanceledException]::new('Verification stopped by user. No verification PASS has been issued.')
    }
    if ($script:PreparationJob -and [IO.File]::Exists(($script:PreparationJob.request+'.cancel'))) {
        throw [OperationCanceledException]::new('Preparation stopped by user. Source files and completed discs are retained.')
    }
}
function Is-PreparationCancellation($ErrorRecord) {
    $e=$ErrorRecord.Exception
    while ($e) { if ($e -is [OperationCanceledException]) { return $true };$e=$e.InnerException }
    return $false
}
function Set-PreparationProgress([string]$Message,[string]$ToolLog='', [switch]$Force,[int]$ToolPid=0,[hashtable]$Metrics=$null) {
    if (!$script:ArchiveProgressJob) { return }
    $now=[DateTime]::UtcNow
    if (!$Force -and ($now-$script:ArchiveProgressJob.last_write).TotalMilliseconds -lt 600) { return }
    try { Write-Json ($script:ArchiveProgressJob.request+'.progress.json') @{message=$Message;disc=$script:ArchiveProgressJob.disc;tool_log=$ToolLog;tool_pid=$ToolPid;started=$script:ArchiveProgressJob.started;updated=$now.ToString('o');metrics=$Metrics} }
    catch { Write-ArchiveProgressWarning $_ }
    $script:ArchiveProgressJob.last_write=$now
}
function Set-PreparationDisc($D) {
    if ($script:ArchiveProgressJob) { $script:ArchiveProgressJob.disc="$($D.disc_id) · $($D.position)/$($D.disc_count)" }
}
function Write-ArchiveProgressWarning($ErrorRecord) {
    if (!$script:ProgressWarningShown) {
        $script:ProgressWarningShown=$true
        Write-Warning ("进度显示暂不可用，校验继续；这不是内容校验失败："+$ErrorRecord.Exception.Message)
    }
}
function Set-HashProgress($Path,[int64]$Bytes,[int64]$Length,$Clock,[switch]$Force) {
    # Telemetry is best-effort; its numeric/I/O errors cannot become hash FAIL.
    try { Set-HashProgressCore $Path $Bytes $Length $Clock -Force:$Force }
    catch { if (Is-PreparationCancellation $_) {throw};Write-ArchiveProgressWarning $_ }
}
function Set-HashProgressCore($Path,[int64]$Bytes,[int64]$Length,$Clock,[switch]$Force) {
    $now=[DateTime]::UtcNow
    if (!$Force -and ($now-$script:HashProgressLastWrite).TotalMilliseconds -lt 600) { return }
    $script:HashProgressLastWrite=$now
    $scope=$script:HashProgressScope
    $batch=($scope -and $scope.path -eq $Path)
    $total=if ($batch) { $scope.total_bytes } else { $Length }
    $done=if ($batch) { $scope.completed_bytes+$Bytes } else { $Bytes }
    $rate=if ($Clock.Elapsed.TotalSeconds -ge 0.1) { $Bytes/$Clock.Elapsed.TotalSeconds } else { 0 }
    $percent=if ($total -gt 0) { [Math]::Min([double]100,([double]100*$done/$total)) } else { 0 }
    $metrics=@{phase='SHA256';completed_bytes=$done;total_bytes=$total;file_bytes=$Bytes;file_size=$Length;percent=$percent;
        file_index=$(if ($batch) {$scope.index} else {1});file_count=$(if ($batch) {$scope.count} else {1});
        rate_mib_s=$rate/1MB;eta_seconds=$(if ($rate -gt 0) {[Math]::Ceiling([Math]::Max([double]0,[double]($total-$done))/$rate)} else {$null})}
    $message="SHA-256：$([IO.Path]::GetFileName($Path))"
    if ($script:ArchiveProgressJob) { Set-PreparationProgress $message -Force -Metrics $metrics }
    else { Write-Progress -Id 31 -Activity 'SHA-256 校验' -Status ("{0} · {1:N1}% · {2:N2}/{3:N2} GiB" -f $message,$percent,($done/1GB),($total/1GB)) -PercentComplete ([int]$percent) }
}
function Get-ArchiveProgressView($Progress) {
    # Old workers have no metrics. Keep their native log/elapsed display usable.
    $m=Optional-Field $Progress 'metrics'
    if (!$m -or $m.phase -ne 'SHA256') { return @{determinate=$false;value=0;detail=''} }
    $detail="SHA-256 {0:N1}% · 文件 {1}/{2} · 已读取 {3:N2}/{4:N2} GiB" -f $m.percent,$m.file_index,$m.file_count,($m.completed_bytes/1GB),($m.total_bytes/1GB)
    if ($m.rate_mib_s -gt 0) { $detail+=" · {0:N1} MiB/s" -f $m.rate_mib_s }
    if ($null -ne $m.eta_seconds -and $m.eta_seconds -gt 0) { $detail+=" · 预计剩余 {0:N0} 分钟" -f [Math]::Ceiling($m.eta_seconds/60) }
    @{determinate=$true;value=[int][Math]::Floor([Math]::Max([double]0,[Math]::Min([double]100,[double]$m.percent)));detail=$detail}
}
function Resume-InterruptedOutput($C,$Kind,$Id) {
    # Called under the Archive Set lock. Only our explicit cancellation marker authorizes
    # moving an incomplete directory; ordinary existing output is never replaced.
    $dir=Safe-Join $C.archive_root "$Kind/$Id";$marker=Join-Path $dir 'PREPARATION-CANCELLED.json'
    if (!(Test-Path -LiteralPath $marker)) { return }
    $m=Read-Json $marker
    if ($m.disc_id -cne $Id -or $m.kind -cne $Kind -or $m.status -ne 'CANCELLED') { throw 'Invalid interrupted preparation marker.' }
    $rec=Get-Disc $C $Id
    if (($Kind -eq 'build' -and (Test-Path -LiteralPath (Join-Path $dir 'build.json'))) -or ($Kind -eq 'staging' -and $rec.stage)) { throw 'Completed output must not carry an interruption marker.' }
    $destination=Safe-Join $C.archive_root ('interrupted/'+$Id+'-'+$Kind+'-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory((Split-Path $destination)) | Out-Null
    [IO.Directory]::Move($dir,$destination)
    Event $C 'preserve-interrupted-output' @{disc_id=$Id;path=$destination}
    Write-Host "Incomplete output preserved at $destination; rebuilding this disc."
}
function Mark-InterruptedOutput($C,$Kind,$Id) {
    $dir=Safe-Join $C.archive_root "$Kind/$Id"
    if (!(Test-Path -LiteralPath $dir)) { return }
    $rec=Get-Disc $C $Id
    if (($Kind -eq 'build' -and (Test-Path -LiteralPath (Join-Path $dir 'build.json'))) -or ($Kind -eq 'staging' -and $rec.stage)) { return }
    Write-Json (Join-Path $dir 'PREPARATION-CANCELLED.json') @{status='CANCELLED';kind=$Kind;disc_id=$Id;time=[DateTime]::UtcNow.ToString('o')}
}
function Read-ArchiveLogTail($Path) {
    if (![IO.File]::Exists($Path)) { return '' }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        $null=$reader.Peek();$encoding=$reader.CurrentEncoding
        if ($stream.Length -gt 65536) {
            $reader.DiscardBufferedData();$offset=$stream.Length-65536
            if ($encoding.CodePage -in @(1200,1201)) { $offset-=$offset%2 }
            $null=$stream.Seek($offset,[IO.SeekOrigin]::Begin)
        }
        try { $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
