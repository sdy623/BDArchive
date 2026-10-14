function Get-ImgBurnOutcome([string]$Text,[string]$Project,[int]$ExitCode) {
    # ImgBurn can return 0 after cancelling its build confirmation. Bind logs
    # to this unique project, never infer success from exit code or blank media.
    $sessions=@([regex]::Split($Text,'(?m)(?=^I \d\d:\d\d:\d\d ImgBurn Version .* started!)') | Where-Object {
        $_ -match ('(?m)^I \d\d:\d\d:\d\d File Name: '+[regex]::Escape($Project)+'\r?$')
    })
    if ($sessions.Count -ne 1) { return @{result='UNKNOWN';retry_allowed=$false;exit_code=$ExitCode;reason='缺少唯一匹配的 ImgBurn 会话日志'} }
    $session=$sessions[0]
    if ([regex]::Matches($session,'(?m)^I \d\d:\d\d:\d\d File Name: ').Count -ne 1) { return @{result='UNKNOWN';retry_allowed=$false;exit_code=$ExitCode;reason='同一会话加载了多个项目，无法绑定本次结果'} }
    if ($session -notmatch '(?m)^I \d\d:\d\d:\d\d ImgBurn closed!\r?$') { return @{result='UNKNOWN';retry_allowed=$false;exit_code=$ExitCode;reason='ImgBurn 会话未完整结束'} }
    $writeIntent=$session -match '(?im)^. \d\d:\d\d:\d\d (Destination Device:|Writing |Synchronising Cache|Closing Track|Finalising Disc)'
    $written=$session -match '(?s)Writing Track .*?Finalising Disc.*?Operation Successfully Completed!.*?Average Write Rate:'
    if ($written) { return @{result='WRITTEN';retry_allowed=$false;exit_code=$ExitCode;reason='日志确认写入完成'} }
    if (!$writeIntent -and $session -match 'Operation Aborted!') { return @{result='CANCELLED_BEFORE_WRITE';retry_allowed=$true;exit_code=$ExitCode;reason='在准备映像时取消，尚未开始写盘'} }
    if (!$writeIntent -and $ExitCode -eq 1 -and $session -match 'Operation Failed!') { return @{result='NOT_STARTED';retry_allowed=$true;exit_code=$ExitCode;reason='操作未能开始'} }
    # ImgBurn also exits 0 when the image-preparation dialog completes and the
    # user closes the application before starting the separate device operation.
    # Recognize the complete, ordered build-only lifecycle; absence of Writing
    # alone, a success line alone, or the current blank medium is not evidence.
    $buildOnly='(?ms)^I \d\d:\d\d:\d\d Operation Started!\r?$.*?^I \d\d:\d\d:\d\d Building Image Tree\.\.\.\r?$.*?^I \d\d:\d\d:\d\d Preparing Image\.\.\.\r?$.*?^I \d\d:\d\d:\d\d Image Sectors: [0-9,]+\r?$.*?^I \d\d:\d\d:\d\d Operation Successfully Completed! - Duration: [0-9:]+\r?$.*?^I \d\d:\d\d:\d\d Close Request Acknowledged\r?$.*?^I \d\d:\d\d:\d\d Closing Down\.\.\.\r?$.*?^I \d\d:\d\d:\d\d Shutting down SPTI\.\.\.\r?$.*?^I \d\d:\d\d:\d\d ImgBurn closed!\r?$'
    $starts=[regex]::Matches($session,'(?m)^I \d\d:\d\d:\d\d Operation Started!\r?$').Count
    $successes=[regex]::Matches($session,'(?m)^I \d\d:\d\d:\d\d Operation Successfully Completed!').Count
    if (!$writeIntent -and $ExitCode -eq 0 -and $starts -eq 1 -and $successes -eq 1 -and $session -match $buildOnly) {
        return @{result='NOT_STARTED';retry_allowed=$true;exit_code=$ExitCode;reason='仅完成映像准备后关闭 ImgBurn，未进入写入阶段'}
    }
    @{result='UNKNOWN';retry_allowed=$false;exit_code=$ExitCode;reason='可能已开始写入；保留记录供检查'}
}
function Read-BurnOutcome($Burn) {
    $native=Optional-Field $Burn 'native_log';$project=Optional-Field $Burn 'project';$exitCode=Optional-Field $Burn 'exit_code'
    if (!$native -or !$project -or $null -eq $exitCode -or !(Test-Path -LiteralPath $native)) { return @{result='UNKNOWN';retry_allowed=$false;reason='旧记录需导入匹配的 ImgBurn 日志'} }
    $expected=Optional-Field $Burn 'native_log_sha256'
    if ($expected -and (File-Hash $native) -cne $expected) { return @{result='UNKNOWN';retry_allowed=$false;reason='ImgBurn 原生日志已变化'} }
    Get-ImgBurnOutcome ([IO.File]::ReadAllText($native)) $project ([int]$exitCode)
}
function Import-LegacyBurnEvidence($C,$Record) {
    if (!$Record.burn -or $Record.burn.simulation -or (Optional-Field $Record.burn 'native_log')) { return }
    # v1.8.1 recorded a unique /SRC job and process times but no native log path.
    # Bind that invocation to the recorded attempt, then take an immutable local
    # snapshot of ImgBurn's rolling log. A different blank disc is not evidence.
    $start=Convert-ArchiveUtcTime $Record.burn.time
    if (!$Record.burn_date) { return }
    $end=Convert-ArchiveUtcTime $Record.burn_date
    $candidates=@(Get-ChildItem -LiteralPath (Join-Path $C.archive_root 'logs') -Filter '*-imgburn-*.log.json' | ForEach-Object {
        $inv=Read-Json $_.FullName;$a=@($inv.arguments);$si=[Array]::IndexOf($a,'/SRC');$di=[Array]::IndexOf($a,'/DEST')
        if ($si -lt 0 -or $di -lt 0 -or $si+1 -ge $a.Count -or $di+1 -ge $a.Count) { return }
        $t=Convert-ArchiveUtcTime $inv.time;$project=[string]$a[$si+1]
        $jobs=(Full-Path (Join-Path $C.archive_root 'images')).TrimEnd('\')+'\'+$Record.disc_id+'-'
        if ($t -ge $start -and [math]::Abs(($end-$t).TotalSeconds) -le 10 -and $project.StartsWith($jobs,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($project) -eq 'disc.ibb' -and $a[$di+1] -eq $Record.burn.drive) {
            @{project=$project;exit_code=$inv.exit_code;invocation=$_.FullName}
        }
    })
    if ($candidates.Count -ne 1) { return }
    $rolling=Join-Path $env:APPDATA 'ImgBurn/Log Files/ImgBurn.log'
    if (!(Test-Path -LiteralPath $rolling)) { return }
    $logText=[IO.File]::ReadAllText($rolling);$e=$candidates[0]
    $outcome=Get-ImgBurnOutcome $logText $e.project ([int]$e.exit_code)
    if ($outcome.result -eq 'UNKNOWN') { return }
    $snapshot=Join-Path $C.archive_root ('reports/'+$Record.disc_id+'-legacy-imgburn-'+[guid]::NewGuid().ToString('N')+'.log')
    Write-Text $snapshot $logText
    foreach ($field in @{project=$e.project;native_log=$snapshot;native_log_sha256=(File-Hash $snapshot);exit_code=$e.exit_code;outcome=$outcome;legacy_invocation=$e.invocation}.GetEnumerator()) { $Record.burn | Add-Member NoteProperty $field.Key $field.Value -Force }
    if ($outcome.result -eq 'WRITTEN') { $Record.burn.result='WRITTEN' }
    Update-Disc $C $Record
    Event $C 'legacy-burn-evidence' @{disc_id=$Record.disc_id;outcome=$outcome;native_log=$snapshot}
}
function Reset-UnwrittenBurn($C,$Record,$Outcome) {
    if (!$Record.burn -or $Record.burn.simulation -or !$Outcome.retry_allowed -or $Outcome.result -notin @('CANCELLED_BEFORE_WRITE','NOT_STARTED')) { throw 'Only a confirmed unwritten attempt can return to staging.' }
    if ($Record.verification -or $Record.burn.result -eq 'WRITTEN') { throw 'Written/verified disc records cannot be reset.' }
    $Record.burn | Add-Member NoteProperty outcome $Outcome -Force
    $Record.burn.result=$Outcome.result
    $history=@(Optional-Field $Record 'burn_history' | Where-Object { $null -ne $_ })+@($Record.burn)
    $Record | Add-Member NoteProperty burn_history $history -Force
    $Record.burn=$null;$Record.status='STAGED';$Record.burn_date=$null
    Update-Disc $C $Record;Event $C 'burn-cancelled-before-write' @{disc_id=$Record.disc_id;outcome=$Outcome}
    Write-Host '尚未写入，已返回待刻状态；可使用同一盘号重新刻录。'
}
function Recover-UnwrittenBurn($C,$P) {
    $record=Get-Disc $C $P.DiscId
    if (!$record.burn) { return @{status='STAGED';disc_id=$record.disc_id} }
    Import-LegacyBurnEvidence $C $record
    $outcome=Read-BurnOutcome $record.burn
    if (!$outcome.retry_allowed) { throw "无法自动恢复待刻：$($outcome.reason)" }
    Reset-UnwrittenBurn $C $record $outcome
    @{status='STAGED';disc_id=$record.disc_id;outcome=$outcome}
}

function Get-SimulationRootInfo($C,$Record) {
    if (!$Record.burn -or ![bool](Optional-Field $Record.burn 'simulation')) { throw '此盘没有可清除的模拟写入记录。' }
    foreach ($field in @('drive','project','native_log')) {
        if (Optional-Field $Record.burn $field) { throw '模拟记录混有实体刻录证据；保留现状供检查。' }
    }
    $result=[string](Optional-Field $Record.burn 'result')
    if ($result -in @('STARTED','WRITTEN','UNKNOWN')) { throw '记录表示可能已开始实体写入；保留现状供检查。' }
    $verification=Optional-Field $Record 'verification'
    if ($verification -and ![bool](Optional-Field $verification 'simulation')) { throw '记录混有实体光盘校验证据；保留现状供检查。' }
    $lastAttempt=Optional-Field $Record 'last_verification_attempt'
    if ($lastAttempt -and ![bool](Optional-Field $lastAttempt 'simulation')) { throw '记录混有实体光盘校验尝试；保留现状供检查。' }

    $base=Full-Path (Join-Path $C.archive_root 'simulated')
    $rootText=[string](Optional-Field $Record.burn 'root')
    if ([string]::IsNullOrWhiteSpace($rootText)) { throw '模拟记录缺少派生目录路径；保留现状供检查。' }
    $root=Full-Path $rootText
    $parent=[IO.Directory]::GetParent($root)
    if (!$parent -or !$parent.FullName.Equals($base,[StringComparison]::OrdinalIgnoreCase)) { throw "拒绝清理模拟目录边界以外的路径：$root" }
    $leaf=[IO.Path]::GetFileName($root)
    if (!$leaf.Equals($Record.disc_id,[StringComparison]::OrdinalIgnoreCase) -and
        !$leaf.StartsWith(($Record.disc_id+'-'),[StringComparison]::OrdinalIgnoreCase)) { throw '模拟目录名称与盘号不匹配；保留现状供检查。' }
    Assert-NoLinks $root
    $exists=Test-Path -LiteralPath $root -PathType Container
    [int64]$bytes=0;[int64]$files=0
    if ($exists) {
        foreach ($file in (Tree-Files $root)) { $files++;$bytes+=[int64]$file.Length }
    } elseif (Test-Path -LiteralPath $root) { throw '模拟路径不是目录；保留现状供检查。' }
    [pscustomobject]@{root=$root;base=$base;exists=$exists;file_count=$files;bytes=$bytes}
}

function Simulation-ClearPreview($C,$P) {
    $record=Get-Disc $C $P.DiscId
    $info=Get-SimulationRootInfo $C $record
    [pscustomobject]@{
        status='DRY_RUN';action='clear-simulation';disc_id=$record.disc_id;archive_set_id=$record.archive_set_id
        previous_status=$record.status;root=$info.root;root_exists=$info.exists;file_count=$info.file_count;bytes=$info.bytes
        stage_path=$(if ($record.stage) {$record.stage.path} else {$null})
        note='只清除本机 simulated 目录中的派生副本和模拟状态；待刻目录、源文件、清单、盘号及实体刻录证据不变。'
    }
}

function Clear-ArchiveSimulation($C,$P) {
    $record=Get-Disc $C $P.DiscId
    $info=Get-SimulationRootInfo $C $record
    if (!$record.stage -or !(Test-Path -LiteralPath $record.stage.path -PathType Container)) { throw '待刻目录缺失；先保留模拟副本并检查归档状态。' }

    $reason=[string](Optional-Field $P 'Reason')
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason='USER_REQUESTED_SIMULATION_CLEAR' }
    $time=[DateTime]::UtcNow.ToString('o')
    $journalDir=Safe-Join $C.archive_root 'maintenance/simulation-clear'
    [IO.Directory]::CreateDirectory($journalDir) | Out-Null
    $journal=Join-Path $journalDir ($record.disc_id+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')+'-'+[guid]::NewGuid().ToString('N')+'.json')
    $original=[pscustomobject]@{
        burn=$record.burn;status=$record.status;burn_date=(Optional-Field $record 'burn_date')
        verification=(Optional-Field $record 'verification');last_verification_attempt=(Optional-Field $record 'last_verification_attempt')
        registered=[bool](Optional-Field $record 'registered');location=(Optional-Field $record 'location')
    }
    Write-Json $journal ([pscustomobject]@{schema_version=1;status='PREPARED';time=$time;reason=$reason;disc_id=$record.disc_id;archive_set_id=$record.archive_set_id;simulation=$info;original_record_fields=$original})

    if ($info.exists) {
        Remove-Item -LiteralPath $info.root -Recurse -Force
        if (Test-Path -LiteralPath $info.root) { throw '模拟目录删除后仍然存在；目录记录尚未更改。' }
    }

    $history=@(Optional-Field $record 'simulation_history' | Where-Object { $null -ne $_ })
    $history+=,[pscustomobject]@{cleared_at=$time;reason=$reason;root=$info.root;root_existed=$info.exists;file_count=$info.file_count;bytes=$info.bytes;journal=$journal;original=$original}
    $record | Add-Member NoteProperty simulation_history $history -Force
    $record.burn=$null;$record.burn_date=$null;$record.verification=$null
    $record | Add-Member NoteProperty last_verification_attempt $null -Force
    if ([bool](Optional-Field $record 'registered')) { $record.location='' }
    $record.registered=$false;$record.status='STAGED'
    Update-Disc $C $record
    Write-Json $journal ([pscustomobject]@{schema_version=1;status='COMPLETE';time=$time;reason=$reason;disc_id=$record.disc_id;archive_set_id=$record.archive_set_id;simulation=$info;original_record_fields=$original;resulting_status='STAGED'})
    Event $C 'simulation-cleared' @{disc_id=$record.disc_id;reason=$reason;root=$info.root;root_existed=$info.exists;file_count=$info.file_count;bytes=$info.bytes;journal=$journal}
    [pscustomobject]@{status='STAGED';disc_id=$record.disc_id;archive_set_id=$record.archive_set_id;deleted_root=$info.root;root_existed=$info.exists;deleted_files=$info.file_count;deleted_bytes=$info.bytes;journal=$journal;stage_path=$record.stage.path}
}
