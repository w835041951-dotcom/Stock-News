# ══════════════════════════════════════════════════════════════
# lib/SaveRecLog.ps1 — 推荐记录CSV写入 (全脚本共享)
# ══════════════════════════════════════════════════════════════

function Save-RecommendationLog {
    <#
    .SYNOPSIS 将推荐股票写入 recommendations-log.csv（去重：同一天同一 Code 不重复）
    .PARAMETER Stocks  推荐数组，至少需要 Code/Name/Price 属性
    .PARAMETER Source  来源脚本标识（AlphaSignal / MarketHotspot / DailyBrief / USStrong 等）
    .PARAMETER SentimentScore  情绪指数（可选）
    #>
    param(
        $Stocks,
        [string]$Source = "Unknown",
        [int]$SentimentScore = 0
    )

    if (-not $Stocks -or $Stocks.Count -eq 0) { return }

    # 优先用调用者的 $PSScriptRoot，否则用 lib 的上级
    $rootDir = if ($script:ProjectRoot) { $script:ProjectRoot } else { Split-Path $PSScriptRoot -Parent }
    $logFile = Join-Path $rootDir "recommendations-log.csv"
    $today   = Get-Date -Format "yyyy-MM-dd"

    # 查已有记录避免重复
    $existingCodes = @()
    if (Test-Path $logFile) {
        try {
            $existingCodes = @(Import-Csv $logFile -Encoding UTF8 |
                Where-Object { $_.Date -eq $today } |
                ForEach-Object { $_.Code })
        } catch {}
    }

    $rows = @($Stocks | Where-Object { $_.Code -notin $existingCodes } | ForEach-Object {
        [PSCustomObject]@{
            Date         = $today
            Code         = $_.Code
            Name         = $_.Name
            Price        = $_.Price
            Score        = if ($_.Score) { $_.Score } else { "" }
            SignalType   = if ($_.SignalType) { $_.SignalType } else { "" }
            HoldPeriod   = if ($_.HoldPeriod) { $_.HoldPeriod } else { "" }
            PosSize      = if ($_.PosSize) { $_.PosSize } else { "" }
            StopLoss     = if ($_.StopLoss) { $_.StopLoss } else { "" }
            SentimentIdx = $SentimentScore
            PE_TTM       = if ($_.Valuation) { $_.Valuation.PE_TTM } elseif ($_.PE_TTM) { $_.PE_TTM } else { "" }
            PEG          = if ($_.PEG) { $_.PEG } else { "" }
            Source       = $Source
        }
    })

    try {
        if ($rows.Count -gt 0) {
            $rows | Export-Csv $logFile -Append -NoTypeInformation -Encoding UTF8
        }
    } catch {}
}
