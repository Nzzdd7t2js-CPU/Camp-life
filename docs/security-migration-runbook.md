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


## 七、依 2026-11-22 正式 Supabase 唯讀盤點新增的修正

### 新增修正腳本
- `docs/production-permission-hardening-v2.sql`（commit `3700cd781247236d7a055bdc8067520514d42019`）
- 依使用者上傳的 757 筆盤點 CSV 編寫，尚未在正式 Supabase 執行。
- 撤銷 anon 的 INSERT／UPDATE／DELETE，並移除 PUBLIC、anon、authenticated 對指定應用資料表的 TRUNCATE／REFERENCES／TRIGGER。
- 日誌、評論、二手裝備投稿要求 status='pending'；移除作者自行更新政策。
- 空位政策改為 authenticated 營主本人可管理，並要求 updated_by = auth.uid()。
- 不刪除或更新任何現有內容資料；不撤銷 authenticated 的一般 INSERT／UPDATE／DELETE 表級權限，避免直接中斷既有功能，仍由 RLS 限制資料列。

### 正式環境盤點的重要更正
- CSV 顯示正式環境 `review_campsite_claim` 已經有營區列鎖定及 existing_owner 檢查，會拒絕把已由其他帳號認領的營區轉給新帳號。這項防重複認領保護已存在，不應再說正式環境沒有此保護。
- 但正式環境尚無 `claim_audit_logs` 與 `set_claim_verification`；人工核實後才可核准的流程仍未上線。
- 所有 8 張盤點資料表均已啟用 RLS，但均未設定 FORCE ROW LEVEL SECURITY。
- CSV 顯示多張資料表曾授予 anon 或 authenticated 不必要的 TRUNCATE／REFERENCES／TRIGGER；新腳本優先移除這些權限。
- 新腳本尚未執行，需先確認備份可用，再執行並檢查檔尾兩組驗收結果。
