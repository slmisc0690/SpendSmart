-- Server-authoritative rate limit for manual Dashboard "Refresh" taps on a single connected
-- account: maximum 2 manual balance refreshes per (user, plaid_accounts.id) per UTC calendar
-- day. Enforced entirely here — never trusted to the client — so it cannot be bypassed by
-- reinstalling the app, clearing UserDefaults, or calling the Edge Function directly.
--
-- SCOPE: this migration creates the tracking table and the one atomic claim function the new
-- `refresh-connected-account` Edge Function calls. It does not touch `plaid_items`,
-- `plaid_accounts`, or any existing Plaid Edge Function/table.
--
-- CALENDAR-DAY BOUNDARY: UTC, not the device's local calendar day. No user-timezone storage
-- exists anywhere in this schema, and inventing one is explicitly out of scope for this phase —
-- UTC is the only deterministic, server-authoritative boundary available without doing so. A
-- user near a UTC day boundary will see their allowance reset at a UTC-based time rather than
-- local midnight; this is a known, disclosed trade-off, not an oversight.
--
-- ATOMICITY: the increment-and-check is a single `INSERT ... ON CONFLICT ... DO UPDATE ...
-- WHERE ... RETURNING` statement. Postgres takes a row-level lock on the conflicting row as part
-- of this one statement, so two simultaneous requests at count=1 cannot both succeed — one wins
-- the `WHERE refresh_count < 2` guard and returns a row; the other sees the now-updated count and
-- the guard evaluates false, returning no row. This is the same class of atomic-write guarantee
-- already relied on elsewhere in this project's schema (see `household_invitations_pending_unique`
-- and `resend_invitation`'s `SELECT ... FOR UPDATE` in migration 0008) — no separate
-- SELECT-then-decide step exists anywhere in this design, so there is no race window to close.
--
-- FAILED-REFRESH CONSUMPTION: claiming happens before the Plaid call (see above), but a claim that
-- gated a Plaid call which then genuinely failed (network error before Plaid was reached, the Edge
-- Function erroring before the call, or Plaid's own API call itself returning an error) is given
-- back via `release_connected_account_refresh` below — a user must not lose one of today's 2
-- refreshes for an attempt that never actually delivered fresh data. A claim is NOT released when
-- Plaid responds successfully but the specific requested account simply isn't in that response —
-- that case genuinely consumed a real, successfully-billed Plaid round-trip. See
-- `release_connected_account_refresh`'s own doc comment for the concurrency argument for why this
-- can never let more than 2 successful/billable refreshes happen in one UTC day.
--
-- PRE-DEPLOYMENT REQUIREMENT: this migration is authored and reviewed here but NOT deployed by
-- this change. Genuine concurrent-request race verification (two simultaneous claims against the
-- same row) requires a live Postgres instance — this repo has no Docker/psql available locally
-- (the same limitation already documented for migration 0008's own verification), so that test
-- can only be run after deploying this migration to an isolated preview branch, exactly like
-- migration 0008's precedent. Do not deploy this migration without explicit separate
-- authorization.

-- ============================================================================================
-- 1. connected_account_refresh_log
-- ============================================================================================

create table if not exists public.connected_account_refresh_log (
  user_id uuid not null references auth.users (id) on delete cascade,
  plaid_account_id uuid not null references public.plaid_accounts (id) on delete cascade,
  refresh_date date not null,
  refresh_count int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, plaid_account_id, refresh_date)
);

comment on table public.connected_account_refresh_log is
  'One row per (user, connected account, UTC calendar day) tracking how many manual Dashboard
   "Refresh" taps have been claimed today. Rows are never deleted by application code (harmless,
   tiny, and useful as an audit trail) — only `refresh_count` is ever incremented, via
   claim_connected_account_refresh() below. A missing row for a given day means zero refreshes
   claimed yet, not an error.';

alter table public.connected_account_refresh_log enable row level security;
-- No policy for anon/authenticated — default-deny, identical posture to plaid_items/
-- plaid_accounts. Only the privileged (service_role) Edge Function client ever touches this
-- table, and only ever through the SECURITY DEFINER function below (see its own EXECUTE
-- lockdown) — never via a direct table-level INSERT/UPDATE from the Edge Function's client.

-- ============================================================================================
-- 2. claim_connected_account_refresh — the one atomic increment-and-check
-- ============================================================================================

-- Attempts to claim one of today's (UTC) 2 manual-refresh slots for (p_user_id,
-- p_plaid_account_id). Returns the NEW claimed count (1 or 2) on success, or NULL if today's
-- allowance is already exhausted — the caller (the Edge Function) must treat NULL as "do not
-- call Plaid" and return a 429 to the client. `p_user_id` must ALWAYS be the Edge Function's own
-- server-verified caller identity (from requireAuthenticatedUserId) — never a client-supplied
-- value trusted as-is; `p_plaid_account_id` must ALWAYS already be verified (by the caller) as
-- belonging to that same user's own plaid_items, via a plaid_accounts -> plaid_items join — this
-- function performs no ownership check of its own, it only tracks/enforces the daily count for
-- whatever pair it's given.
--
-- SECURITY DEFINER is required (not merely convenient): this runs as part of the privileged
-- Edge Function's service_role-authenticated request, and service_role itself is deliberately
-- given NO direct table privileges on this table (see EXECUTE lockdown below and the table's own
-- RLS posture) — the only path to writing a row is through this function, owned by the
-- migration-deploying role. `SET search_path = ''` with full schema-qualification is this
-- project's established anti-hijacking convention for every SECURITY DEFINER function (see
-- migration 0008).
create or replace function public.claim_connected_account_refresh(
  p_user_id uuid,
  p_plaid_account_id uuid
)
returns int
language sql
security definer
set search_path = ''
as $$
  insert into public.connected_account_refresh_log (user_id, plaid_account_id, refresh_date, refresh_count)
  values (p_user_id, p_plaid_account_id, (now() at time zone 'utc')::date, 1)
  on conflict (user_id, plaid_account_id, refresh_date)
  do update set
    refresh_count = public.connected_account_refresh_log.refresh_count + 1,
    updated_at = now()
  where public.connected_account_refresh_log.refresh_count < 2
  returning refresh_count;
