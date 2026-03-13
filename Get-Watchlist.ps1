<#
.SYNOPSIS
    股票关注列表 — 持仓 + 推荐股追踪（含实时CAPE估值）
.DESCRIPTION
    维护持仓和推荐股列表，获取实时行情，记录每日收盘历史，输出涨跌对比。
    对持仓/推荐股逐个调用 Get-CapeValuation.ps1 追加 CAPE 估值信息。
.PARAMETER Action
    show    — 显示当前列表 + 实时行情 + CAPE（默认）
    update  — 抓取最新行情并写入 history
    add     — 添加股票（需 -Type, -Code, -Name 等）
    remove  — 移除股票（需 -Code, -Type）
    history — 查看历史记录
.PARAMETER Type
    holding / rec — 持仓 or 推荐
.PARAMETER Code
    6 位股票代码
.PARAMETER Name
    股票名称
.PARAMETER Cost
    持仓成本价
.PARAMETER Qty
    持仓数量
.PARAMETER RecPrice
    推荐价格
.PARAMETER Source
    推荐来源（默认 AlphaSignal）
.PARAMETER Days
    history 模式下显示最近 N 天（默认 7）
.PARAMETER Quiet
    静默模式，返回对象
.PARAMETER IncludeCAPE
    显示中包含CAPE估值（默认true，可设为false跳过以加速）
#>
param(
    [ValidateSet("show","update","add","remove","history")]
    [string]$Action = "show",
    [ValidateSet("holding","rec","")]
    [string]$Type = "",
    [string]$Code = "",
    [string]$Name = "",
    [double]$Cost = 0,
    [int]$Qty = 0,
    [double]$RecPrice = 0,
    [string]$Source = "AlphaSignal",
    [int]$Days = 7,
    [bool]$IncludeCAPE = $true,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$dataFile = Join-Path $PSScriptRoot "watchlist.json"

# ── 磁盘缓存（与 AlphaSignal 共享 TEMP\MyClaw_StockCache）──
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
    $file = Join-Path $script:CacheDir "$Key.json"
    try { $Value | ConvertTo-Json -Depth 8 | Out-File $file -Encoding UTF8 } catch {}
}

# ── Helper: Market code ──
function Get-MarketCode([string]$code) {
    if ($code -match '^(6|9)') { return 1 }   # SH
    return 0                                     # SZ
}

# ── Helper: Fetch real-time quote（使用 f57 动态精度）──
function Get-Quote([string]$code) {
    $m = Get-MarketCode $code
    # f57 = 小数精度位数，f43 = 最新价（整数形式），除以 10^f57 得真实价格
    $url = "https://push2.eastmoney.com/api/qt/stock/get?secid=$m.$code&fields=f43,f44,f45,f46,f57,f58,f169,f170&ut=fa5fd1943c7b386f172d6893dbfba10b"
    try {
        $r = Invoke-RestMethod -Uri $url -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = "https://quote.eastmoney.com/"
        } -TimeoutSec 10
        $d = $r.data
        if (-not $d) { return $null }

        # f57 returns stock code (not decimal precision). A-shares always use 2 decimal places.
        $dec = 2
        $divisor = 100.0

        return @{
            Price  = [math]::Round([double]$d.f43 / $divisor, $dec)
            High   = [math]::Round([double]$d.f44 / $divisor, $dec)
            Low    = [math]::Round([double]$d.f45 / $divisor, $dec)
            Open   = [math]::Round([double]$d.f46 / $divisor, $dec)
            Name   = ($d.f58 -replace '\s','')
            Change = [math]::Round([double]$d.f170 / 100, 2)  # f170 = 涨跌幅*100
        }
    } catch {
        return $null
    }
}

# ── Load data ──
if (Test-Path $dataFile) {
    $data = Get-Content $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $data = [PSCustomObject]@{
        holdings        = @()
        recommendations = @()
        history         = @()
    }
}

# ── Ensure arrays ──
if (-not $data.holdings)        { $data | Add-Member -NotePropertyName holdings        -NotePropertyValue @() -Force }
if (-not $data.recommendations) { $data | Add-Member -NotePropertyName recommendations -NotePropertyValue @() -Force }
if (-not $data.history)         { $data | Add-Member -NotePropertyName history         -NotePropertyValue @() -Force }

