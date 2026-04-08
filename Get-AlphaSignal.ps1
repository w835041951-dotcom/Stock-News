<#
.SYNOPSIS
    Alpha Signal: 全球热点 × 财经新闻情绪分析 × 信息差 × 基本面优+近期回调 选股（含估值）
.DESCRIPTION
    Stage 1: 聚合全球热搜 + 最新财经新闻（新浪/东财/雪球/36Kr）→ 即时展示
    Stage 2: 多源新闻情绪分析 — 正负面信号计数 → 情绪指数(1-10)
    Stage 3: 信息差分析 — 热搜话题 vs 财经新闻覆盖度
    Stage 4: 热门板块 → 成分股 → 近一周/近一月下跌 → 财报增长筛选
    Stage 5: 三维评分 — 基本面(0-40) + 技术(0-30) + 估值(0-30) = 100分
    Stage 6: 追加估值信息（周期股用CAPE，非周期股用PE/PB）+ 日内买点建议
    每一步结果即时展示，帮助发现"快人一步"的投资机会
.PARAMETER TopN
    最终推荐数量（默认10）
.PARAMETER Quiet
    静默模式，返回对象不输出格式化文本
.PARAMETER IncludeCAPE
    已弃用。候选股默认始终包含估值分析。
.EXAMPLE
    .\Get-AlphaSignal.ps1
    .\Get-AlphaSignal.ps1 -TopN 15
#>
param(
    [int]$TopN = 10,
    [bool]$IncludeCAPE = $true,
    [switch]$Quiet,
    [string]$LogFile = ""
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
if ($LogFile) {
    try { Start-Transcript -Path $LogFile -Force | Out-Null } catch {}
}

# ── 共享库 ──
$script:ProjectRoot = $PSScriptRoot
. "$PSScriptRoot\lib\SaveRecLog.ps1"

# ── 全局常量（所有脚本共享同一份，改行业分类只需改这里）──────
$script:CyclicalKeywords = @(
    '化工','化肥','能源','石油','煤炭','有色','金属','钢铁',
    '矿业','农业','银行','保险','地产','建筑','水泥','航运','航空'
)

# 缓存版本号：修改数据结构后递增，自动使旧缓存失效
$script:CacheVersion = "v4"

# ── 数据质量跟踪 ───────────────────────────────────────────────
$script:DQ = [PSCustomObject]@{
    ApiFailures   = 0   # API 调用失败次数
    CacheHits     = 0   # 缓存命中次数
    DataMissing   = 0   # 数据缺失（null 字段）次数
    StocksSkipped = 0   # 因流动性/数据不足跳过的股票数
}

# ── 并行预取缓存 ──────────────────────────────────────────────
$script:PrefetchedDetail = @{}
$script:PrefetchedCAPE   = @{}

# ── 运行计时器 ────────────────────────────────────────────────
$script:StageTimers = [ordered]@{}
$script:RunStart    = Get-Date
function Start-Stage { param([string]$Name) $script:StageTimers[$Name] = Get-Date }
function End-Stage   { param([string]$Name)
    if ($script:StageTimers.Contains($Name)) {
        $elapsed = ((Get-Date) - $script:StageTimers[$Name]).TotalSeconds
        $script:StageTimers[$Name] = $elapsed
    }
}

# ── Cache helpers ─────────────────────────────────────────────
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
    try {
        $file = Join-Path $script:CacheDir "$Key.json"
        $Value | ConvertTo-Json -Depth 10 -Compress | Out-File $file -Encoding UTF8 -Force
    } catch {}
}

# ── Helpers ──────────────────────────────────────────────────
function Invoke-Api {
    param([string]$Uri, [string]$Referer = "https://quote.eastmoney.com/", [int]$Retries = 2)
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri $Uri -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                "Referer"    = $Referer
            } -TimeoutSec 15
            if ($null -ne $resp) { return $resp }
        } catch {}
        if ($attempt -lt $Retries) { Start-Sleep -Milliseconds (500 * $attempt) }
    }
    return $null
}

function Invoke-XmlApi {
    param([string]$Uri, [int]$Retries = 2)
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 15 -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            }
            if ($resp -and $resp.Content) { return [xml]$resp.Content }
        } catch {}
        if ($attempt -lt $Retries) { Start-Sleep -Milliseconds (500 * $attempt) }
    }
    return $null
}

# CJK-aware string padding
function Get-DisplayWidth {
    param([string]$s)
    $w = 0; foreach ($c in $s.ToCharArray()) { if ([int]$c -gt 0x2E80) { $w += 2 } else { $w += 1 } }; return $w
}
function PadR { param([string]$s, [int]$width); return $s + (" " * [Math]::Max(0, $width - (Get-DisplayWidth $s))) }
function PadL { param([string]$s, [int]$width); return (" " * [Math]::Max(0, $width - (Get-DisplayWidth $s))) + $s }

