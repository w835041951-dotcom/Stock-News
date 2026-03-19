<#
.SYNOPSIS
    Calculate CAPE (Shiller P/E) for an A-share stock.
.DESCRIPTION
    This script fetches current price and historical annual EPS, then calculates:
    1) Nominal CAPE (default)
    2) Optional inflation-adjusted (approximate) CAPE using a fixed annual rate

    EPS source priority:
    - Akshare (Python): 10+ years of annual EPS history (preferred)
    - East Money F10 API: fallback (~3 years)

    Note: Strict CAPE uses real (inflation-adjusted) EPS. By default this script
    returns nominal CAPE. If -AnnualInflationRate is provided, it will also
    return a real-like CAPE approximation.
.PARAMETER Code
    Stock code, e.g. 600519 / SH600519 / sz000001
.PARAMETER Years
    Number of latest annual EPS points to average. Default 10, range 3-15.
.PARAMETER AnnualInflationRate
    Optional fixed annual inflation rate in percent, e.g. 2.0
.PARAMETER Quiet
    Return object only without formatted console output.
.EXAMPLE
    .\Get-CapeValuation.ps1 -Code 600519
    .\Get-CapeValuation.ps1 -Code 000001 -Years 8
    .\Get-CapeValuation.ps1 -Code 600519 -AnnualInflationRate 2.0
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Code,

    [ValidateRange(3, 15)]
    [int]$Years = 10,

    [double]$AnnualInflationRate,

    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

function Invoke-ApiRequest {
    param(
        [string]$Url,
        [string]$Referer = "https://quote.eastmoney.com/",
        [int]$TimeoutSec = 15
    )
    try {
        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = $Referer
            "Accept"     = "application/json, text/plain, */*"
        }
        return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec
    }
    catch {
        if (-not $Quiet) { Write-Warning "Request failed: $Url -> $($_.Exception.Message)" }
        return $null
    }
}

function Resolve-StockCode {
    param([string]$InputCode)

    $raw = $InputCode.Trim().ToUpper()
    if ($raw -match '^(?:SH|SZ)(\d{6})$') {
        $code = $Matches[1]
    }
    elseif ($raw -match '^\d{6}$') {
        $code = $raw
    }
    else {
        if (-not $Quiet) { Write-Warning "Invalid stock code: $InputCode" }
        return $null
    }

    if ($code -match '^6\d{5}$') {
        return [PSCustomObject]@{ Code = $code; Prefix = "SH"; Market = 1; SecId = "1.$code" }
    }
    elseif ($code -match '^[0-3]\d{5}$') {
        return [PSCustomObject]@{ Code = $code; Prefix = "SZ"; Market = 0; SecId = "0.$code" }
    }

    if (-not $Quiet) { Write-Warning "Unsupported market code: $code" }
    return $null
}

function Get-CapeLevel {
    param([double]$Cape)

    if ($Cape -lt 10) { return "Low" }
    if ($Cape -lt 20) { return "Neutral" }
    if ($Cape -lt 30) { return "High" }
    return "Very High"
}

$parsed = Resolve-StockCode -InputCode $Code
if (-not $parsed) { return $null }
# 1) Current price and PE_TTM
# f59=小数位数, f43=现价, f58=股票名称, f164=PE(TTM)
$quoteUrl = "https://push2.eastmoney.com/api/qt/stock/get?secid=$($parsed.SecId)&fields=f43,f58,f59,f164"
$quote = Invoke-ApiRequest -Url $quoteUrl
if (-not $quote -or -not $quote.data) {
    if (-not $Quiet) { Write-Warning "Failed to fetch quote data for $Code." }
    return $null
}

$dec = if ($quote.data.f59 -and [int]$quote.data.f59 -gt 0 -and [int]$quote.data.f59 -le 6) { [int]$quote.data.f59 } else { 2 }
$price = [Math]::Round([double]$quote.data.f43 / [Math]::Pow(10, $dec), $dec)
$name = [string]$quote.data.f58
$peTtmRaw = $quote.data.f164
$peTtm = $null
if ($null -ne $peTtmRaw -and [double]$peTtmRaw -ne 0) {
    $peTtm = [Math]::Round(([double]$peTtmRaw / 100), 2)
}

