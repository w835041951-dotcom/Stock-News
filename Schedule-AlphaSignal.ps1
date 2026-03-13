# Schedule-AlphaSignal.ps1 — 每日定时：Alpha Signal 选股报告
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
$outFile = Join-Path $desktop "$date-AlphaSignal.txt"
$logFile = Join-Path $desktop "$date-AlphaSignal-error.log"

try {
    & ".\stock-news\Get-AlphaSignal.ps1" *> $outFile
    # 若输出为空则写提示
    if (-not (Test-Path $outFile) -or (Get-Item $outFile).Length -eq 0) {
        "[$date] AlphaSignal 输出为空，请检查网络或数据源" | Out-File $logFile -Encoding UTF8
    }
}
catch {
    "[$date] AlphaSignal 运行异常: $_" | Out-File $logFile -Encoding UTF8 -Append
}

Write-Host "Report saved to $outFile"
