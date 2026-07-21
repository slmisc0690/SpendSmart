-- PHASE 6 — MONTHLY PLAN CLOUD SYNCHRONIZATION FOUNDATION.
--
-- Creates server-side storage for owner-synced Monthly Plan data (settings, income sources,
-- recurring expenses), plus the trusted GLOBAL-ONLY read path a future Secondary will use to
-- retrieve a read-only representation of an owner's Monthly Plan — reusing (never duplicating)
-- the canonical `is_effectively_shared_for_user` evaluator from migration 0008. Structurally the
-- same family as migrations 0010/0011, with one deliberate difference: 'monthlyPlan' sharing is
-- GLOBAL ONLY (migration 0008's own CHECK constraint already enforces `item_id is null` for this
-- category) — there is no per-item override concept here at all, unlike connectedAccounts/
-- manualAccounts.
--
-- SCOPE: monthly_plan_settings, monthly_plan_income_sources, monthly_plan_recurring_expenses,
-- their constraints/indexes/RLS/ownership-integrity triggers, and one new SECURITY DEFINER read
-- function (get_monthly_plan_with_sources). Nothing here touches plaid_*/manual_*/households/
-- sharing_permissions (all read-only referenced — sharing_permissions already supports
-- category = 'monthlyPlan' since migration 0008; no schema change needed there), never altered.
--
-- EXCLUDED FROM THIS PHASE (deliberately, per the locked implementation order): Account Related
-- Options UI, invitation acceptance UI, Secondary shared-data UI, Share with Primary, Developer
-- Options. Also excluded, with reasoning: syncing `BudgetSettings.weeklySpendingLimit` at all —
-- Monthly Plan's own synchronized data (income, fixed expenses, savings goal, buffer) is
-- sufficient to recompute `recommendedWeeklySpendingLimit` via the exact same
-- `MonthlyPlanCalculator` formulas a future Secondary UI would reuse; the OWNER'S currently-set
-- manual weekly limit is a separate, not-yet-cloud-synced settings object with no table of its own
-- anywhere in this schema, and inventing one is out of scope for a Monthly Plan phase.
--
-- NO CALCULATED VALUES ARE PERSISTED OR REIMPLEMENTED HERE — per this phase's own instruction not
-- to duplicate or alter `MonthlyPlanCalculator`'s formulas. `get_monthly_plan_with_sources` below
-- returns ONLY the raw synchronized source rows (settings + income sources + recurring expenses),
-- in the same shape already used client-side. A future Secondary UI computes
-- estimatedMonthlyIncome/estimatedMonthlyFixedExpenses/flexibleSpendingAvailable/
-- recommendedWeeklySpendingLimit/etc. by feeding this exact data into the SAME
-- `MonthlyPlanCalculator.summary(...)` the owner's own app already uses — guaranteeing the
-- owner's and a Secondary's views of the same plan can never compute different numbers from
-- equivalent inputs, and never requires a second, TypeScript re-implementation of that math.
--
-- PRE-DEPLOYMENT REQUIREMENT (do not deploy this migration until this is satisfied): every
-- ownership-integrity trigger below and the full owner/Secondary/cross-household permission
-- matrix for `get_monthly_plan_with_sources` must be empirically verified against an isolated
-- Supabase staging/branch database before production deployment — same documented limitation and
-- same required process as migrations 0010/0011 (no local Docker/psql available to this repo).

-- ============================================================================================
-- 1. monthly_plan_settings — one row per owner (singleton, matching the local model's own
--    "singleton-style settings record" design)
-- ============================================================================================
--
-- PRIMARY KEY IS owner_user_id ITSELF, not a separate synchronized `id` — the local
-- `MonthlyPlanSettings.id` is a SwiftData-required artifact never referenced as a foreign key by
-- anything else locally (unlike `Account.id`/`FinanceTransaction.id`, which manual_accounts/
-- manual_transactions do reference) — there is nothing for a server copy to preserve identity
-- continuity with beyond the owner relationship itself, and the phase's own field-list instruction
-- for this table never lists an `id` column at all. This also structurally eliminates the
-- ownership-hijack class discovered in Phase 5B for `manual_accounts` (see that migration's own
-- `prevent_manual_account_owner_change` comment): every upsert here is keyed on the CALLER's own
-- verified `owner_user_id`, so there is no separate client-suppliable `id` a caller could reuse to
-- target a different owner's existing row in the first place.
--
-- COLUMN SELECTION:
--   INCLUDED: `monthly_savings_goal`, `buffer_amount`, `auto_update_weekly_budget_from_plan` — all
--   three are either consumed directly by `MonthlyPlanCalculator`'s formulas
--   (monthlySavingsGoal/bufferAmount, via `flexibleSpendingAvailable`) or explicitly named in this
--   phase's own field-list instruction as useful read-only context for a Secondary
--   (auto_update_weekly_budget_from_plan — whether the owner's own weekly limit auto-updates from
--   this plan).
--   EXCLUDED: `useRecommendedWeeklyBudget` — confirmed by its own local doc comment to be a pure
--   DISPLAY preference ("does not by itself change BudgetSettings") never read by
--   `MonthlyPlanCalculator` at all — not needed to reconstruct a read-only shared plan.
create table if not exists public.monthly_plan_settings (
  owner_user_id uuid primary key references auth.users (id),
  monthly_savings_goal numeric not null,
  buffer_amount numeric,
  auto_update_weekly_budget_from_plan boolean not null default false,
  created_at timestamptz not null,
  updated_at timestamptz not null
);

