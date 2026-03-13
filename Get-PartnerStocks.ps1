<#
.SYNOPSIS
    从美股公司反推A股潜在紧密合作公司（基于Web新闻证据）
.DESCRIPTION
    输入美股代码或公司名（如 NVDA/英伟达），通过 Web 搜索新闻提取潜在合作/供应链/客户关联，
    并按新闻证据源质量打分，输出候选列表与证据。
.PARAMETER Target
    美股目标（Ticker 或公司名）
.PARAMETER TopN
    返回候选数量（默认10）
.PARAMETER Days
    只保留最近N天新闻（默认60）
.PARAMETER UseWebSearch
    是否启用Web搜索（默认启用）
.PARAMETER WebSources
    Web新闻来源（逗号分隔）：google,bing（默认两者都用）
.PARAMETER Quiet
    静默模式，返回对象
.EXAMPLE
    .\stock-news\Get-PartnerStocks.ps1 -Target NVDA
    .\stock-news\Get-PartnerStocks.ps1 -Target 英伟达 -TopN 15 -Days 90
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [int]$TopN = 10,

    [int]$Days = 60,

    [bool]$UseWebSearch = $true,

    [string]$WebSources = 'google,bing',

    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

function Resolve-Python {
    $candidates = @(
        'C:\Dev\MyClaw\.venv\Scripts\python.exe',
        'C:\Users\hongyangwan\AppData\Local\Programs\Python\Python313\python.exe',
        'python'
    )

    foreach ($candidate in $candidates) {
        try {
            if ($candidate -eq 'python') {
                $cmd = Get-Command python -ErrorAction SilentlyContinue
                if ($cmd) { return $cmd.Source }
            }
            elseif (Test-Path $candidate) {
                return $candidate
            }
        }
        catch {}
    }

    throw 'Python not found. Please install Python 3.11 or use workspace .venv.'
}

function Get-AStockAnalysis {
    param([string]$Code)

    # 磁盘缓存（与 AlphaSignal 共享 TEMP\MyClaw_StockCache）
    $cacheDir = Join-Path $env:TEMP "MyClaw_StockCache"
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $cacheFile = Join-Path $cacheDir "partner_detail_$Code.json"
    if (Test-Path $cacheFile) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalMinutes -le 360) {
            try { return (Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
        }
    }

    $detailScript = Join-Path $PSScriptRoot 'Get-StockDetail.ps1'

    $analysis = [ordered]@{
        ReportName    = $null
        RevenueYoY    = $null
        ProfitYoY     = $null
        ROE           = $null
        PE_TTM        = $null
        PB            = $null
    }

    try {
        if (Test-Path $detailScript) {
            $d = & $detailScript -Code $Code -Action all -Quiet -ErrorAction SilentlyContinue
            if ($d) {
                $analysis.PE_TTM = $d.PE_TTM
                $analysis.PB = $d.PB
                if ($d.Reports -and $d.Reports.Count -gt 0) {
                    $r = $d.Reports[0]
                    $analysis.ReportName = $r.ReportName
                    $analysis.RevenueYoY = $r.RevenueYoY
                    $analysis.ProfitYoY = $r.NetProfitYoY
                    $analysis.ROE = $r.ROE
                }
            }
        }
    }
    catch {}

    # 写入缓存
    try { [PSCustomObject]$analysis | ConvertTo-Json -Depth 8 | Out-File $cacheFile -Encoding UTF8 } catch {}

    return [PSCustomObject]$analysis
}

function Get-EntryTimingAdvice {
    param([string]$Code)

    if (-not $Code -or $Code -notmatch '^\d{6}$') { return $null }

    $cacheDir = Join-Path $env:TEMP "MyClaw_StockCache"
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $cacheFile = Join-Path $cacheDir "partner_entry_$Code.json"
    if (Test-Path $cacheFile) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalMinutes -le 15) {
            try { return (Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
        }
    }

    $timingScript = Join-Path $PSScriptRoot 'Get-EntryTiming.ps1'
    if (-not (Test-Path $timingScript)) { return $null }

    try {
        $timing = & $timingScript -Code $Code -Quiet -ErrorAction SilentlyContinue
        if ($timing) {
            try { $timing | ConvertTo-Json -Depth 8 | Out-File $cacheFile -Encoding UTF8 } catch {}
        }
        return $timing
    }
    catch {
        return $null
    }
}

