<# Structured GUI worker. No command text is accepted from the request. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Archive.Core.psm1') -Force -DisableNameChecking
$request=Read-Json (Full-Path $RequestPath)
$logPath="$RequestPath.log"; $resultPath="$RequestPath.result.json"
$allowed=@('import-stage','devices','recover-burn','clear-simulation','repair-verify','init','prepare','summary','catalog','burn','verify','register','restore','split-video','contact-sheet','ids','set-counter','export-index','scan','plan','build','stage','tools','rename-disc','rename-set','ids')
try {
    if ($request.command -notin $allowed) { throw 'Unsupported GUI action.' }
    $parameters=@{}
    foreach ($property in $request.parameters.PSObject.Properties) { $parameters[$property.Name]=$property.Value }
    if ($request.command -in @('prepare','import-stage') -and $parameters.Execute -and !$parameters.DryRun) { Start-PreparationContext $RequestPath }
    elseif ($request.command -eq 'verify' -and $parameters.Execute -and !$parameters.DryRun) { Start-VerificationContext $RequestPath }
    if ($request.command -eq 'burn' -and !$parameters.Simulate) {
        if ($parameters.Execute -and !$parameters.DryRun -and $parameters.ConfirmationMode -ne 'Typed') {throw 'Browser burn requires a validated typed review.'}
    }
    & {
        if ($request.command -eq 'tools') {$script:requestResult=@(Get-ArchiveToolInventory (Load-Config $parameters.Config))}
        else {$script:requestResult=Invoke-Archive -Command $request.command -Parameters $parameters}
        $script:requestResult | ConvertTo-Json -Depth 20
    } *> $logPath
    if ($request.command -eq 'burn' -and (Optional-Field $script:requestResult 'status') -eq 'CANCELLED') {
        Write-Json $resultPath @{status='CANCELLED';command=$request.command;result=$script:requestResult;log=$logPath}
        exit 2
    }
    Write-Json $resultPath @{status='PASS';command=$request.command;result=$script:requestResult;log=$logPath}
} catch {
    [IO.File]::AppendAllText($logPath,($_ | Out-String),[Text.Encoding]::UTF8)
    $cancelled=Is-PreparationCancellation $_
    Write-Json $resultPath @{status=$(if ($cancelled) {'CANCELLED'} else {'FAIL'});command=$request.command;error=$_.Exception.Message;log=$logPath}
    if ($cancelled) { exit 2 };exit 1
}
