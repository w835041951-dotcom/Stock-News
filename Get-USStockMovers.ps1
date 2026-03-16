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

try {
    $resp = Invoke-WebRequest -Uri $url -Headers @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        'Referer'    = 'https://finance.sina.com.cn'
    } -TimeoutSec 15
} catch {
    Write-Host "  [ERROR] 新浪美股接口请求失败: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$lines = $resp.Content -split "`n" | Where-Object { $_ -match 'hq_str' -and $_ -notmatch '=""' }

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
