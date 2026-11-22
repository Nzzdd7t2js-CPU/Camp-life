-- 風餐露宿 CAMP LIFE：日誌審核權限修正
-- 目的：一般會員只能新增自己的待審核日誌；只有網站業主能修改日誌審核狀態。
-- 此 migration 不刪除日誌、不變更既有資料，也不影響已公開日誌的讀取。
-- 請先確認目前線上 schema 與政策名稱，再由管理者於 Supabase SQL Editor 執行。

begin;

drop policy if exists journals_update_self_admin on public.journals;

drop policy if exists journals_admin_update_only on public.journals;
create policy journals_admin_update_only
  on public.journals
  for update
  to authenticated
  using (public.is_site_admin())
  with check (public.is_site_admin());

commit;
