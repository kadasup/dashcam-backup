#Requires -Version 5.1
<#
  dashcam-backup / backup.ps1
  行車紀錄器 SD 卡 → 外接硬碟 自動備份

  流程：找磁碟（用磁碟區標籤，不看代號）→ 右下角進度視窗＋通知「偵測到 SD 卡」
        → robocopy 先列清單算總量 → 正式複製（逐檔更新視窗與通知中心的進度條）
        → 標記到達時間 → 保留清理（三道保險，含進度）→ 結果（視窗＋通知）→ 寫 log

  用法：
    backup.ps1              正常執行（排程用）
    backup.ps1 -DryRun      試跑：robocopy 只列清單、清理只預覽、通知加【試跑】
    backup.ps1 -NoToast     不跳通知（除錯用）
    backup.ps1 -NoWindow    不開進度視窗（除錯用）

  回傳碼：0 成功或靜默略過、1 有問題（已通知）、2 目的磁碟／資料夾找不到
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoToast,
    [switch]$NoWindow
)

$ErrorActionPreference = 'Stop'

# ================= 設定區 =================
$SourceLabel  = 'MUFU V20S'        # SD 卡的磁碟區標籤
$DestLabel    = '2T-2'             # 外接硬碟的磁碟區標籤
$DestRootName = '!!行車紀錄器'      # 外接硬碟底下的根資料夾（必須已存在，避免複製到錯的碟）

# 要備份的子資料夾。RetentionDays = 目的地保留天數，0 = 永不清理
# （SD 卡上還有 Event、Picture，使用者決定只要 Video；要加就多一列）
$Folders = @(
    @{ Name = 'Video'; Required = $true; RetentionDays = 120 }
)

# 保留清理開關：第一次先 $false 只預覽，看過 log 確認無誤後改成 $true
$RetentionApply = $false

# 清理的三道保險
$MinArrivalDays = 7      # 檔案到達目的地至少 N 天才可清（防時鐘錯亂的檔案一到就被刪）
$MaxDeletePct   = 30     # 單次要刪的檔案超過總數 N% 就中止並通知
$MaxFileAgeDays = 400    # 修改時間比這還舊、或在未來 → 視為時鐘異常，不刪並通知

$SourceWaitSeconds        = 15   # 事件觸發後 SD 卡可能還沒掛好，最多等這麼久
$WindowCloseSeconds       = 15   # 成功後進度視窗停留幾秒自動關閉
$ErrorWindowCloseSeconds  = 600  # 失敗時視窗最多停留幾秒（lock 已先釋放，不擋下一次）
$ProgressToastInterval    = 8    # 通知中心的進度條每幾秒更新一次

$StateDir        = Join-Path $env:LOCALAPPDATA 'dashcam-backup'   # lock、log、last-run
$LogKeepDays     = 30
$RobocopyRetries = 3
# ==========================================

$script:LogFile  = $null
$script:Problems = @()
$script:Ui       = $null
$script:Toast    = @{ Ready = $false; Notifier = $null; ProgressShown = $false; Seq = 0; LastUpdate = [datetime]::MinValue }
$Totals = @{ Copied = 0; Skipped = 0; Failed = 0; Mismatch = 0; CopiedBytes = 0
             Deleted = 0; DeletedBytes = 0; Preview = 0; PreviewBytes = 0 }
$tag = if ($DryRun) { '【試跑】' } else { '' }

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

function Format-GB([double]$Bytes) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }

# ================= 通知（Windows 通知中心） =================
function Initialize-Toast {
    if ($NoToast) { return $false }
    if ($script:Toast.Ready) { return $true }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.NotificationData, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $script:Toast.Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
        $script:Toast.Ready = $true
        return $true
    } catch {
        Write-Log "通知初始化失敗：$($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Show-Toast {
    param([string]$Title, [string]$Body, [switch]$Urgent)
    if (-not (Initialize-Toast)) {
        if ($Urgent) { try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($Body, $Title, 'OK', 'Warning') | Out-Null } catch { } }
        return
    }
    try {
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
        $script:Toast.Notifier.Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
    } catch {
        Write-Log "toast 通知失敗：$($_.Exception.Message)" 'WARN'
    }
}

