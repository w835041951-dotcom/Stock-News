<#
.SYNOPSIS
    原子操作：获取美股三大指数 + 黄金/白银/原油 实时行情 (<3s)
.PARAMETER Quiet
    静默模式，仅返回对象
.EXAMPLE
    .\Get-USMarketQuote.ps1
    $data = .\Get-USMarketQuote.ps1 -Quiet
#>
param(
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

# --- 新浪财经美股指数 + 期货接口（主源，带重试） ---
$symbols = 'hf_GC,hf_SI,hf_CL,gb_$dji,gb_$ixic,gb_$inx'
$url = "https://hq.sinajs.cn/list=$symbols"
$resp = $null
for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            'Referer'    = 'https://finance.sina.com.cn'
        } -TimeoutSec 15
        if ($resp -and $resp.Content -and $resp.Content.Length -gt 30) { break }
        $resp = $null
    } catch {
        $resp = $null
    }
    if ($attempt -lt 2) { Start-Sleep -Milliseconds 800 }
}

if (-not $resp) {
    # ── 备源：东方财富美股指数 ──
    # 道琼斯=100.DJIA 纳斯达克=100.NDX 标普500=100.SPX
    $emSymbols = @(
        @{ SecId = "100.DJIA";  Name = '道琼斯';  Order = 1 }
        @{ SecId = "100.NDX";   Name = '纳斯达克'; Order = 2 }
        @{ SecId = "100.SPX";   Name = '标普500';  Order = 3 }
    )
    $results = @()
    foreach ($s in $emSymbols) {
        $emUrl = "https://push2.eastmoney.com/api/qt/stock/get?secid=$($s.SecId)&fields=f43,f44,f45,f46,f57,f58,f169,f170,f60"
        try {
            $emResp = Invoke-RestMethod -Uri $emUrl -TimeoutSec 10 -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                "Referer"    = "https://quote.eastmoney.com/"
            }
            if ($emResp -and $emResp.data) {
                $d = $emResp.data
                $price     = [double]$d.f43 / 100
                $prevClose = [double]$d.f60 / 100
                $change    = [double]$d.f169 / 100
                $changePct = [double]$d.f170 / 100
                $results += [PSCustomObject]@{
                    Name      = $s.Name
                    Symbol    = $s.SecId
                    Price     = [math]::Round($price, 2)
                    Change    = [math]::Round($change, 2)
                    ChangePct = [math]::Round($changePct, 2)
                    DayHigh   = [math]::Round([double]$d.f44 / 100, 2)
                    DayLow    = [math]::Round([double]$d.f45 / 100, 2)
                    PrevClose = [math]::Round($prevClose, 2)
                    Order     = $s.Order
                }
            }
        } catch {}
    }

    # 黄金白银原油暂无东财备源，标注来源
    if ($results.Count -gt 0) {
        if (-not $Quiet) { Write-Host "  [东财备源] 仅指数数据，大宗商品跳过" -ForegroundColor Yellow }
        if ($Quiet) { return $results }

        Write-Host ""
        Write-Host "  === 美股指数 (东财备源) ===" -ForegroundColor Cyan
        Write-Host ""
        foreach ($r in $results | Sort-Object Order) {
            $sign  = if ($r.Change -ge 0) { '+' } else { '' }
            $color = if ($r.Change -ge 0) { 'Green' } else { 'Red' }
            $priceStr  = '{0,12:N2}' -f $r.Price
            $changeStr = '{0}{1:N2}' -f $sign, $r.Change
            $pctStr    = '{0}{1:N2}%' -f $sign, $r.ChangePct
            Write-Host ("  {0,-10} " -f $r.Name) -NoNewline
            Write-Host $priceStr -ForegroundColor $color -NoNewline
            Write-Host ("  {0,10}  {1,8}" -f $changeStr, $pctStr) -ForegroundColor $color
        }
        Write-Host ""
        return
    }

    Write-Host "  [ERROR] 美股行情获取失败（新浪+东财均失败）" -ForegroundColor Red
    return
}

$lines = $resp.Content -split "`n" | Where-Object { $_ -match 'hq_str' }

$nameMap = @{
    'hf_GC'   = 'COMEX黄金'
    'hf_SI'   = 'COMEX白银'
    'hf_CL'   = 'WTI原油'
    'gb_$dji' = '道琼斯'
    'gb_$ixic'= '纳斯达克'
    'gb_$inx' = '标普500'
}

$orderMap = @{ 'gb_$dji'=1; 'gb_$ixic'=2; 'gb_$inx'=3; 'hf_GC'=4; 'hf_SI'=5; 'hf_CL'=6 }

$results = @()
foreach ($line in $lines) {
    if ($line -match 'hq_str_(\S+)="([^"]*)"') {
        $sym = $Matches[1]
        $data = $Matches[2]
        if (-not $data) { continue }
        $name = if ($nameMap[$sym]) { $nameMap[$sym] } else { $sym }
        $fields = $data -split ','

        if ($sym -match '^hf_') {
            # 期货格式: 当前价,买价,卖价,最高,最低,昨收,开盘,...
            $price     = [double]$fields[0]
            $prevClose = [double]$fields[5]
            $high      = [double]$fields[3]
            $low       = [double]$fields[4]
            $change    = $price - $prevClose
            $changePct = if ($prevClose -ne 0) { ($change / $prevClose) * 100 } else { 0 }
        } else {
            # 美股指数格式: 名称,当前价,涨跌点,涨跌幅%,最高,最低,开盘,昨收...
            $price     = [double]$fields[1]
            $change    = [double]$fields[2]
            $changePct = [double]($fields[3] -replace '%','')
            $high      = [double]$fields[4]
            $low       = [double]$fields[5]
            $prevClose = [double]$fields[7]
        }

        $results += [PSCustomObject]@{
            Name      = $name
            Symbol    = $sym
            Price     = [math]::Round($price, 2)
            Change    = [math]::Round($change, 2)
            ChangePct = [math]::Round($changePct, 2)
            DayHigh   = [math]::Round($high, 2)
            DayLow    = [math]::Round($low, 2)
            PrevClose = [math]::Round($prevClose, 2)
            Order     = if ($orderMap[$sym]) { $orderMap[$sym] } else { 99 }
        }
    }
}

$results = $results | Sort-Object Order

if ($Quiet) { return $results }

# --- 格式化输出 ---
Write-Host ""
Write-Host "  === 美股指数 & 大宗商品 实时行情 ===" -ForegroundColor Cyan
Write-Host ""

$lastCategory = ''
foreach ($r in $results) {
    $category = if ($r.Symbol -match '^gb_') { 'index' } else { 'commodity' }
    if ($category -ne $lastCategory -and $lastCategory -ne '') {
        Write-Host "  --------------------------------"
    }
    $lastCategory = $category

    $sign  = if ($r.Change -ge 0) { '+' } else { '' }
    $color = if ($r.Change -ge 0) { 'Green' } else { 'Red' }

    $priceStr  = '{0,12:N2}' -f $r.Price
    $changeStr = '{0}{1:N2}' -f $sign, $r.Change
    $pctStr    = '{0}{1:N2}%' -f $sign, $r.ChangePct
    $rangeStr  = "({0:N2} ~ {1:N2})" -f $r.DayLow, $r.DayHigh

    Write-Host ("  {0,-10} " -f $r.Name) -NoNewline
    Write-Host $priceStr -ForegroundColor $color -NoNewline
    Write-Host ("  {0,10}  {1,8}  " -f $changeStr, $pctStr) -ForegroundColor $color -NoNewline
    Write-Host $rangeStr
}
Write-Host ""
