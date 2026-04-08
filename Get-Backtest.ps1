<#
.SYNOPSIS
    回测查看工具：读取历史推荐记录，追踪每只股票推荐后的实际涨跌表现
.DESCRIPTION
    读取 recommendations-log.csv（由 Get-AlphaSignal.ps1 自动写入）
    通过东方财富历史 K 线 API 获取推荐后 1日/1周 的收盘价
    输出：平均收益率、胜率、各信号类型绩效对比
.PARAMETER Days
    回顾多少天内的推荐记录（默认 30）
.PARAMETER SignalFilter
    按信号类型过滤：价值洼地 / 景气反转 / 主题热点 / （空=全部）
.PARAMETER Quiet
    静默模式，仅返回对象
.EXAMPLE
    .\Get-Backtest.ps1
    .\Get-Backtest.ps1 -Days 60 -SignalFilter 价值洼地
#>
param(
    [int]$Days = 30,
    [string]$SignalFilter = "",
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom

$logFile = Join-Path $PSScriptRoot "recommendations-log.csv"

if (-not (Test-Path $logFile)) {
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  回测数据文件不存在：$logFile" -ForegroundColor Yellow
        Write-Host "  请先运行 .\Get-AlphaSignal.ps1 至少一次，系统将自动开始记录" -ForegroundColor DarkGray
        Write-Host ""
    }
    return $null
}

# ── 读取 CSV ──
$allRows = Import-Csv $logFile -Encoding UTF8
if (-not $allRows -or $allRows.Count -eq 0) {
    if (-not $Quiet) {
        Write-Host "  推荐记录文件为空，暂无数据" -ForegroundColor DarkGray
    }
    return $null
}

$cutoff = (Get-Date).AddDays(-$Days).Date
$rows = $allRows | Where-Object {
    try { [datetime]$_.Date -ge $cutoff } catch { $false }
}

if ($SignalFilter) {
    $rows = $rows | Where-Object { $_.SignalType -eq $SignalFilter }
}

if (-not $rows -or @($rows).Count -eq 0) {
    if (-not $Quiet) {
        Write-Host "  最近 $Days 天内无符合条件的推荐记录" -ForegroundColor DarkGray
    }
    return $null
}

# ── K线 API (东财 + 腾讯备源) ──
function Get-KlineData {
    param([string]$Code, [string]$BegDate, [string]$EndDate, [int]$Lmt = 10)
    $prefix = if ($Code -match '^6') { "1" } else { "0" }
    # 主源：东财
    $url = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=${prefix}.${Code}&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57,f58&klt=101&fqt=1&beg=$BegDate&end=$EndDate&lmt=$Lmt"
    try {
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 10 -Headers @{Referer='https://quote.eastmoney.com/'}
        if ($resp -and $resp.data -and $resp.data.klines -and $resp.data.klines.Count -gt 0) {
            return $resp.data.klines
        }
    } catch {}
    # 备源：腾讯日K
    $tcSym = if ($Code -match '^6') { "sh$Code" } else { "sz$Code" }
    $tcUrl = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=$tcSym,day,,,$Lmt,qfq"
    try {
        $tcResp = Invoke-RestMethod -Uri $tcUrl -TimeoutSec 10 -Headers @{Referer='https://stockapp.finance.qq.com'}
        $tcData = $tcResp.data.$tcSym
        $dayKey = if ($tcData.qfqday) { 'qfqday' } elseif ($tcData.day) { 'day' } else { $null }
        if ($dayKey -and $tcData.$dayKey.Count -gt 0) {
            # 转换腾讯格式为东财逗号字符串格式：日期,开,收,高,低,成交量
            $lines = foreach ($row in $tcData.$dayKey) {
                "$($row[0]),$($row[1]),$($row[2]),$($row[3]),$($row[4]),$($row[5]),0,0,0,0,0"
            }
            # 过滤日期范围
            $beg = $BegDate; $en = $EndDate
            return @($lines | Where-Object { $d = ($_ -split ',')[0] -replace '-',''; $d -ge $beg -and $d -le $en })
        }
    } catch {}
    return $null
}

function Get-ClosePriceOnDate {
    param([string]$Code, [string]$Date)
    $begDate = [datetime]::Parse($Date).ToString("yyyyMMdd")
    $endDate = [datetime]::Parse($Date).AddDays(7).ToString("yyyyMMdd")
    $klines = Get-KlineData -Code $Code -BegDate $begDate -EndDate $endDate -Lmt 10
    if ($klines -and $klines.Count -gt 0) {
        $parts = $klines[0] -split ','
        return [double]$parts[2]
    }
    return $null
}

