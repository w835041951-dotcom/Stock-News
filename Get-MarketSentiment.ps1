<#
.SYNOPSIS
    原子操作：多源新闻情绪分析 → 情绪指数(1-10) (<15s)
.DESCRIPTION
    聚合东财快讯、雪球热帖、36Kr、同花顺，基于多空关键词计数输出情绪指数。
    1(极度悲观) → 5(中性) → 10(极度乐观)
.PARAMETER Quiet
    静默模式
.EXAMPLE
    .\Get-MarketSentiment.ps1
    $s = .\Get-MarketSentiment.ps1 -Quiet
#>
param([switch]$Quiet)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

. "$PSScriptRoot\lib\StockApi.ps1"

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
    $emResp = Invoke-StockApi -Uri "https://np-listapi.eastmoney.com/comm/web/getNewsByColumns?client=web&biz=web_news_col&column=350&order=1&needInteractData=0&page_index=1&page_size=20&req_trace=$traceId" -Referer "https://finance.eastmoney.com/"
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
    $xqResp = Invoke-StockApi -Uri "https://xueqiu.com/statuses/hot/listV2.json?since_id=-1&max_id=-1&count=15&category=-1" -Referer "https://xueqiu.com/"
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

# Source 3: 36Kr 快讯
try {
    $krResp = Invoke-StockApi -Uri "https://36kr.com/api/newsflash?per_page=12" -Referer "https://36kr.com/"
    if ($krResp -and $krResp.data -and $krResp.data.items) {
        foreach ($item in ($krResp.data.items | Select-Object -First 12)) {
            $t = "$($item.title)" -replace '<[^>]+>', '' -replace '&[a-z]+;', ' '
            if ($t.Trim().Length -gt 4) {
                [void]$items.Add([PSCustomObject]@{ Title = $t.Trim(); Source = "36Kr"; Score = Get-HeadlineScore $t })
            }
        }
    }
} catch {}

# Source 4: 同花顺
try {
    $thsResp = Invoke-StockApi -Uri "https://news.10jqka.com.cn/tapp/news/push/stock/?page=1&tag=&track=website&pagesize=20" -Referer "https://www.10jqka.com.cn/"
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
    $result = [PSCustomObject]@{
        SentimentIndex = 5.0; BullCount = 0; BearCount = 0; NeutralCount = 0
        TotalItems = 0; TopBullish = @(); TopBearish = @(); AllItems = @()
    }
} else {
    $bullCount = ($items | Where-Object { $_.Score -gt 0 }).Count
    $bearCount = ($items | Where-Object { $_.Score -lt 0 }).Count
    $total = $items.Count
    $rawScore = ($bullCount - $bearCount) / $total
    $index = [Math]::Max(1.0, [Math]::Min(10.0, [Math]::Round(5 + $rawScore * 4, 1)))

    $result = [PSCustomObject]@{
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

if (-not $Quiet) {
    $idx = [int][Math]::Round($result.SentimentIndex)
    $barFull  = "■" * $idx
    $barEmpty = "□" * (10 - $idx)
    $barClr = if ($idx -ge 7) { "Red" } elseif ($idx -le 3) { "Green" } else { "Yellow" }
    Write-Host ""
    Write-Host "  === 市场情绪指数 ===" -ForegroundColor Cyan
    Write-Host "  [$barFull$barEmpty] " -NoNewline -ForegroundColor $barClr
    Write-Host "$($result.SentimentIndex)/10" -ForegroundColor $barClr
    Write-Host "  多头信号: $($result.BullCount)  空头信号: $($result.BearCount)  中性: $($result.NeutralCount)  (共 $($result.TotalItems) 条)"
    if ($result.TopBullish.Count -gt 0) {
        Write-Host "  最强多头:" -ForegroundColor DarkGray
        foreach ($b in $result.TopBullish) { Write-Host "    + $($b.Title)" -ForegroundColor Red }
    }
    if ($result.TopBearish.Count -gt 0) {
        Write-Host "  最强空头:" -ForegroundColor DarkGray
        foreach ($b in $result.TopBearish) { Write-Host "    - $($b.Title)" -ForegroundColor Green }
    }
    Write-Host ""
}

return $result
