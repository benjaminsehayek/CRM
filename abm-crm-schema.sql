-- =========================================================================
-- Crocs & Clicks ABM CRM — Database migration
-- Run this entire file in the Supabase SQL editor as one batch.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. ENUMS
-- -------------------------------------------------------------------------

create type deal_stage as enum (
  'target',
  'researched',
  'engaged',
  'meeting_set',
  'discovery',
  'proposal',
  'pilot',
  'closed_won',
  'closed_lost'
);

create type account_status as enum (
  'active',
  'archived',
  'deleted'
);

create type activity_type as enum (
  'call',
  'email',
  'sms',
  'meeting',
  'linkedin',
  'site_visit',
  'proposal',
  'note'
);

create type user_role as enum (
  'rep',
  'admin'
);

create type industry as enum (
  'auto_body',
  'paint',
  'electrical',
  'plumbing',
  'hvac',
  'roofing',
  'remodeling',
  'landscaping',
  'janitorial',
  'flooring',
  'concrete',
  'fence_deck',
  'pest_control',
  'pool_spa',
  'garage_door',
  'window_door',
  'solar',
  'tree_service',
  'cleaning',
  'auto_repair',
  'powersports',
  'other'
);

create type marketing_channel as enum (
  'google_ads',
  'meta_ads',
  'seo_agency',
  'yelp',
  'angi',
  'homeadvisor',
  'thumbtack',
  'nextdoor_ads',
  'bni',
  'chamber',
  'direct_mail',
  'radio',
  'tv',
  'billboard',
  'truck_signage',
  'referrals_only',
  'none',
  'unknown'
);

create type revenue_range as enum (
  'under_500k',
  '500k_1m',
  '1m_3m',
  '3m_5m',
  '5m_10m',
  'over_10m',
  'unknown'
);

create type employee_range as enum (
  '1_to_3',
  '4_to_10',
  '11_to_25',
  '26_to_50',
  '51_to_100',
  'over_100',
  'unknown'
);

create type spend_range as enum (
  'under_1k',
  '1k_2_5k',
  '2_5k_5k',
  '5k_10k',
  '10k_25k',
  'over_25k',
  'unknown'
);

create type fit_score as enum (
  'a',
  'b',
  'c',
  'd',
  'unrated'
);

create type lead_source as enum (
  'drive_by',
  'gbp_scrape',
  'referral_client',
  'referral_other',
  'chamber',
  'association',
  'cold_outbound',
  'inbound_website',
  'reddit_nextdoor',
  'event',
  'imported_list',
  'other'
);

-- -------------------------------------------------------------------------
-- 2. TABLES
-- -------------------------------------------------------------------------

-- profiles: one row per authenticated user
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role user_role not null default 'rep',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- accounts: the ABM unit
create table accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles(id),

  -- core
  name text not null,
  phone text,
  email text,
  website text,
  website_domain text generated always as (
    case
      when website is null or website = '' then null
      else lower(regexp_replace(website, '^(https?://)?(www\.)?([^/?#]+).*$', '\3'))
    end
  ) stored,

  -- address
  street text,
  city text,
  state text,
  zip text,

  -- abm fields (SMB qualification)
  industry industry,
  services text,
  annual_revenue_range revenue_range,
  employee_count_range employee_range,
  budget_range text,
  seasonality text,

  -- current marketing posture (your wedge)
  current_marketing_channels marketing_channel[] not null default '{}'::marketing_channel[],
  current_agency text,
  monthly_marketing_spend_range spend_range,
  competitor_agencies_mentioned text,

  -- qualification
  fit fit_score not null default 'unrated',

  -- pipeline
  deal_stage deal_stage not null default 'target',
  status account_status not null default 'active',

  -- cadence
  last_contact_date date,
  next_contact_date date,
  meeting_set boolean not null default false,
  meeting_at timestamptz,

  -- freeform
  notes text,
  lead_source lead_source,

  -- audit
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references profiles(id),
  updated_by uuid references profiles(id)
);

-- contacts: people at an account
create table contacts (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,

  first_name text not null,
  last_name text,
  title text,
  email text,
  phone text,
  mobile text,
  is_primary boolean not null default false,
  notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- activities: append-only log of every touch
create table activities (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  contact_id uuid references contacts(id) on delete set null,
  user_id uuid not null references profiles(id),

  type activity_type not null,
  subject text not null,
  body text,
  occurred_at timestamptz not null default now(),

  created_at timestamptz not null default now()
);

-- prospect_imports: audit log of CSV uploads
create table prospect_imports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id),
  filename text not null,
  total_rows int not null default 0,
  created_count int not null default 0,
  updated_count int not null default 0,
  skipped_count int not null default 0,
  created_at timestamptz not null default now()
);