function Get-ClosePriceAfterDays {
    param([string]$Code, [string]$RecDate, [int]$AfterDays)
    $targetDate = [datetime]::Parse($RecDate).AddDays($AfterDays)
    $begDate = $targetDate.ToString("yyyyMMdd")
    $endDate = $targetDate.AddDays(7).ToString("yyyyMMdd")
    $klines = Get-KlineData -Code $Code -BegDate $begDate -EndDate $endDate -Lmt 10
    if ($klines -and $klines.Count -gt 0) {
        $parts = $klines[0] -split ','
        return [double]$parts[2]
    }
    return $null
}

# ── 计算各记录的绩效 ──
if (-not $Quiet) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    $filterLabel = if ($SignalFilter) { "，筛选: $SignalFilter" } else { "" }
    Write-Host "  推荐回测报告  (最近 $Days 天$filterLabel)" -ForegroundColor Yellow
    Write-Host "  数据来源: $logFile" -ForegroundColor DarkGray
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  正在拉取历史行情数据，请稍候..." -ForegroundColor DarkGray
}

$today = Get-Date
$results = [System.Collections.Generic.List[object]]::new()

foreach ($row in $rows) {
    $recDate  = $row.Date
    $code     = $row.Code
    $recPrice = try { [double]$row.Price } catch { $null }

    if (-not $recPrice -or $recPrice -le 0) { continue }

    # 推荐当天收盘价（验证推荐时价格）
    $closeRec = Get-ClosePriceOnDate -Code $code -Date $recDate

    # 推荐后 1 交易日收盘价
    $close1D  = Get-ClosePriceAfterDays -Code $code -RecDate $recDate -AfterDays 1

    # 推荐后 5 交易日（约1周）收盘价
    $close1W  = Get-ClosePriceAfterDays -Code $code -RecDate $recDate -AfterDays 7

    # 推荐后 20 交易日（约1月）收盘价（仅当推荐日期足够久时才有意义）
    $close1M  = $null
    $daysSinceRec = ($today - [datetime]::Parse($recDate)).Days
    if ($daysSinceRec -ge 25) {
        $close1M = Get-ClosePriceAfterDays -Code $code -RecDate $recDate -AfterDays 21
    }

    $ret1D = if ($close1D -and $recPrice -gt 0) { [Math]::Round(($close1D - $recPrice) / $recPrice * 100, 2) } else { $null }
    $ret1W = if ($close1W -and $recPrice -gt 0) { [Math]::Round(($close1W - $recPrice) / $recPrice * 100, 2) } else { $null }
    $ret1M = if ($close1M -and $recPrice -gt 0) { [Math]::Round(($close1M - $recPrice) / $recPrice * 100, 2) } else { $null }

    $entryScore = try { [int]$row.Score } catch { 0 }
    $entryPEG   = try { [double]$row.PEG } catch { $null }
    $entry = [PSCustomObject]@{
        Date       = $recDate
        Code       = $code
        Name       = $row.Name
        RecPrice   = $recPrice
        Score      = $entryScore
        SignalType = $row.SignalType
        HoldPeriod = $row.HoldPeriod
        PEG        = $entryPEG
        Ret1D      = $ret1D
        Ret1W      = $ret1W
        Ret1M      = $ret1M
        DaysSince  = $daysSinceRec
    }
    $results.Add($entry)
}

if ($results.Count -eq 0) {
    if (-not $Quiet) {
        Write-Host "  没有可计算绩效的记录（可能价格数据无法获取）" -ForegroundColor DarkGray
    }
    return $null
}

if ($Quiet) { return $results }

# ── 输出明细表 ──
Write-Host ""
Write-Host "  推荐明细" -ForegroundColor Yellow
Write-Host ""

$hdr = "  " + "日期".PadRight(12) + "代码".PadRight(10) + "名称".PadRight(12) +
       "评分".PadLeft(6) + "信号".PadLeft(8) + "推荐价".PadLeft(9) +
       "1日%".PadLeft(8) + "1周%".PadLeft(8) + "1月%".PadLeft(8)
Write-Host $hdr -ForegroundColor Cyan
Write-Host ("  " + "-" * 82) -ForegroundColor DarkGray

