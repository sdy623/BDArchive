[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/resume'),[switch]$Gui)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.example.json'))
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite'
$c.numbering.volume_templates.iso9660='{disc_id}-{volume_id}';$c.numbering.volume_templates.application='CHANGED DEFAULT'
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$source=Join-Path $run 'source';Write-Text (Join-Path $source 'one.RAW') 'synthetic'
$p=@{Config=$cfg;Execute=$true;SetId='OLD-PHOTO';Scenario='photo';Source=$source;Media='BD25';ParPercent=10;VolumeTemplates=@{iso9660='';joliet='';system='';volume_set='';publisher='';data_preparer='';application=''}}
$null=Invoke-Archive init $p;$null=Invoke-Archive scan $p;$null=Invoke-Archive plan $p
$path=Join-Path (Set-Dir $c $p.SetId) 'plan.json';$plan=Read-Json $path
$plan.PSObject.Properties.Remove('volume_templates');$plan.PSObject.Properties.Remove('volume_label_template');Write-Json $path $plan
$planHash=File-Hash $path;$catHash=File-Hash (Catalog-Path $c)
$saved=Get-SavedPreparationSettings $c $p.SetId
if ($saved.parameters.ParPercent -ne 10 -or $saved.parameters.VolumeTemplates.iso9660 -ne '' -or $saved.parameters.VolumeTemplates.application -ne '' -or $saved.parameters.StartDiscId -ne 'BD-P-0001') { throw 'Legacy saved settings merged new defaults.' }
# Deliberate mismatches remain rejected; loading does not weaken immutability.
$bad=$p.Clone();$bad.VolumeTemplates=@{iso9660='{disc_id}'};$rejected=$false
try { $null=Invoke-Archive prepare $bad } catch { $rejected=$_.Exception.Message -match 'Volume metadata template differs' }
if (!$rejected) { throw 'Explicit mismatch was accepted.' }
$ready=$saved.parameters.Clone();$ready.Config=$cfg;$ready.Execute=$true
$request=Join-Path $run 'stop.json';Start-PreparationContext $request;Write-Text ($request+'.cancel') 'test stop after resume validation'
$cancelled=$false;try { $null=Invoke-Archive prepare $ready } catch { $cancelled=Is-PreparationCancellation $_ }
& (Get-Module Archive.Core) { $script:PreparationJob=$null }
if (!$cancelled) { throw 'Loaded settings did not pass immutable resume checks.' }
if ($Gui) {
    & (Join-Path $PSScriptRoot '../scripts/archive-ui.ps1') -Config $cfg -SmokeTest -ExerciseResumeSettings -ResumeSetId $p.SetId -ExerciseDryRun -DiagnosticsPath (Join-Path $run 'gui.json') -TestNarrowWindow
    $ui=Read-Json (Join-Path $run 'gui.json');if ($ui.resume_settings -ne 'PASS') { throw 'UI did not load and send saved parameters.' }
}
if ((File-Hash $path) -ne $planHash -or (File-Hash (Catalog-Path $c)) -ne $catHash) { throw 'Read-only loading changed the saved plan or catalog.' }
# Simulate a missing legacy set directory by moving only this isolated fixture.
$setDir=Set-Dir $c $p.SetId;$removed=Safe-Join $run 'removed-fixture';[IO.Directory]::Move($setDir,$removed)
$rejected=$false;try { $null=Invoke-Archive scan $p } catch { $rejected=$_.Exception.Message -match 'already exists in catalog' }
if (!$rejected -or (Test-Path $setDir) -or (File-Hash (Catalog-Path $c)) -ne $catHash) { throw 'Missing set files permitted duplicate catalog records.' }
$rejected=$false;try { $null=Get-SavedPreparationSettings $c $p.SetId } catch { $rejected=$_.Exception.Message -match '原计划或扫描清单不存在' }
if (!$rejected) { throw 'Missing saved files did not produce a recoverable message.' }
Write-Json (Join-Path $run 'resume-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();legacy_empty_templates='PASS';saved_parity_and_ids='PASS';strict_conflict_rejection='PASS';loaded_resume_validation='PASS';read_only_hashes='PASS';orphan_catalog_rejection='PASS';missing_plan_message='PASS';gui=[bool]$Gui;physical_burn=$false}
Write-Host "PASS resume settings and orphan catalog handling: $run"
