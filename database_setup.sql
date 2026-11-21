-- 風餐露宿 CAMP LIFE v2：Supabase 資料庫補齊與安全權限
-- 在 Supabase SQL Editor 執行。可重複執行；不會刪除既有營區資料。

create extension if not exists pgcrypto;

-- 補齊舊版可能缺少的欄位
alter table public.campsites add column if not exists owner_user_id uuid references public.profiles(id);
alter table public.claim_requests add column if not exists campsite_id text references public.campsites(id);
alter table public.claim_requests add column if not exists reviewed_by uuid references public.profiles(id);

-- 收藏
create table if not exists public.favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  campsite_id text not null references public.campsites(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, campsite_id)
);

-- 電話資料：只修正「9 開頭且剛好 9 碼」的手機，不碰市話及其他格式
update public.campsites
set phone = '0' || regexp_replace(phone, '\D', '', 'g')
where phone is not null
  and regexp_replace(phone, '\D', '', 'g') ~ '^9[0-9]{8}$';

-- 權限函式
create or replace function public.is_site_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.profiles where id = auth.uid() and role = 'owner_admin'); $$;

-- 認領審核：只有業主可以核准；核准時同時綁定營區與營主角色
create or replace function public.review_campsite_claim(claim_id uuid, approve boolean)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.claim_requests%rowtype;
begin
  if not public.is_site_admin() then raise exception '只有網站業主可以審核認領申請'; end if;
  select * into r from public.claim_requests where id = claim_id for update;
  if not found then raise exception '找不到認領申請'; end if;
  if r.status <> 'pending' then raise exception '此申請已經處理'; end if;
  if approve then
    if r.campsite_id is null then raise exception '申請未綁定營區，無法核准'; end if;
    update public.campsites set owner_user_id = r.user_id where id = r.campsite_id;
    update public.profiles set role = case when role = 'owner_admin' then role else 'camp_owner' end where id = r.user_id;
    update public.claim_requests set status='approved', reviewed_by=auth.uid() where id=claim_id;
  else
    update public.claim_requests set status='rejected', reviewed_by=auth.uid() where id=claim_id;
  end if;
end; $$;

-- RLS
alter table public.profiles enable row level security;
alter table public.campsites enable row level security;
alter table public.claim_requests enable row level security;
alter table public.journals enable row level security;
alter table public.reviews enable row level security;
alter table public.market_items enable row level security;
alter table public.favorites enable row level security;

-- 刪除本版同名政策後重建，避免重複政策
 drop policy if exists profiles_read_self_admin on public.profiles;
 drop policy if exists campsites_public_read on public.campsites;
 drop policy if exists campsites_admin_all on public.campsites;
 drop policy if exists campsites_owner_update on public.campsites;
 drop policy if exists claims_read_self_admin on public.claim_requests;
 drop policy if exists claims_insert_self on public.claim_requests;
 drop policy if exists journals_read on public.journals;
 drop policy if exists journals_insert_self on public.journals;
 drop policy if exists journals_update_self_admin on public.journals;
 drop policy if exists reviews_read on public.reviews;
 drop policy if exists reviews_insert_self on public.reviews;
 drop policy if exists market_read on public.market_items;
 drop policy if exists market_insert_self on public.market_items;
 drop policy if exists favorites_self on public.favorites;

