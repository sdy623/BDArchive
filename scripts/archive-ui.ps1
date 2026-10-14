<# Responsive DPI-aware GUI. Archive algorithms stay in the PowerShell backend. #>
[CmdletBinding()]
param([switch]$LegacyUi,[switch]$NoOpen,[ValidateRange(1024,65535)][int]$Port=18765,[ValidateSet('en','zh-CN')][string]$Language,[switch]$ExerciseLanguageSwitch,[switch]$ExerciseActionLayout,[string]$Config,[switch]$SmokeTest,[string]$PreviewPath,[switch]$ExerciseDryRun,
    [ValidateRange(1.0,3.0)][double]$TestScale=1.0,[ValidateRange(0,5)][int]$PreviewTab=0,
    [string]$DiagnosticsPath,[switch]$TestNarrowWindow,[switch]$ExerciseIdPreview,[switch]$ExerciseTemplatePreview,
    [switch]$ExerciseConcurrentJobs,[string]$ConcurrentTestFixture,
    [switch]$ExerciseExternalStage,[string]$ExternalTestFixture,
    [switch]$ExercisePreparationStop,[string]$StopTestRequestPath,[switch]$ExerciseVerificationProgress,[string]$VerifyTestRequestPath,
    [switch]$ExerciseResumeSettings,[string]$ResumeSetId,[switch]$ExerciseRenamePreview,[string]$RenameTestDiscId,[string]$OpticalTestFixture)
