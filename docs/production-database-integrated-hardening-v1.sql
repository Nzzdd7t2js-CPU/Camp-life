-- 風餐露宿 CAMP LIFE｜正式資料庫整合修正 v1
-- 將認領人工核實 migration 與正式權限修正合併為一次交易。
-- 依據：2026-11-22 Supabase 唯讀盤點 CSV、目前 main 分支 public/index.html。
-- 不刪除或改寫既有營區、會員、投稿及認領申請資料。
-- 不涉及 Storage bucket / 照片，也不會自動驗證 Email、簡訊或官方網站。
--
-- 執行前須知：
-- 1. 使用 Supabase SQL Editor，以資料庫管理者身分執行整份。
-- 2. 若任一前置檢查失敗，整份交易會回滾，不會留下半套修改。
-- 3. 此腳本不代表已完成 Cloudflare 部署。
--
begin;

-- 前置檢查：必要資料表、RLS 與函式存在；並確認重要欄位型別符合現有 RPC。
do $preflight$
declare
  t text;
  r record;
begin
  foreach t in array array[
    'profiles','campsites','campsite_availability','claim_requests',
    'journals','reviews','market_items','favorites'
  ]
  loop
    select c.relrowsecurity into r
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname=t;
    if not found then
      raise exception '必要資料表 public.% 不存在；整份修正已中止。', t;
    end if;
    if r.relrowsecurity is not true then
      raise exception 'public.% 尚未啟用 RLS；整份修正已中止。', t;
    end if;
  end loop;

  if to_regprocedure('public.is_site_admin()') is null then
    raise exception '找不到 public.is_site_admin()；整份修正已中止。';
  end if;
  if to_regclass('public.claim_requests') is null
     or to_regclass('public.claim_audit_logs') is not null then
    -- claim_audit_logs 已存在時允許重跑；僅保留此分支供可讀性。
    null;
  end if;
  if (select data_type from information_schema.columns
      where table_schema='public' and table_name='claim_requests' and column_name='id') <> 'uuid' then
    raise exception 'claim_requests.id 不是 uuid；整份修正已中止。';
  end if;
  if (select data_type from information_schema.columns
      where table_schema='public' and table_name='claim_requests' and column_name='campsite_id') <> 'text' then
    raise exception 'claim_requests.campsite_id 不是 text；整份修正已中止。';
  end if;
  if (select data_type from information_schema.columns
      where table_schema='public' and table_name='campsites' and column_name='id') <> 'text' then
    raise exception 'campsites.id 不是 text；整份修正已中止。';
  end if;
end
$preflight$;

-- 第一部分：認領人工核實與稽核紀錄。
alter table public.claim_requests
  add column if not exists verification_method text,
  add column if not exists verification_target text,
  add column if not exists verification_status text not null default 'unverified',
  add column if not exists verification_note text,
  add column if not exists verification_checked_at timestamptz,
  add column if not exists verification_checked_by uuid references public.profiles(id),
  add column if not exists review_reason text,
  add column if not exists reviewed_at timestamptz;

update public.claim_requests
set verification_status = 'unverified'
where verification_status is null
   or verification_status not in ('unverified','needs_more_info','verified','failed');

alter table public.claim_requests
  alter column verification_status set default 'unverified',
  alter column verification_status set not null;

revoke insert on table public.claim_requests from anon, public, authenticated;
grant insert (
  user_id,
  campsite_id,
  campsite_name,
  address,
  proof_note,
  verification_method,
  verification_target
) on table public.claim_requests to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.claim_requests'::regclass
      and conname = 'claim_requests_verification_status_check'
  ) then
    alter table public.claim_requests
      add constraint claim_requests_verification_status_check
      check (verification_status in ('unverified','needs_more_info','verified','failed'));
  end if;
end $$;

create table if not exists public.claim_audit_logs (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references public.claim_requests(id) on delete cascade,
  actor_user_id uuid references public.profiles(id),
  action text not null check (action in ('verification_set','approved','rejected')),
  note text,
  created_at timestamptz not null default now()
);

alter table public.claim_audit_logs enable row level security;
revoke all privileges on table public.claim_audit_logs from anon, authenticated;
grant select on table public.claim_audit_logs to authenticated;

drop policy if exists claim_audit_admin_read on public.claim_audit_logs;
create policy claim_audit_admin_read on public.claim_audit_logs
  for select to authenticated using (public.is_site_admin());

