-- 메뉴잇 x KT - Supabase 초기 설정 SQL
-- Supabase Dashboard > SQL Editor에서 전체 실행하세요.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '영업사원',
  role text not null default 'sales' check (role in ('admin','team_lead','sales')),
  team text not null default '영업팀',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  lead_no bigint generated always as identity unique,
  source_type text not null default '인바운드',
  source_channel text not null default '전화',
  customer_type text not null default '매장 사장님',
  business_name text,
  customer_name text not null,
  phone text not null,
  region text,
  interested_products text[] not null default '{}',
  product_notes jsonb not null default '{}'::jsonb,
  support_flags text[] not null default '{}',
  standard_support_amount numeric(12,0) not null default 0,
  additional_gift_amount numeric(12,0) not null default 0,
  penalty_support_amount numeric(12,0) not null default 0,
  cash_support_request_amount numeric(12,0) not null default 0,
  support_memo text,
  current_carrier text,
  contract_end_date date,
  assigned_to uuid references public.profiles(id) on delete set null,
  status text not null default '신규 DB',
  next_follow_up_at timestamptz,
  last_contact_at timestamptz,
  expected_value numeric(12,0) not null default 0,
  failure_reason text,
  memo text,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- 기존 CRM에 상품별 메모 칼럼이 없을 때 안전하게 추가
alter table public.leads add column if not exists product_notes jsonb not null default '{}'::jsonb;

-- 기존 데이터는 유지하고 지원금/사은품 관련 칼럼만 추가
alter table public.leads add column if not exists support_flags text[] not null default '{}';
alter table public.leads add column if not exists standard_support_amount numeric(12,0) not null default 0;
alter table public.leads add column if not exists additional_gift_amount numeric(12,0) not null default 0;
alter table public.leads add column if not exists penalty_support_amount numeric(12,0) not null default 0;
alter table public.leads add column if not exists cash_support_request_amount numeric(12,0) not null default 0;
alter table public.leads add column if not exists support_memo text;

create index if not exists leads_phone_idx on public.leads(phone);
create index if not exists leads_status_idx on public.leads(status);
create index if not exists leads_assigned_idx on public.leads(assigned_to);
create index if not exists leads_followup_idx on public.leads(next_follow_up_at);
create index if not exists leads_deleted_idx on public.leads(deleted_at);

create table if not exists public.lead_notes (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id) on delete cascade,
  content text not null,
  follow_up_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists lead_notes_lead_idx on public.lead_notes(lead_id, created_at desc);

create table if not exists public.activities (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references public.leads(id) on delete cascade,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists activities_lead_idx on public.activities(lead_id, created_at desc);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists leads_set_updated_at on public.leads;
create trigger leads_set_updated_at before update on public.leads
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  existing_count integer;
begin
  select count(*) into existing_count from public.profiles;
  insert into public.profiles (id, display_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1), '영업사원'),
    case when existing_count = 0 then 'admin' else 'sales' end
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.is_manager()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin','team_lead') and is_active = true
  );
$$;

alter table public.profiles enable row level security;
alter table public.leads enable row level security;
alter table public.lead_notes enable row level security;
alter table public.activities enable row level security;

-- 프로필
create policy "profiles_select_authenticated" on public.profiles
for select to authenticated using (true);
create policy "profiles_update_self_or_manager" on public.profiles
for update to authenticated
using (id = auth.uid() or public.is_manager())
with check (id = auth.uid() or public.is_manager());

-- 영업 DB: 로그인 사용자는 전체 조회·등록·수정 가능. 삭제/복원은 팀장 이상만 가능.
create policy "leads_select_authenticated" on public.leads
for select to authenticated using (true);
create policy "leads_insert_authenticated" on public.leads
for insert to authenticated with check (true);
create policy "leads_update_active_or_manager" on public.leads
for update to authenticated
using (deleted_at is null or public.is_manager())
with check (deleted_at is null or public.is_manager());

-- 상담 이력
create policy "notes_select_authenticated" on public.lead_notes
for select to authenticated using (true);
create policy "notes_insert_authenticated" on public.lead_notes
for insert to authenticated with check (true);
create policy "notes_update_own_or_manager" on public.lead_notes
for update to authenticated
using (created_by = auth.uid() or public.is_manager())
with check (created_by = auth.uid() or public.is_manager());

-- 활동 이력
create policy "activities_select_authenticated" on public.activities
for select to authenticated using (true);
create policy "activities_insert_authenticated" on public.activities
for insert to authenticated with check (true);

-- 실시간 변경 구독
alter publication supabase_realtime add table public.leads;
alter publication supabase_realtime add table public.lead_notes;
alter publication supabase_realtime add table public.activities;
