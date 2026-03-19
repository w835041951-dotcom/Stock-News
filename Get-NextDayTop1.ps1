<#
.SYNOPSIS
    下一交易日 TOP1 低开高走预测 — 每小时更新
.DESCRIPTION
    每小时收集新闻/美股/板块数据，预测次日最可能低开高走(收盘≥+5%)的一只股票。
    低开高走 = 跳空低开 → 日内反转 → 收盘涨幅≥5%
.PARAMETER Action
    run: 单次扫描  monitor: 每小时循环
.PARAMETER TopSectors
    扫描热门板块数量（默认8）
.PARAMETER Quiet
    静默模式
.EXAMPLE
    .\Get-NextDayTop1.ps1
    .\Get-NextDayTop1.ps1 -Action monitor
    $pick = .\Get-NextDayTop1.ps1 -Quiet
#>
param(
    [ValidateSet("run","monitor")]
    [string]$Action = "run",
    [int]$TopSectors = 8,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

. "$PSScriptRoot\lib\StockApi.ps1"
. "$PSScriptRoot\lib\StockCode.ps1"
. "$PSScriptRoot\lib\Format.ps1"

$LogFile   = Join-Path $PSScriptRoot "next-day-top1-log.csv"
$StateFile = Join-Path $PSScriptRoot "next-day-top1.json"

# ── 噪音板块 ─────────────────────────────────────────────────
$noisePatterns = @(
    '昨日涨停','昨日首板','昨日连板','百元股','破净股','低价股','新股与次新股',
    '融资融券','股权转让','ST板块','B股','基金重仓','社保重仓','QFII重仓',
    '机构重仓','富时罗素','标普道琼斯','MSCI中国','沪股通','深股通',
    '送转预期','举牌','壳资源','预盈预增','预亏预减'
)

# ── 科技板块关键词 ─────────────────────────────────────────────
$techPattern = '通信|芯片|半导体|集成电路|软件|互联网|计算机|电子|光伏|数字|人工智能|云计算|IT|游戏|传媒|印制电路|元件|AI|算力|存储|光|CPO|服务器|数据中心|IDC|5G|6G|卫星|物联网|智能驾驶|机器人'

# ══════════════════════════════════════════════════════════════
#  时间上下文
# ══════════════════════════════════════════════════════════════
function Get-MarketContext {
    $now   = Get-Date
    $hour  = $now.Hour
    $min   = $now.Minute
    $dow   = $now.DayOfWeek

    # A股 09:30-11:30  13:00-15:00
    $aOpen = $false
    if ($dow -notin @('Saturday','Sunday')) {
        $t = $hour * 60 + $min
        if (($t -ge 570 -and $t -le 690) -or ($t -ge 780 -and $t -lt 900)) { $aOpen = $true }
    }

    # 美股 21:30-05:00 (覆盖夏令/冬令时)
    $usOpen = ($hour -ge 22) -or ($hour -lt 5) -or ($hour -eq 21 -and $min -ge 30)

    # 目标交易日
    $target = $now.Date
    if ($dow -in @('Saturday','Sunday') -or ($hour -ge 15 -and $dow -notin @('Saturday','Sunday'))) {
        $target = $target.AddDays(1)
    }
    while ($target.DayOfWeek -in @('Saturday','Sunday')) { $target = $target.AddDays(1) }

    $phase = if ($aOpen) { "盘中" } elseif ($usOpen) { "美股时段" } else { "盘后" }

    return [PSCustomObject]@{
        Now = $now; AShareOpen = $aOpen; USOpen = $usOpen
        TargetDate = $target; Phase = $phase
    }
}

# ══════════════════════════════════════════════════════════════
#  数据收集（调用现有原子脚本）
# ══════════════════════════════════════════════════════════════
function Get-HourlyData {
    param($Context)
    $bundle = @{ News = @(); USMovers = @(); SentimentIndex = 5 }

    # 新闻
    try {
        $n = & "$PSScriptRoot\Get-MarketNews.ps1" -Quiet
        if ($n) { $bundle.News = @($n) }
    } catch {}

    # 美股
    if ($Context.USOpen) {
        try {
            $m = & "$PSScriptRoot\Get-USStockMovers.ps1" -Quiet
            if ($m) { $bundle.USMovers = @($m) }
        } catch {}
    }

    # 情绪
    try {
        $s = & "$PSScriptRoot\Get-MarketSentiment.ps1" -Quiet
        if ($s -and $s.SentimentIndex) { $bundle.SentimentIndex = $s.SentimentIndex }
    } catch {}

    return $bundle
}

# ══════════════════════════════════════════════════════════════
#  板块 + 成分股扫描（直接调 EM API，不依赖外部脚本）
# ══════════════════════════════════════════════════════════════
function Get-HotSectors {
    param([string]$FsType, [int]$Count)
    $fs = if ($FsType -eq "industry") { "m:90+t:2" } else { "m:90+t:3" }
    $sz = $Count + 20
    $url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$sz&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=$fs&fields=f2,f3,f4,f12,f14"
    $resp = Invoke-StockApi -Uri $url
    if (-not ($resp -and $resp.data -and $resp.data.diff)) {
        $url2 = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$sz&po=1&np=1&ut=7eea3edcaed734bea9cbfc24409ed989&fltt=2&invt=2&fid=f62&fs=$fs&fields=f2,f3,f4,f12,f14"
        $resp = Invoke-StockApi -Uri $url2
    }
    $out = @()
    if ($resp -and $resp.data -and $resp.data.diff) {
        foreach ($item in $resp.data.diff) {
            $name = "$($item.f14)"
            $isNoise = $false
            foreach ($p in $noisePatterns) { if ($name -like "*$p*") { $isNoise = $true; break } }
            if ($isNoise) { continue }
            if ([double]$item.f3 -le 0) { continue }
            $out += [PSCustomObject]@{ Code = "$($item.f12)"; Name = $name; Change = [Math]::Round([double]$item.f3, 2) }
            if ($out.Count -ge $Count) { break }
        }
    }
    return $out
}

function Get-ComponentStocks {
    param([string]$SectorCode, [int]$Max = 25)
    $url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$Max&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=b:$SectorCode&fields=f2,f3,f5,f6,f7,f8,f9,f12,f14,f15,f16,f17,f20"
    $resp = Invoke-StockApi -Uri $url
    $out = @()
    if ($resp -and $resp.data -and $resp.data.diff) {
        foreach ($item in $resp.data.diff) {
            $code = "$($item.f12)"
            if (-not (Test-MainBoard $code)) { continue }
            $stockName = "$($item.f14)"
            $price = [double]$item.f2
            if ($price -le 0) { continue }
            $isST = $stockName -match 'ST|\*ST'
            $out += [PSCustomObject]@{
                Code      = $code
                Name      = $stockName
                IsST      = $isST
                Price     = $price
                Change    = [double]$item.f3
                High      = [double]$item.f15
                Low       = [double]$item.f16
                Open      = [double]$item.f17
                Amplitude = [double]$item.f7
                Turnover  = [double]$item.f8
                PE        = [double]$item.f9
                MarketCap = [double]$item.f20
            }
        }
    }
    return $out
}

# ══════════════════════════════════════════════════════════════
#  K线统计 — ATR / 振幅 / RSI / 低开高走频率
# ══════════════════════════════════════════════════════════════
function Get-KlineStats {
    param([string]$Code, [int]$Days = 35)
    $id  = Resolve-StockCode -InputCode $Code
    $beg = (Get-Date).AddDays(-$Days * 1.6).ToString("yyyyMMdd")
    $end = (Get-Date).ToString("yyyyMMdd")
    $url = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=$($id.SecId)&klt=101&fqt=1&beg=$beg&end=$end&lmt=$Days&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57"
    $resp = Invoke-StockApi -Uri $url -TimeoutSec 8 -Retries 1

    $klines = @()
    if ($resp -and $resp.data -and $resp.data.klines -and $resp.data.klines.Count -ge 5) {
        foreach ($line in $resp.data.klines) {
            $p = $line -split ','
            $klines += [PSCustomObject]@{
                Date = $p[0]; Open = [double]$p[1]; Close = [double]$p[2]
                High = [double]$p[3]; Low = [double]$p[4]; Volume = [double]$p[5]
            }
        }
    } else {
        # ── 备源：腾讯日K ──
        $tcSym = if ($id.Prefix -eq 'SH') { "sh$($id.Code)" } else { "sz$($id.Code)" }
        $tcUrl = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=$tcSym,day,,,$Days,qfq"
        try {
            $tcResp = Invoke-RestMethod -Uri $tcUrl -TimeoutSec 8 -Headers @{
                "User-Agent" = "Mozilla/5.0"; "Referer" = "https://stockapp.finance.qq.com"
            }
            $tcData = $tcResp.data.$tcSym
            $dayKey = if ($tcData.qfqday) { 'qfqday' } elseif ($tcData.day) { 'day' } else { $null }
            if ($dayKey -and $tcData.$dayKey.Count -ge 5) {
                foreach ($row in $tcData.$dayKey) {
                    $klines += [PSCustomObject]@{
                        Date = "$($row[0])"; Open = [double]$row[1]; Close = [double]$row[2]
                        High = [double]$row[3]; Low = [double]$row[4]; Volume = [double]$row[5]
                    }
                }
            }
        } catch {}
    }

    if ($klines.Count -lt 5) { return $null }
    $n    = $klines.Count
    $last = $klines[-1]

    # ATR14
    $atrSum = 0; $atrN = 0
    for ($i = [Math]::Max(1, $n - 14); $i -lt $n; $i++) {
        $tr = [Math]::Max($klines[$i].High - $klines[$i].Low,
              [Math]::Max([Math]::Abs($klines[$i].High - $klines[$i-1].Close),
                          [Math]::Abs($klines[$i].Low  - $klines[$i-1].Close)))
        $atrSum += $tr; $atrN++
    }
    $atrPct = if ($atrN -gt 0 -and $last.Close -gt 0) { $atrSum / $atrN / $last.Close * 100 } else { 0 }

    # 平均日振幅
    $rangeSum = 0; $rangeN = 0
    for ($i = [Math]::Max(0, $n - 14); $i -lt $n; $i++) {
        if ($klines[$i].Low -gt 0) {
            $rangeSum += ($klines[$i].High - $klines[$i].Low) / $klines[$i].Low * 100
            $rangeN++
        }
    }
    $avgRange = if ($rangeN -gt 0) { $rangeSum / $rangeN } else { 0 }

    # 收盘位置（0=收在最低 1=收在最高）
    $dayRange = $last.High - $last.Low
    $closePos = if ($dayRange -gt 0) { ($last.Close - $last.Low) / $dayRange } else { 0.5 }

    # RSI14
    $gains = 0.0; $losses = 0.0
    for ($i = [Math]::Max(1, $n - 14); $i -lt $n; $i++) {
        $d = $klines[$i].Close - $klines[$i-1].Close
        if ($d -gt 0) { $gains += $d } else { $losses += [Math]::Abs($d) }
    }
    $rsi = if (($gains + $losses) -gt 0) { $gains / ($gains + $losses) * 100 } else { 50 }

    # MA20
    $ma20 = 0
    if ($n -ge 20) { $s20 = 0; for ($i = $n - 20; $i -lt $n; $i++) { $s20 += $klines[$i].Close }; $ma20 = $s20 / 20 }

    # 近期低开高走频率（Open<PrevClose 且 日涨≥2%）
    $gapRevCnt = 0
    for ($i = 1; $i -lt $n; $i++) {
        $gapDown  = $klines[$i].Open -lt $klines[$i-1].Close
        $closeUp  = ($klines[$i].Close - $klines[$i].Open) / [Math]::Max(0.01, $klines[$i].Open) * 100 -ge 2
        if ($gapDown -and $closeUp) { $gapRevCnt++ }
    }
    $gapRevFreq = $gapRevCnt / [Math]::Max(1, $n - 1)

    # 周涨跌
    $weekChg = $null
    if ($n -ge 6 -and $klines[$n-6].Close -gt 0) {
        $weekChg = [Math]::Round(($last.Close - $klines[$n-6].Close) / $klines[$n-6].Close * 100, 2)
    }

    # 量比（今日 vs 5日均量）
    $vol5 = 0; for ($i = [Math]::Max(0, $n - 6); $i -lt $n - 1; $i++) { $vol5 += $klines[$i].Volume }
    $vol5avg  = if ($n -ge 6) { $vol5 / [Math]::Min(5, $n - 1) } else { $last.Volume }
    $volRatio = if ($vol5avg -gt 0) { $last.Volume / $vol5avg } else { 1 }

    return [PSCustomObject]@{
        ATR_Pct     = [Math]::Round($atrPct, 2)
        AvgRange    = [Math]::Round($avgRange, 2)
        ClosePos    = [Math]::Round($closePos, 3)
        Bearish     = $last.Close -lt $last.Open
        RSI14       = [Math]::Round($rsi, 1)
        MA20        = [Math]::Round($ma20, 2)
        NearMA20    = ($ma20 -gt 0 -and [Math]::Abs($last.Close - $ma20) / $ma20 -lt 0.03)
        GapRevCnt   = $gapRevCnt
        GapRevFreq  = [Math]::Round($gapRevFreq, 3)
        WeekChange  = $weekChg
        VolRatio    = [Math]::Round($volRatio, 2)
        LastClose   = $last.Close
    }
}

# ══════════════════════════════════════════════════════════════
#  低开高走评分 (满分 100)
# ══════════════════════════════════════════════════════════════
function Score-GapReversal {
    param($C, $K, $Bundle)

    if (-not $K) { return $null }

    $score   = 0
    $reasons = [System.Collections.ArrayList]::new()

    # ── 1. 低开概率 (0-25) ── 尾盘弱势 → 次日跳空低开
    $g = 0
    if ($K.ClosePos -lt 0.20)      { $g += 12; [void]$reasons.Add("极弱收盘(底部$([int]($K.ClosePos*100))%)") }
    elseif ($K.ClosePos -lt 0.35)  { $g += 8;  [void]$reasons.Add("弱势收盘") }
    elseif ($K.ClosePos -lt 0.5)   { $g += 4 }
    if ($K.Bearish) { $g += 5; [void]$reasons.Add("阴线") }
    if ($C.Change -lt 0 -and $C.SectorChange -gt 2) {
        $g += 8; [void]$reasons.Add("逆板块下跌(板块+$($C.SectorChange)%)")
    } elseif ($C.Change -lt ($C.SectorChange - 3)) {
        $g += 5; [void]$reasons.Add("弱于板块")
    }
    $g = [Math]::Min(25, $g)

    # ── 2. 反转强度 (0-30) ── 板块热+超卖+支撑
    $r = 0
    if ($C.SectorChange -gt 4)     { $r += 12; [void]$reasons.Add("板块大涨+$($C.SectorChange)%") }
    elseif ($C.SectorChange -gt 2) { $r += 8 }
    elseif ($C.SectorChange -gt 1) { $r += 4 }
    if ($K.RSI14 -lt 25)           { $r += 10; [void]$reasons.Add("RSI极度超卖($($K.RSI14))") }
    elseif ($K.RSI14 -lt 35)       { $r += 7;  [void]$reasons.Add("RSI超卖($($K.RSI14))") }
    elseif ($K.RSI14 -lt 45)       { $r += 3 }
    if ($K.NearMA20)               { $r += 5;  [void]$reasons.Add("MA20支撑") }
    if ($K.GapRevCnt -ge 4)        { $r += 5;  [void]$reasons.Add("历史低开高走$($K.GapRevCnt)次") }
    elseif ($K.GapRevCnt -ge 2)    { $r += 3 }
    $r = [Math]::Min(30, $r)

    # ── 3. 波动能力 (0-20) ── 日均振幅≥5%才容易实现+5%
    $v = 0
    if ($K.AvgRange -ge 7)         { $v = 20; [void]$reasons.Add("高波动(振幅$($K.AvgRange)%)") }
    elseif ($K.AvgRange -ge 5)     { $v = 16; [void]$reasons.Add("中高波动($($K.AvgRange)%)") }
    elseif ($K.AvgRange -ge 4)     { $v = 12 }
    elseif ($K.AvgRange -ge 3)     { $v = 8 }
    else                           { $v = 3 }

    # ── 4. 基本面+流动性 (0-15) ── 中盘股+合理PE+适度换手
    $f = 0
    if ($C.PE -gt 0 -and $C.PE -lt 30)  { $f += 4 }
    elseif ($C.PE -gt 0 -and $C.PE -lt 50) { $f += 2 }
    $mcYi = $C.MarketCap / 1e8
    if ($mcYi -ge 30 -and $mcYi -le 500)  { $f += 4; [void]$reasons.Add("中盘股$([int]$mcYi)亿") }
    elseif ($mcYi -ge 20 -and $mcYi -lt 30) { $f += 3 }
    elseif ($mcYi -gt 500 -and $mcYi -le 2000) { $f += 2 }
    if ($C.Turnover -ge 3 -and $C.Turnover -le 15) { $f += 4 }
    elseif ($C.Turnover -ge 1.5) { $f += 2 }
    # 量比放大说明资金关注
    if ($K.VolRatio -ge 1.5 -and $K.VolRatio -le 4) { $f += 3; [void]$reasons.Add("量比$($K.VolRatio)") }
    $f = [Math]::Min(15, $f)

    # ── 5. 美股联动 (0-10) ──
    $u = 0
    if ($Bundle.USMovers -and $Bundle.USMovers.Count -gt 0) {
        $techSym    = @('NVDA','AMD','AVGO','QCOM','MU','INTC','AAPL','MSFT','GOOGL','META','TSLA')
        $energySym  = @('XOM','CVX','OXY','SLB','HAL')
        $topUS      = @($Bundle.USMovers | Where-Object { $_.ChangePct -gt 2 })
        $sectorStr  = ($C.Sectors -join ',')
        $techUp     = @($topUS | Where-Object { $_.Symbol -in $techSym })
        $energyUp   = @($topUS | Where-Object { $_.Symbol -in $energySym })
        if ($techUp.Count -gt 0 -and $sectorStr -match '通信|芯片|半导体|电子|AI|算力|光|集成|存储') {
            $u = 10; [void]$reasons.Add("美股科技强势")
        } elseif ($energyUp.Count -gt 0 -and $sectorStr -match '石油|能源|化工|煤') {
            $u = 8; [void]$reasons.Add("美股能源强势")
        }
    }

    $total = $g + $r + $v + $f + $u
    return [PSCustomObject]@{
        Score = $total; Gap = $g; Reversal = $r
        Volatility = $v; Fundamental = $f; USBonus = $u
        Reasons = $reasons
    }
}

# ══════════════════════════════════════════════════════════════
#  财报快查（仅对 TOP 候选验证）
# ══════════════════════════════════════════════════════════════
function Get-FinanceQuick {
    param([string]$Code)
    try {
        $fin = & "$PSScriptRoot\Get-StockFinance.ps1" -Code $Code -Quiet
        if ($fin -and $fin.Reports -and $fin.Reports.Count -gt 0) {
            $r = $fin.Reports[0]
            return [PSCustomObject]@{
                RevenueYoY = $r.RevenueYoY
                ProfitYoY  = $r.ProfitYoY
                ROE        = $r.ROE
                GrossMargin = $r.GrossMargin
            }
        }
    } catch {}
    return $null
}

# ══════════════════════════════════════════════════════════════
#  日志 + 状态
# ══════════════════════════════════════════════════════════════
function Save-Prediction {
    param($Pick, $Context, [string]$Tag = "")
    if (-not $Pick) { return }

    # CSV
    $header = "DateTime,TargetDate,Phase,Tag,Code,Name,Score,Gap,Rev,Vol,Sector,WeekChg,AvgRange,RSI,RevGrow,ProfGrow,Reasons"
    if (-not (Test-Path $LogFile)) { $header | Out-File $LogFile -Encoding UTF8 }
    $sb = $Pick.ScoreDetail
    $line = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},"{10}",{11},{12},{13},{14},{15},"{16}"' -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm"), $Context.TargetDate.ToString("yyyy-MM-dd"), $Context.Phase,
        $Tag, $Pick.Code, $Pick.Name, $Pick.TotalScore,
        $sb.Gap, $sb.Reversal, $sb.Volatility,
        ($Pick.Sectors -join '/'), $Pick.WeekChange, $Pick.AvgRange, $Pick.RSI,
        $Pick.RevenueYoY, $Pick.ProfitYoY,
        ($sb.Reasons -join '; ')
    $line | Out-File $LogFile -Append -Encoding UTF8

    # State JSON (append both picks)
    $state = @{}
    if (Test-Path $StateFile) { try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable } catch { $state = @{} } }
    $key = if ($Tag) { $Tag } else { "Top1" }
    $state[$key] = @{
        LastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm")
        TargetDate = $Context.TargetDate.ToString("yyyy-MM-dd")
        Phase      = $Context.Phase
        Code       = $Pick.Code; Name = $Pick.Name
        Score      = $Pick.TotalScore; Price = $Pick.Price
        Sectors    = $Pick.Sectors; Reasons = @($sb.Reasons)
    }
    $state | ConvertTo-Json -Depth 5 | Out-File $StateFile -Encoding UTF8 -Force
}

