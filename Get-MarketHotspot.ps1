<#
.SYNOPSIS
    A股市场热点分析和股票推荐（含估值参考 + 舆情评分）
.DESCRIPTION
    从东方财富、新浪财经等数据源获取最新行情和新闻，分析市场热点板块，
    推荐A股主板+创业板股票（排除科创板688xxx、北交所8xxxxx）。
    对推荐股票逐个调用 Get-CapeValuation.ps1 追加 CAPE 估值信息。
    增加：磁盘缓存（复用财报数据）、舆情评分、三维度打分模型、日内买点建议。
.PARAMETER Action
    操作类型：
    - news: 仅显示最新财经新闻
    - sectors: 仅显示热门板块（行业+概念）
    - recommend: 分析热门板块并推荐股票（含CAPE）
    - all: 全部信息（默认，含CAPE）
.PARAMETER TopN
    显示前N个结果（默认10）
.PARAMETER Quiet
    静默模式，仅返回对象不输出格式化文本
.PARAMETER IncludeCAPE
    已弃用。推荐股默认始终包含估值与财报分析。
.EXAMPLE
    .\Get-MarketHotspot.ps1
    .\Get-MarketHotspot.ps1 -Action sectors
    .\Get-MarketHotspot.ps1 -Action recommend -TopN 15
    .\Get-MarketHotspot.ps1 -Action news -TopN 20
    .\Get-MarketHotspot.ps1 -Action recommend
#>
param(
    [ValidateSet("news", "sectors", "recommend", "all")]
    [string]$Action = "all",

    [int]$TopN = 10,

    [bool]$IncludeCAPE = $true,

    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# ── 全局常量（与 Get-AlphaSignal.ps1 保持同步，改行业分类只改这里）──
$script:CyclicalKeywords = @(
    '化工','化肥','能源','石油','煤炭','有色','金属','钢铁',
    '矿业','农业','银行','保险','地产','建筑','水泥','航运','航空'
)

# ============================================================
# 磁盘缓存 Helper（与 AlphaSignal / USStrongAStocks 共享）
# ============================================================
$script:CacheDir = Join-Path $env:TEMP "MyClaw_StockCache"
if (-not (Test-Path $script:CacheDir)) {
    New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
}

function Get-CachedData {
    param([string]$Key, [int]$MaxAgeMinutes = 240)
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
    $file = Join-Path $script:CacheDir "$Key.json"
    try { $Value | ConvertTo-Json -Depth 8 | Out-File $file -Encoding UTF8 } catch {}
}

# ============================================================
# HTTP Client Helper
# ============================================================
function Invoke-ApiRequest {
    param(
        [string]$Url,
        [string]$Referer = "https://data.eastmoney.com/",
        [int]$TimeoutSec = 15
    )
    try {
        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            "Referer"    = $Referer
            "Accept"     = "application/json, text/plain, */*"
        }
        $response = Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec
        return $response
    }
    catch {
        return $null
    }
}

