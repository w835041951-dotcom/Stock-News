# ══════════════════════════════════════════════════════════════
# lib/StockApi.ps1 — HTTP Client + 磁盘缓存 (全脚本共享)
# 用法: . "$PSScriptRoot\lib\StockApi.ps1" 或从根目录 . "$PSScriptRoot\..\lib\StockApi.ps1"
# ══════════════════════════════════════════════════════════════

# ── 磁盘缓存 ──────────────────────────────────────────────────
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
    try {
        $file = Join-Path $script:CacheDir "$Key.json"
        $Value | ConvertTo-Json -Depth 10 -Compress | Out-File $file -Encoding UTF8 -Force
    } catch {}
}

# ── HTTP Client ───────────────────────────────────────────────
function Invoke-StockApi {
    param(
        [string]$Uri,
        [string]$Referer = "https://quote.eastmoney.com/",
        [int]$TimeoutSec = 15
    )
    try {
        return Invoke-RestMethod -Uri $Uri -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            "Referer"    = $Referer
            "Accept"     = "application/json, text/plain, */*"
        } -TimeoutSec $TimeoutSec
    } catch {
        return $null
    }
}

function Invoke-StockXmlApi {
    param([string]$Uri, [int]$TimeoutSec = 15)
    try {
        $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }
        return [xml]$resp.Content
    } catch {
        return $null
    }
}
