<#
.SYNOPSIS
    获取A股个股详情：财报经营数据 + 近期涨跌幅 + 股息率 / 行业对标 / 估值分位
.DESCRIPTION
    从东方财富API获取：
    1. 实时行情（价格、PE、PB、市值）
    2. 近一周/近一月涨跌幅（基于日K线数据）
    3. 最近4期财报核心经营指标（营收、净利、毛利率、ROE等）
    4. 股息率（TTM）+ 近期分红记录
    5. 行业对标（行业名称 + 行业PE中位数）
    6. 估值历史分位（该股CAPE历史百分位 + 行业内对标）
.PARAMETER Code
    股票代码，支持纯数字（600519）或带前缀（SH600519 / sz000001）
.PARAMETER Action
    操作类型：
    - all: 全部信息（默认）
    - finance: 仅财报数据
    - price: 仅行情和涨跌幅
    - valuation: 财报 + 估值（股息、行业对标、历史分位）
.PARAMETER Quiet
    静默模式，返回对象不输出格式化文本
.EXAMPLE
    .\Get-StockDetail.ps1 -Code 600519
    .\Get-StockDetail.ps1 -Code 000001 -Action finance
    .\Get-StockDetail.ps1 -Code SH600519 -Action valuation
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Code,

    [ValidateSet("all", "finance", "price", "valuation")]
    [string]$Action = "all",

    [switch]$Quiet
)

# ── Helpers ──────────────────────────────────────────────────
$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

function Invoke-WebRequest2 {
    param([string]$Uri)
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri $Uri -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                "Referer"    = "https://quote.eastmoney.com/"
            } -TimeoutSec 15
            if ($null -ne $resp) { return $resp }
        } catch {}
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 800 }
    }
    return $null
}

function Format-LargeNumber {
    param([double]$Value)
    if ([Math]::Abs($Value) -ge 1e8) {
        return "{0:N2}亿" -f ($Value / 1e8)
    }
    elseif ([Math]::Abs($Value) -ge 1e4) {
        return "{0:N2}万" -f ($Value / 1e4)
    }
    else {
        return "{0:N2}" -f $Value
    }
}

function Format-Percent {
    param([object]$Value, [switch]$WithSign)
    if ($null -eq $Value) { return "N/A" }
    $v = [double]$Value
    if ($WithSign -and $v -gt 0) { return "+{0:N2}%" -f $v }
    return "{0:N2}%" -f $v
}

# ── Parse stock code ─────────────────────────────────────────
$rawCode = $Code.Trim().ToUpper()
# Strip prefix
if ($rawCode -match "^(?:SH|SZ)(\d{6})$") {
    $stockCode = $Matches[1]
}
elseif ($rawCode -match "^\d{6}$") {
    $stockCode = $rawCode
}
else {
    Write-Error "无效股票代码: $Code (请使用6位数字，如 600519 或 SH600519)"
    return
}

# Determine market
if ($stockCode -match "^6\d{5}$") {
    $market = 1       # SH
    $prefix = "SH"
}
elseif ($stockCode -match "^[0-3]\d{5}$") {
    $market = 0       # SZ
    $prefix = "SZ"
}
else {
    # 8xxxxx (北交所) etc
    $market = 0
    $prefix = "SZ"
}

$secId = "$market.$stockCode"

# ── Result container ──────────────────────────────────────────
$result = [PSCustomObject]@{
    Code          = $stockCode
    Name          = ""
    Market        = $prefix
    # Real-time
    Price         = $null
    Change        = $null
    ChangePercent = $null
    Open          = $null
    High          = $null
    Low           = $null
    Volume        = $null
    Amount        = $null
    TotalMktCap   = $null
    CircMktCap    = $null
    PE_TTM        = $null
    PE_Dynamic    = $null
    PB            = $null
    TurnoverRate  = $null
    # Price performance
    Week1Change   = $null
    Month1Change  = $null
    # Financial reports
    Reports       = @()
}

