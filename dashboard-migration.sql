-- =========================================================================
-- Crocs & Clicks CRM — Dashboard migration
-- Adds a stage-change audit log so the dashboard can accurately count
-- transitions ("meetings set", "discovery complete", "wins", "losses")
-- in any time window. Run after the previous migrations.
-- =========================================================================

create table stage_changes (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  from_stage deal_stage,
  to_stage   deal_stage not null,
  changed_by uuid references profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);

create index idx_stage_changes_to_stage_time on stage_changes(to_stage, changed_at desc);
create index idx_stage_changes_account on stage_changes(account_id, changed_at desc);

-- Log every stage transition. Runs as security definer so the trigger can
-- write even when the calling user has restricted RLS access elsewhere.
create or replace function log_stage_change()
returns trigger as $$
begin
  if old.deal_stage is distinct from new.deal_stage then
    insert into stage_changes (account_id, from_stage, to_stage, changed_by, changed_at)
    values (new.id, old.deal_stage, new.deal_stage, new.updated_by, now());
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_log_stage_change
  after update of deal_stage on accounts
  for each row execute function log_stage_change();

-- Backfill: assume each existing account "entered" its current stage at its
-- updated_at. Approximate, but lets the dashboard show meaningful numbers
-- immediately instead of starting from zero today.
insert into stage_changes (account_id, to_stage, changed_at)
select id, deal_stage, updated_at from accounts;

-- RLS: read-all (same pattern as activities), no anon writes (trigger fills).
alter table stage_changes enable row level security;
create policy stage_changes_select on stage_changes
  for select to authenticated using (true);
