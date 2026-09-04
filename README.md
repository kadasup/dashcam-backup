# dashcam-backup

行車紀錄器（MUFU V20S）SD 卡插入電腦時，自動把影片備份到外接硬碟。Windows 11、PowerShell 5.1、內建 robocopy，不需要安裝任何東西。

## 做什麼

1. 用**磁碟區標籤**找 SD 卡（`MUFU V20S`）和外接硬碟（`2T-2`），磁碟代號變了也不受影響。
2. robocopy 遞迴複製整個 `Video` 資料夾到 `<外接硬碟>\!!行車紀錄器\Video`。已存在且相同的檔案自動略過，失敗自動重試 3 次。
3. 目的地 `Video` 只保留 120 天。清理有三道保險，見下。
4. 結束時跳 Windows 通知：成功顯示新增／略過數量，失敗顯示原因與 log 路徑，失敗通知會停在畫面上直到按掉。
5. SD 卡沒插時靜默結束，不吵人。外接硬碟沒接、或資料夾結構不對，一定跳通知。

## 安裝（換電腦也是這幾步）

```powershell
cd ~\Desktop\Claude\dashcam-backup
powershell -ExecutionPolicy Bypass -File .\install-task.ps1
```

會在工作排程器建立「Dashcam-Backup」，只有一個觸發：

- **插卡事件**：`Microsoft-Windows-Kernel-PnP/Configuration` 事件 410，延遲 30 秒。任何 USB 裝置插入都會觸發，但腳本找不到 SD 卡就立刻結束。沒有定時觸發，卡沒插就什麼都不會跑。

工作設成「只在使用者登入時執行」，通知才顯示得出來。不需要管理員權限。

檢查狀態：`.\install-task.ps1 -Check`；移除：`.\install-task.ps1 -Uninstall`。

## 手動執行與試跑

```powershell
powershell -ExecutionPolicy Bypass -File .\backup.ps1 -DryRun   # robocopy 只列清單、清理只預覽
powershell -ExecutionPolicy Bypass -File .\backup.ps1           # 正式執行
```

## 設定

都在 `backup.ps1` 開頭的設定區：

| 變數 | 預設 | 說明 |
|---|---|---|
| `$SourceLabel` | `MUFU V20S` | SD 卡標籤 |
| `$DestLabel` | `2T-2` | 外接硬碟標籤 |
| `$DestRootName` | `!!行車紀錄器` | 硬碟底下的根資料夾，**必須已存在**（防止接錯碟） |
| `$Folders` | Video 120 天 | 要備份的子資料夾與各自保留天數，0 = 永不清理。SD 卡上還有 `Event`、`Picture`，要加就多一列 |
| `$RetentionApply` | `$false` | **清理總開關**。第一次先預覽，看過 log 確認後改 `$true` |
| `$MinArrivalDays` | 7 | 檔案到達目的地滿幾天才可清 |
| `$MaxDeletePct` | 30 | 單次刪除超過總數幾 % 就中止並通知 |
| `$MaxFileAgeDays` | 400 | 修改時間比這舊或在未來，視為時鐘異常 |

## 清理的三道保險

行車紀錄器沒電時時鐘會歸零，錄出來的檔案日期可能變成很久以前，一複製過去就會被當成過期。所以：

1. **到達時間**：腳本在複製後把新檔案的建立時間改成當下，清理只碰到達滿 7 天的檔案。
2. **來源還在就不刪**：SD 卡上還存在的檔案一律不清（真正過期的檔案不可能還在卡上）。
3. **異常日期不刪**：修改時間早於 400 天前或在未來的檔案不清並跳通知。
4. **單次上限**：一次要刪超過 30% 的檔案就中止並通知，請人工確認。

清理只在 robocopy 沒有失敗時才跑。

## Log 與狀態

- `%LOCALAPPDATA%\dashcam-backup\logs\backup-<時間>.log`：腳本 log（UTF-8）
- `%LOCALAPPDATA%\dashcam-backup\logs\robocopy-<時間>.log`：robocopy 原始 log
- `%LOCALAPPDATA%\dashcam-backup\last-run.json`：最後一次執行摘要
- log 保留 30 天

## 排錯

| 現象 | 看哪裡 |
|---|---|
| 插卡沒反應 | 事件檢視器 → 應用程式及服務記錄檔 → Microsoft → Windows → Kernel-PnP → Configuration，確認有事件 410；工作排程器的「歷程記錄」看有沒有觸發 |
| 有觸發但沒通知 | `last-run.json` 與最新 `backup-*.log`；確認工作是「只在使用者登入時執行」 |
| 每次都重新複製 | robocopy log 看原因；FAT32 時間戳精度 2 秒，已用 `/FFT` 處理 |
| robocopy 回傳碼 | 1 有複製、2 目的地有多的檔（正常）、4 不符、8 有失敗、16 嚴重錯誤 |

## 刻意不做

- 不刪 SD 卡上的任何檔案，行車紀錄器自己循環覆寫。
- 不算 hash，影片寫完不會變，檔名＋大小＋時間夠用。
- 不動 `!!行車紀錄器` 底下 `Video` 以外的任何東西（那裡放的是申訴用的重要檔案）。
- 不備份 SD 卡的 `Event`、`Picture` 資料夾，不做定時備援（使用者決定）。
