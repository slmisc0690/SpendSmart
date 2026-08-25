-- PLAID WEBHOOK-DRIVEN BACKGROUND TRANSACTION SYNC — PHASE 1: DATABASE FOUNDATION.
--
-- Gives the future webhook-triggered Item-level /transactions/sync engine (Phase 3, a new Edge
-- Function authored alongside this migration but NOT part of it) everything it needs to safely
-- resolve item_id -> user -> access token -> accounts -> cursor, claim exclusive per-Item work
-- without a second concurrent webhook delivery racing it, and let the iPhone learn about
-- server-reconciled changes (including removals) without ever calling Plaid itself again for its
-- regular sync. This migration is schema + SECURITY DEFINER claim functions ONLY — no Edge
-- Function in this repository calls any of it yet, and no data currently depends on it.
--
-- DESIGN DECISION THIS MIGRATION IMPLEMENTS (confirmed with the project owner before writing this
-- file, since it changes an existing architectural assumption): Plaid's /transactions/sync cursor
-- is a single, stateful, per-Item stream — only one caller can ever "consume" a given diff. Today
-- the iPhone is that caller. Going forward, the webhook-triggered backend becomes the SOLE caller
-- of /transactions/sync for every Item; the iPhone's own sync-transactions call (Phase 3/4, not
-- part of this migration) will be repurposed to read the ALREADY-reconciled server-side mirror
-- (plaid_transactions, migration 0010) instead of calling Plaid directly. This migration adds:
--   1. A handful of new columns on the existing plaid_items row (reusing that table rather than
--      creating a duplicate parallel "item sync state" table, per this phase's own instruction to
--      prefer extending existing structures) for: claim/lock state, last-successful-sync
--      observability, last-error observability, and the iPhone's own "already delivered up to this
--      point in time" watermark.
--   2. plaid_transaction_removals — plaid_transactions (migration 0010) hard-deletes rows Plaid
--      reports as removed, with no history, so there is currently no way for a client that wasn't
--      present at delete-time to ever learn a transaction was removed. This is a small, append-only
--      (upserted) log the Item-sync engine writes to every time it deletes a plaid_transactions row,
--      so the iPhone's watermark-based pull can return both new/changed AND removed transaction ids
--      in one response, matching the shape sync-transactions already returns today.
--   3. claim_item_transaction_sync / release_item_transaction_sync — the atomic, single-statement
--      claim-with-staleness-recovery pattern already established by
--      migration 0009's claim_connected_account_refresh/release_connected_account_refresh, adapted
--      here to serialize per-Item background sync work instead of rate-limiting a per-account daily
--      count. No advisory locks are introduced (none exist anywhere in this schema today — see this
--      phase's own architecture audit) because the same atomic UPDATE ... WHERE ... RETURNING
--      guarantee this project already relies on elsewhere is sufficient and requires no new
--      Postgres capability.
--
-- EXPLICITLY NOT IN SCOPE FOR THIS MIGRATION (per the task's own strict scope boundary): the
-- webhook receiver's routing logic, the actual /transactions/sync pagination loop, any change to
-- sync-transactions/index.ts's behavior, and any iPhone-side change. Those are Phase 2/3/4 Edge
-- Function and Swift work, authored separately, never touching this file.
--
-- PRE-DEPLOYMENT REQUIREMENT (same documented limitation as migrations 0008/0009/0010 — no local
-- Docker/psql available to this repo): the claim/release concurrency guarantee below, the ownership
-- trigger on plaid_transaction_removals, and the RLS default-deny posture must be empirically
-- verified against an isolated Supabase preview branch before production deployment. This migration
-- file being authored and reasoned through here does not constitute that test having been
-- performed. DO NOT DEPLOY this migration without explicit separate authorization.

-- ============================================================================================
-- 1. plaid_items — minimal extension for Item-level sync claim/observability/watermark state
-- ============================================================================================

alter table public.plaid_items
  add column if not exists transaction_sync_claimed_at timestamptz,
  add column if not exists last_transaction_sync_completed_at timestamptz,
  add column if not exists last_transaction_sync_error text,
  add column if not exists last_transactions_ack_at timestamptz;

comment on column public.plaid_items.transaction_sync_claimed_at is
  'Non-null while the webhook-triggered Item-level /transactions/sync engine (Phase 3) is actively
   running for this Item — set by claim_item_transaction_sync, cleared by
   release_item_transaction_sync regardless of success/failure. A claim older than 10 minutes is
   treated as abandoned (crashed function, evicted isolate, etc.) and may be reclaimed by the next
   attempt — see claim_item_transaction_sync below. This is the ONLY concurrency guard for per-Item
   background sync; no advisory lock or external queue exists or is needed given the single atomic
   UPDATE ... WHERE ... RETURNING claim below.';

comment on column public.plaid_items.last_transaction_sync_completed_at is
  'Set only on a fully successful /transactions/sync pagination loop (every page fetched, all
   added/modified/removed persisted, cursor advanced) — never on a partial/failed attempt. Purely
   observability; safe to expose to the owning client (e.g. a future "last updated" Connected
   Accounts UI element) since it carries no secret and no transaction content.';

comment on column public.plaid_items.last_transaction_sync_error is
  'Non-sensitive summary of the most recent failed sync attempt, if any, cleared on the next
   success. Must NEVER be assigned a raw Plaid error body or raw exception message that could embed
   access_token or other request content — callers must pass only a short, pre-sanitized reason
   string (see this project''s existing logSafeError convention in _shared/plaid.ts, which already
   applies the same discipline to every other Plaid-adjacent error path).';

comment on column public.plaid_items.last_transactions_ack_at is
  'Watermark: the point in time up to which the OWNING iPhone client has already received every
   plaid_transactions change (added/modified) and plaid_transaction_removals entry for this Item, via
   its own sync-transactions call. Distinct from `cursor`, which is Plaid''s own opaque bookmark used
   only by the server-side Item-sync engine — this column instead tracks what has already been
   DELIVERED to the app that actually renders Activity/budgeting, so a repeat sync-transactions call
   never re-sends (or, worse, never sends at all) the same batch. Null means "nothing yet
   acknowledged" (deliver everything currently on record for this Item''s accounts) — matches the
   existing nullable-cursor convention (0001_plaid_items.sql) rather than inventing a sentinel date.';

-- ============================================================================================
-- 2. plaid_transaction_removals — append-only removal log, upserted (never duplicated) per
--    (account, transaction) pair
-- ============================================================================================

create table if not exists public.plaid_transaction_removals (
  id uuid primary key default gen_random_uuid(),
  plaid_account_id uuid not null references public.plaid_accounts (id) on delete cascade,
  -- Denormalized owner, identical rationale and identical drift-guarantee mechanism as
  -- plaid_transactions.owner_user_id (migration 0010) — see the trigger below.
  owner_user_id uuid not null references auth.users (id),
  -- Plaid's own transaction_id for the row that was removed from plaid_transactions. Not a foreign
  -- key into plaid_transactions itself — by the time this row is written, the corresponding
  -- plaid_transactions row has already been deleted (that deletion and this insert happen together,
  -- in the same Item-sync engine transaction, for the same reason plaid_transactions itself scopes
  -- uniqueness to (plaid_account_id, transaction_id) rather than a global transaction_id: Plaid
  -- Sandbox fixture data can repeat transaction_id strings across unrelated users/Items.
  transaction_id text not null,
  removed_at timestamptz not null default now(),
  constraint plaid_transaction_removals_account_transaction_unique unique (plaid_account_id, transaction_id)
);

comment on table public.plaid_transaction_removals is
  'Append-only (upserted, never duplicated per account+transaction) record of every transaction the
   Item-sync engine has deleted from plaid_transactions, so a client pulling by
   plaid_items.last_transactions_ack_at can learn about a removal even though plaid_transactions
   itself keeps no history of it. A transaction_id reported removed more than once (e.g. after a
   failed sync attempt is safely retried against the same never-advanced cursor, per this
   migration''s own header) only ever bumps removed_at on the existing row via
   ON CONFLICT ... DO UPDATE in the Item-sync engine — it never accumulates duplicate rows.';

comment on column public.plaid_transaction_removals.owner_user_id is
  'Denormalized from plaid_accounts -> plaid_items -> user_id, structurally guaranteed to match the
   real ownership chain by enforce_plaid_transaction_removal_owner_matches_account below — identical
   pattern and rationale to plaid_transactions.owner_user_id (migration 0010).';

create index if not exists plaid_transaction_removals_account_removed_idx
  on public.plaid_transaction_removals (plaid_account_id, removed_at desc);

create index if not exists plaid_transaction_removals_owner_removed_idx
  on public.plaid_transaction_removals (owner_user_id, removed_at desc);

alter table public.plaid_transaction_removals enable row level security;
-- Default-deny — identical posture to plaid_items/plaid_accounts/plaid_transactions (see those
-- tables' own migration comments for the locked rationale). No anon/authenticated policy; all
-- access goes through the privileged service_role Edge Function client.

-- ============================================================================================
-- 3. enforce_plaid_transaction_removal_owner_matches_account — same ownership-drift guard as
--    plaid_transactions' own trigger (migration 0010), applied here too
-- ============================================================================================

create or replace function public.enforce_plaid_transaction_removal_owner_matches_account()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_expected_owner uuid;
begin
  select pi.user_id
    into v_expected_owner
    from public.plaid_accounts pa
    join public.plaid_items pi on pi.id = pa.plaid_item_id
    where pa.id = NEW.plaid_account_id;

  if v_expected_owner is null then
    raise exception 'plaid_transaction_removals.plaid_account_id % does not resolve to a known plaid_accounts/plaid_items row.', NEW.plaid_account_id;
  end if;

  if NEW.owner_user_id is distinct from v_expected_owner then
    raise exception 'plaid_transaction_removals.owner_user_id must match the resolved owner of plaid_account_id (expected %, got %).', v_expected_owner, NEW.owner_user_id;
  end if;

  return NEW;
end;
$$;

create trigger plaid_transaction_removals_enforce_owner
  before insert or update of plaid_account_id, owner_user_id on public.plaid_transaction_removals
  for each row execute function public.enforce_plaid_transaction_removal_owner_matches_account();

-- ============================================================================================
-- 4. claim_item_transaction_sync — the one atomic per-Item claim, with stale-claim recovery
-- ============================================================================================
--
-- Attempts to claim p_item_id (a plaid_items.id, a UUID) for exclusive Item-level sync work.
-- Returns true if the claim was acquired (the row had no claim, or its claim is older than the
-- 10-minute staleness window below), false if another sync is genuinely in flight right now.
--
-- STALENESS WINDOW RATIONALE: this project introduces no background job scheduler (no pg_cron, no
-- external queue — see this migration's own header) in this phase, so a claim that is never
-- released (the Edge Function process crashes, the isolate is evicted mid-run, an unhandled
-- exception bypasses the release call) would otherwise permanently wedge that one Item's background
-- sync forever, with no other mechanism to ever unstick it. 10 minutes is comfortably longer than
-- this project's own Supabase paid-plan background-task ceiling (400 seconds, ~6m40s, confirmed via
-- Supabase's current documented Edge Function background-task limits) so a claim still held past 10
-- minutes can only mean the process that set it is already gone, never a slow-but-legitimate
-- still-running sync. Recovery is intentionally lazy — the NEXT trigger (a genuine subsequent
-- SYNC_UPDATES_AVAILABLE webhook, or the iPhone's own manual Refresh, per Phase 4) is what performs
-- the reclaim; no separate sweeper process is introduced.
--
-- CONCURRENCY: single atomic UPDATE ... WHERE ... RETURNING inside one CTE — Postgres's row-level
-- lock on the matched row means two simultaneous claim attempts against the same p_item_id can never
-- both succeed, identical guarantee class to claim_connected_account_refresh (migration 0009).
-- Different Items have different rows and are never serialized against each other by this function.
create or replace function public.claim_item_transaction_sync(
  p_item_id uuid
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  with claimed as (
    update public.plaid_items
    set transaction_sync_claimed_at = now()
    where id = p_item_id
      and (
        transaction_sync_claimed_at is null
        or transaction_sync_claimed_at < now() - interval '10 minutes'
      )
    returning id
  )
  select exists (select 1 from claimed);
$$;

-- ============================================================================================
-- 5. release_item_transaction_sync — always clears the claim; advances the cursor ONLY on success
-- ============================================================================================
--
-- Called exactly once per claimed attempt, in a finally-style path covering both success and
-- failure (the calling Edge Function's responsibility, mirroring release_connected_account_refresh's
-- own single-release-per-claim discipline). On success (p_success = true): commits p_new_cursor,
-- stamps last_transaction_sync_completed_at, clears any prior error. On failure (p_success = false):
-- the cursor is left COMPLETELY UNTOUCHED (never advanced past data that was never fully persisted —
-- required by this project's own Phase 3 failure-safety instruction) and last_transaction_sync_error
-- records the caller-supplied, already-sanitized reason. The claim itself
-- (transaction_sync_claimed_at) is always cleared either way, so a later retry is never blocked by
-- this attempt's own claim outlasting it.
create or replace function public.release_item_transaction_sync(
  p_item_id uuid,
  p_success boolean,
  p_new_cursor text,
  p_error text
)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.plaid_items
  set transaction_sync_claimed_at = null,
      cursor = case when p_success then p_new_cursor else cursor end,
      last_transaction_sync_completed_at = case when p_success then now() else last_transaction_sync_completed_at end,
      last_transaction_sync_error = case when p_success then null else p_error end,
      updated_at = now()
  where id = p_item_id;
$$;

-- ============================================================================================
-- 6. EXECUTE privilege lockdown — same convention as migrations 0008/0009/0010
-- ============================================================================================

revoke execute on function public.claim_item_transaction_sync(uuid) from public, anon, authenticated, service_role;
grant execute on function public.claim_item_transaction_sync(uuid) to service_role;

revoke execute on function public.release_item_transaction_sync(uuid, boolean, text, text) from public, anon, authenticated, service_role;
grant execute on function public.release_item_transaction_sync(uuid, boolean, text, text) to service_role;

-- enforce_plaid_transaction_removal_owner_matches_account is a BEFORE trigger function
-- (security invoker, fires automatically as part of a write already made by the privileged
-- service_role client) — no EXECUTE grant is needed or given, identical to
-- enforce_plaid_transaction_owner_matches_account's own trigger in migration 0010.
