function Release-OpticalCom($Object) {
    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) { $null=[Runtime.InteropServices.Marshal]::ReleaseComObject($Object) }
}
function Get-OpticalInventory {
    # Windows device enumeration; no test writes, exclusive access or tray actions.
    $master=$null
    try {
        $master=New-Object -ComObject IMAPI2.MsftDiscMaster2
        foreach ($id in $master) {
            $rec=$null;$format=$null
            try {
                $rec=New-Object -ComObject IMAPI2.MsftDiscRecorder2;$rec.InitializeDiscRecorder($id)
                $paths=@($rec.VolumePathNames);$drive=@($paths | Where-Object { $_ -match '^[A-Za-z]:[\\/]?$' } | Select-Object -First 1)
                $letter=if ($drive.Count) { $drive[0].Substring(0,2).ToUpperInvariant() } else { '' }
                $name=([string]$rec.VendorId+' '+[string]$rec.ProductId).Trim()
                $item=[ordered]@{recorder_id=[string]$id;drive=$letter;model=$name;display="$letter  $name";media='未就绪';blank=$null;free_bytes=$null;capacity_bytes=$null;speeds_x=@();error=$null}
                try {
                    $format=New-BurnWriter $rec
                    $supported=$format.IsCurrentMediaSupported($rec)
                    $type=$format.CurrentPhysicalMediaType
                    if ($null -ne $type) {
                        $types=@{0='无盘 / 未知';1='CD-ROM';2='CD-R';3='CD-RW';4='DVD-ROM';5='DVD-RAM';6='DVD+R';7='DVD+RW';8='DVD+R DL';9='DVD-R';10='DVD-RW';11='DVD-RW';12='DVD-R DL';13='DVD-R DL';17='BD-ROM';18='BD-R';19='BD-RE'}
                        $item.media=if ($types.ContainsKey([int]$type)) {$types[[int]$type]} else {"介质类型 $type"}
                    }
                    $item.blank=$format.MediaPhysicallyBlank
                    $free=$format.FreeSectorsOnMedia;$total=$format.TotalSectorsOnMedia
                    if ($null -ne $free) {$item.free_bytes=[int64]$free*2048}
                    if ($null -ne $total) {$item.capacity_bytes=[int64]$total*2048}
                    # IMAPI reports 2048-byte sectors/second. BD 1x = 4,495,625 B/s.
                    if ($null -ne $type -and [int]$type -in @(17,18,19)) {
                        $item.speeds_x=@($format.SupportedWriteSpeeds | Where-Object { $_ -gt 0 -and $_ -lt 0x7fffffff } | ForEach-Object { [math]::Round([double]$_*2048/4495625,1) } | Sort-Object -Unique)
                    }
                    if (!$supported) {$item.error='当前介质不支持数据写入或尚未就绪'}
                } catch { $item.error=$_.Exception.Message }
                [pscustomobject]$item
            } finally { Release-OpticalCom $format;Release-OpticalCom $rec }
        }
    } finally { Release-OpticalCom $master }
}
