-- LOCAL DATA RESTORE (owner-only) — fixes a real gap surfaced by a fresh-install data-loss report:
-- `get-monthly-plan-data` already supports self-access (get_monthly_plan_with_sources treats
-- p_caller_user_id = p_owner_user_id as always authorized), so Monthly Plan can already be pulled
-- back down after a local wipe by calling that existing, already-deployed function with the
-- caller's own id. Manual Accounts had no equivalent: `get_manual_account_with_transactions`
-- requires a `manual_account_id` the caller must already know, which a fresh local install has no
-- way to discover. This migration adds ONE new owner-only function to close that gap — no sharing
-- logic needed at all, since this only ever returns the caller's own rows.
--
-- SECURITY DEFINER + search_path = '' + full schema-qualification + revoke-then-grant-to-
-- service_role-only, matching every other privileged function in this schema (see
-- get_manual_account_with_transactions, migration 0011, for the identical established pattern).

create or replace function public.get_my_manual_accounts_with_transactions(
  p_caller_user_id uuid,
  p_limit_per_account int default 200
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
  v_limit int;
begin
  v_limit := least(greatest(coalesce(p_limit_per_account, 200), 1), 500);

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
    where ma.owner_user_id = p_caller_user_id
    order by ma.created_at asc;
end;
$$;

revoke execute on function public.get_my_manual_accounts_with_transactions(uuid, int) from public, anon, authenticated, service_role;
grant execute on function public.get_my_manual_accounts_with_transactions(uuid, int) to service_role;
