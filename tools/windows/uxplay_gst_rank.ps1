param(
    [string]$BundleRoot = $PSScriptRoot,
    [string]$MockInputPath,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LaunchTokens {
    param(
        [string]$ArgLine
    )

    if ([string]::IsNullOrWhiteSpace($ArgLine)) {
        return @()
    }

    $matches = [regex]::Matches($ArgLine, '"[^"]*"|''[^'']*''|\S+')
    $tokens = @()
    foreach ($match in $matches) {
        $tokens += $match.Value.Trim('"', "'")
    }
    return $tokens
}

function Get-ExplicitAudioSink {
    param(
        [string[]]$Tokens
    )

    $tokenList = @($Tokens)
    if ($tokenList.Count -lt 2) {
        return $null
    }

    for ($index = 0; $index -lt ($tokenList.Count - 1); $index++) {
        if ($tokenList[$index] -eq '-as') {
            return $tokenList[$index + 1]
        }
    }
    return $null
}

function New-InventoryFromBundle {
    param(
        [string]$BundleRootPath
    )

    $pluginDir = Join-Path $BundleRootPath 'gstreamer-1.0'
    $plugins = [ordered]@{}
    $plugins['hlsdemux'] = Test-Path (Join-Path $pluginDir 'libgsthls.dll')
    $plugins['hlsdemux2'] = Test-Path (Join-Path $pluginDir 'libgsthls.dll')
    $plugins['nvh264dec'] = Test-Path (Join-Path $pluginDir 'libgstnvcodec.dll')
    $plugins['nvh265dec'] = Test-Path (Join-Path $pluginDir 'libgstnvcodec.dll')
    $plugins['d3d11h264dec'] = Test-Path (Join-Path $pluginDir 'libgstd3d11.dll')
    $plugins['d3d11h265dec'] = Test-Path (Join-Path $pluginDir 'libgstd3d11.dll')
    $plugins['wasapisink'] = Test-Path (Join-Path $pluginDir 'libgstwasapi.dll')
    $plugins['wasapi2sink'] = Test-Path (Join-Path $pluginDir 'libgstwasapi2.dll')

    $gpuNames = @()
    try {
        $gpuNames = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name } | Where-Object { $_ })
    } catch {
        $gpuNames = @()
    }

    $gpuText = ($gpuNames -join ' ')
    $hardware = [ordered]@{
        gpus = $gpuNames
        hasNvidia = ($gpuText -match 'NVIDIA|GeForce|RTX|GTX|Quadro|Tesla')
        hasIntel = ($gpuText -match 'Intel')
        hasAmd = ($gpuText -match 'AMD|Radeon')
        source = 'bundle-dlls+win32_video_controller'
    }

    return [ordered]@{
        plugins = $plugins
        hardware = $hardware
    }
}

function New-InventoryFromMock {
    param(
        [string]$MockPath
    )

    $raw = Get-Content -Raw -Path $MockPath | ConvertFrom-Json
    return ConvertTo-HashtableRecursive -Value $raw
}

function ConvertTo-HashtableRecursive {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [pscustomobject]) {
        $table = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-HashtableRecursive -Value $property.Value
        }
        return $table
    }

    if ($Value -is [string] -or $Value -is [int] -or $Value -is [double] -or $Value -is [bool]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-HashtableRecursive -Value $item)
        }
        return $items
    }

    return $Value
}

function New-FeatureDecision {
    param(
        [string]$Name,
        [bool]$Installed,
        [bool]$Usable,
        [string]$Action,
        [string]$EvidenceType,
        [string]$Reason
    )

    $feature = New-Object -TypeName psobject
    $feature | Add-Member -NotePropertyName name -NotePropertyValue $Name
    $feature | Add-Member -NotePropertyName installed -NotePropertyValue $Installed
    $feature | Add-Member -NotePropertyName usable -NotePropertyValue $Usable
    $feature | Add-Member -NotePropertyName action -NotePropertyValue $Action
    $feature | Add-Member -NotePropertyName evidenceType -NotePropertyValue $EvidenceType
    $feature | Add-Member -NotePropertyName reason -NotePropertyValue $Reason
    return $feature
}

