-- PHASE 2 — core household / profile / invitation / sharing-permission schema.
--
-- Locked by the Phase 1 / 1B / 1C / 1D architecture audits (household-membership sharing model,
-- corrected permission uniqueness, category naming, Primary integrity, invitation history, and
-- database security lockdown). This migration creates the schema ONLY — no Edge Function in this
-- repository calls any of these tables/functions yet, and no data currently depends on them.
--
-- SCOPE: households, household_members, household_invitations, sharing_permissions, user_profiles,
-- their constraints/indexes, RLS enablement, the canonical sharing-permission evaluator, Primary
-- membership integrity triggers, and auth.users -> user_profiles synchronization. Nothing here
-- touches plaid_items/plaid_accounts, Plaid credentials, or any existing table's data.
--
-- EXCLUDED FROM THIS PHASE (deliberately, per the locked implementation order): plaid_transactions,
-- any Manual Account/Manual Transaction/Monthly Plan/Budget Settings cloud table. (resend_invitation
-- was completed in a follow-up edit to this same file, once its parameter-list contract was locked
-- — see section 8 below.)
--
-- PRE-DEPLOYMENT REQUIREMENT (do not deploy this migration until this is satisfied): the Primary
-- membership delete-protection trigger below (`prevent_primary_membership_delete`) must be
-- empirically tested against an isolated Supabase staging/branch database before production
-- deployment — (1) create a test household + Primary membership, attempt a direct DELETE of the
-- Primary's household_members row, expect rejection; (2) delete the parent household, expect all
-- household_members rows (including the Primary) to cascade-delete successfully. This migration
-- file being authored does not constitute that test having been performed.

-- ============================================================================================
-- 1. households
-- ============================================================================================

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  primary_user_id uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.households is
  'One row per household. primary_user_id is set once at creation (via create_household) and is
   never reassigned by any application code path — household transfer is out of scope. The
   structural guarantee of "exactly one Primary" is enforced jointly by this column plus the
   partial unique index and integrity triggers on household_members below, not by this table
   alone.';

alter table public.households enable row level security;
-- No policy is created for anon/authenticated — default-deny, identical posture to
-- plaid_items/plaid_accounts. All access goes through trusted Edge Functions using the
-- privileged (service_role) client, per the locked architecture.

-- Enforces at the database level what the comment above only described in prose: once a
-- households row exists, primary_user_id can never be changed to a different value by any
-- UPDATE, through any code path. Ordinary updates to other columns (e.g. updated_at) remain
-- fully permitted — only a change to primary_user_id itself is rejected. This closes the gap
-- between that documented invariant and the household_members Primary-protection triggers below:
-- without this, an UPDATE to households.primary_user_id could silently desynchronize from the
-- protected active Primary membership row. SECURITY INVOKER (the default) is correct here for
-- the same reason as every other household_members integrity trigger: it only ever fires as part
-- of a write already being performed by the privileged/service_role client, which already has
-- full table privileges — no elevation is needed, and none is granted (see the EXECUTE
-- privilege-lockdown section). Household transfer remains explicitly out of scope — this trigger
-- does not implement any mechanism for changing the Primary, it only prevents it.
create or replace function public.prevent_household_primary_user_id_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if NEW.primary_user_id is distinct from OLD.primary_user_id then
    raise exception 'households.primary_user_id cannot be changed once set. Household transfer is not supported.';
  end if;
  return NEW;
end;
$$;

create trigger households_protect_primary_user_id
  before update on public.households
  for each row execute function public.prevent_household_primary_user_id_change();

-- ============================================================================================
-- 2. household_members
-- ============================================================================================

create table if not exists public.household_members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  user_id uuid not null references auth.users (id),
  role text not null check (role in ('primary', 'secondary')),
  status text not null check (status in ('active', 'removed')),
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  unique (household_id, user_id)
);