function Resolve-AStockCodeByName {
    param([string]$Name)

    if (-not $Name) { return $null }
    $kw = [Uri]::EscapeDataString($Name)
    $url = "https://searchapi.eastmoney.com/api/suggest/get?input=$kw&type=14&token=D43BF722C8E33BDC906FB84D85E326E8"
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer" = "https://quote.eastmoney.com/"
        } -TimeoutSec 12

        $items = @($resp.QuotationCodeTable.Data)
        foreach ($it in $items) {
            $code = "$($it.Code)"
            if ($code -match '^(60\d{4}|000\d{3}|001\d{3}|002\d{3})$') {
                return $code
            }
        }
    }
    catch {}

    return $null
}

$pythonCmd = Resolve-Python
$pyScript = Join-Path $PSScriptRoot 'python\FindPartnerAStocks.py'
if (-not (Test-Path $pyScript)) {
    throw "Script not found: $pyScript"
}

$engineArgs = @(
    $pyScript,
    '--target', $Target,
    '--topn', $TopN,
    '--days', $Days,
    '--sources', $WebSources
)

if (-not $UseWebSearch) {
    # 当前版本主能力依赖 Web 新闻检索，关闭后将返回空结果提示。
    $engineArgs += @('--max-per-query', 0)
}

$jsonText = & $pythonCmd @engineArgs 2>$null
if (-not $jsonText) {
    throw 'No result returned from Python engine.'
}

$result = $jsonText | ConvertFrom-Json

if ($result.Error) {
    if ($Quiet) { return $result }
    Write-Warning "Partner engine error: $($result.Error)"
    return
}

if ($Quiet) {
    foreach ($x in @($result.Results)) {
        if ($x.Code -and $x.Code -match '^\d{6}$') {
            $a = Get-AStockAnalysis -Code $x.Code
            $x | Add-Member -NotePropertyName Analysis -NotePropertyValue $a -Force
            $t = Get-EntryTimingAdvice -Code $x.Code
            $x | Add-Member -NotePropertyName EntryTiming -NotePropertyValue $t -Force
        }
    }
    return $result
}

Write-Host ""
Write-Host ("=" * 88) -ForegroundColor Cyan
Write-Host "  美股映射A股合作公司 - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor White
Write-Host "  Target: $($result.Target)" -ForegroundColor Yellow
if ($result.SourcesUsed) {
    Write-Host "  Sources: $($result.SourcesUsed -join ', ')" -ForegroundColor DarkGray
}
Write-Host ("=" * 88) -ForegroundColor Cyan

if ($result.Note) {
    Write-Host "" 
    Write-Warning $result.Note
}

if (-not $result.Results -or $result.Results.Count -eq 0) {
    Write-Host "" 
    Write-Host "未识别到高置信度A股合作候选。" -ForegroundColor Yellow
    Write-Host "建议：增大 -Days 或尝试别名（例如 NVDA/英伟达/NVIDIA）。" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "免责声明：该结果基于公开新闻文本匹配，仅供研究参考，不构成投资建议。" -ForegroundColor DarkYellow
    return
}

