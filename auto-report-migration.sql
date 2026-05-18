-- =========================================================================
-- Crocs & Clicks CRM — Auto-report migration
-- Adds columns the auto_email_report cadence step needs:
--   - report_keywords: per-account override for scan keywords (one per line)
--   - gbp_lat/lng/cid: cached business location from the first lookup
--     (avoids re-running the DataForSEO GBP lookup on every report)
-- =========================================================================

alter table accounts add column report_keywords text;
alter table accounts add column gbp_lat numeric;
alter table accounts add column gbp_lng numeric;
alter table accounts add column gbp_cid text;
alter table accounts add column gbp_place_id text;