comment on table public.household_members is
  'Membership rows for a household. Secondary removal is a status update
   (status = ''removed''), never a physical DELETE, per the locked design — see
   prevent_primary_demotion_or_removal/prevent_primary_membership_delete below for why the
   Primary role''s row is additionally protected against both paths entirely.';

-- Exactly one ACTIVE Primary membership per household.
create unique index if not exists household_members_one_active_primary_idx
  on public.household_members (household_id)
  where role = 'primary' and status = 'active';

-- Exactly one ACTIVE household membership per user, across ALL households — a user already
-- active as a Secondary (or Primary) elsewhere cannot simultaneously be active in a second
-- household. This is also what makes create_household's atomicity guarantee work: inserting a
-- second active membership for an already-active user violates this index and rolls back the
-- whole create_household transaction, including the just-inserted households row.
create unique index if not exists household_members_one_active_membership_per_user_idx
  on public.household_members (user_id)
  where status = 'active';

alter table public.household_members enable row level security;
-- Default-deny — no anon/authenticated policy. See households' comment above.

-- --------------------------------------------------------------------------------------------
-- Primary membership integrity triggers
-- --------------------------------------------------------------------------------------------

-- Blocks any UPDATE that would demote the Primary's role or change its status away from
-- 'active'. SECURITY INVOKER (the default) is correct here: this trigger only ever fires as
-- part of a write to household_members already being performed by the privileged/service_role
-- client, which already has full table privileges — no elevation is needed, and none is granted.
create or replace function public.prevent_primary_demotion_or_removal()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if OLD.role = 'primary' and (NEW.role <> 'primary' or NEW.status <> 'active') then
    raise exception 'The Primary household membership cannot be demoted or removed.';
  end if;
  return NEW;
end;
$$;

create trigger household_members_protect_primary_update
  before update on public.household_members
  for each row execute function public.prevent_primary_demotion_or_removal();

-- Blocks any INSERT or UPDATE that would leave a role='primary' row whose user_id does not
-- match this household's own households.primary_user_id — prevents a different user from ever
-- becoming (or being silently reassigned as) Primary for this household.
create or replace function public.enforce_primary_matches_household()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if NEW.role = 'primary' then
    if NEW.user_id <> (select primary_user_id from public.households where id = NEW.household_id) then
      raise exception 'A primary household_members row must match households.primary_user_id.';
    end if;
  end if;
  return NEW;
end;
$$;

create trigger household_members_enforce_primary_identity
  before insert or update on public.household_members
  for each row execute function public.enforce_primary_matches_household();

-- Blocks a DIRECT (standalone) DELETE of the Primary's membership row, while still allowing the
-- row to be removed as part of an intentional ON DELETE CASCADE triggered by deleting the whole
-- household. Distinguishing technique (verified against documented PostgreSQL behavior, not
-- assumed): ON DELETE CASCADE is implemented as an AFTER ROW constraint trigger on the
-- REFERENCED table (households) that issues a genuine nested DELETE against household_members
-- via SPI once the parent row's own deletion has already been applied within the same
-- transaction. Because every SQL command within one transaction sees the cumulative effect of
-- every earlier command in that same transaction (Postgres's command-counter/MVCC semantics,
-- independent of isolation level), a SELECT against households from inside this BEFORE DELETE
-- trigger correctly finds the parent row already gone when the delete is cascade-caused, and
-- still present when it is a direct, standalone delete attempt.
--
-- REQUIRES EMPIRICAL VERIFICATION AGAINST AN ISOLATED SUPABASE STAGING/BRANCH DATABASE BEFORE
-- THIS MIGRATION IS DEPLOYED TO PRODUCTION — see this file's header comment.
create or replace function public.prevent_primary_membership_delete()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if OLD.role = 'primary' then
    if exists (select 1 from public.households where id = OLD.household_id) then
      raise exception 'The Primary household membership cannot be deleted directly. Delete the household itself to remove all membership rows.';
    end if;
    -- The parent household row is already gone within this transaction, so this DELETE is
    -- occurring as a legitimate ON DELETE CASCADE from households — allow it.
  end if;
  return OLD;
