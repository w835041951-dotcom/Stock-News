<#
.SYNOPSIS
    美股强势 → 关联A股映射（内置主题字典，快速无网络依赖）
.DESCRIPTION
    1. 从 Yahoo Finance 获取当日美股强势股（day_gainers screener）
    2. 东方财富美股数据作为备用数据源
    3. 按内置 Ticker→Theme 字典将美股分类到 18 个行业主题
    4. 按 Theme→A-stock 字典查找关联A股主板候选
    5. 逐只获取A股财报 + CAPE 估值（含缓存加速）
    可选 -UseWebSearch 使用 Get-PartnerStocks.ps1 做更深层关联搜索
.PARAMETER TopUS
    取前N只强势美股（默认8）
.PARAMETER TopA
    每个主题最多保留N只A股候选（默认5）
.PARAMETER Days
    Web搜索模式下关联新闻回溯天数（默认90）
.PARAMETER WebSources
    Web搜索来源（逗号分隔，默认 google,bing）
.PARAMETER UseWebSearch
    使用 Get-PartnerStocks.ps1 做深度关联搜索（慢，默认关闭）
.PARAMETER Quiet
    静默模式，仅返回对象
.EXAMPLE
    .\Get-USStrongAStocks.ps1
    .\Get-USStrongAStocks.ps1 -TopUS 12 -TopA 6
    .\Get-USStrongAStocks.ps1 -UseWebSearch
#>
param(
    [int]$TopUS = 8,
    [int]$TopA  = 5,
    [int]$Days  = 90,
    [string]$WebSources = 'google,bing',
    [switch]$UseWebSearch,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# ── Cache helpers ─────────────────────────────────────────────
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

# ── Helpers ──────────────────────────────────────────────────
function Invoke-Api {
    param([string]$Uri, [string]$Referer = "https://finance.yahoo.com/")
    try {
        $resp = Invoke-RestMethod -Uri $Uri -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Referer"    = $Referer
        } -TimeoutSec 20
        return $resp
    } catch { return $null }
}

function Get-DisplayWidth {
    param([string]$s)
    $w = 0; foreach ($c in $s.ToCharArray()) { if ([int]$c -gt 0x2E80) { $w += 2 } else { $w += 1 } }; return $w
}
function PadR { param([string]$s, [int]$width); return $s + (" " * [Math]::Max(0, $width - (Get-DisplayWidth $s))) }
function PadL { param([string]$s, [int]$width); return (" " * [Math]::Max(0, $width - (Get-DisplayWidth $s))) + $s }

function Get-AStockValuation {
    param([string]$Code, [bool]$IsCyclical = $false)
    # Check cache first (valuation is expensive — cache for 4 hours)
    $cacheKey = "val_$Code"
    $cached = Get-CachedData -Key $cacheKey -MaxAgeMinutes 240
    if ($cached) { return $cached }

    $detailScript = Join-Path $PSScriptRoot 'Get-StockDetail.ps1'
    $v = [ordered]@{ PE_TTM = $null; PB = $null; CapeNominal = $null; CapeLevel = $null }
    try {
        if (Test-Path $detailScript) {
            $d = & $detailScript -Code $Code -Action valuation -Quiet -ErrorAction SilentlyContinue
            if ($d) { $v.PE_TTM = $d.PE_TTM; $v.PB = $d.PB }
        }
    } catch {}
    # 只有周期股才计算 CAPE
    if ($IsCyclical) {
        $capeScript = Join-Path $PSScriptRoot 'Get-CapeValuation.ps1'
        try {
            if (Test-Path $capeScript) {
                $c = & $capeScript -Code $Code -Years 10 -Quiet -ErrorAction SilentlyContinue
                if ($c) { $v.CapeNominal = $c.NominalCAPE; $v.CapeLevel = $c.CapeLevel }
            }
        } catch {}
    }
    $result = [PSCustomObject]$v
    Set-CachedData -Key $cacheKey -Value $result
    return $result
}

function Get-EntryTimingAdvice {
    param([string]$Code)

    $cacheKey = "entry_$Code"
    $cached = Get-CachedData -Key $cacheKey -MaxAgeMinutes 15
    if ($cached) { return $cached }

    $timingScript = Join-Path $PSScriptRoot 'Get-EntryTiming.ps1'
    if (-not (Test-Path $timingScript)) { return $null }

    try {
        $timing = & $timingScript -Code $Code -Quiet -ErrorAction SilentlyContinue
        if ($timing) { Set-CachedData -Key $cacheKey -Value $timing }
        return $timing
    } catch {
        return $null
    }
}