$ErrorActionPreference='Stop'
# Default to the React workbench. The original GUI is an explicit compatibility
# option; existing isolated legacy SmokeTest checks remain available.
if (!$LegacyUi -and !$SmokeTest) {
    & (Join-Path $PSScriptRoot 'start-workbench.ps1') -Config $Config -Language $Language -Port $Port -NoOpen:$NoOpen
    return
}
if ($ExerciseExternalStage -and (!$SmokeTest -or !$ExternalTestFixture)) {throw 'External stage UI test requires an isolated fixture.'}
if ($ExerciseConcurrentJobs -and (!$SmokeTest -or !$ConcurrentTestFixture)) {throw 'Concurrency UI test requires an isolated fixture.'}
if ($OpticalTestFixture -and !$SmokeTest) { throw 'Synthetic optical data is only accepted in SmokeTest.' }
if (($ExerciseLanguageSwitch -or $ExerciseActionLayout) -and !$SmokeTest) {throw 'Language switch exercise requires SmokeTest.'}
if (!$Config) {
    $Config=Join-Path $PSScriptRoot '../archive.config.json'
    if (![IO.File]::Exists($Config)) {
        # Fresh public checkout: provision only an ignored configuration, never an archive.
        try {[IO.File]::Copy((Join-Path $PSScriptRoot '../archive.config.example.json'),$Config,$false)}
        catch {if (![IO.File]::Exists($Config)) {throw}}
    }
}
if (($TestScale -ne 1.0 -or $TestNarrowWindow) -and !$SmokeTest) { throw 'Layout test parameters require SmokeTest; they are not Windows display settings.' }
if ($ExercisePreparationStop -and (!$SmokeTest -or !$StopTestRequestPath)) { throw 'Preparation stop exercise requires SmokeTest and an isolated fixture request.' }
if ($ExerciseVerificationProgress -and (!$SmokeTest -or !$VerifyTestRequestPath)) { throw 'Verification progress exercise requires SmokeTest and an isolated simulation request.' }
if ($ExerciseRenamePreview -and (!$SmokeTest -or !$RenameTestDiscId)) { throw 'Rename preview exercise requires SmokeTest and a fixture disc ID.' }
Import-Module (Join-Path $PSScriptRoot 'Archive.Core.psm1') -Force -DisableNameChecking
if (!$Language) {
    $saved=Read-Json $Config;$preferredLanguage=$null
    if ($saved.PSObject.Properties['ui'] -and $saved.ui.PSObject.Properties['language']) {$preferredLanguage=[string]$saved.ui.language}
    if (!$preferredLanguage) {$preferredLanguage=$env:BD_ARCHIVE_LANGUAGE}
    $Language=if ($preferredLanguage -in @('en','zh-CN')) {$preferredLanguage} else {'en'}
}
Initialize-ArchiveLocale -Language $Language
$dpiState=Initialize-ArchiveDpi
$script:configPath=Full-Path $Config;$script:worker=$null;$script:jobPath=$null
$form=New-ArchiveForm (Get-ArchiveText 'app.title') 1180 850
$root=New-UiTable 1;$root.Dock='Fill';$root.AutoSize=$false;$root.Padding=New-Object Windows.Forms.Padding(12)
$form.Controls.Add($root)
$tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';$tabs.Multiline=$true;Add-UiRow $root @($tabs)
$root.RowStyles[0].SizeType='Percent';$root.RowStyles[0].Height=78
$status=New-UiLabel (Get-ArchiveText 'legacy.0b81eb43a250');$status.AutoSize=$false;$status.AutoEllipsis=$true
$stopPrepare=New-UiButton (Get-ArchiveText 'action.stopPreparation');$stopPrepare.Enabled=$false;$stopPrepare.Visible=$false
$jobPanel=New-UiTable 2
$jobChoice=New-Object Windows.Forms.ComboBox;$jobChoice.DropDownStyle='DropDownList';$jobChoice.Visible=$false;$jobChoice.Dock='Fill';$jobChoice.Margin=New-Object Windows.Forms.Padding(4,4,4,8)
Add-UiRow $jobPanel @($jobChoice);Add-UiRow $jobPanel @($status,$stopPrepare);Add-UiRow $root @($jobPanel)
$jobPanel.ColumnStyles[0].Width=100;$jobPanel.ColumnStyles[1].SizeType='AutoSize'
$jobProgress=New-Object Windows.Forms.ProgressBar;$jobProgress.Dock='Fill';$jobProgress.Height=12;$jobProgress.Visible=$false;$jobProgress.MarqueeAnimationSpeed=30
Add-UiRow $jobPanel @($jobProgress)
$progressDetail=New-UiLabel '';$progressDetail.Margin=New-Object Windows.Forms.Padding(4,0,4,4)
Add-UiRow $jobPanel @($progressDetail)
$jobPanel.Add_SizeChanged({
    $status.MaximumSize=New-Object Drawing.Size([Math]::Max(150,$jobPanel.ClientSize.Width-$stopPrepare.Width-45),0)
    $progressDetail.MaximumSize=New-Object Drawing.Size([Math]::Max(150,$jobPanel.ClientSize.Width-20),0)
})
$script:jobCommand='';$script:stopRequested=$false;$script:jobStarted=[DateTime]::UtcNow
$log=New-UiField;$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Both';$log.WordWrap=$false
$log.Font=New-Object Drawing.Font('Consolas',9);Add-UiRow $root @($log)
$root.RowStyles[2].SizeType='Percent';$root.RowStyles[2].Height=22
function Browse-Folder($Box) { $d=New-Object Windows.Forms.FolderBrowserDialog;try { if ($d.ShowDialog() -eq 'OK') { $Box.Text=$d.SelectedPath } } finally { $d.Dispose() } }
function Show-Error($ErrorText) { if ($SmokeTest) { throw [string]$ErrorText }; [Windows.Forms.MessageBox]::Show([string]$ErrorText,(Get-ArchiveText 'dialog.incomplete'),'OK','Warning') | Out-Null }
$preparePage=New-UiPage $tabs (Get-ArchiveText 'nav.prepare');$prepare=$preparePage.table
$discPage=New-UiPage $tabs (Get-ArchiveText 'nav.discs');$discs=$discPage.table
$videoPage=New-UiPage $tabs (Get-ArchiveText 'nav.video');$video=$videoPage.table
$settingsPage=New-UiPage $tabs (Get-ArchiveText 'nav.settings');$settings=$settingsPage.table
$scenario=New-UiChoice @((Get-ArchiveText 'legacy.d3ef12d6f110'),(Get-ArchiveText 'legacy.7107070139fb'),(Get-ArchiveText 'legacy.7b76ff5ea60d'));Add-UiSetting $prepare (Get-ArchiveText 'legacy.155ae10dfd6d') $scenario
$tier=New-UiChoice @((Get-ArchiveText 'legacy.ddf58408a9a0'),(Get-ArchiveText 'legacy.66675454bf61'),(Get-ArchiveText 'legacy.2fa709d7f7a1'));Add-UiSetting $prepare (Get-ArchiveText 'legacy.2d1caead9543') $tier
$source=New-UiField;$browseSource=New-UiButton (Get-ArchiveText 'action.browse');$browseSource.Add_Click({ Browse-Folder $source })
Add-UiSetting $prepare (Get-ArchiveText 'legacy.0acd4d885ae0') (New-UiPicker $source $browseSource)
$setId=New-UiField ('PHOTO-'+[DateTime]::Now.ToString('yyyyMMdd')+'-01');$loadPlan=New-UiButton (Get-ArchiveText 'legacy.ece07c98fa59');Add-UiSetting $prepare 'Archive ID' (New-UiPicker $setId $loadPlan)
$media=New-UiChoice @('BD25 · 25 GB',(Get-ArchiveText 'legacy.f79b8524057c'));Add-UiSetting $prepare (Get-ArchiveText 'legacy.f7a77db0afdb') $media
$startDiscId=New-UiField;Add-UiSetting $prepare (Get-ArchiveText 'legacy.0cc3722b776a') $startDiscId
Add-UiRow $prepare @((New-UiLabel (Get-ArchiveText 'legacy.7de7fc33aa6d')))
$labelTemplate=New-UiField '{disc_id}';Add-UiSetting $prepare (Get-ArchiveText 'legacy.4f0417c97066') $labelTemplate
$idPreview=New-UiLabel (Get-ArchiveText 'legacy.9586acc6f6d4');Add-UiRow $prepare @($idPreview)
$summary=New-UiField;Add-UiSetting $prepare (Get-ArchiveText 'legacy.4b3a77b9804d') $summary
$dateRange=New-UiField;Add-UiSetting $prepare (Get-ArchiveText 'legacy.5a7124fff1fb') $dateRange
$subject=New-UiField;Add-UiSetting $prepare (Get-ArchiveText 'legacy.c2c7819ad34b') $subject
$second=New-UiField;Add-UiSetting $prepare (Get-ArchiveText 'legacy.0427793f3431') $second
$password=New-UiField;$password.Enabled=$false;Add-UiSetting $prepare (Get-ArchiveText 'legacy.342a873c23b5') $password
$parity=New-UiChoice @((Get-ArchiveText 'choice.noParity'),'5% PAR2','10% PAR2');Add-UiSetting $prepare (Get-ArchiveText 'legacy.012527446886') $parity
$dedup=New-UiCheck (Get-ArchiveText 'legacy.7a5208ad5b24');Add-UiRow $prepare @($dedup)
$execute=New-UiCheck (Get-ArchiveText 'legacy.63b5d981588f');$make=New-UiButton (Get-ArchiveText 'action.prepare');Add-UiRow $prepare @((New-UiFlow @($execute,$make)))
$prepareNote=New-UiLabel (Get-ArchiveText 'legacy.2d9b08c2c524');Add-UiRow $prepare @($prepareNote)
$scenario.Add_SelectedIndexChanged({
    $tier.Enabled=($scenario.SelectedIndex -eq 0);$dedup.Enabled=($scenario.SelectedIndex -eq 0)
    if (!$dedup.Enabled) { $dedup.Checked=$false }
    $password.Enabled=($scenario.SelectedIndex -eq 2)
    $prepareNote.Text=@((Get-ArchiveText 'legacy.2d9b08c2c524'),(Get-ArchiveText 'legacy.431f1a77366e'),(Get-ArchiveText 'legacy.f55465ec1541'))[$scenario.SelectedIndex]
    if ($setId.Text -match '^(PHOTO|GAME|BACKUP)-\d{8}-01$') { $setId.Text=@('PHOTO','GAME','BACKUP')[$scenario.SelectedIndex]+'-'+[DateTime]::Now.ToString('yyyyMMdd')+'-01' }
})
$grid=New-Object Windows.Forms.DataGridView;$grid.Dock='Fill';$grid.Height=180;$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.MultiSelect=$false;$grid.SelectionMode='FullRowSelect';$grid.AutoSizeColumnsMode='Fill';$grid.ColumnHeadersHeightSizeMode='AutoSize';$grid.AutoSizeRowsMode='AllCells';Add-UiRow $discs @($grid)
foreach ($col in @('disc_id','archive_set_id','position','volume_label','disc_index','status','location')) { $null=$grid.Columns.Add($col,@{disc_id=(Get-ArchiveText 'field.discId');archive_set_id=(Get-ArchiveText 'legacy.cc53af6f3724');position=(Get-ArchiveText 'legacy.ef7e223e174d');volume_label=(Get-ArchiveText 'legacy.baeda3c9e221');disc_index=(Get-ArchiveText 'legacy.f7488f3bd4db');status=(Get-ArchiveText 'legacy.236a3cf30749');location=(Get-ArchiveText 'legacy.4c27174b03b8')}[$col]) }
$refresh=New-UiButton (Get-ArchiveText 'legacy.ae93d47bc513');$view=New-UiButton (Get-ArchiveText 'legacy.0a640c1ebbb4');$openStage=New-UiButton (Get-ArchiveText 'legacy.0299ae3d770d')
$sim=New-UiButton (Get-ArchiveText 'legacy.b4f52047489f');$burn=New-UiButton (Get-ArchiveText 'action.burn');$burn.BackColor=[Drawing.Color]::MistyRose
Add-UiRow $discs @((New-UiFlow @($refresh,$view,$openStage,$sim,$burn)))
$drive=New-UiChoice @((Get-ArchiveText 'legacy.20f99990c722'));$drive.Items.Clear();$drive.DisplayMember='display';$drive.Enabled=$false
$refreshDrives=New-UiButton (Get-ArchiveText 'legacy.f71ac489f315')
Add-UiSetting $discs (Get-ArchiveText 'legacy.851764e61ef9') (New-UiPicker $drive $refreshDrives)
$mediaInfo=New-UiLabel (Get-ArchiveText 'legacy.b5f19509c2bb');Add-UiRow $discs @($mediaInfo)
$recoverBurn=New-UiButton (Get-ArchiveText 'legacy.f868054ecfeb');$clearSimulation=New-UiButton (Get-ArchiveText 'legacy.f66209bf92f9');Add-UiRow $discs @((New-UiFlow @($recoverBurn,$clearSimulation)))
$externalRoot=New-UiField;$externalBrowse=New-UiButton (Get-ArchiveText 'action.browse');$externalBrowse.Add_Click({Browse-Folder $externalRoot})
Add-UiSetting $discs (Get-ArchiveText 'legacy.79f2b68249ae') (New-UiPicker $externalRoot $externalBrowse)
$externalExecute=New-UiCheck (Get-ArchiveText 'legacy.34b8142a21be');$externalImport=New-UiButton (Get-ArchiveText 'legacy.c92613d930cb')
Add-UiRow $discs @((New-UiFlow @($externalExecute,$externalImport)))
Add-UiRow $discs @((New-UiLabel (Get-ArchiveText 'legacy.9e19ff37322b')))
$location=New-UiField;Add-UiSetting $discs (Get-ArchiveText 'legacy.4c27174b03b8') $location
$reloaded=New-UiCheck (Get-ArchiveText 'legacy.7c83b5db0ffd');Add-UiRow $discs @($reloaded)
$deepVerify=New-UiCheck (Get-ArchiveText 'legacy.64e9dfe9ecde');Add-UiRow $discs @($deepVerify)
$verify=New-UiButton (Get-ArchiveText 'legacy.332111e1c9f6');$register=New-UiButton (Get-ArchiveText 'legacy.f0282399702a');$repairVerify=New-UiButton (Get-ArchiveText 'legacy.4f13a7f88161');Add-UiRow $discs @((New-UiFlow @($verify,$register,$repairVerify)))
$restoreOutput=New-UiField;$restoreBrowse=New-UiButton (Get-ArchiveText 'action.browse');$restoreBrowse.Add_Click({ Browse-Folder $restoreOutput })
Add-UiSetting $discs (Get-ArchiveText 'legacy.caecb5d342cc') (New-UiPicker $restoreOutput $restoreBrowse)
$restore=New-UiButton (Get-ArchiveText 'legacy.977b8f9afc80');Add-UiRow $discs @((New-UiFlow @($restore)))
Add-UiRow $discs @((New-UiLabel (Get-ArchiveText 'legacy.ad5d1cd94bcc')))
$videoSource=New-UiField;$videoBrowse=New-UiButton (Get-ArchiveText 'action.browse')
$videoBrowse.Add_Click({ $d=New-Object Windows.Forms.OpenFileDialog;try { if ($d.ShowDialog() -eq 'OK') { $videoSource.Text=$d.FileName } } finally { $d.Dispose() } })
Add-UiSetting $video (Get-ArchiveText 'legacy.c5425e15ed67') (New-UiPicker $videoSource $videoBrowse)
$videoOutput=New-UiField;Add-UiSetting $video (Get-ArchiveText 'legacy.045225268884') $videoOutput
$videoSummary=New-UiField;Add-UiSetting $video (Get-ArchiveText 'legacy.e7e132bb5643') $videoSummary
$split=New-UiButton (Get-ArchiveText 'legacy.213b7b84bb5c');$sheet=New-UiButton (Get-ArchiveText 'legacy.cb60bfc98477');Add-UiRow $video @((New-UiFlow @($split,$sheet)))
Add-UiRow $video @((New-UiLabel (Get-ArchiveText 'legacy.8507836b8007')))
Add-UiRow $video @((New-UiLabel (Get-ArchiveText 'legacy.aeafc87ba40e')))
$videoExecute=New-UiCheck (Get-ArchiveText 'legacy.795e9410f1da');Add-UiRow $video @($videoExecute)
$configBox=New-UiField $script:configPath;$configBrowse=New-UiButton (Get-ArchiveText 'action.browse')
$configBrowse.Add_Click({ $d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='JSON (*.json)|*.json';try { if ($d.ShowDialog() -eq 'OK') { $configBox.Text=$d.FileName;Load-Settings;Refresh-Discs;Show-ToolInventory } } finally { $d.Dispose() } })
Add-UiSetting $settings (Get-ArchiveText 'legacy.1d27f02ed278') (New-UiPicker $configBox $configBrowse)
$script:toolBoxes=@{};$toolNames=@('archive_root','dwarfs_bin','dwarfs','python','ffmpeg','mkvmerge','par2','imgburn','winfsp')
$toolLabels=@((Get-ArchiveText 'legacy.3db7b06b5f6d'),(Get-ArchiveText 'legacy.7ffee5b580ce'),(Get-ArchiveText 'legacy.8b7c7f7602c5'),(Get-ArchiveText 'legacy.8efed7db8294'),'ffmpeg','mkvmerge','PAR2',(Get-ArchiveText 'legacy.29f76b5669d4'),(Get-ArchiveText 'legacy.c89876703472'))
for ($i=0;$i -lt $toolNames.Count;$i++) {
    $box=New-UiField;$script:toolBoxes[$toolNames[$i]]=$box
    $picker=New-UiButton (Get-ArchiveText 'action.browse');$picker.Tag=$toolNames[$i]
    $picker.Add_Click({ $key=$this.Tag;$box=$script:toolBoxes[$key];if ($key -in @('archive_root','dwarfs_bin','winfsp')) { Browse-Folder $box } else { $d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='Executable (*.exe)|*.exe';try { if ($d.ShowDialog() -eq 'OK') { $box.Text=$d.FileName } } finally { $d.Dispose() } } })
    Add-UiSetting $settings $toolLabels[$i] (New-UiPicker $box $picker)
}
$buildMode=New-UiChoice @((Get-ArchiveText 'legacy.e80bd3a491f3'),(Get-ArchiveText 'legacy.2afd9f2dadfb'),(Get-ArchiveText 'legacy.09f75ed4a379'));Add-UiSetting $settings (Get-ArchiveText 'legacy.0dd7b4fda503') $buildMode
$burnSpeed=New-UiChoice @('MAX','2x','4x','6x','8x','10x','12x','16x');Add-UiSetting $settings (Get-ArchiveText 'legacy.c82fe9ff8b4f') $burnSpeed
Add-UiRow $settings @((New-UiLabel (Get-ArchiveText 'legacy.a8d3d707c78f')))
$postBurnVerify=New-UiCheck (Get-ArchiveText 'legacy.e74eb1e009f1');Add-UiRow $settings @($postBurnVerify)
Add-UiRow $settings @((New-UiLabel (Get-ArchiveText 'legacy.e12ecf8552c5')))
$saveConfig=New-UiButton (Get-ArchiveText 'legacy.6e584e3d5ce6');$guide=New-UiButton (Get-ArchiveText 'legacy.9d397b5c97da');$detectTools=New-UiButton (Get-ArchiveText 'legacy.0445de9a30b5');$fillTools=New-UiButton (Get-ArchiveText 'legacy.bf98668ecdc2')
$guide.Add_Click({ Start-Process -FilePath (Join-Path $PSScriptRoot '../START-HERE.md') })
Add-UiRow $settings @((New-UiFlow @($detectTools,$fillTools,$saveConfig,$guide)))
$toolGrid=New-Object Windows.Forms.DataGridView;$toolGrid.Dock='Fill';$toolGrid.Height=260;$toolGrid.ReadOnly=$true;$toolGrid.AllowUserToAddRows=$false;$toolGrid.AllowUserToDeleteRows=$false;$toolGrid.AutoSizeColumnsMode='Fill';$toolGrid.AutoSizeRowsMode='AllCells';$toolGrid.ColumnHeadersHeightSizeMode='AutoSize'
foreach ($col in @((Get-ArchiveText 'legacy.5ca6730d4415'),(Get-ArchiveText 'legacy.6320b4a8722a'),(Get-ArchiveText 'legacy.5f76b2bf82dd'),(Get-ArchiveText 'legacy.f67762f56984'))) { $null=$toolGrid.Columns.Add($col,$col) };$toolGrid.Columns[3].FillWeight=230
Add-UiRow $settings @($toolGrid)
Add-UiRow $settings @((New-UiLabel (Get-ArchiveText 'legacy.cae0044ff94b')))
function Show-ToolInventory {
    $script:toolInventory=@(Get-ArchiveToolInventory (Load-Config $configBox.Text));$toolGrid.Rows.Clear()
    $labels=@{FOUND=(Get-ArchiveText 'legacy.de03ee139fe2');MISSING=(Get-ArchiveText 'legacy.12129b289261');INCOMPLETE=(Get-ArchiveText 'legacy.3c6085e46599');CONFIGURED_MISSING=(Get-ArchiveText 'legacy.bd5a4e31e263');BUILT_IN=(Get-ArchiveText 'legacy.b2c6ab2adfe6')}
    foreach ($item in $script:toolInventory) { $null=$toolGrid.Rows.Add([object[]]@($item.tool,$labels[$item.state],$item.version,$item.detected)) }
}
$detectTools.Add_Click({ try { Show-ToolInventory } catch { Show-Error $_ } })
$fillTools.Add_Click({ try {
    Show-ToolInventory
    foreach ($item in $script:toolInventory) {
        if ($item.detected -and $item.state -eq 'FOUND' -and $script:toolBoxes.ContainsKey($item.key) -and !$script:toolBoxes[$item.key].Text) {
            if ($item.key -eq 'dwarfs_bin' -and $script:toolBoxes.dwarfs.Text) { continue }
            $script:toolBoxes[$item.key].Text=$item.detected
        }
    }
    $status.Text=(Get-ArchiveText 'legacy.52e94888bbcf')
} catch { Show-Error $_ } })
function Load-Settings {
    $script:configPath=Full-Path $configBox.Text;$c=Read-Json $script:configPath
    $profile=Dwarfs-BuildProfile $c;$skip=Optional-Field $c.dwarfs 'skip_roundtrip'
    if ($null -eq $skip) {$skip=($profile -eq 'fast')}
    $buildMode.SelectedIndex=if ($profile -eq 'fast') {if ($skip) {0} else {1}} else {2}
    $speed=ImgBurn-RequestedSpeed $c;if (!$burnSpeed.Items.Contains($speed)) { $null=$burnSpeed.Items.Add($speed) };$burnSpeed.SelectedItem=$speed
    $postBurnVerify.Checked=[bool](Optional-Field $c.burn 'verify_after_write')
    $labelTemplate.Text=Volume-LabelTemplate $c @{}
    $t=Volume-Templates $c @{};foreach ($key in $script:volumeBoxes.Keys) { $script:volumeBoxes[$key].Text=[string]$t.$key };$volumeBackend.SelectedItem=$c.burn.backend
    $script:toolBoxes.archive_root.Text=$c.archive_root
    foreach ($key in $toolNames | Where-Object { $_ -ne 'archive_root' }) { $script:toolBoxes[$key].Text=$c.tools.$key }
}
$saveConfig.Add_Click({ try {
    if (Test-AnyArchiveJobRunning) { throw (Get-ArchiveText 'legacy.487019c6c35e') }
    $script:configPath=Full-Path $configBox.Text;$c=Read-Json $script:configPath
    $c.archive_root=$script:toolBoxes.archive_root.Text
    $resolvedRoot=Full-Path $c.archive_root (Split-Path $script:configPath);$c.catalog_path=Join-Path $resolvedRoot 'catalog.sqlite'
    foreach ($key in $toolNames | Where-Object { $_ -ne 'archive_root' }) { $c.tools.$key=$script:toolBoxes[$key].Text }
    $c.dwarfs | Add-Member NoteProperty build_profile $(if ($buildMode.SelectedIndex -eq 2) {'verified'} else {'fast'}) -Force
    $c.dwarfs | Add-Member NoteProperty skip_roundtrip ($buildMode.SelectedIndex -eq 0) -Force
    $c.dwarfs.compression_level=if ($buildMode.SelectedIndex -eq 2) {7} else {0}
    $c.burn.speed=[string]$burnSpeed.SelectedItem;$null=ImgBurn-RequestedSpeed $c
    $c.burn | Add-Member NoteProperty verify_after_write ([bool]$postBurnVerify.Checked) -Force
    $c | Add-Member NoteProperty ui ([pscustomobject]@{language=$script:Language}) -Force
    Write-Json $script:configPath $c;Refresh-Discs;$status.Text=(Get-ArchiveText 'legacy.09d89ed905f6')
} catch { Show-Error $_ } })
function Refresh-Discs {
    Refresh-IdentityView
    $grid.Rows.Clear();$c=Load-Config $configBox.Text
    if (Test-Path -LiteralPath (Catalog-Path $c)) {
        foreach ($d in @((Read-Json (Catalog-Path $c)).discs | Where-Object { !(Optional-Field $_ 'catalog_deleted') })) { $null=$grid.Rows.Add([object[]]@($d.disc_id,$d.archive_set_id,"$($d.position)/$($d.disc_count)",(Disc-Identity $d).volume_label,(Disc-Identity $d).disc_index,$d.status,$d.location)) }
    }
}
. (Join-Path $PSScriptRoot 'Archive.OpticalUi.ps1')
. (Join-Path $PSScriptRoot 'Archive.IdUi.ps1')
. (Join-Path $PSScriptRoot 'Archive.VolumeUi.ps1')
function Selected-Disc { if (!$grid.SelectedRows.Count) { throw (Get-ArchiveText 'legacy.9812ae0f4888') }; $c=Load-Config $configBox.Text;return Get-Disc $c ([string]$grid.SelectedRows[0].Cells[0].Value) }
function Start-ArchiveJob($Command,$Params) {
    Save-SelectedArchiveJob
    Assert-UiJobAvailable $Command $Params
    $Params.Config=Full-Path $configBox.Text
    $jobRoot=Full-Path (Join-Path $PSScriptRoot '../work/ui-jobs');[IO.Directory]::CreateDirectory($jobRoot) | Out-Null
    $newJobPath=Join-Path $jobRoot ([guid]::NewGuid().ToString('N')+'.json')
    Write-Json $newJobPath @{command=$Command;parameters=$Params}
    $engine=(Get-Process -Id $PID).Path;$runner=Join-Path $PSScriptRoot 'run-request.ps1'
    $interactiveReview=($Command -eq 'burn' -and $Params.Execute -and !$Params.DryRun -and !$Params.Simulate)
    $start=New-ArchiveWorkerStartInfo $engine $runner $newJobPath $interactiveReview
    $nextWorker=New-Object Diagnostics.Process;$nextWorker.StartInfo=$start
    try {$null=$nextWorker.Start()} catch {$nextWorker.Dispose();throw}
    $script:worker=$nextWorker;$script:jobPath=$newJobPath
    $script:jobCommand=$Command;$script:stopRequested=$false;$script:jobStarted=[DateTime]::UtcNow
    $stopPrepare.Text=if ($Command -eq 'verify') {(Get-ArchiveText 'action.stopVerification')} else {(Get-ArchiveText 'action.stopPreparation')};$stopPrepare.Enabled=($Command -in @('prepare','verify','import-stage') -and $Params.Execute -and !$Params.DryRun)
    $log.Text=(Get-ArchiveText 'legacy.86f8f464609d');$status.Text=(Get-ArchiveText 'legacy.8eb2e0afdcb2' -Arguments @(($Command)))
    $jobProgress.Style='Marquee';$jobProgress.Value=0;$progressDetail.Text=''
    Add-CurrentArchiveJob $Command $Params
}
$script:loadedPreparation=$null
$loadPlan.Add_Click({ try {
    # Loading another set is read-only; running job parameters are already saved.
    $saved=Get-SavedPreparationSettings (Load-Config $configBox.Text) $setId.Text.Trim()
    $p=$saved.parameters
    $sceneIndex=@('photo','game','backup').IndexOf($p.Scenario)
    if ($sceneIndex -lt 0) { throw (Get-ArchiveText 'legacy.3a67f6f59253') }
    $mediaIndex=@('BD25','BD50').IndexOf($p.Media)
    if ($mediaIndex -lt 0) { throw (Get-ArchiveText 'legacy.6cd1b62ab002') }
    $scenario.SelectedIndex=$sceneIndex;$source.Text=$p.Source
    $tier.SelectedIndex=[math]::Max(0,@('C','B','A').IndexOf($p.PhotoTier))
    $media.SelectedIndex=$mediaIndex
    $parText=if ($p.ParPercent -eq 0) {(Get-ArchiveText 'choice.noParity')} else { "$($p.ParPercent)% PAR2" }
    if (!$parity.Items.Contains($parText)) { $null=$parity.Items.Add($parText) };$parity.SelectedItem=$parText
    $dedup.Enabled=($sceneIndex -eq 0 -or $p.Deduplicate);$dedup.Checked=$p.Deduplicate
    $startDiscId.Text=$p.StartDiscId;$labelTemplate.Text=$p.VolumeLabelTemplate
    foreach ($key in $script:volumeBoxes.Keys) { $script:volumeBoxes[$key].Text=$p.VolumeTemplates[$key] }
    $summary.Text=[string]$p.Summary;$dateRange.Text=[string]$p.DateRange
    $subject.Text=if ($sceneIndex -eq 0) {[string]$p.Camera} elseif ($sceneIndex -eq 1) {[string]$p.Game} else {''}
    $second.Text=[string]$p.SecondCopy;$password.Text=[string]$p.PasswordStorage
    $script:loadedPreparation=$saved;Refresh-IdentityPreview
    $status.Text=(Get-ArchiveText 'legacy.602fdd8d113a' -Arguments @(($($p.SetId)), ($($saved.disc_count)), ($($p.ParPercent))))
} catch { Show-Error $_ } })
function Invoke-UiPreparation([bool]$Run) { try {
    $scene=@('photo','game','backup')[$scenario.SelectedIndex]
    $p=@{StartDiscId=$startDiscId.Text.Trim();VolumeTemplates=(Get-UiVolumeTemplates);VolumeLabelTemplate=$labelTemplate.Text;SetId=$setId.Text.Trim();Source=$source.Text;Scenario=$scene;PhotoTier=@('C','B','A')[$tier.SelectedIndex];Media=@('BD25','BD50')[$media.SelectedIndex];ParPercent=$(if ($parity.SelectedIndex -eq 0) {0} else {[double]([string]$parity.SelectedItem -replace '% PAR2$','')});Summary=$summary.Text;DateRange=$dateRange.Text;SecondCopy=$second.Text;Execute=$Run;DetectDuplicates=$dedup.Checked;Deduplicate=$dedup.Checked}
    if ($scene -eq 'photo') { $p.Camera=$subject.Text } elseif ($scene -eq 'game') { $p.Game=$subject.Text;$p.MasterStatus='existing_highest_quality' } else { $p.PasswordStorage=$password.Text }
    if ($p.PhotoTier -eq 'A') { $p.Deduplicate=$false }
    Start-ArchiveJob prepare $p
} catch { Show-Error $_ } }
$make.Add_Click({if($execute.Checked){Invoke-UiPreparation $true}})
$refresh.Add_Click({ try { Refresh-Discs;Refresh-OpticalDevices } catch { Show-Error $_ } })
$view.Add_Click({ try { $d=Selected-Disc;$c=Load-Config $configBox.Text;Start-Process -FilePath (Join-Path (Set-Dir $c $d.archive_set_id) 'ARCHIVE-SUMMARY.txt') } catch { Show-Error $_ } })
$openStage.Add_Click({ try { $d=Selected-Disc;if (!$d.stage) { throw (Get-ArchiveText 'legacy.a9dbdcb91394') };Start-Process explorer.exe -ArgumentList ('"'+$d.stage.path+'"') } catch { Show-Error $_ } })
$sim.Add_Click({ try { $d=Selected-Disc;Start-ArchiveJob burn @{DiscId=$d.disc_id;Execute=$true;Simulate=$true} } catch { Show-Error $_ } })
$burn.Add_Click({ try {
    $d=Selected-Disc
    if ($d.burn -and $d.burn.simulation) {
        $answer=[Windows.Forms.MessageBox]::Show((Get-ArchiveText 'legacy.b66e85bb8e2f' -Arguments @(($($d.disc_id)))),(Get-ArchiveText 'legacy.3beb92a9ff36'),[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    }
    Start-ArchiveJob burn @{DiscId=$d.disc_id;Drive=(Selected-OpticalDrive);RecorderId=$drive.SelectedItem.recorder_id;Backend=$volumeBackend.SelectedItem;Execute=$true;BurnConfirmed=$true;ConfirmationMode='Dialog'}
} catch { Show-Error $_ } })
$externalImport.Add_Click({try {$d=Selected-Disc;Start-ArchiveJob import-stage @{DiscId=$d.disc_id;Source=$externalRoot.Text;Execute=$externalExecute.Checked}} catch {Show-Error $_}})
$recoverBurn.Add_Click({ try { $d=Selected-Disc;Start-ArchiveJob recover-burn @{DiscId=$d.disc_id;Execute=$true} } catch { Show-Error $_ } })
$clearSimulation.Add_Click({ try {
    $d=Selected-Disc
    if (!$d.burn -or !$d.burn.simulation) { throw (Get-ArchiveText 'legacy.217adffeec91') }
    $answer=[Windows.Forms.MessageBox]::Show((Get-ArchiveText 'legacy.c7a1ae316eaa' -Arguments @(($($d.disc_id)))),(Get-ArchiveText 'legacy.f66209bf92f9'),[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -eq [Windows.Forms.DialogResult]::Yes) { Start-ArchiveJob clear-simulation @{DiscId=$d.disc_id;Execute=$true;Reason='USER_UI'} }
} catch { Show-Error $_ } })
$verify.Add_Click({ try { $d=Selected-Disc;if (!$d.burn) { throw (Get-ArchiveText 'legacy.2e1fbb0e2500') };Start-ArchiveJob verify @{DiscId=$d.disc_id;Drive=(Selected-OpticalDrive -Optional:$d.burn.simulation);Execute=$true;Simulate=[bool]$d.burn.simulation;MediaReloaded=$reloaded.Checked;DeepVerifyDwarfs=$deepVerify.Checked} } catch { Show-Error $_ } })
$repairVerify.Add_Click({ try { $d=Selected-Disc;Start-ArchiveJob repair-verify @{DiscId=$d.disc_id;Drive=(Selected-OpticalDrive);RecorderId=$drive.SelectedItem.recorder_id;Execute=$true} } catch { Show-Error $_ } })
$register.Add_Click({ try { $d=Selected-Disc;Start-ArchiveJob register @{DiscId=$d.disc_id;Execute=$true;Location=$location.Text} } catch { Show-Error $_ } })
$restore.Add_Click({ try { $d=Selected-Disc;$roots=@(Selected-OpticalDrive -Optional);if ($d.burn -and $d.burn.simulation) { $c=Load-Config $configBox.Text;$roots=@((Read-Json (Catalog-Path $c)).discs | Where-Object { $_.archive_set_id -eq $d.archive_set_id -and $_.burn -and $_.burn.simulation } | ForEach-Object { $_.burn.root }) };Start-ArchiveJob restore @{SetId=$d.archive_set_id;Execute=$true;Output=$restoreOutput.Text;MediaRoots=$roots} } catch { Show-Error $_ } })
$split.Add_Click({ try { Start-ArchiveJob split-video @{Source=$videoSource.Text;Output=$videoOutput.Text;Summary=$videoSummary.Text;Execute=$videoExecute.Checked} } catch { Show-Error $_ } })
$sheet.Add_Click({ try { Start-ArchiveJob contact-sheet @{Source=$videoSource.Text;Output=$videoOutput.Text;Execute=$videoExecute.Checked} } catch { Show-Error $_ } })
$stopPrepare.Add_Click({
    try {
        if ($script:worker -and !$script:worker.HasExited -and $script:jobCommand -in @('prepare','verify','import-stage')) {
            Write-Text ($script:jobPath+'.cancel') ('User requested '+$script:jobCommand+' cancellation.')
            $script:stopRequested=$true;$stopPrepare.Enabled=$false;$stopPrepare.Text=(Get-ArchiveText 'legacy.8a99be840844')
            $status.Text=if ($script:jobCommand -eq 'verify') {(Get-ArchiveText 'legacy.c0ca5ab9d265')} else {(Get-ArchiveText 'legacy.71f5a814c170')}
        }
    } catch { Show-Error $_ }
})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=700
function Update-SelectedArchiveJob {
    if ($script:jobPath -and (Test-Path -LiteralPath "$script:jobPath.log")) {
        try {
            $text=Read-ArchiveLogTail ($script:jobPath+'.log')
            $progressPath=$script:jobPath+'.progress.json'
            if ([IO.File]::Exists($progressPath)) {
                $progress=Read-Json $progressPath
                $nativeProgress=''
                if ($progress.tool_log) {
                    $nativeText=Read-ArchiveLogTail $progress.tool_log
                    $text+=(Get-ArchiveText 'legacy.f32b32ec5976')+$nativeText
                    $updates=[regex]::Matches($nativeText,'==>[^\r\n]+')
                    if ($updates.Count) { $nativeProgress=$updates[$updates.Count-1].Value }
                }
                if ($script:worker -and !$script:worker.HasExited) {
                    $view=Get-ArchiveProgressView $progress
                    $jobProgress.Style=if ($view.determinate) {'Continuous'} else {'Marquee'}
                    $jobProgress.Value=$view.value;$progressDetail.Text=$view.detail
                    $elapsed=([DateTime]::UtcNow-$script:jobStarted).ToString('hh\:mm\:ss')
                    $status.Text="$(if ($script:stopRequested) {(Get-ArchiveText 'legacy.741586f26e6b')})$($progress.disc) $($progress.message) · $elapsed$(if ($nativeProgress) { "`r`nDwarFS $nativeProgress" })"
                }
            }
            if ($text.Length -gt 48000) { $text=$text.Substring($text.Length-48000) }
            $text=[regex]::Replace($text,"$([char]27)\[[0-?]*[ -/]*[@-~]",'')
            $log.Text=$text.TrimEnd("`r","`n");$log.SelectionStart=$log.Text.Length;$log.ScrollToCaret()
        } catch { }

    }
    if ($script:worker -and $script:worker.HasExited) {
        $code=$script:worker.ExitCode;$script:worker.Dispose();$script:worker=$null
        $stopPrepare.Enabled=$false;$stopPrepare.Text=(Get-ArchiveText 'action.stopPreparation')
        $jobProgress.Style='Continuous';$jobProgress.Value=0;$progressDetail.Text=''
        $status.Text=if ($code -eq 2 -and $script:jobCommand -eq 'prepare') { (Get-ArchiveText 'legacy.3297feef3a3f') } elseif ($code -eq 0) { (Get-ArchiveText 'legacy.e1b81a3bad76') } else { (Get-ArchiveText 'legacy.a31c48346fa3') }
        if ($code -eq 2 -and $script:jobCommand -eq 'import-stage') {$status.Text=(Get-ArchiveText 'legacy.0b1d7b5305cb')}
        if ($code -eq 2 -and $script:jobCommand -eq 'verify') { $status.Text=(Get-ArchiveText 'legacy.0bbbbd955273') }
        if ($code -eq 2 -and $script:jobCommand -eq 'burn') { $status.Text=(Get-ArchiveText 'legacy.ec8cf223f56b') }
        if ($code -eq 0) {
            $jobProgress.Value=100
            if ($script:jobCommand -eq 'verify') {
                $finished=Read-Json ($script:jobPath+'.result.json')
                $status.Text=if ($finished.result.status -eq 'DRY_RUN') {(Get-ArchiveText 'legacy.3511ccb6a5d6')} elseif ($finished.result.simulation) {(Get-ArchiveText 'legacy.40e7331575bb')} else {(Get-ArchiveText 'legacy.e953c4dee039')}
            }
        }
        if ($code -eq 0 -and $script:jobCommand -in @('rename-disc','rename-set','repair-identity-change')) {
            $script:loadedPreparation=$null
            $status.Text=(Get-ArchiveText 'legacy.53945a984055')
        }
        if ($code -eq 0 -and $script:jobCommand -eq 'clear-simulation') { $status.Text=(Get-ArchiveText 'legacy.e8a588b83708') }
        try { Refresh-Discs } catch { Show-Error $_ }
    }
}
. (Join-Path $PSScriptRoot 'Archive.JobUi.ps1')
$timer.Add_Tick({ Update-ArchiveJob })
$form.Add_FormClosing({
    if (Test-AnyArchiveJobRunning) { $_.Cancel=$true;Show-Error (Get-ArchiveText 'legacy.99055e2ab4fb') }
})
# Record existing interactive controls before regrouping; smoke tests must not lose a feature.
$originalInteractiveControls=@()
if ($SmokeTest) {
    $script:originalInteractiveList=New-Object 'Collections.Generic.List[Windows.Forms.Control]'
    function Get-OriginalInteractiveControls($Container) {
        foreach($child in $Container.Controls) {
            if($child -is [Windows.Forms.ButtonBase] -or $child -is [Windows.Forms.TextBoxBase] -or $child -is [Windows.Forms.ComboBox] -or $child -is [Windows.Forms.DataGridView]) {$script:originalInteractiveList.Add($child)}
            Get-OriginalInteractiveControls $child
        }
    }
    Get-OriginalInteractiveControls $tabs
    $originalInteractiveControls=$script:originalInteractiveList.ToArray()
}
. (Join-Path $PSScriptRoot 'Archive.ActionLayout.ps1')
$shell=New-ArchiveShell -Form $form -Root $root -Tabs $tabs -Log $log -PrimaryButtons @($make,$verify,$saveConfig,$volumeSave) -DangerButtons @($burn,$clearSimulation,$idDelete) -Language $Language
$languageChoice=New-UiChoice @('English','简体中文')
$languageChoice.Dock='None';$languageChoice.Width=150;$languageChoice.AccessibleName='Language / 语言'
$languageChoice.SelectedIndex=if ($Language -eq 'zh-CN') {1} else {0}
$shell.HeaderActions.Controls.Add($languageChoice)
$script:changingLanguage=$false
function Set-UiLanguage([string]$Value) {
    if ($script:changingLanguage) {return}
    $script:changingLanguage=$true
    try {
        $script:Language=$Value;Initialize-ArchiveLocale -Language $Value
        Update-ArchiveControlLocale $form
        Set-ArchiveShellLanguage $shell $Value
        Update-ArchiveShellLayout $shell
        # Recompute display-only summaries, never refresh jobs, catalog rows or user input.
        Refresh-IdentityPreview;Refresh-VolumePreview
    } finally {$script:changingLanguage=$false}
}
$languageChoice.Add_SelectedIndexChanged({Set-UiLanguage @('en','zh-CN')[$languageChoice.SelectedIndex]})
try {
    Load-Settings; Refresh-Discs; Show-ToolInventory;Refresh-OpticalDevices
    Set-UiLanguage $Language
    $form.ResumeLayout($true)
    if ($SmokeTest) {
        if ($ExerciseResumeSettings) {
            $setId.Text=$ResumeSetId;$parity.SelectedIndex=1
            $script:volumeBoxes.iso9660.Text='{disc_id}-{volume_id}'
            $script:volumeBoxes.volume_set.Text='{set_id}';$script:volumeBoxes.application.Text='CHANGED DEFAULT'
            $form.Show();[Windows.Forms.Application]::DoEvents();$loadPlan.PerformClick()
            if (!$script:loadedPreparation -or $script:worker -or $execute.Checked) { throw 'Loading saved settings started a task or changed execution mode.' }
        }
        if ($ExerciseLanguageSwitch) {
            $savedFields=@($source.Text,$summary.Text,$startDiscId.Text,$labelTemplate.Text)
            $savedScenario=$scenario.SelectedIndex;$savedParity=$parity.SelectedIndex
            $source.Text='Z:\Synthetic 用户\Prepare archive';$summary.Text='准备归档 / BURN DEMO-001'
            $startDiscId.Text='DEMO-009';$labelTemplate.Text='{disc_id}-用户'
            $initialValues=@($source.Text,$summary.Text,$startDiscId.Text,$labelTemplate.Text)
            $requestedLanguage=$Language
            foreach($next in @('en','zh-CN',$requestedLanguage)) {
                $languageChoice.SelectedIndex=if($next -eq 'zh-CN'){1}else{0}
                [Windows.Forms.Application]::DoEvents()
                if (($initialValues -join [char]0) -cne (@($source.Text,$summary.Text,$startDiscId.Text,$labelTemplate.Text) -join [char]0) -or $scenario.SelectedIndex -ne $savedScenario -or $parity.SelectedIndex -ne $savedParity -or $execute.Checked) {throw 'Locale change modified user input or execution state.'}
            }
            $source.Text=$savedFields[0];$summary.Text=$savedFields[1];$startDiscId.Text=$savedFields[2];$labelTemplate.Text=$savedFields[3]
        }
        foreach($control in $originalInteractiveControls) {
            if($control.FindForm() -ne $form){throw "Layout dropped an existing interactive control: $($control.GetType().Name) / $($control.Text)"}
        }
        $form.CreateControl();$tabs.CreateControl()
        $tabs.SelectedIndex=$PreviewTab
        if ($TestScale -ne 1.0) {
            # Layout stress fixture: enlarge fonts, not actual Windows DPI.
            # Actual monitor DPI is reported separately; Windows settings stay intact.
            $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',[single](10*$TestScale))
            $log.Font=New-Object Drawing.Font('Consolas',[single](9*$TestScale))
        }
        $form.Show();[Windows.Forms.Application]::DoEvents();$form.PerformLayout()
        if ($ExerciseTemplatePreview) {
            $tabs.SelectedTab=$volumePage.page;Show-UiControl $volumePreset;[Windows.Forms.Application]::DoEvents()
            $volumePreset.PerformClick();$startDiscId.Text='IPA-009';Refresh-IdentityPreview
            if ($script:volumeBoxes.application.Text -ne 'BDARCHIVE 0.3.0' -or !$idPreview.Text.Contains('IPA-009') -or !$volumePreview.Text.Contains('BDARCHIVE 0.3.0')) { throw 'Template preset or custom ID preview failed.' }
        }
        if ($TestNarrowWindow) { $form.Size=$form.MinimumSize;[Windows.Forms.Application]::DoEvents() }
        . (Join-Path $PSScriptRoot '../tests/ui-layout-assertions.ps1')
        $layoutPages=@()
        foreach ($page in @($preparePage,$discPage,$videoPage,$settingsPage,$idPage,$volumePage)) {
            $tabs.SelectedTab=$page.page;[Windows.Forms.Application]::DoEvents()
            try { Assert-UiLayout $form } catch {
                if ($DiagnosticsPath) {
                    Write-Json (Full-Path $DiagnosticsPath) @{status='FAIL';page=$page.page.Text;controls=@($page.table.Controls | ForEach-Object { @{type=$_.GetType().Name;text=$_.Text;bounds=$_.Bounds.ToString();preferred=$_.GetPreferredSize([Drawing.Size]::Empty).ToString();row=$page.table.GetRow($_)} })}
                }
                throw
            }
            $actions=@($page.table.Controls | ForEach-Object { if ($_ -is [Windows.Forms.FlowLayoutPanel]) { $_.Controls } } | Where-Object { $_ -is [Windows.Forms.Button] })+@($page.actions.Controls | Where-Object {$_ -is [Windows.Forms.Button]})
            foreach ($action in $actions) { Assert-UiReachable $page.page $action }
            $layoutPages+=@{page=$page.page.Text;status='PASS';actions_reachable=$actions.Count;vertical_scroll=$page.viewport.VerticalScroll.Visible}
            $page.viewport.AutoScrollPosition=[Drawing.Point]::Empty
        }
        if ($ExerciseActionLayout) {
            if($execute.Checked -or $make.Enabled){throw 'Build must require an explicit local-build enable'}
            $execute.Checked=$true;if(!$make.Enabled){throw 'Explicit local-build enable did not enable its action'};$execute.Checked=$false
            if($script:worker){throw 'Action state exercise started a worker'}
            $ordered=@($discPage.actions.Controls)
            if($ordered.Count -ne 4 -or $ordered[0] -ne $openStage -or $ordered[1] -ne $burn -or $ordered[2] -ne $verify -or $ordered[3] -ne $register){throw 'Disc action workflow order is wrong'}
            foreach($pg in @($preparePage,$discPage,$videoPage,$settingsPage,$idPage,$volumePage)) {
                $tabs.SelectedTab=$pg.page;[Windows.Forms.Application]::DoEvents()
                $before=$pg.actions.RectangleToScreen($pg.actions.ClientRectangle)
                $pg.viewport.AutoScrollPosition=New-Object Drawing.Point(0,10000);[Windows.Forms.Application]::DoEvents()
                if($before -ne $pg.actions.RectangleToScreen($pg.actions.ClientRectangle)){throw 'Primary action bar moved with content'}
                foreach($button in $pg.actions.Controls){Assert-UiReachable $pg.page $button}
                $pg.viewport.AutoScrollPosition=[Drawing.Point]::Empty
            }
        }
        $tabs.SelectedIndex=$PreviewTab;[Windows.Forms.Application]::DoEvents()
        if ($PreviewTab -eq 1) { Show-UiControl $drive;[Windows.Forms.Application]::DoEvents() }
        $windowContext=[ArchiveNativeDpi]::GetWindowDpiAwarenessContext($form.Handle)
        $diagnostics=[ordered]@{status='PASS';action_layout=$(if($ExerciseActionLayout){'PASS'}else{'NOT_RUN'});language=$Language;language_switch=$(if($ExerciseLanguageSwitch){'PASS'}else{'NOT_RUN'});shell_layout=$shell.LayoutMode;powershell=$PSVersionTable.PSVersion.ToString();per_monitor_v2=[ArchiveNativeDpi]::AreDpiAwarenessContextsEqual($windowContext,[IntPtr](-4));window_dpi=[ArchiveNativeDpi]::GetDpiForWindow($form.Handle);managed_dpi=$form.DeviceDpi;test_text_scale=$TestScale;test_narrow_window=[bool]$TestNarrowWindow;viewport_width=$form.ClientSize.Width;viewport_height=$form.ClientSize.Height;pages=$layoutPages;default_execute=$execute.Checked;default_id_execute=$idExecute.Checked;id_preview=$idPreview.Text;counter_rows=$counterGrid.Rows.Count}
        if ($ExerciseConcurrentJobs) {. (Join-Path $PSScriptRoot '../tests/ui-concurrent-jobs.ps1')}
        if ($ExerciseExternalStage) {. (Join-Path $PSScriptRoot '../tests/ui-external-stage.ps1')}
        if ($ExerciseVerificationProgress) {
            . (Join-Path $PSScriptRoot '../tests/ui-verification-progress.ps1')
        }
        $diagnostics.optical_choices=$drive.Items.Count;$diagnostics.manual_drive_input=($drive.DropDownStyle -ne 'DropDownList');$diagnostics.post_burn_verify=$postBurnVerify.Checked;$diagnostics.deep_dwarfs_verify=$deepVerify.Checked
        if ($OpticalTestFixture) {
            if ($drive.Items.Count -ne 2 -or (Selected-OpticalDrive) -ne 'X:') { throw 'Optical dropdown initial selection failed.' }
            $drive.SelectedIndex=1;Refresh-OpticalDevices
            if ((Selected-OpticalDrive) -ne 'Y:' -or !$mediaInfo.Text.Contains('BD-R')) { throw 'Optical selection/media refresh failed.' }
            $diagnostics.optical_selection='PASS'
        }
        if (!$diagnostics.per_monitor_v2) { throw 'Actual window is not Per-Monitor V2 aware.' }
        if ($ExerciseRenamePreview) {
            $before=File-Hash (Catalog-Path (Load-Config $configBox.Text))
            foreach ($action in @('disc','set')) {
                $tabs.SelectedTab=$idPage.page;$form.Show();[Windows.Forms.Application]::DoEvents()
                $indexGrid.ClearSelection()
                $selected=@($indexGrid.Rows | Where-Object { $_.Tag -and $_.Tag.disc_id -ceq $RenameTestDiscId })
                if ($selected.Count -ne 1) { throw 'Rename preview fixture is missing.' }
                $selected[0].Selected=$true
                if ($idExecute.Checked) { throw 'Rename UI must default to preview.' }
                $idNewDiscId.Text='GUI-009';$idNewSetId.Text='GUI-NEW-SET'
                $button=if ($action -eq 'disc') { $idRenameDisc } else { $idRenameSet }
                Show-UiControl $button;[Windows.Forms.Application]::DoEvents();$button.PerformClick()
                if (!$script:worker) { throw 'Rename button did not start a worker.' }
                $deadline=[DateTime]::UtcNow.AddSeconds(25)
                while (!$script:worker.HasExited -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(100) }
                if (!$script:worker.HasExited) { throw 'Rename preview worker timed out.' }
                $result=Read-Json ($script:jobPath+'.result.json')
                if ($script:worker.ExitCode -ne 0 -or $result.result.status -ne 'DRY_RUN' -or $result.result.action -ne ('rename-'+$action)) { throw 'Rename button preview failed.' }
                Update-ArchiveJob
            }
            if ((File-Hash (Catalog-Path (Load-Config $configBox.Text))) -ne $before) { throw 'Rename preview changed the catalog.' }
            $diagnostics.rename_disc_button='DRY_RUN_PASS';$diagnostics.rename_set_button='DRY_RUN_PASS'
        }
        if ($ExercisePreparationStop) {
            $fixture=Read-Json (Full-Path $StopTestRequestPath)
            if ($fixture.command -ne 'prepare') { throw 'Stop test only accepts preparation.' }
            $testParams=@{};foreach ($prop in $fixture.parameters.PSObject.Properties) { $testParams[$prop.Name]=$prop.Value }
            $scenario.SelectedIndex=2;$source.Text=$testParams.Source;$setId.Text=$testParams.SetId;$execute.Checked=$true
            $tabs.SelectedTab=$preparePage.page;$form.Show();[Windows.Forms.Application]::DoEvents()
            Start-ArchiveJob prepare $testParams
            $deadline=[DateTime]::UtcNow.AddSeconds(35)
            while ($script:worker -and !$script:worker.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                Update-ArchiveJob;[Windows.Forms.Application]::DoEvents()
                if ($log.Text -match '==>') { break }
                [Threading.Thread]::Sleep(100)
            }
            if (!$script:worker -or $script:worker.HasExited -or $log.Text -notmatch '==>') { throw 'GUI did not show native progress before completion.' }
            if (!$stopPrepare.Enabled -or !$stopPrepare.Visible) { throw 'Stop button is not available while preparing.' }
            $bounds=$form.RectangleToClient($stopPrepare.RectangleToScreen($stopPrepare.ClientRectangle))
            if (!$form.ClientRectangle.Contains($bounds)) { throw 'Stop button lies outside viewport.' }
            if ($PreviewPath) {
                $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
                try { $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Full-Path $PreviewPath)) } finally { $bitmap.Dispose() }
            }
            $stopPrepare.PerformClick()
            if (!$script:stopRequested -or $stopPrepare.Enabled) { throw 'Stop click did not request cancellation.' }
            $deadline=[DateTime]::UtcNow.AddSeconds(12)
            while ($script:worker -and [DateTime]::UtcNow -lt $deadline) { Update-ArchiveJob;[Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(100) }
            if ($script:worker) { throw 'GUI cancellation timed out.' }
            $stopResult=Read-Json ($script:jobPath+'.result.json')
            if ($stopResult.status -ne 'CANCELLED' -or $status.Text -notmatch (Get-ArchiveText 'legacy.805936f168c5')) { throw 'GUI did not report cancellation.' }
            $diagnostics.preparation_stop_button='PASS';$diagnostics.stop_test_request=$script:jobPath
            $diagnostics.live_progress_before_exit=$true;$diagnostics.stop_visible_in_narrow_view=$true
            $form.Hide()
        }
        if ($DiagnosticsPath) { Write-Json (Full-Path $DiagnosticsPath) $diagnostics }
        $form.Hide()
        if ($PreviewPath -and !$ExercisePreparationStop) {
            $form.Show();[Windows.Forms.Application]::DoEvents()
            if ($PreviewTab -eq 3) { Show-UiControl $burnSpeed;[Windows.Forms.Application]::DoEvents() }
            $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
            try { $bounds=New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height);$form.DrawToBitmap($bitmap,$bounds);$bitmap.Save((Full-Path $PreviewPath),[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
            $form.Hide()
        }
        $dryJob=$null
        if ($ExerciseDryRun) {
            # Exercise the real button event and worker using default Execute=false.
            # Never click a burn, verification, deletion or registration action.
            if ($execute.Checked) { throw 'GUI default must be dry-run.' }
            $tabs.SelectedIndex=0;$form.Show();Show-UiControl $previewPrepare;[Windows.Forms.Application]::DoEvents();$previewPrepare.PerformClick()
            if (!$script:worker) { throw 'Prepare button did not start the worker.' }
            $deadline=[DateTime]::UtcNow.AddSeconds(25)
            while (!$script:worker.HasExited -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(100) }
            if (!$script:worker.HasExited) { throw 'Dry-run worker did not finish within 25 seconds.' }
            $dryJob=Read-Json "$script:jobPath.result.json"
            if ($script:worker.ExitCode -ne 0 -or $dryJob.result.status -ne 'DRY_RUN') { throw 'Prepare click failed to preserve dry-run.' }
            $script:worker.Dispose();$script:worker=$null;$form.Hide()
        }
        if ($ExerciseResumeSettings) {
            $wanted=$script:loadedPreparation.parameters
            if (!$dryJob -or $dryJob.result.parameters.ParPercent -ne $wanted.ParPercent -or $dryJob.result.parameters.StartDiscId -cne $wanted.StartDiscId) { throw 'Loaded resume settings did not reach the dry-run worker.' }
            foreach ($key in $script:volumeBoxes.Keys) { if ($dryJob.result.parameters.VolumeTemplates.$key -cne $wanted.VolumeTemplates[$key]) { throw "Resume template mismatch: $key" } }
            $diagnostics.resume_settings='PASS';$diagnostics.resume_set=$wanted.SetId;$diagnostics.resume_par_percent=$wanted.ParPercent
            $diagnostics.resume_preview=$idPreview.Text
        }
        $diagnostics.dry_run_button_test=if ($dryJob) { 'PASS' } else { 'NOT_RUN' };$diagnostics.burn_worker_started=$false
        $diagnostics.template_preview_button_test=if ($ExerciseTemplatePreview) {'PASS'} else {'NOT_RUN'}
        if ($ExerciseTemplatePreview -and $dryJob) {
            if ($dryJob.result.parameters.StartDiscId -ne 'IPA-009' -or $dryJob.result.parameters.VolumeTemplates.application -ne 'BDARCHIVE 0.3.0') { throw 'GUI worker lost custom ID or volume templates.' }
        }
        $diagnostics.id_counter_preview_button_test='NOT_RUN'
        if ($ExerciseIdPreview) {
            if ($idExecute.Checked) { throw 'ID management must default to preview.' }
            $tabs.SelectedTab=$idPage.page;$form.Show();Show-UiControl $idApply;[Windows.Forms.Application]::DoEvents();$idApply.PerformClick()
            if (!$script:worker) { throw 'ID preview button did not start its worker.' }
            $deadline=[DateTime]::UtcNow.AddSeconds(20)
            while (!$script:worker.HasExited -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(100) }
            if (!$script:worker.HasExited) { throw 'ID preview worker timed out.' }
            $idJob=Read-Json "$script:jobPath.result.json"
            if ($script:worker.ExitCode -ne 0 -or $idJob.result.status -ne 'DRY_RUN') { throw 'ID counter preview did not preserve dry-run.' }
            $script:worker.Dispose();$script:worker=$null;$form.Hide()
            $diagnostics.id_counter_preview_button_test='PASS'
        }
        if ($DiagnosticsPath) { Write-Json (Full-Path $DiagnosticsPath) $diagnostics }
        $diagnostics | ConvertTo-Json -Depth 8
    } else { $timer.Start();[Windows.Forms.Application]::Run($form) }
} finally { $deviceTimer.Stop();$deviceTimer.Dispose();if ($script:deviceWorker) {$script:deviceWorker.Dispose()};$timer.Stop();$timer.Dispose();$form.Dispose();Restore-ArchiveDpi $dpiState }
