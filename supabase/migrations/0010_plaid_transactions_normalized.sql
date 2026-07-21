-- PHASE 4 — CONNECTED ACCOUNT CLOUD-SHARING FOUNDATION / NORMALIZED PLAID TRANSACTIONS.
--
-- Creates server-side normalized Plaid transaction storage, plus the trusted read path a future
-- Secondary will use to retrieve READ-ONLY transaction data for a Connected Account the Primary
-- has shared — reusing, never duplicating, the canonical `is_effectively_shared_for_user`
-- evaluator from migration 0008. This migration creates schema and functions ONLY — no Edge
-- Function in this repository calls any of these tables/functions yet (sync-transactions'
-- integration is authored alongside this migration but not deployed together; see that file's own
-- header), and no data currently depends on them.
--
-- SCOPE: plaid_transactions, its constraints/indexes/RLS/ownership-integrity trigger, and two new
-- SECURITY DEFINER functions (resolve_household_for_owner_and_recipient,
-- get_connected_account_transactions). Nothing here touches households/household_members/
-- household_invitations/sharing_permissions/user_profiles (migration 0008) or
-- connected_account_refresh_log (migration 0009) — all read-only referenced, never altered.
--
-- EXCLUDED FROM THIS PHASE (deliberately, per the locked implementation order): Manual Account
-- cloud sharing, Monthly Plan cloud sharing, Account Related Options UI, invitation acceptance UI,
-- Secondary shared-data UI, Share with Primary, Developer Tools.
--
-- PRE-DEPLOYMENT REQUIREMENT (do not deploy this migration until this is satisfied): the ownership
-- trigger (`enforce_plaid_transaction_owner_matches_account`) and the full owner/Secondary/
-- cross-household permission matrix for `get_connected_account_transactions` must be empirically
-- verified against an isolated Supabase staging/branch database before production deployment —
-- this migration file being authored does not constitute that test having been performed (same
-- documented limitation as migrations 0008/0009: no local Docker/psql available to this repo).