# ── Save helper ──
function Save-Data {
    $data | ConvertTo-Json -Depth 5 | Out-File $dataFile -Encoding UTF8
}

# ── Color helper ──
function Write-Colored([string]$text, [double]$value) {
    if ($value -gt 0) { Write-Host $text -NoNewline -ForegroundColor Red }
    elseif ($value -lt 0) { Write-Host $text -NoNewline -ForegroundColor Green }
    else { Write-Host $text -NoNewline }
}

# ===================== ACTION: ADD =====================
if ($Action -eq "add") {
    if (-not $Code -or -not $Type) {
        Write-Host "需要 -Code 和 -Type (holding/rec)" -ForegroundColor Yellow
        exit 1
    }
    $today = (Get-Date).ToString("yyyy-MM-dd")

    if ($Type -eq "holding") {
        $exists = $data.holdings | Where-Object { $_.code -eq $Code }
        if ($exists) {
            Write-Host "$Code 已在持仓列表中，更新信息" -ForegroundColor Yellow
            if ($Cost -gt 0) { $exists.cost = $Cost }
            if ($Qty -gt 0)  { $exists.qty = $Qty }
            if ($Name)       { $exists.name = $Name }
        } else {
            if (-not $Name) {
                $q = Get-Quote $Code
                if ($q) { $Name = $q.Name }
            }
            $entry = [PSCustomObject]@{
                code      = $Code
                name      = $Name
                cost      = $Cost
                qty       = $Qty
                addedDate = $today
            }
            $data.holdings = @($data.holdings) + $entry
        }
        Save-Data
        Write-Host "持仓已添加: $Code $Name (成本:$Cost x $Qty)" -ForegroundColor Cyan

    } elseif ($Type -eq "rec") {
        if ($RecPrice -le 0) {
            $q = Get-Quote $Code
            if ($q) { $RecPrice = $q.Price; if (-not $Name) { $Name = $q.Name } }
        }
        if (-not $Name) {
            $q = Get-Quote $Code
            if ($q) { $Name = $q.Name }
        }
        $entry = [PSCustomObject]@{
            code     = $Code
            name     = $Name
            recPrice = $RecPrice
            recDate  = $today
            source   = $Source
        }
        $data.recommendations = @($data.recommendations) + $entry
        Save-Data
        Write-Host "推荐已添加: $Code $Name (推荐价:$RecPrice, 来源:$Source)" -ForegroundColor Cyan
    }
    exit 0
}

# ===================== ACTION: REMOVE =====================
if ($Action -eq "remove") {
    if (-not $Code) {
        Write-Host "需要 -Code" -ForegroundColor Yellow
        exit 1
    }
    if ($Type -eq "holding" -or -not $Type) {
        $before = $data.holdings.Count
        $data.holdings = @($data.holdings | Where-Object { $_.code -ne $Code })
        if ($data.holdings.Count -lt $before) { Write-Host "已从持仓移除: $Code" -ForegroundColor Cyan }
    }
    if ($Type -eq "rec" -or -not $Type) {
        $before = $data.recommendations.Count
        $data.recommendations = @($data.recommendations | Where-Object { $_.code -ne $Code })
        if ($data.recommendations.Count -lt $before) { Write-Host "已从推荐移除: $Code" -ForegroundColor Cyan }
    }
    Save-Data
    exit 0
}

