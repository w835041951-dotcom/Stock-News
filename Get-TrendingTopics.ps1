<#
.SYNOPSIS
    全球热搜热点聚合（非财经类），先人一步发现市场机会
.DESCRIPTION
    从多个非财经网站获取实时热搜/热榜数据，帮助提前发现可能影响股市的社会热点。
    数据来源：
    - CN: 百度热搜、头条热榜
    - US: Google Trends US
    - JP: Google Trends JP
    - EU: Google Trends DE/GB/FR
.PARAMETER Action
    操作类型：
    - cn:  仅显示中国热搜（百度+头条）
    - us:  仅显示美国热搜（Google Trends US）
    - jp:  仅显示日本热搜（Google Trends JP）
    - eu:  仅显示欧洲热搜（Google Trends DE/GB/FR）
    - intl: 仅显示国际热搜（US+JP+EU）
    - all: 全部（默认）
.PARAMETER TopN
    每个来源显示前N条（默认15）
.PARAMETER Quiet
    静默模式，仅返回对象不输出格式化文本
.EXAMPLE
    .\Get-TrendingTopics.ps1
    .\Get-TrendingTopics.ps1 -Action cn
    .\Get-TrendingTopics.ps1 -Action us -TopN 20
    .\Get-TrendingTopics.ps1 -Action intl
