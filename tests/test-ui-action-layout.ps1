[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/action-layout'))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot;$run=[IO.Path]::GetFullPath($WorkRoot);[IO.Directory]::CreateDirectory($run)|Out-Null
$engine=(Get-Process -Id $PID).Path
foreach($lang in @('en','zh-CN')) {
 $report=Join-Path $run ($lang+'.json')
 & $engine -NoProfile -STA -File (Join-Path $root 'scripts/archive-ui.ps1') -Language $lang -SmokeTest -ExerciseActionLayout -ExerciseDryRun -OpticalTestFixture (Join-Path $PSScriptRoot 'optical-fixture.json') -DiagnosticsPath $report
 if($LASTEXITCODE -ne 0){throw 'Action layout UI failed'}
 $r=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
 if($r.action_layout -ne 'PASS' -or $r.dry_run_button_test -ne 'PASS' -or $r.default_execute -or $r.burn_worker_started){throw 'Action layout or safety acceptance failed'}
 Write-Output "PASS $lang fixed action bars, stage order, explicit local-build enable, preview worker"
}
