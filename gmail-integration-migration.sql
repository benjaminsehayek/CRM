-- =========================================================================
-- Crocs & Clicks CRM — Gmail integration migration
-- Run after abm-crm-schema.sql and calls-twilio-migration.sql.
-- =========================================================================

-- Add Gmail thread/message tracking to activities so we can re-fetch a
-- thread (and its replies) on demand without storing every message body
-- in the DB. Only meaningful for activities with type = 'email'.

alter table activities add column gmail_thread_id text;
alter table activities add column gmail_message_id text;
alter table activities add column email_to text;
alter table activities add column email_from text;
alter table activities add column email_subject text;

create index idx_activities_gmail_thread on activities(gmail_thread_id) where gmail_thread_id is not null;

-- The previous calls→activities mirror trigger created duplicate rows when the
-- new unified Activity view UNIONs calls + activities client-side. Drop it.
-- (Any rows it created previously can stay; they show up as call activities in
-- the existing per-account Activity tab and the new master list filters them
-- out by the call_id check.)
drop trigger if exists trg_calls_mirror_activity on calls;
drop function if exists calls_to_activity();
