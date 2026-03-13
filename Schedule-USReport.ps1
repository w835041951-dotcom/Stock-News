# Schedule-USReport.ps1 — 每日定时：美股强势板块 + 关联A股推荐
# 由 Windows 任务计划程序调用，输出到桌面

$ErrorActionPreference = 'Continue'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

Set-Location "Q:\MyClaw"

$date    = Get-Date -Format 'yyyy-MM-dd'
$desktop = [Environment]::GetFolderPath('Desktop')
$outFile = Join-Path $desktop "$date-美股强势.txt"
$logFile = Join-Path $desktop "$date-美股强势-error.log"

try {
    & ".\stock-news\Get-USStrongAStocks.ps1" *> $outFile
    if (-not (Test-Path $outFile) -or (Get-Item $outFile).Length -eq 0) {
        "[$date] USReport 输出为空，请检查网络或数据源" | Out-File $logFile -Encoding UTF8
    }
}
catch {
    "[$date] USReport 运行异常: $_" | Out-File $logFile -Encoding UTF8 -Append
}

Write-Host "Report saved to $outFile"
