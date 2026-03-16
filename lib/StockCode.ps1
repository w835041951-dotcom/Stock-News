# ══════════════════════════════════════════════════════════════
# lib/StockCode.ps1 — 股票代码解析 + 主板过滤 (全脚本共享)
# ══════════════════════════════════════════════════════════════

function Resolve-StockCode {
    <#
    .SYNOPSIS 解析股票代码 → { Code, Prefix, Market, SecId }
    .PARAMETER InputCode
        支持 600519 / SH600519 / sz000001
    #>
    param([string]$InputCode)

    $raw = $InputCode.Trim().ToUpper()
    if ($raw -match '^(?:SH|SZ)(\d{6})$') {
        $code = $Matches[1]
    }
    elseif ($raw -match '^\d{6}$') {
        $code = $raw
    }
    else {
        throw "无效股票代码: $InputCode (请使用6位数字，如 600519 或 SH600519)"
    }

    if ($code -match '^6\d{5}$') {
        return [PSCustomObject]@{ Code = $code; Prefix = "SH"; Market = 1; SecId = "1.$code" }
    }
    elseif ($code -match '^[0-3]\d{5}$') {
        return [PSCustomObject]@{ Code = $code; Prefix = "SZ"; Market = 0; SecId = "0.$code" }
    }

    # 北交所等
    return [PSCustomObject]@{ Code = $code; Prefix = "SZ"; Market = 0; SecId = "0.$code" }
}

function Test-MainBoard {
    <#
    .SYNOPSIS 检查是否为A股主板+创业板（排除科创板688/北交所8）
    #>
    param([string]$Code)
    return ($Code -match '^(60[0-9]\d{3}|00[012]\d{3}|300\d{3})$')
}

# 全局常量：周期性行业关键词
$script:CyclicalKeywords = @(
    '化工','化肥','能源','石油','煤炭','有色','金属','钢铁',
    '矿业','农业','银行','保险','地产','建筑','水泥','航运','航空'
)

# 噪音概念板块过滤列表
$script:NoiseSectorPatterns = @(
    '昨日涨停', '昨日首板', '昨日连板', '今日涨停',
    '百元股', '破净股', '低价股', '高价股', '新股与次新股',
    '融资融券', '股权转让', '含可转债', '基金重仓',
    '社保重仓', 'QFII重仓', '机构重仓', '富时罗素',
    '标普道琼斯', 'MSCI中国', '沪股通', '深股通',
    '送转预期', '举牌', '壳资源', 'ST板块', '预盈预增', '预亏预减'
)
