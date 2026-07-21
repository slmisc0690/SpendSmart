-- PHASE 5 — MANUAL ACCOUNT / MANUAL TRANSACTION CLOUD SYNC FOUNDATION.
--
-- Creates server-side storage for owner-synced Manual Accounts/Transactions, plus the trusted
-- read path a future Secondary will use to retrieve a shared Manual Account read-only —
-- structurally the same pattern as migration 0010's Connected Account foundation, reusing (never
-- duplicating) the canonical `is_effectively_shared_for_user` evaluator from migration 0008. This
-- migration creates schema and functions ONLY — no Edge Function deploy happens with it (see the
-- accompanying `sync-manual-data`/`get-manual-account-data` source, authored but not deployed).
--
-- SCOPE: manual_accounts, manual_transactions, their constraints/indexes/RLS/ownership-integrity
-- trigger, and one new SECURITY DEFINER read function (get_manual_account_with_transactions).
-- Nothing here touches plaid_items/plaid_accounts/plaid_transactions (migrations 0001-0010) or
-- households/household_members/household_invitations/sharing_permissions/user_profiles
-- (migration 0008) — all read-only referenced (sharing_permissions already supports
-- category = 'manualAccounts' since migration 0008; no change needed there), never altered.
--
-- EXCLUDED FROM THIS PHASE (deliberately, per the locked implementation order): Monthly Plan cloud
-- sync, Account Related Options UI, invitation acceptance UI, Secondary shared-data UI, Share with
-- Primary, Developer Options.
--
-- PRE-DEPLOYMENT REQUIREMENT (do not deploy this migration until this is satisfied): the ownership
-- trigger (`enforce_manual_transaction_owner_matches_account`) and the full owner/Secondary/
-- cross-household permission matrix for `get_manual_account_with_transactions` must be empirically
-- verified against an isolated Supabase staging/branch database before production deployment —
-- same documented limitation and same required process as migration 0010 (no local Docker/psql
-- available to this repo).

-- ============================================================================================
-- 1. manual_accounts
-- ============================================================================================
--
-- COLUMN SELECTION — not a blind mirror of the local SwiftData `Account` model. Storing only what
-- a read-only shared-display / deterministic-sync / ownership-security foundation actually needs:
--
--   INCLUDED, with reasoning:
--     - `institution_name`, `last_four_digits`: both already documented on the local model as
--       safe-to-display ("Last 4 digits... shown in the UI... Never the full number") — a shared
--       read-only account view is materially less useful without SOME way to distinguish "Chase
--       Checking ...4821" from another checking account, so these are included as the minimal
--       identifying display context.
--     - `shows_in_recent_activity`: the migration task's own instruction calls this out by name
--       ("if relevant to shared presentation") — included so a future shared Activity view can
--       honor the same display filter the owner already sees locally.
--   EXCLUDED, with reasoning:
--     - `credit_limit`/`available_balance`/`payment_due_date`/`minimum_payment`: credit-card
--       statement detail that goes beyond what a read-only balance/identity display needs for this
--       FOUNDATION phase — additive to bring in later if a future shared credit-card UI wants
--       utilization/due-date display.
--     - `color_hex`/`is_archived`: pure local UI presentation, not synchronization- or
--       security-relevant data.
--     - `connection_type`: always `.manual` for every row that reaches this sync path (Plaid
--       accounts are never represented as a local `Account` row at all — see
--       PlaidTransactionDTO/PlaidConnectionManager; a `plaidAccountId` lives directly on
--       `FinanceTransaction`, not on `Account`) — storing a column that could only ever hold one
--       constant value adds nothing.
--     - `external_identifier`: reserved for a future Plaid-linked `Account` and always nil today —
--       nothing to store yet.
--     - `default_counts_toward_monthly_spending`: a local NEW-TRANSACTION-ENTRY default, not a
--       fact about the account itself; irrelevant to a read-only shared display.
--
-- `id` is CLIENT-SUPPLIED (matches the local SwiftData `Account.id` UUID exactly, never
-- server-generated) — this table is a synchronized mirror of a client-owned identity, the same
-- upsert-by-client-id pattern already established for `plaid_transactions.transaction_id` (Plaid's
-- own identity) — here the client (this project's own iOS app) is the authoritative id source
-- instead of a third party, but the pattern (never let the server mint a competing identity) is
-- identical.
create table if not exists public.manual_accounts (
  id uuid primary key,
  owner_user_id uuid not null references auth.users (id),
  name text not null,
  -- Mirrors the local `AccountType` enum's raw values exactly (checking/savings/creditCard/cash/
  -- other) — validated with a CHECK rather than a Postgres enum type, matching this schema's
  -- existing convention of plain `text ... check (... in (...))` for closed string sets (see
  -- `plaid_items.environment`, migration 0005, and `sharing_permissions.category`, migration 0008)
  -- rather than introducing `create type`, which would need its own migration to ever extend.
  account_type text not null check (account_type in ('checking', 'savings', 'creditCard', 'cash', 'other')),
  current_balance numeric not null,
  institution_name text,
  last_four_digits text,
  shows_in_recent_activity boolean not null default true,
  created_at timestamptz not null,
  updated_at timestamptz not null
);

