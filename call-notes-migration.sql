-- =========================================================================
-- Crocs & Clicks CRM — Call-notes RPC migration
--
-- After every call the rep types a note in the dialer. We want that note
-- appended to the account's Notes tab as a running log of every call.
--
-- Doing the append client-side (read accounts.notes -> concat -> write back)
-- has two problems:
--   1) The accounts_update RLS policy restricts updates to the account owner
--      or admins, so a rep covering a teammate's account silently failed to
--      write the log entry — the dispatch was skipped because the UPDATE
--      returned 0 rows.
--   2) Two near-simultaneous calls (power dialer + manual dial, or two reps
--      on the same account) racing in read-modify-write would lose one of
--      the entries.
--
-- This migration replaces the client-side append with a SECURITY DEFINER
-- function that does the concatenation atomically inside a single UPDATE,
-- so the row is locked for the duration and concurrent appends serialize
-- cleanly. Any authenticated user may append a call-log entry; mutation of
-- the rest of the account row (owner/stage/etc.) still goes through the
-- regular RLS-restricted update path.
-- =========================================================================

create or replace function append_call_note(p_account_id uuid, p_entry text)
returns accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_account accounts;
begin
  if v_uid is null then
    raise exception 'append_call_note: not authenticated';
  end if;
  if p_account_id is null then
    raise exception 'append_call_note: account_id required';
  end if;
  if p_entry is null or btrim(p_entry) = '' then
    raise exception 'append_call_note: entry required';
  end if;

  update accounts
     set notes = case
                   when notes is null or btrim(notes) = '' then p_entry
                   else notes || E'\n\n' || p_entry
                 end,
         updated_by = v_uid,
         updated_at = now()
   where id = p_account_id
   returning * into v_account;

  if v_account.id is null then
    raise exception 'append_call_note: account % not found', p_account_id;
  end if;

  return v_account;
end;
$$;

revoke all on function append_call_note(uuid, text) from public;
grant execute on function append_call_note(uuid, text) to authenticated;
