<#
.SYNOPSIS
    原子操作：单股综合评分（基本面+技术面+估值，满分100）(<10s)
.DESCRIPTION
    拉取财报 + K线 + CAPE 估值，按三维评分体系输出总分和各维度明细。
    基本面(0-40) + 技术面(0-30) + 估值面(0-30) = 100
.PARAMETER Code
    股票代码
.PARAMETER SectorName
    所属板块名称（用于判断周期性）
.PARAMETER Quiet
    静默模式
.EXAMPLE
    .\Get-StockScore.ps1 -Code 600519
    $s = .\Get-StockScore.ps1 -Code 000408 -SectorName "矿业" -Quiet
#>
param(
    [Parameter(Mandatory)] [string]$Code,
    [string]$SectorName = "",
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

. "$PSScriptRoot\lib\StockApi.ps1"
. "$PSScriptRoot\lib\StockCode.ps1"
. "$PSScriptRoot\lib\Format.ps1"

$id = Resolve-StockCode -InputCode $Code

# ── 获取基础数据（复用原子脚本）──
$detailScript = Join-Path $PSScriptRoot 'Get-StockDetail.ps1'
$capeScript   = Join-Path $PSScriptRoot 'Get-CapeValuation.ps1'

$detail = $null
$cape   = $null

if (Test-Path $detailScript) {
    $detail = & $detailScript -Code $id.Code -Action all -Quiet -ErrorAction SilentlyContinue
}
if (-not $detail) {
    if (-not $Quiet) { Write-Warning "无法获取 $Code 详情数据" }
    return $null
}

# 判断周期性
$isCyclical = [bool]($script:CyclicalKeywords | Where-Object { $SectorName -match $_ })

if ($isCyclical -and (Test-Path $capeScript)) {
    $cape = & $capeScript -Code $id.Code -Years 10 -Quiet -ErrorAction SilentlyContinue
}

# ── 基本面 (0-40) ──
$fundScore = 0
$fundDetails = @()

# 营收增速
$revYoY = $null
if ($detail.Reports -and $detail.Reports.Count -gt 0 -and $null -ne $detail.Reports[0].RevenueYoY) {
    $revYoY = [double]$detail.Reports[0].RevenueYoY
    if ($revYoY -gt 30) { $fundScore += 10; $fundDetails += "营收增速>30% +10" }
    elseif ($revYoY -gt 15) { $fundScore += 7; $fundDetails += "营收增速>15% +7" }
    elseif ($revYoY -gt 0) { $fundScore += 3; $fundDetails += "营收正增长 +3" }
}

# 净利增速
$profYoY = $null
if ($detail.Reports -and $detail.Reports.Count -gt 0 -and $null -ne $detail.Reports[0].ProfitYoY) {
    $profYoY = [double]$detail.Reports[0].ProfitYoY
    if ($profYoY -gt 30) { $fundScore += 10; $fundDetails += "净利增速>30% +10" }
    elseif ($profYoY -gt 15) { $fundScore += 7; $fundDetails += "净利增速>15% +7" }
    elseif ($profYoY -gt 0) { $fundScore += 3; $fundDetails += "净利正增长 +3" }
}

# ROE
$roe = $null
if ($detail.Reports -and $detail.Reports.Count -gt 0 -and $null -ne $detail.Reports[0].ROE) {
    $roe = [double]$detail.Reports[0].ROE
    if ($roe -gt 20) { $fundScore += 6; $fundDetails += "ROE>20% +6" }
    elseif ($roe -gt 12) { $fundScore += 4; $fundDetails += "ROE>12% +4" }
    elseif ($roe -gt 6) { $fundScore += 2; $fundDetails += "ROE>6% +2" }
}

# PEG
$pe = $detail.PE_TTM
if ($null -ne $pe -and [double]$pe -gt 0 -and $null -ne $profYoY -and [double]$profYoY -gt 5) {
    $peg = [double]$pe / [double]$profYoY
    if ($peg -lt 0.5) { $fundScore += 8; $fundDetails += "PEG<0.5 +8" }
    elseif ($peg -lt 1.0) { $fundScore += 5; $fundDetails += "PEG<1 +5" }
    elseif ($peg -lt 1.5) { $fundScore += 2; $fundDetails += "PEG<1.5 +2" }
    elseif ($peg -gt 3.0) { $fundScore -= 3; $fundDetails += "PEG>3 -3" }
}

# 毛利率趋势
if ($detail.Reports -and $detail.Reports.Count -ge 3) {
    $gms = @($detail.Reports[0..2] | ForEach-Object {
        if ($null -ne $_.GrossMargin -and "$($_.GrossMargin)" -ne '') { [double]$_.GrossMargin } else { $null }
    } | Where-Object { $null -ne $_ })
    if ($gms.Count -ge 2) {
        if ($gms[0] -gt $gms[-1] + 1) { $fundScore += 5; $fundDetails += "毛利率改善 +5" }
        elseif ($gms[0] -lt $gms[-1] - 1) { $fundScore -= 3; $fundDetails += "毛利率下滑 -3" }
    }
}

$fundScore = [Math]::Min(40, [Math]::Max(0, $fundScore))

# ── 技术面 (0-30) ──
$techScore = 0
$techDetails = @()

$w1 = $detail.Week1Change
$m1 = $detail.Month1Change

if ($null -ne $w1) {
    if ($w1 -le -8) { $techScore += 15; $techDetails += "周跌>8%回调 +15" }
    elseif ($w1 -le -4) { $techScore += 10; $techDetails += "周跌>4%回调 +10" }
    elseif ($w1 -le -1) { $techScore += 5; $techDetails += "周微跌调整 +5" }
}

if ($null -ne $m1) {
    if ($m1 -le -15) { $techScore += 15; $techDetails += "月跌>15%超卖 +15" }
    elseif ($m1 -le -8) { $techScore += 10; $techDetails += "月跌>8% +10" }
    elseif ($m1 -le -3) { $techScore += 5; $techDetails += "月微跌 +5" }
}

$techScore = [Math]::Min(30, [Math]::Max(0, $techScore))

# ── 估值面 (0-30) ──
$valScore = 0
$valDetails = @()

if ($isCyclical) {
    if ($cape -and $cape.CapeLevel) {
        switch ($cape.CapeLevel) {
            "Low"     { $valScore += 15; $valDetails += "CAPE低估 +15" }
            "Neutral" { $valScore += 8;  $valDetails += "CAPE合理 +8" }
            "High"    { $valScore += 3;  $valDetails += "CAPE偏高 +3" }
        }
    }
    if ($null -ne $pe -and [double]$pe -gt 0) {
        if ([double]$pe -lt 10) { $valScore += 15; $valDetails += "PE<10 +15" }
        elseif ([double]$pe -lt 20) { $valScore += 10; $valDetails += "PE<20 +10" }
        elseif ([double]$pe -lt 35) { $valScore += 5;  $valDetails += "PE<35 +5" }
    }
} else {
    if ($null -ne $pe -and [double]$pe -gt 0) {
        if ([double]$pe -lt 15) { $valScore += 18; $valDetails += "PE<15 +18" }
        elseif ([double]$pe -lt 25) { $valScore += 12; $valDetails += "PE<25 +12" }
        elseif ([double]$pe -lt 35) { $valScore += 6;  $valDetails += "PE<35 +6" }
    }
    if ($null -ne $detail.PB -and [double]$detail.PB -gt 0) {
        $pb = [double]$detail.PB
        if ($pb -lt 1.5) { $valScore += 12; $valDetails += "PB<1.5 +12" }
        elseif ($pb -lt 3) { $valScore += 7;  $valDetails += "PB<3 +7" }
        elseif ($pb -lt 5) { $valScore += 3;  $valDetails += "PB<5 +3" }
    }
}

# 相对行业PE修正
if ($detail.ValuationExtras -and $null -ne $detail.ValuationExtras.IndustryStaticPEMedian -and
    [double]$detail.ValuationExtras.IndustryStaticPEMedian -gt 0 -and $null -ne $pe -and [double]$pe -gt 0) {
    $relPE = [double]$pe / [double]$detail.ValuationExtras.IndustryStaticPEMedian
    if ($relPE -lt 0.6) { $valScore += 7; $valDetails += "PE低于行业60% +7" }
    elseif ($relPE -lt 0.8) { $valScore += 5; $valDetails += "PE低于行业80% +5" }
    elseif ($relPE -lt 0.9) { $valScore += 2; $valDetails += "PE低于行业90% +2" }
    elseif ($relPE -gt 1.3) { $valScore -= 3; $valDetails += "PE高于行业130% -3" }
}

$valScore = [Math]::Min(30, [Math]::Max(0, $valScore))
$totalScore = $fundScore + $techScore + $valScore

# ── 信号类型 ──
$signalType = "主题热点"
$capeLevel = if ($cape) { $cape.CapeLevel } else { $null }
$relPEValue = $null
if ($detail.ValuationExtras -and $null -ne $detail.ValuationExtras.IndustryStaticPEMedian -and
    [double]$detail.ValuationExtras.IndustryStaticPEMedian -gt 0 -and $null -ne $pe -and [double]$pe -gt 0) {
    $relPEValue = [double]$pe / [double]$detail.ValuationExtras.IndustryStaticPEMedian
}

if ($capeLevel -eq "Low" -or
    ($null -ne $relPEValue -and $relPEValue -lt 0.8) -or
    ($null -ne $pe -and [double]$pe -gt 0 -and [double]$pe -lt 15 -and $null -ne $profYoY -and [double]$profYoY -gt 0) -or
    ($null -ne $detail.PB -and [double]$detail.PB -gt 0 -and [double]$detail.PB -lt 1.5)) {
    $signalType = "价值洼地"
    $totalScore += 8
} elseif ($null -ne $revYoY -and [double]$revYoY -gt 25 -and $null -ne $profYoY -and [double]$profYoY -gt 25) {
    $signalType = "景气反转"
    $totalScore += 5
}

$result = [PSCustomObject]@{
    Code         = $id.Code
    Name         = $detail.Name
    Price        = $detail.Price
    TotalScore   = $totalScore
    FundScore    = $fundScore
    TechScore    = $techScore
    ValScore     = $valScore
    SignalType   = $signalType
    FundDetails  = $fundDetails
    TechDetails  = $techDetails
    ValDetails   = $valDetails
    PE_TTM       = $pe
    PB           = $detail.PB
    Week1Change  = $w1
    Month1Change = $m1
    CapeLevel    = $capeLevel
}

if (-not $Quiet) {
    $sigClr = switch ($signalType) { "价值洼地" { "Cyan" } "景气反转" { "Magenta" } default { "Yellow" } }
    Write-Host ""
    Write-Host "  $($detail.Name) ($($id.Code))  综合评分: $totalScore/100" -ForegroundColor Cyan
    Write-Host "  信号类型: " -NoNewline; Write-Host "【$signalType】" -ForegroundColor $sigClr
    Write-Host ""
    Write-Host "  基本面 ($fundScore/40):" -ForegroundColor Yellow
    foreach ($d in $fundDetails) { Write-Host "    $d" }
    Write-Host "  技术面 ($techScore/30):" -ForegroundColor Yellow
    foreach ($d in $techDetails) { Write-Host "    $d" }
    Write-Host "  估值面 ($valScore/30):" -ForegroundColor Yellow
    foreach ($d in $valDetails) { Write-Host "    $d" }
    Write-Host ""
}

return $result
