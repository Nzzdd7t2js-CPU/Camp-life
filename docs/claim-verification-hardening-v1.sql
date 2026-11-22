-- 風餐露宿 CAMP LIFE｜認領驗證與審核安全增補 v1
-- 目的：讓「驗證完成」成為核准營區認領的必要條件，並保留可追溯的審核紀錄。
-- 安全特性：
-- 1. 不刪除或改寫既有申請；既有申請預設為 unverified，因此不能直接核准。
-- 2. 不收集身分證影本、不建立公開 Storage bucket。
-- 3. 會員不能自行修改驗證狀態、驗證人、審核人或審核結果。
-- 4. 僅網站業主可透過 RPC 設定驗證結果及審核。
-- 執行前請先確認 Supabase 備份可用；本檔尚未在正式資料庫執行。

begin;

alter table public.claim_requests
  add column if not exists verification_method text,
  add column if not exists verification_target text,
  add column if not exists verification_status text not null default 'unverified',
  add column if not exists verification_note text,
  add column if not exists verification_checked_at timestamptz,
  add column if not exists verification_checked_by uuid references public.profiles(id),
  add column if not exists review_reason text,
  add column if not exists reviewed_at timestamptz;

-- 限制狀態值；若欄位已存在，先清理不在允許範圍的值再加約束。
update public.claim_requests
set verification_status = 'unverified'
where verification_status is null
   or verification_status not in ('unverified','needs_more_info','verified','failed');

alter table public.claim_requests
  alter column verification_status set default 'unverified',
  alter column verification_status set not null;

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

-- 審核稽核紀錄：不存放證件影本或驗證碼。
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

-- 只有網站業主可以將人工核對結果寫入申請。
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

-- 保留原本 RPC 名稱與參數，避免前端既有呼叫失效。
-- 新增必要條件：必須先完成驗證，且不可覆蓋其他營主。
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

commit;

-- 執行後唯讀檢查：新欄位及稽核表是否存在。
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

-- 注意：此版本是人工核實的安全流程骨架，不會自動寄送 Email／簡訊或驗證官方網站。
-- 在選定郵件／簡訊供應商並完成伺服器端驗證前，不得把「verified」描述為自動驗證成功。