# ── US Ticker → Theme Dictionary ─────────────────────────────
$USTickerTheme = @{
    # AI / 半导体
    NVDA='AI'; AMD='AI'; INTC='AI'; AVGO='AI'; QCOM='AI'; MU='AI'; MRVL='AI'; ARM='AI'
    TSM='AI'; ASML='AI'; LRCX='AI'; AMAT='AI'; KLAC='AI'; ON='AI'; MPWR='AI'; SMCI='AI'
    MSFT='AI'; GOOGL='AI'; GOOG='AI'; META='AI'; CRM='AI'; PLTR='AI'; AI='AI'
    DELL='AI'; HPE='AI'; CDNS='AI'; SNPS='AI'; MCHP='AI'; TXN='AI'
    NXPI='AI'; SWKS='AI'; QRVO='AI'; CEVA='AI'; SITM='AI'; AXTI='AI'
    # 新能源 / EV
    TSLA='EV'; NIO='EV'; XPEV='EV'; LI='EV'; RIVN='EV'; LCID='EV'; F='EV'; GM='EV'
    ENPH='EV'; SEDG='EV'; FSLR='EV'; RUN='EV'; PLUG='EV'; BE='EV'; BLDP='EV'
    ALB='EV'; SQM='EV'; LAC='EV'; LTHM='EV'; PLL='EV'; CHPT='EV'; BLNK='EV'
    POWI='EV'; STEM='EV'; ARRY='EV'; NOVA='EV'; SPWR='EV'
    # 医药 / 生物科技
    LLY='PHARMA'; NVO='PHARMA'; JNJ='PHARMA'; PFE='PHARMA'; MRK='PHARMA'; ABBV='PHARMA'
    BMY='PHARMA'; AMGN='PHARMA'; GILD='PHARMA'; REGN='PHARMA'; VRTX='PHARMA'; MRNA='PHARMA'
    BIIB='PHARMA'; AZN='PHARMA'; SNY='PHARMA'; BNTX='PHARMA'; BGNE='PHARMA'; ILMN='PHARMA'
    RGEN='PHARMA'; HALO='PHARMA'; INSM='PHARMA'; LEGN='PHARMA'; RXRX='PHARMA'
    # 消费 / 零售
    AAPL='CONSUMER'; WMT='CONSUMER'; COST='CONSUMER'; NKE='CONSUMER'; SBUX='CONSUMER'
    MCD='CONSUMER'; PG='CONSUMER'; KO='CONSUMER'; PEP='CONSUMER'; EL='CONSUMER'
    LULU='CONSUMER'; TGT='CONSUMER'; DG='CONSUMER'; AMZN='CONSUMER'; HD='CONSUMER'
    LOW='CONSUMER'; YUM='CONSUMER'; QSR='CONSUMER'; DLTR='CONSUMER'; FIVE='CONSUMER'
    # 金融
    JPM='FINANCE'; BAC='FINANCE'; GS='FINANCE'; MS='FINANCE'; C='FINANCE'; WFC='FINANCE'
    BLK='FINANCE'; SCHW='FINANCE'; AXP='FINANCE'; V='FINANCE'; MA='FINANCE'
    COF='FINANCE'; DFS='FINANCE'; SPGI='FINANCE'; MCO='FINANCE'; ICE='FINANCE'
    PYPL='FINANCE'; SQ='FINANCE'; HOOD='FINANCE'; SOFI='FINANCE'
    # 能源 / 石油
    XOM='ENERGY'; CVX='ENERGY'; COP='ENERGY'; EOG='ENERGY'; SLB='ENERGY'; OXY='ENERGY'
    VLO='ENERGY'; MPC='ENERGY'; PSX='ENERGY'; HAL='ENERGY'; DVN='ENERGY'; FANG='ENERGY'
    WMB='ENERGY'; KMI='ENERGY'; LNG='ENERGY'
    # 化工 / 化肥
    MOS='CHEMICAL'; NTR='CHEMICAL'; CF='CHEMICAL'; IPI='CHEMICAL'; ICL='CHEMICAL'
    DOW='CHEMICAL'; DD='CHEMICAL'; LYB='CHEMICAL'; EMN='CHEMICAL'; CE='CHEMICAL'
    CTVA='CHEMICAL'; FMC='CHEMICAL'; APD='CHEMICAL'; LIN='CHEMICAL'; PPG='CHEMICAL'
    # 有色金属 / 矿业
    FCX='METAL'; NEM='METAL'; GOLD='METAL'; AEM='METAL'; WPM='METAL'; RGLD='METAL'
    AA='METAL'; X='METAL'; CLF='METAL'; NUE='METAL'; STLD='METAL'; VALE='METAL'
    BHP='METAL'; RIO='METAL'; SCCO='METAL'; TECK='METAL'; MP='METAL'; HL='METAL'
    CTRA='METAL'; APA='METAL'
    # 军工 / 航天
    LMT='DEFENSE'; RTX='DEFENSE'; NOC='DEFENSE'; BA='DEFENSE'; GD='DEFENSE'
    HII='DEFENSE'; LHX='DEFENSE'; TDG='DEFENSE'; HEI='DEFENSE'; KTOS='DEFENSE'
    AXON='DEFENSE'; LDOS='DEFENSE'; SAIC='DEFENSE'; CACI='DEFENSE'
    # 云计算 / SaaS / 网络安全
    SNOW='CLOUD'; DDOG='CLOUD'; NET='CLOUD'; ZS='CLOUD'; CRWD='CLOUD'; PANW='CLOUD'
    FTNT='CLOUD'; NOW='CLOUD'; WDAY='CLOUD'; ORCL='CLOUD'; IBM='CLOUD'; MDB='CLOUD'
    TEAM='CLOUD'; HUBS='CLOUD'; OKTA='CLOUD'; S='CLOUD'; CYBR='CLOUD'; TENB='CLOUD'
    QLYS='CLOUD'; HPQ='CLOUD'; SAP='CLOUD'; INTU='CLOUD'
    # 游戏 / 传媒
    NFLX='MEDIA'; DIS='MEDIA'; CMCSA='MEDIA'; WBD='MEDIA'; PARA='MEDIA'
    EA='MEDIA'; TTWO='MEDIA'; RBLX='MEDIA'; U='MEDIA'; SPOT='MEDIA'; SNAP='MEDIA'
    ROKU='MEDIA'; WMG='MEDIA'; LYV='MEDIA'
    # 地产 / REITs
    AMT='REALESTATE'; PLD='REALESTATE'; EQIX='REALESTATE'; SPG='REALESTATE'
    O='REALESTATE'; PSA='REALESTATE'; DLR='REALESTATE'; WELL='REALESTATE'
    LEN='REALESTATE'; DHI='REALESTATE'; TOL='REALESTATE'; NVR='REALESTATE'
    CSGP='REALESTATE'; Z='REALESTATE'
    # 交运 / 物流
    UPS='LOGISTICS'; FDX='LOGISTICS'; UNP='LOGISTICS'; CSX='LOGISTICS'
    DAL='LOGISTICS'; UAL='LOGISTICS'; LUV='LOGISTICS'; JBHT='LOGISTICS'
    CHRW='LOGISTICS'; XPO='LOGISTICS'; SAIA='LOGISTICS'; ODFL='LOGISTICS'
    EXPD='LOGISTICS'; GXO='LOGISTICS'
    # 农业 / 食品
    ADM='AGRI'; BG='AGRI'; INGR='AGRI'; DAR='AGRI'; TSN='AGRI'; HRL='AGRI'; CAG='AGRI'
    SFM='AGRI'; CALM='AGRI'; VITL='AGRI'; HZNP='AGRI'; BRFS='AGRI'
    # 电力 / 公用
    NEE='UTILITY'; DUK='UTILITY'; SO='UTILITY'; AEP='UTILITY'; D='UTILITY'
    EXC='UTILITY'; SRE='UTILITY'; PCG='UTILITY'; CEG='UTILITY'; VST='UTILITY'
    ETR='UTILITY'; FE='UTILITY'; AES='UTILITY'; PPL='UTILITY'; EIX='UTILITY'
    # 机器人 / 人形机器人 / 自动化
    ISRG='ROBOT'; HON='ROBOT'; ROK='ROBOT'; IRBT='ROBOT'; CGNX='ROBOT'
    BRKS='ROBOT'; NVST='ROBOT'; PTC='ROBOT'; ENTG='ROBOT'
    ABB='ROBOT'; FANUC='ROBOT'; KEYB='ROBOT'; TER='ROBOT'; NATI='ROBOT'
    # 生物技术 CRO / CDMO
    IQV='BIOTECH'; CRL='BIOTECH'; MEDP='BIOTECH'; ICLR='BIOTECH'
    SYNH='BIOTECH'; CTLT='BIOTECH'; PPD='BIOTECH'; DOCS='BIOTECH'; ACCD='BIOTECH'
    # 半导体设备 / 国内制造相关
    ONTO='CHIPEQUIP'; ACLS='CHIPEQUIP'; COHU='CHIPEQUIP'; UCTT='CHIPEQUIP'
    CAMT='CHIPEQUIP'; FORM='CHIPEQUIP'; ICHR='CHIPEQUIP'; MKSI='CHIPEQUIP'
}
# 含连字符的特殊ticker需单独赋值
$USTickerTheme['BRK-B'] = 'FINANCE'