# ── Market Sentiment ─────────────────────────────────────────
function Get-MarketSentiment {
    $bullKeywords = @('上涨','大涨','创新高','突破','利好','增长','超预期','转型','并购','回升','走强','爆发','提升','翻倍','反弹',
                      '新高','强势','放量','融资','增持','回购','扩张','订单','拿下','中标','获批','批准','首发','IPO','分红','派息',
                      '盈利','录得','大单','大客户','战略合作','合同','进入','加速','腾飞','跨越','成功','领涨')
    $bearKeywords = @('下跌','暴跌','创新低','利空','萎缩','不及预期','亏损','监管','处罚','暴雷','下调','调查','违规','风险','崩盘',
                      '破位','缩量','减持','质押','爆仓','退市','ST','违约','债务','亏损','计提','商誉减值','信用评级',
                      '诉讼','索赔','律师函','警示','问询','冻结','查封','处分','流失','下滑','缩水','腰斩','熔断')

    function Get-HeadlineScore([string]$title) {
        foreach ($kw in $bullKeywords) { if ($title -match [regex]::Escape($kw)) { return 1 } }
        foreach ($kw in $bearKeywords) { if ($title -match [regex]::Escape($kw)) { return -1 } }
        return 0
    }

    $items = [System.Collections.ArrayList]::new()

    # Source 1: 东方财富快讯
    try {
        $traceId = [guid]::NewGuid().ToString('N')
        $emResp = Invoke-Api -Uri "https://np-listapi.eastmoney.com/comm/web/getNewsByColumns?client=web&biz=web_news_col&column=350&order=1&needInteractData=0&page_index=1&page_size=20&req_trace=$traceId" `
                             -Referer "https://finance.eastmoney.com/"
        if ($emResp -and $emResp.data -and $emResp.data.list) {
            foreach ($item in ($emResp.data.list | Select-Object -First 15)) {
                $t = "$($item.title)" -replace '<[^>]+>', '' -replace '&nbsp;', ' '
                if ($t.Trim().Length -gt 4) {
                    [void]$items.Add([PSCustomObject]@{ Title = $t.Trim(); Source = "东财快讯"; Score = Get-HeadlineScore $t })
                }
            }
        }
    } catch {}

    # Source 2: 雪球热帖
    try {
        $xqResp = Invoke-Api -Uri "https://xueqiu.com/statuses/hot/listV2.json?since_id=-1&max_id=-1&count=15&category=-1" `
                             -Referer "https://xueqiu.com/"
        if ($xqResp -and $xqResp.list) {
            foreach ($item in ($xqResp.list | Select-Object -First 12)) {
                $raw = if ($item.title) { "$($item.title)" } elseif ($item.text) { "$($item.text)" } else { "" }
                $t = $raw -replace '<[^>]+>', '' -replace '&[a-z]+;', ' '
                if ($t.Trim().Length -gt 4) {
                    [void]$items.Add([PSCustomObject]@{ Title = $t.Trim().Substring(0, [Math]::Min(60, $t.Trim().Length)); Source = "雪球热帖"; Score = Get-HeadlineScore $t })
                }
            }
        }
    } catch {}

    # Source 3: 36Kr 快讯 (JSON API)
    try {
        $krResp = Invoke-Api -Uri "https://36kr.com/api/newsflash?per_page=12" -Referer "https://36kr.com/"
        if ($krResp -and $krResp.data -and $krResp.data.items) {
            foreach ($item in ($krResp.data.items | Select-Object -First 12)) {
                $t = "$($item.title)" -replace '<[^>]+>', '' -replace '&[a-z]+;', ' '
                if ($t.Trim().Length -gt 4) {
                    [void]$items.Add([PSCustomObject]@{ Title = $t.Trim(); Source = "36Kr"; Score = Get-HeadlineScore $t })
                }
            }
        }
    } catch {}

    # Source 4: 同花顺财经快讯
    try {
        $thsResp = Invoke-Api -Uri "https://news.10jqka.com.cn/tapp/news/push/stock/?page=1&tag=&track=website&pagesize=20" `
                              -Referer "https://www.10jqka.com.cn/"
        if ($thsResp -and $thsResp.data -and $thsResp.data.list) {
            foreach ($item in ($thsResp.data.list | Select-Object -First 12)) {
                $t = "$($item.title)" -replace '<[^>]+>', '' -replace '&[a-z]+;', ' '
                if ($t.Trim().Length -gt 4) {
                    [void]$items.Add([PSCustomObject]@{ Title = $t.Trim().Substring(0, [Math]::Min(80, $t.Trim().Length)); Source = "同花顺"; Score = Get-HeadlineScore $t })
                }
            }
        }
    } catch {}

    if ($items.Count -eq 0) {
        return [PSCustomObject]@{
            SentimentIndex = 5.0; BullCount = 0; BearCount = 0; NeutralCount = 0
            TotalItems = 0; TopBullish = @(); TopBearish = @(); AllItems = @()
        }
    }

    $bullCount = ($items | Where-Object { $_.Score -gt 0 }).Count
    $bearCount = ($items | Where-Object { $_.Score -lt 0 }).Count
    $total = $items.Count
    $rawScore = ($bullCount - $bearCount) / $total
    $index = [Math]::Max(1.0, [Math]::Min(10.0, [Math]::Round(5 + $rawScore * 4, 1)))

    return [PSCustomObject]@{
        SentimentIndex = $index
        BullCount      = $bullCount
        BearCount      = $bearCount
        NeutralCount   = $total - $bullCount - $bearCount
        TotalItems     = $total
        TopBullish     = @($items | Where-Object { $_.Score -gt 0 } | Select-Object -First 3)
        TopBearish     = @($items | Where-Object { $_.Score -lt 0 } | Select-Object -First 3)
        AllItems       = $items.ToArray()
    }
}

function Get-AStockValuation {
    param([string]$Code, [bool]$IsCyclical = $false)

    # Check cache first (valuation is expensive — cache for 4 hours)
    $cacheKey = "val_${script:CacheVersion}_$Code"
    $cached = Get-CachedData -Key $cacheKey -MaxAgeMinutes 240
    if ($cached) { $script:DQ.CacheHits++; return $cached }

    $detailScript = Join-Path $PSScriptRoot 'Get-StockDetail.ps1'
    $v = [ordered]@{
        PE_TTM           = $null
        PB               = $null
        CapeNominal      = $null
        CapeLevel        = $null
        IndustryMedianPE = $null   # 行业中位PE，用于相对估值
        TurnoverRate     = $null   # 换手率，用于流动性过滤
        GrossMarginTrend = $null   # 毛利率趋势: improving/declining/stable
        ROETrend         = $null   # ROE 趋势: improving/declining/stable
    }

    try {
        $d = $null
        if ($script:PrefetchedDetail.ContainsKey($Code)) {
            $d = $script:PrefetchedDetail[$Code]
        } elseif (Test-Path $detailScript) {
            $d = & $detailScript -Code $Code -Action all -Quiet -ErrorAction SilentlyContinue
        }
        if ($d) {
                $v.PE_TTM       = $d.PE_TTM
                $v.PB           = $d.PB
                $v.TurnoverRate = $d.TurnoverRate
                # 行业中位PE（来自 ValuationExtras）
                if ($d.ValuationExtras -and $null -ne $d.ValuationExtras.IndustryStaticPEMedian) {
                    $v.IndustryMedianPE = $d.ValuationExtras.IndustryStaticPEMedian
                }
                # 财报趋势：取最近3季度毛利率和ROE
                if ($d.Reports -and $d.Reports.Count -ge 3) {
                    $gms = @($d.Reports[0..2] | ForEach-Object {
                        if ($null -ne $_.GrossMargin -and "$($_.GrossMargin)" -ne '') { [double]$_.GrossMargin } else { $null }
                    } | Where-Object { $null -ne $_ })
                    if ($gms.Count -ge 2) {
                        if ($gms[0] -gt $gms[-1] + 1) { $v.GrossMarginTrend = "improving" }
                        elseif ($gms[0] -lt $gms[-1] - 1) { $v.GrossMarginTrend = "declining" }
                        else { $v.GrossMarginTrend = "stable" }
                    }
                    $roes = @($d.Reports[0..2] | ForEach-Object {
                        if ($null -ne $_.ROE -and "$($_.ROE)" -ne '') { [double]$_.ROE } else { $null }
                    } | Where-Object { $null -ne $_ })
                    if ($roes.Count -ge 2) {
                        if ($roes[0] -gt $roes[-1] + 1) { $v.ROETrend = "improving" }
                        elseif ($roes[0] -lt $roes[-1] - 1) { $v.ROETrend = "declining" }
                        else { $v.ROETrend = "stable" }
                    }
                }
            } else { $script:DQ.ApiFailures++ }
    }
    catch {}

    # 只有周期股才计算 CAPE（拉10年EPS很慢，非周期股用不到）
    if ($IsCyclical) {
        $capeScript = Join-Path $PSScriptRoot 'Get-CapeValuation.ps1'
        try {
            $c = $null
            if ($script:PrefetchedCAPE.ContainsKey($Code)) {
                $c = $script:PrefetchedCAPE[$Code]
            } elseif (Test-Path $capeScript) {
                $c = & $capeScript -Code $Code -Years 10 -Quiet -ErrorAction SilentlyContinue
            }
            if ($c) {
                $v.CapeNominal = $c.NominalCAPE
                $v.CapeLevel = $c.CapeLevel
            }
        }
        catch {}
    }

    $result = [PSCustomObject]$v
    Set-CachedData -Key $cacheKey -Value $result
    return $result
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

# ── Compute sentiment before banner ──────────────────────────
$sentiment = Get-MarketSentiment

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$W = 70  # display width

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("=" * $W) -ForegroundColor Cyan
    Write-Host "  Alpha Signal — $timestamp" -ForegroundColor White
    Write-Host "  全球热点 × 信息差分析 × 优质回调股" -ForegroundColor DarkGray
    Write-Host ("=" * $W) -ForegroundColor Cyan

    # Sentiment bar
    $sentIdx = [int][Math]::Round($sentiment.SentimentIndex)
    $sentColor = if ($sentIdx -ge 7) { "Red" } elseif ($sentIdx -le 3) { "Green" } else { "Yellow" }
    $sentBar = ("■" * $sentIdx) + ("□" * (10 - $sentIdx))
    Write-Host "  市场情绪指数: $($sentiment.SentimentIndex)/10  [$sentBar]" -ForegroundColor $sentColor
    Write-Host "  多头信号 $($sentiment.BullCount) 条 | 空头信号 $($sentiment.BearCount) 条 | 中性 $($sentiment.NeutralCount) 条" -ForegroundColor DarkGray

    # 今日要点
    if ($sentiment.TopBullish.Count -gt 0 -or $sentiment.TopBearish.Count -gt 0) {
        Write-Host ""
        Write-Host "  今日要点:" -ForegroundColor Yellow
        if ($sentiment.TopBullish.Count -gt 0) {
            Write-Host "    看多: " -NoNewline -ForegroundColor Red
            Write-Host "$($sentiment.TopBullish[0].Title)" -NoNewline -ForegroundColor White
            Write-Host "  [$($sentiment.TopBullish[0].Source)]" -ForegroundColor DarkGray
        }
        if ($sentiment.TopBearish.Count -gt 0) {
            Write-Host "    看空: " -NoNewline -ForegroundColor Green
            Write-Host "$($sentiment.TopBearish[0].Title)" -NoNewline -ForegroundColor White
            Write-Host "  [$($sentiment.TopBearish[0].Source)]" -ForegroundColor DarkGray
        }
    }
}

# ══════════════════════════════════════════════════════════════
# STEP 1: 全球热搜
# ══════════════════════════════════════════════════════════════
Start-Stage "S1_热搜"
$allTrends = @()

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host "  [1/6] 全球热搜" -ForegroundColor Yellow
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
}

# ── Baidu ──
$baidu = Invoke-Api -Uri "https://top.baidu.com/api/board?platform=wise&tab=realtime" -Referer "https://top.baidu.com/"
if ($baidu -and $baidu.data -and $baidu.data.cards) {
    $content = $baidu.data.cards[0].content
    if ($content -and $content.Count -gt 0) {
        $items = $content[0].content
        $rank = 0
        foreach ($item in $items) {
            $rank++; if ($rank -gt 8) { break }
            $tag = ""
            if ($item.isTop) { $tag = "TOP" }
            elseif ($item.hotTag -eq "1") { $tag = "NEW" }
            elseif ($item.hotTag -eq "3") { $tag = "HOT" }
            $allTrends += [PSCustomObject]@{
                Region = "CN"; Source = "百度"; Title = $item.word
                Heat = if ($item.hotScore) { $item.hotScore } else { "" }; Tag = $tag
            }
        }
    }
}

# ── Toutiao ──
$toutiao = Invoke-Api -Uri "https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc" -Referer "https://www.toutiao.com/"
if ($toutiao -and $toutiao.data) {
    $rank = 0
    foreach ($item in $toutiao.data) {
        $rank++; if ($rank -gt 8) { break }
        $tag = ""
        if ($item.Label -eq "new") { $tag = "NEW" }
        elseif ($item.Label -eq "hot") { $tag = "HOT" }
        $allTrends += [PSCustomObject]@{
            Region = "CN"; Source = "头条"; Title = $item.Title
            Heat = if ($item.HotValue) { $item.HotValue } else { "" }; Tag = $tag
        }
    }
}

# ── Google Trends ──
foreach ($geo in @(
    @{Code = "US"; Label = "US"},
    @{Code = "JP"; Label = "JP"},
    @{Code = "DE"; Label = "EU"}
)) {
    $rss = Invoke-XmlApi -Uri "https://trends.google.com/trending/rss?geo=$($geo.Code)"
    if ($rss -and $rss.rss -and $rss.rss.channel -and $rss.rss.channel.item) {
        $rank = 0
        foreach ($item in @($rss.rss.channel.item)) {
            $rank++; if ($rank -gt 5) { break }
            $traffic = ""
            $tNode = $item.GetElementsByTagName("ht:approx_traffic")
            if ($tNode -and $tNode.Count -gt 0) { $traffic = $tNode[0].InnerText }
            $allTrends += [PSCustomObject]@{
                Region = $geo.Label; Source = "Google"; Title = $item.title
                Heat = $traffic; Tag = ""
            }
        }
    }
}

# ── Display trends immediately ──
if (-not $Quiet) {
    $lastSource = ""
    $idx = 0
    foreach ($t in $allTrends) {
        $srcKey = "$($t.Region)|$($t.Source)"
        if ($srcKey -ne $lastSource) {
            $lastSource = $srcKey; $idx = 0
            Write-Host ""
            Write-Host "  [$($t.Region)] $($t.Source)" -ForegroundColor Cyan
        }
        $idx++
        Write-Host "    $idx. $($t.Title)" -NoNewline -ForegroundColor White
        if ($t.Tag) {
            $tagColor = switch ($t.Tag) { "TOP" { "Red" } "HOT" { "Yellow" } "NEW" { "Green" } default { "White" } }
            Write-Host " [$($t.Tag)]" -ForegroundColor $tagColor -NoNewline
        }
        Write-Host ""
    }
    Write-Host ""
    Write-Host "    共 $($allTrends.Count) 条热搜" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════
# STEP 2: 财经新闻（多源）
# ══════════════════════════════════════════════════════════════
End-Stage "S1_热搜"; Start-Stage "S2_新闻"
$allNews = @()

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host "  [2/6] 最新财经新闻（新浪/东财/雪球/36Kr/同花顺）" -ForegroundColor Yellow
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host ""
}

# 新浪财经
$newsResp = Invoke-Api -Uri "https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&k=&num=15&page=1&r=0.1" -Referer "https://finance.sina.com.cn/"
if ($newsResp -and $newsResp.result -and $newsResp.result.data) {
    foreach ($item in $newsResp.result.data) {
        $time = ""
        if ($item.ctime) {
            try { $time = [DateTimeOffset]::FromUnixTimeSeconds([long]$item.ctime).ToLocalTime().ToString("HH:mm") } catch {}
        }
        $title = "$($item.title)" -replace '<[^>]+>', ''
        if ($title.Trim()) {
            $allNews += [PSCustomObject]@{ Title = $title.Trim(); Time = $time; Source = "新浪" }
        }
    }
}

# 追加情绪分析来源的新闻（东财/雪球/36Kr）
foreach ($item in $sentiment.AllItems) {
    if ($item.Title.Trim()) {
        $allNews += [PSCustomObject]@{ Title = $item.Title.Trim(); Time = ""; Source = $item.Source }
    }
}

if (-not $Quiet) {
    $i = 0
    foreach ($n in @($allNews | Select-Object -First 10)) {
        $i++
        $timeStr = if ($n.Time) { "[$($n.Time)] " } else { "" }
        $srcStr  = if ($n.Source) { " ($($n.Source))" } else { "" }
        Write-Host "    $i. $timeStr$($n.Title)$srcStr" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "    共 $($allNews.Count) 条新闻（新浪$(@($allNews | Where-Object Source -eq '新浪').Count) + 其他$(@($allNews | Where-Object Source -ne '新浪').Count)）" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════
# STEP 3: 信息差分析 — 热搜 vs 新闻覆盖度 + 情绪背景
# ══════════════════════════════════════════════════════════════
End-Stage "S2_新闻"; Start-Stage "S3_信息差"

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host "  [3/6] 信息差分析 — 热搜话题 vs 财经新闻" -ForegroundColor Yellow
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host ""
}

# Build a joined news text for keyword matching
$newsJoined = ($allNews | ForEach-Object { $_.Title }) -join " "

# Extract keywords from CN trends and check coverage in news
$cnTrends = @($allTrends | Where-Object { $_.Region -eq "CN" })
$intlTrends = @($allTrends | Where-Object { $_.Region -ne "CN" })

$gapTrends = @()
$coveredTrends = @()

foreach ($t in $cnTrends) {
    $title = $t.Title
    $segs = $title -split '[，、：:！!？?\s""《》\[\]【】（）()]+' | Where-Object { $_.Length -ge 2 }
    $keywords = @($segs | Where-Object { $_.Length -ge 2 -and $_.Length -le 8 })
    $matched = $false
    if ($newsJoined -match [regex]::Escape($title)) {
        $matched = $true
    }
    else {
        foreach ($kw in $keywords) {
            if ($kw.Length -ge 2 -and ($newsJoined -match [regex]::Escape($kw))) {
                $matched = $true; break
            }
        }
    }
    if ($matched) { $coveredTrends += $t } else { $gapTrends += $t }
}

$intlGaps = @($intlTrends)

if (-not $Quiet) {
    if ($gapTrends.Count -gt 0) {
        Write-Host "  信息差（热搜热但财经新闻未报道/少报道）:" -ForegroundColor Red
        Write-Host ""
        $gi = 0
        foreach ($g in $gapTrends) {
            $gi++
            Write-Host "    $gi. " -NoNewline -ForegroundColor Red
            Write-Host "$($g.Title)" -NoNewline -ForegroundColor White
            $tagColor = switch ($g.Tag) { "TOP" { "Red" } "HOT" { "Yellow" } "NEW" { "Green" } default { $null } }
            if ($g.Tag -and $tagColor) { Write-Host " [$($g.Tag)]" -ForegroundColor $tagColor -NoNewline }
            Write-Host "  ($($g.Source))" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "    今日国内热搜均已被财经新闻覆盖" -ForegroundColor DarkGray
    }

    if ($coveredTrends.Count -gt 0) {
        Write-Host ""
        Write-Host "  已报道（新闻已覆盖的热搜）:" -ForegroundColor Green
        Write-Host ""
        $ci = 0
        foreach ($c in $coveredTrends) {
            $ci++
            Write-Host "    $ci. $($c.Title)" -ForegroundColor DarkGray
        }
    }

    if ($intlGaps.Count -gt 0) {
        Write-Host ""
        Write-Host "  国际热搜（国内财经尚未报道）:" -ForegroundColor Cyan
        Write-Host ""
        $ii = 0
        foreach ($ig in $intlGaps) {
            $ii++
            Write-Host "    $ii. " -NoNewline -ForegroundColor Cyan
            Write-Host "$($ig.Title)" -NoNewline -ForegroundColor White
            Write-Host "  ($($ig.Region)/$($ig.Source))" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "    信息差 $($gapTrends.Count) 条 | 已报道 $($coveredTrends.Count) 条 | 国际 $($intlGaps.Count) 条" -ForegroundColor DarkGray

    # 情绪背景
    Write-Host ""
    Write-Host "  情绪背景（情绪指数 $($sentiment.SentimentIndex)/10）:" -ForegroundColor Yellow
    if ($sentiment.TopBearish.Count -gt 0) {
        $i = 0
        foreach ($item in $sentiment.TopBearish) {
            $i++
            Write-Host "    空$i. $($item.Title)" -NoNewline -ForegroundColor DarkGreen
            Write-Host "  [$($item.Source)]" -ForegroundColor DarkGray
        }
    }
    if ($sentiment.TopBullish.Count -gt 0) {
        $i = 0
        foreach ($item in $sentiment.TopBullish) {
            $i++
            Write-Host "    多$i. $($item.Title)" -NoNewline -ForegroundColor DarkRed
            Write-Host "  [$($item.Source)]" -ForegroundColor DarkGray
        }
    }
}

# ══════════════════════════════════════════════════════════════
# STEP 4: 热门板块 → 成分股
# ══════════════════════════════════════════════════════════════
End-Stage "S3_信息差"; Start-Stage "S4_板块"

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host "  [4/6] 热门板块 → 成分股扫描" -ForegroundColor Yellow
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host ""
}

$noisePatterns = @(
    '昨日涨停', '昨日首板', '昨日连板', '今日涨停',
    '百元股', '破净股', '低价股', '高价股', '新股与次新股',
    '融资融券', '股权转让', '含可转债', '基金重仓',
    '社保重仓', 'QFII重仓', '机构重仓', '富时罗素',
    '标普道琼斯', 'MSCI中国', '沪股通', '深股通',
    '送转预期', '举牌', '壳资源', 'ST板块', '预盈预增', '预亏预减'
)

function Get-TopSectors {
    param([string]$FsType, [int]$Count)
    $fs = if ($FsType -eq "industry") { "m:90+t:2" } else { "m:90+t:3" }
    $fetchSize = $Count + 20
    $url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$fetchSize&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=$fs&fields=f2,f3,f4,f12,f14"
    $resp = Invoke-Api -Uri $url
    # 备源：换 ut + fid=f62 资金流排序
    if (-not ($resp -and $resp.data -and $resp.data.diff)) {
        $url2 = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$fetchSize&po=1&np=1&ut=7eea3edcaed734bea9cbfc24409ed989&fltt=2&invt=2&fid=f62&fs=$fs&fields=f2,f3,f4,f12,f14"
        $resp = Invoke-Api -Uri $url2
    }
    $results = @()
    if ($resp -and $resp.data -and $resp.data.diff) {
        foreach ($item in $resp.data.diff) {
            $name = "$($item.f14)"
            $isNoise = $false
            foreach ($p in $noisePatterns) { if ($name -like "*$p*") { $isNoise = $true; break } }
            if ($isNoise) { continue }
            if ([double]$item.f3 -le 0) { continue }
            $results += [PSCustomObject]@{
                Code   = "$($item.f12)"
                Name   = $name
                Change = [Math]::Round([double]$item.f3, 2)
            }
            if ($results.Count -ge $Count) { break }
        }
    }
    return $results
}

# 近5日领涨但今日回调的板块（捕捉热门板块回调抄底机会）
function Get-PullbackSectors {
    param([string]$FsType, [int]$Count = 4)
    $fs = if ($FsType -eq "industry") { "m:90+t:2" } else { "m:90+t:3" }
    # f104=5日涨跌 f3=今日涨跌
    $url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=30&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f104&fs=$fs&fields=f2,f3,f12,f14,f104,f105"
    $resp = Invoke-Api -Uri $url
    $results = @()
    if ($resp -and $resp.data -and $resp.data.diff) {
        foreach ($item in $resp.data.diff) {
            $name = "$($item.f14)"
            $isNoise = $false
            foreach ($p in $noisePatterns) { if ($name -like "*$p*") { $isNoise = $true; break } }
            if ($isNoise) { continue }
            $day5 = 0.0; $today = 0.0
            [void][double]::TryParse("$($item.f104)", [ref]$day5)
            [void][double]::TryParse("$($item.f3)", [ref]$today)
            # 5日涨幅>5%，但今日回调（≤0%）→ 热门板块回调
            if ($day5 -gt 5 -and $today -le 0) {
                $results += [PSCustomObject]@{
                    Code       = "$($item.f12)"
                    Name       = $name
                    Change     = [Math]::Round($today, 2)
                    Day5Change = [Math]::Round($day5, 2)
                    IsPullback = $true
                }
            }
            if ($results.Count -ge $Count) { break }
        }
    }
    return $results
}

function Get-SignalTextCorpus {
    $parts = @()
    foreach ($t in $allTrends) { if ($t.Title) { $parts += "$($t.Title)" } }
    foreach ($n in $allNews) { if ($n.Title) { $parts += "$($n.Title)" } }
    foreach ($s in $sentiment.AllItems) { if ($s.Title) { $parts += "$($s.Title)" } }
    return ($parts -join " ").ToLower()
}

# 非交易时段/板块API失败时，用前面步骤的信号推断热门方向，避免全链路为0
$fallbackThemeDefs = @(
    [PSCustomObject]@{ Name='算力半导体'; Kind='concept'; Pattern='ai|算力|芯片|gpu|英伟达|nvidia|半导体|存储'; Seed=@('603986','603501','002049','002230','600584','600745') },
    [PSCustomObject]@{ Name='机器人自动化'; Kind='concept'; Pattern='机器人|自动化|人形|machine|robot'; Seed=@('000333','002747','002527','000425','002009','601766') },
    [PSCustomObject]@{ Name='电力储能'; Kind='industry'; Pattern='电力|储能|风电|光伏|新能源|绿电|电网'; Seed=@('600900','600886','600011','601985','002074','002460') },
    [PSCustomObject]@{ Name='有色资源'; Kind='industry'; Pattern='黄金|铜|稀土|锂|煤|油气|资源|metal|mining'; Seed=@('601899','600547','000630','603993','601225','600188') },
    [PSCustomObject]@{ Name='军工航天'; Kind='industry'; Pattern='军工|航天|防务|导弹|aerospace|defense'; Seed=@('600893','000768','600760','601989','600150','000738') },
    [PSCustomObject]@{ Name='医药创新'; Kind='industry'; Pattern='医药|创新药|biotech|clinical|药品|医疗|health'; Seed=@('600276','000538','600196','002007','600161','000963') },
    [PSCustomObject]@{ Name='消费复苏'; Kind='industry'; Pattern='消费|白酒|旅游|零售|餐饮|beverage|retail'; Seed=@('600519','000858','000568','601888','600887','603288') },
    [PSCustomObject]@{ Name='云计算数据中心'; Kind='concept'; Pattern='云|云计算|数据中心|服务器|大模型|saas|cloud|cyber'; Seed=@('000977','000063','002410','600588','600845','002065') }
)

$fallbackCodeName = @{
    '603986'='兆易创新'; '603501'='韦尔股份'; '002049'='紫光国微'; '002230'='科大讯飞'; '600584'='长电科技'; '600745'='闻泰科技';
    '000333'='美的集团'; '002747'='埃斯顿'; '002527'='新时达'; '000425'='徐工机械'; '002009'='天奇股份'; '601766'='中国中车';
    '600900'='长江电力'; '600886'='国投电力'; '600011'='华能国际'; '601985'='中国核电'; '002074'='国轩高科'; '002460'='赣锋锂业';
    '601899'='紫金矿业'; '600547'='山东黄金'; '000630'='铜陵有色'; '603993'='洛阳钼业'; '601225'='陕西煤业'; '600188'='兖矿能源';
    '600893'='航发动力'; '000768'='中航西飞'; '600760'='中航沈飞'; '601989'='中国重工'; '600150'='中国船舶'; '000738'='航发控制';
    '600276'='恒瑞医药'; '000538'='云南白药'; '600196'='复星医药'; '002007'='华兰生物'; '600161'='天坛生物'; '000963'='华东医药';
    '600519'='贵州茅台'; '000858'='五粮液'; '000568'='泸州老窖'; '601888'='中国中免'; '600887'='伊利股份'; '603288'='海天味业';
    '000977'='浪潮信息'; '000063'='中兴通讯'; '002410'='广联达'; '600588'='用友网络'; '600845'='宝信软件'; '002065'='东华软件'
}

function Get-PredictedSectors {
    param([string]$Corpus, [int]$Top = 6)

    $ranked = @()
    foreach ($def in $fallbackThemeDefs) {
        $hits = 0
        foreach ($kw in ($def.Pattern -split '\|')) {
            if (-not $kw) { continue }
            if ($Corpus -match [regex]::Escape($kw.ToLower())) { $hits++ }
        }
        if ($hits -gt 0) {
            $ranked += [PSCustomObject]@{
                Code        = ''
                Name        = $def.Name
                Change      = [Math]::Round(0.8 + ($hits * 0.35), 2)
                IsPredicted = $true
                Kind        = $def.Kind
                SeedCodes   = $def.Seed
            }
        }
    }

    if ($ranked.Count -eq 0) {
        foreach ($def in ($fallbackThemeDefs | Select-Object -First 6)) {
            $ranked += [PSCustomObject]@{
                Code        = ''
                Name        = $def.Name
                Change      = 0.9
                IsPredicted = $true
                Kind        = $def.Kind
                SeedCodes   = $def.Seed
            }
        }
    }

    return @($ranked | Sort-Object Change -Descending | Select-Object -First $Top)
}

$hotIndustry = @(Get-TopSectors -FsType "industry" -Count 6)
$hotConcept  = @(Get-TopSectors -FsType "concept" -Count 6)
$usingPredictedSectors = $false

if ($hotIndustry.Count -eq 0 -and $hotConcept.Count -eq 0) {
    $usingPredictedSectors = $true
    $predicted = @(Get-PredictedSectors -Corpus (Get-SignalTextCorpus) -Top 8)
    $hotIndustry = @($predicted | Where-Object { $_.Kind -eq 'industry' } | Select-Object -First 6)
    $hotConcept  = @($predicted | Where-Object { $_.Kind -eq 'concept' } | Select-Object -First 6)
}

# 近5日热门但今日回调的板块（补充扫描池）
$pullbackIndustry = @(Get-PullbackSectors -FsType "industry" -Count 3)
$pullbackConcept  = @(Get-PullbackSectors -FsType "concept" -Count 3)
# 去重：排除已在今日Top中的板块
$topCodes = @(($hotIndustry + $hotConcept) | ForEach-Object { $_.Code })
$pullbackIndustry = @($pullbackIndustry | Where-Object { $_.Code -notin $topCodes })
$pullbackConcept  = @($pullbackConcept  | Where-Object { $_.Code -notin $topCodes })

$allSectors  = @($hotIndustry) + @($hotConcept) + @($pullbackIndustry) + @($pullbackConcept)

# Display sectors immediately
if (-not $Quiet) {
    if ($usingPredictedSectors) {
        Write-Host "  (实时板块接口为空，已切换到非交易时段预测模式)" -ForegroundColor DarkYellow
        Write-Host "" 
    }

    Write-Host "  行业板块 Top 6:" -ForegroundColor Cyan
    foreach ($s in $hotIndustry) {
        if ($s.IsPredicted) {
            $bar = "█" * [Math]::Min(20, [Math]::Max(1, [int]($s.Change * 4)))
            Write-Host "    " -NoNewline
            Write-Host (PadR $s.Name 16) -NoNewline -ForegroundColor White
            Write-Host (PadL "热度$($s.Change)" 10) -NoNewline -ForegroundColor Yellow
            Write-Host "  $bar" -ForegroundColor Yellow
        }
        else {
            $bar = "█" * [Math]::Min(20, [Math]::Max(1, [int]($s.Change * 2)))
            Write-Host "    " -NoNewline
            Write-Host (PadR $s.Name 16) -NoNewline -ForegroundColor White
            Write-Host (PadL "+$($s.Change)%" 8) -NoNewline -ForegroundColor Red
            Write-Host "  $bar" -ForegroundColor Red
        }
    }
    Write-Host ""
    Write-Host "  概念板块 Top 6:" -ForegroundColor Cyan
    foreach ($s in $hotConcept) {
        if ($s.IsPredicted) {
            $bar = "█" * [Math]::Min(20, [Math]::Max(1, [int]($s.Change * 4)))
            Write-Host "    " -NoNewline
            Write-Host (PadR $s.Name 16) -NoNewline -ForegroundColor White
            Write-Host (PadL "热度$($s.Change)" 10) -NoNewline -ForegroundColor Yellow
            Write-Host "  $bar" -ForegroundColor Yellow
        }
        else {
            $bar = "█" * [Math]::Min(20, [Math]::Max(1, [int]($s.Change * 2)))
            Write-Host "    " -NoNewline
            Write-Host (PadR $s.Name 16) -NoNewline -ForegroundColor White
            Write-Host (PadL "+$($s.Change)%" 8) -NoNewline -ForegroundColor Red
            Write-Host "  $bar" -ForegroundColor Red
        }
    }

    # 回调板块显示
    $pbAll = @($pullbackIndustry) + @($pullbackConcept)
    if ($pbAll.Count -gt 0) {
        Write-Host ""
        Write-Host "  近5日热门→今日回调（补充扫描）:" -ForegroundColor Magenta
        foreach ($s in $pbAll) {
            Write-Host "    " -NoNewline
            Write-Host (PadR $s.Name 16) -NoNewline -ForegroundColor White
            Write-Host (PadL "$($s.Change)%" 8) -NoNewline -ForegroundColor Green
            Write-Host "  5日:+$($s.Day5Change)%" -ForegroundColor Yellow
        }
    }
}

# Get component stocks
$stockMap = @{}

foreach ($sector in $allSectors) {
    if ($sector.Code) {
        $url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=20&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=b:$($sector.Code)&fields=f2,f3,f4,f5,f6,f12,f14"
        $resp = Invoke-Api -Uri $url
        if ($resp -and $resp.data -and $resp.data.diff) {
            foreach ($stk in $resp.data.diff) {
                $code = "$($stk.f12)"
                if (-not $code -or $code -eq "-") { continue }
                if ($code -notmatch '^(60[0-9]\d{3}|00[012]\d{3}|300\d{3})$') { continue }
                if (-not $stockMap.ContainsKey($code)) {
                    $rawPrice = $stk.f2; $rawChg = $stk.f3
                    if ($rawPrice -eq '-' -or $null -eq $rawPrice) { continue }
                    $dPrice = 0.0; $dChg = 0.0
                    if (-not [double]::TryParse("$rawPrice", [ref]$dPrice)) { continue }
                    [void][double]::TryParse("$rawChg", [ref]$dChg)
                    $stockMap[$code] = [PSCustomObject]@{
                        Code         = $code
                        Name         = "$($stk.f14)"
                        Price        = [Math]::Round($dPrice, 2)
                        DayChange    = [Math]::Round($dChg, 2)
                        Sectors      = [System.Collections.ArrayList]@($sector.Name)
                        Market       = if ($code -match "^6") { 1 } else { 0 }
                        WeekChg      = $null
                        MonthChg     = $null
                        AboveMA20    = $false
                        BelowMA60    = $false
                        HighVolume   = $false
                        RSI14        = $null
                        RevGrowth    = $null
                        ProfitGrowth = $null
                        ROE          = $null
                        ReportName   = ""
                        Score        = 0
                    }
                }
                else {
                    [void]$stockMap[$code].Sectors.Add($sector.Name)
                }
            }
        }
        continue
    }

    foreach ($seedCode in @($sector.SeedCodes)) {
        $code = "$seedCode"
        if ($code -notmatch '^(60[0-9]\d{3}|00[012]\d{3}|300\d{3})$') { continue }
        if (-not $stockMap.ContainsKey($code)) {
            $stockMap[$code] = [PSCustomObject]@{
                Code         = $code
                Name         = if ($fallbackCodeName.ContainsKey($code)) { $fallbackCodeName[$code] } else { $code }
                Price        = 0
                DayChange    = 0
                Sectors      = [System.Collections.ArrayList]@($sector.Name)
                Market       = if ($code -match "^6") { 1 } else { 0 }
                WeekChg      = $null
                MonthChg     = $null
                AboveMA20    = $false
                BelowMA60    = $false
                HighVolume   = $false
                RSI14        = $null
                RevGrowth    = $null
                ProfitGrowth = $null
                ROE          = $null
                ReportName   = ""
                Score        = 0
            }
        }
        else {
            [void]$stockMap[$code].Sectors.Add($sector.Name)
        }
    }
}

$candidates = @($stockMap.Values)
if (-not $Quiet) {
    Write-Host ""
    Write-Host "    → 共扫描 $($allSectors.Count) 个板块, 获得 $($candidates.Count) 只主板+创业板成分股（去重后）" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════
# STEP 5: K线检查 — 近一周 / 近一月涨跌 + 技术指标
# ══════════════════════════════════════════════════════════════
End-Stage "S4_板块"; Start-Stage "S5_K线"

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host "  [5/6] K线筛选 + 技术指标（MA20/RSI14/量能）" -ForegroundColor Yellow
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host ""
}

$begDate = (Get-Date).AddDays(-55).ToString("yyyyMMdd")
$endDate = (Get-Date).ToString("yyyyMMdd")
$decliners = @()
$momentumCandidates = @()
$processed = 0
$tcKlineHitCount  = 0        # 腾讯主源命中次数
$tcKlineFailCount = 0        # 腾讯连续失败计数

foreach ($stk in $candidates) {
    $processed++
    $secId = "$($stk.Market).$($stk.Code)"
    $kline = $null

    # ── 主源：腾讯 K 线（稳定快速）──
    $tcSym = if ($stk.Market -eq '1') { "sh$($stk.Code)" } else { "sz$($stk.Code)" }
    $tcUrl = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=$tcSym,day,,,50,qfq"
    try {
        $tcResp = Invoke-RestMethod -Uri $tcUrl -TimeoutSec 10 -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = "https://stockapp.finance.qq.com"
        }
        $tcData = $tcResp.data.$tcSym
        $dayKey = if ($tcData.qfqday) { 'qfqday' } elseif ($tcData.day) { 'day' } else { $null }
        if ($dayKey -and $tcData.$dayKey.Count -gt 0) {
            $tcLines = @(foreach ($row in $tcData.$dayKey) {
                "$($row[0]),$($row[1]),$($row[2]),$($row[3]),$($row[4]),$($row[5])"
            })
            $kline = [PSCustomObject]@{
                data = [PSCustomObject]@{
                    klines = $tcLines
                    name   = $stk.Name
                }
            }
            $tcKlineHitCount++
            $tcKlineFailCount = 0
        } else { $tcKlineFailCount++ }
    } catch { $tcKlineFailCount++ }

    # ── 备源：东财 K 线（腾讯失败时兜底，8s超时）──
    if (-not ($kline -and $kline.data -and $kline.data.klines)) {
        $url = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=$secId&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56&klt=101&fqt=0&beg=$begDate&end=$endDate&lmt=45"
        try {
            $kline = Invoke-RestMethod -Uri $url -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                "Referer"    = "https://quote.eastmoney.com/"
            } -TimeoutSec 8
        } catch { $kline = $null }
    }

    if ($kline -and $kline.data -and $kline.data.klines) {
        # seed code 路径名称可能只是代码，用K线API返回的name补全
        if ($kline.data.name -and ($stk.Name -eq $stk.Code -or $stk.Name -match '^\d{6}$')) {
            $stk.Name = "$($kline.data.name)"
        }
        $lines = @($kline.data.klines)
        $count = $lines.Count
        if ($count -ge 2) {
            $lastParts = $lines[$count - 1] -split ","
            $latestClose = [double]$lastParts[2]
            # 盘中K线API可能不含当日bar，用实时价格覆盖以反映最新行情
            if ($stk.Price -gt 0) { $latestClose = $stk.Price }
            # seed code 路径 Price=0 时，用K线收盘价回填
            if ($stk.Price -le 0 -and $latestClose -gt 0) {
                $stk.Price = [Math]::Round($latestClose, 2)
                # 尝试获取日涨跌
                if ($count -ge 2) {
                    $prevClose = [double](($lines[$count - 2] -split ",")[2])
                    if ($prevClose -gt 0) { $stk.DayChange = [Math]::Round(($latestClose - $prevClose) / $prevClose * 100, 2) }
                }
            }

            # Week change (5 trading days back)
            $weekIdx = [Math]::Max(0, $count - 6)
            $weekClose = [double](($lines[$weekIdx] -split ",")[2])
            $weekChg = if ($weekClose -gt 0) { [Math]::Round(($latestClose - $weekClose) / $weekClose * 100, 2) } else { 0 }
            $stk.WeekChg = $weekChg

            # Month change (22 trading days back)
            $monthIdx = [Math]::Max(0, $count - 23)
            $monthClose = [double](($lines[$monthIdx] -split ",")[2])
            $monthChg = if ($monthClose -gt 0) { [Math]::Round(($latestClose - $monthClose) / $monthClose * 100, 2) } else { 0 }
            $stk.MonthChg = $monthChg

            # MA20 — use last 20 closing prices
            if ($count -ge 5) {
                $ma20start = [Math]::Max(0, $count - 20)
                $closeSum = 0.0; $closeN = 0
                for ($ci = $ma20start; $ci -lt $count; $ci++) {
                    $cp = $lines[$ci] -split ","
                    if ($cp.Count -gt 2) { $closeSum += [double]$cp[2]; $closeN++ }
                }
                $ma20 = if ($closeN -gt 0) { $closeSum / $closeN } else { 0 }
                $stk.AboveMA20 = ($ma20 -gt 0 -and $latestClose -gt $ma20)
            }

            # MA60 — 60日均线（用于破位判断）
            if ($count -ge 20) {
                $ma60start = [Math]::Max(0, $count - 60)
                $cSum60 = 0.0; $cN60 = 0
                for ($ci = $ma60start; $ci -lt $count; $ci++) {
                    $cp60 = $lines[$ci] -split ","
                    if ($cp60.Count -gt 2) { $cSum60 += [double]$cp60[2]; $cN60++ }
                }
                $ma60 = if ($cN60 -gt 0) { $cSum60 / $cN60 } else { 0 }
                $stk.BelowMA60 = ($ma60 -gt 0 -and $latestClose -lt $ma60)
            }

            # Volume check: today vs 5-day average
            if ($lastParts.Count -gt 5 -and [double]$lastParts[5] -gt 0) {
                $todayVol = [double]$lastParts[5]
                $volSum = 0.0; $volN = 0
                $vol5start = [Math]::Max(0, $count - 6)
                for ($vi = $vol5start; $vi -lt ($count - 1); $vi++) {
                    $vp = $lines[$vi] -split ","
                    if ($vp.Count -gt 5) { $volSum += [double]$vp[5]; $volN++ }
                }
                $avg5Vol = if ($volN -gt 0) { $volSum / $volN } else { 0 }
                $stk.HighVolume = ($avg5Vol -gt 0 -and $todayVol -gt $avg5Vol * 1.2)
            }

            # RSI-14 approximation
            if ($count -ge 15) {
                $gains = 0.0; $losses = 0.0
                $rsiStart = [Math]::Max(0, $count - 15)
                for ($ri = $rsiStart; $ri -lt ($count - 1); $ri++) {
                    $prev = [double](($lines[$ri] -split ",")[2])
                    $curr = [double](($lines[$ri + 1] -split ",")[2])
                    $diff = $curr - $prev
                    if ($diff -gt 0) { $gains += $diff } else { $losses += [Math]::Abs($diff) }
                }
                $avgGain = $gains / 14.0; $avgLoss = $losses / 14.0
                if ($avgLoss -gt 0) {
                    $rs = $avgGain / $avgLoss
                    $stk.RSI14 = [Math]::Round(100 - 100 / (1 + $rs), 1)
                } else {
                    $stk.RSI14 = 100.0
                }
            }

            # Filter: week decline OR month decline (at low position)
            if ($weekChg -lt 0 -or $monthChg -lt -5) {
                $decliners += $stk
            }

            # Momentum candidate: strong daily surge + volume + trend support
            if ($stk.DayChange -gt 3 -and $stk.AboveMA20 -and $stk.HighVolume -and
                ($null -eq $stk.RSI14 -or $stk.RSI14 -lt 80)) {
                $momentumCandidates += $stk
            }
        }
    }
    if (-not $Quiet -and $processed % 20 -eq 0) {
        $srcTag = if ($tcKlineHitCount -gt 0) { " (腾讯:$tcKlineHitCount)" } else { "" }
        Write-Host "    已检查 $processed / $($candidates.Count) ...$srcTag" -ForegroundColor DarkGray
    }
}

if (-not $Quiet) {
    if ($tcKlineHitCount -gt 0) {
        Write-Host "    [备源统计] 腾讯K线命中 $tcKlineHitCount 只" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "    ── 回调股一览（近周下跌 或 近月跌幅>5%）──" -ForegroundColor Cyan
    Write-Host ""

    $sortedDecliners = @($decliners | Sort-Object -Property WeekChg)

    $hdr = "    " + (PadR "代码" 10) + (PadR "名称" 10) + (PadL "现价" 9) + (PadL "周涨跌" 9) + (PadL "月涨跌" 9) + (PadL "RSI14" 8) + "  板块"
    Write-Host $hdr -ForegroundColor DarkGray
    Write-Host ("    " + ("-" * 68)) -ForegroundColor DarkGray

    foreach ($stk in $sortedDecliners) {
        $sectorStr = ($stk.Sectors | Select-Object -First 2) -join "/"
        $weekStr  = "{0:N2}%" -f $stk.WeekChg
        $monthStr = "{0:N2}%" -f $stk.MonthChg
        $rsiStr   = if ($null -ne $stk.RSI14) { "{0:N1}" -f $stk.RSI14 } else { "N/A" }
        $weekColor = if ($stk.WeekChg -lt 0) { "Green" } else { "Red" }
        $monthColor = if ($stk.MonthChg -lt 0) { "Green" } else { "Red" }
        $volMark = if ($stk.HighVolume) { "[放量]" } else { "" }

        Write-Host "    " -NoNewline
        Write-Host (PadR $stk.Code 10) -NoNewline -ForegroundColor White
        Write-Host (PadR $stk.Name 10) -NoNewline -ForegroundColor White
        Write-Host (PadL ("{0:N2}" -f $stk.Price) 9) -NoNewline -ForegroundColor White
        Write-Host (PadL $weekStr 9) -NoNewline -ForegroundColor $weekColor
        Write-Host (PadL $monthStr 9) -NoNewline -ForegroundColor $monthColor
        Write-Host (PadL $rsiStr 8) -NoNewline -ForegroundColor Yellow
        Write-Host "  $sectorStr $volMark" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "    → $($candidates.Count) 只成分股 → $($decliners.Count) 只处于回调/低位 | $($momentumCandidates.Count) 只强势动量" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════
# STEP 6: 财报增长筛选 + 三维评分
# ══════════════════════════════════════════════════════════════
End-Stage "S5_K线"; Start-Stage "S6_评分"

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host "  [6/6] 财报验证 — 营收&净利同比增长 + 三维评分(含毛利率/RSI/估值)" -ForegroundColor Yellow
    Write-Host ("─" * $W) -ForegroundColor DarkCyan
    Write-Host ""
}

$alphaStocks = @()
$checkedCount = 0

# ── 批量预取财报（1次API取代N次sequential，大幅加速S6） ──
$uncachedCodes = @($decliners | ForEach-Object { $_.Code } | Where-Object {
    -not (Get-CachedData -Key "fin_$_" -MaxAgeMinutes 360)
})
if ($uncachedCodes.Count -gt 0) {
    $codeStr = ($uncachedCodes | ForEach-Object { "`"$_`"" }) -join ','
    $batchUrl = "https://datacenter-web.eastmoney.com/api/data/v1/get?reportName=RPT_LICO_FN_CPD&columns=ALL&filter=(SECURITY_CODE+in+($codeStr))&pageSize=200&sortColumns=REPORT_DATE&sortTypes=-1&source=WEB&client=WEB"
    try {
        $batchResp = Invoke-RestMethod -Uri $batchUrl -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = "https://data.eastmoney.com"
        } -TimeoutSec 20
        if ($batchResp -and $batchResp.result -and $batchResp.result.data) {
            $seen = @{}
            foreach ($row in $batchResp.result.data) {
                $c = $row.SECURITY_CODE
                if (-not $seen[$c]) {
                    $seen[$c] = $true
                    $obj = [PSCustomObject]@{
                        TOTALOPERATEREVETZ = $row.TOTAL_OPERATE_INCOME_YOY
                        PARENTNETPROFITTZ  = $row.PARENT_NETPROFIT_YOY
                        ROEJQ              = $row.ROE_WEIGHT
                        REPORT_DATE_NAME   = $row.REPORT_DATE_NAME
                        XSJLL              = $row.GROSS_PROFIT_RATIO
                        XSMLL              = $row.GROSS_PROFIT_RATIO
                    }
                    Set-CachedData -Key "fin_$c" -Value $obj
                }
            }
            if (-not $Quiet) {
                Write-Host "    [批量财报] 预取 $($seen.Count)/$($uncachedCodes.Count) 只" -ForegroundColor DarkGray
            }
        }
    } catch {
        if (-not $Quiet) {
            Write-Host "    [批量财报] 批量失败，回退逐只查询" -ForegroundColor DarkYellow
        }
    }
}