comment on table public.monthly_plan_settings is
  'Server-side synchronized mirror of the owner''s local (singleton) MonthlyPlanSettings row,
   maintained by sync-monthly-plan-data. Read-only from every OTHER client''s perspective (a future
   Secondary) — the owning device''s own local SwiftData store remains authoritative for that
   owner''s own UI in this phase, matching the exact posture already established for
   manual_accounts/manual_transactions (migration 0011).';

alter table public.monthly_plan_settings enable row level security;
-- Default-deny — no anon/authenticated policy, identical posture to every other Plaid/Manual/
-- sharing table in this schema. All access goes through trusted Edge Functions using the
-- privileged service_role client.

-- ============================================================================================
-- 2. monthly_plan_income_sources
-- ============================================================================================
--
-- COLUMN SELECTION reasoning (per-field):
--   INCLUDED: `name`, `note` — display/identity context, matching the exact precedent already set
--   for `manual_transactions.note` (migration 0011). `amount`/`frequency`/`is_active`/
--   `next_pay_date` — all four are the ONLY `IncomeSource` fields `MonthlyPlanCalculator.
--   estimatedMonthlyIncome` actually reads (verified directly against that function's current
--   source, not assumed): a `.oneTime` source only counts when `next_pay_date` falls in the target
--   month; every other frequency is converted via `monthlyAmount(for:frequency:)`, gated by
--   `is_active`.
--   EXCLUDED: `timing` (`PlanTiming`) and `dayOfMonth` — confirmed by direct inspection of
--   `MonthlyPlanCalculator.swift` that NEITHER is read by any current formula (`PlanTiming`'s own
--   doc comment claims `dayOfMonth` feeds "actual date math," but the calculator's actual source
--   only ever reads `frequency`/`nextPayDate`/`amount`/`isActive` — this migration follows the
--   verified current code, not that comment's claim, per this phase's own instruction not to
--   assume). Both are additive to bring in later if a future formula or shared UI actually
--   consumes them.
--
-- `next_pay_date` is `date`, not `timestamptz` — a `.oneTime` income source's date is a
-- user-selected calendar day compared against a calendar month (`month.contains(date)` in
-- `MonthlyPlanCalculator`), the exact same semantics already locked for
-- `manual_transactions.transaction_date` (migration 0011) and `plaid_transactions.
-- authorized_date`/`posted_date` (migration 0010) — the client resolves the local `Date`'s LOCAL
-- calendar components before sync, never sending an instant for the server (or a later reader) to
-- re-derive a calendar day from.
create table if not exists public.monthly_plan_income_sources (
  id uuid primary key,
  owner_user_id uuid not null references auth.users (id),
  name text not null,
  amount numeric not null,
  frequency text not null check (
    frequency in ('weekly', 'biweekly', 'twiceMonthly', 'monthly', 'quarterly', 'yearly', 'oneTime')
  ),
  is_active boolean not null,
  next_pay_date date,
  note text,
  created_at timestamptz not null,
  updated_at timestamptz not null
);

comment on table public.monthly_plan_income_sources is
  'Server-side synchronized mirror of a locally-owned IncomeSource. Same "cloud durability / future
   shared read, never a second source of truth for the owner''s own app" posture as
   manual_accounts/manual_transactions.';

create index if not exists monthly_plan_income_sources_owner_user_id_idx
  on public.monthly_plan_income_sources (owner_user_id);

alter table public.monthly_plan_income_sources enable row level security;
-- Default-deny — no anon/authenticated policy.

