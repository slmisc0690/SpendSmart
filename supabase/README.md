# SpendSmart Plaid backend (Supabase Edge Functions)

This directory is the secure backend the SpendSmart iOS app talks to for connecting financial
institutions through Plaid. **None of this code runs on the iPhone.** The app only ever calls the
HTTPS endpoints these functions expose — it never talks to Plaid directly and never sees a Plaid
client secret or access token.

**Multi-institution, institution-agnostic.** A household account can link more than one
institution (or more than one Item at the same institution — see "Duplicate Item detection"
below). Nothing in this backend assumes a specific bank; the user picks their institution inside
Plaid Link's own hosted UI. Every Plaid connection is scoped by `connection_id` — this project's
own opaque `plaid_items.id` UUID — never guessed from "the one row for this user," since a user
can have more than one.

**Products.** `create-link-token` requests the `transactions` product from Plaid for every new
connection. Account and balance data is retrieved for the same Item via Plaid's `/accounts/get`
(the "Balance" functionality) — through the single shared `refreshPlaidAccounts` helper in
`_shared/plaid.ts`, used by `exchange-public-token`, `sync-balances`, and
`refresh-plaid-accounts` alike, so there is exactly one place in this project that maps a Plaid
account onto a `plaid_accounts` row.

## Environment handling

`_shared/plaid.ts`'s `loadPlaidCredentials` is the single place that decides which Plaid
environment every Edge Function talks to, controlled by the `PLAID_ENV` Supabase Secret. It
accepts exactly `"sandbox"`, `"development"`, or `"production"` — **fails closed**: a missing,
empty, whitespace-only, or unrecognized `PLAID_ENV` value throws rather than silently defaulting
to any environment (there is no implicit fallback to Sandbox). Switching which environment is live
is a deliberate `supabase secrets set PLAID_ENV=...` change, not something that happens by
accident.

Every `plaid_items` row records the Plaid environment it was created under (see migration
`0005_plaid_items_environment.sql`). Before any Plaid call that reuses an existing Item's stored
`access_token`, `assertItemEnvironmentMatches` checks that the Item's stored environment still
matches the server's currently active `PLAID_ENV` — a token issued under one environment can never
be sent to a different environment's host.

## Functions

| Function | Called by | Purpose |
|---|---|---|
| `create-link-token` | iOS app | Gets a `link_token` for Plaid Link — either a NEW connection, or UPDATE MODE (reconnect) for an existing `connection_id` |
| `exchange-public-token` | iOS app (after Link succeeds) | Exchanges `public_token` → `access_token`, stores it server-side, discovers accounts, and checks for a duplicate Item at the same institution |
| `sync-transactions` | iOS app | Fetches new/updated transactions via `/transactions/sync` for one `connection_id`, returns a normalized read-only list |
| `sync-balances` | iOS app | Refreshes account balances for one `connection_id` via `/accounts/get` |
| `refresh-plaid-accounts` | iOS app | Rediscovers accounts for an EXISTING connection after a successful reconnect, and clears `requires_reauth`/`new_accounts_available` on success |
| `disconnect-account` | iOS app | Revokes the Plaid Item (`/item/remove`) and deletes the stored `plaid_items` row for one `connection_id` |
| `delete-account` | iOS app | Revokes every Plaid connection this user has, deletes every row this user owns, then deletes the `auth.users` row itself |
| `plaid-webhook` | Plaid (server-to-server) | Verifies Plaid's `Plaid-Verification` signature, then updates `plaid_items` state flags (`requires_reauth`, `pending_expiration_at`, `pending_disconnect_at`, `new_accounts_available`) for the affected Item |
| `list-connections` | iOS app | Returns the authoritative, server-side status of every institution this user has linked, including flags set asynchronously by a webhook |

## OAuth redirect URI

`PLAID_OAUTH_REDIRECT_URI` (`_shared/plaid.ts`) is a fixed constant —
`https://plaid.sldevapps.com/spendsmart/plaid/` — passed on every `/link/token/create` call
(both new-connection and update-mode). It is a Universal Link (HTTPS), never a custom URL scheme,
which Plaid requires for native-iOS OAuth/App-to-App institution redirects. This exact string must
match, byte-for-byte: the iOS Associated Domains entitlement (`applinks:plaid.sldevapps.com`), the
app-side URL-recognition boundary (`PlaidOAuthReturn` in `PlaidConnectionManager.swift`), the Plaid
Dashboard's Allowed Redirect URI entry, and the `apple-app-site-association` file hosted at that
subdomain. It is never read from the request body — the iOS client can never influence it.

## Webhook signature verification

