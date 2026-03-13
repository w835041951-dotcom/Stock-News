# Register-DailyTasks.ps1 -- Register two Windows Scheduled Tasks
# Trigger times are Beijing Time (CST = UTC+8)
# Windows Task Scheduler stores times as UTC internally, so we pre-convert here.

param([switch]$Unregister)

$pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"

# Times stored as UTC (CST - 8h):
#   09:00 CST = 01:00 UTC  -> AlphaSignal
#   05:00 CST = 21:00 UTC (previous day) -> USReport
$tasks = @(
    @{
        Name      = "MyClaw_USReport_0500"
        TimeUTC   = "21:00"   # 05:00 CST = 21:00 UTC
        TimeLabel = "05:00"
        Script    = "Q:\MyClaw\stock-news\Schedule-USReport.ps1"
    },
    @{
        Name      = "MyClaw_AlphaSignal_0900"
        TimeUTC   = "01:00"   # 09:00 CST = 01:00 UTC
        TimeLabel = "09:00"
        Script    = "Q:\MyClaw\stock-news\Schedule-AlphaSignal.ps1"
    }
)

if ($Unregister) {
    foreach ($t in $tasks) {
        if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
            Write-Host "Removed: $($t.Name)" -ForegroundColor Yellow
        } else {
            Write-Host "Not found: $($t.Name)" -ForegroundColor Gray
        }
    }
    return
}

foreach ($t in $tasks) {
    $startBoundary = "2000-01-01T$($t.TimeUTC):00+00:00"

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>MyClaw daily $($t.TimeLabel) CST (=$($t.TimeUTC) UTC): $($t.Script)</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings>
      <Duration>PT10M</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
  </Settings>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$pwsh</Command>
      <Arguments>-NoProfile -File "$($t.Script)"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
    Register-ScheduledTask -TaskName $t.Name -Xml $xml -Force | Out-Null
    Write-Host "Registered: $($t.Name) @ $($t.TimeLabel) CST ($($t.TimeUTC) UTC)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Current tasks (NextRun shown in local time):" -ForegroundColor White
Get-ScheduledTask -TaskName "MyClaw_*" | Format-Table TaskName, State, @{N='NextRun';E={(Get-ScheduledTaskInfo $_).NextRunTime}} -AutoSize