$$;

-- ============================================================================================
-- 3. release_connected_account_refresh — undoes one claim when the Plaid call it gated never
--    actually delivered fresh data
-- ============================================================================================
--
-- A user must not lose one of today's 2 refreshes merely because the network failed before Plaid
-- was reached, the Edge Function errored before the Plaid call, or Plaid's own API call itself
-- returned an error — none of those are the billable operation this limit exists to cap. The
-- billable operation is the actual `/accounts/get` HTTP call inside `refreshPlaidAccounts`
-- (`_shared/plaid.ts`); `refresh-connected-account/index.ts` calls this function in its catch
-- block around exactly that call, and ONLY that call — never for the (rarer, and genuinely
-- Plaid-answered) case where Plaid responds successfully but the specific requested account_id
-- isn't in the response, which still consumed a real, successfully-billed Plaid round-trip.
--
-- Concurrency note: this is a plain relative decrement (`greatest(refresh_count - 1, 0)`), never
-- an absolute-value overwrite, and Postgres's row-level lock on the single UPDATE statement
-- serializes it against any concurrent claim/release on the exact same row — so interleaving with
-- another request's own claim always nets out to the true count of currently-consumed,
-- never-released attempts, regardless of ordering. `greatest(..., 0)` is defense-in-depth against
-- a caller-side bug ever double-releasing the same claim; the Edge Function's own control flow
-- already guarantees at most one release per successful claim (called only from the catch branch
-- immediately wrapping that one Plaid call). Never lets more than 2 successful/billable refreshes
-- happen per day — it only ever gives back a slot for an attempt that never actually completed.
create or replace function public.release_connected_account_refresh(
  p_user_id uuid,
  p_plaid_account_id uuid
)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.connected_account_refresh_log
  set refresh_count = greatest(refresh_count - 1, 0),
      updated_at = now()
  where user_id = p_user_id
    and plaid_account_id = p_plaid_account_id
    and refresh_date = (now() at time zone 'utc')::date;
$$;

-- ============================================================================================
-- 4. EXECUTE privilege lockdown — same convention as migration 0008 section 10
-- ============================================================================================
--
-- Postgres grants EXECUTE on a newly created function to PUBLIC by default unless explicitly
-- revoked; a Supabase project's anon/authenticated roles inherit that PUBLIC-level reachability
-- via PostgREST RPC unless revoked. Reset to zero, then grant back only to service_role — the
-- sole caller, via the new refresh-connected-account Edge Function's privileged client. Neither
-- anon nor authenticated should ever be able to call this directly (bypassing the Edge Function's
-- own ownership verification entirely).
revoke execute on function public.claim_connected_account_refresh(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.claim_connected_account_refresh(uuid, uuid) to service_role;

revoke execute on function public.release_connected_account_refresh(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.release_connected_account_refresh(uuid, uuid) to service_role;