# ══════════════════════════════════════════════════════════════
# 1. Real-time quote + price performance
# ══════════════════════════════════════════════════════════════
if ($Action -in "all", "price") {
    # ── 1a. Real-time quote ──
    # f57=代码, f58=名称, f59=小数位数, f43=现价, f44=最高, f45=最低, f46=今开, f47=成交量(手), f48=成交额(元)
    # f162=动态PE, f164=PE(TTM), f167=PB, f168=换手率, f169=涨跌额, f170=涨跌幅
    $quoteUrl = "https://push2.eastmoney.com/api/qt/stock/get?secid=$secId&fields=f43,f44,f45,f46,f47,f48,f57,f58,f59,f116,f117,f162,f164,f167,f168,f169,f170"
    $quote = Invoke-WebRequest2 -Uri $quoteUrl

    if ($quote -and $quote.data) {
        $d = $quote.data
        # f59 = 小数位数（通常2），用于还原真实价格；f57 是代码字段，勿混淆
        $dec = if ($d.f59 -and [int]$d.f59 -gt 0 -and [int]$d.f59 -le 15) { [int]$d.f59 } else { 2 }
        $div = [Math]::Pow(10, $dec)

        $result.Name          = $d.f58
        $result.Price         = [Math]::Round($d.f43 / $div, $dec)
        $result.High          = [Math]::Round($d.f44 / $div, $dec)
        $result.Low           = [Math]::Round($d.f45 / $div, $dec)
        $result.Open          = [Math]::Round($d.f46 / $div, $dec)
        $result.Volume        = $d.f47        # 手
        $result.Amount        = $d.f48        # 元
        $result.TotalMktCap   = $d.f116
        $result.CircMktCap    = $d.f117
        $result.PE_Dynamic    = if ($d.f162 -and [double]$d.f162 -ne 0) { [Math]::Round([double]$d.f162 / 100, 2) } else { $null }
        $result.PE_TTM        = if ($d.f164 -and [double]$d.f164 -ne 0) { [Math]::Round([double]$d.f164 / 100, 2) } else { $null }
        $result.PB            = if ($d.f167 -and [double]$d.f167 -ne 0) { [Math]::Round([double]$d.f167 / 100, 2) } else { $null }
        $result.TurnoverRate  = if ($d.f168 -and [double]$d.f168 -ne 0) { [Math]::Round([double]$d.f168 / 100, 2) } else { $null }
        $result.ChangePercent = if ($d.f170) { [Math]::Round([double]$d.f170 / 100, 2) } else { $null }
        $result.Change        = if ($d.f169) { [Math]::Round([double]$d.f169 / $div, $dec) } else { $null }
    }

    # ── 1b. Kline for 1-week / 1-month change ──
    # Fetch ~45 trading days of daily klines (no adjustment)
    $today = Get-Date -Format "yyyyMMdd"
    $begDate = (Get-Date).AddDays(-60).ToString("yyyyMMdd")
    $klineUrl = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=$secId&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61&klt=101&fqt=0&beg=$begDate&end=$today&lmt=45"
    $kline = Invoke-WebRequest2 -Uri $klineUrl

    if ($kline -and $kline.data -and $kline.data.klines) {
        $lines = @($kline.data.klines)
        if (-not $result.Name -and $kline.data.name) {
            $result.Name = $kline.data.name
        }
        $count = $lines.Count
        if ($count -ge 2) {
            # Latest close — 盘中K线可能不含当日bar，用实时价格覆盖
            $latestParts = $lines[$count - 1] -split ","
            $latestClose = [double]$latestParts[2]
            if ($result.Price -gt 0) { $latestClose = $result.Price }

            # 1-week: ~5 trading days ago
            $week1Idx = [Math]::Max(0, $count - 6)
            $week1Parts = $lines[$week1Idx] -split ","
            $week1Close = [double]$week1Parts[2]
            if ($week1Close -gt 0) {
                $result.Week1Change = [Math]::Round(($latestClose - $week1Close) / $week1Close * 100, 2)
            }

            # 1-month: ~22 trading days ago
            $month1Idx = [Math]::Max(0, $count - 23)
            $month1Parts = $lines[$month1Idx] -split ","
            $month1Close = [double]$month1Parts[2]
            if ($month1Close -gt 0) {
                $result.Month1Change = [Math]::Round(($latestClose - $month1Close) / $month1Close * 100, 2)
            }
        }
    }
}