# 2) Historical EPS series for CAPE
# --- Primary: Akshare (Python), 10+ years of annual data ---
$epsSeries = @()
$seriesMode = "Akshare"

try {
    $pyHelper = Join-Path $PSScriptRoot "python\Get-EpsSeries.py"
    if (Test-Path $pyHelper) {
        $env:PYTHONIOENCODING = "utf-8"
        $pyOutFile = Join-Path $env:TEMP "eps_$($parsed.Code).json"
        if (Test-Path $pyOutFile) { Remove-Item $pyOutFile -Force }
        $pyProc = Start-Process -FilePath "C:\Python\Python39\python.exe" -ArgumentList "$pyHelper","$($parsed.Code)","$Years" -Wait:$false -NoNewWindow -PassThru -RedirectStandardOutput $pyOutFile -RedirectStandardError "NUL"
        $pyOut = $null
        if ($pyProc.WaitForExit(30000)) {
            if (Test-Path $pyOutFile) { $pyOut = Get-Content $pyOutFile -Raw -ErrorAction SilentlyContinue }
        } else {
            try { $pyProc.Kill() } catch {}
        }
        if ($pyOut) {
            $pyData = $pyOut | ConvertFrom-Json
            if ($pyData -is [array] -and $pyData.Count -ge 2) {
                foreach ($item in $pyData) {
                    $epsSeries += [PSCustomObject]@{
                        Year = [int]$item.Year
                        EPS  = [Math]::Round([double]$item.EPS, 4)
                    }
                }
            }
        }
    }
}
catch {
    $epsSeries = @()
}

# --- Fallback: East Money F10 API (~3 years) ---
if ($epsSeries.Count -lt 2) {
    $seriesMode = "EastMoneyFallback"
    if (-not $Quiet) { Write-Warning "Akshare unavailable, falling back to East Money API (~3y)." }

    $finUrl = "https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/ZYZBAjaxNew?type=0&code=$($parsed.Prefix)$($parsed.Code)"
    $fin = Invoke-ApiRequest -Url $finUrl -Referer "https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/Index?type=web&code=$($parsed.Prefix)$($parsed.Code)"
    if (-not $fin -or -not $fin.data) {
        if (-not $Quiet) { Write-Warning "Failed to fetch financial report data from both sources for $Code." }
        return $null
    }

    $allRows = @()
    foreach ($row in $fin.data) {
        $eps = $null
        try { if ($row.EPSJB -ne $null -and "$($row.EPSJB)" -ne "") { $eps = [double]$row.EPSJB } } catch {}
        if ($null -eq $eps) { continue }
        $reportYear = $null
        try { if ($row.REPORT_DATE) { $reportYear = ([datetime]$row.REPORT_DATE).Year } } catch {}
        if ($null -eq $reportYear) {
            try { if ($row.REPORT_DATE_NAME -match '^(\d{4})') { $reportYear = [int]$Matches[1] } } catch {}
        }
        if ($null -eq $reportYear) { continue }
        $allRows += [PSCustomObject]@{
            Year = $reportYear
            ReportDate = [datetime]$row.REPORT_DATE
            EPS  = [Math]::Round($eps, 4)
        }
    }

    if ($allRows.Count -lt 2) { throw "Not enough EPS data points to calculate CAPE." }

    $annualRows = @($allRows | Where-Object { $_.ReportDate.Month -eq 12 -and $_.ReportDate.Day -eq 31 })
    if ($annualRows.Count -ge 3) {
        $epsSeries = @($annualRows | Sort-Object Year -Descending | Select-Object -First $Years)
    } else {
        $seriesMode = "EastMoneyLatestPerYearFallback"
        $perYear = @($allRows | Group-Object Year | ForEach-Object {
            $_.Group | Sort-Object ReportDate -Descending | Select-Object -First 1
        })
        $epsSeries = @($perYear | Sort-Object Year -Descending | Select-Object -First $Years)
    }
}

if ($epsSeries.Count -lt 2) {
    if (-not $Quiet) { Write-Warning "Effective EPS points fewer than 2 for $Code. Skipping CAPE." }
    return $null
}

# 3) Nominal CAPE
$avgNominalEps = ($epsSeries | Measure-Object -Property EPS -Average).Average
if ($null -eq $avgNominalEps -or $avgNominalEps -le 0) {
    if (-not $Quiet) { Write-Warning "Average EPS <= 0 for $Code. CAPE not meaningful." }
    return $null
}
$nominalCape = [Math]::Round($price / $avgNominalEps, 2)

