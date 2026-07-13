-- Prepares plaid_items for multiple institutions per user and real institution identity, and
-- adds plaid_accounts for per-account balance tracking. Additive only — no existing column is
-- dropped or renamed, so every already-deployed row (including any Sandbox test connections)
-- keeps working unchanged; new columns default to values that describe "nothing has happened
-- yet" (false/null), not "everything is fine".

-- institution_name previously defaulted to the literal string 'American Express' — a hardcoded
-- assumption this migration removes. exchange-public-token now writes the REAL institution name
-- Plaid Link reports at connection time; existing rows keep whatever value they already have
-- (which, for every row created before this migration, genuinely was American Express, so no
-- backfill is needed or performed).
alter table public.plaid_items
  alter column institution_name drop default;

alter table public.plaid_items
  add column if not exists institution_id text,
  -- Set by plaid-webhook on an ITEM_LOGIN_REQUIRED webhook — the user must reconnect (Link
  -- update mode) before sync-transactions will work again for this item. Plaid still accepts
  -- /transactions/sync calls with a token in this state, but they fail, so the app should stop
  -- calling it and prompt reconnection instead of retrying indefinitely.
  add column if not exists requires_reauth boolean not null default false,
  -- Set by plaid-webhook on a PENDING_EXPIRATION webhook (mainly OAuth institutions whose
  -- consent expires on a schedule) — when this is in the past, expect ITEM_LOGIN_REQUIRED soon.
  add column if not exists pending_expiration_at timestamptz,
  -- Set by plaid-webhook on a NEW_ACCOUNTS_AVAILABLE webhook — the institution has accounts this
  -- Item doesn't cover yet; the user can reconnect (update mode) to add them. Cleared back to
  -- false once the app has re-run exchange-public-token-style account discovery for this item.
  add column if not exists new_accounts_available boolean not null default false,
  -- Observability only — the most recent webhook this item received, for support/debugging.
  -- Never used for authorization or business logic; requires_reauth/pending_expiration_at/
  -- new_accounts_available above are the actual state flags the app reads.
  add column if not exists last_webhook_code text,
  add column if not exists last_webhook_at timestamptz;

comment on column public.plaid_items.institution_id is
  'Plaid''s own institution identifier (e.g. "ins_109508") — stable across reconnects, unlike institution_name which a user could theoretically see change.';

-- One row per Plaid account within an item (a single American Express Item, for example, can
-- cover more than one physical card). Populated by exchange-public-token right after a successful
-- exchange, and refreshed by sync-balances. Never holds a Plaid access_token — that stays only on
-- plaid_items, which every function here reads through instead.
create table if not exists public.plaid_accounts (
  id uuid primary key default gen_random_uuid(),
  plaid_item_id uuid not null references public.plaid_items (id) on delete cascade,
  account_id text not null unique, -- Plaid's own account_id
  name text,
  official_name text,
  mask text, -- last 2-4 digits, safe to store/display
  type text, -- Plaid's `type`, e.g. "credit", "depository"
  subtype text, -- Plaid's `subtype`, e.g. "credit card", "checking"
  current_balance numeric,
  available_balance numeric,
  iso_currency_code text,
  updated_at timestamptz not null default now()
);

create index if not exists plaid_accounts_plaid_item_id_idx on public.plaid_accounts (plaid_item_id);

alter table public.plaid_accounts enable row level security;
-- Same policy stance as plaid_items: locked down entirely by default, no anon/authenticated
-- policy — only Edge Functions running with the service-role-equivalent secret key ever touch
-- this table.
