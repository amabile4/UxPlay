Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$toolPath = Join-Path $repoRoot 'tools\windows\uxplay_gst_rank.ps1'

$cases = @(
    @{
        Name = 'non_nvidia_hls'
        Fixture = 'fixtures\windows_rank\non_nvidia_hls.json'
        ExpectedDisabled = @('hlsdemux', 'nvh264dec', 'nvh265dec', 'wasapi2sink', 'wasapisink')
        ExpectedKept = @('d3d11h264dec', 'd3d11h265dec')
    },
    @{
        Name = 'nvidia_hls'
        Fixture = 'fixtures\windows_rank\nvidia_hls.json'
        ExpectedDisabled = @('hlsdemux', 'wasapi2sink', 'wasapisink')
        ExpectedKept = @('nvh264dec', 'nvh265dec', 'd3d11h264dec', 'd3d11h265dec')
    },
    @{
        Name = 'non_nvidia_no_hls'
        Fixture = 'fixtures\windows_rank\non_nvidia_no_hls.json'
        ExpectedDisabled = @('nvh264dec', 'nvh265dec')
        ExpectedKept = @('hlsdemux', 'wasapi2sink', 'wasapisink', 'd3d11h264dec', 'd3d11h265dec')
    }
)

$failures = New-Object System.Collections.Generic.List[string]

foreach ($case in $cases) {
    $fixturePath = Join-Path $PSScriptRoot $case.Fixture
    $report = & $toolPath -MockInputPath $fixturePath -AsJson | ConvertFrom-Json
    $disabledNames = @($report.features | Where-Object { $_.action -eq 'disable' } | ForEach-Object { $_.name })
    $keptNames = @($report.features | Where-Object { $_.action -eq 'keep' } | ForEach-Object { $_.name })

    foreach ($expectedName in $case.ExpectedDisabled) {
        if ($disabledNames -notcontains $expectedName) {
            $failures.Add("[$($case.Name)] expected disabled feature missing: $expectedName")
        }
    }

    foreach ($expectedName in $case.ExpectedKept) {
        if ($keptNames -notcontains $expectedName) {
            $failures.Add("[$($case.Name)] expected kept feature missing: $expectedName")
        }
    }

    if ($case.Name -eq 'non_nvidia_hls') {
        $nvh264 = $report.features | Where-Object { $_.name -eq 'nvh264dec' }
        if ($nvh264.reason -notmatch 'No NVIDIA adapter detected') {
            $failures.Add('[non_nvidia_hls] nvh264dec reason does not contain NVIDIA evidence')
        }
    }

    if ($case.Name -eq 'nvidia_hls') {
        $wasapi2 = $report.features | Where-Object { $_.name -eq 'wasapi2sink' }
        if ($wasapi2.evidenceType -ne 'policy') {
            $failures.Add('[nvidia_hls] wasapi2sink should be disabled by policy evidence')
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output 'All static Windows GStreamer rank cases passed.'