-- OWNERSHIP IMMUTABILITY GUARD — `id` here IS client-supplied (matches the local `IncomeSource.id`
-- UUID, needed for idempotent per-row sync unlike the singleton settings table above), so the
-- exact ownership-hijack class discovered and fixed for `manual_accounts` in Phase 5B applies
-- here too: a caller could otherwise reuse an `id` already owned by someone else and have a bare
-- upsert silently reassign that row to themselves. This trigger closes that gap at the database
-- level (defense in depth, alongside sync-monthly-plan-data's own pre-upsert ownership check —
-- see that file's own header) — mirrors `prevent_manual_account_owner_change` exactly (migration
-- 0011): ordinary updates to every OTHER column remain fully permitted; only a change to
-- owner_user_id itself is rejected.
create or replace function public.prevent_monthly_plan_income_source_owner_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if NEW.owner_user_id is distinct from OLD.owner_user_id then
    raise exception 'monthly_plan_income_sources.owner_user_id cannot be changed once set.';
  end if;
  return NEW;
end;
$$;

create trigger monthly_plan_income_sources_protect_owner
  before update on public.monthly_plan_income_sources
  for each row execute function public.prevent_monthly_plan_income_source_owner_change();

-- ============================================================================================
-- 3. monthly_plan_recurring_expenses
-- ============================================================================================
--
-- COLUMN SELECTION reasoning:
--   INCLUDED: `name`, `note`, `is_essential` — display context (`is_essential` is explicitly
--   documented locally as "shown in the UI as a badge; not used in the money math itself," but is
--   cheap, already-available, and directly useful for a future shared display — included as
--   context, not because any formula needs it). `category_name` — a DENORMALIZED SNAPSHOT of the
--   local `Category.name` at sync time, NOT a foreign key, matching `manual_transactions.
--   category_name`''s exact precedent and reasoning (migration 0011) — `Category` has no
--   server-side table. `amount`/`frequency`/`is_active`/`due_date` — the ONLY `RecurringExpense`
--   fields `MonthlyPlanCalculator.estimatedMonthlyFixedExpenses` actually reads (verified directly
--   against current source, same method as income sources above).
--   EXCLUDED: `timing`/`dayOfMonth` — same verified-unused reasoning as `IncomeSource` above.
--   `paymentAccount` — a local FK to `Account` (now itself cloud-synced as `manual_accounts`,
--   migration 0011) — NEVER read by `MonthlyPlanCalculator`''s formulas (confirmed directly: only
--   amount/frequency/isActive/dueDate are used) and irrelevant to a read-only shared Monthly Plan,
--   which is fundamentally about income/expense/savings NUMBERS, not which physical account pays
--   what. Deliberately excluded rather than adding a cross-feature `manual_accounts` FK coupling
--   this phase does not need — matches this phase''s own instruction not to modify/extend Manual
--   Account sync without a direct dependency requiring it.
--
-- `due_date` is `date`, not `timestamptz` — identical reasoning to `next_pay_date` above.
create table if not exists public.monthly_plan_recurring_expenses (
  id uuid primary key,
  owner_user_id uuid not null references auth.users (id),
  name text not null,
  amount numeric not null,
  frequency text not null check (
    frequency in ('weekly', 'biweekly', 'twiceMonthly', 'monthly', 'quarterly', 'yearly', 'oneTime')
  ),
  is_active boolean not null,
  due_date date,
  is_essential boolean not null,
  category_name text,
  note text,
  created_at timestamptz not null,
  updated_at timestamptz not null
);

comment on table public.monthly_plan_recurring_expenses is
  'Server-side synchronized mirror of a locally-owned RecurringExpense. Same posture as
   monthly_plan_income_sources above.';

comment on column public.monthly_plan_recurring_expenses.category_name is
  'A denormalized snapshot of the local Category.name at sync time — NOT a foreign key, matching
   manual_transactions.category_name''s exact precedent (migration 0011).';

create index if not exists monthly_plan_recurring_expenses_owner_user_id_idx
  on public.monthly_plan_recurring_expenses (owner_user_id);

alter table public.monthly_plan_recurring_expenses enable row level security;
-- Default-deny — no anon/authenticated policy.

-- OWNERSHIP IMMUTABILITY GUARD — same reasoning and shape as
-- prevent_monthly_plan_income_source_owner_change above.
create or replace function public.prevent_monthly_plan_recurring_expense_owner_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if NEW.owner_user_id is distinct from OLD.owner_user_id then
    raise exception 'monthly_plan_recurring_expenses.owner_user_id cannot be changed once set.';
  end if;
  return NEW;
end;
$$;

create trigger monthly_plan_recurring_expenses_protect_owner
  before update on public.monthly_plan_recurring_expenses
  for each row execute function public.prevent_monthly_plan_recurring_expense_owner_change();