# ── Name-based fallback theme classification ─────────────────
$NameKeywords = @(
    @{ Theme='AI';         Pattern='semicon|chip|nvidia|amd|intel|micro|silicon|ai\b|robot.?ai|gpu' }
    @{ Theme='EV';         Pattern='tesla|electric.?vehic|ev\b|lithium|battery|solar|hydrogen|clean.?energy|renewable' }
    @{ Theme='PHARMA';     Pattern='pharm|biotech|thera|medical|drug|oncol|vaccine|health' }
    @{ Theme='CONSUMER';   Pattern='retail|consumer|brand|food|bever|apparel|luxury|store|shop' }
    @{ Theme='FINANCE';    Pattern='bank|financ|invest|insur|capital|asset|credit|pay' }
    @{ Theme='ENERGY';     Pattern='oil|gas|petro|energy|crude|drill|refin|lng|pipeline' }
    @{ Theme='CHEMICAL';   Pattern='chem|fertil|potash|nitro|phosph|polymer|plastic|material' }
    @{ Theme='METAL';      Pattern='metal|gold|silver|copper|iron|steel|mining|alum|zinc|nickel|rare.?earth' }
    @{ Theme='DEFENSE';    Pattern='defense|aerospace|military|weapon|missil|lockheed|boeing' }
    @{ Theme='CLOUD';      Pattern='cloud|cyber|secur|saas|software|data|network' }
    @{ Theme='MEDIA';      Pattern='media|stream|game|entertain|film|music|content|studio' }
    @{ Theme='REALESTATE'; Pattern='reit|real.?estate|property|tower|homebuilder|housing' }
    @{ Theme='LOGISTICS';  Pattern='logist|freight|transport|airline|shipping|rail|truck|cargo' }
    @{ Theme='AGRI';       Pattern='agri|grain|soybean|corn|wheat|crop|farm|seed|livestock' }
    @{ Theme='UTILITY';    Pattern='utilit|electri|power|grid|nuclear|hydro|generat' }
    @{ Theme='ROBOT';      Pattern='robot|automat|cobotic|humanoid|manipulat|motion.?control|industri.?robot' }
    @{ Theme='BIOTECH';    Pattern='cro\b|contract.?research|clinical.?trial|biologics|biopharma|cdmo' }
    @{ Theme='CHIPEQUIP';  Pattern='semicond.?equip|wafer|etch|litho|fab.?equip|foundry.?tool|ic.?test' }
)