# ══════════════════════════════════════════════════════════════
#  主扫描流程
# ══════════════════════════════════════════════════════════════
function Invoke-HourlyScan {
    $ctx = Get-MarketContext
    $ts  = Get-Date -Format "yyyy-MM-dd HH:mm"

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  [$ts] 低开高走 TOP1 扫描 — $($ctx.Phase)" -ForegroundColor Cyan
        Write-Host "  目标日期: $($ctx.TargetDate.ToString('yyyy-MM-dd'))  A股:$(if($ctx.AShareOpen){'开盘'}else{'休市'})  美股:$(if($ctx.USOpen){'开盘'}else{'休市'})" -ForegroundColor DarkGray
        Write-Host ""
    }

    # ── Step 1: 数据收集 ──
    if (-not $Quiet) { Write-Host "  [数据收集] " -NoNewline -ForegroundColor Yellow }
    $data = Get-HourlyData -Context $ctx
    if (-not $Quiet) {
        $usStr = if ($data.USMovers.Count -gt 0) { " | 美股${($data.USMovers.Count)}只" } else { "" }
        Write-Host "新闻$($data.News.Count)条$usStr | 情绪$($data.SentimentIndex)/10"
    }

    # ── Step 2: 热门板块 → 成分股（科技+非科技双通道）──
    if (-not $Quiet) { Write-Host "  [板块扫描] " -NoNewline -ForegroundColor Yellow }
    $indSectors  = Get-HotSectors -FsType "industry" -Count ($TopSectors + 5)
    $conSectors  = Get-HotSectors -FsType "concept"  -Count ($TopSectors + 5)
    $rawSectors  = @($indSectors) + @($conSectors) | Sort-Object Change -Descending
    # 分为科技/非科技，各取一半名额确保双通道都有候选
    $techSectors    = @($rawSectors | Where-Object { $_.Name -match $techPattern } | Select-Object -First ([Math]::Ceiling($TopSectors / 2)))
    $nonTechSectors = @($rawSectors | Where-Object { $_.Name -notmatch $techPattern } | Select-Object -First ([Math]::Ceiling($TopSectors / 2)))
    $allSectors = @($techSectors) + @($nonTechSectors) | Sort-Object Change -Descending

    if ($allSectors.Count -eq 0) {
        if (-not $Quiet) { Write-Host "无热门板块，跳过" -ForegroundColor Red }
        return $null
    }
    if (-not $Quiet) { Write-Host "$($allSectors.Count)个热门板块" -NoNewline }

    $pool = @{}
    foreach ($sec in $allSectors) {
        $stocks = Get-ComponentStocks -SectorCode $sec.Code -Max 25
        foreach ($s in $stocks) {
            if ($s.Turnover -lt 0.5) { continue }
            if (-not $pool.ContainsKey($s.Code)) {
                $s | Add-Member -NotePropertyName "Sectors"      -NotePropertyValue @($sec.Name) -Force
                $s | Add-Member -NotePropertyName "SectorChange" -NotePropertyValue $sec.Change   -Force
                $pool[$s.Code] = $s
            } else {
                $pool[$s.Code].Sectors += $sec.Name
                if ($sec.Change -gt $pool[$s.Code].SectorChange) { $pool[$s.Code].SectorChange = $sec.Change }
            }
        }
    }
    # 预排序：优先弱势/高振幅候选，限制最多60只
    $candidates = @($pool.Values | Sort-Object { $_.Change } | Select-Object -First 60)
    if (-not $Quiet) { Write-Host " → $($candidates.Count)只候选" }

    if ($candidates.Count -eq 0) {
        if (-not $Quiet) { Write-Host "  [WARN] 无有效候选" -ForegroundColor Red }
        return $null
    }

    # ── Step 3: K线分析 + 评分 ──
    if (-not $Quiet) { Write-Host "  [K线评分] " -NoNewline -ForegroundColor Yellow }
    $scored = @()
    $checked = 0
    foreach ($c in $candidates) {
        $k = Get-KlineStats -Code $c.Code -Days 35
        if (-not $k) { continue }
        $sr = Score-GapReversal -C $c -K $k -Bundle $data
        if (-not $sr) { continue }

        $scored += [PSCustomObject]@{
            Code         = $c.Code
            Name         = $c.Name
            IsST         = $c.IsST
            Price        = $c.Price
            Change       = $c.Change
            Sectors      = $c.Sectors
            SectorChange = $c.SectorChange
            Turnover     = $c.Turnover
            PE           = $c.PE
            WeekChange   = $k.WeekChange
            AvgRange     = $k.AvgRange
            RSI          = $k.RSI14
            GapRevCnt    = $k.GapRevCnt
            VolRatio     = $k.VolRatio
            TotalScore   = $sr.Score
            ScoreDetail  = $sr
            RevenueYoY   = $null
            ProfitYoY    = $null
        }
        $checked++
        if ($checked % 20 -eq 0 -and -not $Quiet) { Write-Host "." -NoNewline }
    }
    if (-not $Quiet) { Write-Host " $checked只已评分" }

    if ($scored.Count -eq 0) {
        if (-not $Quiet) { Write-Host "  [WARN] K线分析全部失败" -ForegroundColor Red }
        return $null
    }

    # ── Step 4: TOP 5 财报验证 ──
    $ranked = @($scored | Sort-Object TotalScore -Descending)
    if (-not $Quiet) { Write-Host "  [财报验证] " -NoNewline -ForegroundColor Yellow }
    $topCheck = [Math]::Min(8, $ranked.Count)
    for ($i = 0; $i -lt $topCheck; $i++) {
        $fin = Get-FinanceQuick -Code $ranked[$i].Code
        if ($fin) {
            $ranked[$i].RevenueYoY = $fin.RevenueYoY
            $ranked[$i].ProfitYoY  = $fin.ProfitYoY
            # 财报加/减分
            $bonus = 0
            if ($fin.RevenueYoY -gt 0 -and $fin.ProfitYoY -gt 0) { $bonus += 5 }
            if ($fin.RevenueYoY -gt 25 -and $fin.ProfitYoY -gt 25) { $bonus += 3 }
            if ($fin.ProfitYoY -lt -20) { $bonus -= 5 }
            $ranked[$i].TotalScore += $bonus
            if ($bonus -ne 0) {
                [void]$ranked[$i].ScoreDetail.Reasons.Add("财报$(if($bonus -gt 0){'+'}else{''})${bonus}分")
            }
        }
    }
    if (-not $Quiet) { Write-Host "已验证${topCheck}只" }

    # 重新排序
    $ranked = @($ranked | Sort-Object TotalScore -Descending)

    # ── 双通道分类：科技 vs 非科技 ──
    $techRanked    = @($ranked | Where-Object { ($_.Sectors -join ',') -match $techPattern })
    $nonTechRanked = @($ranked | Where-Object { ($_.Sectors -join ',') -notmatch $techPattern })

    $topTech    = if ($techRanked.Count -gt 0)    { $techRanked[0] }    else { $null }
    $topNonTech = if ($nonTechRanked.Count -gt 0) { $nonTechRanked[0] } else { $null }

    # ── Step 5: 保存 ──
    if ($topTech)    { Save-Prediction -Pick $topTech    -Context $ctx -Tag "科技" }
    if ($topNonTech) { Save-Prediction -Pick $topNonTech -Context $ctx -Tag "非科技" }

    # ── Step 6: 展示 ──
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  ══════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
        Write-Host "  低开高走双通道预测 — $($ctx.TargetDate.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
        Write-Host "  ══════════════════════════════════════════════════════════" -ForegroundColor DarkCyan

        foreach ($entry in @(
            @{ Pick = $topTech;    Label = "科技 TOP1";  Color = "Cyan" },
            @{ Pick = $topNonTech; Label = "非科技 TOP1"; Color = "Yellow" }
        )) {
            $pick = $entry.Pick
            if (-not $pick) {
                Write-Host ""
                Write-Host "  [$($entry.Label)] 无符合条件的候选" -ForegroundColor DarkGray
                continue
            }
            $stars    = [Math]::Min(5, [Math]::Floor($pick.TotalScore / 15))
            $starStr  = ("★" * $stars) + ("☆" * (5 - $stars))
            $scoreClr = if ($pick.TotalScore -ge 55) { "Green" } elseif ($pick.TotalScore -ge 40) { "Yellow" } else { "Red" }

            Write-Host ""
            Write-Host "  ── $($entry.Label) ──" -ForegroundColor $entry.Color
            Write-Host "  $($pick.Name) ($($pick.Code))$(if($pick.IsST){' [ST⚠]'})" -ForegroundColor White
            Write-Host "  评分: $($pick.TotalScore)/100  信心: $starStr" -ForegroundColor $scoreClr
            Write-Host "  现价: $($pick.Price)  今日: $(Format-Percent $pick.Change -WithSign)  近周: $(if($null -ne $pick.WeekChange){Format-Percent $pick.WeekChange -WithSign}else{'N/A'})"
            Write-Host "  板块: $($pick.Sectors -join ' / ')  板块涨幅: +$($pick.SectorChange)%"
            Write-Host "  日均振幅: $($pick.AvgRange)%  RSI: $($pick.RSI)  换手: $($pick.Turnover)%  量比: $($pick.VolRatio)"
            if ($null -ne $pick.RevenueYoY) {
                Write-Host "  营收同比: $(Format-Percent $pick.RevenueYoY -WithSign)  净利同比: $(Format-Percent $pick.ProfitYoY -WithSign)"
            }
            $sb = $pick.ScoreDetail
            Write-Host "  评分明细: 低开:$($sb.Gap)/25  反转:$($sb.Reversal)/30  波动:$($sb.Volatility)/20  基本面:$($sb.Fundamental)/15  美股:$($sb.USBonus)/10" -ForegroundColor DarkGray
            Write-Host "  理由:" -ForegroundColor DarkGray
            foreach ($reason in $pick.ScoreDetail.Reasons) { Write-Host "    • $reason" }
        }

        # TOP 5 per category
        foreach ($cat in @(
            @{ List = $techRanked;    Label = "科技 TOP5" },
            @{ List = $nonTechRanked; Label = "非科技 TOP5" }
        )) {
            if ($cat.List.Count -gt 1) {
                Write-Host ""
                Write-Host "  ── $($cat.Label) ──" -ForegroundColor DarkGray
                $rank = 1
                foreach ($item in ($cat.List | Select-Object -First 5)) {
                    $tag = if ($rank -eq 1) { "→" } else { " " }
                    $clr = if ($rank -eq 1) { "Cyan" } else { "Gray" }
                    Write-Host ("  $tag{0}. {1,-6} {2,-8} {3,3}分  振幅{4,4}%  RSI:{5,4}  {6}" -f `
                        $rank, $item.Code, $item.Name, $item.TotalScore, `
                        $item.AvgRange, $item.RSI, $item.Sectors[0]) -ForegroundColor $clr
                    $rank++
                }
            }
        }

        Write-Host ""
        Write-Host "  * 低开高走 = 跳空低开 → 日内反转 → 收盘≥+5%  此为模型预测，不构成投资建议" -ForegroundColor DarkGray
        Write-Host ""
    }

    return @{ Tech = $topTech; NonTech = $topNonTech }
}

# ══════════════════════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════════════════════
if ($Action -eq "monitor") {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  低开高走 TOP1 监控 — 每小时自动扫描             ║" -ForegroundColor Cyan
    Write-Host "  ║  Ctrl+C 退出                                    ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan

    $round = 0
    while ($true) {
        $round++
        Write-Host "`n  ────── 第 $round 轮 ──────" -ForegroundColor DarkYellow

        try { Invoke-HourlyScan } catch {
            Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }

        $next = (Get-Date).AddHours(1).ToString("HH:mm")
        Write-Host "  下次扫描: $next" -ForegroundColor DarkGray
        Start-Sleep -Seconds 3600
    }
} else {
    Invoke-HourlyScan
}
