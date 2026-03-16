<#
.SYNOPSIS
    原子操作：获取K线数据 + 计算近一周/近一月涨跌幅 (<2s)
.PARAMETER Code
    股票代码
.PARAMETER Days
    回溯天数（默认45，用于计算月涨跌幅）
.PARAMETER Quiet
    静默模式
.EXAMPLE
    .\Get-StockKline.ps1 -Code 600519
    $k = .\Get-StockKline.ps1 -Code 000001 -Quiet
#>
param(
    [Parameter(Mandatory)] [string]$Code,
    [int]$Days = 45,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

. "$PSScriptRoot\lib\StockApi.ps1"
. "$PSScriptRoot\lib\StockCode.ps1"
. "$PSScriptRoot\lib\Format.ps1"

$id  = Resolve-StockCode -InputCode $Code
$beg = (Get-Date).AddDays(-$Days).ToString("yyyyMMdd")
$end = (Get-Date).ToString("yyyyMMdd")

$url = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=$($id.SecId)&klt=101&fqt=1&beg=$beg&end=$end&lmt=$Days&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57"
$resp = Invoke-StockApi -Uri $url -Referer "https://quote.eastmoney.com/"

if (-not ($resp -and $resp.data -and $resp.data.klines)) {
    if (-not $Quiet) { Write-Warning "无法获取 $Code K线数据" }
    return $null
}

$name   = "$($resp.data.name)"
$klines = @()
foreach ($line in $resp.data.klines) {
    $parts = $line -split ','
    $klines += [PSCustomObject]@{
        Date   = $parts[0]
        Open   = [double]$parts[1]
        Close  = [double]$parts[2]
        High   = [double]$parts[3]
        Low    = [double]$parts[4]
        Volume = [double]$parts[5]
        Amount = [double]$parts[6]
    }
}

$count = $klines.Count
$todayClose = if ($count -gt 0) { $klines[-1].Close } else { $null }

# 近一周涨跌幅（5个交易日前）
$week1Change = $null
if ($count -ge 6) {
    $prev = $klines[$count - 6].Close
    if ($prev -gt 0) { $week1Change = [Math]::Round(($todayClose - $prev) / $prev * 100, 2) }
}

# 近一月涨跌幅（22个交易日前）
$month1Change = $null
if ($count -ge 23) {
    $prev = $klines[$count - 23].Close
    if ($prev -gt 0) { $month1Change = [Math]::Round(($todayClose - $prev) / $prev * 100, 2) }
}

$result = [PSCustomObject]@{
    Code         = $id.Code
    Name         = $name
    Klines       = $klines
    LatestClose  = $todayClose
    Week1Change  = $week1Change
    Month1Change = $month1Change
    TradingDays  = $count
}

if (-not $Quiet) {
    $w1Str = if ($null -ne $week1Change) { Format-Percent $week1Change -WithSign } else { "N/A" }
    $m1Str = if ($null -ne $month1Change) { Format-Percent $month1Change -WithSign } else { "N/A" }
    $w1Clr = if ($week1Change -gt 0) { "Red" } elseif ($week1Change -lt 0) { "Green" } else { "White" }
    $m1Clr = if ($month1Change -gt 0) { "Red" } elseif ($month1Change -lt 0) { "Green" } else { "White" }
    Write-Host ""
    Write-Host "  $name ($($id.Code)) K线 — 最近 $count 个交易日" -ForegroundColor Cyan
    Write-Host "  最新收盘: $todayClose"
    Write-Host "  近一周: " -NoNewline; Write-Host "$w1Str" -ForegroundColor $w1Clr
    Write-Host "  近一月: " -NoNewline; Write-Host "$m1Str" -ForegroundColor $m1Clr
    Write-Host ""
}

return $result