# ══════════════════════════════════════════════════════════════
# 2. Financial reports
# ══════════════════════════════════════════════════════════════
if ($Action -in "all", "finance") {
    $finUrl = "https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/ZYZBAjaxNew?type=0&code=${prefix}${stockCode}"
    # 财报接口需要 f10 页面 Referer，否则返回空数据
    $fin = $null
    try {
        $fin = Invoke-RestMethod -Uri $finUrl -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = "https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/Index?type=web&code=${prefix}${stockCode}"
            "Accept"     = "application/json, text/plain, */*"
        } -TimeoutSec 15
    } catch { }

    if ($fin -and $fin.data) {
        # Get name from financial data if not set
        if (-not $result.Name -and $fin.data.Count -gt 0) {
            $result.Name = $fin.data[0].SECURITY_NAME_ABBR
        }

        # Take latest 8 reports (2 years)
        $reports = @()
        $topN = [Math]::Min(8, $fin.data.Count)
        for ($i = 0; $i -lt $topN; $i++) {
            $r = $fin.data[$i]
            $reports += [PSCustomObject]@{
                ReportName     = $r.REPORT_DATE_NAME              # e.g. "2025三季报"
                ReportDate     = if ($r.REPORT_DATE) { ([datetime]$r.REPORT_DATE).ToString("yyyy-MM-dd") } else { "N/A" }
                Revenue        = $r.TOTALOPERATEREVE              # 营业收入
                RevenueYoY     = $r.TOTALOPERATEREVETZ            # 营收同比增长%
                NetProfit      = $r.PARENTNETPROFIT               # 归母净利润
                NetProfitYoY   = $r.PARENTNETPROFITTZ             # 净利同比增长%
                EPS            = $r.EPSJB                         # 每股收益
                BPS            = $r.BPS                           # 每股净资产
                GrossMargin    = $r.XSMLL                         # 毛利率%
                NetMargin      = $r.XSJLL                         # 净利率%
                ROE            = $r.ROEJQ                         # ROE(加权)
                DebtRatio      = $r.ZCFZL                         # 资产负债率%
                CashFlowPS     = $r.MGJYXJJE                     # 每股经营现金流
            }
        }
        $result.Reports = $reports
    }
}

# ══════════════════════════════════════════════════════════════
# 3. Valuation Extras (Dividend / Industry Comparison / CAPE Percentile)
# ══════════════════════════════════════════════════════════════
$valExtras = @{
    DividendPerShareTTM         = $null
    DividendYieldTTM            = $null
    DividendYears               = 0
    DividendRecords             = @()
    IndustryName                = $null
    IndustryStaticPEWeighted    = $null
    IndustryStaticPEMedian      = $null
    IndustrySampleCount         = $null
    HistoricalCapePercentile    = $null
    HistoricalCapeMedian        = $null
    HistoricalCapeSamples       = @()
}

if ($Action -in "all", "valuation") {
    if ($null -ne $result.Price -and $result.Price -gt 0) {
        try {
            $pyHelper = Join-Path $PSScriptRoot "python\Get-ValuationExtras.py"
            if (Test-Path $pyHelper) {
                # Fetch CAPE first (quick call to Get-CapeValuation)
                $cape = $null
                try {
                    $capeScript = Join-Path $PSScriptRoot "Get-CapeValuation.ps1"
                    if (Test-Path $capeScript) {
                        $capeRes = & $capeScript -Code $stockCode -Years 10 -Quiet -ErrorAction SilentlyContinue
                        if ($capeRes) { $cape = $capeRes.NominalCAPE }
                    }
                } catch { }

                $env:PYTHONIOENCODING = "utf-8"
                $pyOutFile = Join-Path $env:TEMP "stockdetail_$stockCode.json"
                if (Test-Path $pyOutFile) { Remove-Item $pyOutFile -Force }
                $pyProc = Start-Process -FilePath "C:\Python\Python39\python.exe" -ArgumentList "$pyHelper","$stockCode","10","$($result.Price)","$cape" -Wait:$false -NoNewWindow -PassThru -RedirectStandardOutput $pyOutFile -RedirectStandardError "NUL"
                if ($pyProc.WaitForExit(30000)) {
                    # Completed within 30s
                    if (Test-Path $pyOutFile) {
                        $pyOut = Get-Content $pyOutFile -Raw -ErrorAction SilentlyContinue
                    }
                } else {
                    # Timeout — kill it
                    try { $pyProc.Kill() } catch {}
                    $pyOut = $null
                }
                if ($pyOut) {
                    $pyData = $pyOut | ConvertFrom-Json
                    foreach ($key in $pyData.PSObject.Properties.Name) {
                        if ($valExtras.ContainsKey($key)) {
                            $valExtras[$key] = $pyData.$key
                        }
                    }
                }
            }
        }
        catch { }
    }
}

$result | Add-Member -MemberType NoteProperty -Name "ValuationExtras" -Value $valExtras -Force

# ══════════════════════════════════════════════════════════════
# 4. Display
# ══════════════════════════════════════════════════════════════
if ($Quiet) {
    return $result
}

$nameDisplay = if ($result.Name) { "$($result.Name) ($prefix$stockCode)" } else { "$prefix$stockCode" }
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  $nameDisplay" -ForegroundColor White
Write-Host ("=" * 60) -ForegroundColor Cyan