foreach ($stk in $decliners) {
    $checkedCount++
    $prefix = if ($stk.Code -match "^6") { "SH" } else { "SZ" }

    # Check cache first (batch pre-fetch + prior cache)
    $finCacheKey = "fin_$($stk.Code)"
    $cachedFin = Get-CachedData -Key $finCacheKey -MaxAgeMinutes 360
    $latest = $null

    if ($cachedFin) {
        $latest = $cachedFin
    } else {
        # ── 逐只兜底：datacenter API（批量未命中时） ──
        $dcUrl = "https://datacenter-web.eastmoney.com/api/data/v1/get?reportName=RPT_LICO_FN_CPD&columns=ALL&filter=(SECURITY_CODE=%22$($stk.Code)%22)&pageSize=1&sortColumns=REPORT_DATE&sortTypes=-1&source=WEB&client=WEB"
        try {
            $dcResp = Invoke-RestMethod -Uri $dcUrl -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                "Referer"    = "https://data.eastmoney.com"
            } -TimeoutSec 12
            if ($dcResp -and $dcResp.result -and $dcResp.result.data -and $dcResp.result.data.Count -gt 0) {
                $dcRow = $dcResp.result.data[0]
                $latest = [PSCustomObject]@{
                    TOTALOPERATEREVETZ = $dcRow.TOTAL_OPERATE_INCOME_YOY
                    PARENTNETPROFITTZ  = $dcRow.PARENT_NETPROFIT_YOY
                    ROEJQ              = $dcRow.ROE_WEIGHT
                    REPORT_DATE_NAME   = $dcRow.REPORT_DATE_NAME
                    XSJLL              = $dcRow.GROSS_PROFIT_RATIO
                    XSMLL              = $dcRow.GROSS_PROFIT_RATIO
                }
                Set-CachedData -Key $finCacheKey -Value $latest
            }
        } catch {}

        # ── 备源：东财 emweb ──
        if (-not $latest) {
            $finUrl = "https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/ZYZBAjaxNew?type=0&code=${prefix}$($stk.Code)"
            $finReferer = "https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/Index?type=web&code=${prefix}$($stk.Code)"
            try {
                $fin = Invoke-RestMethod -Uri $finUrl -Headers @{
                    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                    "Referer"    = $finReferer
                    "Accept"     = "application/json, text/plain, */*"
                } -TimeoutSec 10
                if ($fin -and $fin.data -and $fin.data.Count -gt 0) {
                    $latest = $fin.data[0]
                    Set-CachedData -Key $finCacheKey -Value $latest
                }
            } catch {}
        }
    }

    if ($latest) {
        $revG = $latest.TOTALOPERATEREVETZ
        $profG = $latest.PARENTNETPROFITTZ
        $roe = $latest.ROEJQ

        $revGd = 0.0; $profGd = 0.0
        $revOk  = $null -ne $revG  -and [double]::TryParse("$revG",  [ref]$revGd)
        $profOk = $null -ne $profG -and [double]::TryParse("$profG", [ref]$profGd)

        if ($revOk -and $profOk -and $revGd -gt 0 -and $profGd -gt 0) {
            $stk.RevGrowth    = [Math]::Round($revGd, 1)
            $stk.ProfitGrowth = [Math]::Round($profGd, 1)
            $roeD = 0.0
            $stk.ROE          = if ($null -ne $roe -and [double]::TryParse("$roe", [ref]$roeD)) { [Math]::Round($roeD, 1) } else { $null }
            $stk.ReportName   = $latest.REPORT_DATE_NAME

            # ── 三维评分 (满分100) ──

            # 1. 基本面评分 (0-40)
            $fundScore = 0
            if ($stk.RevGrowth -gt 30) { $fundScore += 15 }
            elseif ($stk.RevGrowth -gt 15) { $fundScore += 10 }
            elseif ($stk.RevGrowth -gt 0)  { $fundScore += 5 }

            if ($stk.ProfitGrowth -gt 30) { $fundScore += 15 }
            elseif ($stk.ProfitGrowth -gt 15) { $fundScore += 10 }
            elseif ($stk.ProfitGrowth -gt 0)  { $fundScore += 5 }

            if ($null -ne $stk.ROE) {
                if ($stk.ROE -gt 20) { $fundScore += 10 }
                elseif ($stk.ROE -gt 15) { $fundScore += 7 }
                elseif ($stk.ROE -gt 10) { $fundScore += 4 }
            }

            # 毛利率 bonus (上限40分)
            $grossMargin = $latest.XSMLL
            $gmD = 0.0
            if ($null -ne $grossMargin -and [double]::TryParse("$grossMargin", [ref]$gmD)) {
                $gm = $gmD
                if ($gm -gt 50) { $fundScore += 5 }
                elseif ($gm -gt 30) { $fundScore += 3 }
                elseif ($gm -gt 15) { $fundScore += 1 }
                $fundScore = [Math]::Min(40, $fundScore)
            }

            # 2. 技术评分 (0-30)
            $techScore = 0
            if ($stk.WeekChg -ge -15 -and $stk.WeekChg -le -5) { $techScore += 15 }
            elseif ($stk.WeekChg -gt -5 -and $stk.WeekChg -le 0) { $techScore += 10 }

            if ($stk.MonthChg -ge -25 -and $stk.MonthChg -le -10) { $techScore += 15 }
            elseif ($stk.MonthChg -ge -10 -and $stk.MonthChg -le -5) { $techScore += 10 }

            # RSI oversold bonus (RSI < 35 = good entry point)
            if ($null -ne $stk.RSI14 -and $stk.RSI14 -lt 35) { $techScore += 5 }

            # ── 回测教训：RSI 过热惩罚（追高杀手，比亚迪 RSI=74.6 → 当天-2%） ──
            if ($null -ne $stk.RSI14 -and $stk.RSI14 -gt 70) { $techScore -= 10 }
            if ($null -ne $stk.RSI14 -and $stk.RSI14 -gt 80) { $techScore -= 5 }  # 累计-15

            # ── 回测教训：5日追高惩罚（超声电子 5日+9.43% → 当天-4%） ──
            if ($stk.WeekChg -gt 7)     { $techScore -= 8 }
            elseif ($stk.WeekChg -gt 4) { $techScore -= 4 }

            # ── 破位下跌惩罚：跌破均线说明趋势走坏 ──
            # 注: 双破位(BelowMA60 + !AboveMA20)已在估值阶段硬过滤，此处处理单破位
            if ($stk.BelowMA60) {
                $techScore -= 5   # 仅破MA60 = 中期趋势转弱
            }
            elseif (-not $stk.AboveMA20) {
                $techScore -= 3   # 仅破MA20 = 短期趋势偏弱
            }

            $techScore = [Math]::Max(-10, [Math]::Min(30, $techScore))

            $stk.Score = $fundScore + $techScore  # valuation added after CAPE

            $alphaStocks += $stk

            if (-not $Quiet) {
                Write-Host "    OK $($stk.Code) $($stk.Name) " -NoNewline -ForegroundColor Green
                Write-Host "营收+$($stk.RevGrowth)% 净利+$($stk.ProfitGrowth)%" -NoNewline -ForegroundColor White
                $roeStr = if ($null -ne $stk.ROE) { " ROE=$($stk.ROE)%" } else { "" }
                Write-Host "$roeStr" -ForegroundColor DarkGray
            }
        }
        else {
            if (-not $Quiet) {
                $revStr  = if ($revOk)  { "{0:N1}%" -f $revGd  } else { "N/A" }
                $profStr = if ($profOk) { "{0:N1}%" -f $profGd } else { "N/A" }
                Write-Host "    -- $($stk.Code) $($stk.Name) " -NoNewline -ForegroundColor DarkGray
                Write-Host "营收$revStr 净利$profStr" -ForegroundColor DarkGray
            }
        }
    }
    else {
        if (-not $Quiet) {
            Write-Host "    ??  $($stk.Code) $($stk.Name) 财报数据获取失败" -ForegroundColor DarkGray
        }
    }
}