`plaid-webhook` verifies every incoming webhook is genuinely from Plaid before trusting anything in
the payload — `verifyPlaidWebhookSignature` in `_shared/plaid.ts` decodes the `Plaid-Verification`
JWT header, fetches (and caches) the matching verification key from Plaid's own
`/webhook_verification_key/get`, verifies the ES256 signature, checks the JWT is fresh (`iat`
within 5 minutes), and checks the JWT's `request_body_sha256` claim against a SHA-256 of the exact
raw request body. Any failure (missing header, malformed JWT, unknown/expired key, bad signature,
stale timestamp, body hash mismatch) is rejected with a flat, detail-free 401 — never revealing
which check failed. `plaid-webhook` never calls `sync-transactions`/`sync-balances` itself; it only
flips state flags on the affected `plaid_items` row, which the app reads via `list-connections`.

## Update / reconnect mode

Reconnecting an existing institution (e.g. after `ITEM_LOGIN_REQUIRED`, or to pick up newly
available accounts) goes through `create-link-token`'s `connection_id` branch — Plaid Link opens in
UPDATE MODE using the Item's own existing `access_token` (never a fresh `user`/`products`), with
`update.account_selection_enabled: true` so the user can pick up new accounts during the same
session. This does not invalidate the existing `access_token`, `plaid_items` row, or any
already-synced transactions/accounts. After a successful update-mode Link session, the app calls
`refresh-plaid-accounts`, which rediscovers accounts and — only on success — clears
`requires_reauth`/`new_accounts_available` together.

## Duplicate Item detection

After a successful `exchange-public-token` call, the backend checks whether the same user already
has a *different* `plaid_items` row for the same `institution_id` (via the non-unique
`plaid_items_user_institution_idx` index — see migration
`0007_plaid_items_institution_index.sql`). This never blocks or merges anything: a user can
legitimately have more than one Item at the same institution (e.g. two different logins). The
response includes `duplicate_institution`/`existing_connection_id`/`existing_institution_name` so
the app can prompt the user to choose "Keep Both" or "Use Existing Connection" (which disconnects
only the newly created Item).

## Pending expiration / disconnect states

`plaid-webhook` records two at-risk signals Plaid can send ahead of an Item actually breaking:
`PENDING_EXPIRATION` sets `pending_expiration_at` (an OAuth consent window closing soon), and
`PENDING_DISCONNECT` sets `pending_disconnect_at` (Plaid expects the Item to stop working soon).
Neither ever triggers an automatic disconnect — both are recorded only, surfaced to the user via
`list-connections`, and the app prompts a reconnect through its own UI. A `LOGIN_REPAIRED` webhook
clears `requires_reauth`, `pending_expiration_at`, and `pending_disconnect_at` together, since a
successful re-authentication supersedes any earlier at-risk signal.

## Local cleanup on disconnect and account deletion

`disconnect-account` revokes the Item at Plaid and deletes its `plaid_items` row server-side; the
iOS app then calls `PlaidLocalDataCleanupService.deletePlaidTransactions(matchingAccountIds:)` to
remove only that connection's locally-cached, Plaid-imported transactions (scoped by the
connection's own account IDs, resolved before the disconnect call while still possible) — Plaid
data should not outlive the connection it came from. `delete-account` revokes every Plaid
connection this user has (best-effort per Item, skipping any Item created under a different
environment than the one currently active), deletes every row this user owns, then deletes the
`auth.users` row itself; the iOS app follows with
`PlaidLocalDataCleanupService.deleteAllLocalData(context:)` to clear every local SwiftData model.

## One-time setup

1. **Install the Supabase CLI** and log in / link this project:
   ```
   supabase login
   supabase link --project-ref <your-project-ref>
   ```

