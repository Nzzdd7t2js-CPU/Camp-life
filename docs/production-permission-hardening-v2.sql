-- 風餐露宿 CAMP LIFE｜正式環境權限修正 v2
-- 根據 2026-11-22 Supabase 唯讀盤點 CSV 編寫。
-- 本 migration 不刪除或更新任何營區、會員、日誌、評論或裝備資料。
-- 主要修正：
-- 1. 撤銷 anon 對應用資料表的寫入與 TRUNCATE 等危險權限。
-- 2. 撤銷 anon / authenticated / PUBLIC 不必要的 TRUNCATE、REFERENCES、TRIGGER。
-- 3. 投稿必須以 pending 狀態建立；投稿者不能自行更新審核狀態。
-- 4. 空位管理僅允許 authenticated 營主管理自己的營區。
-- 請先確認 Supabase 備份可用，再執行。執行後請依檔尾查詢驗收。

begin;

-- A. 收斂資料表層級的高風險權限。
-- 不撤銷 authenticated 原有的正常 INSERT / UPDATE / DELETE 權限，
-- 以免無意間中斷網站既有功能；實際資料列仍受 RLS 限制。
revoke truncate, references, trigger
on table public.profiles, public.campsites, public.campsite_availability,
         public.claim_requests, public.journals, public.reviews,
         public.market_items, public.favorites
from public, anon, authenticated;

-- anon 不應能新增、修改或刪除任何會員／營主資料。
-- 保留原有 SELECT 權限，公開讀取仍由 RLS 控制。
revoke insert, update, delete
on table public.profiles, public.campsites, public.campsite_availability,
         public.claim_requests, public.journals, public.reviews,
         public.market_items, public.favorites
from anon;

-- A2. CSV 同時顯示 anon 有欄位層級 INSERT / UPDATE / REFERENCES。
-- 撤銷這些欄位授權；單純 REVOKE 表層級權限不會自動移除欄位層級授權。
do $audit$
declare
  r record;
  cols text;
begin
  for r in
    select table_name, privilege_type
    from information_schema.role_column_grants
    where table_schema = 'public'
      and table_name in (
        'profiles','campsites','campsite_availability','claim_requests',
        'journals','reviews','market_items','favorites'
      )
      and grantee = 'anon'
      and privilege_type in ('INSERT','UPDATE','REFERENCES')
    group by table_name, privilege_type
  loop
    select string_agg(quote_ident(column_name), ', ')
      into cols
    from information_schema.role_column_grants
    where table_schema = 'public'
      and table_name = r.table_name
      and grantee = 'anon'
      and privilege_type = r.privilege_type;

    if cols is not null then
      execute format(
        'REVOKE %s (%s) ON TABLE public.%I FROM anon',
        r.privilege_type, cols, r.table_name
      );
    end if;
  end loop;
end
$audit$;

-- B. 日誌：只能以 pending 投稿；作者可編輯自己的內容，但不能改審核狀態。
drop policy if exists journals_insert_self on public.journals;
create policy journals_insert_self
  on public.journals
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

-- C. 評論：只能以 pending 投稿；保留原有作者編輯政策，但禁止作者改審核狀態。
drop policy if exists reviews_insert_self on public.reviews;
create policy reviews_insert_self
  on public.reviews
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

-- D. 二手裝備：只能以 pending 投稿；保留原有作者編輯政策，但禁止作者改審核狀態。
drop policy if exists market_insert_self on public.market_items;
create policy market_insert_self
  on public.market_items
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

-- E. 以資料庫 trigger 保護審核狀態，避免為了防止改狀態而剝奪作者正常編輯內容的能力。
create or replace function public.prevent_member_content_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $guard$
begin
  if old.status is distinct from new.status
     and not public.is_site_admin() then
    raise exception '投稿者不能自行修改審核狀態';
  end if;
  return new;
end;
$guard$;

revoke all on function public.prevent_member_content_status_change() from public;
grant execute on function public.prevent_member_content_status_change() to authenticated;

drop trigger if exists journals_guard_status on public.journals;
create trigger journals_guard_status
before update on public.journals
for each row execute function public.prevent_member_content_status_change();

drop trigger if exists reviews_guard_status on public.reviews;
create trigger reviews_guard_status
before update on public.reviews
for each row execute function public.prevent_member_content_status_change();

drop trigger if exists market_items_guard_status on public.market_items;
create trigger market_items_guard_status
before update on public.market_items
for each row execute function public.prevent_member_content_status_change();

-- F. 空位：明確授予登入會員必要的資料表操作權；實際可操作資料列仍由下方 RLS 限制。
-- database_setup.sql 原本未明確授予 campsite_availability 寫入權，只有 policy 不足以讓營主透過 API 寫入。
grant select, insert, update, delete
on table public.campsite_availability
to authenticated;

-- 移除角色範圍過寬的舊 ALL policy，改用明確的 authenticated policies。
drop policy if exists availability_owner_write on public.campsite_availability;
drop policy if exists availability_owner_insert on public.campsite_availability;
drop policy if exists availability_owner_update on public.campsite_availability;
drop policy if exists availability_owner_delete on public.campsite_availability;
drop policy if exists availability_admin_all on public.campsite_availability;

create policy availability_owner_insert
  on public.campsite_availability
  for insert
  to authenticated
  with check (
    updated_by = auth.uid()
    and exists (
      select 1 from public.campsites c
      where c.id = campsite_id
        and c.owner_user_id = auth.uid()
    )
  );

create policy availability_owner_update
  on public.campsite_availability
  for update
  to authenticated
  using (
    exists (
      select 1 from public.campsites c
      where c.id = campsite_id
        and c.owner_user_id = auth.uid()
    )
  )
  with check (
    updated_by = auth.uid()
    and exists (
      select 1 from public.campsites c
      where c.id = campsite_id
        and c.owner_user_id = auth.uid()
    )
  );

create policy availability_owner_delete
  on public.campsite_availability
  for delete
  to authenticated
  using (
    exists (
      select 1 from public.campsites c
      where c.id = campsite_id
        and c.owner_user_id = auth.uid()
    )
  );

create policy availability_admin_all
  on public.campsite_availability
  for all
  to authenticated
  using (public.is_site_admin())
  with check (public.is_site_admin());

commit;

-- G. 驗收查詢：確認投稿與空位政策已更新。
select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('journals','reviews','market_items','campsite_availability')
order by tablename, policyname;

-- H. 驗收查詢：確認 anon 不再有 INSERT / UPDATE / DELETE / TRUNCATE。
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in (
    'profiles','campsites','campsite_availability','claim_requests',
    'journals','reviews','market_items','favorites'
  )
  and grantee in ('anon','authenticated','PUBLIC')
  and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')
order by table_name, grantee, privilege_type;

-- 注意：此 migration 不包含認領驗證欄位及 set_claim_verification RPC。
-- 正式環境的 review_campsite_claim 已有「不可覆蓋其他營主」防護，
-- 但仍需另行加入「先人工核實、再核准」的流程。
