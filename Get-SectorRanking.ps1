<#
.SYNOPSIS
    原子操作：获取热门板块排行（行业 + 概念）(<5s)
.PARAMETER Top
    每类返回前N个（默认10）
.PARAMETER Type
    industry / concept / all（默认 all）
.PARAMETER Quiet
    静默模式
.EXAMPLE
    .\Get-SectorRanking.ps1
    .\Get-SectorRanking.ps1 -Type industry -Top 5
    $s = .\Get-SectorRanking.ps1 -Quiet
#>
param(
    [int]$Top = 10,
    [ValidateSet("industry","concept","all")]
    [string]$Type = "all",
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

. "$PSScriptRoot\lib\StockApi.ps1"
. "$PSScriptRoot\lib\StockCode.ps1"

function Get-Sectors {
    param([string]$FsType, [int]$Count)
    $fs = if ($FsType -eq "industry") { "m:90+t:2" } else { "m:90+t:3" }
    $fetchSize = $Count + 20
    $url = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=$fetchSize&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=$fs&fields=f2,f3,f4,f12,f14"
    $resp = Invoke-StockApi -Uri $url
    $results = @()
    if ($resp -and $resp.data -and $resp.data.diff) {
        $idx = 1
        foreach ($item in $resp.data.diff) {
            $name = "$($item.f14)"
            # 概念板块过滤噪音
            if ($FsType -eq "concept") {
                $isNoise = $false
                foreach ($p in $script:NoiseSectorPatterns) { if ($name -like "*$p*") { $isNoise = $true; break } }
                if ($isNoise) { continue }
            }
            if ([double]$item.f3 -le 0 -and $FsType -eq "concept") { continue }
            $results += [PSCustomObject]@{
                Rank      = $idx
                Code      = "$($item.f12)"
                Name      = $name
                ChangePct = [Math]::Round([double]$item.f3, 2)
                Type      = if ($FsType -eq "industry") { "行业" } else { "概念" }
            }
            $idx++
            if ($results.Count -ge $Count) { break }
        }
    }
    return $results
}

$industries = @()
$concepts   = @()

if ($Type -in @("industry","all")) {
    $industries = Get-Sectors -FsType "industry" -Count $Top
}
if ($Type -in @("concept","all")) {
    $concepts = Get-Sectors -FsType "concept" -Count $Top
}

$result = [PSCustomObject]@{
    Industries = $industries
    Concepts   = $concepts
}

if (-not $Quiet) {
    if ($industries.Count -gt 0) {
        Write-Host "`n  === 行业板块涨幅 Top $Top ===" -ForegroundColor Cyan
        foreach ($s in $industries) {
            $chgStr = if ($s.ChangePct -gt 0) { "+$($s.ChangePct)%" } else { "$($s.ChangePct)%" }
            $clr = if ($s.ChangePct -gt 0) { "Red" } elseif ($s.ChangePct -lt 0) { "Green" } else { "White" }
            Write-Host "  $($s.Rank). $($s.Name)" -NoNewline -ForegroundColor White
            Write-Host "  $chgStr" -ForegroundColor $clr
        }
    }
    if ($concepts.Count -gt 0) {
        Write-Host "`n  === 概念板块涨幅 Top $Top ===" -ForegroundColor Cyan
        foreach ($s in $concepts) {
            $chgStr = if ($s.ChangePct -gt 0) { "+$($s.ChangePct)%" } else { "$($s.ChangePct)%" }
            $clr = if ($s.ChangePct -gt 0) { "Red" } elseif ($s.ChangePct -lt 0) { "Green" } else { "White" }
            Write-Host "  $($s.Rank). $($s.Name)" -NoNewline -ForegroundColor White
            Write-Host "  $chgStr" -ForegroundColor $clr
        }
    }
    Write-Host ""
}

return $result