# ── Theme → A-stock candidates (mainboard only) ─────────────
$ThemeAStocks = @{
    AI         = @('603501','002049','002415','600745','002236','000063','002230','603986','002371','600584','600460','002241')
    EV         = @('002460','600438','000625','600733','002594','601633','600104','000338','002812','600406','002074','601127','002466')
    PHARMA     = @('600276','000538','002007','600196','002422','600085','000963','002252','600867','002001','600161','002589','600079')
    CONSUMER   = @('600519','000858','000568','002304','600887','000895','600600','002507','603288','002714','601888','600690','603605')
    FINANCE    = @('600036','601318','000001','601166','600030','601688','000776','601398','601628','601601','600000','601939','002916')
    ENERGY     = @('601857','600028','600585','601808','000983','601225','002221','000703','601899','600339','600011','002222')
    CHEMICAL   = @('600309','002539','000792','600096','002601','600141','002250','000830','600426','002223','600352','000422','601216')
    METAL      = @('601899','000630','601600','002460','600362','600489','000876','002155','600547','601003','000878','600219','603993')
    DEFENSE    = @('600893','000768','600760','601989','002013','600316','600150','000738','002414','600862','601952','000969')
    CLOUD      = @('002230','000977','002410','600845','000066','600588','002474','600570','002268','002065','300454','600271')
    MEDIA      = @('002602','600637','002027','600373','002624','000681','600556','600633','002607','000156','002292','003816')
    REALESTATE = @('001979','600048','000002','600383','000069','600340','601155','000031','600606','601969')
    LOGISTICS  = @('601006','600029','002120','600115','600009','000089','601111','600221','600233','002352','601258','000507')
    AGRI       = @('600598','000998','002311','600127','002234','601952','002299','000735','600359','000592','002041')
    UTILITY    = @('600900','600886','000027','600023','601985','600011','600025','600795','000875','601619','600795','002039')
    ROBOT      = @('300024','002527','002747','000425','002610','002009','601137','000333','002903','002891')
    BIOTECH    = @('300122','300759','002001','600276','300347','002727','300015','603218','300603','000963')
    CHIPEQUIP  = @('002049','600460','002230','600745','603501','002371','002179','688981','000063','603986')
}

$ThemeLabels = @{
    AI='AI/半导体';         EV='新能源/电车';       PHARMA='医药生物'
    CONSUMER='消费零售';    FINANCE='金融';         ENERGY='能源石油'
    CHEMICAL='化工化肥';    METAL='有色金属';       DEFENSE='军工航天'
    CLOUD='云计算/安全';    MEDIA='游戏传媒';       REALESTATE='地产'
    LOGISTICS='交运物流';   AGRI='农业食品';        UTILITY='电力公用'
    ROBOT='机器人/自动化';  BIOTECH='生物技术CRO';  CHIPEQUIP='半导体设备'
}

function Get-USTheme {
    param([string]$Symbol, [string]$Name)
    if ($USTickerTheme.ContainsKey($Symbol.ToUpper())) { return $USTickerTheme[$Symbol.ToUpper()] }
    foreach ($kw in $NameKeywords) {
        if ($Name -match $kw.Pattern) { return $kw.Theme }
    }
    return $null
}

# ══════════════════════════════════════════════════════════════
# STEP 1: 获取美股强势列表
# ══════════════════════════════════════════════════════════════

