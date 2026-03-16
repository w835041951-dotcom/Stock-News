<#
.SYNOPSIS
    原子操作：获取单只股票实时行情 (<1s)
.PARAMETER Code
    股票代码，支持 600519 / SH600519 / sz000001
.PARAMETER Quiet
    静默模式，仅返回对象
.EXAMPLE
    .\Get-StockQuote.ps1 -Code 600519
    $q = .\Get-StockQuote.ps1 -Code 000001 -Quiet
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

$url = "https://push2.eastmoney.com/api/qt/stock/get?secid=$($id.SecId)&fields=f43,f44,f45,f46,f57,f58,f59,f60,f168,f169,f170,f47,f48,f164,f167&ut=fa5fd1943c7b386f172d6893dbfba10b"
$resp = Invoke-StockApi -Uri $url

if (-not ($resp -and $resp.data)) {
    if (-not $Quiet) { Write-Warning "无法获取 $Code 行情" }
    return $null
}

$d   = $resp.data
$dec = 2
$div = 100.0
if ($d.f59 -and [int]$d.f59 -gt 0 -and [int]$d.f59 -le 6) {
    $dec = [int]$d.f59
    $div = [Math]::Pow(10, $dec)
}

$result = [PSCustomObject]@{
    Code         = $id.Code
    Name         = "$($d.f58)".Trim()
    Market       = $id.Prefix
    Price        = if ($null -ne (Convert-ToNumber $d.f43)) { [Math]::Round([double]$d.f43 / $div, $dec) } else { $null }
    Open         = if ($null -ne (Convert-ToNumber $d.f46)) { [Math]::Round([double]$d.f46 / $div, $dec) } else { $null }
    High         = if ($null -ne (Convert-ToNumber $d.f44)) { [Math]::Round([double]$d.f44 / $div, $dec) } else { $null }
    Low          = if ($null -ne (Convert-ToNumber $d.f45)) { [Math]::Round([double]$d.f45 / $div, $dec) } else { $null }
    PrevClose    = if ($null -ne (Convert-ToNumber $d.f60)) { [Math]::Round([double]$d.f60 / $div, $dec) } else { $null }
    Change       = if ($null -ne (Convert-ToNumber $d.f169)) { [Math]::Round([double]$d.f169 / $div, $dec) } else { $null }
    ChangePct    = if ($null -ne (Convert-ToNumber $d.f170)) { [Math]::Round([double]$d.f170 / 100, 2) } else { $null }
    Volume       = $d.f47
    Amount       = $d.f48
    TurnoverRate = if ($null -ne (Convert-ToNumber $d.f168)) { [Math]::Round([double]$d.f168 / 100, 2) } else { $null }
    PE_TTM       = if ($null -ne (Convert-ToNumber $d.f164)) { [Math]::Round([double]$d.f164 / 100, 2) } else { $null }
    PB           = if ($null -ne (Convert-ToNumber $d.f167)) { [Math]::Round([double]$d.f167 / 100, 2) } else { $null }
}

if (-not $Quiet) {
    $chgStr = if ($result.ChangePct -gt 0) { "+$($result.ChangePct)%" } else { "$($result.ChangePct)%" }
    $color  = if ($result.ChangePct -gt 0) { "Red" } elseif ($result.ChangePct -lt 0) { "Green" } else { "White" }
    Write-Host ""
    Write-Host "  $($result.Name) ($($result.Code).$($result.Market))" -ForegroundColor Cyan
    Write-Host "  价格: " -NoNewline; Write-Host "$($result.Price)" -NoNewline -ForegroundColor $color
    Write-Host "  涨跌: " -NoNewline; Write-Host "$chgStr" -ForegroundColor $color
    Write-Host "  开: $($result.Open)  高: $($result.High)  低: $($result.Low)  昨收: $($result.PrevClose)"
    Write-Host "  成交额: $(Format-LargeNumber $result.Amount)  换手率: $($result.TurnoverRate)%"
    if ($result.PE_TTM) { Write-Host "  PE(TTM): $($result.PE_TTM)  PB: $($result.PB)" }
    Write-Host ""
}

return $result