# 4) Optional inflation-adjusted approximation
$realCape = $null
$realAvgEps = $null
$realSeries = @()
$hasInflation = $PSBoundParameters.ContainsKey('AnnualInflationRate')
if ($hasInflation) {
    $r = $AnnualInflationRate / 100
    $currentYear = (Get-Date).Year

    foreach ($item in $epsSeries) {
        $yearsAgo = [Math]::Max(0, $currentYear - [int]$item.Year)
        $factor = [Math]::Pow((1 + $r), $yearsAgo)
        $realEps = [Math]::Round(([double]$item.EPS * $factor), 4)
        $realSeries += [PSCustomObject]@{
            Year     = $item.Year
            EPS      = $item.EPS
            Adjusted = $realEps
            Factor   = [Math]::Round($factor, 4)
        }
    }

    $realAvgEps = ($realSeries | Measure-Object -Property Adjusted -Average).Average
    if ($realAvgEps -and $realAvgEps -gt 0) {
        $realCape = [Math]::Round($price / $realAvgEps, 2)
    }
}

$bandLevels = @(10, 15, 20, 25, 30)
$bandRows = $bandLevels | ForEach-Object {
    $pe = $_
    $implied = [Math]::Round($pe * $avgNominalEps, 2)
    $diff = [Math]::Round(($implied - $price) / $price * 100, 1)
    $sign = if ($diff -ge 0) { "+" } else { "" }
    [PSCustomObject]@{
        CapeLevel    = $pe
        ImpliedPrice = $implied
        VsCurrentPct = "$sign$diff%"
    }
}

$extras = [PSCustomObject]@{
    DividendPerShareTTM      = $null
    DividendYieldTTM         = $null
    DividendRecords          = @()
    IndustryName             = $null
    IndustryLevel            = $null
    IndustryStandard         = $null
    IndustryDate             = $null
    IndustryStaticPEWeighted = $null
    IndustryStaticPEMedian   = $null
    IndustryStaticPEAverage  = $null
    IndustrySampleCount      = $null
    HistoricalCapePercentile = $null
    HistoricalCapeMedian     = $null
    HistoricalCapeMin        = $null
    HistoricalCapeMax        = $null
    HistoricalCapeSamples    = @()
}

try {
    $pyExtraHelper = Join-Path $PSScriptRoot "python\Get-ValuationExtras.py"
    if (Test-Path $pyExtraHelper) {
        $env:PYTHONIOENCODING = "utf-8"
        $pyExOutFile = Join-Path $env:TEMP "valext_$($parsed.Code).json"
        if (Test-Path $pyExOutFile) { Remove-Item $pyExOutFile -Force }
        $pyExProc = Start-Process -FilePath "C:\Python\Python39\python.exe" -ArgumentList "$pyExtraHelper","$($parsed.Code)","$Years","$price","$nominalCape" -Wait:$false -NoNewWindow -PassThru -RedirectStandardOutput $pyExOutFile -RedirectStandardError "NUL"
        $pyExtraOut = $null
        if ($pyExProc.WaitForExit(30000)) {
            if (Test-Path $pyExOutFile) { $pyExtraOut = Get-Content $pyExOutFile -Raw -ErrorAction SilentlyContinue }
        } else {
            try { $pyExProc.Kill() } catch {}
        }
        if ($pyExtraOut) {
            $extraData = $pyExtraOut | ConvertFrom-Json
            if ($extraData) {
                $extras = [PSCustomObject]@{
                    DividendPerShareTTM      = if ($null -ne $extraData.DividendPerShareTTM) { [Math]::Round([double]$extraData.DividendPerShareTTM, 4) } else { $null }
                    DividendYieldTTM         = if ($null -ne $extraData.DividendYieldTTM) { [Math]::Round([double]$extraData.DividendYieldTTM, 2) } else { $null }
                    DividendRecords          = @($extraData.DividendRecords)
                    IndustryName             = $extraData.IndustryName
                    IndustryLevel            = $extraData.IndustryLevel
                    IndustryStandard         = $extraData.IndustryStandard
                    IndustryDate             = $extraData.IndustryDate
                    IndustryStaticPEWeighted = if ($null -ne $extraData.IndustryStaticPEWeighted) { [Math]::Round([double]$extraData.IndustryStaticPEWeighted, 2) } else { $null }
                    IndustryStaticPEMedian   = if ($null -ne $extraData.IndustryStaticPEMedian) { [Math]::Round([double]$extraData.IndustryStaticPEMedian, 2) } else { $null }
                    IndustryStaticPEAverage  = if ($null -ne $extraData.IndustryStaticPEAverage) { [Math]::Round([double]$extraData.IndustryStaticPEAverage, 2) } else { $null }
                    IndustrySampleCount      = $extraData.IndustrySampleCount
                    HistoricalCapePercentile = if ($null -ne $extraData.HistoricalCapePercentile) { [Math]::Round([double]$extraData.HistoricalCapePercentile, 1) } else { $null }
                    HistoricalCapeMedian     = if ($null -ne $extraData.HistoricalCapeMedian) { [Math]::Round([double]$extraData.HistoricalCapeMedian, 2) } else { $null }
                    HistoricalCapeMin        = if ($null -ne $extraData.HistoricalCapeMin) { [Math]::Round([double]$extraData.HistoricalCapeMin, 2) } else { $null }
                    HistoricalCapeMax        = if ($null -ne $extraData.HistoricalCapeMax) { [Math]::Round([double]$extraData.HistoricalCapeMax, 2) } else { $null }
                    HistoricalCapeSamples    = @($extraData.HistoricalCapeSamples)
                }
            }
        }
    }
}
catch {
}