-- ============================================================================================
-- 1. plaid_transactions
-- ============================================================================================
--
-- COLUMN SELECTION — deliberately NOT a blind copy of every Plaid transaction field. Storing only
-- what SpendSmart's read-only shared Activity / account transaction history / pending-to-posted
-- replacement / deterministic sync actually needs (see this migration's own header):
--
--   - No `iso_currency_code`: the existing iOS `PlaidTransactionDTO` (FinanceTrack/Sync/
--     PlaidTransactionDTO.swift) does not carry a per-transaction currency code today — only
--     balances do — so there is nothing currently displayed that would consume it. Additive to add
--     later if/when multi-currency transaction display becomes an actual requirement.
--   - No `category_guess`: `BackendTransactionDTO.categoryGuess` is decoded on the iOS side today
--     but never actually applied anywhere (`PlaidTransactionImportService.mapToFinanceTransaction`'s
--     `category` parameter defaults to nil and no call site passes `categoryGuess` into it —
--     confirmed by inspection, not assumed). Not "currently needed" per this phase's own
--     instruction; additive to add later if a shared Activity UI ever wants a category label.
--   - No access_token/processor token/secret/raw Plaid payload of any kind — this table is a
--     normalized read model, never a credential store.
--
-- DATE TYPE — `date`, not `timestamptz`, for both `authorized_date`/`posted_date` and the derived
-- `transaction_date`. This is the server-side continuation of the exact bug already fixed on the
-- iOS side (see FinanceTrack/Sync/PlaidBackendService.swift's `parseBareDate` doc comment): Plaid
-- sends transaction dates as bare calendar strings ("2026-07-18"), never as instants. A `timestamptz`
-- column would force picking SOME time-of-day/time-zone anchor for a value that has neither —
-- exactly the class of bug (UTC-midnight anchoring silently rolling back a day in any zone behind
-- UTC) already diagnosed and fixed once on-device. Postgres's `date` type stores a calendar date
-- with no time-of-day/time-zone component at all, so it is structurally immune to that entire bug
-- class: `insert ... values ('2026-07-18', ...)` and `select ... where transaction_date = '2026-07-18'`
-- always mean exactly and only July 18, everywhere, forever — there is no reconstruction/parsing
-- step server-side (unlike the iOS `Date` type) that could reintroduce a timezone-anchoring choice.
--
-- OWNERSHIP CHAIN — transaction -> plaid_accounts.id -> plaid_items -> user_id. `owner_user_id` is
-- intentionally ALSO denormalized directly onto this table (see column comment below) because the
-- future shared-read path (`get_connected_account_transactions`) and any future owner-side
-- aggregation query need to filter/authorize by owner without a join through plaid_accounts ->
-- plaid_items on every single transaction row scanned — this table is expected to be, by a wide
-- margin, the largest table in this schema. Denormalization without a structural drift guarantee
-- would be a real security hazard (a stale/wrong owner_user_id could let the wrong user's rows
-- appear "owned" by someone else) — `enforce_plaid_transaction_owner_matches_account` below closes
-- that gap by re-deriving the true owner from plaid_account_id on every INSERT/UPDATE and rejecting
-- any mismatch, so owner_user_id can never independently drift from the real ownership chain.
create table if not exists public.plaid_transactions (
  id uuid primary key default gen_random_uuid(),
  plaid_account_id uuid not null references public.plaid_accounts (id) on delete cascade,
  -- Denormalized owner — see this migration's header comment for why, and
  -- enforce_plaid_transaction_owner_matches_account below for the drift guarantee. No ON DELETE
  -- action specified, matching plaid_items.user_id's own FK (migration 0001) — by the time
  -- delete-account's Admin API call removes the auth.users row, every plaid_transactions row for
  -- that user has already been cascade-deleted via plaid_items -> plaid_accounts -> here, so this
  -- FK never actually blocks anything; it exists purely as a structural guarantee, not a code path
  -- this project relies on firing.
  owner_user_id uuid not null references auth.users (id),
  -- Plaid's own transaction_id. NOT declared globally unique — Plaid Sandbox is known to reuse
  -- fixture data across separate test users/Items (this project already hit an analogous case with
  -- plaid_accounts.account_id, corrected in migration 0004_plaid_accounts_balance_fields.sql; the
  -- same defensive posture is applied here from the start rather than waiting to hit the bug).
  -- Scoped instead to (plaid_account_id, transaction_id) — see the composite unique constraint
  -- below — so even an identical transaction_id string from two different users' Sandbox fixtures
  -- can never collide, since their plaid_account_id values always differ.
  transaction_id text not null,
  -- Plaid's own pending_transaction_id — present only on the POSTED delivery that replaces a
  -- pending transaction, pointing back at the pending transaction's own transaction_id. Not used
  -- for a re-keying merge server-side the way the iOS local import does (see Phase 5 sync
  -- integration's own doc comment for why that's a deliberate, explained divergence) — stored
  -- anyway since it is Plaid's own authoritative linkage data, cheap to keep, and may be useful for
  -- a future feature without requiring another migration.
  pending_transaction_id text,
  original_description text not null,
  merchant_name text,
  amount numeric not null,
  authorized_date date,
  posted_date date,
  -- The single authoritative calendar date this row should be grouped/displayed under — ALWAYS
  -- derived, never independently caller-supplied, so it can never drift from authorized_date/
  -- posted_date the way a plain stored column could if a future code path forgot to keep it in
  -- sync. Mirrors the exact same `postedDate ?? authorizedDate` priority the iOS import layer
  -- already uses (PlaidTransactionImportService.mapToFinanceTransaction/applyUpdates) — Plaid's own
  -- `date` field mirrors `authorized_date` while a transaction is pending and becomes the true
  -- posted date once it posts, so "prefer posted, fall back to authorized" is correct for both
  -- pending and posted rows alike, not merely a posted-only rule.
  transaction_date date generated always as (coalesce(posted_date, authorized_date)) stored not null,
  is_pending boolean not null,
  created_at timestamptz not null default now(),
  -- Maintained by application code in the Edge Function on every upsert, NOT by a database
  -- trigger — this matches the EXISTING convention for every other Plaid table in this schema
  -- (plaid_items/plaid_accounts both set updated_at explicitly from application code; only the
  -- newer Phase-2 household/sharing tables from migration 0008 use a set_updated_at() DB trigger).
  -- Deliberately kept consistent with the Plaid-table family it belongs to rather than the
  -- household-table family, since it is populated by the same sync code path as plaid_accounts.
  updated_at timestamptz not null default now(),
  constraint plaid_transactions_account_transaction_unique unique (plaid_account_id, transaction_id)
);

comment on table public.plaid_transactions is
  'Server-side normalized mirror of Plaid-imported transactions, maintained by sync-transactions on
   every added/modified/removed delta. Read-only from every client''s perspective — no user-entered
   field (category, note, approval flags, matched-manual-expense linkage) exists on this table at
   all, unlike the iOS-local FinanceTransaction; those stay entirely local/per-device. Exists so a
   future Secondary can read a shared Connected Account''s transaction history without either device
   holding a Plaid access token, and so Primary/Secondary transaction access has one single
   server-side source of truth instead of trusting whatever a device''s own local sync happens to
   have applied.';

comment on column public.plaid_transactions.owner_user_id is
  'Denormalized from plaid_accounts -> plaid_items -> user_id for query performance — see this
   migration''s header comment. Structurally guaranteed to match the real ownership chain by
   enforce_plaid_transaction_owner_matches_account below; never independently writable in a way
   that could drift from it.';

create index if not exists plaid_transactions_plaid_account_id_idx
  on public.plaid_transactions (plaid_account_id);

create index if not exists plaid_transactions_owner_user_id_idx
  on public.plaid_transactions (owner_user_id);

-- Supports the shared-read path's own query shape (one account, most-recent-first) — see
-- get_connected_account_transactions below.
create index if not exists plaid_transactions_account_date_idx
  on public.plaid_transactions (plaid_account_id, transaction_date desc, created_at desc);

alter table public.plaid_transactions enable row level security;
-- Default-deny — no anon/authenticated policy, identical posture to plaid_items/plaid_accounts/
-- households/sharing_permissions (see migration 0008's own comments for the locked rationale).
-- This project's complex cross-user permission evaluation (household membership + global/per-item
-- sharing_permissions, via is_effectively_shared_for_user) has consistently been kept OUT of RLS
-- policy expressions and instead enforced by trusted Edge Functions calling SECURITY DEFINER
-- functions — the same architecture is continued here rather than introducing a narrower
-- authenticated-role RLS policy, per this phase's own instruction to prefer the already-locked
-- architecture absent a strong reason to change it. All access (owner-side future tooling and the
-- future Secondary shared-read path alike) goes through get_connected_account_transactions below,
-- itself only ever callable by the privileged service_role Edge Function client.

-- ============================================================================================
-- 2. enforce_plaid_transaction_owner_matches_account — ownership-drift guard
-- ============================================================================================
--
-- Re-derives the TRUE owner of NEW.plaid_account_id (via plaid_accounts -> plaid_items) on every
-- INSERT and on any UPDATE that touches plaid_account_id/owner_user_id, and rejects the write if
-- NEW.owner_user_id doesn't match. SECURITY INVOKER (the default) is correct here for the same
-- reason as every household_members integrity trigger in migration 0008: this only ever fires as
-- part of a write already being performed by the privileged/service_role client, which already has
-- full table privileges — no elevation is needed, and none is granted (see the EXECUTE
-- privilege-lockdown section below).
create or replace function public.enforce_plaid_transaction_owner_matches_account()
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
    raise exception 'plaid_transactions.plaid_account_id % does not resolve to a known plaid_accounts/plaid_items row.', NEW.plaid_account_id;
  end if;

  if NEW.owner_user_id is distinct from v_expected_owner then
    raise exception 'plaid_transactions.owner_user_id must match the resolved owner of plaid_account_id (expected %, got %).', v_expected_owner, NEW.owner_user_id;
  end if;

  return NEW;
end;
$$;

create trigger plaid_transactions_enforce_owner
  before insert or update of plaid_account_id, owner_user_id on public.plaid_transactions
  for each row execute function public.enforce_plaid_transaction_owner_matches_account();

-- ============================================================================================
-- 3. resolve_household_for_owner_and_recipient
-- ============================================================================================
--
-- Finds the household (if any) where p_owner_user_id is the ACTIVE Primary and p_recipient_user_id
-- is an ACTIVE member (any role) — i.e. the one household relationship in this phase's locked
-- sharing model (Primary owns and shares; "Share with Primary" is explicitly out of scope this
-- phase, so this deliberately never resolves the reverse direction). Returns NULL when no such
-- household exists (different households, recipient not a member anywhere, recipient's membership
-- inactive/removed, etc.) — callers must treat NULL as "cannot possibly be shared," never attempt a
-- permission check with a NULL household_id. A user can have at most one ACTIVE household
-- membership at a time (household_members_one_active_membership_per_user_idx, migration 0008), so
-- this can only ever match at most one household regardless of the `limit 1` below; the limit is
-- defensive clarity, not load-bearing correctness.
--
-- Never reads auth.uid() — both identities are explicit, caller-verified parameters, same
-- reasoning as is_effectively_shared_for_user (migration 0008): a service_role database session has
-- no end-user JWT attached to it.
create or replace function public.resolve_household_for_owner_and_recipient(
  p_owner_user_id uuid,
  p_recipient_user_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select hm.household_id
  from public.household_members hm
  join public.households h on h.id = hm.household_id
  where hm.user_id = p_recipient_user_id
    and hm.status = 'active'
    and h.primary_user_id = p_owner_user_id
  limit 1;
$$;

-- ============================================================================================
-- 4. get_connected_account_transactions — the trusted shared-read path
-- ============================================================================================
--
-- Returns up to p_limit transaction rows for ONE Connected Account (p_plaid_account_id, a
-- plaid_accounts.id — never plaid_items.id, per this project's locked sharing-key semantics for
-- the 'connectedAccounts' category), for a caller identity that MUST already be server-verified
-- (requireAuthenticatedUserId() in the calling Edge Function) — never a client-supplied
-- "recipient_user_id" trusted as-is. Two paths, checked in this order:
--
--   1. OWNER PATH: p_caller_user_id is the account's own owner -> always authorized, entirely
--      independent of sharing_permissions (an owner's access to their own data is never gated by
--      whether they've turned sharing on for themselves — matching is_effectively_shared_for_user's
--      own documented stance that owner access is never decided by that function).
--   2. SECONDARY PATH: p_caller_user_id is not the owner -> resolve the one household (if any)
--      connecting them (see resolve_household_for_owner_and_recipient above), then defer entirely
--      to the canonical is_effectively_shared_for_user evaluator for the actual permission
--      decision — this function contains NO duplicated permission logic of its own (per this
--      phase's explicit instruction: "Do not duplicate permission logic in TypeScript" — the same
--      discipline applies here, in SQL, to keep exactly one evaluator in the whole system).
--
-- ANTI-ENUMERATION: an unknown p_plaid_account_id, an account that exists but belongs to someone
-- entirely unconnected to the caller, and an account that exists and IS connected but isn't shared
-- all produce the exact same result — zero rows, no error, no distinguishing signal — so a caller
-- can never use this function's response shape to probe which account ids exist or who owns them.
--
-- Returns ONLY the columns a read-only shared Activity view needs — never plaid_account_id itself
-- (the internal join key), never owner_user_id, never anything from plaid_items/plaid_accounts
-- (never an access_token, never any credential, never Plaid's own item_id).
create or replace function public.get_connected_account_transactions(
  p_caller_user_id uuid,
  p_plaid_account_id uuid,
  p_limit int default 200
)
returns table (
  id uuid,
  transaction_id text,
  pending_transaction_id text,
  original_description text,
  merchant_name text,
  amount numeric,
  authorized_date date,
  posted_date date,
  transaction_date date,
  is_pending boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner_user_id uuid;
  v_household_id uuid;
  v_authorized boolean;
  v_limit int;
begin
  select pi.user_id
    into v_owner_user_id
    from public.plaid_accounts pa
    join public.plaid_items pi on pi.id = pa.plaid_item_id
    where pa.id = p_plaid_account_id;

  if v_owner_user_id is null then
    -- No such connected account — see this function's ANTI-ENUMERATION note above.
    return;
  end if;

  if p_caller_user_id = v_owner_user_id then
    v_authorized := true;
  else
    v_household_id := public.resolve_household_for_owner_and_recipient(v_owner_user_id, p_caller_user_id);
    v_authorized := v_household_id is not null
      and public.is_effectively_shared_for_user(
        v_household_id, v_owner_user_id, p_caller_user_id, 'connectedAccounts', p_plaid_account_id
      );
  end if;

  if not coalesce(v_authorized, false) then
    return;
  end if;

  -- Defensive clamp — never trust a caller-supplied limit unbounded (a very large p_limit could
  -- otherwise be used to pull an entire account's history in one call with no pagination pressure)
  -- and never allow a non-positive value to silently mean "unlimited" instead of "at least 1".
  v_limit := least(greatest(coalesce(p_limit, 200), 1), 500);

  return query
    select
      pt.id, pt.transaction_id, pt.pending_transaction_id, pt.original_description,
      pt.merchant_name, pt.amount, pt.authorized_date, pt.posted_date, pt.transaction_date,
      pt.is_pending, pt.created_at, pt.updated_at
    from public.plaid_transactions pt
    where pt.plaid_account_id = p_plaid_account_id
    order by pt.transaction_date desc, pt.created_at desc
    limit v_limit;
end;
$$;

-- ============================================================================================
-- 5. EXECUTE privilege lockdown — same convention as migrations 0008/0009
-- ============================================================================================

revoke execute on function public.enforce_plaid_transaction_owner_matches_account() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation (see migration 0008's own comment
-- block on why trigger functions never need a runtime EXECUTE grant).

revoke execute on function public.resolve_household_for_owner_and_recipient(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.resolve_household_for_owner_and_recipient(uuid, uuid) to service_role;

revoke execute on function public.get_connected_account_transactions(uuid, uuid, int) from public, anon, authenticated, service_role;
grant execute on function public.get_connected_account_transactions(uuid, uuid, int) to service_role;
-- Not granted to authenticated: p_caller_user_id is a plain parameter, not derived from auth.uid()
-- — granting this to authenticated would let any signed-in caller pass ANY user id as
-- p_caller_user_id and impersonate them for permission-evaluation purposes. Only the trusted
-- get-connected-account-transactions Edge Function (which derives this value itself from
-- requireAuthenticatedUserId(), via its own service_role client) may ever call this.
