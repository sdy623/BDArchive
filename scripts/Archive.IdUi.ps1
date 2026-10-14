# Dot-sourced by archive-ui after its controls are created. UI-only helpers;
# calls the existing JSON worker for every write. No disc operation here.
$idPage=New-UiPage $tabs (Get-ArchiveText 'nav.identities');$identityTable=$idPage.table
$idMetadata=New-UiLabel (Get-ArchiveText 'legacy.b5c26a032a1f');Add-UiRow $identityTable @($idMetadata)
$counterGrid=New-Object Windows.Forms.DataGridView;$counterGrid.Dock='Fill';$counterGrid.Height=155
$counterGrid.ReadOnly=$true;$counterGrid.AllowUserToAddRows=$false;$counterGrid.AllowUserToDeleteRows=$false
$counterGrid.AutoSizeColumnsMode='Fill';$counterGrid.ColumnHeadersHeightSizeMode='AutoSize'
foreach ($caption in @((Get-ArchiveText 'legacy.0d12cbd6562b'),(Get-ArchiveText 'legacy.a57886f06767'),(Get-ArchiveText 'legacy.25524837dbed'),(Get-ArchiveText 'legacy.593ad09b76fc'))) { $null=$counterGrid.Columns.Add($caption,$caption) }
Add-UiRow $identityTable @($counterGrid)
$idPrefix=New-UiChoice @((Get-ArchiveText 'legacy.442a5a991094'),(Get-ArchiveText 'legacy.d35ef1c053a9'),(Get-ArchiveText 'legacy.d606c4a05ac5'),(Get-ArchiveText 'legacy.686ddd4ac841'))
# .NET Framework NumericUpDown repeatedly rescales its margins on this
# scrolling high-DPI page. A plain field avoids that bug; backend validates
# the integer and 1..2147483647 range before any counter mutation.
$idNext=New-UiField '1'
$idReason=New-UiField
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.074322147ab9') $idPrefix
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.b3e96a978922') $idNext
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.ae55f6952a17') $idReason
$idExecute=New-UiCheck (Get-ArchiveText 'legacy.1840accc5afa');Add-UiRow $identityTable @($idExecute)
$idRefresh=New-UiButton (Get-ArchiveText 'legacy.afd0a82897b2');$idApply=New-UiButton (Get-ArchiveText 'legacy.2b3248a99bb1');$idInit=New-UiButton (Get-ArchiveText 'legacy.572f6383838b');$idExport=New-UiButton (Get-ArchiveText 'legacy.6fed06d9eb35')
Add-UiRow $identityTable @((New-UiFlow @($idRefresh,$idApply,$idInit,$idExport)))
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.1f98508359fc')))
$idShowDeleted=New-UiCheck (Get-ArchiveText 'legacy.8879bf47a0db');Add-UiRow $identityTable @($idShowDeleted)
$idDelete=New-UiButton (Get-ArchiveText 'legacy.948725d00ec0');$idRestore=New-UiButton (Get-ArchiveText 'legacy.675c2e148a7a');Add-UiRow $identityTable @((New-UiFlow @($idDelete,$idRestore)))
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.3195c54f27ac')))
$idNewDiscId=New-UiField;$idNewSetId=New-UiField
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.0bbbaab721bc') $idNewDiscId
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.af96185c33f0') $idNewSetId
$idRenameDisc=New-UiButton (Get-ArchiveText 'legacy.94aa1369f187');$idRenameSet=New-UiButton (Get-ArchiveText 'legacy.3a5fadaf7625');$idRepair=New-UiButton (Get-ArchiveText 'legacy.8e7988621cb2')
Add-UiRow $identityTable @((New-UiFlow @($idRenameDisc,$idRenameSet,$idRepair)))
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.6a937ada7d15')))
$indexGrid=New-Object Windows.Forms.DataGridView;$indexGrid.Dock='Fill';$indexGrid.Height=220
$indexGrid.ReadOnly=$true;$indexGrid.AllowUserToAddRows=$false;$indexGrid.AllowUserToDeleteRows=$false
$indexGrid.AutoSizeColumnsMode='DisplayedCells';$indexGrid.ColumnHeadersHeightSizeMode='AutoSize';$indexGrid.MultiSelect=$false;$indexGrid.SelectionMode='FullRowSelect'
foreach ($caption in @((Get-ArchiveText 'legacy.f7488f3bd4db'),(Get-ArchiveText 'legacy.4281377fe54e'),'Archive Set','Volume ID',(Get-ArchiveText 'legacy.70ff067cb6fc'),(Get-ArchiveText 'legacy.baeda3c9e221'),(Get-ArchiveText 'legacy.4e59591912f8'),(Get-ArchiveText 'legacy.6320b4a8722a'))) { $null=$indexGrid.Columns.Add($caption,$caption) }
Add-UiRow $identityTable @($indexGrid)
$idDetails=New-UiField;$idDetails.Multiline=$true;$idDetails.ReadOnly=$true;$idDetails.ScrollBars='Both';$idDetails.Height=130;Add-UiRow $identityTable @($idDetails)
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.282558dba0f1')))
function Refresh-IdentityView {
    $script:idSnapshot=Get-ArchiveIds (Load-Config $configBox.Text)
    $counterGrid.Rows.Clear();$indexGrid.Rows.Clear()
    $categoryNames=@{P=(Get-ArchiveText 'legacy.44f6c330de48');G=(Get-ArchiveText 'legacy.d86a2aff5614');B=(Get-ArchiveText 'legacy.14589ad81f10');M=(Get-ArchiveText 'legacy.7edc563184e6')}
    foreach ($r in $script:idSnapshot.counters) { $null=$counterGrid.Rows.Add([object[]]@($categoryNames[$r.prefix],$r.last_number,$r.next_disc_id,$r.allocated_discs)) }
    $visibleRows=@($script:idSnapshot.discs);if ($idShowDeleted.Checked) { $visibleRows+=@($script:idSnapshot.deleted_discs) }
    foreach ($r in @($visibleRows | Sort-Object disc_index,disc_id)) {
        $serial=if ($r.filesystem_serial) { $r.filesystem_serial } else { (Get-ArchiveText 'legacy.a4c2a7fcb6a5') }
        $index=if ($r.disc_index) { '{0:D6}' -f [int64]$r.disc_index } else { (Get-ArchiveText 'legacy.ecd78be1b517') }
        $row=$indexGrid.Rows.Add([object[]]@($index,$r.disc_id,$r.archive_set_id,$r.volume_id,"$($r.volume_index)/$($r.volume_count)",$r.volume_label,$serial,$(if ($r.catalog_deleted) {(Get-ArchiveText 'legacy.0d2eb7740c17')+$r.status} else {$r.status})))
        $indexGrid.Rows[$row].Tag=$r
    }
    $library=if ($script:idSnapshot.catalog_id) { $script:idSnapshot.catalog_id } else { (Get-ArchiveText 'legacy.5f9f1a0c87b8') }
    $idMetadata.Text=(Get-ArchiveText 'legacy.60cd5eddf58e' -Arguments @(($library), ($($script:idSnapshot.disc_index_next)), ($($script:idSnapshot.legacy_unindexed)), ($($script:idSnapshot.archive_root))))
    Set-NextCounterField;Refresh-IdentityPreview
}
function Set-NextCounterField {
    if ($script:idSnapshot) {
        $selected=@('P','G','B','M')[$idPrefix.SelectedIndex]
        $row=@($script:idSnapshot.counters | Where-Object prefix -eq $selected)[0]
        $idNext.Text=[string]$row.next_number
    }
}
function Refresh-IdentityPreview {
    if (!$script:idSnapshot) { return }
    try {
        if ((Get-Variable -Name loadedPreparation -Scope Script -ErrorAction SilentlyContinue) -and $script:loadedPreparation -and $script:loadedPreparation.parameters.SetId -ceq $setId.Text.Trim()) {
            $script:previewDisc=$script:loadedPreparation.first_disc
            $idPreview.Text=(Get-ArchiveText 'legacy.fa68a46a0a7c' -Arguments @(($($script:previewDisc.disc_id)), ($($script:loadedPreparation.disc_count))))
            if (Get-Command Refresh-VolumePreview -ErrorAction SilentlyContinue) { Refresh-VolumePreview }
            return
        }
        $prefix=@('P','G','B')[$scenario.SelectedIndex]
        if ($scenario.SelectedIndex -eq 0 -and $tier.SelectedIndex -eq 2) { $prefix='M' }
        $next=@($script:idSnapshot.counters | Where-Object prefix -eq $prefix)[0]
        Assert-Id $setId.Text.Trim()
        $d=[pscustomobject]@{disc_id=$(if ($startDiscId.Text.Trim()) { Batch-DiscId $startDiscId.Text.Trim() } else { $next.next_disc_id });catalog_id=$script:idSnapshot.catalog_id;disc_index=$script:idSnapshot.disc_index_next;archive_set_id=$setId.Text.Trim();position=1;disc_count=1}
        $script:previewDisc=$d
        Assert-DiscIdAvailable (Load-Config $configBox.Text) (Catalog-Snapshot (Load-Config $configBox.Text)) $d.disc_id
        $label=Format-VolumeLabel $labelTemplate.Text $d
        $idPreview.Text=(Get-ArchiveText 'legacy.e90b319aa524' -Arguments @(($($d.disc_id)), ($($d.disc_index)), ($((Disc-Identity $d).volume_id)), ($label)))
        if (Get-Command Refresh-VolumePreview -ErrorAction SilentlyContinue) { Refresh-VolumePreview }
    } catch { $idPreview.Text=(Get-ArchiveText 'legacy.49760c568a0c' -Arguments @(($($_.Exception.Message)))) }
}
$script:idSnapshot=$null
$idPrefix.Add_SelectedIndexChanged({ Set-NextCounterField })
$idRefresh.Add_Click({ try { Refresh-IdentityView } catch { Show-Error $_ } })
$idApply.Add_Click({ try { Start-ArchiveJob set-counter @{Prefix=@('P','G','B','M')[$idPrefix.SelectedIndex];NextNumber=[int64]$idNext.Text.Trim();Reason=$idReason.Text;Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$idInit.Add_Click({ try { Start-ArchiveJob init @{Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$idExport.Add_Click({ try { Start-ArchiveJob export-index @{Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$indexGrid.Add_SelectionChanged({
    if ($indexGrid.SelectedRows.Count -and $indexGrid.SelectedRows[0].Tag) { $idDetails.Text=$indexGrid.SelectedRows[0].Tag | ConvertTo-Json -Depth 6 }
})
$scenario.Add_SelectedIndexChanged({ Refresh-IdentityPreview });$tier.Add_SelectedIndexChanged({ Refresh-IdentityPreview })
$setId.Add_TextChanged({ Refresh-IdentityPreview });$labelTemplate.Add_TextChanged({ Refresh-IdentityPreview })

$startDiscId.Add_TextChanged({ Refresh-IdentityPreview })
$idShowDeleted.Add_CheckedChanged({ try { Refresh-IdentityView } catch { Show-Error $_ } })
function Selected-IdentityRow {
    if (!$indexGrid.SelectedRows.Count -or !$indexGrid.SelectedRows[0].Tag) { throw (Get-ArchiveText 'legacy.4c23fcdbbf2d') }
    $indexGrid.SelectedRows[0].Tag
}
$idRenameDisc.Add_Click({ try { $r=Selected-IdentityRow;Start-ArchiveJob rename-disc @{DiscId=$r.disc_id;NewDiscId=$idNewDiscId.Text.Trim();Reason=$idReason.Text;Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$idRenameSet.Add_Click({ try { $r=Selected-IdentityRow;Start-ArchiveJob rename-set @{SetId=$r.archive_set_id;NewSetId=$idNewSetId.Text.Trim();Reason=$idReason.Text;Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$idRepair.Add_Click({ try { Start-ArchiveJob repair-identity-change @{Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$idDelete.Add_Click({ try { $r=Selected-IdentityRow;Start-ArchiveJob delete-disc-record @{DiscId=$r.disc_id;Reason=$idReason.Text;Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$idRestore.Add_Click({ try { $r=Selected-IdentityRow;Start-ArchiveJob restore-disc-record @{DiscId=$r.disc_id;Reason=$idReason.Text;Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$idOrphanSet=New-UiField
$idDeleteOrphan=New-UiButton (Get-ArchiveText 'legacy.66944b79abd7')
$idDiscardPlan=New-UiButton (Get-ArchiveText 'legacy.953d6fab8c09')
Add-UiSetting $identityTable (Get-ArchiveText 'legacy.b4e583f55822') $idOrphanSet
Add-UiRow $identityTable @((New-UiFlow @($idDeleteOrphan,$idDiscardPlan)))
Add-UiRow $identityTable @((New-UiLabel (Get-ArchiveText 'legacy.bd408e4fa8a3')))
$idDeleteOrphan.Add_Click({ try { $id=$idOrphanSet.Text.Trim();if(!$id){throw (Get-ArchiveText 'legacy.8449e2ad209d')};Start-ArchiveJob delete-orphan-set @{SetId=$id;Reason=$idReason.Text;Execute=$idExecute.Checked} } catch { Show-Error $_ } })
$idDiscardPlan.Add_Click({ try { $id=$idOrphanSet.Text.Trim();if(!$id){throw (Get-ArchiveText 'legacy.9bf417058530')};Start-ArchiveJob discard-unburned-plan @{SetId=$id;Reason=$idReason.Text;Execute=$idExecute.Checked} } catch { Show-Error $_ } })

# Keep label preferred heights independent of the AutoSize row's assigned
# height while this longer page is resized or scrolled at high DPI.
foreach ($control in $identityTable.Controls) { if ($control -is [Windows.Forms.Label]) { $control.Dock='Top' } }
