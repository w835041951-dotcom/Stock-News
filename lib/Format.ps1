# ══════════════════════════════════════════════════════════════
# lib/Format.ps1 — 显示格式化 (全脚本共享)
# ══════════════════════════════════════════════════════════════

function Format-LargeNumber {
    param([double]$Value)
    if ([Math]::Abs($Value) -ge 1e8) { return "{0:N2}亿" -f ($Value / 1e8) }
    elseif ([Math]::Abs($Value) -ge 1e4) { return "{0:N2}万" -f ($Value / 1e4) }
    else { return "{0:N2}" -f $Value }
}

function Format-Percent {
    param([object]$Value, [switch]$WithSign)
    if ($null -eq $Value) { return "N/A" }
    $v = [double]$Value
    if ($WithSign -and $v -gt 0) { return "+{0:N2}%" -f $v }
    return "{0:N2}%" -f $v
}

function Get-DisplayWidth {
    param([string]$s)
    $w = 0; foreach ($c in $s.ToCharArray()) { if ([int]$c -gt 0x2E80) { $w += 2 } else { $w += 1 } }; return $w
}

function PadR {
    param([string]$s, [int]$width)
    return $s + (" " * [Math]::Max(0, $width - (Get-DisplayWidth $s)))
}

function PadL {
    param([string]$s, [int]$width)
    return (" " * [Math]::Max(0, $width - (Get-DisplayWidth $s))) + $s
}

function Convert-ToNumber {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $s = "$Value".Trim()
    if (-not $s -or $s -eq "-" -or $s -eq "--") { return $null }
    $num = 0.0
    if ([double]::TryParse($s, [ref]$num)) { return [double]$num }
    return $null
}

function Write-Colored {
    param([string]$text, [double]$value)
    if ($value -gt 0) { Write-Host $text -NoNewline -ForegroundColor Red }
    elseif ($value -lt 0) { Write-Host $text -NoNewline -ForegroundColor Green }
    else { Write-Host $text -NoNewline }
}
