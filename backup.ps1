#Requires -Version 5.1
<#
  dashcam-backup / backup.ps1
  行車紀錄器 SD 卡 → 外接硬碟 自動備份

  流程：找磁碟（用磁碟區標籤，不看代號）→ robocopy 複製 → 標記到達時間
        → 保留清理（只清 Video，含三道保險）→ Windows 通知 → 寫 log

  用法：
    backup.ps1              正常執行（排程用）
    backup.ps1 -DryRun      試跑：robocopy 只列清單、清理只預覽、通知加【試跑】
    backup.ps1 -NoToast     不跳通知（除錯用）

  回傳碼：0 成功或靜默略過、1 有問題（已通知）、2 目的磁碟／資料夾找不到
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoToast
)

$ErrorActionPreference = 'Stop'

# ================= 設定區 =================
$SourceLabel  = 'MUFU V20S'        # SD 卡的磁碟區標籤
$DestLabel    = '2T-2'             # 外接硬碟的磁碟區標籤
$DestRootName = '!!行車紀錄器'      # 外接硬碟底下的根資料夾（必須已存在，避免複製到錯的碟）

# 要備份的子資料夾。RetentionDays = 目的地保留天數，0 = 永不清理
$Folders = @(
    @{ Name = 'Video'; Required = $true;  RetentionDays = 120 },
    @{ Name = 'Event'; Required = $false; RetentionDays = 0   }   # 碰撞鎖定影片，永久保留
)

# 保留清理開關：第一次先 $false 只預覽，看過 log 確認無誤後改成 $true
$RetentionApply = $false

# 清理的三道保險
$MinArrivalDays = 7      # 檔案到達目的地至少 N 天才可清（防時鐘錯亂的檔案一到就被刪）
$MaxDeletePct   = 30     # 單次要刪的檔案超過總數 N% 就中止並通知
$MaxFileAgeDays = 400    # 修改時間比這還舊、或在未來 → 視為時鐘異常，不刪並通知

$StateDir        = Join-Path $env:LOCALAPPDATA 'dashcam-backup'   # lock、log、last-run
$LogKeepDays     = 30
$RobocopyRetries = 3
# ==========================================

$script:LogFile  = $null
$script:Problems = @()
$Totals = @{ Copied = 0; Skipped = 0; Failed = 0; Mismatch = 0; CopiedBytes = 0
             Deleted = 0; DeletedBytes = 0; Preview = 0; PreviewBytes = 0 }

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    Write-Host $line
}

function Add-Problem([string]$Msg) {
    Write-Log $Msg 'ERROR'
    $script:Problems += $Msg
}