# ============================================================
# 舆情分析（东财快讯 + 雪球 + 36Kr）
# ============================================================
function Get-MarketSentiment {
    $bullKeywords = @('上涨','大涨','创新高','突破','利好','增长','超预期','转型','并购','回升','走强','爆发','提升','翻倍','反弹','新高','放量','强势')
    $bearKeywords = @('下跌','暴跌','创新低','利空','萎缩','不及预期','亏损','监管','处罚','暴雷','下调','调查','违规','风险','崩盘','破位','缩量','弱势')

    $headlines = @()

    # 东财快讯
    try {
        $emUrl = "https://np-listapi.eastmoney.com/comm/web/getNewsByColumns?client=web&biz=web_news_col&column=350&order=1&needInteractData=0&page_index=1&page_size=30"
        $emData = Invoke-RestMethod -Uri $emUrl -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = "https://finance.eastmoney.com/"
        } -TimeoutSec 12
        if ($emData -and $emData.data -and $emData.data.list) {
            foreach ($it in $emData.data.list) { $headlines += "$($it.title)" }
        }
    } catch {}

    # 雪球热帖
    try {
        $xqUrl = "https://xueqiu.com/v4/statuses/public_timeline_by_category.json?since_id=-1&max_id=-1&count=20&category=-1"
        $xqData = Invoke-RestMethod -Uri $xqUrl -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = "https://xueqiu.com/"
            "Cookie"     = "xq_a_token=xueqiu"
        } -TimeoutSec 12
        if ($xqData -and $xqData.list) {
            foreach ($it in $xqData.list) {
                $text = "$($it.text)" -replace '<[^>]+>', ''
                if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
                $headlines += $text
            }
        }
    } catch {}

    # 36Kr
    try {
        $krUrl = "https://www.36kr.com/newsflashes"
        $krResp = Invoke-WebRequest -Uri $krUrl -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        } -TimeoutSec 12 -UseBasicParsing
        if ($krResp.Content) {
            $matches1 = [regex]::Matches($krResp.Content, '"title"\s*:\s*"([^"]{5,80})"')
            if ($matches1.Count -gt 0) {
                foreach ($m in $matches1) { $headlines += $m.Groups[1].Value }
            } else {
                $matches2 = [regex]::Matches($krResp.Content, '<h3[^>]*>([^<]{5,80})</h3>')
                foreach ($m in $matches2) { $headlines += $m.Groups[1].Value }
            }
        }
    } catch {}

    if ($headlines.Count -eq 0) {
        return [PSCustomObject]@{ SentimentIndex = 5; BullCount = 0; BearCount = 0; Total = 0; TopBullish = @(); TopBearish = @() }
    }

    $bullCount = 0; $bearCount = 0
    $topBullish = @(); $topBearish = @()
    foreach ($line in $headlines) {
        $isBull = $false; $isBear = $false
        foreach ($kw in $bullKeywords) { if ($line -like "*$kw*") { $isBull = $true; break } }
        foreach ($kw in $bearKeywords) { if ($line -like "*$kw*") { $isBear = $true; break } }
        if ($isBull -and -not $isBear) {
            $bullCount++
            if ($topBullish.Count -lt 3) { $topBullish += $line.Substring(0, [Math]::Min(60, $line.Length)) }
        } elseif ($isBear -and -not $isBull) {
            $bearCount++
            if ($topBearish.Count -lt 3) { $topBearish += $line.Substring(0, [Math]::Min(60, $line.Length)) }
        }
    }

    $total = $bullCount + $bearCount
    $sentimentIndex = 5
    if ($total -gt 0) {
        $sentimentIndex = [Math]::Round(5 + ($bullCount - $bearCount) / $total * 4, 1)
        $sentimentIndex = [Math]::Max(1, [Math]::Min(10, $sentimentIndex))
    }

    return [PSCustomObject]@{
        SentimentIndex = $sentimentIndex
        BullCount      = $bullCount
        BearCount      = $bearCount
        Total          = $total
        TopBullish     = $topBullish
        TopBearish     = $topBearish
    }
}

# ============================================================
# 1. 获取热门板块（行业 + 概念）
# ============================================================
function Get-HotSectors {
    param([int]$Top = 10)

    # --- 行业板块 ---
    $industryUrl = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$Top&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=m:90+t:2&fields=f2,f3,f4,f12,f14"
    $industryData = Invoke-ApiRequest -Url $industryUrl

    $industries = @()
    if ($industryData -and $industryData.data -and $industryData.data.diff) {
        $idx = 1
        foreach ($item in $industryData.data.diff) {
            $industries += [PSCustomObject]@{
                Rank      = $idx
                Code      = "$($item.f12)"
                Name      = "$($item.f14)"
                ChangePct = [double]$item.f3
                Change    = "$($item.f3)%"
                Type      = "行业"
            }
            $idx++
        }
    }

    # --- 概念板块（过滤掉噪音概念）---
    $fetchSize = $Top + 15
    $conceptUrl = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$fetchSize&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=m:90+t:3&fields=f2,f3,f4,f12,f14"
    $conceptData = Invoke-ApiRequest -Url $conceptUrl

    $noisePatterns = @(
        '昨日涨停', '昨日首板', '昨日连板', '今日涨停',
        '百元股', '破净股', '低价股', '高价股', '新股与次新股',
        '融资融券', '股权转让', '含可转债', '基金重仓',
        '社保重仓', 'QFII重仓', '机构重仓'
    )

    $concepts = @()
    if ($conceptData -and $conceptData.data -and $conceptData.data.diff) {
        $idx = 1
        foreach ($item in $conceptData.data.diff) {
            $name = "$($item.f14)"
            $isNoise = $false
            foreach ($pattern in $noisePatterns) {
                if ($name -like "*$pattern*") { $isNoise = $true; break }
            }
            if ($isNoise) { continue }
            if ($idx -gt $Top) { break }
            $concepts += [PSCustomObject]@{
                Rank      = $idx
                Code      = "$($item.f12)"
                Name      = $name
                ChangePct = [double]$item.f3
                Change    = "$($item.f3)%"
                Type      = "概念"
            }
            $idx++
        }
    }

    if (-not $Quiet) {
        if ($industries.Count -gt 0) {
            Write-Host "`n=== 行业板块涨幅 Top $Top ===" -ForegroundColor Cyan
            $industries | Format-Table Rank, Name, Change -AutoSize | Out-String | Write-Host
        } else {
            Write-Host "  (无法获取行业板块数据，可能为非交易时段)" -ForegroundColor DarkGray
        }
        if ($concepts.Count -gt 0) {
            Write-Host "=== 概念板块涨幅 Top $Top ===" -ForegroundColor Cyan
            $concepts | Format-Table Rank, Name, Change -AutoSize | Out-String | Write-Host
        } else {
            Write-Host "  (无法获取概念板块数据)" -ForegroundColor DarkGray
        }
    }

    return @{ Industries = $industries; Concepts = $concepts }
}