end;
$$;

create trigger household_members_protect_primary_delete
  before delete on public.household_members
  for each row execute function public.prevent_primary_membership_delete();

-- ============================================================================================
-- 3. household_invitations
-- ============================================================================================

create table if not exists public.household_invitations (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  invited_email_normalized text not null,
  invited_by_user_id uuid not null references auth.users (id),
  status text not null check (status in ('pending', 'accepted', 'revoked', 'expired')),
  expires_at timestamptz not null,
  accepted_by_user_id uuid references auth.users (id),
  supersedes_invitation_id uuid references public.household_invitations (id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  revoked_at timestamptz
);

comment on table public.household_invitations is
  'Email is trimmed/lowercased into invited_email_normalized before insert (application-layer
   responsibility — see the locked invitation lifecycle). Expiration is 7 days from created_at,
   evaluated lazily at read/acceptance time, not by a scheduled job. Resend never rewrites an
   existing row: the prior pending row becomes status = ''revoked'' and a NEW row is inserted with
   supersedes_invitation_id pointing back to it, preserving full history.';

comment on column public.household_invitations.supersedes_invitation_id is
  'Set only on a resend-created row, pointing at the invitation it replaced. Lets the full
   resend history for one (household_id, invited_email_normalized) pair be reconstructed by
   walking this chain backward.';

-- At most one currently-actionable PENDING invitation per (household_id, invited_email_normalized).
-- This is also what forces a resend to be atomic: the old row must be flipped away from 'pending'
-- before the new pending row can be inserted, or this index rejects the insert.
create unique index if not exists household_invitations_pending_unique
  on public.household_invitations (household_id, invited_email_normalized)
  where status = 'pending';

-- Supporting lookup index for the registration/login-time "does this email have a pending
-- invitation" check — not itself a uniqueness requirement, just a read-path index.
create index if not exists household_invitations_email_status_idx
  on public.household_invitations (invited_email_normalized, status);

alter table public.household_invitations enable row level security;
-- Default-deny — no anon/authenticated policy. Invitation creation/resend/acceptance are all
-- Edge-Function-mediated (accept-invitation is explicitly NOT implemented in this phase).

-- ============================================================================================
-- 4. sharing_permissions
-- ============================================================================================

create table if not exists public.sharing_permissions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  owner_user_id uuid not null references auth.users (id),
  category text not null check (category in ('connectedAccounts', 'manualAccounts', 'monthlyPlan')),
  item_id uuid,
  is_shared boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- monthlyPlan is a global-only category in the initial implementation — no per-item row is
  -- ever valid for it.
  check (category <> 'monthlyPlan' or item_id is null)
);

comment on table public.sharing_permissions is
  'item_id is NULL for a category''s global permission row, and non-null for a per-item override.
   The MEANING of item_id depends on category: for connectedAccounts it references
   public.plaid_accounts.id (never plaid_items.id — a single Plaid connection can hold multiple
   accounts, and sharing must be account-level, not connection-level); for manualAccounts it is
   the existing local SwiftData Account.id UUID, which cannot be enforced as a foreign key in this
   phase because Manual Accounts are not yet stored in Supabase (no cloud table exists for them
   yet); for monthlyPlan item_id is always NULL (enforced by the CHECK constraint above). No
   single FOREIGN KEY is declared on item_id, since its target table differs by category and one
   of those targets does not exist yet.';

-- Exactly one GLOBAL permission row per (household_id, owner_user_id, category).
create unique index if not exists sharing_permissions_global_unique
  on public.sharing_permissions (household_id, owner_user_id, category)
  where item_id is null;

-- Exactly one PER-ITEM override row per (household_id, owner_user_id, category, item_id).
create unique index if not exists sharing_permissions_item_unique
  on public.sharing_permissions (household_id, owner_user_id, category, item_id)
  where item_id is not null;