# ===================== ACTION: UPDATE (fetch & record) =====================
if ($Action -eq "update") {
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $allCodes = @{}
    foreach ($h in $data.holdings) { $allCodes[$h.code] = $h.name }
    foreach ($r in $data.recommendations) { $allCodes[$r.code] = $r.name }

    $newRecords = @()
    $count = 0
    $total = $allCodes.Count
    foreach ($kv in $allCodes.GetEnumerator()) {
        $count++
        $q = Get-Quote $kv.Key
        if ($q) {
            $newRecords += [PSCustomObject]@{
                date   = $today
                code   = $kv.Key
                name   = $kv.Value
                close  = $q.Price
                change = $q.Change
                high   = $q.High
                low    = $q.Low
            }
            Write-Host ("`r  [$count/$total] $($kv.Key) $($kv.Value) $($q.Price) $($q.Change)%") -NoNewline
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host ""

    $data.history = @($data.history | Where-Object { $_.date -ne $today })
    $data.history = @($data.history) + $newRecords
    Save-Data

    Write-Host "已更新 $($newRecords.Count) 只股票的行情到 history ($today)" -ForegroundColor Cyan
    Write-Host ""
    $Action = "show"
}

# ===================== ACTION: SHOW =====================
if ($Action -eq "show") {
    $allCodes = @{}
    foreach ($h in $data.holdings) { $allCodes[$h.code] = @{name=$h.name; type="holding"; cost=$h.cost; qty=$h.qty} }
    foreach ($r in $data.recommendations) {
        if ($allCodes.ContainsKey($r.code)) {
            $allCodes[$r.code].recPrice = $r.recPrice
            $allCodes[$r.code].recDate  = $r.recDate
            $allCodes[$r.code].type     = "both"
        } else {
            $allCodes[$r.code] = @{name=$r.name; type="rec"; recPrice=$r.recPrice; recDate=$r.recDate}
        }
    }

    $results = @()
    $total = $allCodes.Count
    $count = 0
    foreach ($kv in $allCodes.GetEnumerator()) {
        $count++
        Write-Host ("`r  获取行情 [$count/$total] $($kv.Key)...") -NoNewline
        $q = Get-Quote $kv.Key
        if ($q) {
            $info = $kv.Value
            $obj = [PSCustomObject]@{
                Code     = $kv.Key
                Name     = $info.name
                Type     = $info.type
                Price    = $q.Price
                TodayChg = $q.Change
                Cost     = if ($info.cost) { $info.cost } else { 0 }
                Qty      = if ($info.qty) { $info.qty } else { 0 }
                PnL      = 0
                PnLPct   = 0
                RecPrice = if ($info.recPrice) { $info.recPrice } else { 0 }
                RecDate  = if ($info.recDate) { $info.recDate } else { "" }
                VsRec    = 0
                MktVal   = 0
            }
            if ($obj.Cost -gt 0) {
                $obj.PnL    = [math]::Round(($q.Price - $obj.Cost) * $obj.Qty, 0)
                $obj.PnLPct = [math]::Round(($q.Price - $obj.Cost) / $obj.Cost * 100, 2)
                $obj.MktVal = [math]::Round($q.Price * $obj.Qty, 0)
            }
            if ($obj.RecPrice -gt 0) {
                $obj.VsRec = [math]::Round(($q.Price - $obj.RecPrice) / $obj.RecPrice * 100, 2)
            }
            $results += $obj
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host ("`r" + (" " * 60) + "`r")

    if ($Quiet) { return $results }

    # ── Display Holdings ──
    $holdings = $results | Where-Object { $_.Type -eq "holding" -or $_.Type -eq "both" } | Sort-Object MktVal -Descending
    if ($holdings.Count -gt 0) {
        Write-Host ""
        Write-Host "  ============================================================" -ForegroundColor White
        Write-Host "   持仓" -ForegroundColor Cyan
        Write-Host "  ============================================================" -ForegroundColor White
        Write-Host ""
        Write-Host ("  {0,-8} {1,-8} {2,8} {3,8} {4,10} {5,9} {6,9}" -f "代码","名称","现价","今日%","浮盈","浮盈%","市值")
        Write-Host ("  " + "-" * 72)
        $totalPnL = 0
        $totalMV  = 0
        foreach ($s in $holdings) {
            $todayStr = "{0,7:F2}%" -f $s.TodayChg
            $pnlStr   = "{0,9:N0}" -f $s.PnL
            $pctStr   = "{0,8:F2}%" -f $s.PnLPct
            $line = "  {0,-8} {1,-8} {2,8:F2} " -f $s.Code, $s.Name, $s.Price
            Write-Host $line -NoNewline
            Write-Colored $todayStr $s.TodayChg
            Write-Host " " -NoNewline
            Write-Colored $pnlStr $s.PnL
            Write-Host " " -NoNewline
            Write-Colored $pctStr $s.PnLPct
            Write-Host (" {0,9:N0}" -f $s.MktVal)
            $totalPnL += $s.PnL
            $totalMV  += $s.MktVal
        }
        Write-Host ("  " + "-" * 72)
        $totalLine = "  合计{0,48:N0} " -f $totalPnL
        Write-Host $totalLine -NoNewline
        $totalPct = if ($totalMV -gt 0) { [math]::Round($totalPnL / ($totalMV - $totalPnL) * 100, 2) } else { 0 }
        Write-Colored ("{0,8:F2}%" -f $totalPct) $totalPnL
        Write-Host (" {0,9:N0}" -f $totalMV)

        $both = $holdings | Where-Object { $_.Type -eq "both" }
        if ($both.Count -gt 0) {
            Write-Host ""
            foreach ($b in $both) {
                $vsStr = "{0:+0.00;-0.00}%" -f $b.VsRec
                Write-Host "  $($b.Code) $($b.Name) 同时在推荐列表 (推荐价:$($b.RecPrice) " -NoNewline -ForegroundColor DarkYellow
                Write-Colored $vsStr $b.VsRec
                Write-Host ")" -ForegroundColor DarkYellow
            }
        }
    }

    # ── Display Recommendations ──
    $recs = $results | Where-Object { $_.Type -eq "rec" } | Sort-Object VsRec -Descending
    if ($recs.Count -gt 0) {
        Write-Host ""
        Write-Host "  ============================================================" -ForegroundColor White
        Write-Host "   推荐追踪" -ForegroundColor Yellow
        Write-Host "  ============================================================" -ForegroundColor White
        Write-Host ""
        Write-Host ("  {0,-8} {1,-8} {2,8} {3,8} {4,9} {5,9} {6,-12}" -f "代码","名称","现价","今日%","推荐价","vs推荐%","推荐日期")
        Write-Host ("  " + "-" * 72)
        foreach ($s in $recs) {
            $todayStr = "{0,7:F2}%" -f $s.TodayChg
            $vsStr    = "{0,8:F2}%" -f $s.VsRec
            $line = "  {0,-8} {1,-8} {2,8:F2} " -f $s.Code, $s.Name, $s.Price
            Write-Host $line -NoNewline
            Write-Colored $todayStr $s.TodayChg
            Write-Host (" {0,9:F2} " -f $s.RecPrice) -NoNewline
            Write-Colored $vsStr $s.VsRec
            Write-Host (" {0,-12}" -f $s.RecDate)
        }
    }


    Write-Host ""
    Write-Host "  * 数据来源: 东方财富  行情可能有15分钟延迟" -ForegroundColor DarkGray
    Write-Host "  * 此为数据追踪，不构成投资建议" -ForegroundColor DarkGray
    Write-Host ""
}

# ===================== ACTION: HISTORY =====================
if ($Action -eq "history") {
    $cutoff = (Get-Date).AddDays(-$Days).ToString("yyyy-MM-dd")
    $recent = $data.history | Where-Object { $_.date -ge $cutoff } | Sort-Object date, code

    if ($recent.Count -eq 0) {
        Write-Host "最近 $Days 天无历史记录。先运行 -Action update 记录今日数据。" -ForegroundColor Yellow
        exit 0
    }

    if ($Quiet) { return $recent }

    $codes  = $recent | Select-Object -ExpandProperty code -Unique | Sort-Object

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor White
    Write-Host "   历史行情 (最近 $Days 天)" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor White
    Write-Host ""

    foreach ($c in $codes) {
        $stockRows = $recent | Where-Object { $_.code -eq $c }
        $sname = ($stockRows | Select-Object -First 1).name
        Write-Host "  $c $sname" -ForegroundColor White
        foreach ($row in ($stockRows | Sort-Object date)) {
            $chgStr = "{0:+0.00;-0.00}%" -f $row.change
            Write-Host "    $($row.date)  $($row.close)  " -NoNewline
            Write-Colored $chgStr $row.change
            Write-Host ""
        }
        Write-Host ""
    }
    Write-Host "  * 此为数据追踪，不构成投资建议" -ForegroundColor DarkGray
    Write-Host ""
}
