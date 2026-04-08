<#
.SYNOPSIS
    原子操作：多源财经新闻聚合 (<10s)
.PARAMETER Top
    每个源返回条数（默认15）
.PARAMETER Source
    sina / eastmoney / all（默认 all）
.PARAMETER Quiet
    静默模式
.EXAMPLE
    .\Get-MarketNews.ps1
    .\Get-MarketNews.ps1 -Top 20
    $n = .\Get-MarketNews.ps1 -Quiet
#>
param(
    [int]$Top = 15,
    [ValidateSet("sina","eastmoney","all")]
    [string]$Source = "all",
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

. "$PSScriptRoot\lib\StockApi.ps1"

$news = @()

# ── 新浪财经 ──
if ($Source -in @("sina","all")) {
    try {
        $sinaUrl = "https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&k=&num=$Top&page=1"
        $sinaData = Invoke-StockApi -Uri $sinaUrl -Referer "https://finance.sina.com.cn/"
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
}

# ── 东方财富快讯 ──
if ($Source -in @("eastmoney","all")) {
    try {
        $traceId = [guid]::NewGuid().ToString('N')
        $emUrl = "https://np-listapi.eastmoney.com/comm/web/getNewsByColumns?client=web&biz=web_news_col&column=350&order=1&needInteractData=0&page_index=1&page_size=$Top&req_trace=$traceId"
        $emData = Invoke-StockApi -Uri $emUrl -Referer "https://finance.eastmoney.com/"
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

if (-not $Quiet) {
    Write-Host "`n  === 最新财经要闻 ===" -ForegroundColor Cyan
    if ($news.Count -gt 0) {
        $idx = 1
        foreach ($n in $news | Select-Object -First $Top) {
            $timeStr = if ($n.Time) { "[$($n.Time)]" } else { "" }
            Write-Host ("  {0,2}. " -f $idx) -NoNewline -ForegroundColor DarkGray
            if ($timeStr) { Write-Host "$timeStr " -NoNewline -ForegroundColor DarkGray }
            Write-Host "$($n.Title)" -ForegroundColor White
            $idx++
        }
    } else {
        Write-Host "  (无法获取新闻数据)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

return $news
