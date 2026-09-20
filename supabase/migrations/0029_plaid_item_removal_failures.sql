-- PLAID ITEM LEAK CLOSURE — records a Plaid Item's access_token when delete-account cannot
-- confirm the Item was actually revoked at Plaid (either /item/remove failed, or the Item's
-- environment didn't match the server's active PLAID_ENV and the call was never attempted at
-- all — see delete-account/index.ts). Before this table existed, delete-account deleted the
-- plaid_items row in both cases regardless, permanently losing the only local record of a Plaid
-- Item that could keep billing forever with zero trace anywhere in this system.
--
-- SELF-EMPTYING BY DESIGN, per explicit product decision: a row here exists ONLY because its
-- Item is not yet confirmed revoked. The retry-plaid-item-removals function (a separate,
-- follow-up migration/function) deletes a row the moment /item/remove succeeds for it — never
-- marks it resolved, never retains it as history. This table's steady-state size should be zero;
-- any non-zero count is an open, actionable problem, not a historical log.
--
-- MINIMUM FIELDS ONLY, deliberately: item_id, access_token, environment, reason, detected_at are
-- the fields identified as strictly necessary to eventually finish revoking the Item.
-- attempt_count/last_attempted_at are the two additional fields approved specifically because
-- they are process metadata (how the retry mechanism is doing), never user identity. There is
-- NO user_id, no email, and no account identifier of any kind here — by the time a row is
-- written, the owning user's account has already been deleted; this table must never become a
-- record of who they were.
create table if not exists public.plaid_item_removal_failures (
  id uuid primary key default gen_random_uuid(),
  item_id text not null,
  access_token text not null, -- never returned to any client; server-side use only, exactly like plaid_items.access_token
  environment text not null,
  reason text not null check (reason in ('environment_mismatch', 'revoke_failed')),
  detected_at timestamptz not null default now(),
  attempt_count int not null default 0,
  last_attempted_at timestamptz
);

comment on table public.plaid_item_removal_failures is
  'Self-emptying queue of Plaid Items delete-account could not confirm were revoked. A row is
   deleted the instant retry-plaid-item-removals successfully calls /item/remove for it — this
   table is never a history, only a to-do list. Steady-state size should be zero.';

-- Supports the future monitor endpoint''s "how many rows are older than 24 hours" query
-- (Step 2 of this feature) without a sequential scan as this table grows.
create index if not exists plaid_item_removal_failures_detected_at_idx
  on public.plaid_item_removal_failures (detected_at);

alter table public.plaid_item_removal_failures enable row level security;

-- DEFENSE IN DEPTH, explicitly requested: default-deny RLS (matching plaid_items/plaid_accounts/
-- plaid_transaction_removals' own established posture) PLUS an explicit revoke/grant, so two
-- independent mechanisms both have to fail for any non-service-role client to ever read a row
-- here. Zero policies are created for any role — only service_role (which bypasses RLS
-- entirely) can read or write this table, and only from an Edge Function, never directly from
-- the iOS app.
revoke all on public.plaid_item_removal_failures from public, anon, authenticated;
grant all on public.plaid_item_removal_failures to service_role;