#>
param(
    [ValidateSet("cn", "us", "jp", "eu", "intl", "all")]
    [string]$Action = "all",

    [int]$TopN = 15,

    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# ============================================================
# HTTP Helper
# ============================================================
function Invoke-WebRequest2 {
    param(
        [string]$Url,
        [string]$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        [int]$TimeoutSec = 15,
        [string]$ContentType = "application/json"
    )
    try {
        $headers = @{
            "User-Agent" = $UserAgent
            "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        }
        $resp = Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec
        return $resp
    } catch {
        return $null
    }
}

function Invoke-XmlRequest {
    param(
        [string]$Url,
        [int]$TimeoutSec = 15
    )
    try {
        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Accept"     = "application/xml, text/xml, */*"
        }
        # Invoke-WebRequest to get raw content, then parse as XML
        $resp = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing
        $content = $resp.Content
        # Parse XML
        $xml = [xml]$content
        return $xml
    } catch {
        return $null
    }
}

# ============================================================
# CN Source 1: Baidu Hot Search (百度热搜)
# ============================================================
function Get-BaiduHotSearch {
    param([int]$Top = 30)

    $url = "https://top.baidu.com/api/board?platform=wise&tab=realtime"
    $data = Invoke-WebRequest2 -Url $url
    if (-not $data -or -not $data.data) {
        return @()
    }

    $results = @()
    $cards = $data.data.cards
    if ($cards -and $cards.Count -gt 0) {
        $content = $cards[0].content
        if ($content -and $content.Count -gt 0) {
            $items = $content[0].content
            $rank = 0
            foreach ($item in $items) {
                $rank++
                if ($rank -gt $Top) { break }

                $tagLabel = ""
                if ($item.isTop) { $tagLabel = "TOP" }
                elseif ($item.hotTag -eq "1") { $tagLabel = "NEW" }
                elseif ($item.hotTag -eq "3") { $tagLabel = "HOT" }

                $results += [PSCustomObject]@{
                    Rank   = $rank
                    Title  = $item.word
                    Heat   = if ($item.hotScore) { $item.hotScore } else { "" }
                    Tag    = $tagLabel
                    Source = "Baidu"
                    Region = "CN"
                    Url    = $item.url
                }
            }
        }
    }
    return $results
}

# ============================================================
# CN Source 2: Toutiao Hot Board (头条热榜)
# ============================================================
function Get-ToutiaoHotBoard {
    param([int]$Top = 30)

    $url = "https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc"
    $data = Invoke-WebRequest2 -Url $url
    if (-not $data -or -not $data.data) {
        return @()
    }

    $results = @()
    $rank = 0
    foreach ($item in $data.data) {
        $rank++
        if ($rank -gt $Top) { break }

        $tagLabel = ""
        if ($item.Label -eq "new") { $tagLabel = "NEW" }
        elseif ($item.Label -eq "hot") { $tagLabel = "HOT" }
        elseif ($item.Label -eq "refuteRumors") { $tagLabel = "RUMOR" }

        $category = ""
        if ($item.InterestCategory -and $item.InterestCategory.Count -gt 0) {
            $category = ($item.InterestCategory -join ",")
        }

        $results += [PSCustomObject]@{
            Rank     = $rank
            Title    = $item.Title
            Heat     = if ($item.HotValue) { $item.HotValue } else { "" }
            Tag      = $tagLabel
            Category = $category
            Source   = "Toutiao"
            Region   = "CN"
            Url      = $item.Url
        }
    }
    return $results
}

# ============================================================
# International: Google Trends RSS
# ============================================================
function Get-GoogleTrends {
    param(
        [string]$GeoCode,
        [string]$RegionLabel,
        [int]$Top = 20
    )

    $url = "https://trends.google.com/trending/rss?geo=$GeoCode"
    $xml = Invoke-XmlRequest -Url $url
    if (-not $xml) {
        return @()
    }

    $ns = @{ ht = "https://trends.google.com/trending/rss" }
    $items = $xml.rss.channel.item

    $results = @()
    $rank = 0
    foreach ($item in $items) {
        $rank++
        if ($rank -gt $Top) { break }

        $title = $item.title
        $traffic = $item.GetElementsByTagName("ht:approx_traffic") | ForEach-Object { $_.InnerText }
        if (-not $traffic) {
            # Fallback: try direct namespace
            try { $traffic = $item.'approx_traffic' } catch { $traffic = "" }
        }

        # Get first news headline if available
        $newsTitle = ""
        $newsSource = ""
        $newsItems = $item.GetElementsByTagName("ht:news_item")
        if ($newsItems -and $newsItems.Count -gt 0) {
            $firstNews = $newsItems[0]
            $newsTitleNodes = $firstNews.GetElementsByTagName("ht:news_item_title")
            if ($newsTitleNodes.Count -gt 0) { $newsTitle = $newsTitleNodes[0].InnerText }
            $newsSourceNodes = $firstNews.GetElementsByTagName("ht:news_item_source")
            if ($newsSourceNodes.Count -gt 0) { $newsSource = $newsSourceNodes[0].InnerText }
        }

        $results += [PSCustomObject]@{
            Rank       = $rank
            Title      = $title
            Traffic    = $traffic
            NewsTitle  = $newsTitle
            NewsSource = $newsSource
            Source     = "Google"
            Region     = $RegionLabel
        }
    }
    return $results
}

# ============================================================
# Formatted Output Functions
# ============================================================
function Write-SectionHeader {
    param([string]$Text, [string]$Emoji = "=")
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
}

function Show-BaiduResults {
    param($Items, [int]$Top = 15)
    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host "  (No data)" -ForegroundColor DarkGray
        return
    }
    $display = $Items | Select-Object -First $Top
    foreach ($item in $display) {
        $rankStr = "{0,3}" -f $item.Rank
        $tagStr = if ($item.Tag) { " [$($item.Tag)]" } else { "" }
        $color = switch ($item.Tag) {
            "TOP" { "Red" }
            "HOT" { "Yellow" }
            "NEW" { "Green" }
            default { "White" }
        }
        Write-Host "  $rankStr. " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($item.Title)" -NoNewline -ForegroundColor $color
        Write-Host "$tagStr" -ForegroundColor DarkYellow
    }
}

function Show-ToutiaoResults {
    param($Items, [int]$Top = 15)
    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host "  (No data)" -ForegroundColor DarkGray
        return
    }
    $display = $Items | Select-Object -First $Top
    foreach ($item in $display) {
        $rankStr = "{0,3}" -f $item.Rank
        $tagStr = if ($item.Tag) { " [$($item.Tag)]" } else { "" }
        $catStr = if ($item.Category) { " ($($item.Category))" } else { "" }
        $heatStr = if ($item.Heat) { " [{0:N0}]" -f [double]$item.Heat } else { "" }
        $color = switch ($item.Tag) {
            "HOT" { "Yellow" }
            "NEW" { "Green" }
            default { "White" }
        }
        Write-Host "  $rankStr. " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($item.Title)" -NoNewline -ForegroundColor $color
        Write-Host "$tagStr$catStr" -ForegroundColor DarkYellow
    }
}

function Show-GoogleResults {
    param($Items, [string]$RegionLabel, [int]$Top = 15)
    if (-not $Items -or $Items.Count -eq 0) {
        Write-Host "  (No data)" -ForegroundColor DarkGray
        return
    }
    $display = $Items | Select-Object -First $Top
    foreach ($item in $display) {
        $rankStr = "{0,3}" -f $item.Rank
        $trafficStr = if ($item.Traffic) { " [~$($item.Traffic) searches]" } else { "" }
        $newsStr = ""
        if ($item.NewsTitle) {
            $truncTitle = if ($item.NewsTitle.Length -gt 60) { $item.NewsTitle.Substring(0,60) + "..." } else { $item.NewsTitle }
            $newsStr = "`n       -> $truncTitle"
            if ($item.NewsSource) { $newsStr += " ($($item.NewsSource))" }
        }
        Write-Host "  $rankStr. " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($item.Title)" -NoNewline -ForegroundColor White
        Write-Host "$trafficStr" -ForegroundColor DarkYellow
        if ($newsStr) {
            Write-Host "$newsStr" -ForegroundColor DarkGray
        }
    }
}

# ============================================================
# Main Entry
# ============================================================
$allResults = @{}

$showCN   = $Action -in @("cn", "all")
$showUS   = $Action -in @("us", "intl", "all")
$showJP   = $Action -in @("jp", "intl", "all")
$showEU   = $Action -in @("eu", "intl", "all")

# --- CN sources ---
if ($showCN) {
    $baidu   = Get-BaiduHotSearch -Top ($TopN + 5)
    $toutiao = Get-ToutiaoHotBoard -Top ($TopN + 5)
    $allResults["Baidu"]   = $baidu
    $allResults["Toutiao"] = $toutiao
}

# --- US source ---
if ($showUS) {
    $googleUS = Get-GoogleTrends -GeoCode "US" -RegionLabel "US" -Top $TopN
    $allResults["Google_US"] = $googleUS
}

# --- JP source ---
if ($showJP) {
    $googleJP = Get-GoogleTrends -GeoCode "JP" -RegionLabel "JP" -Top $TopN
    $allResults["Google_JP"] = $googleJP
}

# --- EU sources ---
if ($showEU) {
    $googleDE = Get-GoogleTrends -GeoCode "DE" -RegionLabel "DE" -Top $TopN
    $googleGB = Get-GoogleTrends -GeoCode "GB" -RegionLabel "GB" -Top $TopN
    $googleFR = Get-GoogleTrends -GeoCode "FR" -RegionLabel "FR" -Top $TopN
    $allResults["Google_DE"] = $googleDE
    $allResults["Google_GB"] = $googleGB
    $allResults["Google_FR"] = $googleFR
}

# --- Quiet mode: return raw objects ---
if ($Quiet) {
    return $allResults
}

# --- Formatted output ---
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
Write-Host ""
Write-Host "  Global Trending Topics - $timestamp" -ForegroundColor Magenta
Write-Host "  Data from non-financial sources for early market signal detection" -ForegroundColor DarkGray

if ($showCN) {
    Write-SectionHeader "Baidu Hot Search (百度热搜) - CN"
    Show-BaiduResults -Items $allResults["Baidu"] -Top $TopN

    Write-SectionHeader "Toutiao Hot Board (头条热榜) - CN"
    Show-ToutiaoResults -Items $allResults["Toutiao"] -Top $TopN
}

if ($showUS) {
    Write-SectionHeader "Google Trends - United States (US)"
    Show-GoogleResults -Items $allResults["Google_US"] -RegionLabel "US" -Top $TopN
}

if ($showJP) {
    Write-SectionHeader "Google Trends - Japan (JP)"
    Show-GoogleResults -Items $allResults["Google_JP"] -RegionLabel "JP" -Top $TopN
}

if ($showEU) {
    Write-SectionHeader "Google Trends - Germany (DE)"
    Show-GoogleResults -Items $allResults["Google_DE"] -RegionLabel "DE" -Top $TopN

    Write-SectionHeader "Google Trends - United Kingdom (GB)"
    Show-GoogleResults -Items $allResults["Google_GB"] -RegionLabel "GB" -Top $TopN

    Write-SectionHeader "Google Trends - France (FR)"
    Show-GoogleResults -Items $allResults["Google_FR"] -RegionLabel "FR" -Top $TopN
}

Write-Host ""
Write-Host "  * Non-financial trending data for early signal detection, not investment advice." -ForegroundColor DarkGray
Write-Host "  * Sources: Baidu, Toutiao, Google Trends (US/JP/DE/GB/FR)" -ForegroundColor DarkGray
Write-Host ""