$alphaStocks = @($alphaStocks | Sort-Object -Property Score -Descending | Select-Object -First $TopN)

# ── 并行预取：一次性启动所有 StockDetail + CAPE 进程 ──
$uncachedCodes = @()
foreach ($stk in $alphaStocks) {
    $cacheKey = "val_${script:CacheVersion}_$($stk.Code)"
    $cached = Get-CachedData -Key $cacheKey -MaxAgeMinutes 240
    if (-not $cached) { $uncachedCodes += $stk }
}

if ($uncachedCodes.Count -gt 0) {
    if (-not $Quiet) {
        Write-Host "  并行预取 $($uncachedCodes.Count) 只股票估值..." -ForegroundColor DarkGray
    }

    # Capture script-scope vars for parallel access
    $localScriptDir    = $PSScriptRoot
    $localCyclicalKWs  = $script:CyclicalKeywords

    # ForEach-Object -Parallel: thread pool, no process startup cost
    $parallelResults = $uncachedCodes | ForEach-Object -Parallel {
        $code      = $_.Code
        $sectors   = $_.Sectors
        $scriptDir = $using:localScriptDir
        $kws       = $using:localCyclicalKWs
        $sectorStr = ($sectors -join ' ')
        $isCyclical = [bool]($kws | Where-Object { $sectorStr -match $_ })

        $r = @{ Code = $code }
        try {
            $d = & "$scriptDir\Get-StockDetail.ps1" -Code $code -Action all -Quiet -ErrorAction SilentlyContinue
            if ($d) { $r['Detail'] = $d }
        } catch {}
        if ($isCyclical) {
            try {
                $c = & "$scriptDir\Get-CapeValuation.ps1" -Code $code -Years 10 -Quiet -ErrorAction SilentlyContinue
                if ($c) { $r['CAPE'] = $c }
            } catch {}
        }
        [PSCustomObject]$r
    } -ThrottleLimit 5 -TimeoutSeconds 90

    # Collect results into prefetch hashtables
    foreach ($r in @($parallelResults)) {
        if ($r.Detail) { $script:PrefetchedDetail[$r.Code] = $r.Detail }
        if ($r.CAPE)   { $script:PrefetchedCAPE[$r.Code]   = $r.CAPE }
    }

    if (-not $Quiet) {
        $okCount = $script:PrefetchedDetail.Count
        Write-Host "  并行预取完成：$okCount/$($uncachedCodes.Count) 成功" -ForegroundColor DarkGray
    }
}

