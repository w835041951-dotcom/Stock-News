<#
.SYNOPSIS
    基于日内分时走势和资金流，给出A股更合适的入手时点。
.DESCRIPTION
    结合东方财富分时走势和分钟级资金流接口，输出：
    1. 当前日内强弱（价格相对均价线 / 当日位置）
    2. 主力资金走向（分钟级净流入/净流出）
    3. 更适合的入手时窗（如 10:00-10:30 / 13:15-13:45）
    4. 简短执行建议：分批低吸 / 午后确认 / 暂不追高
.PARAMETER Code
    股票代码，支持 600519 / SH600519 / sz000001
.PARAMETER Quiet
    静默模式，仅返回对象
.EXAMPLE
    .\Get-EntryTiming.ps1 -Code 600519
    .\Get-EntryTiming.ps1 -Code 300750 -Quiet
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Code,

    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

$script:CacheDir = Join-Path $env:TEMP "MyClaw_StockCache"
if (-not (Test-Path $script:CacheDir)) {
    New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
}

function Get-CachedData {
    param([string]$Key, [int]$MaxAgeMinutes = 15)
    $file = Join-Path $script:CacheDir "$Key.json"
    if (Test-Path $file) {
        $age = (Get-Date) - (Get-Item $file).LastWriteTime
        if ($age.TotalMinutes -le $MaxAgeMinutes) {
            try { return (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
        }
    }
    return $null
}

function Set-CachedData {
    param([string]$Key, $Value)
    try {
        $file = Join-Path $script:CacheDir "$Key.json"
        $Value | ConvertTo-Json -Depth 8 -Compress | Out-File $file -Encoding UTF8 -Force
    } catch {}
}

function Invoke-Api {
    param([string]$Uri, [string]$Referer = "https://quote.eastmoney.com/")
    try {
        return Invoke-RestMethod -Uri $Uri -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = $Referer
            "Accept"     = "application/json, text/plain, */*"
        } -TimeoutSec 15
    } catch {
        return $null
    }
}

function Convert-ToNumber {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $s = "$Value".Trim()
    if (-not $s -or $s -eq "-" -or $s -eq "--") { return $null }
    $num = 0.0
    if ([double]::TryParse($s, [ref]$num)) { return [double]$num }
    return $null
}

function Get-StockIdentity {
    param([string]$RawCode)

    $normalized = $RawCode.Trim().ToUpper()
    if ($normalized -match '^(?:SH|SZ)(\d{6})$') {
        $stockCode = $Matches[1]
    }
    elseif ($normalized -match '^\d{6}$') {
        $stockCode = $normalized
    }
    else {
        throw "无效股票代码: $RawCode"
    }

    if ($stockCode -match '^6\d{5}$') {
        return [PSCustomObject]@{ Code = $stockCode; Market = 1; Prefix = 'SH'; SecId = "1.$stockCode" }
    }

    return [PSCustomObject]@{ Code = $stockCode; Market = 0; Prefix = 'SZ'; SecId = "0.$stockCode" }
}

function Get-QuoteSnapshot {
    param([string]$SecId)

    $quoteUrl = "https://push2.eastmoney.com/api/qt/stock/get?secid=$SecId&fields=f43,f44,f45,f46,f57,f58,f59,f60,f168,f169,f170"
    $quote = Invoke-Api -Uri $quoteUrl
    if (-not ($quote -and $quote.data)) { return $null }

    $d = $quote.data
    $dec = if ($d.f59 -and [int]$d.f59 -gt 0 -and [int]$d.f59 -le 15) { [int]$d.f59 } else { 2 }
    $div = [Math]::Pow(10, $dec)

    return [PSCustomObject]@{
        Name          = "$($d.f58)"
        CurrentPrice  = if ($null -ne (Convert-ToNumber $d.f43)) { [Math]::Round(([double]$d.f43 / $div), $dec) } else { $null }
        OpenPrice     = if ($null -ne (Convert-ToNumber $d.f46)) { [Math]::Round(([double]$d.f46 / $div), $dec) } else { $null }
        HighPrice     = if ($null -ne (Convert-ToNumber $d.f44)) { [Math]::Round(([double]$d.f44 / $div), $dec) } else { $null }
        LowPrice      = if ($null -ne (Convert-ToNumber $d.f45)) { [Math]::Round(([double]$d.f45 / $div), $dec) } else { $null }
        PrevClose     = if ($null -ne (Convert-ToNumber $d.f60)) { [Math]::Round(([double]$d.f60 / $div), $dec) } else { $null }
        TurnoverRate  = if ($null -ne (Convert-ToNumber $d.f168)) { [Math]::Round(([double]$d.f168 / 100), 2) } else { $null }
        DayChange     = if ($null -ne (Convert-ToNumber $d.f169)) { [Math]::Round(([double]$d.f169 / $div), $dec) } else { $null }
        DayChangePct  = if ($null -ne (Convert-ToNumber $d.f170)) { [Math]::Round(([double]$d.f170 / 100), 2) } else { $null }
    }
}

function Get-IntradayTrend {
    param([string]$SecId)

    $trendUrl = "https://push2.eastmoney.com/api/qt/stock/trends2/get?secid=$SecId&fields1=f1,f2,f3,f4,f5,f6,f7,f8&fields2=f51,f52,f53,f54,f55,f56,f57,f58&ut=fa5fd1943c7b386f172d6893dbfba10b&iscr=0&ndays=1"
    $trendData = Invoke-Api -Uri $trendUrl
    if (-not ($trendData -and $trendData.data -and $trendData.data.trends)) { return @() }

    $items = @()
    foreach ($line in @($trendData.data.trends)) {
        $parts = "$line" -split ','
        if ($parts.Count -lt 3) { continue }
        $price = Convert-ToNumber $parts[1]
        $avg = if ($parts.Count -ge 3) { Convert-ToNumber $parts[2] } else { $null }
        $volume = if ($parts.Count -ge 4) { Convert-ToNumber $parts[3] } else { $null }
        $amount = if ($parts.Count -ge 5) { Convert-ToNumber $parts[4] } else { $null }
        if ($null -eq $price) { continue }
        $items += [PSCustomObject]@{
            Time     = "$($parts[0])"
            Price    = [double]$price
            AvgPrice = if ($null -ne $avg) { [double]$avg } else { $null }
            Volume   = $volume
            Amount   = $amount
        }
    }
    return $items
}

function Get-MoneyFlow {
    param([string]$SecId)

    $flowUrl = "https://push2.eastmoney.com/api/qt/stock/fflow/kline/get?secid=$SecId&lmt=0&klt=1&fields1=f1,f2,f3,f7&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63"
    $flowData = Invoke-Api -Uri $flowUrl
    if (-not ($flowData -and $flowData.data -and $flowData.data.klines)) { return @() }

    $items = @()
    foreach ($line in @($flowData.data.klines)) {
        $parts = "$line" -split ','
        if ($parts.Count -lt 2) { continue }
        $mainNet = Convert-ToNumber $parts[1]
        if ($null -eq $mainNet) { continue }
        $items += [PSCustomObject]@{
            Time        = "$($parts[0])"
            MainNet     = [double]$mainNet
            SmallNet    = if ($parts.Count -ge 3) { Convert-ToNumber $parts[2] } else { $null }
            MediumNet   = if ($parts.Count -ge 4) { Convert-ToNumber $parts[3] } else { $null }
            LargeNet    = if ($parts.Count -ge 5) { Convert-ToNumber $parts[4] } else { $null }
            SuperNet    = if ($parts.Count -ge 6) { Convert-ToNumber $parts[5] } else { $null }
            MainNetPct  = if ($parts.Count -ge 7) { Convert-ToNumber $parts[6] } else { $null }
        }
    }
    return $items
}

function Get-TimeBucketSum {
    param($Items, [scriptblock]$Predicate)
    $sum = 0.0
    $count = 0
    foreach ($item in @($Items)) {
        if (& $Predicate $item.Time) {
            $sum += [double]$item.MainNet
            $count++
        }
    }
    if ($count -eq 0) { return $null }
    return [Math]::Round($sum, 0)
}

function Get-EntryDecision {
    param(
        $Quote,
        $TrendPoints,
        $FlowPoints
    )

    $priceVsAvgPct = $null
    $intradayBias = '未知'
    $fundFlowBias = '未知'
    $phase = '盘中'
    $primaryWindow = '10:00-10:30'
    $secondaryWindow = '13:15-13:45'
    $action = '等待确认'
    $reason = '等待价格重新站稳均价线再动手。'
    $risk = '若主力继续流出，不建议当日追单。'
    $confidence = 50
    $mainNet = $null
    $morningMain = $null
    $afternoonMain = $null

    if ($TrendPoints.Count -gt 0) {
        $first = $TrendPoints[0]
        $latest = $TrendPoints[-1]
        $avgRef = if ($null -ne $latest.AvgPrice -and $latest.AvgPrice -gt 0) { [double]$latest.AvgPrice } else { [double]$latest.Price }
        if ($avgRef -gt 0) {
            $priceVsAvgPct = [Math]::Round((([double]$latest.Price - $avgRef) / $avgRef) * 100, 2)
        }

        $morningPoints = @($TrendPoints | Where-Object { $_.Time -match ' (09|10|11):' -or $_.Time -match '^(09|10|11):' })
        $afternoonPoints = @($TrendPoints | Where-Object { $_.Time -match ' (13|14|15):' -or $_.Time -match '^(13|14|15):' })
        if ($afternoonPoints.Count -gt 0) { $phase = '午后' } elseif ($morningPoints.Count -gt 0) { $phase = '早盘' }

        $highPrice = [double](($TrendPoints | Measure-Object -Property Price -Maximum).Maximum)
        $pullbackFromHighPct = if ($highPrice -gt 0) { [Math]::Round((($highPrice - [double]$latest.Price) / $highPrice) * 100, 2) } else { 0 }

        if ($null -ne $priceVsAvgPct) {
            if ($priceVsAvgPct -ge 0.35) { $intradayBias = '偏强' }
            elseif ($priceVsAvgPct -ge -0.15) { $intradayBias = '震荡' }
            else { $intradayBias = '偏弱' }
        }

        if ($FlowPoints.Count -gt 0) {
            $mainNet = [Math]::Round((@($FlowPoints | Measure-Object -Property MainNet -Sum).Sum), 0)
            $morningMain = Get-TimeBucketSum -Items $FlowPoints -Predicate { param($t) $t -match ' (09|10|11):' -or $t -match '^(09|10|11):' }
            $afternoonMain = Get-TimeBucketSum -Items $FlowPoints -Predicate { param($t) $t -match ' (13|14|15):' -or $t -match '^(13|14|15):' }

            if ($mainNet -gt 0 -and $null -ne $afternoonMain -and $afternoonMain -gt 0) {
                $fundFlowBias = '主力净流入增强'
            }
            elseif ($mainNet -gt 0) {
                $fundFlowBias = '主力小幅净流入'
            }
            elseif ($mainNet -lt 0) {
                $fundFlowBias = '主力净流出'
            }
            else {
                $fundFlowBias = '主力基本持平'
            }
        }

        $dayChangePct = if ($Quote -and $null -ne $Quote.DayChangePct) { [double]$Quote.DayChangePct } else { 0 }
        $openPrice = if ($Quote -and $null -ne $Quote.OpenPrice) { [double]$Quote.OpenPrice } elseif ($first) { [double]$first.Price } else { 0 }
        $currentPrice = if ($Quote -and $null -ne $Quote.CurrentPrice) { [double]$Quote.CurrentPrice } elseif ($latest) { [double]$latest.Price } else { 0 }
        $aboveOpen = ($openPrice -gt 0 -and $currentPrice -ge $openPrice)
        $nearAvg = ($null -ne $priceVsAvgPct -and $priceVsAvgPct -ge -0.3 -and $priceVsAvgPct -le 0.25)
        $strongAboveAvg = ($null -ne $priceVsAvgPct -and $priceVsAvgPct -ge 0.8)
        $weakBelowAvg = ($null -ne $priceVsAvgPct -and $priceVsAvgPct -le -0.3)

        if ($mainNet -gt 0 -and $nearAvg -and $aboveOpen) {
            $primaryWindow = '10:00-10:30'
            $secondaryWindow = '13:15-13:45'
            $action = '分批低吸'
            $reason = '价格贴近均价线但没有走坏，主力仍在净流入，适合等回踩承接。'
            $risk = '若跌破早盘均价线且资金翻绿，撤掉当日计划。'
            $confidence = 82
        }
        elseif ($mainNet -gt 0 -and $strongAboveAvg -and $dayChangePct -ge 5) {
            $primaryWindow = '13:15-13:45'
            $secondaryWindow = '次日 09:45-10:15'
            $action = '不追高，等午后二次确认'
            $reason = '日内涨幅已经不小，价格离均价线偏远，午后等二次回踩更稳。'
            $risk = '若午后资金不继续回流，宁可错过，也不在高位追。'
            $confidence = 74
        }
        elseif ($mainNet -gt 0 -and $null -ne $afternoonMain -and $afternoonMain -gt 0 -and $phase -eq '午后') {
            $primaryWindow = '13:10-13:40'
            $secondaryWindow = '14:00-14:20'
            $action = '午后回流跟随'
            $reason = '午后主力继续回流，分时重新抬升，适合等 5-10 分钟确认后跟随。'
            $risk = '14:00 之后若量价背离，不建议继续加仓。'
            $confidence = 79
        }
        elseif ($weakBelowAvg -or $mainNet -lt 0) {
            $primaryWindow = '次日 09:45-10:15'
            $secondaryWindow = '13:15-13:45'
            $action = '今天先等'
            $reason = '价格落在均价线下方，主力偏流出，今天更像观察盘，不适合硬接。'
            $risk = '若午后仍无法翻回均价线，继续放弃当日交易。'
            $confidence = 38
        }
        elseif ($pullbackFromHighPct -ge 1.2 -and $mainNet -ge 0) {
            $primaryWindow = '13:15-13:45'
            $secondaryWindow = '14:00-14:20'
            $action = '等二次回踩结束后介入'
            $reason = '早盘冲高后已有回落，等午后缩量企稳再接，比早盘追单更合适。'
            $risk = '若午后不能收回均价线，继续等待次日。'
            $confidence = 67
        }
        else {
            $primaryWindow = '10:15-10:45'
            $secondaryWindow = '13:15-13:45'
            $action = '轻仓试错'
            $reason = '分时还在震荡，先等均价线方向更明确，再做小仓位试单。'
            $risk = '震荡盘不要一次性打满，优先分两笔。'
            $confidence = 58
        }
    }
    else {
        $dayChangePct = if ($Quote -and $null -ne $Quote.DayChangePct) { [double]$Quote.DayChangePct } else { 0 }
        if ($dayChangePct -ge 5) {
            $primaryWindow = '13:15-13:45'
            $secondaryWindow = '次日 09:45-10:15'
            $action = '不追高'
            $reason = '当日涨幅已大，优先等午后回踩或次日分歧转一致。'
            $risk = '缺少分钟数据，今天更适合保守处理。'
            $confidence = 45
        }
        elseif ($dayChangePct -gt 0) {
            $primaryWindow = '10:00-10:30'
            $secondaryWindow = '13:15-13:45'
            $action = '分批试'
            $reason = '日线偏强但缺少盘中细节，优先选择早盘回踩和午后确认两个时窗。'
            $risk = '没有资金流时，不建议一次性重仓。'
            $confidence = 42
        }
        else {
            $primaryWindow = '次日 09:45-10:15'
            $secondaryWindow = '13:15-13:45'
            $action = '先观察'
            $reason = '缺少有效盘中数据时，弱势票不适合硬做当天买点。'
            $risk = '等待次日重新走强再考虑。'
            $confidence = 35
        }
    }

    return [PSCustomObject]@{
        IntradayBias     = $intradayBias
        FundFlowBias     = $fundFlowBias
        CurrentPhase     = $phase
        PriceVsAvgPct    = $priceVsAvgPct
        MainNetInflow    = $mainNet
        MorningMainNet   = $morningMain
        AfternoonMainNet = $afternoonMain
        PrimaryWindow    = $primaryWindow
        SecondaryWindow  = $secondaryWindow
        Action           = $action
        Reason           = $reason
        RiskNote         = $risk
        Confidence       = $confidence
    }
}

try {
    $identity = Get-StockIdentity -RawCode $Code
} catch {
    Write-Error $_
    return
}

$cacheKey = "entry_timing_$($identity.Code)"
$cached = Get-CachedData -Key $cacheKey -MaxAgeMinutes 15
if ($cached) {
    if ($Quiet) { return $cached }
    $result = $cached
} else {
    $quote = Get-QuoteSnapshot -SecId $identity.SecId
    $trends = Get-IntradayTrend -SecId $identity.SecId
    $flows = Get-MoneyFlow -SecId $identity.SecId
    $decision = Get-EntryDecision -Quote $quote -TrendPoints $trends -FlowPoints $flows

    $result = [PSCustomObject]@{
        Code             = $identity.Code
        Market           = $identity.Prefix
        Name             = if ($quote -and $quote.Name) { $quote.Name } else { $identity.Code }
        EvaluationTime   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        CurrentPrice     = if ($quote) { $quote.CurrentPrice } else { $null }
        DayChangePct     = if ($quote) { $quote.DayChangePct } else { $null }
        TurnoverRate     = if ($quote) { $quote.TurnoverRate } else { $null }
        TrendAvailable   = ($trends.Count -gt 0)
        FlowAvailable    = ($flows.Count -gt 0)
        TrendPoints      = $trends.Count
        FlowPoints       = $flows.Count
        IntradayBias     = $decision.IntradayBias
        FundFlowBias     = $decision.FundFlowBias
        CurrentPhase     = $decision.CurrentPhase
        PriceVsAvgPct    = $decision.PriceVsAvgPct
        MainNetInflow    = $decision.MainNetInflow
        MorningMainNet   = $decision.MorningMainNet
        AfternoonMainNet = $decision.AfternoonMainNet
        PrimaryWindow    = $decision.PrimaryWindow
        SecondaryWindow  = $decision.SecondaryWindow
        Action           = $decision.Action
        Reason           = $decision.Reason
        RiskNote         = $decision.RiskNote
        Confidence       = $decision.Confidence
        DataStatus       = if ($trends.Count -gt 0 -and $flows.Count -gt 0) { '分时+资金流齐全' } elseif ($trends.Count -gt 0) { '仅分时可用' } else { '使用日线降级判断' }
    }

    Set-CachedData -Key $cacheKey -Value $result
}

if ($Quiet) {
    return $result
}

Write-Host ""
Write-Host ("=" * 64) -ForegroundColor Cyan
Write-Host "  $($result.Name) ($($result.Market)$($result.Code)) 日内入手建议" -ForegroundColor Yellow
Write-Host ("=" * 64) -ForegroundColor Cyan
Write-Host "  当前: $($result.CurrentPrice)  涨跌幅: $($result.DayChangePct)%  换手: $($result.TurnoverRate)%" -ForegroundColor White
Write-Host "  分时: $($result.IntradayBias)  资金: $($result.FundFlowBias)  数据: $($result.DataStatus)" -ForegroundColor DarkGray
if ($null -ne $result.PriceVsAvgPct) {
    Write-Host "  现价相对均价线: $([string]::Format('{0:+0.00;-0.00}%', [double]$result.PriceVsAvgPct))" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  更适合的入手时点: $($result.PrimaryWindow)" -ForegroundColor Green
Write-Host "  备选时点: $($result.SecondaryWindow)" -ForegroundColor DarkGray
Write-Host "  动作: $($result.Action)" -ForegroundColor White
Write-Host "  理由: $($result.Reason)" -ForegroundColor DarkGray
Write-Host "  风险: $($result.RiskNote)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  * 仅供盘中节奏参考，不构成投资建议" -ForegroundColor DarkGray
Write-Host ""