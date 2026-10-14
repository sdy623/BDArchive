# Dot-sourced by archive-ui SmokeTest with a synthetic prepared directory.
$fixture=Read-Json (Full-Path $ExternalTestFixture)
if ((Full-Path $fixture.config) -ine $script:configPath) {throw 'UI fixture/config mismatch.'}
$tabs.SelectedTab=$discPage.page
$grid.ClearSelection()
$selected=@($grid.Rows | Where-Object {$_.Cells[0].Value -ceq $fixture.disc_id})
if ($selected.Count -ne 1 -or $externalExecute.Checked) {throw 'External stage UI must have a fixture and default to preview.'}
$selected[0].Selected=$true
$externalRoot.Text=Join-Path $fixture.root '00_DISC_CATALOG'
$c=Load-Config $script:configPath;$before=File-Hash (Catalog-Path $c)
foreach ($executeImport in @($false,$true)) {
    $externalExecute.Checked=$executeImport
    Show-UiControl $externalImport;[Windows.Forms.Application]::DoEvents()
    $externalImport.PerformClick()
    if (!$script:worker) {throw 'External import button did not start its worker.'}
    $deadline=[DateTime]::UtcNow.AddSeconds(25)
    while (!$script:worker.HasExited -and [DateTime]::UtcNow -lt $deadline) {[Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(50)}
    if (!$script:worker.HasExited) {throw 'External import UI worker timed out.'}
    $result=Read-Json ($script:jobPath+'.result.json')
    $wanted=if ($executeImport) {'STAGED'} else {'DRY_RUN'}
    if ($script:worker.ExitCode -ne 0 -or $result.result.status -ne $wanted -or $result.result.root -ine $fixture.root) {throw ('External stage UI result: '+($result | ConvertTo-Json -Depth 5))}
    if (!$executeImport -and (File-Hash (Catalog-Path $c)) -cne $before) {throw 'Preview changed catalog.'}
    Update-ArchiveJob
    $grid.ClearSelection();@($grid.Rows | Where-Object {$_.Cells[0].Value -ceq $fixture.disc_id})[0].Selected=$true
}
$diagnostics.external_import_default_preview='PASS'
$diagnostics.external_import_worker_execute='PASS'
$diagnostics.external_import_whole_root='PASS'
$externalExecute.Checked=$false
Show-UiControl $externalImport;[Windows.Forms.Application]::DoEvents()