comment on table public.manual_accounts is
  'Server-side synchronized mirror of a locally-owned Manual Account, maintained by
   sync-manual-data on every owner create/update/delete. Read-only from every OTHER client''s
   perspective (a future Secondary) — the owning device''s own local SwiftData store remains
   authoritative for that owner''s own UI in this phase (see this migration''s own header); this
   table exists purely for cloud durability and future shared read access, never as a second
   source of truth the owner''s own app reads back from.';

create index if not exists manual_accounts_owner_user_id_idx
  on public.manual_accounts (owner_user_id);

alter table public.manual_accounts enable row level security;
-- Default-deny — no anon/authenticated policy, identical posture to every other Plaid/sharing
-- table in this schema (plaid_items/plaid_accounts/plaid_transactions/households/
-- sharing_permissions). All access goes through trusted Edge Functions using the privileged
-- service_role client — sync-manual-data for owner writes, get-manual-account-data (via
-- get_manual_account_with_transactions below) for the future Secondary shared-read path.

-- OWNERSHIP IMMUTABILITY GUARD — defense in depth, discovered necessary during Phase 5B preview
-- verification: unlike manual_transactions (which cannot drift because
-- enforce_manual_transaction_owner_matches_account re-derives its owner from manual_accounts on
-- every write), manual_accounts.owner_user_id has no OTHER table to re-derive itself from — the
-- only backstop against a caller-controlled `id` colliding with an EXISTING row owned by someone
-- else (which a bare upsert would otherwise silently reassign to the new caller) is this trigger,
-- alongside sync-manual-data's own application-layer pre-upsert ownership check (see that file's
-- own header for the exact scenario this closes). Mirrors
-- prevent_household_primary_user_id_change's identical "cannot be changed once set" shape
-- (migration 0008) — ordinary updates to every OTHER column remain fully permitted; only a change
-- to owner_user_id itself is rejected. SECURITY INVOKER (the default) is correct here for the same
-- reason as every other integrity trigger in this schema: it only ever fires as part of a write
-- already being performed by the privileged/service_role client.
create or replace function public.prevent_manual_account_owner_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if NEW.owner_user_id is distinct from OLD.owner_user_id then
    raise exception 'manual_accounts.owner_user_id cannot be changed once set.';
  end if;
  return NEW;
end;
$$;

create trigger manual_accounts_protect_owner
  before update on public.manual_accounts
  for each row execute function public.prevent_manual_account_owner_change();