# ── 追加估值 + 估值评分（满分30分） ──
$filteredAlphaStocks = [System.Collections.Generic.List[object]]::new()
foreach ($stk in $alphaStocks) {
    $sectorNames = ($stk.Sectors -join ' ')
    $isCyclical = [bool]($script:CyclicalKeywords | Where-Object { $sectorNames -match $_ })
    $va = Get-AStockValuation -Code $stk.Code -IsCyclical $isCyclical
    $stk | Add-Member -NotePropertyName Valuation -NotePropertyValue $va -Force

    # ── 流动性过滤：换手率 < 0.15% 的股票跳过（真正僵尸股） ──
    if ($va -and $null -ne $va.TurnoverRate -and [double]$va.TurnoverRate -lt 0.15) {
        $script:DQ.StocksSkipped++
        if (-not $Quiet) {
            Write-Host "    [流动性不足] 跳过 $($stk.Code) $($stk.Name) 换手率=$($va.TurnoverRate)%" -ForegroundColor DarkGray
        }
        continue
    }

    # ── 双均线破位硬过滤：同时跌破MA20+MA60 = 趋势彻底走坏，不推荐 ──
    if ($stk.BelowMA60 -and -not $stk.AboveMA20) {
        $script:DQ.StocksSkipped++
        if (-not $Quiet) {
            Write-Host "    [双破位] 跳过 $($stk.Code) $($stk.Name) 跌破MA20+MA60" -ForegroundColor DarkGray
        }
        continue
    }

    # ── 趋势标签（用于输出展示） ──
    $maTag = if ($stk.AboveMA20 -and -not $stk.BelowMA60) { "↑多" }
             elseif ($stk.AboveMA20 -and $stk.BelowMA60)  { "→整" }
             elseif (-not $stk.AboveMA20 -and -not $stk.BelowMA60) { "↓弱" }
             else { "↓破" }
    $stk | Add-Member -NotePropertyName MATag -NotePropertyValue $maTag -Force

    # 3. 估值评分 (0-30)
    # CAPE 仅适用于周期股（化工/能源/有色等），非周期股用 PE_TTM+PB
    $valScore = 0
    $relPE = 1.0  # 相对行业PE比值，默认1（无数据时不调整）
    $pegVal = $null

    if ($va) {
        if ($isCyclical) {
            # 周期股：CAPE 权重高(20分) + PE 补充(10分)
            switch ($va.CapeLevel) {
                "Low"     { $valScore += 20 }
                "Neutral" { $valScore += 12 }
                "High"    { $valScore += 5 }
            }
            if ($null -ne $va.PE_TTM -and [double]$va.PE_TTM -gt 0) {
                $pe = [double]$va.PE_TTM
                if ($pe -lt 10)      { $valScore += 10 }
                elseif ($pe -lt 20)  { $valScore += 7 }
                elseif ($pe -lt 35)  { $valScore += 3 }
            }
        }
        else {
            # 非周期股（消费/医药/科技等）：PE_TTM 为主(25分) + PB 补充(5分)，不用CAPE
            if ($null -ne $va.PE_TTM -and [double]$va.PE_TTM -gt 0) {
                $pe = [double]$va.PE_TTM
                if ($pe -lt 15)      { $valScore += 25 }
                elseif ($pe -lt 25)  { $valScore += 18 }
                elseif ($pe -lt 35)  { $valScore += 10 }
                elseif ($pe -lt 50)  { $valScore += 4 }
            }
            if ($null -ne $va.PB) {
                $pb = [double]$va.PB
                if ($pb -lt 2)       { $valScore += 5 }
                elseif ($pb -lt 4)   { $valScore += 3 }
                elseif ($pb -lt 7)   { $valScore += 1 }
            }
        }

        # ── 回测教训：极端估值惩罚（巨力索具 PE=877 得80分 → 当天-3.7%） ──
        if ($null -ne $va.PE_TTM -and [double]$va.PE_TTM -gt 0) {
            $pe = [double]$va.PE_TTM
            if ($pe -gt 300)     { $valScore -= 15 }  # PE>300 = 纯投机
            elseif ($pe -gt 100) { $valScore -= 10 }  # PE>100 = 极端高估
        }
        # ── 回测教训：极端PB惩罚（昂立教育 PB=21.53 得94分 → 当天-0.6%） ──
        if ($null -ne $va.PB -and [double]$va.PB -gt 10) { $valScore -= 8 }

        # ── 相对估值修正：PE 相对行业中位PE（±7分） ──
        if ($null -ne $va.IndustryMedianPE -and [double]$va.IndustryMedianPE -gt 0 -and $null -ne $va.PE_TTM) {
            $relPE = [double]$va.PE_TTM / [double]$va.IndustryMedianPE
            if ($relPE -lt 0.6)     { $valScore += 7 }   # 比行业便宜40%+
            elseif ($relPE -lt 0.8) { $valScore += 5 }   # 比行业便宜20%+
            elseif ($relPE -lt 0.9) { $valScore += 2 }   # 比行业便宜10%+
            elseif ($relPE -gt 1.3) { $valScore -= 3 }   # 比行业贵30%+
        }

        $valScore = [Math]::Min(30, [Math]::Max(-10, $valScore))
    }

    # ── PEG 加分进入基本面（从 stk.Score 的基本面部分追加） ──
    # 负PE → PEG无意义，必须 PE>0 且 PEG>0 才加分
    if ($null -ne $va -and $null -ne $va.PE_TTM -and [double]$va.PE_TTM -gt 0 -and $null -ne $stk.ProfitGrowth -and [double]$stk.ProfitGrowth -gt 5) {
        $pegVal = [Math]::Round([double]$va.PE_TTM / [double]$stk.ProfitGrowth, 2)
        $pegBonus = 0
        if ($pegVal -le 0)       { $pegBonus = 0 }   # 负PEG = 亏损，不加分
        elseif ($pegVal -lt 0.5) { $pegBonus = 8 }
        elseif ($pegVal -lt 1.0) { $pegBonus = 5 }
        elseif ($pegVal -lt 1.5) { $pegBonus = 2 }
        elseif ($pegVal -gt 3.0) { $pegBonus = -3 }
        $stk.Score = [Math]::Max(0, $stk.Score + $pegBonus)
    }

    # ── 财报趋势奖惩：毛利率持续改善/恶化（±5分到基本面） ──
    if ($va) {
        $trendBonus = 0
        if ($va.GrossMarginTrend -eq "improving") { $trendBonus += 5 }
        elseif ($va.GrossMarginTrend -eq "declining") { $trendBonus -= 3 }
        if ($va.ROETrend -eq "improving") { $trendBonus += 3 }
        elseif ($va.ROETrend -eq "declining") { $trendBonus -= 2 }
        $stk.Score = [Math]::Max(0, $stk.Score + $trendBonus)
    }

    $stk | Add-Member -NotePropertyName IsCyclical -NotePropertyValue ([bool]$isCyclical) -Force
    $stk.Score = [Math]::Min(100, $stk.Score + $valScore)

    # ── 信号类型标注（放宽价值洼地判定：CAPE Low / 相对PE<0.8 / PE<15且盈利 / PB<1.5） ──
    $isValueTrap = ($va -and $va.CapeLevel -eq "Low") -or $relPE -lt 0.8
    if (-not $isValueTrap -and $null -ne $va) {
        $peOK = $null -ne $va.PE_TTM -and [double]$va.PE_TTM -gt 0 -and [double]$va.PE_TTM -lt 15
        $pbOK = $null -ne $va.PB -and [double]$va.PB -gt 0 -and [double]$va.PB -lt 1.5
        if ($peOK -or $pbOK) { $isValueTrap = $true }
    }
    $signalType = if ($isValueTrap) {
        "价值洼地"
    } elseif ($null -ne $stk.ProfitGrowth -and [double]$stk.ProfitGrowth -gt 25 -and
              $null -ne $stk.RevGrowth -and [double]$stk.RevGrowth -gt 25) {
        "景气反转"
    } else {
        "主题热点"
    }

    # ── 信号类型加分/扣分（回测教训：主题热点 24% 胜率 → 扣分） ──
    $signalBonus = switch ($signalType) {
        "价值洼地" { 8 }
        "景气反转" { 5 }
        "主题热点" { -3 }   # 回测胜率仅24%，抑制纯板块跟风
        default    { 0 }
    }
    $stk.Score = [Math]::Min(100, $stk.Score + $signalBonus)

    # ── 回测教训：换手率过高惩罚（巨力索具 换手率18.7% = 投机炒作） ──
    if ($va -and $null -ne $va.TurnoverRate -and [double]$va.TurnoverRate -gt 15) {
        $stk.Score = [Math]::Max(0, $stk.Score - 5)
    }

    # ── 持有时长 + 仓位建议 ──
    $holdPeriod = switch ($signalType) {
        "价值洼地" { "长线 3-6月" }
        "景气反转" { "波段 1-2月" }
        default    { "短线 1-2周" }
    }
    $posSize = if ($stk.Score -ge 75) { "15-20%" }
               elseif ($stk.Score -ge 60) { "10-15%" }
               else { "5-10%" }

    # ── 止损位（当前价 × 0.92，即 -8%） ──
    $stopLoss = if ($null -ne $stk.Price) { [Math]::Round([double]$stk.Price * 0.92, 2) } else { $null }

    $stk | Add-Member -NotePropertyName SignalType  -NotePropertyValue $signalType  -Force
    $stk | Add-Member -NotePropertyName HoldPeriod  -NotePropertyValue $holdPeriod  -Force
    $stk | Add-Member -NotePropertyName PosSize     -NotePropertyValue $posSize     -Force
    $stk | Add-Member -NotePropertyName StopLoss    -NotePropertyValue $stopLoss    -Force
    $stk | Add-Member -NotePropertyName PEG         -NotePropertyValue $pegVal      -Force

    $filteredAlphaStocks.Add($stk)
}
# ── 回测教训：最低分门槛 55（低分股全军覆没：30/39/51 分全跌） ──
$preFilterCount = $filteredAlphaStocks.Count
$filteredAlphaStocks = @($filteredAlphaStocks | Where-Object { $_.Score -ge 55 })
if (-not $Quiet -and $preFilterCount -gt $filteredAlphaStocks.Count) {
    Write-Host "    [低分过滤] 移除 $($preFilterCount - $filteredAlphaStocks.Count) 只低于55分的股票" -ForegroundColor DarkGray
}
$alphaStocks = @($filteredAlphaStocks | Sort-Object -Property Score -Descending | Select-Object -First $TopN)

