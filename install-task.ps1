#Requires -Version 5.1
<#
  dashcam-backup / install-task.ps1
  註冊（或移除、檢查）工作排程器的「Dashcam-Backup」工作。可重複執行，會覆蓋舊設定。

  觸發：只有插卡事件。Microsoft-Windows-StorageVolume/Operational 事件 1001（Volume arrived），延遲 5 秒（腳本自己再等磁碟掛好）。
  任何磁碟區掛載都會觸發（含隨身碟），但 backup.ps1 找不到 SD 卡就靜默結束，成本極低。
  （使用者決定不要每日定時備援）

  ⚠️ 不要用 Kernel-PnP/Configuration 410：實測 2026-09-04 拔插 SD 卡完全沒有 410，
  它只在裝置第一次設定／換讀卡機時才記；StorageVolume 1001 則每次插卡都有。

  用法：
    install-task.ps1               註冊
    install-task.ps1 -Check        顯示目前狀態與最後執行結果
    install-task.ps1 -Uninstall    移除
#>
[CmdletBinding()]
param(
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
    Write-Host "     觸發：$($t.Triggers.Count) 個（插卡事件）"
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
$evt.Delay = 'PT5S'   # 短延遲即可，backup.ps1 自己會等 SD 卡掛好（最多 15 秒）
$evt.Subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-StorageVolume/Operational"><Select Path="Microsoft-Windows-StorageVolume/Operational">*[System[Provider[@Name='Microsoft-Windows-StorageVolume'] and EventID=1001]]</Select></Query></QueryList>
'@

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# 只在使用者登入時執行（Interactive），toast 通知才顯示得出來；不需要管理員
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $evt `
    -Settings $settings -Principal $principal -Force `
    -Description '行車紀錄器 SD 卡插入時自動備份到外接硬碟（dashcam-backup/backup.ps1）' | Out-Null

Write-Host "[OK] 已註冊工作「$TaskName」"
Write-Host "     觸發：插卡事件 StorageVolume/Operational 1001（延遲 5 秒），沒有定時觸發"
Write-Host "     腳本：$ps1"
Write-Host "     驗證：拔卡再插，30 秒後應跳出通知；或執行 install-task.ps1 -Check"