-- ============================================================================================
-- 2. manual_transactions
-- ============================================================================================
--
-- COLUMN SELECTION reasoning (per-field, since the migration task explicitly asks for this):
--
--   INCLUDED:
--     - `note` (not `description`, even though the task's own suggested field list said
--       "description" — named to match the local model's ACTUAL property 1:1, `FinanceTransaction.
--       note`, the same 1:1-naming convention already used for `plaid_transactions.
--       original_description` mirroring `PlaidTransactionDTO.originalDescription`): the
--       user-facing description of the transaction, exactly what a shared read-only view needs to
--       show what the entry was.
--     - `category_name`: a DENORMALIZED SNAPSHOT of `Category.name` at sync time, not a foreign
--       key — `Category` has no server-side table at all yet (categories remain entirely local/
--       per-device, unaffected by this phase), so there is nothing to reference. Storing the name
--       as plain text is the smallest safe way to let a future shared view show SOME category
--       label without inventing a whole category-sync subsystem, which is out of scope here.
--   EXCLUDED, with reasoning (the migration task explicitly asks whether these belong — they do
--   not):
--     - `counts_toward_weekly_budget` / `counts_toward_monthly_spending` / `is_excluded_from_reports`:
--       these are the OWNER''S OWN personal budgeting preferences (how this entry affects THEIR
--       weekly limit / monthly plan / Spend Sense) — not an intrinsic fact about the transaction,
--       and meaningless (or actively wrong) if blindly inherited by a Secondary''s own future budget
--       math, which would need its own independent preference if it ever exists. A read-only "what
--       did the owner spend" display has no need for them either.
--     - `external_transaction_id`/`pending_transaction_id`/`merchant_name`/`original_description`/
--       `plaid_account_id`/`authorized_date`/`posted_date`: all explicitly documented on the local
--       model as "Reserved for future Plaid/Amex sync (always nil/false in version 1)" — this sync
--       path only ever handles `source == .manual` rows, so these are always nil for anything
--       reaching here.
--     - `is_matched_to_manual_expense`/`matched_transaction_id`: local bookkeeping for an unbuilt
--       future transaction-matching feature (confirmed by the model''s own doc comment: "no live
--       code path sets this today") — nothing to synchronize yet.
--     - `transfer_destination_account`: a `.transfer`/`.creditCardPayment` row''s cross-account
--       counterpart. KNOWN, DELIBERATE LIMITATION of this foundation phase: a shared transaction
--       row shows only its own account''s side of a transfer/payment, never the destination
--       account''s identity — full two-account-aware shared semantics is real additional design
--       work (what happens when only ONE of the two accounts is shared?) left for a future phase
--       once Secondary UI itself is being built, not invented speculatively now.
--
-- `manual_account_id` is a FOREIGN KEY (`on delete cascade`) — deleting a `manual_accounts` row
-- (via `sync-manual-data`''s account-delete path) automatically removes every one of its
-- `manual_transactions` rows server-side, mirroring exactly how `plaid_transactions` cascades from
-- `plaid_accounts` in migration 0010 — no separate per-transaction tombstone is needed for
-- transactions that were only removed because their OWNING ACCOUNT was deleted (the local
-- SwiftData side already gets this for free too, via `Account`''s own
-- `@Relationship(deleteRule: .cascade, ...)`). A transaction deleted INDIVIDUALLY (its account
-- still exists) is handled by its own explicit delete call in sync-manual-data instead.
create table if not exists public.manual_transactions (
  id uuid primary key,
  manual_account_id uuid not null references public.manual_accounts (id) on delete cascade,
  -- Denormalized owner — see the OWNERSHIP MODEL section below for the drift guarantee. No ON
  -- DELETE action specified, matching plaid_transactions.owner_user_id's own FK (migration 0010)
  -- for the identical reason: by the time delete-account's Admin API call removes the auth.users
  -- row, every manual_transactions row for that user has already been cascade-deleted via
  -- manual_accounts -> here (once a future delete-account update also deletes that user's
  -- manual_accounts rows — out of scope for THIS migration, which only creates the table; see
  -- this migration's own EXCLUDED section), so this FK is a structural guarantee, not a relied-on
  -- runtime path today.
  owner_user_id uuid not null references auth.users (id),
  amount numeric not null,
  -- Mirrors the local `TransactionType` enum's raw values exactly.
  transaction_type text not null check (
    transaction_type in ('expense', 'income', 'transfer', 'creditCardPayment', 'refund', 'balanceAdjustment')
  ),
  -- `date`, not `timestamptz` — see DATE SEMANTICS section below.
  transaction_date date not null,
  note text not null,
  category_name text,
  is_pending boolean not null,
  created_at timestamptz not null,
  updated_at timestamptz not null
);

comment on table public.manual_transactions is
  'Server-side synchronized mirror of a locally-owned Manual Transaction — see
   public.manual_accounts'' own comment for the same "cloud durability / future shared read, never
   a second source of truth for the owner''s own app" posture.';

comment on column public.manual_transactions.category_name is
  'A denormalized snapshot of the local Category.name at sync time — NOT a foreign key. Categories
   have no server-side table of their own; this exists only so a future shared view can show some
   category label without inventing a category-sync subsystem this phase does not need.';

-- DATE SEMANTICS — `transaction_date` is PostgreSQL `date`, matching the exact reasoning already
-- locked for migration 0010''s Plaid date columns: a Manual Transaction''s date is a user-SELECTED
-- CALENDAR DAY (picked via a date picker), not an instant with a meaningful time-of-day/time-zone
-- component. The local SwiftData `FinanceTransaction.date` IS a genuine `Date` (an instant) on the
-- Swift side — unlike Plaid''s already-bare "YYYY-MM-DD" strings, the sync client (see
-- sync-manual-data''s own header / the iOS-side mapping) must resolve that `Date` to its LOCAL
-- CALENDAR DAY components (the same calendar day already shown to the user in the app''s own UI)
-- BEFORE sending it as a plain date string — never send an ISO8601 instant/timestamptz and let
-- Postgres or a later reader re-derive a calendar day from it, which is exactly the
-- UTC-midnight-shift bug class already fixed once for Plaid dates. Once the plain "YYYY-MM-DD"
-- string reaches this column, it is stored and read back as that exact calendar day forever, with
-- no timezone-anchoring step possible.
comment on column public.manual_transactions.transaction_date is
  'The user-selected calendar day, as a plain date — never a timestamptz. Resolved from the local
   Date''s LOCAL calendar components on the client before sync, matching the same no-UTC-shift
   discipline already locked for Plaid dates (migration 0010).';

create index if not exists manual_transactions_manual_account_id_idx
  on public.manual_transactions (manual_account_id);

create index if not exists manual_transactions_owner_user_id_idx
  on public.manual_transactions (owner_user_id);

create index if not exists manual_transactions_account_date_idx
  on public.manual_transactions (manual_account_id, transaction_date desc, created_at desc);

alter table public.manual_transactions enable row level security;
-- Default-deny — no anon/authenticated policy. Same rationale as manual_accounts and every prior
-- table in this schema's locked architecture.

-- ============================================================================================
-- 3. OWNERSHIP MODEL — enforce_manual_transaction_owner_matches_account
-- ============================================================================================
--
-- Re-derives the TRUE owner of NEW.manual_account_id (a single-hop lookup into manual_accounts —
-- simpler than plaid_transactions' two-hop plaid_accounts -> plaid_items chain, since
-- manual_accounts stores owner_user_id directly, not via a separate "item" table) on every INSERT
-- and on any UPDATE that touches manual_account_id/owner_user_id, and rejects the write if
-- NEW.owner_user_id doesn't match. SECURITY INVOKER (the default) is correct here for the same
-- reason as migration 0010's identical trigger: this only ever fires as part of a write already
-- being performed by the privileged/service_role client, which already has full table privileges.
create or replace function public.enforce_manual_transaction_owner_matches_account()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_expected_owner uuid;
begin
  select ma.owner_user_id
    into v_expected_owner
    from public.manual_accounts ma
    where ma.id = NEW.manual_account_id;

  if v_expected_owner is null then
    raise exception 'manual_transactions.manual_account_id % does not resolve to a known manual_accounts row.', NEW.manual_account_id;
  end if;

  if NEW.owner_user_id is distinct from v_expected_owner then
    raise exception 'manual_transactions.owner_user_id must match the resolved owner of manual_account_id (expected %, got %).', v_expected_owner, NEW.owner_user_id;
  end if;

  return NEW;
end;
$$;

create trigger manual_transactions_enforce_owner
  before insert or update of manual_account_id, owner_user_id on public.manual_transactions
  for each row execute function public.enforce_manual_transaction_owner_matches_account();

-- ============================================================================================
-- 4. get_manual_account_with_transactions — the trusted shared-read path
-- ============================================================================================
--
-- Returns ONE Manual Account's own display fields plus up to p_limit of its transactions (as a
-- jsonb array), for a caller identity that MUST already be server-verified
-- (requireAuthenticatedUserId() in the calling Edge Function) — never a client-supplied
-- "recipient_user_id" trusted as-is. Combines account + transactions in ONE function (rather than
-- two separate RPCs mirroring migration 0010's plaid_accounts/plaid_transactions split) so the
-- owner/Secondary authorization check is performed exactly ONCE per call, never duplicated across
-- two functions that could otherwise drift out of sync with each other.
--
-- Same two-path authorization as get_connected_account_transactions (migration 0010):
--   1. OWNER PATH: p_caller_user_id is the account's own owner -> always authorized, independent
--      of sharing_permissions.
--   2. SECONDARY PATH: resolve the one household (if any) connecting caller and owner (reusing
--      resolve_household_for_owner_and_recipient from migration 0010 — a category-agnostic helper,
--      not Connected-Account-specific despite where it was first introduced), then defer entirely
--      to is_effectively_shared_for_user with category = 'manualAccounts' and
--      item_id = manual_accounts.id (per this project's locked sharing-key semantics, migration
--      0008's own comment: "for manualAccounts it is the existing local SwiftData Account.id
--      UUID"). No duplicated permission logic — same discipline as migration 0010.
--
-- ANTI-ENUMERATION: an unknown p_manual_account_id, one belonging to someone entirely unconnected
-- to the caller, and one that exists and IS connected but isn't shared all produce the exact same
-- result — a single null row, no error, no distinguishing signal.
--
-- Returns ONLY the columns a read-only shared display needs — never owner_user_id itself.
create or replace function public.get_manual_account_with_transactions(
  p_caller_user_id uuid,
  p_manual_account_id uuid,
  p_limit int default 200
)
returns table (
  id uuid,
  name text,
  account_type text,
  current_balance numeric,
  institution_name text,
  last_four_digits text,
  shows_in_recent_activity boolean,
  updated_at timestamptz,
  transactions jsonb
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
  select ma.owner_user_id
    into v_owner_user_id
    from public.manual_accounts ma
    where ma.id = p_manual_account_id;

  if v_owner_user_id is null then
    -- No such manual account — see this function's ANTI-ENUMERATION note above.
    return;
  end if;

  if p_caller_user_id = v_owner_user_id then
    v_authorized := true;
  else
    v_household_id := public.resolve_household_for_owner_and_recipient(v_owner_user_id, p_caller_user_id);
    v_authorized := v_household_id is not null
      and public.is_effectively_shared_for_user(
        v_household_id, v_owner_user_id, p_caller_user_id, 'manualAccounts', p_manual_account_id
      );
  end if;

  if not coalesce(v_authorized, false) then
    return;
  end if;

  v_limit := least(greatest(coalesce(p_limit, 200), 1), 500);

  return query
    select
      ma.id, ma.name, ma.account_type, ma.current_balance, ma.institution_name,
      ma.last_four_digits, ma.shows_in_recent_activity, ma.updated_at,
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', mt.id,
              'amount', mt.amount,
              'transaction_type', mt.transaction_type,
              'transaction_date', mt.transaction_date,
              'note', mt.note,
              'category_name', mt.category_name,
              'is_pending', mt.is_pending,
              'updated_at', mt.updated_at
            )
            order by mt.transaction_date desc, mt.created_at desc
          )
          from (
            select *
            from public.manual_transactions
            where manual_transactions.manual_account_id = ma.id
            order by transaction_date desc, created_at desc
            limit v_limit
          ) mt
        ),
        '[]'::jsonb
      ) as transactions
    from public.manual_accounts ma
    where ma.id = p_manual_account_id;
end;
$$;

-- ============================================================================================
-- 5. EXECUTE privilege lockdown — same convention as migrations 0008/0009/0010
-- ============================================================================================

revoke execute on function public.enforce_manual_transaction_owner_matches_account() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.

revoke execute on function public.prevent_manual_account_owner_change() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.

revoke execute on function public.get_manual_account_with_transactions(uuid, uuid, int) from public, anon, authenticated, service_role;
grant execute on function public.get_manual_account_with_transactions(uuid, uuid, int) to service_role;
-- Not granted to authenticated — identical reasoning to get_connected_account_transactions
-- (migration 0010): p_caller_user_id is a plain parameter, not derived from auth.uid(), so only
-- the trusted get-manual-account-data Edge Function (which derives it from
-- requireAuthenticatedUserId()) may ever call this.
