# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 專案名稱
dashcam-backup

## 對話開始時請先讀
進度與最近更動都在 Obsidian：`創作庫/dashcam-backup/dashcam-backup-工作筆記.md`

## 🕳️ 已知地雷（動工前必讀）
- robocopy 摘要表頭隨環境變語言：對話裡跑是英文 `Files :`，排程器跑是中文 `檔案 :`；`Get-RobocopySummary` 兩種都要認，改 regex 時兩種都要測。
- robocopy `/UNILOG` 實測寫出 ANSI；讀 log 先看 BOM 決定編碼。
- robocopy 保留來源 CreationTime，「到達時間」是腳本複製後自己標的，別拿建立時間反推複製時間。
- `%LOCALAPPDATA%\dashcam-backup\` 的狀態檔在 Claude 工具裡看到的可能是覆蓋層假象（見全域記憶 pitfall-localappdata-overlay）；驗證排程產物用排程器跑 `dir` 輸出到新檔。
- 插卡觸發用 StorageVolume/Operational 1001，**不要用 Kernel-PnP/Configuration 410**：2026-09-04 實測拔插卡完全沒有 410（只在裝置首次設定時記），1001 每次都有。換訊號前先實際拔插一次、掃全部記錄檔看哪個有動。
- 保留清理總開關 `$RetentionApply` 預設 `$false`，要使用者看過預覽 log 才可改 `$true`。

## 工作模式
- **結束工作**：說「收工」→ 自動 commit + push + 更新 Obsidian 工作筆記
- **接續工作**：說「開工」→ 讀工作筆記、報告 git 狀態、建議下一步

## 三個家
- 📋 本機：`~/Desktop/Claude/dashcam-backup/`
- 🐙 GitHub：https://github.com/kadasup/dashcam-backup
- 📘 Obsidian：`創作庫/dashcam-backup/dashcam-backup-工作筆記.md`
