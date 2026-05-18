-- =========================================================================
-- Crocs & Clicks CRM — Power dialer migration
-- Adds a rep-classified call outcome separate from Twilio's call status
-- so the dialer can drive next-contact dates and stage transitions.
-- =========================================================================

alter table calls add column outcome text
  check (outcome is null or outcome in (
    'no_answer', 'voicemail', 'interested', 'not_interested', 'bad_number', 'callback'
  ));

create index idx_calls_outcome on calls(outcome) where outcome is not null;