-- saved_views: per-user filter presets
create table saved_views (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  name text not null,
  filters jsonb not null default '{}'::jsonb,
  sort_by text,
  sort_dir text check (sort_dir in ('asc', 'desc')),
  created_at timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- 3. INDEXES
-- -------------------------------------------------------------------------

create index idx_accounts_owner on accounts(owner_id);
create index idx_accounts_stage on accounts(deal_stage);
create index idx_accounts_state_city on accounts(state, city);
create index idx_accounts_next_contact on accounts(next_contact_date) where status = 'active';
create index idx_accounts_status on accounts(status);
create index idx_accounts_industry on accounts(industry);
create index idx_accounts_fit on accounts(fit);
create index idx_accounts_lead_source on accounts(lead_source);
create index idx_accounts_marketing_channels on accounts using gin (current_marketing_channels);
create unique index idx_accounts_domain_unique on accounts(website_domain) where website_domain is not null and status != 'deleted';

create index idx_contacts_account on contacts(account_id);
create index idx_contacts_primary on contacts(account_id) where is_primary = true;

create index idx_activities_account_time on activities(account_id, occurred_at desc);
create index idx_activities_user on activities(user_id);
create index idx_activities_contact on activities(contact_id);

create index idx_saved_views_user on saved_views(user_id);
create index idx_imports_user on prospect_imports(user_id);

-- -------------------------------------------------------------------------
-- 4. TRIGGERS
-- -------------------------------------------------------------------------

-- generic updated_at trigger
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger trg_profiles_updated before update on profiles for each row execute function set_updated_at();
create trigger trg_accounts_updated before update on accounts for each row execute function set_updated_at();
create trigger trg_contacts_updated before update on contacts for each row execute function set_updated_at();

-- auto-update last_contact_date on accounts when activities are logged
create or replace function update_account_last_contact()
returns trigger as $$
begin
  update accounts
  set last_contact_date = greatest(coalesce(last_contact_date, '1900-01-01'::date), new.occurred_at::date)
  where id = new.account_id;
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_activities_update_last_contact
after insert on activities
for each row
execute function update_account_last_contact();

-- ensure only one primary contact per account
create or replace function enforce_single_primary_contact()
returns trigger as $$
begin
  if new.is_primary then
    update contacts
    set is_primary = false
    where account_id = new.account_id and id != new.id;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_contacts_single_primary
after insert or update of is_primary on contacts
for each row
when (new.is_primary = true)
execute function enforce_single_primary_contact();

-- auto-create a profiles row when a new auth user is created
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    'rep'
  );
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_auth_user_created
after insert on auth.users
for each row
execute function handle_new_user();

-- -------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- -------------------------------------------------------------------------

alter table profiles enable row level security;
alter table accounts enable row level security;
alter table contacts enable row level security;
alter table activities enable row level security;
alter table prospect_imports enable row level security;
alter table saved_views enable row level security;

-- helper: is current user an admin?
create or replace function is_admin()
returns boolean as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'admin'
  );
$$ language sql stable security definer;

-- profiles: everyone authed can read, only self can update, only admins can change roles
create policy profiles_select on profiles
  for select to authenticated
  using (true);

create policy profiles_update_self on profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and (role = (select role from profiles where id = auth.uid()) or is_admin()));

create policy profiles_admin_update on profiles
  for update to authenticated
  using (is_admin())
  with check (is_admin());

-- accounts: read all, insert any authed, update by owner or admin, no hard delete
create policy accounts_select on accounts
  for select to authenticated
  using (true);

create policy accounts_insert on accounts
  for insert to authenticated
  with check (auth.uid() is not null);

create policy accounts_update on accounts
  for update to authenticated
  using (owner_id = auth.uid() or is_admin())
  with check (owner_id = auth.uid() or is_admin());

-- contacts: read all, write if you own the parent account or are admin
create policy contacts_select on contacts
  for select to authenticated
  using (true);

create policy contacts_insert on contacts
  for insert to authenticated
  with check (
    exists (select 1 from accounts where id = account_id and (owner_id = auth.uid() or is_admin()))
  );

create policy contacts_update on contacts
  for update to authenticated
  using (
    exists (select 1 from accounts where id = account_id and (owner_id = auth.uid() or is_admin()))
  );

create policy contacts_delete on contacts
  for delete to authenticated
  using (
    exists (select 1 from accounts where id = account_id and (owner_id = auth.uid() or is_admin()))
  );

-- activities: read all, anyone authed can insert, only creator (within 24h) or admin can update/delete
create policy activities_select on activities
  for select to authenticated
  using (true);

create policy activities_insert on activities
  for insert to authenticated
  with check (user_id = auth.uid());

create policy activities_update on activities
  for update to authenticated
  using (
    (user_id = auth.uid() and created_at > now() - interval '24 hours')
    or is_admin()
  );

create policy activities_delete on activities
  for delete to authenticated
  using (
    (user_id = auth.uid() and created_at > now() - interval '24 hours')
    or is_admin()
  );

-- prospect_imports: users see their own, admins see all
create policy imports_select on prospect_imports
  for select to authenticated
  using (user_id = auth.uid() or is_admin());

create policy imports_insert on prospect_imports
  for insert to authenticated
  with check (user_id = auth.uid());

-- saved_views: each user only sees and edits their own
create policy saved_views_all on saved_views
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- =========================================================================
-- POST-MIGRATION STEPS
-- =========================================================================
-- 1. Add team members in Supabase dashboard:
--    Authentication > Users > Add user
--
-- 2. Promote yourself to admin:
--    update profiles set role = 'admin'
--    where id = (select id from auth.users where email = 'YOUR_EMAIL');
--
-- 3. Grab project URL and anon key from Settings > API and paste them into
--    index.html before deploying to Vercel.
-- =========================================================================