alter table public.sharing_permissions enable row level security;
-- Default-deny — no anon/authenticated policy. Reads/writes are Edge-Function-mediated.

-- ============================================================================================
-- 5. user_profiles
-- ============================================================================================

create table if not exists public.user_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  normalized_email text,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.user_profiles is
  'Non-sensitive display metadata only — no password, JWT, session token, or other authentication
   secret is ever stored here. Populated/kept in sync with auth.users by sync_user_profile
   (see below). Cross-user household-member display must be brokered through trusted Edge
   Functions, never through a broad authenticated-role RLS grant on this table.';

alter table public.user_profiles enable row level security;

-- Narrow, explicitly approved self-access only (per the locked design, user_profiles is the one
-- table in this migration where direct authenticated self-access is intended) — a user may read
-- and update only their own row. No policy grants any cross-user read here; household-member
-- profile display is a future Edge-Function-brokered concern, not implemented in this phase.
create policy user_profiles_select_own
  on public.user_profiles
  for select
  to authenticated
  using (user_id = auth.uid());

create policy user_profiles_update_own
  on public.user_profiles
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Explicit table/column-level privilege lockdown. RLS restricts WHICH ROWS the two policies
-- above make reachable — it does NOT by itself restrict WHICH COLUMNS an already-row-permitted
-- UPDATE may touch. A Supabase project's own default schema privileges grant SELECT/INSERT/
-- UPDATE/DELETE on newly created public-schema tables to anon/authenticated (this is Supabase's
-- own project-level ALTER DEFAULT PRIVILEGES setup, not anything any migration in this repository
-- has ever configured) — this repository's other tables (plaid_items/plaid_accounts, and every
-- other table in this migration) rely entirely on RLS's implicit per-command default-deny to
-- neutralize that default grant, which is correct there because NO partial access is intended for
-- any of them. user_profiles is different: authenticated is intended to retain narrow SELECT/
-- UPDATE access to their own row, but that UPDATE access must never extend to every column on
-- that row (normalized_email, user_id, created_at must stay out of reach) — RLS cannot express a
-- column-level distinction, so it is established here with explicit GRANT/REVOKE, matching the
-- same "never rely on assumed default privilege state" discipline already used for every
-- function's EXECUTE grant in this migration.
revoke all on public.user_profiles from anon;
-- No anon access of any kind is intended — anon has no SELECT/UPDATE policy above either, so
-- this is defense-in-depth alongside RLS's own implicit default-deny for that role.

revoke all on public.user_profiles from authenticated;
-- Reset to zero, then grant back only the exact narrow access intended below. INSERT, DELETE,
-- TRUNCATE, REFERENCES, and TRIGGER are all correctly left ungranted — authenticated has no
-- INSERT or DELETE policy above either (RLS's own implicit default-deny already blocks both
-- commands entirely), and TRUNCATE/REFERENCES/TRIGGER have no legitimate use for this role.

grant select on public.user_profiles to authenticated;
-- Row-scoped to "own row only" by the user_profiles_select_own policy above.

grant update (display_name) on public.user_profiles to authenticated;
-- Column-scoped: authenticated may update ONLY display_name, and only on their own row (per the
-- user_profiles_update_own policy above). normalized_email, user_id, created_at, and updated_at
-- all remain unreachable through this grant, regardless of which row RLS would otherwise permit —
-- an UPDATE statement naming any of those columns in its SET list is rejected by Postgres's own
-- column-privilege check before RLS is even consulted. normalized_email is intended to be derived
-- exclusively from auth.users.email via sync_user_profile()'s own SECURITY DEFINER execution,
-- which runs as that function's OWNER (never as `authenticated`) and is therefore entirely
-- unaffected by this REVOKE/GRANT — a table's owner privileges are never altered by GRANT/REVOKE
-- statements targeting other roles. updated_at continues to be maintained automatically by the
-- existing user_profiles_set_updated_at trigger regardless of what the client's own UPDATE
-- statement names in its SET list — a BEFORE UPDATE trigger setting NEW.updated_at does not
-- require the invoking role to hold separate column privilege on updated_at itself.

