[CmdletBinding()]
param([string]$WorkRoot,[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/simulation-clear' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json')
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite'
if ($Python) { $c.tools.python=$Python }
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$checks=@()
function Assert($Value,$Message='Assertion failed') { if (!$Value) { throw $Message } }
function Reject([scriptblock]$Body,$Pattern) { $caught=$false;try { & $Body | Out-Null } catch { $caught=$true;Assert ($_.Exception.Message -match $Pattern) "Wrong rejection: $_" };Assert $caught 'Expected rejection.' }
function Case($Name,[scriptblock]$Body) { & $Body;$script:checks+=@{name=$Name;status='PASS'};Write-Host "PASS $Name" }
function Run($Command,$Extra=@{}) { $p=@{Config=$cfg;Execute=$true};foreach($key in $Extra.Keys){$p[$key]=$Extra[$key]};Invoke-Archive $Command $p }
$source=Join-Path $run 'source 空格';[IO.Directory]::CreateDirectory($source)|Out-Null
Write-Text (Join-Path $source 'fixture.bin') 'Synthetic simulation-clear fixture; not user data.'
try {
    $null=Run init
    $null=Run scan @{SetId='SIM-CLEAR';Source=$source;Scenario='photo';PhotoTier='C'}
    $null=Run plan @{SetId='SIM-CLEAR';StartDiscId='BD-P-0042'}
    $null=Run stage @{DiscId='BD-P-0042'}
    $stage=(Get-Disc $c 'BD-P-0042').stage.path
    $stageHash=File-Hash (Join-Path $stage 'SHA256SUMS')
    $null=Run burn @{DiscId='BD-P-0042';Simulate=$true}
    $null=Run verify @{DiscId='BD-P-0042';Simulate=$true}
    $null=Run register @{DiscId='BD-P-0042';Location='SIMULATION ONLY'}
    $simulation=(Get-Disc $c 'BD-P-0042').burn.root

    Case 'dry-run reports exact derived root and changes no bytes' {
        $before=File-Hash (Catalog-Path $c)
        $preview=Invoke-Archive clear-simulation @{Config=$cfg;DiscId='BD-P-0042'}
        Assert ($preview.status -eq 'DRY_RUN' -and $preview.root -eq $simulation)
        Assert ($preview.root_exists -and $preview.file_count -gt 0 -and $preview.bytes -gt 0)
        Assert ((File-Hash (Catalog-Path $c)) -eq $before)
        Assert (Test-Path -LiteralPath $simulation)
    }
    Case 'path boundary rejects a simulation root outside archive_root simulated' {
        $outside=Join-Path $run 'outside-do-not-delete';[IO.Directory]::CreateDirectory($outside)|Out-Null
        Write-Text (Join-Path $outside 'keep.txt') 'keep'
        $record=Get-Disc $c 'BD-P-0042';$record.burn.root=$outside;Update-Disc $c $record
        Reject { Clear-ArchiveSimulation $c @{DiscId='BD-P-0042';Reason='TEST'} } '边界以外'
        Assert (Test-Path -LiteralPath (Join-Path $outside 'keep.txt'))
        $record=Get-Disc $c 'BD-P-0042';$record.burn.root=$simulation;Update-Disc $c $record
    }
    Case 'execute deletes only simulation and returns registered simulation to STAGED' {
        $result=Run clear-simulation @{DiscId='BD-P-0042';Reason='TEST_CLEAR'}
        $record=Get-Disc $c 'BD-P-0042'
        Assert ($result.status -eq 'STAGED' -and $result.deleted_root -eq $simulation)
        Assert (!(Test-Path -LiteralPath $simulation))
        Assert ($record.status -eq 'STAGED' -and !$record.burn -and !$record.verification)
        Assert (!$record.registered -and [string]::IsNullOrEmpty($record.location))
        Assert (@($record.simulation_history).Count -eq 1)
        Assert ($record.simulation_history[0].original.registered)
        Assert (Test-Path -LiteralPath $result.journal)
        Assert ((Read-Json $result.journal).status -eq 'COMPLETE')
        Assert (Test-Path -LiteralPath $stage)
        Assert ((File-Hash (Join-Path $stage 'SHA256SUMS')) -eq $stageHash)
        Assert (Test-Path -LiteralPath (Join-Path $source 'fixture.bin'))
    }
    Case 'repeat clear and physical write evidence remain protected' {
        Reject { Run clear-simulation @{DiscId='BD-P-0042'} } '没有可清除'
        $record=Get-Disc $c 'BD-P-0042'
        $record.burn=[pscustomobject]@{simulation=$false;result='WRITTEN';drive='Z:'}
        $record.status='BURNED_UNVERIFIED';Update-Disc $c $record
        Reject { Clear-ArchiveSimulation $c @{DiscId='BD-P-0042'} } '没有可清除'
        Assert ((Get-Disc $c 'BD-P-0042').burn.result -eq 'WRITTEN')
        Assert (Test-Path -LiteralPath $stage)
    }
    Case 'GUI worker accepts clear-simulation without command-text injection' {
        $record=Get-Disc $c 'BD-P-0042';$record.burn=$null;$record.burn_date=$null;$record.status='STAGED';Update-Disc $c $record
        $null=Run burn @{DiscId='BD-P-0042';Simulate=$true}
        $secondRoot=(Get-Disc $c 'BD-P-0042').burn.root
        $request=Join-Path $run 'clear-simulation-request.json'
        Write-Json $request @{command='clear-simulation';parameters=@{Config=$cfg;DiscId='BD-P-0042';Execute=$true;Reason='TEST_GUI_WORKER'}}
        $engine=(Get-Process -Id $PID).Path
        & $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../scripts/run-request.ps1') -RequestPath $request
        Assert ($LASTEXITCODE -eq 0) 'GUI worker returned a failure exit code.'
        $workerResult=Read-Json ($request+'.result.json')
        Assert ($workerResult.status -eq 'PASS' -and $workerResult.result.status -eq 'STAGED')
        Assert (!(Test-Path -LiteralPath $secondRoot))
        Assert ((Get-Disc $c 'BD-P-0042').status -eq 'STAGED')
    }
    Case 'physical-burn branch clears simulation only after blank-media preflight' {
        $media=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../scripts/Archive.Media.ps1'))
        $getRecorder=$media.IndexOf('$rec=Get-Recorder')
        $capacity=$media.IndexOf("if (`$d.media_type -eq 'BD50'")
        $clear=$media.IndexOf("Clear-ArchiveSimulation `$C @{DiscId=`$record.disc_id;Reason='SWITCH_TO_PHYSICAL_BURN'}")
        $physicalRecord=$media.IndexOf('$record.burn=[pscustomobject]@{simulation=$false')
        Assert ($getRecorder -ge 0 -and $capacity -gt $getRecorder -and $clear -gt $capacity -and $physicalRecord -gt $clear)
    }
    Write-Json (Join-Path $run 'simulation-clear-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();checks=$checks;physical_burn=$false;hardware_access=$false;source_deletion=$false}
    Write-Host "PASS $($checks.Count) groups: $run"
} catch {
    Write-Json (Join-Path $run 'simulation-clear-results.json') @{status='FAIL';powershell=$PSVersionTable.PSVersion.ToString();checks=$checks;error=$_.Exception.Message;physical_burn=$false;hardware_access=$false;source_deletion=$false}
    throw
}