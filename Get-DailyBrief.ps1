<#
.SYNOPSIS
    每日早报：一键生成格式化的 A 股早报文本（含市场情绪 + TOP3 推荐 + 热点板块）
.DESCRIPTION
    调用 Get-AlphaSignal.ps1 -Quiet 获取当日分析结果
    输出易读的纯文本早报，可选保存到桌面
.PARAMETER Save
    将早报保存到桌面（文件名: YYYY-MM-DD-A股早报.txt）
.PARAMETER Quiet
    静默模式，仅返回对象，不打印
.PARAMETER Top
    早报中展示的推荐股票数量（默认3）
.EXAMPLE
    .\Get-DailyBrief.ps1
    .\Get-DailyBrief.ps1 -Save
    .\Get-DailyBrief.ps1 -Top 5 -Save
#>
param(
    [switch]$Save,
    [switch]$Quiet,
    [int]$Top = 3
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom

# ── 共享库 ──
$script:ProjectRoot = $PSScriptRoot
. "$PSScriptRoot\lib\SaveRecLog.ps1"

$alphaScript = Join-Path $PSScriptRoot 'Get-AlphaSignal.ps1'
if (-not (Test-Path $alphaScript)) {
    Write-Host "  找不到 Get-AlphaSignal.ps1，请确认脚本目录正确" -ForegroundColor Red
    return
}

if (-not $Quiet) {
    Write-Host ""
    Write-Host "  正在生成今日早报，请稍候（约 3-5 分钟）..." -ForegroundColor DarkGray
}

$data = & $alphaScript -TopN ([Math]::Max($Top, 10)) -Quiet

if (-not $data) {
    Write-Host "  获取数据失败，请检查网络连接" -ForegroundColor Red
    return
}

$today      = Get-Date -Format "yyyy年MM月dd日"
$todayShort = Get-Date -Format "yyyy-MM-dd"
$lines      = [System.Collections.Generic.List[string]]::new()

# ── 情绪标签 ──
$sentIdx = [int][Math]::Round($data.Sentiment.SentimentIndex)
$sentLabel = if ($sentIdx -ge 8) { "极度乐观" }
             elseif ($sentIdx -ge 7) { "偏乐观" }
             elseif ($sentIdx -ge 5) { "中性" }
             elseif ($sentIdx -ge 3) { "偏悲观" }
             else { "极度悲观" }
$sentBar = ("■" * $sentIdx) + ("□" * (10 - $sentIdx))

# ── 信号类型分布 ──
$stocks = @($data.AlphaStocks)
$sigCounts = @{}
foreach ($stk in $stocks) {
    $sig = if ($stk.SignalType) { $stk.SignalType } else { "主题热点" }
    $sigCounts[$sig] = ($sigCounts[$sig] ?? 0) + 1
}
$sigSummary = ($sigCounts.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)只" }) -join "  "

# ── 构建早报文本 ──
$W = 56
$lines.Add("=" * $W)
$lines.Add("  A股早报  $today")
$lines.Add("=" * $W)
$lines.Add("")
$lines.Add("  市场情绪：$sentIdx/10（$sentLabel）")
$lines.Add("  情绪指标：[$sentBar]")
$lines.Add("  多头信号 $($data.Sentiment.BullCount) 条 | 空头信号 $($data.Sentiment.BearCount) 条")
$lines.Add("")

# 今日套点新闻
if ($data.Sentiment.TopBullish -and $data.Sentiment.TopBullish.Count -gt 0) {
    $bull = $data.Sentiment.TopBullish[0]
    $lines.Add("  看多要点：$($bull.Title)")
}
if ($data.Sentiment.TopBearish -and $data.Sentiment.TopBearish.Count -gt 0) {
    $bear = $data.Sentiment.TopBearish[0]
    $lines.Add("  看空要点：$($bear.Title)")
}
$lines.Add("")
$lines.Add(("-" * $W))
$lines.Add("")

# ── 信号分布 ──
if ($sigSummary) {
    $lines.Add("  今日信号分布：$sigSummary")
    $lines.Add("")
}

# ── TOP N 推荐 ──
$lines.Add("  TOP $Top 推荐")
$lines.Add("")

$topStocks = $stocks | Select-Object -First $Top
$rank = 1
foreach ($stk in $topStocks) {
    $sigMark = switch ($stk.SignalType) {
        "价值洼地" { "★" }
        "景气反转" { "▲" }
        default    { "◆" }
    }
    $pegStr    = if ($null -ne $stk.PEG) { "  PEG=$("{0:N2}" -f $stk.PEG)" } else { "" }
    $priceStr  = if ($null -ne $stk.Price) { "{0:N2}" -f [double]$stk.Price } else { "--" }
    $stopStr   = if ($null -ne $stk.StopLoss) { $stk.StopLoss } else { "--" }
    $posStr    = if ($stk.PosSize) { $stk.PosSize } else { "--" }
    $holdStr   = if ($stk.HoldPeriod) { $stk.HoldPeriod } else { "--" }
    $sigType   = if ($stk.SignalType) { $stk.SignalType } else { "主题热点" }

    $lines.Add("  $sigMark $rank. $($stk.Name)（$($stk.Code)）  评分 $($stk.Score)  [$sigType]")
    $lines.Add("     现价:$priceStr 元$pegStr")
    $lines.Add("     止损参考:$stopStr 元  仓位建议:$posStr  预计持有:$holdStr")

    if ($stk.EntryTiming) {
        $t = $stk.EntryTiming
        $lines.Add("     买点:$($t.PrimaryWindow)  操作:$($t.Action)")
        $lines.Add("     $($t.Reason)")
    }
    $lines.Add("")
    $rank++
}

# ── 热点板块 ──
if ($data.HotSectors -and $data.HotSectors.Count -gt 0) {
    $lines.Add(("-" * $W))
    $lines.Add("")
    $topSnamesRaw = $data.HotSectors | Select-Object -First 5 | ForEach-Object {
        if ($_.Name) { $_.Name } elseif ($_.SectorName) { $_.SectorName } else { $null }
    } | Where-Object { $_ }
    $topSnames = $topSnamesRaw -join " / "
    $lines.Add("  热点板块：$topSnames")
    $lines.Add("")
}

# ── 全球信息差 ──
if ($data.GapTrends -and $data.GapTrends.Count -gt 0) {
    $lines.Add(("-" * $W))
    $lines.Add("")
    $lines.Add("  信息差（热搜但未见财经报道）：")
    $top3Gaps = $data.GapTrends | Select-Object -First 3
    foreach ($g in $top3Gaps) {
        $kw = if ($g.Keyword) { $g.Keyword } elseif ($g -is [string]) { $g } else { "$g" }
        $lines.Add("    · $kw")
    }
    $lines.Add("")
}

$lines.Add("=" * $W)
$lines.Add("  * 数据来源: 东方财富/新浪/雪球/36Kr/百度/Google")
$lines.Add("  * 此为量化筛选参考，不构成投资建议")
$lines.Add("=" * $W)

# ── 输出 ──
$text = $lines -join "`n"

if (-not $Quiet) {
    Write-Host ""
    foreach ($line in $lines) {
        # 简单着色：标题行用 Cyan，★/▲ 行用 Yellow/Green，其余 White
        if ($line -match "^={3,}") {
            Write-Host $line -ForegroundColor Cyan
        } elseif ($line -match "^\s+[★▲◆]\s+\d+\.") {
            Write-Host $line -ForegroundColor Yellow
        } elseif ($line -match "^\s+(买点|操作|止损|仓位)") {
            Write-Host $line -ForegroundColor DarkCyan
        } elseif ($line -match "^\s+\*") {
            Write-Host $line -ForegroundColor DarkGray
        } else {
            Write-Host $line -ForegroundColor White
        }
    }
}

if ($Save) {
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $fileName    = "$todayShort-A股早报.txt"
    $filePath    = Join-Path $desktopPath $fileName
    $text | Out-File $filePath -Encoding UTF8 -Force
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  早报已保存至桌面：$fileName" -ForegroundColor Green
    }
}

# ── 保存推荐到 CSV（DailyBrief 本身的 TOP N 作为推荐源记录）──
if ($topStocks -and $topStocks.Count -gt 0) {
    Save-RecommendationLog -Stocks $topStocks -Source "DailyBrief" -SentimentScore $sentIdx
}

$briefObj = [PSCustomObject]@{
    Date       = $todayShort
    Sentiment  = $sentIdx
    SentLabel  = $sentLabel
    TopStocks  = $topStocks
    HotSectors = $data.HotSectors | Select-Object -First 5
    GapTrends  = $data.GapTrends  | Select-Object -First 5
    Text       = $text
}
return $briefObj