function Get-UsDayGainers {
    param([int]$Top = 8)

    # Primary: Yahoo screener API
    $url = "https://query1.finance.yahoo.com/v1/finance/screener/predefined/saved?formatted=true&scrIds=day_gainers&count=$($Top * 2)&start=0"
    $resp = Invoke-Api -Uri $url
    $quotes = @()
    if ($resp -and $resp.finance -and $resp.finance.result) {
        $quotes = @((($resp.finance.result)[0]).quotes)
    }

    # Fallback 1: batch quote of curated tickers
    if (-not $quotes -or $quotes.Count -eq 0) {
        $fallbackTickers = @('NVDA','AMD','TSLA','AAPL','MSFT','GOOGL','META','AMZN','AVGO','MU',
                             'LLY','NVO','MRK','XOM','CVX','MOS','NTR','CF','FCX','NEM',
                             'JPM','GS','LMT','RTX','NFLX','ISRG','HON','IQV','CRL','ONTO')
        $syms = $fallbackTickers -join ','
        $fbUrl = "https://query1.finance.yahoo.com/v7/finance/quote?symbols=$syms"
        $fbResp = Invoke-Api -Uri $fbUrl
        if ($fbResp -and $fbResp.quoteResponse -and $fbResp.quoteResponse.result) {
            $quotes = @($fbResp.quoteResponse.result | Where-Object {
                $null -ne $_.regularMarketChangePercent -and [double]$_.regularMarketChangePercent -gt 2
            })
        }
    }

    $rows = @()
    foreach ($q in $quotes) {
        $symbol = "$($q.symbol)"
        if (-not $symbol) { continue }

        $chgPct = $null
        if ($null -ne $q.regularMarketChangePercent) {
            $raw = $q.regularMarketChangePercent
            if ($raw -is [PSCustomObject] -and $null -ne $raw.raw) { $chgPct = [double]$raw.raw }
            else { $chgPct = [double]$raw }
        }

        $price = $null
        if ($null -ne $q.regularMarketPrice) {
            $rp = $q.regularMarketPrice
            if ($rp -is [PSCustomObject] -and $null -ne $rp.raw) { $price = $rp.raw }
            else { $price = $rp }
        }

        $rows += [PSCustomObject]@{
            Symbol    = $symbol
            Name      = if ($q.shortName) { "$($q.shortName)" } elseif ($q.longName) { "$($q.longName)" } else { $symbol }
            Price     = $price
            ChangePct = $chgPct
            Volume    = if ($q.regularMarketVolume) { $q.regularMarketVolume } else { $null }
            Exchange  = if ($q.fullExchangeName) { "$($q.fullExchangeName)" } else { "" }
        }
    }

    return @($rows | Sort-Object -Property ChangePct -Descending | Select-Object -First $Top)
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$W = 92

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("=" * $W) -ForegroundColor Cyan
    Write-Host "  美股强势 → 关联A股映射  $timestamp" -ForegroundColor White
    Write-Host ("=" * $W) -ForegroundColor Cyan
}

# ── Step 1: Fetch US gainers ──
if (-not $Quiet) { Write-Host "`n[1/4] 获取美股强势列表..." -ForegroundColor Yellow }

$usLeaders = Get-UsDayGainers -Top $TopUS

# Fallback 2: East Money US stock list (when Yahoo returns too few)
if ($usLeaders.Count -lt [Math]::Max(2, [int]($TopUS / 2))) {
    if (-not $Quiet) { Write-Host "  Yahoo数据不足，尝试东方财富美股数据..." -ForegroundColor DarkGray }
    # m:105=NYSE, m:106=NASDAQ, m:107=AMEX  fid=f3(涨跌幅)
    $emUsUrl = "https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=30&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=m:105,m:106,m:107&fields=f2,f3,f12,f14,f5"
    $emUsResp = Invoke-Api -Uri $emUsUrl -Referer "https://quote.eastmoney.com/"
    if ($emUsResp -and $emUsResp.data -and $emUsResp.data.diff) {
        $seen = @{}; foreach ($u in $usLeaders) { $seen[$u.Symbol.ToUpper()] = $true }
        $emRows = @()
        foreach ($item in $emUsResp.data.diff) {
            $sym = "$($item.f12)"
            if (-not $sym -or $seen.ContainsKey($sym.ToUpper())) { continue }
            $chg = [double]$item.f3
            if ($chg -lt 2) { continue }
            $rawPrice = [double]$item.f2
            # East Money US prices in fltt=2 mode are already float
            $emRows += [PSCustomObject]@{
                Symbol    = $sym
                Name      = "$($item.f14)"
                Price     = [Math]::Round($rawPrice, 2)
                ChangePct = [Math]::Round($chg, 2)
                Volume    = $item.f5
                Exchange  = "EastMoney"
            }
        }
        $needed = $TopUS - $usLeaders.Count
        $usLeaders = @($usLeaders) + @($emRows | Sort-Object ChangePct -Descending | Select-Object -First $needed)
    }
}

if (-not $usLeaders -or $usLeaders.Count -eq 0) {
    if (-not $Quiet) {
        Write-Host "  未获取到美股强势列表" -ForegroundColor Yellow
        Write-Host "`n  * 此为跨市场联动观察参考，不构成投资建议" -ForegroundColor DarkGray
    }
    if ($Quiet) { return [PSCustomObject]@{ USGainers = @(); Themes = @{}; AStocks = @() } }
    return
}

