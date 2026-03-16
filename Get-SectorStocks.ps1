<#
.SYNOPSIS
    原子操作：获取板块成分股列表 (<3s)
.PARAMETER SectorCode
    板块代码（东方财富格式，如 BK0477）
.PARAMETER Top
    返回前N只（默认30）
.PARAMETER MainBoardOnly
    仅保留主板+创业板，排除科创板/北交所
.PARAMETER Quiet
    静默模式
.EXAMPLE
    .\Get-SectorStocks.ps1 -SectorCode BK0477
    .\Get-SectorStocks.ps1 -SectorCode BK0477 -MainBoardOnly -Quiet
#>
param(
    [Parameter(Mandatory)] [string]$SectorCode,
    [int]$Top = 30,
    [switch]$MainBoardOnly,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

. "$PSScriptRoot\lib\StockApi.ps1"
. "$PSScriptRoot\lib\StockCode.ps1"
. "$PSScriptRoot\lib\Format.ps1"

$url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$Top&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=b:$SectorCode&fields=f2,f3,f4,f5,f6,f12,f14,f9,f23"
$resp = Invoke-StockApi -Uri $url

$stocks = @()
if ($resp -and $resp.data -and $resp.data.diff) {
    foreach ($item in $resp.data.diff) {
        $code = "$($item.f12)"
        if (-not $code -or $code -eq "-") { continue }
        if ($MainBoardOnly -and -not (Test-MainBoard $code)) { continue }

        $stocks += [PSCustomObject]@{
            Code      = $code
            Name      = "$($item.f14)"
            Price     = $item.f2
            ChangePct = $item.f3
            Change    = $item.f4
            Volume    = $item.f5
            Amount    = $item.f6
            PE_TTM    = $item.f9
            PB        = $item.f23
        }
    }
}

if (-not $Quiet) {
    Write-Host "`n  板块 $SectorCode 成分股 (共 $($stocks.Count) 只)" -ForegroundColor Cyan
    foreach ($s in $stocks | Select-Object -First 15) {
        $chgStr = if ($s.ChangePct -gt 0) { "+$($s.ChangePct)%" } else { "$($s.ChangePct)%" }
        $clr = if ($s.ChangePct -gt 0) { "Red" } elseif ($s.ChangePct -lt 0) { "Green" } else { "White" }
        Write-Host "  $($s.Code) $($s.Name)" -NoNewline
        Write-Host "  $chgStr" -NoNewline -ForegroundColor $clr
        Write-Host "  成交额: $(Format-LargeNumber $s.Amount)"
    }
    Write-Host ""
}

return $stocks