# Re-sort after final score
$alphaStocks = @($alphaStocks | Sort-Object -Property Score -Descending)

if (-not $Quiet -and $alphaStocks.Count -gt 0) {
    Write-Host ""
    Write-Host "  正在补充日内买点建议..." -ForegroundColor DarkGray
}
foreach ($stk in @($alphaStocks)) {
    $timing = Get-EntryTimingAdvice -Code $stk.Code
    $stk | Add-Member -NotePropertyName EntryTiming -NotePropertyValue $timing -Force
}

# ══════════════════════════════════════════════════════════════
# FINAL OUTPUT
# ══════════════════════════════════════════════════════════════

# ── 回测日志：自动保存推荐记录 ──
Save-RecommendationLog -Stocks $alphaStocks -Source "AlphaSignal" -SentimentScore ([int][Math]::Round($sentiment.SentimentIndex))

# ══════════════════════════════════════════════════════════════
# 短线动量信号 — 评分（独立于基本面，在 Quiet return 之前完成）
# ══════════════════════════════════════════════════════════════
$alphaCodesSet = @{}
foreach ($a in $alphaStocks) { $alphaCodesSet[$a.Code] = $true }
$momentumOnly = @($momentumCandidates | Where-Object { -not $alphaCodesSet.ContainsKey($_.Code) })
$topMomentum = @()

