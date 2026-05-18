-- =========================================================================
-- Crocs & Clicks CRM — Tasks migration
-- The tasks table was added to abm-crm-schema.sql after some environments
-- had already applied the original schema, so this stand-alone migration
-- exists to backfill the table for older deployments. Safe to run on a
-- fresh DB too (will conflict with the table already created by
-- abm-crm-schema.sql in that case — skip if you applied a recent copy).
-- =========================================================================

create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  assignee_id uuid not null references profiles(id),
  created_by uuid not null references profiles(id),
  title text not null,
  notes text,
  due_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_tasks_account on tasks(account_id);
create index if not exists idx_tasks_assignee_due on tasks(assignee_id, due_at);
create index if not exists idx_tasks_open_due on tasks(due_at) where completed_at is null;

drop trigger if exists trg_tasks_updated on tasks;
create trigger trg_tasks_updated before update on tasks
  for each row execute function set_updated_at();

alter table tasks enable row level security;

drop policy if exists tasks_select on tasks;
create policy tasks_select on tasks
  for select to authenticated using (true);

drop policy if exists tasks_insert on tasks;
create policy tasks_insert on tasks
  for insert to authenticated with check (created_by = auth.uid());

drop policy if exists tasks_update on tasks;
create policy tasks_update on tasks
  for update to authenticated
  using (created_by = auth.uid() or assignee_id = auth.uid() or is_admin())
  with check (created_by = auth.uid() or assignee_id = auth.uid() or is_admin());

drop policy if exists tasks_delete on tasks;
create policy tasks_delete on tasks
  for delete to authenticated
  using (created_by = auth.uid() or is_admin());