# ── 3a. Price & Performance ──
if ($Action -in "all", "price") {
    Write-Host ""
    Write-Host "  ── 实时行情 ──" -ForegroundColor Yellow

    if ($null -ne $result.Price) {
        # Color based on change
        $priceColor = "White"
        if ($result.ChangePercent -gt 0) { $priceColor = "Red" }
        elseif ($result.ChangePercent -lt 0) { $priceColor = "Green" }

        $changeStr = ""
        if ($null -ne $result.Change) {
            $sign = if ($result.Change -gt 0) { "+" } else { "" }
            $changeStr = "  $sign$($result.Change)  $(Format-Percent -Value $result.ChangePercent -WithSign)"
        }

        Write-Host ("    最新价: {0:N2}" -f $result.Price) -ForegroundColor $priceColor -NoNewline
        Write-Host $changeStr -ForegroundColor $priceColor

        Write-Host ("    今开: {0:N2}  最高: {1:N2}  最低: {2:N2}" -f $result.Open, $result.High, $result.Low)
        Write-Host ("    成交量: {0:N0}手  成交额: {1}" -f $result.Volume, (Format-LargeNumber $result.Amount))

        if ($null -ne $result.TotalMktCap) {
            Write-Host ("    总市值: {0}  流通市值: {1}" -f (Format-LargeNumber $result.TotalMktCap), (Format-LargeNumber $result.CircMktCap))
        }

        $peStr = if ($null -ne $result.PE_TTM) { "{0:N2}" -f $result.PE_TTM } else { "N/A" }
        $pbStr = if ($null -ne $result.PB) { "{0:N2}" -f $result.PB } else { "N/A" }
        $trStr = if ($null -ne $result.TurnoverRate) { "{0:N2}%" -f $result.TurnoverRate } else { "N/A" }
        Write-Host ("    PE(TTM): {0}  PB: {1}  换手率: {2}" -f $peStr, $pbStr, $trStr)
    }
    else {
        Write-Host "    (无法获取实时行情数据)" -ForegroundColor DarkGray
    }

    # Price performance
    Write-Host ""
    Write-Host "  ── 近期涨跌幅 ──" -ForegroundColor Yellow

    function Show-ChangeBar {
        param([string]$Label, [object]$Value)
        if ($null -eq $Value) {
            Write-Host "    ${Label}: N/A" -ForegroundColor DarkGray
            return
        }
        $v = [double]$Value
        $color = if ($v -gt 0) { "Red" } elseif ($v -lt 0) { "Green" } else { "White" }
        $sign = if ($v -gt 0) { "+" } else { "" }
        $barLen = [Math]::Min([Math]::Abs([int]$v), 30)
        $bar = if ($v -ge 0) { ("█" * $barLen) } else { ("█" * $barLen) }
        Write-Host "    ${Label}: " -NoNewline
        Write-Host ("{0}{1:N2}% {2}" -f $sign, $v, $bar) -ForegroundColor $color
    }

    Show-ChangeBar -Label "近一周" -Value $result.Week1Change
    Show-ChangeBar -Label "近一月" -Value $result.Month1Change
}

