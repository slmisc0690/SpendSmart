-- Adds tracking for Plaid's PENDING_DISCONNECT Item webhook — sent when Plaid expects an Item to
-- stop working soon (e.g. after a prolonged ITEM_LOGIN_REQUIRED, or the institution itself
-- signals an upcoming removal). Additive only, mirrors pending_expiration_at's shape and intent:
-- record the state, don't act on it — this project never auto-removes Items in response to a
-- webhook (see plaid-webhook/index.ts's own file header for why webhooks are state-only, never
-- action-triggering). The user is only ever prompted via the app's own UI reading this flag;
-- actually disconnecting the Item remains a separate, user-initiated action through
-- disconnect-account.

alter table public.plaid_items
  add column if not exists pending_disconnect_at timestamptz;

comment on column public.plaid_items.pending_disconnect_at is
  'Set by plaid-webhook on a PENDING_DISCONNECT webhook — Plaid expects this Item to stop working soon. Cleared back to null by a LOGIN_REPAIRED webhook (same as requires_reauth/pending_expiration_at), since a successful re-authentication supersedes an earlier at-risk signal. Never causes automatic removal of the Item — the user must still explicitly reconnect or disconnect.';