2. **Get Plaid credentials** from the [Plaid Dashboard](https://dashboard.plaid.com/) — a
   `client_id` and the `secret` matching whichever environment you intend to run
   (`PLAID_ENV=sandbox` needs the Sandbox secret, `PLAID_ENV=production` needs the Production
   secret — never mix the two).

3. **Set secrets** (never commit these — this is why they're secrets, not code):
   ```
   supabase secrets set PLAID_CLIENT_ID=your_client_id
   supabase secrets set PLAID_SECRET=your_secret
   supabase secrets set PLAID_ENV=sandbox   # or development / production
   ```
   `SUPABASE_URL` and `SUPABASE_SECRET_KEYS` (a JSON object of named secret keys — read the
   `"default"` entry) are provided automatically to Edge Functions by Supabase — you don't set
   those yourself.

4. **Run the migrations** to create/update the `plaid_items`/`plaid_accounts` schema:
   ```
   supabase db push
   ```
   Migrations `0001` through `0007` cover the base schema, requiring an authenticated `user_id`,
   multi-institution support, balance fields, the per-Item environment marker, the
   `pending_disconnect_at` flag, and the duplicate-Item detection index, in that order.

5. **Deploy the functions:**
   ```
   supabase functions deploy create-link-token
   supabase functions deploy exchange-public-token
   supabase functions deploy sync-transactions
   supabase functions deploy sync-balances
   supabase functions deploy refresh-plaid-accounts
   supabase functions deploy disconnect-account
   supabase functions deploy delete-account
   supabase functions deploy plaid-webhook
   supabase functions deploy list-connections
   ```

6. **Point the iOS app at your backend** — set `PlaidBackendConfig.baseURL` in
   `FinanceTrack/Sync/PlaidBackendService.swift` to your project's Edge Functions URL:
   `https://<project-ref>.supabase.co/functions/v1` (this is the standard Supabase Edge
   Functions invocation path — plain `https://<project-ref>.supabase.co` on its own will 404).

## Plaid Support and Troubleshooting

### Where to find logs and tools

- **Supabase Edge Function logs** — Supabase Dashboard → Edge Functions → select a function →
  Logs, or `supabase functions logs <function-name>` from the CLI. Every function logs a
  `[function-name]`-prefixed line for its key steps, plus one structured `logPlaidOperation(...)`
  line per successful operation (see `_shared/plaid.ts`) carrying safe correlation identifiers.
- **Plaid Dashboard Activity Log** — [dashboard.plaid.com](https://dashboard.plaid.com/) →
  Activity — a chronological log of every API call this project's credentials made against Plaid,
  searchable by `request_id` or Item.
- **Plaid Item Debugger** — Plaid Dashboard → search a specific Item by its `item_id` to see its
  current status, last webhook, and error state directly from Plaid's side.
- **Institution Status** — [status.plaid.com](https://status.plaid.com/) — check for an ongoing
  institution-wide outage before assuming the issue is this project's own code.

### Correlating an incident

Each of these identifiers narrows an incident to one specific request, Item, or connection —
cross-reference them between Supabase logs and Plaid's own tools:

- **`connection_id`** — this project's own `plaid_items.id` UUID. Logged by every function as
  `connectionId` in its `logPlaidOperation` line; also the identifier the iOS app itself holds and
  sends on every call. Use it to find the exact `plaid_items` row in Postgres.
- **`item_id`** — Plaid's own Item identifier. Logged where already in scope (e.g.
  `exchange-public-token`, `plaid-webhook`) as `itemId`; never fetched solely to log it. This is
  what the Plaid Item Debugger searches by.
- **`request_id`** — Plaid's own per-call correlation id, captured from the response body (or
  header, as a fallback) by `extractPlaidRequestId` and attached to `PlaidRequestError`. Logged by
  `logSafeError`'s `PlaidRequestError` branch and by `logPlaidOperation` where available. This is
  the identifier Plaid Support asks for first when investigating a specific API call.
- **`institution_id`** — Plaid's institution identifier, logged where known (e.g.
  `exchange-public-token`). Useful for spotting an institution-wide pattern versus a single user's
  issue.
- **`link_session_id`** — LinkKit's own per-Link-session identifier, logged client-side via
  `PlaidLinkLogging` (Apple Unified Logging, `"PlaidLink"` category) in
  `ConnectedAccountsView.swift` for every Link lifecycle/event/exit. Correlates a specific Link
  session on-device with Plaid's own Link analytics.

### Identifiers safe to give Plaid Support

`connection_id`, `item_id`, `request_id`, `institution_id`, `link_session_id`, webhook
`type`/`code`, the active Plaid environment (`sandbox`/`development`/`production`), and an
approximate timestamp/operation name are all safe to share — none of them are secrets, and none of
them can be used to access an account.

### Values that must never be shared

Never paste or send any of the following to Plaid Support, in a bug report, or anywhere outside
this project's own Supabase Secrets:

- `PLAID_SECRET`
- `access_token`
- `public_token`
- `link_token`
- the Supabase **service-role key**
- any Supabase user authentication token
- account or routing numbers
- any other raw financial data (balances, transaction descriptions/amounts)

### Troubleshooting sequence

1. **Reproduce** the issue (or get the exact steps/time from the user report).
2. **Record the time and the operation** — which screen action, which of the 9 functions.
3. **Find the Supabase log** for that function around that time (Dashboard or
   `supabase functions logs`).
4. **Capture `request_id`/`item_id`** from that log line (or from `logSafeError`'s
   `PlaidRequestError` output, which includes `request_id` alongside the HTTP `status`).
5. **Check Plaid's Activity Log and Institution Status** for that `request_id`/Item and
   institution.
6. **Escalate to Plaid Support only with the safe identifiers** listed above — never a token or
   secret.