if (-not $Quiet) {
    Write-Host "  获取到 $($usLeaders.Count) 只强势美股" -ForegroundColor Green
    Write-Host ""
    $hdr = "    " + (PadR "Symbol" 8) + (PadR "Name" 26) + (PadL "Price" 10) + (PadL "Chg%" 9) + "  Exchange"
    Write-Host $hdr -ForegroundColor Cyan
    Write-Host ("    " + ("-" * 70)) -ForegroundColor DarkGray

    foreach ($u in $usLeaders) {
        $pStr = if ($null -ne $u.Price) { "{0:N2}" -f [double]$u.Price } else { "--" }
        $cStr = if ($null -ne $u.ChangePct) { "+{0:N2}%" -f [double]$u.ChangePct } else { "--" }
        Write-Host "    " -NoNewline
        Write-Host (PadR $u.Symbol 8) -NoNewline -ForegroundColor White
        Write-Host (PadR ($u.Name.Substring(0, [Math]::Min(24, $u.Name.Length))) 26) -NoNewline -ForegroundColor White
        Write-Host (PadL $pStr 10) -NoNewline -ForegroundColor White
        Write-Host (PadL $cStr 9) -NoNewline -ForegroundColor Red
        Write-Host "  $($u.Exchange)" -ForegroundColor DarkGray
    }
}

# ── Step 2: Classify themes + map A-stocks ──
if (-not $Quiet) { Write-Host "`n[2/4] 主题分类 + A股映射..." -ForegroundColor Yellow }

$themeGainers = @{}  # theme → list of US stocks
$unmapped = @()

foreach ($u in $usLeaders) {
    $theme = Get-USTheme -Symbol $u.Symbol -Name $u.Name
    if ($theme) {
        if (-not $themeGainers.ContainsKey($theme)) { $themeGainers[$theme] = @() }
        $themeGainers[$theme] += $u
    } else {
        $unmapped += $u
    }
}

if (-not $Quiet) {
    Write-Host "  主题映射: $($themeGainers.Count) 个主题, 未匹配 $($unmapped.Count) 只" -ForegroundColor Green
    foreach ($t in $themeGainers.Keys | Sort-Object) {
        $label = if ($ThemeLabels.ContainsKey($t)) { $ThemeLabels[$t] } else { $t }
        $syms = ($themeGainers[$t] | ForEach-Object { $_.Symbol }) -join ", "
        Write-Host "    $label  <- $syms" -ForegroundColor DarkGray
    }
}

# Collect A-stock candidates per theme
$allCandidates = @()

if ($UseWebSearch) {
    # Deep web search mode via Get-PartnerStocks.ps1
    $partnerScript = Join-Path $PSScriptRoot 'Get-PartnerStocks.ps1'
    if (Test-Path $partnerScript) {
        foreach ($u in $usLeaders) {
            if (-not $Quiet) { Write-Host "  Web搜索: $($u.Symbol)..." -ForegroundColor DarkGray }
            try {
                $mapped = & $partnerScript -Target $u.Symbol -TopN $TopA -Days $Days -Quiet -UseWebSearch $true -WebSources $WebSources
                if ($mapped -and $mapped.Results) {
                    foreach ($r in ($mapped.Results | Select-Object -First $TopA)) {
                        $code = if ($r.Code) { $r.Code } else { '' }
                        if ($code -and $code -match '^(60[0-9]\d{3}|00[012]\d{3})$') {
                            $allCandidates += [PSCustomObject]@{
                                Code = $code; Name = $r.Name; Theme = (Get-USTheme -Symbol $u.Symbol -Name $u.Name)
                                USSource = $u.Symbol; Confidence = $r.Confidence
                            }
                        }
                    }
                }
            } catch {}
        }
    }
} else {
    # Fast built-in dictionary mode (default)
    $seen = @{}
    foreach ($theme in $themeGainers.Keys) {
        $aCodes = $ThemeAStocks[$theme]
        if (-not $aCodes) { continue }
        # Keep only mainboard
        $mainboard = @($aCodes | Where-Object { $_ -match '^(60[0-9]\d{3}|00[012]\d{3}|300\d{3})$' })
        $usSyms = ($themeGainers[$theme] | ForEach-Object { $_.Symbol }) -join "/"
        foreach ($code in ($mainboard | Select-Object -First ($TopA * 2))) {
            if ($seen.ContainsKey($code)) { continue }
            $seen[$code] = $true
            $allCandidates += [PSCustomObject]@{
                Code = $code; Name = ''; Theme = $theme; USSource = $usSyms; Confidence = $null
            }
        }
    }
}

if (-not $Quiet) { Write-Host "  A股候选: $($allCandidates.Count) 只" -ForegroundColor Green }

# ── Step 3: Fetch A-stock details (with caching) ──
if (-not $Quiet) { Write-Host "`n[3/4] 获取A股财报数据..." -ForegroundColor Yellow }