# ============================================================
# 2. 获取最新财经新闻（新浪 + 东财备用）
# ============================================================
function Get-LatestNews {
    param([int]$Top = 10)

    $news = @()

    # --- 新浪财经滚动新闻 ---
    try {
        $sinaUrl = "https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&k=&num=$Top&page=1"
        $sinaData = Invoke-ApiRequest -Url $sinaUrl -Referer "https://finance.sina.com.cn/"
        if ($sinaData -and $sinaData.result -and $sinaData.result.data) {
            foreach ($item in $sinaData.result.data) {
                $time = ""
                try {
                    if ($item.ctime) { $time = [DateTimeOffset]::FromUnixTimeSeconds([long]$item.ctime).ToLocalTime().ToString("HH:mm") }
                } catch {}
                $title = "$($item.title)" -replace '<[^>]+>', ''
                if ($title) {
                    $news += [PSCustomObject]@{
                        Time   = $time
                        Title  = $title.Trim()
                        Source = "新浪财经"
                        Url    = "$($item.url)"
                    }
                }
            }
        }
    } catch {}

    # 东财备用
    if ($news.Count -eq 0) {
        try {
            $emUrl = "https://np-listapi.eastmoney.com/comm/web/getNewsByColumns?client=web&biz=web_news_col&column=350&order=1&needInteractData=0&page_index=1&page_size=$Top"
            $emData = Invoke-ApiRequest -Url $emUrl -Referer "https://finance.eastmoney.com/"
            if ($emData -and $emData.data -and $emData.data.list) {
                foreach ($item in $emData.data.list) {
                    $news += [PSCustomObject]@{
                        Time   = if ($item.showTime) { $item.showTime } else { "" }
                        Title  = "$($item.title)"
                        Source = "东方财富"
                        Url    = "$($item.url)"
                    }
                }
            }
        } catch {}
    }

    # 东财快讯（第3备用）
    if ($news.Count -eq 0) {
        try {
            $emKxUrl = "https://np-anotice-stock.eastmoney.com/api/security/ann?sr=-1&page=1&num=$Top&sign=eg"
            $emKxData = Invoke-ApiRequest -Url $emKxUrl -Referer "https://data.eastmoney.com/"
            if ($emKxData -and $emKxData.data -and $emKxData.data.list) {
                foreach ($item in $emKxData.data.list) {
                    $news += [PSCustomObject]@{
                        Time   = ""
                        Title  = "$($item.TITLE)"
                        Source = "东财公告"
                        Url    = ""
                    }
                }
            }
        } catch {}
    }

    if (-not $Quiet) {
        Write-Host "`n=== 最新财经要闻 ===" -ForegroundColor Cyan
        if ($news.Count -gt 0) {
            $idx = 1
            foreach ($n in $news) {
                $timeStr = if ($n.Time) { "[$($n.Time)]" } else { "" }
                Write-Host ("  {0,2}. " -f $idx) -NoNewline -ForegroundColor DarkGray
                if ($timeStr) { Write-Host "$timeStr " -NoNewline -ForegroundColor DarkGray }
                Write-Host "$($n.Title)" -ForegroundColor White
                $idx++
            }
        } else {
            Write-Host "  (无法获取新闻数据)" -ForegroundColor DarkGray
        }
    }

    return $news
}

