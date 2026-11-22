# 風餐露宿 CAMP LIFE｜安全修正與部署順序

本文件依目前 GitHub main 分支的程式碼與 SQL 腳本整理。它不是線上環境稽核報告；Supabase 實際政策、GRANT、函式定義仍須以正式資料庫查詢結果為準。

## 一、目前部署方式

- Cloudflare Worker：`black-unit-0ca4`
- 靜態入口：`public/index.html`
- 靜態資料：`public/data/campsites.json`（1,804 筆）
- 部署方式：需在原 Cloudflare 帳號登入的 Node.js / Wrangler 環境執行 `npm install`、`npx wrangler login`、`npx wrangler deploy`。
- GitHub 提交不等於 Cloudflare 已更新；本專案文件沒有設定 GitHub push 自動部署。

## 二、資料庫修正腳本與順序

### 已執行（使用者先前確認）
1. `docs/claim-requests-permission-hardening.sql`
   - 收斂 claim_requests 的 INSERT 欄位權限。
   - 先前使用者已在 Supabase 執行，結果畫面顯示只允許五個申請欄位。

### 尚未執行
2. `docs/claim-verification-hardening-v1.sql`
   - 新增人工核實欄位、稽核紀錄表及管理者 RPC。
   - 核准認領前必須先標記 verified。
   - 保留既有申請資料；既有申請預設為 unverified。
   - 不提供自動 Email／簡訊／DNS 驗證。

3. `docs/journals-review-permission-hardening.sql`
   - 會員投稿日誌、評論、二手裝備時必須為 pending。
   - 投稿者不能自行更新日誌審核狀態；日誌更新由網站業主管理。

## 三、建議正式操作順序

1. 先確認 Supabase 備份可用。
2. 在 Supabase 執行尚未執行的 migration；每份執行後都要檢查 SQL Editor 結果及腳本末尾的檢查查詢。
3. 完成資料庫修正後，再從原 Cloudflare Worker 專案部署網站。
4. 部署後依角色做驗收：未登入訪客、一般會員、營主、網站業主。
5. 若任何一步出現錯誤，先停止，不要重跑整份 `database_setup.sql`，也不要刪表或重建資料。

## 四、部署前必做驗收

- 一般會員不能將日誌、評論或裝備直接新增為 published。
- 一般會員不能修改別人的投稿，也不能自行把日誌改成 published。
- 一般會員不能修改 profiles.role 或其他人的個人資料。
- 未完成人工核實的認領不能核准。
- 已有其他營主的營區不能被第二個帳號接管。
- 營主只能更新自己已核准營區的空位；不能修改其他營區。
- 非網站業主不能呼叫管理者 RPC 成功。
- claim_requests 的聯絡資訊及核實管道只對申請者本人與網站業主可見。
- 公開的日誌／裝備照片目前使用公開 bucket；不得把身分證、私人文件或認領證明放進該 bucket。

## 五、尚未完成的核對

- 正式 Supabase 的 RLS、table grants、column grants、RPC 定義是否與 GitHub 腳本一致。
- `campsite_availability`、`journals`、`reviews`、`market_items`、`favorites` 的正式資料表權限是否完整授予且符合 RLS。
- 營主、會員及管理者在正式網站的完整端到端測試。
- Cloudflare Worker 實際部署版本與部署時間。

## 六、安全原則

- 不在前端放置 Supabase service_role key。
- 不將敏感認領文件存入公開 Storage bucket。
- 不把 GitHub commit、SQL 腳本存在或前端按鈕限制，誤稱為正式環境已生效。
- 不執行刪除資料、重建資料表或重設整個 Supabase 專案的操作，除非另有明確核准及可還原備份。
