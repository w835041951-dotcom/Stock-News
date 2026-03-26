# Register-DailyTasks.ps1 -- Register two Windows Scheduled Tasks
# Trigger times are Beijing Time (local time, no UTC offset)
# Using local time avoids Task Scheduler UTC-offset edge cases with daily triggers.

param([switch]$Unregister)

$pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"

# Times in LOCAL time (Beijing CST, no UTC offset in StartBoundary).
$tasks = @(
    @{
        Name      = "MyClaw_USReport_0500"
        TimeLocal = "05:00"
        Script    = "Q:\stock-news\Schedule-USReport.ps1"
    },
    @{
        Name      = "MyClaw_AlphaSignal_0900"
        TimeLocal = "09:00"
        Script    = "Q:\stock-news\Schedule-AlphaSignal.ps1"
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
    # Use local timezone offset so scheduler treats times as local, not UTC
    $tzOffset = [System.TimeZoneInfo]::Local.BaseUtcOffset.ToString("hh\:mm")
    $startBoundary = "$(Get-Date -Format 'yyyy-MM-dd')T$($t.TimeLocal):00+$tzOffset"

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>MyClaw daily $($t.TimeLocal): $($t.Script)</Description>
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
    <WakeToRun>true</WakeToRun>
    <IdleSettings>
      <Duration>PT10M</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>false</StopOnIdleEnd>
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
    <LogonTrigger>
      <Delay>PT1M</Delay>
    </LogonTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$pwsh</Command>
      <Arguments>-NoProfile -File "$($t.Script)"</Arguments>
      <WorkingDirectory>Q:\stock-news</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
    Register-ScheduledTask -TaskName $t.Name -Xml $xml -Force | Out-Null
    Write-Host "Registered: $($t.Name) @ $($t.TimeLocal) local" -ForegroundColor Green
}

Write-Host ""
Write-Host "Current tasks (NextRun shown in local time):" -ForegroundColor White
Get-ScheduledTask -TaskName "MyClaw_*" | Format-Table TaskName, State, @{N='NextRun';E={(Get-ScheduledTaskInfo $_).NextRunTime}} -AutoSize
