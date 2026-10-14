[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/storage'))
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($run) | Out-Null
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert($Test,$Message) { if (!$Test) { throw $Message } }
function Reject([scriptblock]$Body) { $failed=$false;try { & $Body | Out-Null } catch { $failed=$true };Assert $failed 'Expected rejection' }
function Pass($Name) { $results.Add(@{name=$Name;status='PASS'});Write-Host "PASS $Name" }
$source=Join-Path $run 'source 空格/data.RAW';Write-Text $source 'SYNTHETIC original'
$hash=File-Hash $source;$mtime=[IO.File]::GetLastWriteTimeUtc($source);$attributes=[IO.File]::GetAttributes($source)
$target=Join-Path $run 'stage 空格/data.RAW'
$r=Stage-Payload $source $target $hash
Assert ($r.mode -eq 'HARDLINK' -and [ArchiveFileLinks]::Identity($source) -eq [ArchiveFileLinks]::Identity($target)) 'Same-volume payload duplicated'
Assert ([IO.File]::GetLastWriteTimeUtc($source) -eq $mtime -and [IO.File]::GetAttributes($source) -eq $attributes) 'Source metadata changed'
Pass 'same-volume Unicode payload uses the same file ID without changing attributes'
$hidden=Join-Path $run 'source 空格/hidden.txt';Write-Text $hidden ''
[IO.File]::SetAttributes($hidden,[IO.FileAttributes]::Hidden)
$r=Stage-Payload $hidden (Join-Path $run 'stage 空格/hidden.txt') (File-Hash $hidden)
Assert ($r.mode -eq 'HARDLINK' -and $r.bytes -eq 0 -and [IO.File]::GetAttributes($hidden) -band [IO.FileAttributes]::Hidden) 'Empty/hidden source changed'
Pass 'hidden empty file links preserve source attributes'
Reject { Stage-Payload $source $target $hash }
Reject { Stage-Payload $source (Join-Path $run 'bad/hash.RAW') ('0'*64) }
Assert (!(Test-Path (Join-Path $run 'bad/hash.RAW'))) 'Bad hash produced a payload'
Pass 'existing destinations and changed source hashes reject before copying'
$guards=Open-StageReadGuards (Split-Path $target)
try {
    Reject { $stream=[IO.File]::Open($source,'Open','Write','ReadWrite');$stream.Dispose() }
    Reject { [IO.File]::Delete($target) }
    $stream=[IO.File]::OpenRead($source);$stream.Dispose()
} finally { Close-StageReadGuards $guards }
Assert ((File-Hash $source) -eq $hash) 'Burn read guard changed the file'
# Existing writers also reject the guard; closing it releases earlier handles.
$writer=[IO.File]::Open($source,'Open','Write','ReadWrite')
try { Reject { Open-StageReadGuards (Split-Path $target) } } finally { $writer.Dispose() }
$writer=[IO.File]::Open($source,'Open','Write','ReadWrite');$writer.Dispose()
Pass 'read guards block shared-data writes and staged-name deletion, reject existing writers, then release'
$copy=Join-Path $run 'independent/restore.RAW';Copy-Checked $target $copy $hash
Assert ([ArchiveFileLinks]::Identity($copy) -ne [ArchiveFileLinks]::Identity($source)) 'Independent copy shares source identity'
[IO.File]::AppendAllText($copy,' changed independent copy')
Assert ((File-Hash $source) -eq $hash) 'Independent copy mutation reached source'
Pass 'restore and simulated-media copy helper keeps independent data'
[IO.File]::AppendAllText($source,' changed source')
Assert ((File-Hash $target) -ne $hash) 'Test did not exercise shared file mutation'
Reject { Stage-Payload $source (Join-Path $run 'bad/changed.RAW') $hash }
Pass 'source mutation is detected against the sealed hash'
$sealedRoot=Join-Path $run 'seal/data';[IO.Directory]::CreateDirectory($sealedRoot) | Out-Null
$sealFile=Join-Path $sealedRoot 'one.RAW';$r=Stage-Payload $source $sealFile (File-Hash $source)
Write-Text (Join-Path (Split-Path $sealedRoot) 'DISC.json') '{}'
$expected=File-Hash $source
$disc=[pscustomobject]@{dwarfs=$false;files=@([pscustomobject]@{path='one.RAW';sha256=$expected});budget=@{capacity_bytes=100MB;reserve_bytes=1MB}}
$cfg=[pscustomobject]@{planning=@{per_file_overhead_bytes=4096}}
[IO.File]::AppendAllText($source,' edited after linking, before sealing')
$reason='';try { Seal-Stage $cfg $disc (Split-Path $sealedRoot) | Out-Null } catch { $reason=$_.Exception.Message }
Assert ($reason -match 'Payload differs from ingest/build') 'Stage sealed source bytes that differ from ingest'
Assert (!(Test-Path (Join-Path (Split-Path $sealedRoot) 'SHA256SUMS'))) 'Altered source received a seal'
Pass 'staging refuses a source edit between linking and sealing'

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $longRoot=Join-Path $run ('long/'+('a'*90)+'/'+('b'*90))
    $longSource=Join-Path $longRoot 'unicode 中文.RAW';Write-Text $longSource 'long-path payload'
    $longTarget=Join-Path $longRoot 'destination/unicode 中文.RAW'
    $r=Stage-Payload $longSource $longTarget (File-Hash $longSource)
    Assert ($longTarget.Length -gt 260 -and [ArchiveFileLinks]::Identity($longTarget) -eq [ArchiveFileLinks]::Identity($longSource)) 'Long hard link failed'
    Pass 'PowerShell 7 long-path hard link and volume detection'
}
Write-Json (Join-Path $run 'storage-results.json') @{status='PASS';results=$results.ToArray();powershell=$PSVersionTable.PSVersion.ToString();physical_burn=$false;cross_volume_hardware_test='NOT_RUN'}
Write-Host "Results: $run"