create or replace function public.set_claim_verification(
  target_claim_id uuid,
  new_verification_status text,
  admin_note text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare r public.claim_requests%rowtype;
begin
  if not public.is_site_admin() then
    raise exception '只有網站業主可以設定認領驗證結果';
  end if;
  if new_verification_status not in ('needs_more_info','verified','failed') then
    raise exception '不允許的驗證狀態';
  end if;

  select * into r
  from public.claim_requests
  where id = target_claim_id
  for update;

  if not found then raise exception '找不到認領申請'; end if;
  if r.status <> 'pending' then raise exception '只有待審核申請可以變更驗證狀態'; end if;
  if new_verification_status = 'verified' and (
    nullif(trim(r.verification_method), '') is null
    or nullif(trim(r.verification_target), '') is null
    or nullif(trim(admin_note), '') is null
  ) then
    raise exception '核實前必須具備驗證方式、可核對管道及核對依據';
  end if;

  update public.claim_requests
  set verification_status = new_verification_status,
      verification_note = nullif(trim(admin_note), ''),
      verification_checked_at = now(),
      verification_checked_by = auth.uid()
  where id = target_claim_id;

  insert into public.claim_audit_logs(claim_id, actor_user_id, action, note)
  values (target_claim_id, auth.uid(), 'verification_set',
          '驗證狀態：' || new_verification_status ||
          case when nullif(trim(admin_note), '') is null then '' else '；' || trim(admin_note) end);
end;
$$;

revoke all on function public.set_claim_verification(uuid,text,text) from public;
grant execute on function public.set_claim_verification(uuid,text,text) to authenticated;

create or replace function public.review_campsite_claim(claim_id uuid, approve boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r public.claim_requests%rowtype;
  existing_owner uuid;
begin
  if not public.is_site_admin() then
    raise exception '只有網站業主可以審核認領申請';
  end if;

  select * into r
  from public.claim_requests
  where id = claim_id
  for update;

  if not found then raise exception '找不到認領申請'; end if;
  if r.status <> 'pending' then raise exception '此申請已經處理'; end if;

  if approve then
    if r.verification_status <> 'verified' then
      raise exception '必須先完成營主管道與營區關聯核實，才能核准認領';
    end if;
    if r.campsite_id is null then
      raise exception '申請未綁定營區，無法核准';
    end if;

    select owner_user_id into existing_owner
    from public.campsites
    where id = r.campsite_id
    for update;

    if not found then raise exception '找不到此營區'; end if;
    if existing_owner is not null and existing_owner <> r.user_id then
      raise exception '此營區已由其他營主認領，不能重複轉移';
    end if;

    update public.campsites
    set owner_user_id = r.user_id
    where id = r.campsite_id;

    update public.profiles
    set role = case when role = 'owner_admin' then role else 'camp_owner' end
    where id = r.user_id;

    update public.claim_requests
    set status = 'approved',
        reviewed_by = auth.uid(),
        reviewed_at = now(),
        review_reason = coalesce(verification_note, '驗證完成，核准認領')
    where id = claim_id;

    insert into public.claim_audit_logs(claim_id, actor_user_id, action, note)
    values (claim_id, auth.uid(), 'approved', '認領核准');
  else
    update public.claim_requests
    set status = 'rejected',
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = claim_id;

    insert into public.claim_audit_logs(claim_id, actor_user_id, action, note)
    values (claim_id, auth.uid(), 'rejected', '認領退回');
  end if;
end;
$$;

revoke all on function public.review_campsite_claim(uuid,boolean) from public;
grant execute on function public.review_campsite_claim(uuid,boolean) to authenticated;

select column_name, data_type, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'claim_requests'
  and column_name in (
    'verification_method','verification_target','verification_status',
    'verification_note','verification_checked_at','verification_checked_by',
    'review_reason','reviewed_at'
  )
order by column_name;

select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename = 'claim_audit_logs'; 
-- 第二部分：資料表權限、投稿審核與營主空位政策。
revoke truncate, references, trigger
on table public.profiles, public.campsites, public.campsite_availability,
         public.claim_requests, public.journals, public.reviews,
         public.market_items, public.favorites
from public, anon, authenticated;

revoke insert, update, delete
on table public.profiles, public.campsites, public.campsite_availability,
         public.claim_requests, public.journals, public.reviews,
         public.market_items, public.favorites
from anon;

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

grant select, insert, update, delete
on table public.campsite_availability
to authenticated;

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

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('journals','reviews','market_items','campsite_availability')
order by tablename, policyname;

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
commit;

-- 驗收 A：確認認領驗證欄位與稽核表。
select column_name, data_type, column_default
from information_schema.columns
where table_schema='public' and table_name='claim_requests'
  and column_name in (
    'verification_method','verification_target','verification_status',
    'verification_note','verification_checked_at','verification_checked_by',
    'review_reason','reviewed_at'
  )
order by column_name;

select tablename, rowsecurity
from pg_tables
where schemaname='public' and tablename='claim_audit_logs';

-- 驗收 B：確認投稿與空位政策。
select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname='public'
  and tablename in ('journals','reviews','market_items','campsite_availability','claim_audit_logs')
order by tablename, policyname;

-- 驗收 C：確認匿名角色沒有應用資料表寫入及高風險權限。
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema='public'
  and table_name in (
    'profiles','campsites','campsite_availability','claim_requests',
    'journals','reviews','market_items','favorites','claim_audit_logs'
  )
  and grantee in ('anon','authenticated','PUBLIC')
  and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')
order by table_name, grantee, privilege_type;

-- 注意：claim_requests 的驗證狀態、核實人及審核欄位只由管理者 RPC 修改。
-- 既有申請預設為 unverified；必須人工核實後才能核准。
