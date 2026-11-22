-- 風餐露宿 CAMP LIFE｜會員投稿、營主空位與收藏權限唯讀盤點
-- 本檔只有 SELECT，不會修改資料、不會讀取會員實際內容。
-- 請在 Supabase SQL Editor 執行；回傳結果時請遮蔽任何實際個資。

-- 1. 相關資料表是否存在、RLS 是否啟用／強制
select n.nspname as schema_name, c.relname as table_name,
       c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'profiles','campsites','campsite_availability','claim_requests',
    'journals','reviews','market_items','favorites','claim_audit_logs'
  )
order by c.relname;

-- 2. 相關資料表全部 RLS policies
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in (
    'profiles','campsites','campsite_availability','claim_requests',
    'journals','reviews','market_items','favorites','claim_audit_logs'
  )
order by tablename, policyname;

-- 3. 相關資料表層級權限
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in (
    'profiles','campsites','campsite_availability','claim_requests',
    'journals','reviews','market_items','favorites','claim_audit_logs'
  )
  and grantee in ('anon','authenticated','service_role')
order by table_name, grantee, privilege_type;

-- 4. 欄位層級權限（特別檢查 role、owner_user_id、status、reviewed_by 等欄位）
select grantee, table_name, column_name, privilege_type
from information_schema.role_column_grants
where table_schema = 'public'
  and table_name in (
    'profiles','campsites','campsite_availability','claim_requests',
    'journals','reviews','market_items','favorites','claim_audit_logs'
  )
  and grantee in ('anon','authenticated','service_role')
order by table_name, grantee, column_name, privilege_type;

-- 5. 管理／營主管理 RPC 的定義與執行權限
select p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments,
       p.prosecdef as security_definer,
       p.proconfig as function_settings,
       pg_get_functiondef(p.oid) as definition,
       coalesce(array_to_string(p.proacl, ', '), '(default ACL)') as function_acl
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'is_site_admin','review_campsite_claim','set_claim_verification',
    'update_owned_campsite_details','set_member_role'
  )
order by p.proname;

-- 6. Storage buckets（僅名稱、公開狀態及限制）
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
order by name;

-- 7. Storage policies（只看政策定義，不讀取檔案）
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
order by policyname;