if ($momentumOnly.Count -gt 0) {
    foreach ($stk in $momentumOnly) {
        $mScore = 0

        # 1. 日涨幅 (0-40)
        if ($stk.DayChange -ge 8)      { $mScore += 40 }
        elseif ($stk.DayChange -ge 5)  { $mScore += 30 }
        elseif ($stk.DayChange -ge 3)  { $mScore += 20 }

        # 2. 放量确认 (0-20)
        if ($stk.HighVolume) { $mScore += 20 }

        # 3. 板块热度 (0-25)
        $bestRank = 999
        foreach ($sec in $stk.Sectors) {
            $idx = 0
            foreach ($s in $allSectors) {
                $idx++
                if ($s.Name -eq $sec -and $idx -lt $bestRank) { $bestRank = $idx }
            }
        }
        if ($bestRank -le 3)       { $mScore += 25 }
        elseif ($bestRank -le 5)   { $mScore += 15 }
        elseif ($bestRank -le 8)   { $mScore += 10 }

        # 4. 技术面 (0-15)
        if ($stk.AboveMA20) { $mScore += 5 }
        if ($null -ne $stk.RSI14) {
            if ($stk.RSI14 -ge 40 -and $stk.RSI14 -le 65) { $mScore += 10 }
            elseif ($stk.RSI14 -gt 65 -and $stk.RSI14 -le 75) { $mScore += 5 }
        }

        $stk | Add-Member -NotePropertyName MomentumScore -NotePropertyValue $mScore -Force
        $stk | Add-Member -NotePropertyName Score         -NotePropertyValue $mScore -Force
        $stk | Add-Member -NotePropertyName SignalType    -NotePropertyValue "短线动量"  -Force
        $stk | Add-Member -NotePropertyName HoldPeriod    -NotePropertyValue "短线 1-2周" -Force
        $stk | Add-Member -NotePropertyName PosSize       -NotePropertyValue "5-10%"     -Force
        $stk | Add-Member -NotePropertyName StopLoss      -NotePropertyValue ([Math]::Round([double]$stk.Price * 0.95, 2)) -Force
    }

    $topMomentum = @($momentumOnly | Sort-Object -Property MomentumScore -Descending | Select-Object -First 5)

    # 入手时间
    if (-not $Quiet -and $topMomentum.Count -gt 0) {
        Write-Host ""
        Write-Host "  正在为动量股补充日内买点建议..." -ForegroundColor DarkGray
    }
    foreach ($stk in $topMomentum) {
        $timing = Get-EntryTimingAdvice -Code $stk.Code
        $stk | Add-Member -NotePropertyName EntryTiming -NotePropertyValue $timing -Force
    }

    Save-RecommendationLog -Stocks $topMomentum -Source "Momentum" -SentimentScore ([int][Math]::Round($sentiment.SentimentIndex))
}

if ($Quiet) {
    return [PSCustomObject]@{
        Trends         = $allTrends
        News           = $allNews
        GapTrends      = $gapTrends
        IntlGaps       = $intlGaps
        AlphaStocks    = $alphaStocks
        MomentumStocks = $topMomentum
        HotSectors     = $allSectors
        Decliners      = $decliners
        Sentiment      = $sentiment
    }
}

Write-Host ""
Write-Host ("═" * $W) -ForegroundColor Cyan
Write-Host "  Alpha 候选股 — TOP $TopN" -ForegroundColor Yellow
Write-Host "  条件: 热门板块成分 + 近期回调/低位 + 营收&净利同比增长" -ForegroundColor DarkGray
Write-Host "  默认附带: 日内分时 + 主力资金流买点建议" -ForegroundColor DarkGray
Write-Host ("═" * $W) -ForegroundColor Cyan
Write-Host ""