# ============================================================
# 3. 获取板块成分股
# ============================================================
function Get-SectorStocks {
    param([string]$SectorCode, [int]$Top = 30)

    $url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$Top&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=b:$SectorCode&fields=f2,f3,f4,f5,f6,f12,f14,f9,f23"
    $data = Invoke-ApiRequest -Url $url

    $stocks = @()
    if ($data -and $data.data -and $data.data.diff) {
        foreach ($item in $data.data.diff) {
            $code = "$($item.f12)"
            if (-not $code -or $code -eq "-") { continue }
            $stocks += [PSCustomObject]@{
                Code      = $code
                Name      = "$($item.f14)"
                Price     = $item.f2
                ChangePct = $item.f3
                Change    = $item.f4
                Volume    = $item.f5
                Amount    = $item.f6
                PE_TTM    = $item.f9
                PB        = $item.f23
            }
        }
    }
    return $stocks
}

# ============================================================
# 4. 检查是否为A股主板+创业板（排除科创板/北交所）
# ============================================================
function Test-MainBoard {
    param([string]$Code)
    if ($Code -match '^(60[0-9]\d{3}|00[012]\d{3}|300\d{3})$') { return $true }
    return $false
}

# ============================================================
# 5. 格式化成交额
# ============================================================
function Format-Amount {
    param($Value)
    if ($null -eq $Value -or $Value -eq "-") { return "-" }
    try {
        $num = [double]$Value
        if ($num -ge 100000000) { return "{0:N2}亿" -f ($num / 100000000) }
        elseif ($num -ge 10000) { return "{0:N0}万" -f ($num / 10000) }
        else { return "$num" }
    } catch { return "$Value" }
}

# ============================================================
# 6. A股分析（带缓存）
# ============================================================
function Get-AStockAnalysis {
    param([string]$Code, [bool]$IsCyclical = $false)

    # 先查磁盘缓存
    $cached = Get-CachedData -Key "hotspot_detail_$Code" -MaxAgeMinutes 360
    if ($cached) { return [PSCustomObject]$cached }

    $detailScript = Join-Path $PSScriptRoot 'Get-StockDetail.ps1'

    $analysis = [ordered]@{
        ReportName       = $null
        RevenueYoY       = $null
        ProfitYoY        = $null
        ROE              = $null
        PE_TTM           = $null
        PB               = $null
        CapeNominal      = $null
        CapeLevel        = $null
        IndustryMedianPE = $null   # 行业中位PE，用于相对估值
        GrossMarginTrend = $null   # improving/declining/stable
        ROETrend         = $null   # improving/declining/stable
    }

    try {
        if (Test-Path $detailScript) {
            $d = & $detailScript -Code $Code -Action all -Quiet -ErrorAction SilentlyContinue
            if ($d) {
                $analysis.PE_TTM = $d.PE_TTM
                $analysis.PB = $d.PB
                if ($d.ValuationExtras -and $null -ne $d.ValuationExtras.IndustryStaticPEMedian) {
                    $analysis.IndustryMedianPE = $d.ValuationExtras.IndustryStaticPEMedian
                }
                if ($d.Reports -and $d.Reports.Count -gt 0) {
                    $r = $d.Reports[0]
                    $analysis.ReportName = $r.ReportName
                    $analysis.RevenueYoY = $r.RevenueYoY
                    $analysis.ProfitYoY  = $r.NetProfitYoY
                    $analysis.ROE        = $r.ROE
                }
                # 财报趋势：取最近3季度毛利率和ROE
                if ($d.Reports -and $d.Reports.Count -ge 3) {
                    $gms = @($d.Reports[0..2] | ForEach-Object {
                        if ($null -ne $_.GrossMargin -and "$($_.GrossMargin)" -ne '') { [double]$_.GrossMargin } else { $null }
                    } | Where-Object { $null -ne $_ })
                    if ($gms.Count -ge 2) {
                        if ($gms[0] -gt $gms[-1] + 1) { $analysis.GrossMarginTrend = "improving" }
                        elseif ($gms[0] -lt $gms[-1] - 1) { $analysis.GrossMarginTrend = "declining" }
                        else { $analysis.GrossMarginTrend = "stable" }
                    }
                    $roes = @($d.Reports[0..2] | ForEach-Object {
                        if ($null -ne $_.ROE -and "$($_.ROE)" -ne '') { [double]$_.ROE } else { $null }
                    } | Where-Object { $null -ne $_ })
                    if ($roes.Count -ge 2) {
                        if ($roes[0] -gt $roes[-1] + 1) { $analysis.ROETrend = "improving" }
                        elseif ($roes[0] -lt $roes[-1] - 1) { $analysis.ROETrend = "declining" }
                        else { $analysis.ROETrend = "stable" }
                    }
                }
            }
        }
    } catch {}

    # 只有周期股才计算 CAPE
    if ($IsCyclical) {
        $capeScript = Join-Path $PSScriptRoot 'Get-CapeValuation.ps1'
        try {
            if (Test-Path $capeScript) {
                $c = & $capeScript -Code $Code -Years 10 -Quiet -ErrorAction SilentlyContinue
                if ($c) {
                    $analysis.CapeNominal = $c.NominalCAPE
                    $analysis.CapeLevel   = $c.CapeLevel
                }
            }
        } catch {}
    }

    # 写缓存
    Set-CachedData -Key "hotspot_detail_$Code" -Value $analysis

    return [PSCustomObject]$analysis
}

