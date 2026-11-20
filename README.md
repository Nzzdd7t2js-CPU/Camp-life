# 風餐露宿 CAMP LIFE v2

以現有 1,804 筆營區 CSV 重建的靜態網站 + Supabase 後端專案。

## 專案內容
- `public/index.html`：響應式網站前台、營區詳細資料、登入、營主/業主管理入口、日誌、評論、裝備交流。
- `public/data/campsites.json`：由原始 `Campsite_export.csv` 轉換的 1,804 筆資料。
- `database_setup.sql`：Supabase 權限、認領核准、營主綁定、收藏與電話修正。
- `src/index.js`、`wrangler.jsonc`：更新既有 Cloudflare Worker `black-unit-0ca4` 的靜態資產入口。

## 免費優先
Cloudflare Workers Free、Supabase Free、GitHub Free。各服務免費額度與閒置政策依供應商當期規則；不保證超額或未來永遠免費。

## 重要
1. 不要刪除既有 Supabase 專案或 Base44 專案。
2. 這個專案的 Worker 名稱固定為 `black-unit-0ca4`，只有部署到原本 Cloudflare 帳號才能保留原 workers.dev 網址。
3. `database_setup.sql` 是增補/權限腳本，不會刪除 campsites 資料。執行前仍應在 Supabase 建立備份。
4. 第一次建立網站業主：先在網站註冊，再把 SQL 最後一行註解的 email 換成你的登入 Email 執行。
5. Supabase 前端使用既有 publishable key；不可把 service_role key 放進網站。
6. 正式營運前仍需實際測試會員驗證、認領核准、營主管理、業主管理、評論與刊登流程。

## 部署指令（需要 Node.js 環境）
```bash
npm install
npx wrangler login
npx wrangler deploy
```
