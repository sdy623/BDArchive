[CmdletBinding()]
param([string]$WorkRoot,[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/burn-preflight' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json');$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
$source=Join-Path $run '合成 source';Write-Text (Join-Path $source 'fixture.bin') 'Synthetic burn preflight. No optical hardware is accessed.'
$c.tools.imgburn=Join-Path $run 'never-execute.exe';Write-Text $c.tools.imgburn 'Not an executable. The test always cancels before tool invocation.'
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
function Run($Command,$Extra=@{}) { $p=@{Config=$cfg;Execute=$true};foreach($k in $Extra.Keys){$p[$k]=$Extra[$k]};Invoke-Archive $Command $p }
function Assert($Value,$Message='Assertion failed') { if (!$Value) { throw $Message } }
$null=Run init;$null=Run scan @{SetId='TEST-PREFLIGHT';Source=$source;Scenario='photo';PhotoTier='C'};$null=Run plan @{SetId='TEST-PREFLIGHT';ParPercent=0};$null=Run stage @{DiscId='BD-P-0001'}
$payload=Join-Path $c.archive_root 'staging/BD-P-0001/data/fixture.bin';$results=@()
# Replace only this module instance's device factory and review with synthetic
# objects / unconditional cancellation. There is no approving test path.
& (Get-Module Archive.Core) {
    param($Payload)
    $script:testPayload=$Payload;$script:hashReads=0;$script:reviewCalls=0
    $script:preflightOriginal=@{}
    foreach($name in @('Get-Recorder','New-BurnWriter','Confirm-PhysicalBurn','File-Hash')) { $script:preflightOriginal[$name]=(Get-Command $name).ScriptBlock }
    function script:Get-Recorder($Drive) { [pscustomobject]@{synthetic=$true} }
    function script:New-BurnWriter($Recorder) {
        if (!$Recorder.synthetic) { throw 'Synthetic recorder expected.' }
        $w=[pscustomobject]@{MediaPhysicallyBlank=$true;CurrentPhysicalMediaType=18;FreeSectorsOnMedia=12219360}
        $w | Add-Member ScriptMethod IsCurrentMediaSupported { param($r) $r.synthetic };$w
    }
    function script:File-Hash($Path) { if ((Full-Path $Path) -eq $script:testPayload) { $script:hashReads++ }; & $script:preflightOriginal['File-Hash'] $Path }
    function script:Confirm-PhysicalBurn($C,$D,$Record,$P,$Backend,$FreeBytes) {
        $script:reviewCalls++;$blocked=$false
        try { $h=[IO.File]::Open($script:testPayload,'Open','Write','ReadWrite');$h.Dispose() } catch [IO.IOException] { $blocked=$true }
        if (!$blocked) { throw 'Guard did not protect reviewed payload.' }
        throw 'TEST_CANCEL_WITH_GUARD'
    }
} $payload
try {
    $failure='';try { $null=Run burn @{DiscId='BD-P-0001';Drive='Z:';Backend='ImgBurn';BurnConfirmed=$true} } catch { $failure=$_.Exception.Message }
    Assert ($failure -match 'TEST_CANCEL_WITH_GUARD') $failure
    $state=& (Get-Module Archive.Core) { @{reads=$script:hashReads;reviews=$script:reviewCalls} }
    Assert ($state.reads -eq 0 -and $state.reviews -eq 1) 'Recent valid stage should reach review without reading payload.'
    Assert (!(Get-Disc $c 'BD-P-0001').burn) 'Cancellation consumed the disc.'
    $h=[IO.File]::Open($payload,'Open','Write','ReadWrite');$h.Dispose()
    $results+=@{name='cached check performs zero payload reads; review cancellation releases all handles';status='PASS'}
    # Deliberately corrupt only this isolated fixture and ensure review is never reached.
    [IO.File]::WriteAllText((Join-Path $source 'fixture.bin'),'changed synthetic bytes')
    $failure='';try { $null=Run burn @{DiscId='BD-P-0001';Drive='Z:';Backend='ImgBurn';BurnConfirmed=$true} } catch { $failure=$_.Exception.Message }
    Assert ($failure -match 'SHA-256 FAIL') $failure
    Assert ((& (Get-Module Archive.Core) { $script:reviewCalls }) -eq 1) 'Corrupt payload reached review.'
    $h=[IO.File]::Open($payload,'Open','Write','ReadWrite');$h.Dispose()
    $results+=@{name='corruption rejected before review; preflight failure releases guards';status='PASS'}
    $stage=Split-Path (Split-Path $payload);$guards=Open-StageReadGuards $stage
    try {
        Assert-StageReadGuardMembership $stage $guards
        Write-Text (Join-Path $stage 'synthetic-extra.txt') 'Added after guards; fixture only.'
        $blocked=$false;try { Assert-StageReadGuardMembership $stage $guards } catch {$blocked=$true}
        Assert $blocked 'New file during confirmation was not detected.'
    } finally { Close-StageReadGuards $guards }
    $results+=@{name='new filenames during review are rejected without a second hash pass';status='PASS'}
    foreach($speed in @('MAX','4x','6x','2.4x')) { $c.burn.speed=$speed;Assert ((ImgBurn-RequestedSpeed $c) -ceq $speed) }
    foreach($speed in @('0x','4x /START','garbage','')) { $c.burn.speed=$speed;$caught=$false;try { $null=ImgBurn-RequestedSpeed $c } catch {$caught=$true};Assert $caught }
    $results+=@{name='requested speed is preserved and malformed values rejected';status='PASS'}
    Write-Json (Join-Path $run 'burn-preflight-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();results=$results;physical_burn=$false;device_factories_mocked=$true;confirmation_always_cancelled=$true}
} finally {
    & (Get-Module Archive.Core) { foreach($name in $script:preflightOriginal.Keys) { Set-Item ('Function:script:'+$name) -Value $script:preflightOriginal[$name] } }
}