function Get-EntryTimingAdvice {
    param([string]$Code)

    $timingScript = Join-Path $PSScriptRoot 'Get-EntryTiming.ps1'
    if (-not (Test-Path $timingScript)) { return $null }

    try {
        return (& $timingScript -Code $Code -Quiet -ErrorAction SilentlyContinue)
    } catch {
        return $null
    }
}

# ============================================================
# 7. 三维度打分（基本面 0-40 + 技术 0-20 + 估值 0-40）
# ============================================================
function Get-StockScore {
    param(
        $Stock,           # 板块成分股对象（含 ChangePct/Amount/PE_TTM）
        $Analysis         # Get-AStockAnalysis 输出
    )

    $score = 0

    # -- 基本面 0-40 --
    if ($null -ne $Analysis.RevenueYoY) {
        $rv = [double]$Analysis.RevenueYoY
        if ($rv -gt 30) { $score += 20 } elseif ($rv -gt 15) { $score += 14 } elseif ($rv -gt 0) { $score += 7 }
    }
    if ($null -ne $Analysis.ProfitYoY) {
        $pf = [double]$Analysis.ProfitYoY
        if ($pf -gt 30) { $score += 15 } elseif ($pf -gt 15) { $score += 10 } elseif ($pf -gt 0) { $score += 5 }
    }
    if ($null -ne $Analysis.ROE) {
        $roe = [double]$Analysis.ROE
        if ($roe -gt 20) { $score += 5 } elseif ($roe -gt 12) { $score += 3 }
    }

    # ── PEG 加分（PE / 净利润增速，<1 是价值区） ──
    $pePrimary = $null
    if ($null -ne $Analysis.PE_TTM -and [double]$Analysis.PE_TTM -gt 0) { $pePrimary = [double]$Analysis.PE_TTM }
    elseif ($null -ne $Stock.PE_TTM -and "$($Stock.PE_TTM)" -ne "-" -and [double]$Stock.PE_TTM -gt 0) { $pePrimary = [double]$Stock.PE_TTM }
    if ($null -ne $pePrimary -and $null -ne $Analysis.ProfitYoY -and [double]$Analysis.ProfitYoY -gt 5) {
        $peg = $pePrimary / [double]$Analysis.ProfitYoY
        if ($peg -lt 0.5)     { $score += 8 }
        elseif ($peg -lt 1.0) { $score += 5 }
        elseif ($peg -lt 1.5) { $score += 2 }
        elseif ($peg -gt 3.0) { $score -= 3 }
    }

    # ── 财报趋势奖惩 ──
    if ($Analysis.GrossMarginTrend -eq "improving") { $score += 5 }
    elseif ($Analysis.GrossMarginTrend -eq "declining") { $score -= 3 }
    if ($Analysis.ROETrend -eq "improving") { $score += 3 }
    elseif ($Analysis.ROETrend -eq "declining") { $score -= 2 }

    $score = [Math]::Min(40, [Math]::Max(0, $score))

    # -- 技术面 0-20（板块当日涨幅、成交额） --
    $chg = if ($null -ne $Stock.ChangePct) { [double]$Stock.ChangePct } else { 0 }
    if ($chg -ge 8) { $score += 20 } elseif ($chg -ge 5) { $score += 15 } elseif ($chg -ge 3) { $score += 10 } elseif ($chg -gt 0) { $score += 5 }

    # -- 估值面 0-40 --
    $sName = "$($Stock.SectorName)"
    $isCyclical = $script:CyclicalKeywords | Where-Object { $sName -match $_ }

    $pe = $pePrimary  # reuse computed value

    if ($isCyclical) {
        # 周期股：CAPE(20) + PE(20)
        if ($null -ne $Analysis.CapeLevel) {
            switch ($Analysis.CapeLevel) {
                "Low"     { $score += 20 }
                "Neutral" { $score += 12 }
                "High"    { $score += 5 }
            }
        }
        if ($null -ne $pe) {
            if ($pe -lt 10) { $score += 20 } elseif ($pe -lt 20) { $score += 14 } elseif ($pe -lt 35) { $score += 8 } elseif ($pe -lt 60) { $score += 3 }
        }
    }
    else {
        # 非周期股：PE(25) + PB(15)，不用CAPE
        if ($null -ne $pe) {
            if ($pe -lt 15) { $score += 25 } elseif ($pe -lt 25) { $score += 18 } elseif ($pe -lt 35) { $score += 10 } elseif ($pe -lt 50) { $score += 4 }
        }
        if ($null -ne $Analysis.PB) {
            $pb = [double]$Analysis.PB
            if ($pb -lt 2) { $score += 15 } elseif ($pb -lt 4) { $score += 10 } elseif ($pb -lt 7) { $score += 5 }
        }

        # ── 相对估值修正：PE 相对行业中位PE（±5分） ──
        if ($null -ne $Analysis.IndustryMedianPE -and [double]$Analysis.IndustryMedianPE -gt 0 -and $null -ne $pe) {
            $relPE = $pe / [double]$Analysis.IndustryMedianPE
            if ($relPE -lt 0.8)     { $score += 5 }
            elseif ($relPE -gt 1.3) { $score -= 3 }
        }
    }

    return [Math]::Min(100, [Math]::Max(0, $score))
}

