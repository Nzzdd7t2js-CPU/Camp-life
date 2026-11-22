-- 風餐露宿 CAMP LIFE｜claim_requests 最小權限補強
-- 執行前請確認已備份 Supabase 專案。
-- 本腳本不刪除/更新任何資料、不改 RLS policy、不改審核 RPC。
-- 目的：
-- 1) anon 不需要存取 claim_requests：撤銷其表級權限。
-- 2) authenticated 只保留 SELECT，以及建立申請所需的指定欄位 INSERT。
-- 3) 會員不能自行 INSERT status、reviewed_by、id、created_at。
-- 4) 移除不需要的 TRUNCATE / REFERENCES / TRIGGER 權限。

begin;

revoke all privileges on table public.claim_requests from anon;

revoke truncate, references, trigger
on table public.claim_requests
from authenticated;

revoke insert
on table public.claim_requests
from authenticated;

grant insert (
  user_id,
  campsite_id,
  campsite_name,
  address,
  proof_note
)
on table public.claim_requests
to authenticated;

commit;

-- 執行後請用 docs/claim-privacy-readonly-audit.sql 的第 4 項及下列查詢複查：
select
  grantee,
  column_name,
  privilege_type
from information_schema.column_privileges
where table_schema = 'public'
  and table_name = 'claim_requests'
  and grantee in ('anon','authenticated')
  and privilege_type in ('INSERT','UPDATE','DELETE','REFERENCES')
order by grantee, column_name, privilege_type;

-- 預期：
-- anon 不應再有任何欄位權限。
-- authenticated 的 INSERT 只應出現在 user_id、campsite_id、
-- campsite_name、address、proof_note。
-- authenticated 仍保留 SELECT（由既有 RLS 限制只能讀自己的申請或管理員讀取）。
