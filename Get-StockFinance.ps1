<#
.SYNOPSIS
    原子操作：获取最近4期财报核心经营指标 (<3s)
.PARAMETER Code
    股票代码
.PARAMETER Quiet
    静默模式
.EXAMPLE
    .\Get-StockFinance.ps1 -Code 600519
#>
param(
    [Parameter(Mandatory)] [string]$Code,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

. "$PSScriptRoot\lib\StockApi.ps1"
. "$PSScriptRoot\lib\StockCode.ps1"
. "$PSScriptRoot\lib\Format.ps1"

$id = Resolve-StockCode -InputCode $Code

$finUrl = "https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/ZYZBAjaxNew?type=0&code=$($id.Prefix)$($id.Code)"
$finData = Invoke-StockApi -Uri $finUrl -Referer "https://emweb.securities.eastmoney.com/PC_HSF10/NewFinanceAnalysis/Index?type=web&code=$($id.Prefix)$($id.Code)"

if (-not ($finData -and $finData.data)) {
    if (-not $Quiet) { Write-Warning "无法获取 $Code 财报数据" }
    return $null
}

$reports = @()
$items = @($finData.data | Select-Object -First 8)

foreach ($r in $items) {
    $reports += [PSCustomObject]@{
        ReportName  = "$($r.REPORT_DATE_NAME)"
        ReportDate  = "$($r.REPORT_DATE)"
        Revenue     = $r.TOTAL_OPERATE_INCOME
        RevenueYoY  = $r.YSTZ                         # 营收同比增长率
        NetProfit   = $r.PARENT_NETPROFIT
        ProfitYoY   = $r.SJLTZ                        # 净利润同比增长率
        EPS         = $r.BASIC_EPS
        BPS         = $r.BPS
        GrossMargin = $r.XSMLL                         # 毛利率
        NetMargin   = $r.XSJLL                         # 净利率
        ROE         = $r.ROEJQ                         # ROE(加权)
        DebtRatio   = $r.ZCFZL                         # 资产负债率
        CashFlowPS  = $r.MGJYXJJE                      # 每股经营现金流
    }
}

$result = [PSCustomObject]@{
    Code    = $id.Code
    Reports = $reports
}

if (-not $Quiet -and $reports.Count -gt 0) {
    Write-Host ""
    Write-Host "  $($id.Code) 最近 $($reports.Count) 期财报" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray

    foreach ($r in $reports | Select-Object -First 4) {
        $revStr = if ($r.Revenue) { Format-LargeNumber $r.Revenue } else { "N/A" }
        $npStr  = if ($r.NetProfit) { Format-LargeNumber $r.NetProfit } else { "N/A" }
        Write-Host "  $($r.ReportName)" -ForegroundColor Yellow
        Write-Host "    营收: $revStr  同比: $(Format-Percent $r.RevenueYoY -WithSign)"
        Write-Host "    净利: $npStr  同比: $(Format-Percent $r.ProfitYoY -WithSign)"
        Write-Host "    毛利率: $(Format-Percent $r.GrossMargin)  ROE: $(Format-Percent $r.ROE)  负债率: $(Format-Percent $r.DebtRatio)"
    }
    Write-Host ""
}

return $result