# ============================================================
# 8. 股票推荐引擎（含缓存分析 + 评分）
# ============================================================
function Get-StockRecommendation {
    param([hashtable]$SectorData, [int]$Top = 10)

    $topSectors = @()
    if ($SectorData.Industries) {
        $topSectors += $SectorData.Industries | Where-Object { $_.ChangePct -gt 0 } | Select-Object -First 5
    }
    if ($SectorData.Concepts) {
        $topSectors += $SectorData.Concepts | Where-Object { $_.ChangePct -gt 0 } | Select-Object -First 5
    }

    if ($topSectors.Count -eq 0) {
        if (-not $Quiet) {
            Write-Host "`n=== 股票推荐 ===" -ForegroundColor Yellow
            Write-Host "  当前无上涨板块，暂无推荐" -ForegroundColor DarkGray
        }
        return @()
    }

    $allRecommendations = @()

    foreach ($sector in $topSectors) {
        $stocks = Get-SectorStocks -SectorCode $sector.Code -Top 30

        $mainBoardStocks = $stocks | Where-Object {
            (Test-MainBoard -Code $_.Code) -and $_.Price -gt 0 -and $_.ChangePct -gt 0
        }

        $topStocks = $mainBoardStocks | Sort-Object -Property ChangePct -Descending | Select-Object -First 3

        foreach ($stock in $topStocks) {
            $allRecommendations += [PSCustomObject]@{
                StockCode    = $stock.Code
                StockName    = $stock.Name
                Price        = $stock.Price
                StockChange  = "$($stock.ChangePct)%"
                ChangePctNum = [double]$stock.ChangePct
                SectorName   = $sector.Name
                SectorType   = $sector.Type
                SectorChange = $sector.Change
                Amount       = Format-Amount -Value $stock.Amount
                PE_TTM       = $stock.PE_TTM
                Score        = 0
            }
        }
    }

    # 去重（同一股票出现在多板块时保留）
    $uniqueRecommendations = $allRecommendations |
        Group-Object -Property StockCode |
        ForEach-Object {
            $_.Group | Sort-Object -Property ChangePctNum -Descending | Select-Object -First 1
        }

    # 拉取分析 + 打分
    if (-not $Quiet) {
        Write-Host "`n  正在分析推荐股 ($($uniqueRecommendations.Count) 只)..." -ForegroundColor DarkGray
    }
    foreach ($rec in $uniqueRecommendations) {
        $recIsCyc = [bool]($script:CyclicalKeywords | Where-Object { $rec.SectorName -match $_ })
        $a = Get-AStockAnalysis -Code $rec.StockCode -IsCyclical $recIsCyc
        $rec | Add-Member -NotePropertyName Analysis -NotePropertyValue $a -Force
        $rec.Score = Get-StockScore -Stock $rec -Analysis $a
    }

    $finalRecs = $uniqueRecommendations | Sort-Object -Property Score -Descending | Select-Object -First $Top

    if (-not $Quiet -and $finalRecs.Count -gt 0) {
        Write-Host "  正在生成日内买点建议 ($($finalRecs.Count) 只)..." -ForegroundColor DarkGray
    }
    foreach ($rec in @($finalRecs)) {
        $timing = Get-EntryTimingAdvice -Code $rec.StockCode
        $rec | Add-Member -NotePropertyName EntryTiming -NotePropertyValue $timing -Force
    }

    if (-not $Quiet) {
        Write-Host "`n=== A股推荐（排除科创板/北交所）===" -ForegroundColor Yellow
        Write-Host "  评分 = 基本面(0-40) + 技术(0-20,当日涨幅) + 估值(0-40,周期股CAPE/非周期PE+PB)  满分100" -ForegroundColor DarkGray
        Write-Host "  默认附带: 日内分时 + 主力资金流买点建议`n" -ForegroundColor DarkGray

        if ($finalRecs.Count -gt 0) {
            $idx = 1
            foreach ($rec in $finalRecs) {
                $exchange   = if ($rec.StockCode -match '^6') { "SH" } else { "SZ" }
                $changeColor = if ($rec.ChangePctNum -gt 0) { "Red" } else { "Green" }
                $scoreColor  = if ($rec.Score -ge 60) { "Green" } elseif ($rec.Score -ge 40) { "Yellow" } else { "DarkGray" }
                $a = $rec.Analysis
                $rev  = if ($a -and $null -ne $a.RevenueYoY)  { "{0:+0.0;-0.0}%" -f [double]$a.RevenueYoY }  else { "--" }
                $prof = if ($a -and $null -ne $a.ProfitYoY)   { "{0:+0.0;-0.0}%" -f [double]$a.ProfitYoY }   else { "--" }
                $pe   = if ($a -and $null -ne $a.PE_TTM)       { "{0:N1}x" -f [double]$a.PE_TTM }             else { "--" }
                $cape = if ($a -and $null -ne $a.CapeLevel)    { $a.CapeLevel }                                else { "--" }

                Write-Host ("  {0,2}. " -f $idx) -NoNewline -ForegroundColor DarkGray
                Write-Host ("{0}" -f $rec.StockName) -NoNewline -ForegroundColor Green
                Write-Host (" ({0}.{1})" -f $exchange, $rec.StockCode) -NoNewline -ForegroundColor DarkGray
                Write-Host (" {0:N2}" -f $rec.Price) -NoNewline -ForegroundColor White
                Write-Host (" {0}" -f $rec.StockChange) -NoNewline -ForegroundColor $changeColor
                Write-Host (" [{0}]" -f $rec.Amount) -NoNewline -ForegroundColor DarkGray
                Write-Host (" 评分:" -f $null) -NoNewline -ForegroundColor DarkGray
                Write-Host ("{0}" -f $rec.Score) -NoNewline -ForegroundColor $scoreColor
                Write-Host (" -> $($rec.SectorType):$($rec.SectorName)") -ForegroundColor Cyan
                $recIsCyclical = $script:CyclicalKeywords | Where-Object { $rec.SectorName -match $_ }
                $valDisplay = if ($recIsCyclical) {
                    "CAPE=" + (if ($a -and $null -ne $a.CapeLevel) { $a.CapeLevel } else { "--" })
                } else {
                    $pbVal = if ($a -and $null -ne $a.PB) { "{0:N1}x" -f [double]$a.PB } else { "--" }
                    "PB=$pbVal"
                }
                Write-Host ("      营收YoY=$rev  净利YoY=$prof  PE=$pe  $valDisplay") -ForegroundColor DarkGray
                if ($rec.EntryTiming) {
                    $timing = $rec.EntryTiming
                    Write-Host ("      买点: {0}" -f $timing.PrimaryWindow) -NoNewline -ForegroundColor Green
                    Write-Host ("  备选: {0}" -f $timing.SecondaryWindow) -NoNewline -ForegroundColor DarkGray
                    Write-Host ("  资金: {0}" -f $timing.FundFlowBias) -ForegroundColor DarkGray
                    Write-Host ("      策略: {0}  原因: {1}" -f $timing.Action, $timing.Reason) -ForegroundColor DarkGray
                }
                $idx++
            }

            Write-Host ""
            Write-Host "  --- 说明 ---" -ForegroundColor DarkGray
            Write-Host "  * 筛选范围: 沪市主板(60xxxx) + 深市主板(000/001/002xxx) + 创业板(300xxx)" -ForegroundColor DarkGray
            Write-Host "  * 已排除: 科创板(688xxx) 北交所(8xxxxx)" -ForegroundColor DarkGray
            Write-Host "  * 推荐逻辑: 热门板块Top5行业+Top5概念 -> 各板块领涨主板股 -> 综合打分排序 -> 给出日内入手时窗" -ForegroundColor DarkGray
        } else {
            Write-Host "  未找到符合条件的主板推荐股票" -ForegroundColor DarkGray
        }
    }

    return $finalRecs
}

