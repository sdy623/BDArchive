[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/cancel-boundaries'))
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$module=Get-Module Archive.Core
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($run) | Out-Null
$c=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.example.json'))
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite'
$c.tools.python='';$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$source=Join-Path $run 'source';Write-Text (Join-Path $source 'one.RAW') 'synthetic-original'
$p=@{Config=$cfg;Execute=$true;Source=$source;SetId='PHOTO-CANCEL';Scenario='photo';PhotoTier='C';Media='BD25';ParPercent=0}
$null=Invoke-Archive init $p
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert($Value,$Message) { if (!$Value) { throw $Message } }
function Cancelled([scriptblock]$Body) {
    $caught=$false
    try { & $Body | Out-Null } catch { if (!(Is-PreparationCancellation $_)) { throw };$caught=$true }
    Assert $caught 'Expected cancellation'
}
function Pass($Name) { $results.Add(@{name=$Name;status='PASS'});Write-Host "PASS $Name" }
function Reset-Context {
    & $module {
        if (Get-Variable -Name OriginalWriteJson -Scope Script -ErrorAction SilentlyContinue) { Set-Item Function:script:Write-Json $script:OriginalWriteJson }
        if (Get-Variable -Name OriginalCopy -Scope Script -ErrorAction SilentlyContinue) { Set-Item Function:script:Copy-Checked $script:OriginalCopy }
        $script:PreparationJob=$null
    }
}
function Inject-CommitStop($Phase,$Request) {
    Start-PreparationContext $Request
    & $module {
        param($Phase,$Request)
        $script:TestPhase=$Phase;$script:TestRequest=$Request
        $script:OriginalWriteJson=${function:Write-Json}
        function script:Write-Json($Path,$Value) {
            & $script:OriginalWriteJson $Path $Value
            if (($script:TestPhase -eq 'scan' -and [IO.Path]::GetFileName($Path) -eq 'ingest.json') -or ($script:TestPhase -eq 'plan' -and [IO.Path]::GetFileName($Path) -eq 'catalog.json' -and $Value.discs.Count -gt 0)) {
                Write-Text ($script:TestRequest+'.cancel') 'stop during paired publication'
            }
        }
    } $Phase $Request
}
try {
    $request=Join-Path $run 'pre-cancel.json';Start-PreparationContext $request;Write-Text ($request+'.cancel') 'stop'
    Cancelled { File-Hash (Join-Path $source 'one.RAW') }
    Cancelled { Copy-Checked (Join-Path $source 'one.RAW') (Join-Path $run 'must-not-exist.RAW') 'unused' }
    Assert (!(Test-Path -LiteralPath (Join-Path $run 'must-not-exist.RAW'))) 'Cancelled copy wrote a target'
    Reset-Context;Pass 'hash and copy honor a pending stop without creating output'
    Inject-CommitStop scan (Join-Path $run 'scan.json')
    Cancelled { Invoke-Archive scan $p }
    Reset-Context
    $cat=Read-Json (Catalog-Path $c);$ing=Join-Path (Set-Dir $c $p.SetId) 'ingest.json'
    Assert ($cat.sets.Count -eq 1 -and $cat.sets[0].ingest_sha256 -eq (File-Hash $ing)) 'Cancellation orphaned ingest'
    Pass 'stop during ingest publication leaves catalog and immutable hash consistent'
    Inject-CommitStop plan (Join-Path $run 'plan.json')
    Cancelled { Invoke-Archive plan $p }
    Reset-Context
    $cat=Read-Json (Catalog-Path $c);$plan=Load-Plan $c $p.SetId
    Assert ($cat.discs.Count -eq 1 -and $plan.discs[0].disc_id -eq $cat.discs[0].disc_id) 'Cancellation orphaned reserved IDs'
    Pass 'stop during plan publication preserves reserved IDs and matching plan'
    $p.DiscId=$plan.discs[0].disc_id
    $request=Join-Path $run 'stage.json';Start-PreparationContext $request
    & $module {
        param($Request)
        $script:TestRequest=$Request;$script:OriginalCopy=${function:Copy-Checked}
        function script:Copy-Checked($Source,$Target,$Expected) {
            & $script:OriginalCopy $Source $Target $Expected
            Write-Text ($script:TestRequest+'.cancel') 'stop after first payload copy'
        }
    } $request
    Cancelled { Invoke-Archive stage $p }
    Reset-Context
    $root=Join-Path $c.archive_root ('staging/'+$p.DiscId)
    Assert (Test-Path -LiteralPath (Join-Path $root 'PREPARATION-CANCELLED.json')) 'Stage marker absent'
    Assert (!(Get-Disc $c $p.DiscId).stage) 'Interrupted stage became sealed'
    $null=Invoke-Archive stage $p
    $record=Get-Disc $c $p.DiscId;$sealHash=$record.stage.hash
    Assert ($record.status -eq 'STAGED') 'Stage retry failed'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $c.archive_root 'interrupted') -Directory).Count -eq 1) 'Stage partial was not retained'
    Pass 'cancelled staging stays unsealed and resumes with preserved partials'
    $request=Join-Path $run 'completed.json';Start-PreparationContext $request;Write-Text ($request+'.cancel') 'stop'
    Cancelled { Invoke-Archive prepare $p };Reset-Context
    Assert ((Get-Disc $c $p.DiscId).stage.hash -eq $sealHash) 'Completed stage changed'
    $sourceHash=File-Hash (Join-Path $source 'one.RAW')
    Assert ($sourceHash -eq (Load-Ingest $c $p.SetId).files[0].sha256) 'Source changed'
    Pass 'later cancellation retains completed stage and original source'
    Write-Json (Join-Path $run 'boundary-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();results=$results.ToArray();physical_burn=$false}
    Write-Host "Results: $run"
} finally { Reset-Context }
