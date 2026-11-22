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

-- B. 日誌：只能以 pending 投稿；作者不得自行更新狀態或內容。
drop policy if exists journals_insert_self on public.journals;
create policy journals_insert_self
  on public.journals
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

drop policy if exists journals_update_self_admin on public.journals;
drop policy if exists journals_admin_update_only on public.journals;
create policy journals_admin_update_only
  on public.journals
  for update
  to authenticated
  using (public.is_site_admin())
  with check (public.is_site_admin());

-- C. 評論：只能以 pending 投稿；作者不得自行更新審核狀態。
drop policy if exists reviews_insert_self on public.reviews;
create policy reviews_insert_self
  on public.reviews
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

drop policy if exists reviews_update_self_admin on public.reviews;

-- D. 二手裝備：只能以 pending 投稿；作者不得自行更新審核狀態。
drop policy if exists market_insert_self on public.market_items;
create policy market_insert_self
  on public.market_items
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

drop policy if exists market_update_self_admin on public.market_items;

-- E. 空位：移除角色範圍過寬的舊 ALL policy，改用明確的 authenticated policies。
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

-- F. 驗收查詢：確認投稿與空位政策已更新。
select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('journals','reviews','market_items','campsite_availability')
order by tablename, policyname;

-- G. 驗收查詢：確認 anon 不再有 INSERT / UPDATE / DELETE / TRUNCATE。
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
