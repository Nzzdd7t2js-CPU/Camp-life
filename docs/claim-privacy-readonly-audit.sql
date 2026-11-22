-- 風餐露宿 CAMP LIFE｜認領與個資權限唯讀盤點
-- 請在 Supabase SQL Editor 執行。本檔只有 SELECT，不會修改資料。
-- 執行後請把結果截圖或複製回 ChatGPT；請勿分享任何會員實際個資資料列。

-- 1. claim_requests 欄位、型別、預設值、是否允許 NULL
select
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'claim_requests'
order by ordinal_position;

-- 2. claim_requests / profiles / campsites 的 RLS 是否啟用及強制
select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('claim_requests','profiles','campsites')
order by c.relname;

-- 3. 三張表目前所有 RLS policies（只顯示政策定義，不讀取會員資料）
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('claim_requests','profiles','campsites')
order by tablename, policyname;

-- 4. 三張表對各資料庫角色的資料表層級權限
select
  grantee,
  table_name,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('claim_requests','profiles','campsites')
  and grantee in ('anon','authenticated','service_role')
order by table_name, grantee, privilege_type;

-- 5. claim_requests 相關函式定義（確認是否另有安全 RPC）
select
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as arguments,
  pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (p.proname ilike '%claim%' or p.proname ilike '%owner%')
order by p.proname;

-- 6. Storage buckets 的名稱及是否公開（不讀取檔案內容）
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
order by name;

-- 7. Storage 物件政策（不讀取檔案內容）
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
order by policyname;