# 同一張帶進度條的通知，原地更新（tag 固定），複製中每隔幾秒更新一次
function Update-ProgressToast {
    param([string]$Status, [double]$Value, [string]$ValueText, [string]$Detail, [switch]$Final, [switch]$Force)
    if (-not (Initialize-Toast)) { return }
    $now = Get-Date
    if (-not $Final -and -not $Force -and $script:Toast.ProgressShown -and ($now - $script:Toast.LastUpdate).TotalSeconds -lt $ProgressToastInterval) { return }
    $script:Toast.LastUpdate = $now
    try {
        # WinRT 的 Values 字典在 PowerShell 不能用索引寫值，要先用 .NET Dictionary 建好再丟進建構子
        $dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $dict.Add('progressStatus', $Status)
        $dict.Add('progressValue', ([math]::Max(0, [math]::Min(1, $Value))).ToString([Globalization.CultureInfo]::InvariantCulture))
        $dict.Add('progressValueString', $ValueText)
        $dict.Add('detail', $Detail)
        $data = New-Object Windows.UI.Notifications.NotificationData -ArgumentList (,$dict)
        $script:Toast.Seq++
        $data.SequenceNumber = [uint32]$script:Toast.Seq
        $needShow = -not $script:Toast.ProgressShown
        if (-not $needShow) {
            $r = $script:Toast.Notifier.Update($data, 'dashcam-progress')
            if ("$r" -ne 'Succeeded') { $needShow = $true }    # 使用者從通知中心清掉了 → 重新顯示（最終結果一定要留紀錄）
        }
        if ($needShow) {
            if (-not $Final -and $script:Toast.ProgressShown) { return }   # 進行中被清掉就不再吵，等最終結果再出現
            $xmlText = "<toast><visual><binding template=`"ToastGeneric`"><text>行車紀錄器備份$tag</text>" +
                       "<progress title=`"{progressStatus}`" value=`"{progressValue}`" valueStringOverride=`"{progressValueString}`" status=`"`"/>" +
                       "<text>{detail}</text></binding></visual></toast>"
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml($xmlText)
            $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
            $toast.Tag = 'dashcam-progress'
            $toast.Data = $data
            $script:Toast.Notifier.Show($toast)
            $script:Toast.ProgressShown = $true
        }
    } catch {
        Write-Log "進度通知失敗：$($_.Exception.Message)" 'WARN'
    }
}

# ================= 右下角進度視窗 =================
function Show-ProgressWindow {
    if ($NoWindow) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $f = New-Object System.Windows.Forms.Form
        $f.Text = "行車紀錄器備份$tag"
        $f.FormBorderStyle = 'FixedToolWindow'
        $f.TopMost = $true
        $f.ShowInTaskbar = $false
        $f.StartPosition = 'Manual'
        $f.ClientSize = New-Object System.Drawing.Size(460, 124)
        $f.BackColor = [System.Drawing.Color]::White
        $f.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 9.5)
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $f.Location = New-Object System.Drawing.Point(($wa.Right - $f.Width - 12), ($wa.Bottom - $f.Height - 12))

        $phase = New-Object System.Windows.Forms.Label
        $phase.Location = New-Object System.Drawing.Point(14, 10); $phase.Size = New-Object System.Drawing.Size(432, 24)
        $phase.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 11, [System.Drawing.FontStyle]::Bold)
        $phase.AutoEllipsis = $true

        $detail = New-Object System.Windows.Forms.Label
        $detail.Location = New-Object System.Drawing.Point(14, 38); $detail.Size = New-Object System.Drawing.Size(432, 20)
        $detail.AutoEllipsis = $true

        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Location = New-Object System.Drawing.Point(14, 64); $bar.Size = New-Object System.Drawing.Size(432, 18)
        $bar.Minimum = 0; $bar.Maximum = 1000; $bar.Style = 'Marquee'; $bar.MarqueeAnimationSpeed = 30

        $stats = New-Object System.Windows.Forms.Label
        $stats.Location = New-Object System.Drawing.Point(14, 92); $stats.Size = New-Object System.Drawing.Size(432, 20)
        $stats.ForeColor = [System.Drawing.Color]::Gray
        $stats.AutoEllipsis = $true

        $f.Controls.AddRange(@($phase, $detail, $bar, $stats))
        $f.Show()
        $script:Ui = @{ Form = $f; Phase = $phase; Detail = $detail; Bar = $bar; Stats = $stats }
        Invoke-Pump
    } catch {
        Write-Log "進度視窗建立失敗：$($_.Exception.Message)" 'WARN'
        $script:Ui = $null
    }
}

