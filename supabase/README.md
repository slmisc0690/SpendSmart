# SpendSmart Plaid backend (Supabase Edge Functions)

This directory is the secure backend the SpendSmart iOS app talks to for American Express
syncing. **None of this code runs on the iPhone.** The app only ever calls the HTTPS endpoints
these functions expose — it never talks to Plaid directly and never sees a Plaid client secret
or access token.

Sandbox only, on purpose: `_shared/plaid.ts` hard-fails if `PLAID_ENV` isn't `"sandbox"`. Going
live with production Plaid/real Amex credentials is a deliberate future decision, not something
that happens by accident.

## Functions

| Function | Called by | Purpose |
|---|---|---|
| `create-link-token` | iOS app | Gets a `link_token` for Plaid Link |
| `exchange-public-token` | iOS app (after Link succeeds) | Exchanges `public_token` → `access_token`, stores it server-side |
| `sync-transactions` | iOS app | Fetches new transactions via `/transactions/sync`, returns a normalized read-only list |
| `disconnect-amex` | iOS app | Revokes the Plaid item and deletes the stored token |
| `plaid-webhook` | Plaid (server-to-server) | Placeholder — not verified or wired up yet, see TODOs in the file |

## One-time setup

1. **Install the Supabase CLI** and log in / link this project:
   ```
   supabase login
   supabase link --project-ref <your-project-ref>
   ```

2. **Get Plaid Sandbox credentials** from the [Plaid Dashboard](https://dashboard.plaid.com/) —
   your `client_id` and **Sandbox** `secret` (not the Development/Production secret).

3. **Set secrets** (never commit these — this is why they're secrets, not code):
   ```
   supabase secrets set PLAID_CLIENT_ID=your_client_id
   supabase secrets set PLAID_SECRET=your_sandbox_secret
   supabase secrets set PLAID_ENV=sandbox
   ```
   `SUPABASE_URL` and `SUPABASE_SECRET_KEYS` (a JSON object of named secret keys — read the
   `"default"` entry) are provided automatically to Edge Functions by Supabase — you don't set
   those yourself.

4. **Run the migration** to create the `plaid_items` table:
   ```
   supabase db push
   ```
   Read the comment at the top of `migrations/0001_plaid_items.sql` first — it asks you to
   decide between a single-user setup (simplest, since SpendSmart has no login today) or wiring
   up Supabase Auth for multiple users.

5. **Deploy the functions:**
   ```
   supabase functions deploy create-link-token
   supabase functions deploy exchange-public-token
   supabase functions deploy sync-transactions
   supabase functions deploy disconnect-amex
   supabase functions deploy plaid-webhook
   ```

6. **Point the iOS app at your backend** — set `PlaidBackendConfig.baseURL` in
   `FinanceTrack/Sync/PlaidBackendService.swift` to your project's Edge Functions URL:
   `https://<project-ref>.supabase.co/functions/v1` (this is the standard Supabase Edge
   Functions invocation path — plain `https://<project-ref>.supabase.co` on its own will 404).
   `baseURL` is `nil` by default so the app can't accidentally call a real endpoint before you've
   set this up.

## What's NOT done yet

- **Webhook verification.** `plaid-webhook` logs whatever it receives without checking it's
  really from Plaid. Don't register this URL with Plaid until that's fixed.
- **User authentication.** There's no login in SpendSmart yet, so these functions assume a
  single linked Amex account. The `user_id` column in `plaid_items` is ready for when that
  changes, but nothing currently enforces it.
- **Plaid Link on iOS.** The app can request a `link_token` and would send back a
  `public_token`, but actually presenting Plaid's Link UI needs the `plaid-link-ios` SDK, which
  hasn't been added to the Xcode project yet (see the iOS app's `Sync/PlaidBackendService.swift`
  doc comment for exactly what to add when you're ready).
