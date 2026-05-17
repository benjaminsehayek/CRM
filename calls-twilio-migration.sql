-- =========================================================================
-- Crocs & Clicks CRM — Twilio Voice migration
-- Run this entire file in the Supabase SQL editor as one batch.
-- Prerequisite: abm-crm-schema.sql has already been applied.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. ENUMS
-- -------------------------------------------------------------------------

create type call_direction as enum ('outbound', 'inbound');

create type call_status as enum (
  'queued',
  'ringing',
  'in_progress',
  'completed',
  'no_answer',
  'busy',
  'failed',
  'voicemail',
  'canceled'
);

-- -------------------------------------------------------------------------
-- 2. TABLES
-- -------------------------------------------------------------------------

-- Per-account sticky caller-ID assignment. Null until first outbound call.
alter table accounts add column caller_id_number text;

-- Single-row round-robin counter for assigning the next caller-ID number.
create table caller_id_rotation (
  id int primary key default 1,
  next_index int not null default 0,
  check (id = 1)
);
insert into caller_id_rotation (id, next_index) values (1, 0);

-- Calls log: one row per outbound or inbound call.
create table calls (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references accounts(id) on delete set null,
  contact_id uuid references contacts(id) on delete set null,
  user_id uuid references profiles(id) on delete set null,  -- null for inbound

  direction call_direction not null,
  from_number text not null,
  to_number text not null,
  status call_status,
  duration_seconds int,

  twilio_call_sid text unique,
  voicemail_url text,
  voicemail_duration_seconds int,
  voicemail_transcription text,
  notes text,

  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- 3. INDEXES
-- -------------------------------------------------------------------------

create index idx_calls_account_time on calls(account_id, started_at desc);
create index idx_calls_contact on calls(contact_id);
create index idx_calls_user on calls(user_id);
create index idx_calls_direction on calls(direction);
create index idx_calls_started on calls(started_at desc);

-- -------------------------------------------------------------------------
-- 4. TRIGGERS
-- -------------------------------------------------------------------------

create trigger trg_calls_updated before update on calls
  for each row execute function set_updated_at();

-- Mirror an outbound call into activities so the existing Activity tab keeps
-- working without changes. Only insert when the call has a matched account.
create or replace function calls_to_activity()
returns trigger as $$
begin
  if new.status = 'completed' and new.account_id is not null and new.user_id is not null
     and (old is null or old.status is distinct from new.status) then
    insert into activities (account_id, contact_id, user_id, type, subject, body, occurred_at)
    values (
      new.account_id, new.contact_id, new.user_id, 'call',
      case when new.direction = 'outbound' then 'Outbound call' else 'Inbound call' end,
      case when new.duration_seconds is not null
           then 'Duration: ' || new.duration_seconds || 's'
           else null end,
      coalesce(new.ended_at, new.started_at)
    );
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_calls_mirror_activity
  after insert or update of status on calls
  for each row execute function calls_to_activity();

-- -------------------------------------------------------------------------
-- 5. ROUND-ROBIN RPC
-- -------------------------------------------------------------------------

-- Atomically returns the current index, then advances the counter (mod 3).
-- Use this from the edge function when assigning a caller-ID to a new account.
create or replace function next_caller_id_index() returns int as $$
declare v int;
begin
  update caller_id_rotation
    set next_index = (next_index + 1) % 3
    where id = 1
    returning ((next_index - 1 + 3) % 3) into v;
  return v;
end;
$$ language plpgsql security definer;

-- -------------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY
-- -------------------------------------------------------------------------

alter table calls enable row level security;

-- All authed users can read every call (matches accounts/activities pattern).
create policy calls_select on calls
  for select to authenticated using (true);

-- Reps may update notes on calls they placed; admins may update any call.
-- All other writes (inserts, status, duration, voicemail) go through the edge
-- function with the service role and bypass RLS.
create policy calls_update_own_notes on calls
  for update to authenticated
  using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid() or is_admin());

-- caller_id_rotation: no direct access; only the edge function (service role)
-- ever reads/writes it.
alter table caller_id_rotation enable row level security;
-- (No policies → only service role can touch it, which is what we want.)

-- =========================================================================
-- POST-MIGRATION STEPS
-- =========================================================================
-- 1. Deploy the supabase/functions/twilio-voice edge function.
-- 2. Set edge function secrets (see DEPLOYMENT.md).
-- 3. Wire the Twilio TwiML App + the 3 phone numbers to the function URLs.
-- =========================================================================
