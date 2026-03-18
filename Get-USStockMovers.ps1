<#
.SYNOPSIS
    原子操作：获取美股热门个股涨跌排行 (<5s)
.PARAMETER Top
    显示涨幅榜前 N 名（默认 15）
.PARAMETER Quiet
    静默模式，仅返回对象
.EXAMPLE
    .\Get-USStockMovers.ps1
    .\Get-USStockMovers.ps1 -Top 20
    $data = .\Get-USStockMovers.ps1 -Quiet
#>
param(
    [int]$Top = 15,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

# --- 热门美股池（科技/AI/消费/金融/能源/军工/中概）---
$stocks = @(
    'AAPL','MSFT','GOOGL','AMZN','NVDA','META','TSLA','AMD','NFLX','AVGO',
    'CRM','ORCL','INTC','QCOM','MU',
    'JPM','GS','BAC','V','MA',
    'XOM','CVX','OXY','SLB','HAL',
    'LMT','RTX','NOC','GD','BA',
    'BABA','JD','PDD','NIO','XPEV','LI'
)

$symbolList = ($stocks | ForEach-Object { "gb_$($_.ToLower())" }) -join ','
$url = "https://hq.sinajs.cn/list=$symbolList"

$resp = $null
for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            'Referer'    = 'https://finance.sina.com.cn'
        } -TimeoutSec 15
        if ($resp -and $resp.Content -and $resp.Content.Length -gt 50) { break }
        $resp = $null
    } catch {
        $resp = $null
    }
    if ($attempt -lt 2) { Start-Sleep -Milliseconds 800 }
}

$lines = @()
if ($resp) {
    $lines = $resp.Content -split "`n" | Where-Object { $_ -match 'hq_str' -and $_ -notmatch '=""' }
}

# 新浪美股格式: 名称,价格,涨跌幅%,时间,涨跌额,开盘,最高,最低,...
$results = @()
$idx = 0
foreach ($line in $lines) {
    if ($line -match '"([^"]+)"') {
        $f = $Matches[1] -split ','
        $sym = $stocks[$idx]
        $price = [double]$f[1]
        if ($price -gt 0) {
            $results += [PSCustomObject]@{
                Symbol    = $sym
                Name      = $f[0]
                Price     = [math]::Round($price, 2)
                Change    = [math]::Round([double]$f[4], 2)
                ChangePct = [math]::Round([double]$f[2], 2)
            }
        }
        $idx++
    }
}

# ── 备源：东方财富美股个股 ──
if ($results.Count -eq 0) {
    # 用东财 secid 105/106 前缀获取美股
    $emMap = @{
        'AAPL'='105.AAPL';  'MSFT'='105.MSFT';  'GOOGL'='105.GOOGL'; 'AMZN'='105.AMZN'
        'NVDA'='105.NVDA';  'META'='105.META';   'TSLA'='105.TSLA';  'AMD'='105.AMD'
        'NFLX'='105.NFLX';  'AVGO'='105.AVGO';   'CRM'='105.CRM';   'ORCL'='105.ORCL'
        'INTC'='105.INTC';  'QCOM'='105.QCOM';   'MU'='105.MU'
        'JPM'='106.JPM';    'GS'='106.GS';       'BAC'='106.BAC';    'V'='106.V';   'MA'='106.MA'
        'XOM'='106.XOM';    'CVX'='106.CVX';      'OXY'='106.OXY';   'SLB'='106.SLB';  'HAL'='106.HAL'
        'LMT'='106.LMT';   'RTX'='106.RTX';      'NOC'='106.NOC';   'GD'='106.GD';    'BA'='106.BA'
        'BABA'='105.BABA';  'JD'='105.JD';        'PDD'='105.PDD';   'NIO'='105.NIO';  'XPEV'='105.XPEV'; 'LI'='105.LI'
    }
    foreach ($sym in $stocks) {
        $secid = $emMap[$sym]
        if (-not $secid) { continue }
        $emUrl = "https://push2.eastmoney.com/api/qt/stock/get?secid=$secid&fields=f43,f57,f58,f169,f170,f60"
        try {
            $emResp = Invoke-RestMethod -Uri $emUrl -TimeoutSec 8 -Headers @{
                "User-Agent" = "Mozilla/5.0"; "Referer" = "https://quote.eastmoney.com/"
            }
            if ($emResp -and $emResp.data -and $emResp.data.f43 -and [double]$emResp.data.f43 -gt 0) {
                $d = $emResp.data
                $results += [PSCustomObject]@{
                    Symbol    = $sym
                    Name      = "$($d.f58)"
                    Price     = [math]::Round([double]$d.f43 / 100, 2)
                    Change    = [math]::Round([double]$d.f169 / 100, 2)
                    ChangePct = [math]::Round([double]$d.f170 / 100, 2)
                }
            }
        } catch {}
    }
    if ($results.Count -gt 0 -and -not $Quiet) {
        Write-Host "  [东财备源]" -ForegroundColor Yellow
    }
}

if ($results.Count -eq 0) {
    Write-Host "  [WARN] 未获取到美股行情数据" -ForegroundColor Yellow
    return
}

$sorted = $results | Sort-Object ChangePct -Descending

if ($Quiet) { return $sorted }

# --- 格式化输出 ---
$gainers = $sorted | Where-Object { $_.ChangePct -gt 0 } | Select-Object -First $Top
$losers  = $sorted | Where-Object { $_.ChangePct -lt 0 } | Sort-Object ChangePct | Select-Object -First 10

Write-Host ""
Write-Host "  === 美股涨幅榜 TOP $Top ===" -ForegroundColor Cyan
Write-Host ""
$rank = 0
foreach ($s in $gainers) {
    $rank++
    Write-Host ("  {0,2}. {1,-6} {2,-16} {3,10:N2}  +{4:N2}%" -f $rank, $s.Symbol, $s.Name, $s.Price, $s.ChangePct) -ForegroundColor Green
}
if ($rank -eq 0) { Write-Host "  (无上涨个股)" }

if ($losers.Count -gt 0) {
    Write-Host ""
    Write-Host "  === 美股跌幅榜 ===" -ForegroundColor Yellow
    Write-Host ""
    $rank = 0
    foreach ($s in $losers) {
        $rank++
        Write-Host ("  {0,2}. {1,-6} {2,-16} {3,10:N2}  {4:N2}%" -f $rank, $s.Symbol, $s.Name, $s.Price, $s.ChangePct) -ForegroundColor Red
    }
}
Write-Host ""
