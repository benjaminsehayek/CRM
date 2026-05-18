-- =========================================================================
-- Crocs & Clicks CRM — Cadence (sequence) migration
-- Reusable, multi-step outreach sequences. Each step generates a row in
-- the existing tasks table when it becomes current; completing the task
-- advances the enrollment to the next step.
-- Seeds one cadence: Default Outbound (Call → 1d → Auto report → 2d →
-- Call → Personal email).
-- =========================================================================

create type cadence_step_type as enum (
  'call',
  'auto_email_report',
  'personal_email',
  'manual_task'
);

create type cadence_status as enum (
  'active',
  'paused',
  'completed',
  'opted_out'
);

create table cadences (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  created_at timestamptz not null default now(),
  created_by uuid references profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create trigger trg_cadences_updated before update on cadences
  for each row execute function set_updated_at();

create table cadence_steps (
  id uuid primary key default gen_random_uuid(),
  cadence_id uuid not null references cadences(id) on delete cascade,
  step_order int not null,
  step_type cadence_step_type not null,
  wait_days_before int not null default 0,
  label text,
  created_at timestamptz not null default now(),
  unique (cadence_id, step_order)
);

create index idx_cadence_steps_order on cadence_steps(cadence_id, step_order);

create table cadence_enrollments (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  cadence_id uuid not null references cadences(id) on delete cascade,
  enrolled_at timestamptz not null default now(),
  enrolled_by uuid references profiles(id) on delete set null,
  status cadence_status not null default 'active',
  current_step_order int not null default 1,
  current_task_id uuid references tasks(id) on delete set null,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (account_id, cadence_id)
);

create index idx_cadence_enrollments_account on cadence_enrollments(account_id);
create index idx_cadence_enrollments_status on cadence_enrollments(status);
create index idx_cadence_enrollments_current_task on cadence_enrollments(current_task_id) where current_task_id is not null;

create trigger trg_cadence_enrollments_updated before update on cadence_enrollments
  for each row execute function set_updated_at();

-- Audit log of completed/skipped steps
create table cadence_step_executions (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references cadence_enrollments(id) on delete cascade,
  step_order int not null,
  step_type cadence_step_type not null,
  executed_at timestamptz not null default now(),
  executed_by uuid references profiles(id) on delete set null,
  task_id uuid references tasks(id) on delete set null,
  skipped boolean not null default false
);

create index idx_cadence_executions_enrollment on cadence_step_executions(enrollment_id, executed_at desc);

-- ── Seed: Default Outbound cadence ─────────────────────────────────────
insert into cadences (id, name, description) values
  ('11111111-1111-1111-1111-111111111111',
   'Default Outbound',
   'Cold outreach: Call → 1 day → Auto SEO report → 2 days → Follow-up call → Personal email');

insert into cadence_steps (cadence_id, step_order, step_type, wait_days_before, label) values
  ('11111111-1111-1111-1111-111111111111', 1, 'call',              0, 'Cold call'),
  ('11111111-1111-1111-1111-111111111111', 2, 'auto_email_report', 1, 'Auto-send SEO report'),
  ('11111111-1111-1111-1111-111111111111', 3, 'call',              2, 'Follow-up call'),
  ('11111111-1111-1111-1111-111111111111', 4, 'personal_email',    0, 'Personal follow-up email');

-- ── RLS ────────────────────────────────────────────────────────────────
alter table cadences enable row level security;
alter table cadence_steps enable row level security;
alter table cadence_enrollments enable row level security;
alter table cadence_step_executions enable row level security;

create policy cadences_select         on cadences         for select to authenticated using (true);
create policy cadence_steps_select    on cadence_steps    for select to authenticated using (true);
create policy enrollments_select      on cadence_enrollments for select to authenticated using (true);
create policy executions_select       on cadence_step_executions for select to authenticated using (true);

create policy enrollments_insert on cadence_enrollments
  for insert to authenticated with check (auth.uid() is not null);
create policy enrollments_update on cadence_enrollments
  for update to authenticated using (true) with check (true);
create policy enrollments_delete on cadence_enrollments
  for delete to authenticated using (
    enrolled_by = auth.uid()
    or exists (select 1 from accounts where id = account_id and (owner_id = auth.uid() or is_admin()))
  );

create policy executions_insert on cadence_step_executions
  for insert to authenticated with check (auth.uid() is not null);