$industryVsMedianPct = $null
if ($null -ne $peTtm -and $null -ne $extras.IndustryStaticPEMedian -and $extras.IndustryStaticPEMedian -gt 0) {
    $industryVsMedianPct = [Math]::Round((($peTtm / $extras.IndustryStaticPEMedian) - 1) * 100, 1)
}

$result = [PSCustomObject]@{
    Code                    = $parsed.Code
    Name                    = $name
    Price                   = [Math]::Round($price, 2)
    PETTM                   = $peTtm
    SeriesMode              = $seriesMode
    YearsUsed               = $epsSeries.Count
    NominalAvgEPS           = [Math]::Round($avgNominalEps, 4)
    NominalCAPE             = $nominalCape
    NominalCAPELevel        = Get-CapeLevel -Cape $nominalCape
    InflationRatePercent    = if ($hasInflation) { [Math]::Round($AnnualInflationRate, 2) } else { $null }
    RealAvgEPS              = if ($realAvgEps) { [Math]::Round($realAvgEps, 4) } else { $null }
    RealLikeCAPE            = $realCape
    DividendPerShareTTM     = $extras.DividendPerShareTTM
    DividendYieldTTM        = $extras.DividendYieldTTM
    DividendRecords         = $extras.DividendRecords
    IndustryName            = $extras.IndustryName
    IndustryLevel           = $extras.IndustryLevel
    IndustryStandard        = $extras.IndustryStandard
    IndustryDate            = $extras.IndustryDate
    IndustryStaticPEWeighted = $extras.IndustryStaticPEWeighted
    IndustryStaticPEMedian  = $extras.IndustryStaticPEMedian
    IndustryStaticPEAverage = $extras.IndustryStaticPEAverage
    IndustrySampleCount     = $extras.IndustrySampleCount
    IndustryPEPremiumPct    = $industryVsMedianPct
    HistoricalCapePercentile = $extras.HistoricalCapePercentile
    HistoricalCapeMedian    = $extras.HistoricalCapeMedian
    HistoricalCapeMin       = $extras.HistoricalCapeMin
    HistoricalCapeMax       = $extras.HistoricalCapeMax
    HistoricalCapeSamples   = $extras.HistoricalCapeSamples
    PEBands                 = $bandRows
    EpsSeries               = $epsSeries
    RealEpsSeries           = $realSeries
}