# ── 3b. Financial reports ──
if ($Action -in "all", "finance") {
    Write-Host ""
    Write-Host "  ── 财报核心指标 ──" -ForegroundColor Yellow

    if ($result.Reports.Count -gt 0) {
        # Header — use compact column width for 8 reports
        $colW = 14
        $headerParts = @("    {0,-12}" -f "指标")
        foreach ($rpt in $result.Reports) {
            # Shorten: "2025三季报" → "25Q3", "2024年报" → "24FY", "2024中报" → "24H1", "2024一季报" → "24Q1"
            $shortName = $rpt.ReportName
            if ($shortName -match "^(\d{4})(.+)$") {
                $yr = $Matches[1].Substring(2)  # "2025" → "25"
                $qtr = $Matches[2]
                $shortName = switch -Regex ($qtr) {
                    "年报"   { "${yr}FY" }
                    "一季报" { "${yr}Q1" }
                    "中报"   { "${yr}H1" }
                    "三季报" { "${yr}Q3" }
                    default  { "${yr}${qtr}" }
                }
            }
            $headerParts += ("{0,$colW}" -f $shortName)
        }
        Write-Host ($headerParts -join "") -ForegroundColor Cyan
        Write-Host ("    " + ("-" * (12 + $colW * $result.Reports.Count))) -ForegroundColor DarkGray

        # Helper to write a row
        function Write-FinRow {
            param([string]$Label, [string]$FormatType, [string]$PropName)
            $parts = @("    {0,-12}" -f $Label)
            foreach ($rpt in $result.Reports) {
                $val = $rpt.$PropName
                switch ($FormatType) {
                    "money"   { $parts += ("{0,$colW}" -f (Format-LargeNumber $val)) }
                    "percent" { $parts += ("{0,$colW}" -f (Format-Percent -Value $val)) }
                    "number"  {
                        if ($null -ne $val) { $parts += ("{0,$colW}" -f ("{0:N2}" -f [double]$val)) }
                        else { $parts += ("{0,$colW}" -f "N/A") }
                    }
                    "growth"  {
                        if ($null -ne $val) {
                            $v = [double]$val
                            $sign = if ($v -gt 0) { "+" } else { "" }
                            $str = "$sign{0:N2}%" -f $v
                            $parts += ("{0,$colW}" -f $str)
                        }
                        else { $parts += ("{0,$colW}" -f "N/A") }
                    }
                }
            }
            $line = $parts -join ""
            Write-Host $line
        }

        Write-FinRow -Label "营业收入"   -FormatType "money"   -PropName "Revenue"
        Write-FinRow -Label "  同比增长" -FormatType "growth"  -PropName "RevenueYoY"
        Write-FinRow -Label "归母净利润" -FormatType "money"   -PropName "NetProfit"
        Write-FinRow -Label "  同比增长" -FormatType "growth"  -PropName "NetProfitYoY"
        Write-FinRow -Label "每股收益"   -FormatType "number"  -PropName "EPS"
        Write-FinRow -Label "每股净资产" -FormatType "number"  -PropName "BPS"
        Write-FinRow -Label "毛利率"     -FormatType "percent" -PropName "GrossMargin"
        Write-FinRow -Label "净利率"     -FormatType "percent" -PropName "NetMargin"
        Write-FinRow -Label "ROE(加权)"  -FormatType "percent" -PropName "ROE"
        Write-FinRow -Label "资产负债率" -FormatType "percent" -PropName "DebtRatio"
        Write-FinRow -Label "經營現金流/股" -FormatType "number" -PropName "CashFlowPS"
    }
    else {
        Write-Host "    (无法获取财报数据)" -ForegroundColor DarkGray
    }
}

# ── 3c. Valuation Extras ──
if ($Action -in "all", "valuation" -and (@($valExtras.DividendPerShareTTM, $valExtras.IndustryName, $valExtras.HistoricalCapePercentile) | Where-Object { $null -ne $_ }).Count -gt 0) {
    Write-Host ""
    Write-Host "  ── 估值与行业对标 ──" -ForegroundColor Cyan

    # Dividend
    if ($null -ne $valExtras.DividendYieldTTM) {
        Write-Host ("    股息率(TTM): {0:N2}%" -f $valExtras.DividendYieldTTM) -ForegroundColor Yellow
        if ($valExtras.DividendRecords.Count -gt 0) {
            Write-Host "      最近分红: " -NoNewline
            $divEntries = $valExtras.DividendRecords | ForEach-Object { "$($_.Date) $($_.DividendPerShare)元" }
            Write-Host ($divEntries -join " | ") -ForegroundColor DarkGray
        }
    }

    # Industry PE
    if ($null -ne $valExtras.IndustryName) {
        $indStr = $valExtras.IndustryName
        if ($null -ne $valExtras.IndustryStaticPEMedian) {
            $indStr += " (行业PE中位數: $($valExtras.IndustryStaticPEMedian))"
        }
        if ($null -ne $valExtras.IndustrySampleCount) {
            $indStr += " 样本: $($valExtras.IndustrySampleCount)"
        }
        Write-Host ("    行业对标: {0}" -f $indStr) -ForegroundColor Cyan
    }

    # CAPE Percentile
    if ($null -ne $valExtras.HistoricalCapePercentile) {
        Write-Host ("    CAPE历史分位: {0}% " -f $valExtras.HistoricalCapePercentile) -NoNewline -ForegroundColor Yellow
        $median = $valExtras.HistoricalCapeMedian
        $bar = "("
        if ($median) { $bar += "历史中位: $median" }
        if ($valExtras.HistoricalCapeMin) { $bar += " | 范围: $($valExtras.HistoricalCapeMin)-$($valExtras.HistoricalCapeMax)" }
        $bar += ")"
        Write-Host $bar -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  * 数据来源: 东方财富  行情可能有15分钟延迟" -ForegroundColor DarkGray
Write-Host "  * 此为数据展示，不构成投资建议" -ForegroundColor DarkGray
Write-Host ""
