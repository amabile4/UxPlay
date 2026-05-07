param(
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BonjourServiceState {
    $svc = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue
    if (-not $svc) {
        return [pscustomobject]@{ exists = $false; status = 'not-installed' }
    }
    return [pscustomobject]@{ exists = $true; status = $svc.Status.ToString() }
}

function Get-DnssdStatus {
    $paths = @()
    $where = & where.exe dnssd.dll 2>$null
    if ($LASTEXITCODE -eq 0 -and $where) {
        $paths = @($where)
    }
    return [pscustomobject]@{
        found = ($paths.Count -gt 0)
        paths = $paths
    }
}

function Get-MdnsNspCatalogStatus {
    $catalog = & netsh winsock show catalog 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $catalog) {
        return [pscustomobject]@{ present = $false; note = 'winsock-catalog-unavailable' }
    }

    $joined = ($catalog -join "`n")
    $present = $joined -match 'mdnsnsp\.dll'
    return [pscustomobject]@{
        present = [bool]$present
        note = if ($present) { 'registered-in-winsock-catalog' } else { 'not-registered-in-winsock-catalog' }
    }
}

function Get-LsaBlockHints {
    $hints = New-Object System.Collections.Generic.List[string]
    $channels = @(
        'Microsoft-Windows-CodeIntegrity/Operational',
        'System'
    )

    foreach ($channel in $channels) {
        try {
            $events = Get-WinEvent -LogName $channel -MaxEvents 200 -ErrorAction Stop |
                Where-Object { $_.Message -match 'mdnsNSP\.dll' -and $_.Message -match 'blocked|Local Security Authority|LSA' }
            foreach ($evt in $events) {
                $hints.Add("${channel}:$($evt.Id):$($evt.TimeCreated)")
            }
        } catch {
            continue
        }
    }
    return @($hints)
}

$bonjourService = Get-BonjourServiceState
$dnssd = Get-DnssdStatus
$mdnsNsp = Get-MdnsNspCatalogStatus
$lsaHints = Get-LsaBlockHints

$uxplayUsage = [pscustomobject]@{
    usesDnssdDll = $true
    usesMdnsNspDll = $false
    rationale = 'UxPlay Windows build loads dnssd.dll via LoadLibrary/GetProcAddress and does not directly load mdnsNSP.dll.'
}

$safeToRunUxplay = $dnssd.found
$recommendations = @()

if (-not $dnssd.found) {
    $recommendations += 'dnssd.dll not found. Install Bonjour (iTunes or Bonjour Print Services).'
}

if ($dnssd.found -and -not $bonjourService.exists) {
    $recommendations += 'dnssd.dll exists but Bonjour Service was not found. Verify service installation for AirPlay discovery.'
}

if ($lsaHints.Count -gt 0) {
    $recommendations += 'Found LSA block hints for mdnsNSP.dll. UxPlay does not directly use mdnsNSP.dll if dnssd.dll is available.'
}

$recommendations += 'Do not lower security settings such as disabling LSA protection.'
$recommendations += 'If mdnsNSP.dll is disabled or unregistered, validate only .local name resolution impact for your environment.'

$report = [pscustomobject]@{
    uxplayUsage = $uxplayUsage
    dnssd = $dnssd
    bonjourService = $bonjourService
    mdnsNsp = $mdnsNsp
    lsaBlockHints = $lsaHints
    safeToRunUxplay = $safeToRunUxplay
    recommendations = $recommendations
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 6
    exit 0
}

Write-Output '=== UxPlay Bonjour Safety Check ==='
Write-Output ("dnssd.dll found: {0}" -f $report.dnssd.found)
if ($report.dnssd.paths.Count -gt 0) {
    Write-Output 'dnssd.dll path(s):'
    $report.dnssd.paths | ForEach-Object { Write-Output ("  - {0}" -f $_) }
}
Write-Output ("Bonjour Service: {0}" -f $report.bonjourService.status)
Write-Output ("mdnsNSP in Winsock catalog: {0}" -f $report.mdnsNsp.present)
Write-Output ("UxPlay uses mdnsNSP.dll directly: {0}" -f $report.uxplayUsage.usesMdnsNspDll)
Write-Output ("Safe to run UxPlay (dnssd.dll basis): {0}" -f $report.safeToRunUxplay)
if ($report.lsaBlockHints.Count -gt 0) {
    Write-Output 'LSA block hints:'
    $report.lsaBlockHints | ForEach-Object { Write-Output ("  - {0}" -f $_) }
}
Write-Output 'Recommendations:'
$report.recommendations | ForEach-Object { Write-Output ("  - {0}" -f $_) }
