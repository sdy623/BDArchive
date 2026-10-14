# A separate scrollable page keeps optional descriptor fields out of the main flow.
$volumePage=New-UiPage $tabs (Get-ArchiveText 'nav.volumes');$volumeTable=$volumePage.table
Add-UiRow $volumeTable @((New-UiLabel (Get-ArchiveText 'legacy.b79d2762f1cf')))
$volumeBackend=New-UiChoice @('IMAPI2','ImgBurn');Add-UiSetting $volumeTable (Get-ArchiveText 'legacy.52d1a88a8abe') $volumeBackend
Add-UiRow $volumeTable @((New-UiLabel (Get-ArchiveText 'legacy.59b1870b28e1')))
$script:volumeBoxes=@{}
$volumeCaptions=[ordered]@{iso9660=(Get-ArchiveText 'legacy.0c796dd4a26b');joliet=(Get-ArchiveText 'legacy.08ae3e43f479');system='System';volume_set='Volume Set';publisher='Publisher';data_preparer='Data Preparer';application='Application'}
foreach ($key in $volumeCaptions.Keys) { $box=New-UiField;$script:volumeBoxes[$key]=$box;Add-UiSetting $volumeTable $volumeCaptions[$key] $box;$box.Add_TextChanged({ Refresh-VolumePreview }) }
Add-UiRow $volumeTable @((New-UiLabel (Get-ArchiveText 'legacy.13bf910f5fd3')))
$volumePreset=New-UiButton (Get-ArchiveText 'legacy.ba2245a421b1');$volumeSave=New-UiButton (Get-ArchiveText 'legacy.79ff6bbe97d2');Add-UiRow $volumeTable @((New-UiFlow @($volumePreset,$volumeSave)))
$volumePreview=New-UiField;$volumePreview.Multiline=$true;$volumePreview.ReadOnly=$true;$volumePreview.ScrollBars='Both';$volumePreview.Height=205;Add-UiRow $volumeTable @($volumePreview)
function Get-UiVolumeTemplates {
    $values=@{};foreach ($key in $script:volumeBoxes.Keys) { $values[$key]=$script:volumeBoxes[$key].Text };$values
}
function Refresh-VolumePreview {
    if (!$volumePreview -or !$script:previewDisc) { return }
    try {
        $t=Volume-Templates (Load-Config $configBox.Text) @{VolumeLabelTemplate=$labelTemplate.Text;VolumeTemplates=(Get-UiVolumeTemplates)}
        $m=New-VolumeMetadata $t $script:previewDisc
        $lines=@((Get-ArchiveText 'legacy.7a3647c5dfcb'))
        foreach ($f in $m.values.PSObject.Properties) {
            $target=if ($f.Name -eq 'udf') {(Get-ArchiveText 'legacy.7b61afb568da')} elseif ($f.Name -eq 'application') {if ($volumeBackend.SelectedItem -eq 'ImgBurn') {(Get-ArchiveText 'legacy.0633fcccf38c')} else {(Get-ArchiveText 'legacy.3a2a100c5d8e')}} elseif ($f.Name -eq 'volume_set') {(Get-ArchiveText 'legacy.91a88222fe42')} else {(Get-ArchiveText 'legacy.59aca8963ef7')}
            $lines+="$($f.Name) = $($f.Value)  [$target]"
        }
        $volumePreview.Text=$lines -join "`r`n"
    } catch { $volumePreview.Text=(Get-ArchiveText 'legacy.4e815ecf52f3')+$_.Exception.Message }
}
$volumePreset.Add_Click({
    $script:volumeBoxes.volume_set.Text='{set_id}';$script:volumeBoxes.application.Text='BDARCHIVE 0.3.0'
    $volumeBackend.SelectedItem='ImgBurn';Refresh-VolumePreview
})
$volumeBackend.Add_SelectedIndexChanged({ Refresh-VolumePreview })
$volumeSave.Add_Click({ try {
    if (Test-AnyArchiveJobRunning) { throw (Get-ArchiveText 'legacy.817c350b2703') }
    $c=Read-Json (Full-Path $configBox.Text)
    $null=New-VolumeMetadata (Volume-Templates $c @{VolumeLabelTemplate=$labelTemplate.Text;VolumeTemplates=(Get-UiVolumeTemplates)}) $script:previewDisc
    $numbering=Optional-Field $c 'numbering';if (!$numbering) { $numbering=[pscustomobject]@{} }
    $numbering | Add-Member NoteProperty volume_label_template $labelTemplate.Text -Force
    $numbering | Add-Member NoteProperty volume_templates ([pscustomobject](Get-UiVolumeTemplates)) -Force
    $c | Add-Member NoteProperty numbering $numbering -Force
    $c.burn.backend=[string]$volumeBackend.SelectedItem
    Write-Json (Full-Path $configBox.Text) $c;$status.Text=(Get-ArchiveText 'legacy.af1ff01269e3')
} catch { Show-Error $_ } })
