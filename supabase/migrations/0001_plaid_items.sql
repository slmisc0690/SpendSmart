-- Storage for Plaid access tokens. This table lives ONLY in your Supabase Postgres database —
-- the access_token column is never sent to the iOS app under any circumstance.
--
-- Decision you need to make before running this: this project currently has no user accounts
-- (SpendSmart v1 is local-only, no login). Pick one:
--
--   A) Personal single-user deployment (simplest): skip the `user_id` column and Row Level
--      Security below, and just ensure only your own Edge Functions (which hold the service
--      role key) can read this table. Anonymous/public access must stay fully locked down.
--
--   B) Multi-user (if you ever add Supabase Auth / sign-in to SpendSmart): keep `user_id`
--      and the RLS policy below, so each user can only ever have their own row touched by
--      functions running on their behalf.
--
-- The schema below supports both — just decide whether `user_id` is enforced by RLS (B) or
-- effectively unused/single-row (A).

create table if not exists public.plaid_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id), -- nullable for a single-user (option A) deployment
  item_id text not null unique,
  access_token text not null, -- never returned to any client; server-side use only
  cursor text, -- Plaid /transactions/sync cursor, for incremental syncing
  institution_name text default 'American Express',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.plaid_items enable row level security;

-- Locks the table down entirely by default. No policy is created that allows the anon or
-- authenticated roles to read/write this table directly — only Edge Functions running with the
-- service role key (which bypasses RLS) should ever touch it. If you adopt option B (multi-user),
-- add a policy here scoping access to `auth.uid() = user_id` for the specific operations you
-- actually need the client to perform directly (ideally none — go through Edge Functions).