-- --------------------------------------------------------------------------------------------
-- auth.users -> user_profiles synchronization
-- --------------------------------------------------------------------------------------------

-- No pre-existing auth.users profile trigger was found anywhere in this repository's migrations
-- (confirmed by inspection before authoring this file) — this is a new addition, not a
-- replacement or duplicate of anything.
--
-- SECURITY DEFINER is required here, not merely recommended: this trigger fires on auth.users
-- DML performed by Supabase's own internal Auth service, under whatever role that service uses
-- internally — a role that cannot be assumed to already hold direct grants on
-- public.user_profiles. Runs as the function owner (the migration-deploying role), which — as
-- the owner of public.user_profiles — bypasses this table's own RLS policies for its own writes
-- (standard Postgres table-owner behavior; FORCE ROW LEVEL SECURITY is deliberately not enabled
-- on user_profiles), so the INSERT/UPDATE below succeeds regardless of the narrow self-only
-- policies declared above.
--
-- Never overwrites display_name: on INSERT it is left NULL (no approved metadata source for an
-- initial display name exists anywhere in this repository/database today — inventing a
-- derivation, e.g. from the email's local-part, was explicitly out of scope); on UPDATE this
-- function only ever touches normalized_email, never display_name.
create or replace function public.sync_user_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'INSERT' then
    insert into public.user_profiles (user_id, normalized_email)
    values (NEW.id, lower(trim(NEW.email)))
    on conflict (user_id) do nothing;
  elsif TG_OP = 'UPDATE' then
    update public.user_profiles
      set normalized_email = lower(trim(NEW.email)),
          updated_at = now()
      where user_id = NEW.id;
  end if;
  return NEW;
end;
$$;

create trigger auth_users_sync_profile_on_insert
  after insert on auth.users
  for each row execute function public.sync_user_profile();

create trigger auth_users_sync_profile_on_email_update
  after update of email on auth.users
  for each row execute function public.sync_user_profile();

-- ============================================================================================
-- 6. updated_at maintenance (new, minimal, Phase-2-scoped only)
-- ============================================================================================

-- No reusable updated_at-maintenance function exists anywhere in this repository's existing
-- migrations today (confirmed by inspection — every existing updated_at column, on plaid_items/
-- plaid_accounts, is maintained manually by application code in the Edge Functions, not by a
-- database trigger). This is a new, minimal helper scoped only to the three Phase 2 tables that
-- need it (households, sharing_permissions, user_profiles) — existing tables' updated_at
-- handling is left completely untouched.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  NEW.updated_at = now();
  return NEW;
end;
$$;

create trigger households_set_updated_at
  before update on public.households
  for each row execute function public.set_updated_at();

create trigger sharing_permissions_set_updated_at
  before update on public.sharing_permissions
  for each row execute function public.set_updated_at();

create trigger user_profiles_set_updated_at
  before update on public.user_profiles
  for each row execute function public.set_updated_at();

-- ============================================================================================
-- 7. create_household
-- ============================================================================================

-- Atomically creates a household and its Primary membership row in one transaction (both
-- succeed or neither does). p_user_id must ALWAYS be a server-verified identity supplied by the
-- calling Edge Function (requireAuthenticatedUserId()) — never a client-supplied value trusted
-- as-is. Not directly callable by the iOS client under any circumstance (see EXECUTE grants
-- below): the trust boundary is iOS -> create-household Edge Function -> requireAuthenticatedUserId()
-- -> verified UID -> this function, via the Edge Function's privileged (service_role) client.
--
-- "A user who already has an active household_members row cannot create another household" is
-- enforced by household_members_one_active_membership_per_user_idx (declared above) — if
-- p_user_id already has any active membership anywhere, the second insert below violates that
-- index and the whole function (including the just-inserted households row) rolls back.
create or replace function public.create_household(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
begin
  insert into public.households (primary_user_id)
  values (p_user_id)
  returning id into v_household_id;

  insert into public.household_members (household_id, user_id, role, status)
  values (v_household_id, p_user_id, 'primary', 'active');

  return v_household_id;
end;
$$;

-- ============================================================================================
-- 8. resend_invitation
-- ============================================================================================
--
-- Authorized contract (the open parameter-list decision flagged in the prior turn is now locked):
-- public.resend_invitation(p_invitation_id uuid, p_requesting_user_id uuid) returns uuid.
--
-- p_requesting_user_id must ALWAYS be a server-verified identity supplied by the calling Edge
-- Function (requireAuthenticatedUserId()) — never a client-supplied value trusted as-is. This
-- function performs its own independent authorization (Primary identity + active Primary
-- membership) as defense-in-depth; that does NOT relieve the future Edge Function of deriving
-- p_requesting_user_id from verified authentication. Never reads auth.uid() — same reasoning as
-- is_effectively_shared_for_user: a service_role database session has no end-user JWT attached to
-- it, so auth.uid() would be meaningless here.
--
-- p_invitation_id identifies the invitation whose HISTORY is being resent — it need not itself
-- be the currently-pending row (it may be an older, already-revoked/expired/accepted invitation
-- for the same household/email pair). The function always revokes and supersedes whichever row
-- is CURRENTLY pending for that same (household_id, invited_email_normalized) pair, never a stale
-- historical row merely because its id was supplied; if no row is currently pending, the new
-- invitation supersedes p_invitation_id directly. Historical (accepted/revoked/expired) invitation
-- data is never altered by this function beyond the one row it identifies as currently pending.
--
-- Atomicity/concurrency: both the target invitation and the current-pending lookup are read with
-- `for update`, taking a row lock that blocks a second concurrent resend attempt for the same
-- invitation/pair until the first call's transaction completes — combined with this being one
-- plpgsql function body (one implicit transaction, no exception is caught, so any failure at any
-- point rolls back everything already done in this call, including a revoke with no matching
-- insert), and household_invitations_pending_unique as the final backstop even in the unlikely
-- case two calls somehow still raced (only one INSERT could ever succeed; the other fails the
-- whole function with a unique-violation and rolls back cleanly, never leaving two pending rows).
create or replace function public.resend_invitation(
  p_invitation_id uuid,
  p_requesting_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target_household_id uuid;
  v_invited_email_normalized text;
  v_household_primary_user_id uuid;
  v_current_pending_id uuid;
  v_superseded_id uuid;
  v_new_invitation_id uuid;
begin
  -- Lock and read the target invitation. Must exist.
  select household_id, invited_email_normalized
    into v_target_household_id, v_invited_email_normalized
    from public.household_invitations
    where id = p_invitation_id
    for update;

  if not found then
    raise exception 'resend_invitation: invitation % does not exist.', p_invitation_id;
  end if;

  -- The household must exist (already guaranteed by the FK, checked explicitly anyway per the
  -- required authorization steps).
  select primary_user_id
    into v_household_primary_user_id
    from public.households
    where id = v_target_household_id;

  if not found then
    raise exception 'resend_invitation: household % does not exist.', v_target_household_id;
  end if;

  -- The requesting user must be this household's Primary...
  if p_requesting_user_id <> v_household_primary_user_id then
    raise exception 'resend_invitation: requesting user is not the Primary for this household.';
  end if;

  -- ...and must also hold the matching active Primary household_members row (defense-in-depth —
  -- both checks are required independently, per the locked authorization contract).
  if not exists (
    select 1 from public.household_members
    where household_id = v_target_household_id
      and user_id = p_requesting_user_id
      and role = 'primary'
      and status = 'active'
  ) then
    raise exception 'resend_invitation: requesting user does not have an active Primary membership for this household.';
  end if;

  -- Identify the CURRENT pending invitation for this household/email pair, locking it against a
  -- concurrent resend attempt. At most one such row can exist at any time
  -- (household_invitations_pending_unique).
  select id
    into v_current_pending_id
    from public.household_invitations
    where household_id = v_target_household_id
      and invited_email_normalized = v_invited_email_normalized
      and status = 'pending'
    for update;

  if found then
    -- The supplied p_invitation_id may or may not itself be this row — either way, the CURRENT
    -- pending row is the one that must be revoked and superseded, never a stale historical row.
    v_superseded_id := v_current_pending_id;

    update public.household_invitations
      set status = 'revoked',
          revoked_at = now()
      where id = v_current_pending_id;
  else
    -- No row is currently pending for this household/email pair — the new invitation supersedes
    -- the supplied target invitation directly.
    v_superseded_id := p_invitation_id;
  end if;

  -- Insert exactly one new pending invitation, always crediting the CURRENT verified Primary —
  -- never copied from any older row.
  insert into public.household_invitations (
    household_id,
    invited_email_normalized,
    invited_by_user_id,
    status,
    expires_at,
    accepted_by_user_id,
    supersedes_invitation_id,
    created_at,
    accepted_at,
    revoked_at
  )
  values (
    v_target_household_id,
    v_invited_email_normalized,
    p_requesting_user_id,
    'pending',
    now() + interval '7 days',
    null,
    v_superseded_id,
    now(),
    null,
    null
  )
  returning id into v_new_invitation_id;

  return v_new_invitation_id;
end;
$$;

-- ============================================================================================
-- 9. is_effectively_shared_for_user (canonical evaluator) and its RLS-facing wrapper
-- ============================================================================================

-- The single, canonical, authoritative sharing-permission evaluator. Never reads auth.uid() —
-- the recipient identity is always an explicit parameter, supplied only by a trusted caller that
-- has already verified it (a privileged Edge Function using requireAuthenticatedUserId(), never
-- a client-supplied value). This is deliberate: a service_role database session has no end-user
-- JWT attached to it, so auth.uid() would be meaningless/NULL if read from inside a
-- service_role-invoked function — reading it here would have been a real defect, not merely a
-- style choice.
--
-- Semantics (unchanged from the locked Phase 1C/1D design):
--   1. p_recipient_user_id must have ACTIVE membership in p_household_id, or the result is false
--      unconditionally, regardless of any permission row.
--   2. The GLOBAL permission row (item_id IS NULL) for (household_id, owner_user_id, category)
--      must exist and be is_shared = true, or the result is false. A missing global row and an
--      explicit is_shared = false both mean "not shared."
--   3. When the global row is true and p_item_id is non-null: a missing per-item row defaults to
--      shared (true); an explicit per-item false overrides to not-shared; an explicit per-item
--      true is redundantly confirmed shared.
--   4. For category = 'monthlyPlan', callers always pass p_item_id = NULL — the per-item lookup
--      then structurally matches nothing, so its "default to true" fallback always applies and
--      the global row alone determines the result. No special-cased branch is needed for this.
--   5. Owner access is NEVER decided by this function — every caller must check
--      owner_user_id = <caller's own verified identity> independently and FIRST, falling back to
--      this function only for a genuine non-owner recipient. This function has no way to know
--      "the caller is the owner" and does not attempt to.
create or replace function public.is_effectively_shared_for_user(
  p_household_id uuid,
  p_owner_user_id uuid,
  p_recipient_user_id uuid,
  p_category text,
  p_item_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with membership as (
    select 1 from public.household_members
    where household_id = p_household_id
      and status = 'active'
      and user_id = p_recipient_user_id
  ),
  global_perm as (
    select is_shared from public.sharing_permissions
    where household_id = p_household_id
      and owner_user_id = p_owner_user_id
      and category = p_category
      and item_id is null
  ),
  item_perm as (
    select is_shared from public.sharing_permissions
    where household_id = p_household_id
      and owner_user_id = p_owner_user_id
      and category = p_category
      and item_id = p_item_id
  )
  select
    exists (select 1 from membership)
    and coalesce((select is_shared from global_perm), false)
    and coalesce((select is_shared from item_perm), true);
$$;

-- RLS-facing wrapper for a genuine authenticated-session context (a future table read directly
-- through the Secondary's own Supabase client/session, not through an Edge Function) — the one
-- place auth.uid() is actually trustworthy, since RLS policy expressions are evaluated within
-- the real querying user's own request context. Contains NO independent permission logic of its
-- own; it does nothing but delegate to is_effectively_shared_for_user with
-- p_recipient_user_id = auth.uid(), so both the Edge Function path and any future RLS path can
-- never disagree. Safe to grant to `authenticated` specifically because it accepts no
-- caller-suppliable recipient parameter at all — auth.uid() cannot be spoofed by the calling
-- role. Not yet referenced by any RLS policy in this migration (no Phase 2 table needs it), but
-- defined now so a future phase never needs a fresh migration merely to add it.
create or replace function public.is_effectively_shared_for_current_user(
  p_household_id uuid,
  p_owner_user_id uuid,
  p_category text,
  p_item_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_effectively_shared_for_user(p_household_id, p_owner_user_id, auth.uid(), p_category, p_item_id);
$$;

-- ============================================================================================
-- 10. EXECUTE privilege lockdown
-- ============================================================================================
--
-- Postgres grants EXECUTE on a newly created function to PUBLIC by default unless explicitly
-- revoked, and a Supabase project's anon/authenticated roles inherit that PUBLIC-level
-- reachability via PostgREST RPC unless revoked — so every function above is explicitly reset to
-- zero access, then only the specific role(s) that genuinely need direct invocation are granted
-- back. service_role is NOT a PostgreSQL superuser — it holds only the narrower BYPASSRLS
-- attribute, which affects Row Level Security policy evaluation only and has no effect
-- whatsoever on ordinary EXECUTE privilege checks. Every REVOKE ... FROM service_role below is
-- therefore a real, enforced restriction, not a cosmetic no-op: a service_role call to a
-- function it has not been explicitly granted EXECUTE on will fail with "permission denied for
-- function", identical in kind to what anon/authenticated would receive.
--
-- Trigger functions (prevent_primary_demotion_or_removal, enforce_primary_matches_household,
-- prevent_primary_membership_delete, prevent_household_primary_user_id_change, sync_user_profile,
-- set_updated_at) receive NO runtime grant to any role at all — verified PostgreSQL
-- trigger-invocation behavior: EXECUTE privilege on a
-- trigger function is checked only once, at CREATE TRIGGER time, against the role creating the
-- trigger (here, the migration-deploying role, which owns every object it creates and therefore
-- already satisfies this check with no explicit grant needed); actually FIRING an existing
-- trigger never re-checks EXECUTE privilege for the role performing the triggering DML. Granting
-- any runtime role EXECUTE on these would serve no purpose and is correctly omitted.

revoke execute on function public.create_household(uuid) from public, anon, authenticated, service_role;
grant execute on function public.create_household(uuid) to service_role;

revoke execute on function public.resend_invitation(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.resend_invitation(uuid, uuid) to service_role;

revoke execute on function public.is_effectively_shared_for_user(uuid, uuid, uuid, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.is_effectively_shared_for_user(uuid, uuid, uuid, text, uuid) to service_role;

revoke execute on function public.is_effectively_shared_for_current_user(uuid, uuid, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.is_effectively_shared_for_current_user(uuid, uuid, text, uuid) to authenticated;

revoke execute on function public.sync_user_profile() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation (see comment block above).

revoke execute on function public.set_updated_at() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.

revoke execute on function public.prevent_primary_demotion_or_removal() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.

revoke execute on function public.enforce_primary_matches_household() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.

revoke execute on function public.prevent_primary_membership_delete() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.

revoke execute on function public.prevent_household_primary_user_id_change() from public, anon, authenticated, service_role;
-- No re-grant — reachable only via automatic trigger invocation.
