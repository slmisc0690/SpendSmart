-- ================================================================================================
-- BACKFILL user_profiles FOR PRE-EXISTING auth.users ROWS
-- ================================================================================================
--
-- PROBLEM: migration 0008 introduced user_profiles plus two triggers
-- (auth_users_sync_profile_on_insert / auth_users_sync_profile_on_email_update) that keep it in
-- sync with auth.users going forward — but neither trigger fires retroactively. Any auth.users row
-- that already existed before migration 0008 was deployed has no user_profiles row and never will
-- on its own, since nothing about that account's own email/existence changes again to re-trigger
-- sync_user_profile(). Confirmed live on Production: 2 of 3 auth.users rows (both created
-- 2026-07-11, before user_profiles existed) had no profile row; the third (created 2026-07-19,
-- after migration 0008) did.
--
-- FIX: a one-time backfill, INSERT ... SELECT ... WHERE NOT EXISTS, using the exact same shape
-- sync_user_profile()'s own INSERT branch already uses (`lower(trim(email))`, display_name left
-- NULL — no approved source for an initial display name exists, matching that function's own
-- documented decision) so a backfilled row is indistinguishable from one the trigger would have
-- created itself. Purely additive: never touches an existing user_profiles row, never deletes
-- anything, safe to run any number of times (the NOT EXISTS guard makes it idempotent).
insert into public.user_profiles (user_id, normalized_email)
select au.id, lower(trim(au.email))
from auth.users au
where not exists (
  select 1 from public.user_profiles up where up.user_id = au.id
);