function Invoke-Pump { if ($script:Ui) { try { [System.Windows.Forms.Application]::DoEvents() } catch { } } }

function Update-ProgressWindow {
    param([string]$Phase, [string]$Detail, [double]$Fraction = -1, [string]$Stats, [ValidateSet('Normal','Ok','Error')][string]$State = 'Normal')
    if (-not $script:Ui -or $script:Ui.Form.IsDisposed) { return }
    try {
        $u = $script:Ui
        if ($PSBoundParameters.ContainsKey('Phase'))  { $u.Phase.Text  = $Phase }
        if ($PSBoundParameters.ContainsKey('Detail')) { $u.Detail.Text = $Detail }
        if ($PSBoundParameters.ContainsKey('Stats'))  { $u.Stats.Text  = $Stats }
        if ($Fraction -lt 0) {
            if ($u.Bar.Style -ne 'Marquee') { $u.Bar.Style = 'Marquee' }
        } else {
            if ($u.Bar.Style -ne 'Continuous') { $u.Bar.Style = 'Continuous' }
            $u.Bar.Value = [int][math]::Round([math]::Max(0, [math]::Min(1, $Fraction)) * 1000)
        }
        switch ($State) {
            'Ok'    { $u.Phase.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 64) }
            'Error' { $u.Phase.ForeColor = [System.Drawing.Color]::FromArgb(200, 32, 32) }
            default { $u.Phase.ForeColor = [System.Drawing.Color]::Black }
        }
        Invoke-Pump
    } catch { }
}

# 停留幾秒後關閉；使用者自己關掉也算
function Close-ProgressWindow([int]$Seconds) {
    if (-not $script:Ui) { return }
    $f = $script:Ui.Form
    $until = (Get-Date).AddSeconds($Seconds)
    try {
        while (-not $f.IsDisposed -and (Get-Date) -lt $until) { Invoke-Pump; Start-Sleep -Milliseconds 100 }
        if (-not $f.IsDisposed) { $f.Close(); $f.Dispose() }
    } catch { }
    $script:Ui = $null
}