-- ============================================================================================
-- 4. get_monthly_plan_with_sources — the trusted shared-read path
-- ============================================================================================
--
-- Returns ONE owner's Monthly Plan settings plus their income sources and recurring expenses (as
-- jsonb arrays), for a caller identity that MUST already be server-verified
-- (requireAuthenticatedUserId() in the calling Edge Function) — never a client-supplied
-- "recipient_user_id" trusted as-is. Combines all three synchronized sources in ONE function
-- (rather than separate RPCs) so the owner/Secondary authorization check is performed exactly
-- ONCE per call — same discipline as get_manual_account_with_transactions (migration 0011).
--
-- GLOBAL-ONLY SHARING — the one deliberate structural difference from
-- get_connected_account_transactions/get_manual_account_with_transactions: this function takes NO
-- item_id parameter at all, and always calls is_effectively_shared_for_user with p_item_id = NULL.
-- Migration 0008's own CHECK constraint (`category <> 'monthlyPlan' or item_id is null`) already
-- makes a per-item monthlyPlan permission row impossible to insert in the first place — this
-- function's own hardcoded NULL is a second, structural enforcement of the same "global only"
-- rule, not merely relying on that CHECK constraint alone.
--
-- Same two-path authorization as prior phases:
--   1. OWNER PATH: p_caller_user_id is the plan's own owner -> always authorized, independent of
--      sharing_permissions.
--   2. SECONDARY PATH: resolve the one household (if any) connecting caller and owner (reusing
--      resolve_household_for_owner_and_recipient from migration 0010 — a category-agnostic
--      helper), then defer entirely to is_effectively_shared_for_user with
--      category = 'monthlyPlan' and item_id = NULL. No duplicated permission logic.
--
-- ANTI-ENUMERATION: an owner with no monthly_plan_settings row at all, an owner entirely
-- unconnected to the caller, and a genuinely-connected-but-not-shared owner all produce the exact
-- same result — a single null row, no error, no distinguishing signal.
--
-- Returns ONLY the columns a read-only shared display needs — never owner_user_id itself.
create or replace function public.get_monthly_plan_with_sources(
  p_caller_user_id uuid,
  p_owner_user_id uuid
)
returns table (
  monthly_savings_goal numeric,
  buffer_amount numeric,
  auto_update_weekly_budget_from_plan boolean,
  updated_at timestamptz,
  income_sources jsonb,
  recurring_expenses jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_authorized boolean;
begin
  if p_caller_user_id = p_owner_user_id then
    v_authorized := true;
  else
    v_household_id := public.resolve_household_for_owner_and_recipient(p_owner_user_id, p_caller_user_id);
    v_authorized := v_household_id is not null
      and public.is_effectively_shared_for_user(
        v_household_id, p_owner_user_id, p_caller_user_id, 'monthlyPlan', null
      );
  end if;

  if not coalesce(v_authorized, false) then
    return;
  end if;

  return query
    select
      mps.monthly_savings_goal, mps.buffer_amount, mps.auto_update_weekly_budget_from_plan,
      mps.updated_at,
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', s.id, 'name', s.name, 'amount', s.amount, 'frequency', s.frequency,
              'is_active', s.is_active, 'next_pay_date', s.next_pay_date, 'note', s.note
            )
          )
          from public.monthly_plan_income_sources s
          where s.owner_user_id = p_owner_user_id
        ),
        '[]'::jsonb
      ) as income_sources,
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', e.id, 'name', e.name, 'amount', e.amount, 'frequency', e.frequency,
              'is_active', e.is_active, 'due_date', e.due_date, 'is_essential', e.is_essential,
              'category_name', e.category_name, 'note', e.note
            )
          )
          from public.monthly_plan_recurring_expenses e
          where e.owner_user_id = p_owner_user_id
        ),
        '[]'::jsonb
      ) as recurring_expenses
    from public.monthly_plan_settings mps
    where mps.owner_user_id = p_owner_user_id;
end;
$$;

-- ============================================================================================
-- 5. EXECUTE privilege lockdown — same convention as migrations 0008/0009/0010/0011
-- ============================================================================================

revoke execute on function public.prevent_monthly_plan_income_source_owner_change() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.

revoke execute on function public.prevent_monthly_plan_recurring_expense_owner_change() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.

revoke execute on function public.get_monthly_plan_with_sources(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_monthly_plan_with_sources(uuid, uuid) to service_role;
-- Not granted to authenticated — identical reasoning to get_connected_account_transactions/
-- get_manual_account_with_transactions: p_caller_user_id is a plain parameter, not derived from
-- auth.uid(), so only the trusted get-monthly-plan-data Edge Function (which derives it from
-- requireAuthenticatedUserId()) may ever call this.