if ($alphaStocks.Count -gt 0) {
    $hdr = "    " + (PadR "代码" 10) + (PadR "名称" 10) + (PadL "价格" 9) + (PadL "日涨" 8) + (PadL "周涨跌" 9) + (PadL "月涨跌" 9) + (PadL "趋势" 5) + (PadL "营收增长" 10) + (PadL "净利增长" 10) + (PadL "ROE" 8) + (PadL "评分" 8) + (PadL "估值" 8) + (PadL "信号" 8) + "  板块"
    Write-Host $hdr -ForegroundColor Cyan
    Write-Host ("    " + ("-" * 123)) -ForegroundColor DarkGray

    foreach ($stk in $alphaStocks) {
        $sectorStr = ($stk.Sectors | Select-Object -First 2) -join "/"
        if ($stk.Sectors.Count -gt 2) { $sectorStr += "..." }

        $dayStr   = "{0:+0.00;-0.00;0.00}%" -f $stk.DayChange
        $weekStr  = "{0:N2}%" -f $stk.WeekChg
        $monthStr = "{0:N2}%" -f $stk.MonthChg
        $revStr   = "+{0:N1}%" -f $stk.RevGrowth
        $profStr  = "+{0:N1}%" -f $stk.ProfitGrowth
        $roeStr   = if ($null -ne $stk.ROE) { "{0:N1}%" -f $stk.ROE } else { "N/A" }
        $scoreStr = "$($stk.Score)"
        # 周期股显示CAPE，非周期股显示PE/PB
        $valStr   = if ($stk.IsCyclical) {
            if ($stk.Valuation -and $null -ne $stk.Valuation.CapeNominal) { "C:{0:N1}" -f [double]$stk.Valuation.CapeNominal } else { "C:N/A" }
        } else {
            if ($stk.Valuation -and $null -ne $stk.Valuation.PE_TTM) { "P:{0:N1}" -f [double]$stk.Valuation.PE_TTM } else { "P:N/A" }
        }
        $sigStr   = if ($stk.SignalType) { $stk.SignalType } else { "" }
        $priceStr = "{0:N2}" -f $stk.Price
        $dayColor   = if ($stk.DayChange -lt 0) { "Green" } elseif ($stk.DayChange -gt 0) { "Red" } else { "White" }
        $weekColor  = if ($stk.WeekChg -lt 0) { "Green" } else { "Red" }
        $monthColor = if ($stk.MonthChg -lt 0) { "Green" } else { "Red" }
        $scoreColor = if ($stk.Score -ge 70) { "Red" } elseif ($stk.Score -ge 50) { "Yellow" } else { "White" }
        $sigColor   = switch ($stk.SignalType) { "价值洼地" { "Cyan" } "景气反转" { "Green" } default { "Yellow" } }

        Write-Host "    " -NoNewline
        Write-Host (PadR $stk.Code 10) -NoNewline -ForegroundColor White
        Write-Host (PadR $stk.Name 10) -NoNewline -ForegroundColor White
        Write-Host (PadL $priceStr 9) -NoNewline -ForegroundColor White
        Write-Host (PadL $dayStr 8) -NoNewline -ForegroundColor $dayColor
        Write-Host (PadL $weekStr 9) -NoNewline -ForegroundColor $weekColor
        Write-Host (PadL $monthStr 9) -NoNewline -ForegroundColor $monthColor
        $maTagStr = if ($stk.MATag) { $stk.MATag } else { "" }
        $maColor  = switch ($stk.MATag) { "↑多" { "Red" } "→整" { "Yellow" } "↓弱" { "Green" } "↓破" { "DarkGreen" } default { "White" } }
        Write-Host (PadL $maTagStr 5) -NoNewline -ForegroundColor $maColor
        Write-Host (PadL $revStr 10) -NoNewline -ForegroundColor Red
        Write-Host (PadL $profStr 10) -NoNewline -ForegroundColor Red
        Write-Host (PadL $roeStr 8) -NoNewline -ForegroundColor Yellow
        Write-Host (PadL $scoreStr 8) -NoNewline -ForegroundColor $scoreColor
        Write-Host (PadL $valStr 8) -NoNewline -ForegroundColor Cyan
        Write-Host (PadL $sigStr 8) -NoNewline -ForegroundColor $sigColor
        Write-Host "  $sectorStr" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "    报告期: $($alphaStocks[0].ReportName)" -ForegroundColor DarkGray

    Write-Host ""
    Write-Host "  日内入手建议 + 风险管理" -ForegroundColor Yellow
    Write-Host ""
    foreach ($stk in $alphaStocks) {
        $stopStr = if ($null -ne $stk.StopLoss) { "止损参考: $($stk.StopLoss)" } else { "" }
        $posStr  = if ($stk.PosSize) { "仓位: $($stk.PosSize)" } else { "" }
        $holdStr = if ($stk.HoldPeriod) { "持有: $($stk.HoldPeriod)" } else { "" }
        $pegStr  = if ($null -ne $stk.PEG) { " PEG=$("{0:N2}" -f $stk.PEG)" } else { "" }

        if ($stk.EntryTiming) {
            $timing = $stk.EntryTiming
            Write-Host ("    {0} {1}:{2}  [{3}]" -f $stk.Code, $stk.Name, $pegStr, $stk.SignalType) -ForegroundColor Green
            Write-Host ("      买点: {0}  备选: {1}  [{2}]" -f $timing.PrimaryWindow, $timing.SecondaryWindow, $timing.FundFlowBias) -ForegroundColor White
            Write-Host ("      操作: {0}；{1}" -f $timing.Action, $timing.Reason) -ForegroundColor DarkGray
            Write-Host ("      $stopStr  $posStr  $holdStr") -ForegroundColor DarkCyan
        } else {
            Write-Host ("    {0} {1}:{2}  [{3}]  $stopStr  $posStr  $holdStr" -f $stk.Code, $stk.Name, $pegStr, $stk.SignalType) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}
else {
    Write-Host "    今日未找到符合全部条件的股票" -ForegroundColor DarkGray
    Write-Host "    (条件: 热门板块成分 + 近期回调 + 营收&净利同比增长)" -ForegroundColor DarkGray
}

# ── 动量信号输出（评分已在 Quiet return 之前完成）──
if ($topMomentum.Count -gt 0) {
    Write-Host ""
    Write-Host ("═" * $W) -ForegroundColor Magenta
    Write-Host "  短线动量信号 — 板块强势股（非基本面驱动，严控仓位和止损）" -ForegroundColor Magenta
    Write-Host "  条件: 日涨>3% + 放量 + 站上MA20 + RSI<80" -ForegroundColor DarkGray
    Write-Host ("═" * $W) -ForegroundColor Magenta
    Write-Host ""

    $hdr = "    " + (PadR "代码" 10) + (PadR "名称" 10) + (PadL "价格" 9) + (PadL "日涨" 8) + (PadL "周涨跌" 9) + (PadL "月涨跌" 9) + (PadL "RSI14" 8) + (PadL "动量分" 8) + "  板块"
    Write-Host $hdr -ForegroundColor DarkGray
    Write-Host ("    " + ("-" * 80)) -ForegroundColor DarkGray

    foreach ($stk in $topMomentum) {
        $sectorStr = ($stk.Sectors | Select-Object -First 2) -join "/"
        $dayStr   = "+{0:N2}%" -f $stk.DayChange
        $weekStr  = "{0:N2}%" -f $stk.WeekChg
        $monthStr = "{0:N2}%" -f $stk.MonthChg
        $rsiStr   = if ($null -ne $stk.RSI14) { "{0:N1}" -f $stk.RSI14 } else { "N/A" }
        $weekColor  = if ($stk.WeekChg -lt 0) { "Green" } else { "Red" }
        $monthColor = if ($stk.MonthChg -lt 0) { "Green" } else { "Red" }
        $mScoreColor = if ($stk.MomentumScore -ge 70) { "Red" } elseif ($stk.MomentumScore -ge 50) { "Yellow" } else { "White" }

        Write-Host "    " -NoNewline
        Write-Host (PadR $stk.Code 10) -NoNewline -ForegroundColor White
        Write-Host (PadR $stk.Name 10) -NoNewline -ForegroundColor White
        Write-Host (PadL ("{0:N2}" -f $stk.Price) 9) -NoNewline -ForegroundColor White
        Write-Host (PadL $dayStr 8) -NoNewline -ForegroundColor Red
        Write-Host (PadL $weekStr 9) -NoNewline -ForegroundColor $weekColor
        Write-Host (PadL $monthStr 9) -NoNewline -ForegroundColor $monthColor
        Write-Host (PadL $rsiStr 8) -NoNewline -ForegroundColor Yellow
        Write-Host (PadL "$($stk.MomentumScore)" 8) -NoNewline -ForegroundColor $mScoreColor
        Write-Host "  $sectorStr" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  动量入手建议（严控风险：-5%止损）" -ForegroundColor Magenta
    Write-Host ""
    foreach ($stk in $topMomentum) {
        $stopStr = "止损: $($stk.StopLoss)(-5%)"
        $posStr  = "仓位: $($stk.PosSize)"
        $holdStr = "持有: $($stk.HoldPeriod)"

        if ($stk.EntryTiming) {
            $timing = $stk.EntryTiming
            Write-Host ("    {0} {1}  [短线动量]" -f $stk.Code, $stk.Name) -ForegroundColor Magenta
            Write-Host ("      买点: {0}  备选: {1}  [{2}]" -f $timing.PrimaryWindow, $timing.SecondaryWindow, $timing.FundFlowBias) -ForegroundColor White
            Write-Host ("      操作: {0}；{1}" -f $timing.Action, $timing.Reason) -ForegroundColor DarkGray
            Write-Host ("      $stopStr  $posStr  $holdStr") -ForegroundColor DarkCyan
        } else {
            Write-Host ("    {0} {1}  [短线动量]  $stopStr  $posStr  $holdStr" -f $stk.Code, $stk.Name) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}

End-Stage "S6_评分"

# ── Footer ──
Write-Host ""
Write-Host ("─" * $W) -ForegroundColor DarkGray
Write-Host "  筛选漏斗:" -ForegroundColor DarkGray
Write-Host "    热门板块 $($allSectors.Count) → 成分股 $($candidates.Count) → 回调/低位 $($decliners.Count) → 财报增长+≥55分 $($alphaStocks.Count)" -ForegroundColor DarkGray
Write-Host "    动量通道: 日涨>3%+放量+MA20 $($momentumCandidates.Count) → 去重排序 → TOP $($topMomentum.Count)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  情绪指数: $($sentiment.SentimentIndex)/10  多头$($sentiment.BullCount) | 空头$($sentiment.BearCount) | 中性$($sentiment.NeutralCount)" -ForegroundColor DarkGray
Write-Host "  信息差: 未报道 $($gapTrends.Count) 条 | 已报道 $($coveredTrends.Count) 条 | 国际 $($intlGaps.Count) 条" -ForegroundColor DarkGray
Write-Host "  回调条件: 近一周下跌 或 近一月跌幅>5%" -ForegroundColor DarkGray
Write-Host "  评分 = 基本面(0-40,含PEG+趋势) + 技术(-10~30,含RSI过热/追高/破位惩罚) + 估值(-10~30,含极端PE/PB惩罚), 满分100" -ForegroundColor DarkGray
Write-Host "  信号类型: 价值洼地(+8) | 景气反转(+5) | 主题热点(-3); 换手率>15%再-5; 最低55分门槛" -ForegroundColor DarkGray
Write-Host "  止损参考: 当前价×92%；推荐记录已保存至 recommendations-log.csv" -ForegroundColor DarkGray
Write-Host "  动量评分: 日涨(0-40) + 放量(0-20) + 板块热度(0-25) + 技术(0-15), 满分100; 止损×95%(-5%)" -ForegroundColor DarkGray
Write-Host "  买点建议 = 分时相对均价线 + 主力资金分钟级净流向 + 当日阶段节奏" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  * 数据来源: 百度/头条/Google Trends/新浪财经/东方财富/雪球/36Kr/同花顺" -ForegroundColor DarkGray
Write-Host "  * 此为量化筛选参考，不构成投资建议" -ForegroundColor DarkGray
Write-Host ""

# ── 运行诊断 ──
$totalSec = [Math]::Round(((Get-Date) - $script:RunStart).TotalSeconds, 1)
Write-Host ("─" * $W) -ForegroundColor DarkGray
Write-Host "  运行诊断" -ForegroundColor DarkGray
$stageLine = ($script:StageTimers.GetEnumerator() | Where-Object { $_.Value -is [double] } |
              ForEach-Object { "$($_.Key) $([Math]::Round($_.Value,1))s" }) -join "  |  "
if ($stageLine) { Write-Host "    各步耗时: $stageLine" -ForegroundColor DarkGray }
Write-Host "    总耗时: ${totalSec}s  |  缓存命中: $($script:DQ.CacheHits)  |  API失败: $($script:DQ.ApiFailures)  |  跳过股票: $($script:DQ.StocksSkipped)" -ForegroundColor DarkGray
Write-Host ""
if ($LogFile) { try { Stop-Transcript | Out-Null } catch {} }