# ================= 磁碟／robocopy =================
function Find-VolumeRoot([string]$Label) {
    $disk = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
            Where-Object { $_.VolumeName -eq $Label -and $_.DeviceID } |
            Select-Object -First 1
    if ($disk) { return ($disk.DeviceID + '\') }
    return $null
}

# 從 robocopy 輸出抓最後一段摘要。表頭會隨 UI 語言變：互動視窗是英文（Files / Bytes），排程環境實測是中文（檔案 / 位元組）
function Get-RobocopySummary([string[]]$Lines) {
    $r = @{ Ok = $false; Total = 0; Copied = 0; Skipped = 0; Mismatch = 0; Failed = 0; Extras = 0; CopiedBytes = 0 }
    $fileLine = $Lines | Where-Object { $_ -match '^\s*(Files|檔案)\s*:\s+\d' } | Select-Object -Last 1
    $byteLine = $Lines | Where-Object { $_ -match '^\s*(Bytes|位元組)\s*:\s+\d' } | Select-Object -Last 1
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

# 跑 robocopy，逐行讀輸出（不阻塞視窗），每行呼叫 OnLine
function Invoke-Robocopy {
    param([string]$Src, [string]$Dst, [switch]$ListOnly, [scriptblock]$OnLine)
    # /XX：不理會目的地多出來的檔案（舊備份），輸出才不會被幾千行 EXTRA 洗掉
    $args = @("`"$Src`"", "`"$Dst`"", '/E', '/COPY:DAT', '/DCOPY:T', '/FFT', '/DST', '/XJ', '/XX',
              "/R:$RobocopyRetries", '/W:5', '/NP', '/NDL')
    if ($ListOnly) { $args += '/L' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'robocopy.exe'
    $psi.Arguments = ($args -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }
    $p = [System.Diagnostics.Process]::Start($psi)
    $lines = New-Object System.Collections.Generic.List[string]
    $reader = $p.StandardOutput
    $task = $reader.ReadLineAsync()
    while ($true) {
        if ($task.Wait(150)) {
            $line = $task.Result
            if ($null -eq $line) { break }
            $lines.Add($line)
            if ($OnLine) { & $OnLine $line }
            $task = $reader.ReadLineAsync()
        } else {
            Invoke-Pump
        }
    }
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Lines = $lines.ToArray() }
}

# ================= 保留清理 =================
function Invoke-Retention {
    param([hashtable]$Folder, [string]$SrcFolder, [string]$DstFolder)
    $name = $Folder.Name
    $days = [int]$Folder.RetentionDays
    $now  = Get-Date
    $cut  = $now.Date.AddDays(-$days)

    Update-ProgressWindow -Phase "檢查 ${name} 保留期（$days 天）" -Detail '掃描目的地檔案…' -Fraction -1 -Stats ''
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
        $i = 0
        foreach ($c in $cands) {
            $i++
            Update-ProgressWindow -Phase "清理 ${name} 超過 $days 天的檔案" -Detail $c.Name -Fraction ($i / $cands.Count) -Stats "第 $i / $($cands.Count) 個"
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
$lockHeld = $true
$exitCode = 0

try {
    Write-Log "===== dashcam-backup 開始 $tag PID=$PID ====="

    # log 輪替
    Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogKeepDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # 來源：事件觸發時磁碟可能還沒掛好，等一下；等不到就靜默結束（SD 卡沒插、或插的是別的隨身碟）
    $srcRoot = $null
    for ($i = 0; $i -le $SourceWaitSeconds; $i++) {
        $srcRoot = Find-VolumeRoot $SourceLabel
        if ($srcRoot) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $srcRoot) {
        Write-Log "找不到來源磁碟「$SourceLabel」（等了 $SourceWaitSeconds 秒），靜默結束"
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

    # 偵測到了：開視窗、發通知
    Show-ProgressWindow
    Update-ProgressWindow -Phase "偵測到 SD 卡（$SourceLabel）" -Detail "備份到 $dstBase" -Fraction -1 -Stats '正在計算要複製的檔案…'
    Show-Toast "偵測到 SD 卡$tag" "MUFU V20S 已插入，開始備份到 $dstBase"
    Update-ProgressToast -Status '計算要複製的檔案…' -Value 0 -ValueText '' -Detail "來源 $srcRoot → $dstBase" -Force

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

        # 第一遍：只列清單，算出要複製多少（給進度條當分母）
        Write-Log "${name}：robocopy 列清單 $s → $d"
        $plan = Invoke-Robocopy -Src $s -Dst $d -ListOnly
        $planSum = Get-RobocopySummary $plan.Lines
        $toCopy = $planSum.Copied; $toBytes = $planSum.CopiedBytes
        Write-Log ("{0}：要複製 {1} 個（{2}），略過 {3} 個" -f $name, $toCopy, (Format-GB $toBytes), $planSum.Skipped)
        Update-ProgressWindow -Phase "複製 ${name}" -Detail "要複製 $toCopy 個檔案（$(Format-GB $toBytes)），略過 $($planSum.Skipped) 個" -Fraction 0 -Stats ''

        if ($DryRun) {
            # 試跑：拿清單當結果，不真的複製
            $rc = $plan.ExitCode; $sum = $planSum; $rcLines = $plan.Lines; $secs = 0
        } else {
            # 第二遍：正式複製，逐行讀輸出更新進度
            $before = @{}
            Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $before[$_.FullName] = $true }

            $prog = @{ Started = 0; DoneBytes = 0; CurBytes = 0; CurName = ''; T0 = Get-Date }
            $onLine = {
                param($line)
                # robocopy 開始複製一個檔案時印一行「新檔案 / New File  大小  路徑」（前一個檔此時已完成）
                if ($line -match '^\s*(New File|新檔案)\s') {
                    $prog.DoneBytes += $prog.CurBytes
                    $path = ($line -split "`t")[-1].Trim()
                    $prog.CurName = Split-Path $path -Leaf
                    $prog.CurBytes = 0
                    try { $prog.CurBytes = (Get-Item -LiteralPath $path).Length } catch { }
                    $prog.Started++
                    $frac = if ($toBytes -gt 0) { $prog.DoneBytes / $toBytes } else { 0 }
                    $el = ((Get-Date) - $prog.T0).TotalSeconds
                    $eta = ''
                    if ($prog.DoneBytes -gt 0 -and $el -gt 3) {
                        $remain = ($toBytes - $prog.DoneBytes) / ($prog.DoneBytes / $el)
                        $eta = if ($remain -ge 90) { "，剩餘約 $([math]::Ceiling($remain / 60)) 分" } else { "，剩餘約 $([math]::Ceiling($remain)) 秒" }
                    }
                    $stats = "$(Format-GB $prog.DoneBytes) / $(Format-GB $toBytes)$eta"
                    Update-ProgressWindow -Phase "複製 ${name}（第 $($prog.Started) / $toCopy 個）" -Detail $prog.CurName -Fraction $frac -Stats $stats
                    Update-ProgressToast -Status "複製 ${name}：第 $($prog.Started) / $toCopy 個" -Value $frac -ValueText "$([math]::Round($frac * 100))%" -Detail $stats
                }
            }
            Write-Log "${name}：robocopy 正式複製"
            $t0 = Get-Date
            $run = Invoke-Robocopy -Src $s -Dst $d -OnLine $onLine
            $rc = $run.ExitCode; $rcLines = $run.Lines
            $sum = Get-RobocopySummary $rcLines
            $secs = [int]((Get-Date) - $t0).TotalSeconds
        }

        # robocopy 原始輸出存檔（每個資料夾一檔），方便事後查
        $rcLog = Join-Path $logDir "robocopy-$stamp-$name.log"
        [IO.File]::WriteAllLines($rcLog, [string[]]$rcLines, (New-Object System.Text.UTF8Encoding $true))

        if (-not $sum.Ok) { Write-Log "${name}：無法解析 robocopy 摘要，改用檔案數推算" 'WARN' }
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
            Update-ProgressWindow -Phase "複製 ${name} 完成" -Detail '標記新檔案的到達時間…' -Fraction 1 -Stats ''
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
                  Totals = $Totals; Problems = $script:Problems; Log = $script:LogFile }
    try {
        [IO.File]::WriteAllText((Join-Path $StateDir 'last-run.json'), ($lastRun | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $true))
    } catch { Write-Log "last-run.json 寫入失敗：$($_.Exception.Message)" 'WARN' }

    # 工作做完就先放 lock，失敗視窗停著時不擋下一次插卡
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue; $lockHeld = $false

    if ($script:Problems.Count -gt 0) {
        Write-Log "===== 結束：有 $($script:Problems.Count) 個問題。$stat =====" 'ERROR'
        $body = ($script:Problems -join "`n") + "`n$stat`nlog：$($script:LogFile)"
        Update-ProgressToast -Status "有問題：$($script:Problems.Count) 項" -Value 1 -ValueText '' -Detail $stat -Final
        Show-Toast "行車紀錄器備份 有問題$tag" $body -Urgent
        Update-ProgressWindow -Phase "備份有問題（$($script:Problems.Count) 項）" -Detail ($script:Problems[0]) -Fraction 1 -Stats "$stat（詳見 log）" -State Error
        $exitCode = 1
        Close-ProgressWindow $ErrorWindowCloseSeconds
    } else {
        Write-Log "===== 結束：成功。$stat ====="
        Update-ProgressToast -Status '完成' -Value 1 -ValueText '100%' -Detail $stat -Final
        Update-ProgressWindow -Phase '備份完成' -Detail $stat -Fraction 1 -Stats "視窗 $WindowCloseSeconds 秒後自動關閉" -State Ok
        $exitCode = 0
        Close-ProgressWindow $WindowCloseSeconds
    }
} catch {
    $msg = "腳本例外：$($_.Exception.Message)（$($_.InvocationInfo.ScriptLineNumber) 行）"
    Write-Log $msg 'ERROR'
    Show-Toast "行車紀錄器備份 失敗$tag" "$msg`nlog：$($script:LogFile)" -Urgent
    Update-ProgressWindow -Phase '備份失敗' -Detail $msg -Fraction 1 -Stats "log：$($script:LogFile)" -State Error
    $exitCode = 1
    if ($lockHeld) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue; $lockHeld = $false }
    Close-ProgressWindow $ErrorWindowCloseSeconds
} finally {
    if ($lockHeld) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
