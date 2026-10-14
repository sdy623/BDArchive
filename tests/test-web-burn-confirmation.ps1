[CmdletBinding()]
param([string]$WorkRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Unit-only: no Archive.Core import, filesystem payload, native tool or hardware.
. (Join-Path $PSScriptRoot '../scripts/Archive.Scenes.ps1')
. (Join-Path $PSScriptRoot '../scripts/Archive.Dispatch.ps1')
$script:events=New-Object 'Collections.Generic.List[object]'
$script:promptCount=0;$script:dialogCount=0;$script:disposed=0
$script:promptAnswer='BURN BD-B-0001';$script:dialogAnswer='BURN BD-B-0001';$script:dialogResult='OK'
function Assert($Value,[string]$Message) {if(!$Value){throw $Message}}
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Name) {
    $before=$script:events.Count;$errorText=''
    try {$null=& $Action} catch {$errorText=$_.Exception.Message}
    Assert ($errorText -match $Pattern) "Expected rejection ($Name): $errorText"
    Assert ($script:events.Count -eq $before) "Rejected confirmation emitted receipt: $Name"
}
function Burn-ReviewText {'SYNTHETIC REVIEW: no physical device'}
function ImgBurn-RequestedSpeed {'MAX'}
function Optional-Field($Object,$Name) {if($Object -is [Collections.IDictionary]) {return $Object[$Name]};$prop=$Object.PSObject.Properties[$Name];if($prop){return $prop.Value};return $null}
function Event($C,$Kind,$Receipt) {$script:events.Add(@{kind=$Kind;receipt=$Receipt})}
function Read-Host {param($Prompt) $script:promptCount++;return $script:promptAnswer}
function Initialize-ArchiveDpi {'synthetic'}
function Restore-ArchiveDpi {param($State)}
function New-BurnConfirmationForm {param($Review,$Expected)
    $script:dialogCount++
    $form=[pscustomobject]@{}
    $form | Add-Member ScriptMethod ShowDialog {return $script:dialogResult}
    $form | Add-Member ScriptMethod Dispose {$script:disposed++}
    return @{form=$form;answer=@{Text=$script:dialogAnswer}}
}
$c=@{burn=@{verify_after_write=$false}}
$d=@{disc_id='BD-B-0001';archive_set_id='SYNTHETIC-SET'}
$r=@{stage=@{hash=('A'*64)}}
function New-Params {
    @{Execute=$true;BurnConfirmed=$true;Drive='G:';ConfirmationMode='Typed';ConfirmationText='BURN BD-B-0001';ConfirmationContext=@{disc_id='BD-B-0001';drive='G:';manifest_sha256=('A'*64)}}
}
$results=@()
$p=New-Params;$receipt=Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000
Assert ($script:promptCount -eq 0 -and $script:dialogCount -eq 0) 'Typed confirmation incorrectly invoked an interactive prompt.'
Assert ($receipt.method -eq 'typed exact-disc phrase with stage context') 'Typed receipt provenance missing.'
Assert ($receipt.disc_id -ceq $d.disc_id -and $receipt.drive -ceq $p.Drive -and $receipt.manifest_sha256 -ceq $r.stage.hash) 'Receipt not bound to reviewed values.'
Assert ($receipt.scope -eq 'this single burn attempt' -and $script:events.Count -eq 1) 'Receipt scope/event incorrect.'
$results+=@{name='exact typed phrase and bound context';status='PASS'}
foreach($bad in @('', $null, 'burn BD-B-0001','BURN BD-B-0002',' BURN BD-B-0001','BURN BD-B-0001 ',"BURN BD-B-0001`n",@('BURN BD-B-0001'))) {
    $p=New-Params;$p.ConfirmationText=$bad
    Reject {Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000} 'explicit user confirmation' 'blank/wrong/case/whitespace/nonstring phrase'
}
$results+=@{name='typed phrase is exact, case-sensitive and never trimmed';status='PASS'}
foreach($bad in @($null,@{},'not-an-object',@('wrong'))) {
    $p=New-Params;$p.ConfirmationContext=$bad
    Reject {Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000} 'confirmation context' 'missing or invalid context'
}
foreach($field in @('disc_id','drive','manifest_sha256')) {
    foreach($bad in @($null,'',23,'wrong')) {
        $p=New-Params;$p.ConfirmationContext[$field]=$bad
        Reject {Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000} 'confirmation context' "mismatched $field"
    }
}
$p=New-Params;$p.ConfirmationContext=[pscustomobject]$p.ConfirmationContext
$null=Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000
$results+=@{name='required context rejects missing, malformed, stale disc/drive/stage; JSON object accepted';status='PASS'}
foreach($key in @('Execute','BurnConfirmed')) {
    foreach($bad in @($false,$null,'true')) {
        $p=New-Params;$p[$key]=$bad
        Reject {Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000} 'Execute and BurnConfirmed' "typed guard $key"
    }
}
$p=New-Params;$blankRecord=@{stage=@{hash=''}}
Reject {Confirm-PhysicalBurn $c $d $blankRecord $p 'ImgBurn' 24000000000} 'confirmation context' 'empty current stage hash'
$results+=@{name='typed opt-in flags and current context cannot be empty';status='PASS'}
$p=New-Params;$p.ConfirmationMode='Console';$p.Remove('ConfirmationText');$p.Remove('ConfirmationContext')
$console=Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000
Assert ($script:promptCount -eq 1 -and $console.method -eq 'interactive exact-disc phrase') 'Console behavior changed.'
$script:promptAnswer='wrong';Reject {Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000} 'explicit user confirmation' 'console cancellation'
$p.ConfirmationMode='Dialog';$dialog=Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000
Assert ($script:dialogCount -eq 1 -and $script:disposed -eq 1 -and $dialog.method -eq 'interactive exact-disc phrase') 'Dialog behavior changed.'
$script:dialogResult='Cancel';Reject {Confirm-PhysicalBurn $c $d $r $p 'ImgBurn' 24000000000} 'explicit user confirmation' 'dialog cancellation'
Assert ($script:disposed -eq 2) 'Cancelled dialog not disposed.'
$results+=@{name='console and dialog exact-disc confirmation preserved';status='PASS'}
# Dispatcher dry-run must preserve typed fields and safely default missing fields.
function Full-Path($Path) {return $Path}
function Load-Config($Path) {return @{archive_root='synthetic-not-used'}}
$script:ArchiveOperationConfig=$null
$p=New-Params;$p.Config='synthetic.config.json';$p.Execute=$false
$dry=Invoke-Archive -Command burn -Parameters $p
Assert ($dry.status -eq 'DRY_RUN' -and $dry.parameters.ConfirmationText -ceq 'BURN BD-B-0001' -and $dry.parameters.ConfirmationContext.drive -ceq 'G:') 'Dispatch lost typed confirmation.'
$dry=Invoke-Archive -Command burn -Parameters @{Config='synthetic.config.json'}
Assert ($dry.parameters.ContainsKey('ConfirmationText') -and $dry.parameters.ContainsKey('ConfirmationContext')) 'Dispatch does not default typed fields.'
$results+=@{name='dispatcher defaults and preserves typed fields';status='PASS'}
if($WorkRoot) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($WorkRoot)) | Out-Null
    [IO.File]::WriteAllText((Join-Path $WorkRoot 'web-burn-confirmation-results.json'),(@{status='PASS';results=$results;physical_burn=$false;hardware_access=$false} | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
}
Write-Host "PASS $($results.Count) groups; physical_burn=false; hardware_access=false"