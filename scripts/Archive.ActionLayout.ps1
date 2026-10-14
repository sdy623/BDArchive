# Presentation-only regrouping: reuse the original controls and event handlers.
function Reset-UiRows($Table) {$Table.Controls.Clear();$Table.RowStyles.Clear();$Table.RowCount=0}
function Add-UiSection($Table,[string]$Key) {
 $heading=New-UiLabel (Get-ArchiveText $Key);$heading.Font=New-ArchiveFont -Role Ui -Size 10 -Bold
 $heading.Margin=New-Object Windows.Forms.Padding(4,18,4,8);$heading.Tag='section-heading';Add-UiRow $Table @($heading)
}
Reset-UiRows $prepare
Add-UiSection $prepare 'section.source'
Add-UiSetting $prepare (Get-ArchiveText 'legacy.155ae10dfd6d') $scenario
Add-UiSetting $prepare (Get-ArchiveText 'legacy.2d1caead9543') $tier
Add-UiSetting $prepare (Get-ArchiveText 'legacy.0acd4d885ae0') (New-UiPicker $source $browseSource)
Add-UiRow $prepare @($prepareNote)
Add-UiSection $prepare 'section.identity'
Add-UiSetting $prepare 'Archive ID' (New-UiPicker $setId $loadPlan)
Add-UiSetting $prepare (Get-ArchiveText 'legacy.f7a77db0afdb') $media
Add-UiSetting $prepare (Get-ArchiveText 'legacy.0cc3722b776a') $startDiscId
Add-UiSetting $prepare (Get-ArchiveText 'legacy.4f0417c97066') $labelTemplate
Add-UiRow $prepare @($idPreview)
Add-UiRow $prepare @((New-UiLabel (Get-ArchiveText 'legacy.7de7fc33aa6d')))
Add-UiSection $prepare 'section.metadata'
Add-UiSetting $prepare (Get-ArchiveText 'legacy.4b3a77b9804d') $summary
Add-UiSetting $prepare (Get-ArchiveText 'legacy.5a7124fff1fb') $dateRange
Add-UiSetting $prepare (Get-ArchiveText 'legacy.c2c7819ad34b') $subject
Add-UiSetting $prepare (Get-ArchiveText 'legacy.0427793f3431') $second
Add-UiSetting $prepare (Get-ArchiveText 'legacy.342a873c23b5') $password
Add-UiSection $prepare 'section.protection'
Add-UiSetting $prepare (Get-ArchiveText 'legacy.012527446886') $parity
Add-UiRow $prepare @($dedup)
$previewPrepare=New-UiButton (Get-ArchiveText 'action.preview')
$previewPrepare.Add_Click({Invoke-UiPreparation $false})
$execute.Text=Get-ArchiveText 'action.allowBuild';$make.Text=Get-ArchiveText 'action.build';$make.Enabled=$execute.Checked
$execute.Add_CheckedChanged({$make.Enabled=$execute.Checked})
Add-UiActionBar $preparePage @($previewPrepare,$execute,$make)

Reset-UiRows $discs
Add-UiSection $discs 'section.discs'
Add-UiRow $discs @((New-UiFlow @($refresh,$view)))
Add-UiRow $discs @($grid)
Add-UiSection $discs 'section.device'
Add-UiSetting $discs (Get-ArchiveText 'legacy.851764e61ef9') (New-UiPicker $drive $refreshDrives)
Add-UiRow $discs @($mediaInfo)
Add-UiSection $discs 'section.verify'
Add-UiRow $discs @($reloaded);Add-UiRow $discs @($deepVerify)
Add-UiSetting $discs (Get-ArchiveText 'legacy.4c27174b03b8') $location
Add-UiSection $discs 'section.external'
Add-UiSetting $discs (Get-ArchiveText 'legacy.79f2b68249ae') (New-UiPicker $externalRoot $externalBrowse)
Add-UiRow $discs @((New-UiFlow @($externalExecute,$externalImport)))
Add-UiRow $discs @((New-UiLabel (Get-ArchiveText 'legacy.9e19ff37322b')))
Add-UiSection $discs 'section.restore'
Add-UiSetting $discs (Get-ArchiveText 'legacy.caecb5d342cc') (New-UiPicker $restoreOutput $restoreBrowse)
Add-UiRow $discs @((New-UiFlow @($restore)))
Add-UiRow $discs @((New-UiLabel (Get-ArchiveText 'legacy.ad5d1cd94bcc')))
Add-UiSection $discs 'section.maintenance'
Add-UiRow $discs @((New-UiFlow @($sim,$recoverBurn,$repairVerify,$clearSimulation)))
$openStage.Text=Get-ArchiveText 'action.reviewStage';$burn.Text=Get-ArchiveText 'action.writeMedia'
$verify.Text=Get-ArchiveText 'action.verifyMedia';$register.Text=Get-ArchiveText 'action.registerMedia'
Add-UiActionBar $discPage @($openStage,$burn,$verify,$register)
Add-UiActionBar $videoPage @($videoExecute,$split,$sheet)
Add-UiActionBar $settingsPage @($detectTools,$fillTools,$guide,$saveConfig)
Add-UiActionBar $volumePage @($volumePreset,$volumeSave)

Reset-UiRows $identityTable
Add-UiRow $identityTable @($idMetadata)
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.282558dba0f1')))
Add-UiSection $identityTable 'section.counter'
Add-UiRow $identityTable @($counterGrid)
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.074322147ab9') $idPrefix
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.b3e96a978922') $idNext
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.ae55f6952a17') $idReason
Add-UiRow $identityTable @((New-UiFlow @($idExecute,$idApply)))
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.1f98508359fc')))
Add-UiSection $identityTable 'section.records'
Add-UiRow $identityTable @($indexGrid);Add-UiRow $identityTable @($idDetails)
Add-UiSection $identityTable 'section.rename'
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.0bbbaab721bc') $idNewDiscId
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.af96185c33f0') $idNewSetId
Add-UiRow $identityTable @((New-UiFlow @($idRenameDisc,$idRenameSet,$idRepair)))
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.6a937ada7d15')))
Add-UiSection $identityTable 'section.removed'
Add-UiRow $identityTable @($idShowDeleted);Add-UiRow $identityTable @((New-UiFlow @($idDelete,$idRestore,$idInit)))
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.3195c54f27ac')))
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.b4e583f55822') $idOrphanSet
Add-UiRow $identityTable @((New-UiFlow @($idDeleteOrphan,$idDiscardPlan)))
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.bd408e4fa8a3')))
Add-UiActionBar $idPage @($idRefresh,$idExport)
