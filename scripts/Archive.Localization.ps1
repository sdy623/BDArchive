# UI text only. Never localize file paths, user-entered metadata, protocol states,
# archive IDs or the human-typed BURN confirmation token. Compatible with PS 5.1+.
$script:ArchiveLocaleRoot=Join-Path (Split-Path $PSScriptRoot) 'locales'
$script:ArchiveLocaleCatalogs=$null
$script:ArchiveLocaleLanguage=$null
$script:ArchiveLocaleRendered=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
$script:ArchiveLocaleBindings=New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,object]'

function Initialize-ArchiveLocale {
    [CmdletBinding()]
    param([string]$Language=$env:BD_ARCHIVE_LANGUAGE)
    if ([string]::IsNullOrWhiteSpace($Language)) { $Language='en' }
    if ($Language -match '^zh(?:-|$)') { $Language='zh-CN' }
    if ($Language -notin @('en','zh-CN')) { $Language='en' }
    if (!$script:ArchiveLocaleCatalogs) {
        $script:ArchiveLocaleCatalogs=@{}
        $script:ArchiveLocaleSources=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach($name in @('zh-CN','en')) {
            $path=Join-Path $script:ArchiveLocaleRoot ($name+'.json')
            $data=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $values=@{}
            foreach($property in $data.PSObject.Properties) {
                $values[$property.Name]=[string]$property.Value
                if (!$script:ArchiveLocaleSources.ContainsKey([string]$property.Value)) { $script:ArchiveLocaleSources.Add([string]$property.Value,$property.Name) }
            }
            $script:ArchiveLocaleCatalogs[$name]=$values
        }
        # Alias for pre-localization burn dialogs; the displayed confirmation
        # payload remains a separate argument, never parsed or translated.
        $script:ArchiveLocaleSources['请亲自输入 / Type: {0}']='burn.typePhrase'
    }
    $script:ArchiveLocaleLanguage=$Language
    # Workers created with UseShellExecute=false inherit this display preference.
    $env:BD_ARCHIVE_LANGUAGE=$Language
}

function Get-ArchiveText {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Key,[object[]]$Arguments=@(),[string]$Fallback)
    if (!$script:ArchiveLocaleCatalogs -or $script:ArchiveLocaleLanguage -ne $env:BD_ARCHIVE_LANGUAGE) { Initialize-ArchiveLocale }
    $catalog=$script:ArchiveLocaleCatalogs[$script:ArchiveLocaleLanguage]
    $value=if($catalog.ContainsKey($Key)){[string]$catalog[$Key]}elseif($PSBoundParameters.ContainsKey('Fallback')){$Fallback}else{$Key}
    if (!$Arguments.Count) { return $value }
    # Numeric placeholders only. Literal template tokens such as {disc_id} and
    # braces in user-supplied values remain intact, unlike indiscriminate -f.
    $values=$Arguments
    $rendered=[regex]::Replace($value,'\{(\d+)\}',[Text.RegularExpressions.MatchEvaluator]{param($m)
        $i=[int]$m.Groups[1].Value
        if($i -ge $values.Count){throw "Missing localization argument $i for $Key"}
        return [string]$values[$i]
    })
    if($script:ArchiveLocaleRendered.Count -gt 1024) {$script:ArchiveLocaleRendered.Clear()}
    $script:ArchiveLocaleRendered[$rendered]=@{key=$Key;arguments=@($Arguments)}
    return $rendered
}

function Get-ArchiveLocaleKey {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if (!$script:ArchiveLocaleCatalogs) { Initialize-ArchiveLocale }
    if ($null -ne $Text -and $script:ArchiveLocaleSources.ContainsKey($Text)) { return $script:ArchiveLocaleSources[$Text] }
    return $null
}

function Translate-ArchiveText {
    [CmdletBinding()]
    param([Parameter(Position=0)][AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { return $Text }
    if($script:ArchiveLocaleRendered.ContainsKey($Text)) {
        $rendered=$script:ArchiveLocaleRendered[$Text]
        return Get-ArchiveText $rendered.key -Arguments $rendered.arguments
    }
    $key=Get-ArchiveLocaleKey $Text
    if ($key) { return Get-ArchiveText $key }
    # Deliberately no regex or substring translation here. Dynamic messages are
    # migrated to semantic/template keys with explicit, untouched arguments.
    return $Text
}

function Get-ArchiveLocaleBinding($Object) {
    $binding=$null
    if (!$script:ArchiveLocaleBindings.TryGetValue($Object,[ref]$binding)) {
        $binding=@{}
        $script:ArchiveLocaleBindings.Add($Object,$binding)
    }
    return $binding
}

function Update-ArchiveControlLocale {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)]$Container)
    if (!$script:ArchiveLocaleCatalogs -or $script:ArchiveLocaleLanguage -ne $env:BD_ARCHIVE_LANGUAGE) { Initialize-ArchiveLocale }
    $binding=Get-ArchiveLocaleBinding $Container
    # Input controls are not captions. Even a field reading "Prepare archive"
    # must remain byte-for-byte user data across language changes.
    if ($Container -is [Windows.Forms.ComboBox]) {
        if (!$Container.DataSource -and !$Container.DisplayMember -and $Container.DropDownStyle -eq 'DropDownList') {
            $selected=$Container.SelectedIndex
            $Container.BeginUpdate()
            try {
                for($i=0;$i -lt $Container.Items.Count;$i++) {
                    $item=$Container.Items[$i]
                    if ($item -isnot [string]) {continue}
                    $slot='item_'+$i
                    if (!$binding.ContainsKey($slot) -or $item -cne $binding[$slot].last) { $binding[$slot]=@{source=$item;last=$item} }
                    $translated=Translate-ArchiveText $binding[$slot].source
                    if($item -cne $translated) { $Container.Items[$i]=$translated }
                    $binding[$slot].last=$translated
                }
                if($selected -ge 0) {
                    if($Container.SelectedIndex -ne $selected) { $Container.SelectedIndex=$selected }
                    # Replacing Items[index] leaves the selected display text
                    # stale on WinForms. Assigning Text refreshes it without
                    # firing a SelectedIndexChanged event or changing the ID.
                    $Container.Text=[string]$Container.Items[$selected]
                }
            } finally {$Container.EndUpdate()}
        }
    } elseif ($Container -is [Windows.Forms.Label] -or $Container -is [Windows.Forms.ButtonBase] -or $Container -is [Windows.Forms.Form] -or $Container -is [Windows.Forms.TabPage] -or $Container -is [Windows.Forms.GroupBox]) {
        if (!$binding.ContainsKey('caption') -or $Container.Text -cne $binding.caption.last) { $binding.caption=@{source=$Container.Text;last=$Container.Text} }
        $translated=Translate-ArchiveText $binding.caption.source
        if($Container.Text -cne $translated) {$Container.Text=$translated}
        $binding.caption.last=$translated
    }
    if($Container -is [Windows.Forms.DataGridView]) {
        foreach($column in $Container.Columns) {
            $columnBinding=Get-ArchiveLocaleBinding $column
            if(!$columnBinding.ContainsKey('header') -or $column.HeaderText -cne $columnBinding.header.last) { $columnBinding.header=@{source=$column.HeaderText;last=$column.HeaderText} }
            $column.HeaderText=Translate-ArchiveText $columnBinding.header.source
            $columnBinding.header.last=$column.HeaderText
        }
        # Data keys, cells, data-bound values and protocol states are untouched.
    }
    foreach($child in $Container.Controls) { Update-ArchiveControlLocale $child }
}