function Show-Toast {
    param([string]$Title, [string]$Body, [switch]$Urgent)
    if ($NoToast) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $t = [System.Security.SecurityElement]::Escape($Title)
        $b = [System.Security.SecurityElement]::Escape($Body)
        if ($Urgent) {
            # reminder 情境：通知會停在畫面上直到按掉
            $xmlText = "<toast scenario=`"reminder`"><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual>" +
                       "<actions><action content=`"知道了`" arguments=`"dismiss`" activationType=`"system`"/></actions></toast>"
        } else {
            $xmlText = "<toast><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual></toast>"
        }
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($xmlText)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        Write-Log "toast 通知失敗：$($_.Exception.Message)" 'WARN'
        if ($Urgent) {
            try {
                Add-Type -AssemblyName System.Windows.Forms
                [System.Windows.Forms.MessageBox]::Show($Body, $Title, 'OK', 'Warning') | Out-Null
            } catch { }
        }
    }
}

function Find-VolumeRoot([string]$Label) {
    $disk = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.VolumeName -eq $Label -and $_.DeviceID } |
            Select-Object -First 1
    if ($disk) { return ($disk.DeviceID + '\') }
    return $null
}

function Format-GB([double]$Bytes) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }

# 讀 robocopy 的 log，抓最後一段摘要
function Get-RobocopySummary([string]$Path) {
    $r = @{ Ok = $false; Total = 0; Copied = 0; Skipped = 0; Mismatch = 0; Failed = 0; Extras = 0; CopiedBytes = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    # robocopy 的 log 編碼不一定（/UNILOG 實測也可能寫出 ANSI），看 BOM 決定
    $head = [IO.File]::ReadAllBytes($Path) | Select-Object -First 2
    $enc = if ($head.Count -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) { 'Unicode' } else { 'Default' }
    $lines = Get-Content -LiteralPath $Path -Encoding $enc
    # 表頭會隨 UI 語言變：互動視窗是英文（Files / Bytes），排程環境實測是中文（檔案 / 位元組）
    $fileLine = $lines | Where-Object { $_ -match '^\s*(Files|檔案)\s*:\s+\d' } | Select-Object -Last 1
    $byteLine = $lines | Where-Object { $_ -match '^\s*(Bytes|位元組)\s*:\s+\d' } | Select-Object -Last 1
    if ($fileLine -match '^\s*(Files|檔案)\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)') {
        $r.Total = [int]$Matches[2]; $r.Copied = [int]$Matches[3]; $r.Skipped = [int]$Matches[4]
        $r.Mismatch = [int]$Matches[5]; $r.Failed = [int]$Matches[6]; $r.Extras = [int]$Matches[7]
        $r.Ok = $true
    }
    if ($byteLine -match '^\s*(Bytes|位元組)\s*:\s+([\d.]+)\s*([kmgt]?)\s+([\d.]+)\s*([kmgt]?)') {
        $mult = @{ '' = 1; 'k' = 1KB; 'm' = 1MB; 'g' = 1GB; 't' = 1TB }
        $r.CopiedBytes = [double]$Matches[4] * $mult[$Matches[5]]
    }
    return $r
}

function Invoke-Retention {
    param([hashtable]$Folder, [string]$SrcFolder, [string]$DstFolder)
    $name = $Folder.Name
    $days = [int]$Folder.RetentionDays
    $now  = Get-Date
    $cut  = $now.Date.AddDays(-$days)

    $all = @(Get-ChildItem -LiteralPath $DstFolder -File -Recurse -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { Write-Log "${name}：目的地沒有檔案，不清理"; return }

    # 保險 3：時鐘異常（太舊或在未來）
    $anom = @($all | Where-Object { $_.LastWriteTime -lt $now.AddDays(-$MaxFileAgeDays) -or $_.LastWriteTime -gt $now.AddDays(1) })
    if ($anom.Count -gt 0) {
        Add-Problem ("{0}：有 {1} 個檔案的修改時間異常（早於 {2} 天前或在未來），可能是行車紀錄器時鐘錯亂，這些不清理。例：{3}" -f $name, $anom.Count, $MaxFileAgeDays, $anom[0].Name)
    }

    $cands = @($all | Where-Object {
        $_.LastWriteTime -lt $cut -and
        $_.LastWriteTime -ge $now.AddDays(-$MaxFileAgeDays) -and
        $_.CreationTime  -lt $now.AddDays(-$MinArrivalDays)          # 保險 1：到達滿 N 天
    })
    # 保險 2 前置：來源還有的檔案不刪（真正超過保留期的檔案不可能還在 SD 卡上）
    $cands = @($cands | Where-Object {
        $rel = $_.FullName.Substring($DstFolder.Length).TrimStart('\')
        -not (Test-Path -LiteralPath (Join-Path $SrcFolder $rel))
    })

    if ($cands.Count -eq 0) { Write-Log "${name}：沒有超過 $days 天且符合清理條件的檔案"; return }

    $bytes = ($cands | Measure-Object Length -Sum).Sum
    $pct   = [math]::Round(100.0 * $cands.Count / $all.Count, 1)
    $lo    = ($cands | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime.ToString('yyyy-MM-dd')
    $hi    = ($cands | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime.ToString('yyyy-MM-dd')
    $desc  = "{0} 個檔案（{1}，{2} ～ {3}，佔 {4}%）" -f $cands.Count, (Format-GB $bytes), $lo, $hi, $pct

    # 保險 2：單次刪除上限
    if ($pct -gt $MaxDeletePct) {
        Add-Problem "清理安全上限：${name} 要刪 $desc 超過 $MaxDeletePct%，已中止清理，請人工確認"
        return
    }

    if ($RetentionApply -and -not $DryRun) {
        Write-Log "${name}：開始清理 $desc"
        foreach ($c in $cands) {
            try {
                Remove-Item -LiteralPath $c.FullName -Force
                Write-Log "刪除 $($c.FullName)"
                $Totals.Deleted++; $Totals.DeletedBytes += $c.Length
            } catch {
                Add-Problem "刪除失敗 $($c.FullName)：$($_.Exception.Message)"
            }
        }
        # 清空的子資料夾（最深的先）
        Get-ChildItem -LiteralPath $DstFolder -Directory -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; Write-Log "移除空資料夾 $($_.FullName)" }
    } else {
        $why = if ($DryRun) { 'DryRun' } else { 'RetentionApply=$false' }
        Write-Log "${name}：【預覽，$why】符合清理條件 $desc，未刪除"
        foreach ($c in $cands) { Write-Log "  預覽 $($c.FullName)  $($c.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  $([math]::Round($c.Length/1MB)) MB" }
        $Totals.Preview += $cands.Count; $Totals.PreviewBytes += $bytes
    }
}

# ================= 主流程 =================
$startedAt = Get-Date
$logDir = Join-Path $StateDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = $startedAt.ToString('yyyyMMdd-HHmmss')
$script:LogFile = Join-Path $logDir "backup-$stamp.log"
$rcLog          = $null   # 每個資料夾跑 robocopy 時各自指定（robocopy-<時間>-<資料夾>.log）
$tag = if ($DryRun) { '【試跑】' } else { '' }

# lock：防重疊
$lockFile = Join-Path $StateDir 'backup.lock'
if (Test-Path -LiteralPath $lockFile) {
    $oldPid = Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $p = if ($oldPid) { Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue } else { $null }
    if ($p -and $p.ProcessName -match 'powershell') {
        Write-Log "另一個備份（PID $oldPid）還在跑，這次略過"
        exit 0
    }
    Write-Log "發現殘留 lock（PID $oldPid 已不存在），清掉重來" 'WARN'
}
Set-Content -LiteralPath $lockFile -Value $PID

try {
    Write-Log "===== dashcam-backup 開始 $tag PID=$PID ====="

    # log 輪替
    Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogKeepDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # 來源：找不到就靜默結束（SD 卡沒插是常態）
    $srcRoot = Find-VolumeRoot $SourceLabel
    if (-not $srcRoot) {
        Write-Log "找不到來源磁碟「$SourceLabel」（SD 卡沒插），靜默結束"
        exit 0
    }
    Write-Log "來源：$srcRoot（$SourceLabel）"

    # 目的：找不到一定要講
    $dstRoot = Find-VolumeRoot $DestLabel
    if (-not $dstRoot) {
        Add-Problem "找不到目的磁碟「$DestLabel」，外接硬碟沒接？"
        Show-Toast "行車紀錄器備份 失敗$tag" ($script:Problems -join "`n") -Urgent
        exit 2
    }
    $dstBase = Join-Path $dstRoot $DestRootName
    if (-not (Test-Path -LiteralPath $dstBase)) {
        Add-Problem "目的磁碟 $dstRoot 底下沒有「$DestRootName」資料夾，確認是不是接錯硬碟"
        Show-Toast "行車紀錄器備份 失敗$tag" ($script:Problems -join "`n") -Urgent
        exit 2
    }
    Write-Log "目的：$dstBase（$DestLabel）"

    foreach ($f in $Folders) {
        $name = $f.Name
        $s = Join-Path $srcRoot $name
        $d = Join-Path $dstBase $name

        if (-not (Test-Path -LiteralPath $s)) {
            if ($f.Required) { Add-Problem "SD 卡上找不到「$name」資料夾（$s）" }
            else             { Write-Log "SD 卡上沒有「$name」資料夾，略過" }
            continue
        }
        if (-not (Test-Path -LiteralPath $d)) {
            if ($f.Required) { Add-Problem "目的地找不到「$name」資料夾（$d）"; continue }
            if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $d | Out-Null; Write-Log "建立目的資料夾 $d" }
        }

        # 複製前快照，之後用來找出「這次新增」的檔案
        $before = @{}
        if (Test-Path -LiteralPath $d) {
            Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $before[$_.FullName] = $true }
        }

        # /XX：不理會目的地多出來的檔案（舊備份），log 才不會被幾千行 EXTRA 洗掉
        # 每個資料夾各一個 robocopy log，摘要才不會互相混到
        $rcLog = Join-Path $logDir "robocopy-$stamp-$name.log"
        $rcArgs = @($s, $d, '/E', '/COPY:DAT', '/DCOPY:T', '/FFT', '/DST', '/XJ', '/XX',
                    "/R:$RobocopyRetries", '/W:5', '/NP', '/NDL', "/LOG:$rcLog")
        if ($DryRun) { $rcArgs += '/L' }
        Write-Log "${name}：robocopy $s → $d"
        $t0 = Get-Date
        & robocopy.exe @rcArgs | Out-Null
        $rc = $LASTEXITCODE
        $sum = Get-RobocopySummary $rcLog
        $secs = [int]((Get-Date) - $t0).TotalSeconds

        if (-not $sum.Ok) {
            Write-Log "${name}：無法解析 robocopy 摘要，改用檔案數推算" 'WARN'
        }
        Write-Log ("{0}：回傳碼 {1}，新增 {2}（{3}）、略過 {4}、失敗 {5}、不符 {6}，{7} 秒" -f
                   $name, $rc, $sum.Copied, (Format-GB $sum.CopiedBytes), $sum.Skipped, $sum.Failed, $sum.Mismatch, $secs)
        $Totals.Copied += $sum.Copied; $Totals.Skipped += $sum.Skipped; $Totals.Failed += $sum.Failed
        $Totals.Mismatch += $sum.Mismatch; $Totals.CopiedBytes += $sum.CopiedBytes

        # 回傳碼：1=有複製 2=目的有多的檔（正常） 4=不符 8=有檔案失敗 16=嚴重錯誤
        if ($rc -ge 16)     { Add-Problem "${name}：robocopy 嚴重錯誤（回傳碼 $rc），詳見 $rcLog" }
        elseif ($rc -ge 8)  { Add-Problem "${name}：有 $($sum.Failed) 個檔案複製失敗（回傳碼 $rc），詳見 $rcLog" }
        elseif ($rc -band 4){ Write-Log "${name}：有 $($sum.Mismatch) 個不符項目（同名但一邊是檔案一邊是資料夾），詳見 $rcLog" 'WARN' }

        # 標記到達時間：這次新增的檔案 CreationTime 改成現在（robocopy 會沿用來源的建立時間，不能拿來判斷「何時到達」）
        if (-not $DryRun) {
            $now = Get-Date; $marked = 0
            Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $before.ContainsKey($_.FullName) } |
                ForEach-Object { try { $_.CreationTime = $now; $marked++ } catch { } }
            Write-Log "${name}：標記 $marked 個新檔案的到達時間"
            if (-not $sum.Ok) { $Totals.Copied += $marked }
        }

        # 保留清理：複製失敗這輪就不清，避免在不健康的狀態下刪東西
        if ([int]$f.RetentionDays -gt 0) {
            if ($rc -ge 8) { Write-Log "${name}：這輪複製有失敗，跳過清理" 'WARN' }
            else           { Invoke-Retention -Folder $f -SrcFolder $s -DstFolder $d }
        }
    }

    # ===== 總結 =====
    $elapsed = (Get-Date) - $startedAt
    $mins = [math]::Round($elapsed.TotalMinutes, 1)
    $stat = "新增 $($Totals.Copied) 個（$(Format-GB $Totals.CopiedBytes)）、略過 $($Totals.Skipped) 個"
    if ($Totals.Deleted -gt 0) { $stat += "、清理 $($Totals.Deleted) 個（$(Format-GB $Totals.DeletedBytes)）" }
    if ($Totals.Preview -gt 0) { $stat += "、待清理預覽 $($Totals.Preview) 個（$(Format-GB $Totals.PreviewBytes)）" }
    $stat += "，耗時 $mins 分"

    $lastRun = @{ StartedAt = $startedAt.ToString('s'); Minutes = $mins; DryRun = [bool]$DryRun
                  Totals = $Totals; Problems = $script:Problems; Log = $script:LogFile; RobocopyLog = $rcLog }
    try {
        $json = $lastRun | ConvertTo-Json -Depth 4
        $lrPath = Join-Path $StateDir 'last-run.json'
        [IO.File]::WriteAllText($lrPath, $json, (New-Object Text.UTF8Encoding $true))
        Write-Log "last-run.json 已寫入 $lrPath（$([IO.File]::GetLastWriteTime($lrPath).ToString('HH:mm:ss'))，$([IO.File]::ReadAllBytes($lrPath).Length) bytes）"
    } catch {
        Write-Log "last-run.json 寫入失敗：$($_.Exception.Message)" 'WARN'
    }

    if ($script:Problems.Count -gt 0) {
        Write-Log "===== 結束：有 $($script:Problems.Count) 個問題。$stat =====" 'ERROR'
        $body = ($script:Problems -join "`n") + "`n$stat`nlog：$($script:LogFile)"
        Show-Toast "行車紀錄器備份 有問題$tag" $body -Urgent
        exit 1
    } else {
        Write-Log "===== 結束：成功。$stat ====="
        Show-Toast "行車紀錄器備份 完成$tag" $stat
        exit 0
    }
} catch {
    $msg = "腳本例外：$($_.Exception.Message)（$($_.InvocationInfo.ScriptLineNumber) 行）"
    Write-Log $msg 'ERROR'
    Show-Toast "行車紀錄器備份 失敗$tag" "$msg`nlog：$($script:LogFile)" -Urgent
    exit 1
} finally {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}
