#Requires -Version 5.1
<#
  dashcam-backup / install-task.ps1
  註冊（或移除、檢查）工作排程器的「Dashcam-Backup」工作。可重複執行，會覆蓋舊設定。

  觸發：
    1. 事件觸發：Microsoft-Windows-Kernel-PnP/Configuration 事件 410（裝置啟動），延遲 30 秒等磁碟掛好。
       任何 USB 裝置插入都會觸發，但 backup.ps1 找不到 SD 卡就靜默結束，成本極低。
    2. 每日備援：預設 12:00 跑一次，萬一事件漏掉也有補。

  用法：
    install-task.ps1               註冊
    install-task.ps1 -DailyTime 20:00
    install-task.ps1 -Check        顯示目前狀態與最後執行結果
    install-task.ps1 -Uninstall    移除
#>
[CmdletBinding()]
param(
    [string]$DailyTime = '12:00',
    [switch]$Check,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$TaskName = 'Dashcam-Backup'
$proj = $PSScriptRoot
$vbs  = Join-Path $proj 'run-hidden.vbs'
$ps1  = Join-Path $proj 'backup.ps1'

if ($Check) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "[--] 工作「$TaskName」不存在，請先執行 install-task.ps1"; exit 1 }
    $i = $t | Get-ScheduledTaskInfo
    Write-Host "[OK] 工作：$TaskName  狀態：$($t.State)"
    Write-Host "     動作：$($t.Actions[0].Execute) $($t.Actions[0].Arguments)"
    Write-Host "     觸發：$($t.Triggers.Count) 個（事件 + 每日）"
    Write-Host "     上次執行：$($i.LastRunTime)  結果碼：$($i.LastTaskResult)  下次：$($i.NextRunTime)"
    $lr = Join-Path $env:LOCALAPPDATA 'dashcam-backup\last-run.json'
    if (Test-Path $lr) {
        $j = Get-Content $lr -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "     最後一次 backup.ps1：$($j.StartedAt)  新增 $($j.Totals.Copied) 略過 $($j.Totals.Skipped) 失敗 $($j.Totals.Failed)  問題 $($j.Problems.Count) 個"
        Write-Host "     log：$($j.Log)"
    }
    exit 0
}

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[OK] 已移除工作「$TaskName」"
    } else { Write-Host "[--] 工作「$TaskName」本來就不存在" }
    exit 0
}

foreach ($p in $vbs, $ps1) { if (-not (Test-Path $p)) { throw "找不到 $p" } }

$action = New-ScheduledTaskAction -Execute 'wscript.exe' `
    -Argument "`"$vbs`" powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ps1`""

# 事件觸發（New-ScheduledTaskTrigger 不支援事件，走 CIM）
$evtClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'root/Microsoft/Windows/TaskScheduler'
$evt = New-CimInstance -CimClass $evtClass -ClientOnly
$evt.Enabled = $true
$evt.Delay = 'PT30S'
$evt.Subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-Kernel-PnP/Configuration"><Select Path="Microsoft-Windows-Kernel-PnP/Configuration">*[System[Provider[@Name='Microsoft-Windows-Kernel-PnP'] and EventID=410]]</Select></Query></QueryList>
'@

$daily = New-ScheduledTaskTrigger -Daily -At $DailyTime

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# 只在使用者登入時執行（Interactive），toast 通知才顯示得出來；不需要管理員
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($evt, $daily) `
    -Settings $settings -Principal $principal -Force `
    -Description '行車紀錄器 SD 卡插入時自動備份到外接硬碟（dashcam-backup/backup.ps1）' | Out-Null

Write-Host "[OK] 已註冊工作「$TaskName」"
Write-Host "     事件觸發：Kernel-PnP/Configuration 410（延遲 30 秒）"
Write-Host "     每日備援：$DailyTime"
Write-Host "     腳本：$ps1"
Write-Host "     驗證：拔卡再插，30 秒後應跳出通知；或執行 install-task.ps1 -Check"