$rows = @()
foreach ($x in $result.Results) {
    $rel = if ($x.Relations) { ($x.Relations -join ', ') } else { '' }
    $tiers = ''
    if ($x.SourceTiers) {
        $tierParts = @()
        foreach ($p in $x.SourceTiers.PSObject.Properties) {
            $tierParts += "$($p.Name):$($p.Value)"
        }
        $tiers = ($tierParts -join ', ')
    }

    $analysis = $null
    $codeForAnalysis = $x.Code
    if (-not $codeForAnalysis -or $codeForAnalysis -notmatch '^\d{6}$') {
        $resolved = Resolve-AStockCodeByName -Name $x.Name
        if ($resolved) {
            $codeForAnalysis = $resolved
            $x | Add-Member -NotePropertyName ResolvedCode -NotePropertyValue $resolved -Force
        }
    }

    if ($codeForAnalysis -and $codeForAnalysis -match '^\d{6}$') {
        $analysis = Get-AStockAnalysis -Code $codeForAnalysis
        $x | Add-Member -NotePropertyName Analysis -NotePropertyValue $analysis -Force
        $timing = Get-EntryTimingAdvice -Code $codeForAnalysis
        $x | Add-Member -NotePropertyName EntryTiming -NotePropertyValue $timing -Force
    }

    $rev = if ($analysis -and $null -ne $analysis.RevenueYoY) { "{0:N1}%" -f [double]$analysis.RevenueYoY } else { "--" }
    $prof = if ($analysis -and $null -ne $analysis.ProfitYoY) { "{0:N1}%" -f [double]$analysis.ProfitYoY } else { "--" }
    $rows += [PSCustomObject]@{
        Code        = if ($x.Code) { $x.Code } elseif ($x.ResolvedCode) { $x.ResolvedCode } else { '--' }
        Name        = $x.Name
        Strength    = $x.RelationStrength
        Confidence  = $x.Confidence
        Articles    = $x.ArticleCount
        Mentions    = $x.MentionCount
        WeightedEv  = $x.WeightedEvidence
        RevYoY      = $rev
        ProfitYoY   = $prof
        Tiers       = $tiers
        Relations   = $rel
    }
}

Write-Host ""
Write-Host "候选公司（按置信度排序）" -ForegroundColor Green
$rows | Format-Table -AutoSize | Out-Host

Write-Host ""
Write-Host "证据样例（每家公司最多2条）" -ForegroundColor Green
foreach ($x in $result.Results) {
    Write-Host ""
    $displayCode = if ($x.Code) { $x.Code } elseif ($x.ResolvedCode) { $x.ResolvedCode } else { '--' }
    Write-Host "[$displayCode] $($x.Name) 强度: $($x.RelationStrength) 置信度: $($x.Confidence)" -ForegroundColor Cyan
    if ($x.Analysis) {
        $revStr = if ($null -ne $x.Analysis.RevenueYoY) { "{0:N1}%" -f [double]$x.Analysis.RevenueYoY } else { "--" }
        $profStr = if ($null -ne $x.Analysis.ProfitYoY) { "{0:N1}%" -f [double]$x.Analysis.ProfitYoY } else { "--" }
        $peStr = if ($null -ne $x.Analysis.PE_TTM) { "{0:N2}" -f [double]$x.Analysis.PE_TTM } else { "--" }
        $pbStr = if ($null -ne $x.Analysis.PB) { "{0:N2}" -f [double]$x.Analysis.PB } else { "--" }
        Write-Host "    财报: 营收YoY=$revStr 净利YoY=$profStr | 估值: PE(TTM)=$peStr PB=$pbStr" -ForegroundColor DarkGray
    }
    if ($x.EntryTiming) {
        Write-Host "    买点: $($x.EntryTiming.PrimaryWindow) | 备选: $($x.EntryTiming.SecondaryWindow)" -ForegroundColor Green
        Write-Host "    策略: $($x.EntryTiming.Action) | 资金: $($x.EntryTiming.FundFlowBias)" -ForegroundColor DarkGray
    }
    $evCount = 0
    foreach ($ev in $x.Evidence) {
        $evCount++
        if ($evCount -gt 2) { break }
        $src = if ($ev.Source) { $ev.Source } else { 'N/A' }
        Write-Host "  - $($ev.Title)" -ForegroundColor White
        $provider = if ($ev.Provider) { $ev.Provider } else { 'unknown' }
        Write-Host "    Source: $src  Provider: $provider  Tier: $($ev.SourceTier)" -ForegroundColor DarkGray
        if ($ev.Link) { Write-Host "    Link: $($ev.Link)" -ForegroundColor DarkGray }
    }
}

Write-Host ""
Write-Host "免责声明：该结果基于公开新闻文本匹配，仅供研究参考，不构成投资建议。" -ForegroundColor DarkYellow