if ($Quiet) {
    return $result
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor DarkCyan
Write-Host "  CAPE (Shiller P/E) Valuation" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor DarkCyan
Write-Host "Stock: $($result.Name) ($($result.Code))" -ForegroundColor White
Write-Host "Price: $($result.Price)" -ForegroundColor White
if ($null -ne $result.PETTM) {
    Write-Host "PE(TTM): $($result.PETTM)" -ForegroundColor White
}
Write-Host "Series mode: $($result.SeriesMode)" -ForegroundColor White
Write-Host "Nominal Avg EPS ($($result.YearsUsed)y): $($result.NominalAvgEPS)" -ForegroundColor White
Write-Host "Nominal CAPE: $($result.NominalCAPE) ($($result.NominalCAPELevel))" -ForegroundColor Yellow

if ($result.YearsUsed -lt $Years) {
    if (-not $Quiet) { Write-Warning "Requested $Years years but only $($result.YearsUsed) years are available from source data." }
}

if ($result.SeriesMode -like "EastMoney*") {
    if (-not $Quiet) { Write-Warning "Data source limited to ~3 years (East Money). CAPE reliability is reduced." }
}

# Detect EPS outliers (>3x median) that may indicate M&A / restructuring distortions
$epsValues = @($epsSeries | ForEach-Object { $_.EPS })
$sortedEps = @($epsValues | Sort-Object)
$midIdx = [int]($sortedEps.Count / 2)
$median = $sortedEps[$midIdx]
$outliers = @($epsSeries | Where-Object { $_.EPS -gt ($median * 3) -or $_.EPS -lt ($median / 3) })
if ($outliers.Count -gt 0) {
    $outlierYears = ($outliers | ForEach-Object { "$($_.Year)(EPS=$($_.EPS))" }) -join ", "
    if (-not $Quiet) { Write-Warning "EPS outlier detected: $outlierYears. Possible restructuring or extraordinary item. Review before relying on CAPE." }
}

if ($hasInflation) {
    if ($null -ne $result.RealLikeCAPE) {
        Write-Host "Inflation (annual): $($result.InflationRatePercent)%" -ForegroundColor White
        Write-Host "Adjusted Avg EPS: $($result.RealAvgEPS)" -ForegroundColor White
        Write-Host "Real-like CAPE: $($result.RealLikeCAPE)" -ForegroundColor Green
    }
    else {
        if (-not $Quiet) { Write-Warning "Real-like CAPE calculation failed (adjusted EPS may be invalid)." }
    }
}

if ($null -ne $result.HistoricalCapePercentile) {
    Write-Host "Historical CAPE percentile: $($result.HistoricalCapePercentile)%" -ForegroundColor White
    Write-Host "Historical CAPE range: $($result.HistoricalCapeMin) - $($result.HistoricalCapeMax) (median $($result.HistoricalCapeMedian))" -ForegroundColor White
}

if ($null -ne $result.DividendYieldTTM) {
    Write-Host "Dividend yield (TTM): $($result.DividendYieldTTM)%" -ForegroundColor White
}

if ($result.IndustryName) {
    Write-Host "Industry: $($result.IndustryName)" -ForegroundColor White
    if ($null -ne $result.IndustryStaticPEMedian) {
        Write-Host "Industry static PE median: $($result.IndustryStaticPEMedian)" -ForegroundColor White
    }
    if ($null -ne $result.IndustryPEPremiumPct) {
        $premiumSign = if ($result.IndustryPEPremiumPct -ge 0) { "+" } else { "" }
        Write-Host "PE vs industry median: $premiumSign$($result.IndustryPEPremiumPct)%" -ForegroundColor White
    }
}

Write-Host "`n--- PE Valuation Band (Nominal Avg EPS = $($result.NominalAvgEPS)) ---" -ForegroundColor DarkCyan
$result.PEBands |
    Select-Object @{Name = "CAPE Level"; Expression = { $_.CapeLevel }},
                  @{Name = "Implied Price"; Expression = { $_.ImpliedPrice }},
                  @{Name = "vs Current"; Expression = { $_.VsCurrentPct }} |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Host "`n--- Annual EPS samples used for CAPE ---" -ForegroundColor DarkCyan
$epsSeries | Sort-Object Year | Format-Table Year, EPS -AutoSize | Out-String | Write-Host

if ($hasInflation -and $realSeries.Count -gt 0) {
    Write-Host "--- Inflation-adjusted sample ---" -ForegroundColor DarkCyan
    $realSeries | Sort-Object Year | Format-Table Year, EPS, Adjusted, Factor -AutoSize | Out-String | Write-Host
}

Write-Host "Note: CAPE is for medium/long-term valuation reference only, not investment advice." -ForegroundColor DarkGray