foreach ($r in $results | Sort-Object Date -Descending) {
    $ret1DStr = if ($null -ne $r.Ret1D) { "{0:+0.00;-0.00}%" -f $r.Ret1D } else { "  N/A" }
    $ret1WStr = if ($null -ne $r.Ret1W) { "{0:+0.00;-0.00}%" -f $r.Ret1W } else { "  N/A" }
    $ret1MStr = if ($null -ne $r.Ret1M) { "{0:+0.00;-0.00}%" -f $r.Ret1M } else { "  N/A" }

    $ret1DColor = if ($null -eq $r.Ret1D) { "DarkGray" } elseif ($r.Ret1D -gt 0) { "Red" } else { "Green" }
    $ret1WColor = if ($null -eq $r.Ret1W) { "DarkGray" } elseif ($r.Ret1W -gt 0) { "Red" } else { "Green" }
    $ret1MColor = if ($null -eq $r.Ret1M) { "DarkGray" } elseif ($r.Ret1M -gt 0) { "Red" } else { "Green" }
    $sigColor   = switch ($r.SignalType) { "价值洼地" { "Cyan" } "景气反转" { "Green" } default { "Yellow" } }

    Write-Host ("  " + $r.Date.PadRight(12) + $r.Code.PadRight(10) + $r.Name.PadRight(12)) -NoNewline -ForegroundColor White
    Write-Host ("$($r.Score)".PadLeft(6)) -NoNewline -ForegroundColor Yellow
    Write-Host ($r.SignalType.PadLeft(8)) -NoNewline -ForegroundColor $sigColor
    Write-Host ("{0:N2}" -f $r.RecPrice).PadLeft(9) -NoNewline -ForegroundColor White
    Write-Host $ret1DStr.PadLeft(8) -NoNewline -ForegroundColor $ret1DColor
    Write-Host $ret1WStr.PadLeft(8) -NoNewline -ForegroundColor $ret1WColor
    Write-Host $ret1MStr.PadLeft(8) -ForegroundColor $ret1MColor
}

# ── 汇总统计 ──
Write-Host ""
Write-Host ("─" * 70) -ForegroundColor DarkGray
Write-Host "  汇总统计" -ForegroundColor Yellow
Write-Host ""

function Show-Summary {
    param([string]$Label, $Items, [string]$Period, $RetField)
    $valid = @($Items | Where-Object { $null -ne $_.$RetField })
    if ($valid.Count -eq 0) { return }
    $wins    = @($valid | Where-Object { $_.$RetField -gt 0 }).Count
    $avg     = [Math]::Round(($valid | Measure-Object -Property $RetField -Average).Average, 2)
    $win_pct = [Math]::Round($wins / $valid.Count * 100, 1)
    $best    = ($valid | Measure-Object -Property $RetField -Maximum).Maximum
    $worst   = ($valid | Measure-Object -Property $RetField -Minimum).Minimum
    $color   = if ($avg -gt 0) { "Red" } else { "Green" }
    Write-Host ("  {0,-10} {1}  样本:{2,3}  均收益:{3:+0.00;-0.00}%  胜率:{4}%  最大:{5:+0.0}%  最小:{6:+0.0}%" `
        -f $Label, $Period, $valid.Count, $avg, $win_pct, $best, $worst) -ForegroundColor $color
}

# 全量
Show-Summary -Label "【全部】" -Items $results -Period "1日" -RetField "Ret1D"
Show-Summary -Label "【全部】" -Items $results -Period "1周" -RetField "Ret1W"
Show-Summary -Label "【全部】" -Items ($results | Where-Object { $null -ne $_.Ret1M }) -Period "1月" -RetField "Ret1M"

# 按信号类型分组
$signals = $results | Select-Object -ExpandProperty SignalType -Unique
foreach ($sig in $signals) {
    if (-not $sig) { continue }
    $subset = @($results | Where-Object { $_.SignalType -eq $sig })
    Write-Host ""
    Show-Summary -Label "[$sig]" -Items $subset -Period "1日" -RetField "Ret1D"
    Show-Summary -Label "[$sig]" -Items $subset -Period "1周" -RetField "Ret1W"
}

Write-Host ""
Write-Host "  * 收益率基于推荐当日价格，不含交易成本" -ForegroundColor DarkGray
Write-Host "  * 胜率=推荐后上涨天数/总样本；N/A=推荐不足1日/1周/1月" -ForegroundColor DarkGray
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host ""

return $results