create policy profiles_read_self_admin on public.profiles for select using (id = auth.uid() or public.is_site_admin());
create policy campsites_public_read on public.campsites for select using (true);
create policy campsites_admin_all on public.campsites for all using (public.is_site_admin()) with check (public.is_site_admin());
create policy campsites_owner_update on public.campsites for update using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());
create policy claims_read_self_admin on public.claim_requests for select using (user_id = auth.uid() or public.is_site_admin());
create policy claims_insert_self on public.claim_requests for insert with check (user_id = auth.uid());
create policy journals_read on public.journals for select using (status = 'published' or user_id = auth.uid() or public.is_site_admin());
create policy journals_insert_self on public.journals for insert with check (user_id = auth.uid());
create policy journals_update_self_admin on public.journals for update using (user_id = auth.uid() or public.is_site_admin()) with check (user_id = auth.uid() or public.is_site_admin());
create policy reviews_read on public.reviews for select using (status = 'published' or user_id = auth.uid() or public.is_site_admin());
create policy reviews_insert_self on public.reviews for insert with check (user_id = auth.uid());
create policy market_read on public.market_items for select using (status = 'published' or user_id = auth.uid() or public.is_site_admin());
create policy market_insert_self on public.market_items for insert with check (user_id = auth.uid());
create policy favorites_self on public.favorites for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 新會員自動建立一般會員資料
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$ begin
  insert into public.profiles(id,email,role) values(new.id,new.email,'member')
  on conflict(id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

-- 第一次建立網站業主：先在網站註冊一個帳號，再把下方 email 換成該帳號 Email 執行一次。
-- update public.profiles set role='owner_admin' where email='你的登入Email';


-- === CAMP LIFE 安全補強與管理功能（增補，不刪除既有營區資料） ===

-- 營主每日空位資料：公開唯讀，營主只能管理自己認領的營區，業主可完整管理。
create table if not exists public.campsite_availability (
  campsite_id text not null references public.campsites(id) on delete cascade,
  available_date date not null,
  remaining_slots integer not null default 0 check (remaining_slots >= 0),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  primary key (campsite_id, available_date)
);
alter table public.campsite_availability enable row level security;
drop policy if exists availability_public_read on public.campsite_availability;
drop policy if exists availability_owner_write on public.campsite_availability;
drop policy if exists availability_admin_all on public.campsite_availability;
create policy availability_public_read on public.campsite_availability
  for select using (true);
create policy availability_owner_write on public.campsite_availability
  for all using (
    exists (select 1 from public.campsites c
      where c.id = campsite_id and c.owner_user_id = auth.uid())
  ) with check (
    updated_by = auth.uid() and exists (select 1 from public.campsites c
      where c.id = campsite_id and c.owner_user_id = auth.uid())
  );
create policy availability_admin_all on public.campsite_availability
  for all using (public.is_site_admin()) with check (public.is_site_admin());

-- 防止同一營區被不同會員重複認領或轉移。
create or replace function public.review_campsite_claim(claim_id uuid, approve boolean)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.claim_requests%rowtype; existing_owner uuid;
begin
  if not public.is_site_admin() then raise exception '只有網站業主可以審核認領申請'; end if;
  select * into r from public.claim_requests where id = claim_id for update;
  if not found then raise exception '找不到認領申請'; end if;
  if r.status <> 'pending' then raise exception '此申請已經處理'; end if;
  if approve then
    if r.campsite_id is null then raise exception '申請未綁定營區，無法核准'; end if;
    select owner_user_id into existing_owner from public.campsites
      where id = r.campsite_id for update;
    if not found then raise exception '找不到此營區'; end if;
    if existing_owner is not null and existing_owner <> r.user_id then
      raise exception '此營區已由其他營主認領，不能重複轉移';
    end if;
    update public.campsites set owner_user_id = r.user_id where id = r.campsite_id;
    update public.profiles set role = case when role = 'owner_admin' then role else 'camp_owner' end where id = r.user_id;
    update public.claim_requests set status='approved', reviewed_by=auth.uid() where id=claim_id;
  else
    update public.claim_requests set status='rejected', reviewed_by=auth.uid() where id=claim_id;
  end if;
end; $$;
revoke all on function public.review_campsite_claim(uuid,boolean) from public;
grant execute on function public.review_campsite_claim(uuid,boolean) to authenticated;

-- 業主可管理評論及二手裝備的審核狀態。
drop policy if exists reviews_admin_manage on public.reviews;
drop policy if exists market_admin_manage on public.market_items;
create policy reviews_admin_manage on public.reviews
  for all using (public.is_site_admin()) with check (public.is_site_admin());
create policy market_admin_manage on public.market_items
  for all using (public.is_site_admin()) with check (public.is_site_admin());


-- === CAMP LIFE 業主會員管理與營主欄位權限收斂 ===

-- 營主不能直接更新營區任意欄位，只能透過受限 RPC 修改電話與價格說明。
drop policy if exists campsites_owner_update on public.campsites;
create or replace function public.update_owned_campsite_details(
  target_campsite_id text, new_phone text, new_price_note text
) returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.campsites
    where id = target_campsite_id
      and (owner_user_id = auth.uid() or public.is_site_admin())
  ) then
    raise exception '沒有權限修改此營區';
  end if;
  update public.campsites
    set phone = new_phone, price_note = new_price_note
    where id = target_campsite_id;
end;
$$;
revoke all on function public.update_owned_campsite_details(text,text,text) from public;
grant execute on function public.update_owned_campsite_details(text,text,text) to authenticated;

-- 網站業主管理會員角色；此函式不允許把一般會員升級為網站業主。
create or replace function public.set_member_role(target_user_id uuid, new_role text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_site_admin() then raise exception '只有網站業主可以管理會員身分'; end if;
  if new_role not in ('member','camp_owner') then
    raise exception '只允許設定一般會員或營主身分';
  end if;
  if target_user_id = auth.uid() then raise exception '不能透過此功能修改自己的業主身分'; end if;
  update public.profiles set role = new_role where id = target_user_id;
  if not found then raise exception '找不到會員'; end if;
end; $$;
revoke all on function public.set_member_role(uuid,text) from public;
grant execute on function public.set_member_role(uuid,text) to authenticated;


-- 修正 campsites 資料表層級權限：RLS 仍會限制只有網站業主可新增／更新。
grant insert, update on table public.campsites to authenticated;

-- 修正 profiles 表的資料表層級讀取權限（RLS policy 不會自動授予 SQL GRANT）
grant usage on schema public to authenticated;
grant select on table public.profiles to authenticated;