function Build-DecisionReport {
    param(
        [hashtable]$Inventory,
        [string[]]$LaunchTokens
    )

    $plugins = $Inventory.plugins
    $hardware = $Inventory.hardware
    $isHlsMode = $LaunchTokens -contains '-hls'
    $explicitAudioSink = Get-ExplicitAudioSink -Tokens $LaunchTokens
    $features = New-Object System.Collections.Generic.List[object]

    if ($plugins['hlsdemux']) {
        if ($isHlsMode) {
            $features.Add((New-FeatureDecision -Name 'hlsdemux' -Installed $true -Usable $false -Action 'disable' -EvidenceType 'policy' -Reason 'HLS launch profile prefers adaptivedemux2 over legacy hlsdemux on the bundled Windows runtime.'))
        } else {
            $features.Add((New-FeatureDecision -Name 'hlsdemux' -Installed $true -Usable $true -Action 'keep' -EvidenceType 'not-applicable' -Reason 'Legacy HLS demux ranking is only evaluated for -hls launches.'))
        }
    } else {
        $features.Add((New-FeatureDecision -Name 'hlsdemux' -Installed $false -Usable $false -Action 'skip' -EvidenceType 'missing-plugin' -Reason 'libgsthls.dll is not bundled.'))
    }

    foreach ($decoderName in @('nvh264dec', 'nvh265dec')) {
        $installed = [bool]$plugins[$decoderName]
        if (-not $installed) {
            $features.Add((New-FeatureDecision -Name $decoderName -Installed $false -Usable $false -Action 'skip' -EvidenceType 'missing-plugin' -Reason 'libgstnvcodec.dll is not bundled.'))
            continue
        }

        if ($hardware.hasNvidia) {
            $features.Add((New-FeatureDecision -Name $decoderName -Installed $true -Usable $true -Action 'keep' -EvidenceType 'hardware' -Reason 'NVIDIA adapter detected, so the nvcodec decoder remains eligible.'))
        } else {
            $features.Add((New-FeatureDecision -Name $decoderName -Installed $true -Usable $false -Action 'disable' -EvidenceType 'hardware' -Reason 'No NVIDIA adapter detected; disable nvcodec decoder auto-selection.'))
        }
    }

    foreach ($decoderName in @('d3d11h264dec', 'd3d11h265dec')) {
        $installed = [bool]$plugins[$decoderName]
        if ($installed) {
            $features.Add((New-FeatureDecision -Name $decoderName -Installed $true -Usable $true -Action 'keep' -EvidenceType 'hardware' -Reason 'D3D11 decoder is bundled; no automatic disable rule is applied.'))
        } else {
            $features.Add((New-FeatureDecision -Name $decoderName -Installed $false -Usable $false -Action 'skip' -EvidenceType 'missing-plugin' -Reason 'libgstd3d11.dll is not bundled.'))
        }
    }

    foreach ($sinkName in @('wasapi2sink', 'wasapisink')) {
        $installed = [bool]$plugins[$sinkName]
        if (-not $installed) {
            $features.Add((New-FeatureDecision -Name $sinkName -Installed $false -Usable $false -Action 'skip' -EvidenceType 'missing-plugin' -Reason 'The corresponding WASAPI plugin is not bundled.'))
            continue
        }

        if ($isHlsMode) {
            $reason = 'HLS launch profile disables WASAPI auto-selection so mixed RAOP/HLS playback falls back to DirectSound.'
            if ($explicitAudioSink) {
                $reason += " Explicit -as '$explicitAudioSink' remains user-controlled."
            }
            $features.Add((New-FeatureDecision -Name $sinkName -Installed $true -Usable $false -Action 'disable' -EvidenceType 'policy' -Reason $reason))
        } else {
            $features.Add((New-FeatureDecision -Name $sinkName -Installed $true -Usable $true -Action 'keep' -EvidenceType 'not-applicable' -Reason 'WASAPI policy override is only applied for -hls launches.'))
        }
    }

    $featureRankEntries = @($features | Where-Object { $_.action -eq 'disable' } | ForEach-Object { '{0}:0' -f $_.name })
    $featureRank = [string]::Join(',', $featureRankEntries)
    $featureList = @()
    foreach ($feature in $features) {
        $featureList += ,$feature
    }

    $report = New-Object -TypeName psobject
    $report | Add-Member -NotePropertyName launchArgs -NotePropertyValue $LaunchTokens
    $report | Add-Member -NotePropertyName hlsMode -NotePropertyValue $isHlsMode
    $report | Add-Member -NotePropertyName explicitAudioSink -NotePropertyValue $explicitAudioSink
    $report | Add-Member -NotePropertyName inventory -NotePropertyValue $Inventory
    $report | Add-Member -NotePropertyName features -NotePropertyValue $featureList
    $report | Add-Member -NotePropertyName featureRank -NotePropertyValue $featureRank
    return $report
}

function Test-DataKey {
    param(
        $Data,
        [string]$Key
    )

    if ($Data -is [System.Collections.IDictionary]) {
        return $Data.Contains($Key)
    }

    return $null -ne $Data.PSObject.Properties[$Key]
}

$inputData = if ($MockInputPath) {
    New-InventoryFromMock -MockPath $MockInputPath
} else {
    New-InventoryFromBundle -BundleRootPath $BundleRoot
}

$launchTokens = if (Test-DataKey -Data $inputData -Key 'launchArgs') {
    @($inputData.launchArgs)
} elseif (Test-DataKey -Data $inputData -Key 'launchArgsString') {
    Get-LaunchTokens -ArgLine $inputData.launchArgsString
} else {
    Get-LaunchTokens -ArgLine $env:UXPLAY_LAUNCH_ARGS
}

if ((Test-DataKey -Data $inputData -Key 'plugins') -and (Test-DataKey -Data $inputData -Key 'hardware')) {
    $inventory = @{
        plugins = $inputData.plugins
        hardware = $inputData.hardware
    }
} else {
    $inventory = $inputData
}

$report = Build-DecisionReport -Inventory $inventory -LaunchTokens $launchTokens

if (-not $MockInputPath) {
    $reportPath = Join-Path $BundleRoot 'uxplay-gst-rank-report.json'
    $report | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $reportPath
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 8
    exit 0
}

Write-Output ('set "GST_PLUGIN_FEATURE_RANK={0}"' -f $report.featureRank)
