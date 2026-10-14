[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/ui-language'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$run=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($run)|Out-Null
$cfg=Get-Content -Raw -LiteralPath (Join-Path $root 'archive.config.example.json')|ConvertFrom-Json
$cfg.archive_root=Join-Path $run 'archive';$cfg.catalog_path=Join-Path $run 'archive/catalog.sqlite'
$configPath=Join-Path $run 'config.json';$cfg|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $configPath -Encoding UTF8
$engine=(Get-Process -Id $PID).Path
foreach($language in @('en','zh-CN')) {
    $report=Join-Path $run ($language+'.json')
    $args=@('-NoProfile','-STA','-File',(Join-Path $root 'scripts/archive-ui.ps1'),'-Config',$configPath,'-Language',$language,'-SmokeTest','-ExerciseLanguageSwitch','-ExerciseDryRun','-OpticalTestFixture',(Join-Path $root 'tests/optical-fixture.json'),'-DiagnosticsPath',$report)
    & $engine @args 1> (Join-Path $run ($language+'.stdout.txt')) 2> (Join-Path $run ($language+'.stderr.txt'))
    if($LASTEXITCODE -ne 0) {Get-Content (Join-Path $run ($language+'.stderr.txt'));throw "UI $language failed; see $run"}
    $result=Get-Content -Raw -LiteralPath $report|ConvertFrom-Json
    if($result.status -ne 'PASS' -or $result.language -ne $language -or $result.language_switch -ne 'PASS') {throw 'Locale switch did not preserve selected language and user fields'}
    if($result.default_execute -or $result.burn_worker_started -or $result.dry_run_button_test -ne 'PASS') {throw 'Language UI changed dry-run safety'}
    if($language -eq 'en' -and ($result.pages.page -join '') -match '[\u4e00-\u9fff]') {throw 'English page navigation still contains untranslated captions'}
    if(Test-Path -LiteralPath $cfg.archive_root) {throw 'Preview unexpectedly created archive data'}
    Write-Output "PASS $language : language switch, preserved data, optical dropdown and dry-run worker"
}