$detailScript = Join-Path $PSScriptRoot 'Get-StockDetail.ps1'
$enriched = @()
$idx = 0

foreach ($cand in $allCandidates) {
    $idx++
    if (-not $Quiet -and $idx % 5 -eq 0) { Write-Host "  进度: $idx / $($allCandidates.Count)" -ForegroundColor DarkGray }

    # Check financial report cache first
    $finCacheKey = "detail_$($cand.Code)"
    $cachedDetail = Get-CachedData -Key $finCacheKey -MaxAgeMinutes 360
    $d = $null

    if ($cachedDetail) {
        $d = $cachedDetail
    } else {
        try {
            $d = & $detailScript -Code $cand.Code -Action all -Quiet -ErrorAction SilentlyContinue
            if ($d) { Set-CachedData -Key $finCacheKey -Value $d }
        } catch {}
    }

    if ($d) {
        $rep = if ($d.Reports -and $d.Reports.Count -gt 0) { $d.Reports[0] } else { $null }
        $cand.Name = if ($d.Name) { $d.Name } else { $cand.Code }
        $enriched += [PSCustomObject]@{
            Code       = $cand.Code
            Name       = $cand.Name
            Theme      = $cand.Theme
            USSource   = $cand.USSource
            Price      = $d.Price
            Week1Chg   = $d.Week1Change
            Month1Chg  = $d.Month1Change
            PE_TTM     = $d.PE_TTM
            PB         = $d.PB
            RevYoY     = if ($rep) { $rep.RevenueYoY } else { $null }
            ProfitYoY  = if ($rep) { $rep.NetProfitYoY } else { $null }
            ROE        = if ($rep) { $rep.ROE } else { $null }
            ReportName = if ($rep) { $rep.ReportName } else { $null }
            Valuation  = $null
            EntryTiming = $null
        }
    }
}

if (-not $Quiet) { Write-Host "  成功获取 $($enriched.Count) 只A股数据" -ForegroundColor Green }

# ── Step 4: CAPE valuation (with caching) ──
if (-not $Quiet) { Write-Host "`n[4/4] CAPE 估值（缓存加速）..." -ForegroundColor Yellow }

$valIdx = 0
foreach ($stk in $enriched) {
    $valIdx++
    if (-not $Quiet -and $valIdx % 3 -eq 0) { Write-Host "  估值: $valIdx / $($enriched.Count)" -ForegroundColor DarkGray }
    $cyclicalThemesVal = @('CHEMICAL','METAL','ENERGY','AGRI','FINANCE','REALESTATE','LOGISTICS')
    $stk.Valuation = Get-AStockValuation -Code $stk.Code -IsCyclical ($cyclicalThemesVal -contains $stk.Theme)
}

if (-not $Quiet) { Write-Host "  估值完成" -ForegroundColor Green }

if (-not $Quiet) { Write-Host "  正在补充日内买点建议..." -ForegroundColor DarkGray }
foreach ($stk in $enriched) {
    $stk.EntryTiming = Get-EntryTimingAdvice -Code $stk.Code
}

# ══════════════════════════════════════════════════════════════
# FINAL OUTPUT
# ══════════════════════════════════════════════════════════════

if ($Quiet) {
    return [PSCustomObject]@{
        USGainers   = $usLeaders
        Themes      = $themeGainers
        AStocks     = $enriched
        ThemeLabels = $ThemeLabels
        Unmapped    = $unmapped
    }
}

Write-Host ""
Write-Host ("═" * $W) -ForegroundColor Cyan
Write-Host "  关联A股候选 — 按主题分组" -ForegroundColor Yellow
Write-Host ("═" * $W) -ForegroundColor Cyan

