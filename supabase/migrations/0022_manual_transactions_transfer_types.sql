-- BUG FIX — `manual_transactions.transaction_type` was never widened when
-- `transferWithdrawal`/`transferDeposit`/`transferToSavings` were added to the Swift
-- `TransactionType` enum. Every such transaction has been silently rejected by
-- `planManualTransactionSync` (supabase/functions/_shared/manual.ts's matching allowlist, fixed
-- alongside this migration) and has never reached this table — meaning it can never be shared
-- with a household Secondary, and would be permanently lost on a cloud restore
-- (`get-my-manual-accounts`) after a local wipe. This migration only widens the CHECK constraint;
-- no other column, index, trigger, or function is touched, and no existing row is affected (they
-- were all already one of the six pre-existing values, since nothing else could have been
-- inserted).
--
-- Never edit an already-shipped migration (this project's own standing discipline) — 0011's
-- constraint is dropped and re-added here. Looked up dynamically by definition, matching
-- migration 0018's own precedent, rather than assuming the auto-generated name, so this is not
-- silently ineffective if the constraint was ever named explicitly.
do $$
declare
  v_constraint_name text;
begin
  select conname
    into v_constraint_name
    from pg_constraint
    where conrelid = 'public.manual_transactions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%transaction_type%expense%income%';

  if v_constraint_name is not null then
    execute format('alter table public.manual_transactions drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.manual_transactions
  add constraint manual_transactions_transaction_type_check
  check (
    transaction_type in (
      'expense', 'income', 'transfer', 'creditCardPayment', 'refund', 'balanceAdjustment',
      'transferWithdrawal', 'transferDeposit', 'transferToSavings'
    )
  );