# ============================================================
# Main
# ============================================================
if (-not $Quiet) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  A股市场热点分析 & 股票推荐" -ForegroundColor Cyan
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor Cyan
}

$result = @{}

# 舆情评分（在所有 action 下均获取，供输出参考）
$sentiment = $null
try { $sentiment = Get-MarketSentiment } catch {}

if (-not $Quiet -and $sentiment) {
    $sColor = if ($sentiment.SentimentIndex -ge 7) { "Green" } elseif ($sentiment.SentimentIndex -ge 4) { "Yellow" } else { "Red" }
    Write-Host "`n  市场舆情指数: " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0:N1}/10" -f $sentiment.SentimentIndex) -NoNewline -ForegroundColor $sColor
    Write-Host ("  (多头:{0} 空头:{1} 共{2}条)" -f $sentiment.BullCount, $sentiment.BearCount, $sentiment.Total) -ForegroundColor DarkGray
}

switch ($Action) {
    "news" {
        $result.News = Get-LatestNews -Top $TopN
    }
    "sectors" {
        $result.Sectors = Get-HotSectors -Top $TopN
    }
    "recommend" {
        $result.Sectors = Get-HotSectors -Top $TopN
        $result.Recommendations = Get-StockRecommendation -SectorData $result.Sectors -Top $TopN
    }
    "all" {
        $result.News = Get-LatestNews -Top $TopN
        $result.Sectors = Get-HotSectors -Top $TopN
        $result.Recommendations = Get-StockRecommendation -SectorData $result.Sectors -Top $TopN
    }
}

$result.Sentiment = $sentiment

if (-not $Quiet) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  数据来源: 东方财富 / 新浪财经 / 雪球 / 36Kr" -ForegroundColor DarkGray
    Write-Host "  免责声明: 以上内容仅供参考，不构成投资建议" -ForegroundColor Yellow
    Write-Host "  投资有风险，入市需谨慎" -ForegroundColor Yellow
    Write-Host "========================================`n" -ForegroundColor Cyan
}

if ($Quiet) {
    return $result
}