foreach ($theme in ($themeGainers.Keys | Sort-Object)) {
    $label = if ($ThemeLabels.ContainsKey($theme)) { $ThemeLabels[$theme] } else { $theme }
    $usSyms = ($themeGainers[$theme] | ForEach-Object { $_.Symbol }) -join ", "
    $themeStocks = @($enriched | Where-Object { $_.Theme -eq $theme } | Select-Object -First $TopA)

    if ($themeStocks.Count -eq 0) { continue }

    Write-Host ""
    Write-Host "  [$label]  <- $usSyms" -ForegroundColor Cyan
    Write-Host "  买点: 默认按分时+主力资金给出主时窗" -ForegroundColor DarkGray

    $hdr = "    " + (PadR "代码" 10) + (PadR "名称" 10) + (PadL "价格" 9) + (PadL "周涨跌" 9) + (PadL "月涨跌" 9) + (PadL "营收增长" 10) + (PadL "净利增长" 10) + (PadL "ROE" 8) + (PadL "PE" 8) + (PadL "估值" 8)
    # 周期性主题用CAPE，非周期主题用PB
    $cyclicalThemes = @('CHEMICAL','METAL','ENERGY','AGRI','FINANCE','REALESTATE','LOGISTICS')
    $themeIsCyclical = $cyclicalThemes -contains $theme
    Write-Host $hdr -ForegroundColor DarkCyan
    Write-Host ("    " + ("-" * 95)) -ForegroundColor DarkGray

    foreach ($stk in $themeStocks) {
        $priceStr = if ($null -ne $stk.Price) { "{0:N2}" -f [double]$stk.Price } else { "N/A" }
        $weekStr  = if ($null -ne $stk.Week1Chg) { "{0:N2}%" -f [double]$stk.Week1Chg } else { "N/A" }
        $monthStr = if ($null -ne $stk.Month1Chg) { "{0:N2}%" -f [double]$stk.Month1Chg } else { "N/A" }
        $revStr   = if ($null -ne $stk.RevYoY) { "{0:N1}%" -f [double]$stk.RevYoY } else { "N/A" }
        $profStr  = if ($null -ne $stk.ProfitYoY) { "{0:N1}%" -f [double]$stk.ProfitYoY } else { "N/A" }
        $roeStr   = if ($null -ne $stk.ROE) { "{0:N1}%" -f [double]$stk.ROE } else { "N/A" }
        $peStr    = if ($null -ne $stk.PE_TTM) { "{0:N1}" -f [double]$stk.PE_TTM } else { "N/A" }
        $valStr   = if ($themeIsCyclical) {
            if ($stk.Valuation -and $null -ne $stk.Valuation.CapeNominal) { "C:{0:N1}" -f [double]$stk.Valuation.CapeNominal } else { "C:N/A" }
        } else {
            if ($stk.Valuation -and $null -ne $stk.Valuation.PB) { "B:{0:N1}" -f [double]$stk.Valuation.PB } else { "B:N/A" }
        }

        $weekColor  = if ($null -ne $stk.Week1Chg -and $stk.Week1Chg -lt 0) { "Green" } else { "Red" }
        $monthColor = if ($null -ne $stk.Month1Chg -and $stk.Month1Chg -lt 0) { "Green" } else { "Red" }
        $revColor   = if ($null -ne $stk.RevYoY -and $stk.RevYoY -gt 0) { "Red" } else { "Green" }
        $profColor  = if ($null -ne $stk.ProfitYoY -and $stk.ProfitYoY -gt 0) { "Red" } else { "Green" }

        Write-Host "    " -NoNewline
        Write-Host (PadR $stk.Code 10) -NoNewline -ForegroundColor White
        Write-Host (PadR $stk.Name 10) -NoNewline -ForegroundColor White
        Write-Host (PadL $priceStr 9) -NoNewline -ForegroundColor White
        Write-Host (PadL $weekStr 9) -NoNewline -ForegroundColor $weekColor
        Write-Host (PadL $monthStr 9) -NoNewline -ForegroundColor $monthColor
        Write-Host (PadL $revStr 10) -NoNewline -ForegroundColor $revColor
        Write-Host (PadL $profStr 10) -NoNewline -ForegroundColor $profColor
        Write-Host (PadL $roeStr 8) -NoNewline -ForegroundColor Yellow
        Write-Host (PadL $peStr 8) -NoNewline -ForegroundColor White
        Write-Host (PadL $valStr 8) -ForegroundColor Cyan

        if ($stk.EntryTiming) {
            Write-Host "      " -NoNewline -ForegroundColor DarkGray
            Write-Host ("买点 {0}" -f $stk.EntryTiming.PrimaryWindow) -NoNewline -ForegroundColor Green
            Write-Host (" | 备选 {0}" -f $stk.EntryTiming.SecondaryWindow) -NoNewline -ForegroundColor DarkGray
            Write-Host (" | {0}" -f $stk.EntryTiming.Action) -NoNewline -ForegroundColor White
            Write-Host (" | 资金: {0}" -f $stk.EntryTiming.FundFlowBias) -ForegroundColor DarkGray
        }
    }
}

if ($unmapped.Count -gt 0) {
    Write-Host ""
    Write-Host "  [未匹配主题]" -ForegroundColor DarkGray
    foreach ($u in $unmapped) {
        Write-Host "    $($u.Symbol)  $($u.Name)  +$("{0:N2}%" -f [double]$u.ChangePct)" -ForegroundColor DarkGray
    }
}

# ── Footer ──
Write-Host ""
Write-Host ("─" * $W) -ForegroundColor DarkGray
Write-Host "  美股强势 $($usLeaders.Count) 只 → 主题 $($themeGainers.Count) 个 → A股候选 $($enriched.Count) 只" -ForegroundColor DarkGray
Write-Host "  模式: $(if ($UseWebSearch) { 'Web搜索 (Get-PartnerStocks)' } else { '内置字典 (快速)' })" -ForegroundColor DarkGray
Write-Host "  主题数: 18个 (含机器人/生물技术CRO/半导体设备)" -ForegroundColor DarkGray
Write-Host "  推荐输出默认附带日内买点时窗" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  * 数据来源: Yahoo Finance / 东方财富 / Akshare" -ForegroundColor DarkGray
Write-Host "  * 此为跨市场联动观察参考，不构成投资建议" -ForegroundColor DarkGray
Write-Host ""
