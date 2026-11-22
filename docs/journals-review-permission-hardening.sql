-- 風餐露宿 CAMP LIFE：內容審核權限修正
-- 目的：
-- 1. 一般會員只能新增自己的「待審核」日誌、評論及二手裝備。
-- 2. 一般會員不能直接修改日誌狀態繞過審核；日誌更新僅限網站業主。
-- 3. 評論及二手裝備的審核狀態由既有管理者政策控制。
-- 此 migration 不刪除任何內容、不變更既有資料。
-- 請先確認線上 schema 與政策名稱，再由管理者於 Supabase SQL Editor 執行。

begin;

-- 會員投稿只能以 pending 狀態新增，避免直接透過 API 建立公開內容。
drop policy if exists journals_insert_self on public.journals;
create policy journals_insert_self
  on public.journals
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

drop policy if exists reviews_insert_self on public.reviews;
create policy reviews_insert_self
  on public.reviews
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

drop policy if exists market_insert_self on public.market_items;
create policy market_insert_self
  on public.market_items
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'pending');

-- 投稿者不得自行將日誌改成公開；只有網站業主可以更新審核狀態。
drop policy if exists journals_update_self_admin on public.journals;
drop policy if exists journals_admin_update_only on public.journals;
create policy journals_admin_update_only
  on public.journals
  for update
  to authenticated
  using (public.is_site_admin())
  with check (public.is_site_admin());

commit;
