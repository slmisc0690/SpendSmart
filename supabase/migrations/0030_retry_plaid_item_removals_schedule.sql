-- RETRY-PLAID-ITEM-REMOVALS SCHEDULING — the automatic, indefinite consumer of
-- plaid_item_removal_failures (migration 0029). Introduces this project's FIRST background job
-- scheduler (pg_cron + pg_net) — deliberately avoided until now (see migration 0028's own
-- header: "this project introduces no background job scheduler... in this phase"). Justified
-- specifically because a live Plaid Item's access_token sitting unrevoked is the one thing in
-- this app that keeps costing real money for as long as nothing acts on it.
--
-- SECRET HANDLING — pg_net's http_post needs a literal URL and Authorization header value at
-- call time; NEITHER is embedded in this migration file (which is committed to git). Both are
-- read from Supabase Vault (already enabled on this project) via vault.decrypted_secrets,
-- populated separately, outside of any migration file, under the names
-- 'retry_plaid_item_removals_url' and 'retry_plaid_item_removals_auth_key' — this migration only
-- references those NAMES, never a value. A run with either secret missing logs a warning and
-- does nothing, rather than failing loudly on every tick or (worse) calling out with a garbage
-- Authorization header.
create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function public.trigger_retry_plaid_item_removals()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_key text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'retry_plaid_item_removals_url';

  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'retry_plaid_item_removals_auth_key';

  if v_url is null or v_key is null then
    raise warning 'trigger_retry_plaid_item_removals: Vault secrets not configured, skipping this run';
    return;
  end if;

  perform net.http_post(
    url := v_url,
    headers := pg_catalog.jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := '{}'::pg_catalog.jsonb
  );
end;
$$;

comment on function public.trigger_retry_plaid_item_removals() is
  'Called hourly by the retry-plaid-item-removals-hourly cron job. Reads its target URL and auth
   secret from Supabase Vault (never from this migration file) and fires one HTTP POST to the
   retry-plaid-item-removals Edge Function, which itself decides per-row whether each is actually
   due for a retry this tick (hourly for 24h, then daily) — this function is only the trigger.';

-- Never callable by anon/authenticated, even indirectly — only the cron scheduler (which runs as
-- the Postgres superuser regardless of these grants) and service_role can invoke it.
revoke all on function public.trigger_retry_plaid_item_removals() from public, anon, authenticated;
grant execute on function public.trigger_retry_plaid_item_removals() to service_role;

select cron.schedule(
  'retry-plaid-item-removals-hourly',
  '0 * * * *',
  $$select public.trigger_retry_plaid_item_removals();$$
);
