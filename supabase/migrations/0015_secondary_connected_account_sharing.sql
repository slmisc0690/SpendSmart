-- PHASE 8D — (1) Secondary → Primary Connected Account sharing, (2) Secondary → Primary Manual
-- Account sharing (added in the same-day follow-up, before this migration was ever deployed —
-- see that function's own header below for why it lives here rather than a fresh migration file),
-- (3) authenticated pending-invitation discovery + accept-by-id, and (4) decline-by-id (PHASE 8D
-- FOLLOW-UP, same reasoning — added before this migration was ever deployed). Adds five new
-- SECURITY DEFINER functions (set_secondary_connected_account_sharing,
-- set_secondary_manual_account_sharing, find_pending_invitation_for_email,
-- accept_household_invitation_by_id, decline_household_invitation_by_id), plus ONE constraint
-- change (widening household_invitations.status, see that section's own header for why). No
-- table, column, index, or existing FUNCTION from any prior migration is touched — only the one
-- pre-existing CHECK constraint named above. Authored as source only per this phase's own
-- instructions — NOT deployed in this task.
--
-- ARCHITECTURE FINDING (this migration's own reason for existing — see Phase 8D's final report
-- §7 for the full write-up): the `sharing_permissions` TABLE and the canonical
-- `is_effectively_shared_for_user` evaluator (both migration 0008, untouched here) are already
-- directionless/role-agnostic — `owner_user_id` may structurally be ANY active household member,
-- and the evaluator only asks "does the RECIPIENT have active membership, and did the OWNER mark
-- this shared" without caring which of them is Primary or Secondary. NO schema change is needed to
-- represent a Secondary sharing their own Connected Account (or Manual Account) back to the
-- Primary — the SAME finding applies to both categories, for the identical reason.
--
-- What actually blocks it today is the API layer: `set_sharing_permission` (migration 0013)
-- hardcodes "the caller must BE the household's Primary" (`p_requesting_user_id =
-- households.primary_user_id`) and rejects every other caller outright — there has never been a
-- trusted write path for a Secondary to create their own sharing_permissions rows. This migration
-- adds exactly that, scoped narrowly to this phase's own locked requirement: connectedAccounts and
-- manualAccounts only, per-item only (a Secondary has no "global category" toggle of their own in
-- this phase, for either category), caller must be the household's ACTIVE Secondary, and the item
-- must be an account the caller themselves owns (never the Primary's, never another household's).
--
-- GLOBAL-ROW BOOTSTRAP: `is_effectively_shared_for_user`'s own AND-logic means a per-item override
-- is only ever honored when the owner's GLOBAL row for that category is ALSO `is_shared = true`
-- (a false or missing global row makes every item unshared regardless of per-item state — see
-- migration 0008's own header). A Secondary in this phase has no separate "Share Connected
-- Accounts" global toggle of their own (only the single per-account "Share Connected Account"
-- control this phase's UI exposes) — so this function transparently ensures that global row exists
-- and is `true` the first time a Secondary shares anything, exactly once, idempotently. It is
-- never set back to false by this function (there is no "unshare everything" concept here); a
-- Secondary "unsharing" one account simply flips that account's own per-item row to false, which
-- the evaluator already honors correctly on its own.
create or replace function public.set_secondary_connected_account_sharing(
  p_requesting_user_id uuid,
  p_item_id uuid,
  p_is_shared boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_result_id uuid;
begin
  if p_item_id is null then
    raise exception 'set_secondary_connected_account_sharing: item_id is required — a Secondary has no global sharing toggle in this phase.';
  end if;

  select household_id
    into v_household_id
    from public.household_members
    where user_id = p_requesting_user_id
      and role = 'secondary'
      and status = 'active';

  if not found then
    raise exception 'set_secondary_connected_account_sharing: requesting user does not have an active Secondary membership.';
  end if;

  -- Item ownership re-validation — identical discipline to set_sharing_permission's own
  -- connectedAccounts check (migration 0013): plaid_accounts carries no owner column directly,
  -- so ownership is proven only via its parent plaid_items.user_id.
  if not exists (
    select 1
    from public.plaid_accounts pa
    join public.plaid_items pi on pi.id = pa.plaid_item_id
    where pa.id = p_item_id
      and pi.user_id = p_requesting_user_id
  ) then
    raise exception 'set_secondary_connected_account_sharing: item % is not a Connected Account owned by the requesting user.', p_item_id;
  end if;

  -- Bootstrap the global row to true exactly once (idempotent no-op on every later call) — see
  -- this migration's own header for why this is required and safe.
  insert into public.sharing_permissions (household_id, owner_user_id, category, item_id, is_shared)
  values (v_household_id, p_requesting_user_id, 'connectedAccounts', null, true)
  on conflict (household_id, owner_user_id, category) where item_id is null
  do nothing;

  insert into public.sharing_permissions (household_id, owner_user_id, category, item_id, is_shared)
  values (v_household_id, p_requesting_user_id, 'connectedAccounts', p_item_id, p_is_shared)
  on conflict (household_id, owner_user_id, category, item_id) where item_id is not null
  do update set is_shared = excluded.is_shared, updated_at = now()
  returning id into v_result_id;

  return v_result_id;
end;
$$;

revoke execute on function public.set_secondary_connected_account_sharing(uuid, uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.set_secondary_connected_account_sharing(uuid, uuid, boolean) to service_role;

-- ============================================================================================
-- Secondary → Primary Manual Account sharing (same-day follow-up)
-- ============================================================================================
--
-- Exact structural mirror of set_secondary_connected_account_sharing above — same active-Secondary
-- check, same global-row bootstrap reasoning, same upsert-by-partial-unique-index pattern. The
-- ONLY difference is the ownership re-validation target: manual_accounts carries its own
-- owner_user_id column directly (no join required, unlike plaid_accounts, which has none and must
-- be proven via its parent plaid_items.user_id) — ownership here means
-- manual_accounts.owner_user_id = p_requesting_user_id, full stop. A Manual Account merely SHARED
-- with this Secondary (i.e. owned by the Primary, with a sharing_permissions row making it visible
-- to this Secondary in some future browsing UI) is never eligible — this function only ever checks
-- true ownership, never effective visibility, so there is no path by which an account the Secondary
-- doesn't own could be re-shared back to its actual owner or anyone else.
create or replace function public.set_secondary_manual_account_sharing(
  p_requesting_user_id uuid,
  p_item_id uuid,
  p_is_shared boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_result_id uuid;
begin
  if p_item_id is null then
    raise exception 'set_secondary_manual_account_sharing: item_id is required — a Secondary has no global sharing toggle in this phase.';
  end if;

  select household_id
    into v_household_id
    from public.household_members
    where user_id = p_requesting_user_id
      and role = 'secondary'
      and status = 'active';

  if not found then
    raise exception 'set_secondary_manual_account_sharing: requesting user does not have an active Secondary membership.';
  end if;

  -- Item ownership re-validation — manual_accounts.owner_user_id is authoritative and direct (no
  -- join needed, unlike connectedAccounts' plaid_accounts/plaid_items).
  if not exists (
    select 1
    from public.manual_accounts ma
    where ma.id = p_item_id
      and ma.owner_user_id = p_requesting_user_id
  ) then
    raise exception 'set_secondary_manual_account_sharing: item % is not a Manual Account owned by the requesting user.', p_item_id;
  end if;

  -- Bootstrap the global row to true exactly once (idempotent no-op on every later call) — see
  -- the connectedAccounts function's own header, immediately above, for the full reasoning.
  insert into public.sharing_permissions (household_id, owner_user_id, category, item_id, is_shared)
  values (v_household_id, p_requesting_user_id, 'manualAccounts', null, true)
  on conflict (household_id, owner_user_id, category) where item_id is null
  do nothing;

  insert into public.sharing_permissions (household_id, owner_user_id, category, item_id, is_shared)
  values (v_household_id, p_requesting_user_id, 'manualAccounts', p_item_id, p_is_shared)
  on conflict (household_id, owner_user_id, category, item_id) where item_id is not null
  do update set is_shared = excluded.is_shared, updated_at = now()
  returning id into v_result_id;

  return v_result_id;
end;
$$;

revoke execute on function public.set_secondary_manual_account_sharing(uuid, uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.set_secondary_manual_account_sharing(uuid, uuid, boolean) to service_role;

-- ============================================================================================
-- Authenticated pending-invitation discovery
-- ============================================================================================
--
-- PROBLEM: the manual invitation_url/token flow (migration 0014) requires the Primary to actually
-- share the link and the invitee to open it — a Secondary who simply signs into SpendSmart sees
-- nothing, because nothing about their own pending invitation is ever surfaced to them without
-- that link. This is a discovery gap, not a security gap: the invitation row has existed and been
-- addressed to their verified email the whole time.
--
-- WHY A TOKEN CANNOT BE "SIMPLY REGENERATED": household_invitations stores only
-- acceptance_token_hash (a SHA-256 digest) — by construction a hash cannot be inverted back to the
-- raw token that produced it (migration 0014's own header explains why only the hash is ever
-- persisted). There is no raw token anywhere on the server to hand back for automatic discovery.
--
-- CHOSEN DESIGN (Option A from this phase's own brief): authenticated-identity-based discovery and
-- acceptance, keyed by invitation id rather than a bearer token. This is not a weaker security
-- model than the token path — it is a DIFFERENT one, appropriate to a different situation:
--   - The token path exists for an out-of-band channel (an email/share-sheet link) that has no
--     prior relationship with the app's own session; the token itself is the only thing proving
--     "the holder of this link was meant to receive it."
--   - The discovery path only ever runs for an ALREADY-AUTHENTICATED session; the server has
--     already verified the caller's identity and (via user_profiles) their verified email before
--     find_pending_invitation_for_email is ever called with it — so authenticated-UID +
--     server-verified-email-match against the specific invitation row IS the authorization,
--     exactly as strong as what accept_household_invitation ultimately checks internally after a
--     valid token narrows it down to one row. No new trust is extended to the client either way.
-- The existing token/hash mechanism is completely unmodified and remains fully valid as an
-- alternate acceptance path (e.g. a Primary who wants to share the link directly still can).
create or replace function public.find_pending_invitation_for_email(
  p_requesting_user_email_normalized text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_invitation public.household_invitations%rowtype;
  v_primary_display_name text;
begin
  -- No client-suppliable parameter narrows this query beyond the server-derived email — a caller
  -- can only ever discover an invitation addressed to their OWN verified identity, so (unlike
  -- preview_household_invitation) there is no cross-caller enumeration surface here at all.
  select *
    into v_invitation
    from public.household_invitations
    where invited_email_normalized = p_requesting_user_email_normalized
      and status = 'pending'
      and expires_at > now()
    order by created_at desc
    limit 1;

  if not found then
    return jsonb_build_object('found', false);
  end if;

  select up.display_name
    into v_primary_display_name
    from public.households h
    join public.user_profiles up on up.user_id = h.primary_user_id
    where h.id = v_invitation.household_id;

  return jsonb_build_object(
    'found', true,
    'invitation_id', v_invitation.id,
    'status', v_invitation.status,
    'is_expired', v_invitation.expires_at <= now(),
    'expires_at', v_invitation.expires_at,
    'primary_display_name', v_primary_display_name,
    'invited_email', v_invitation.invited_email_normalized
  );
end;
$$;

-- Accept-by-id counterpart to migration 0014's accept_household_invitation — identical
-- validation/atomicity (see that function's own header for the full reasoning on row locking,
-- concurrent-acceptance safety, and why household_id/Primary/Secondary-conflict are re-checked
-- independently here rather than trusted from the caller), differing ONLY in how the target
-- invitation row is located: by primary key (already scoped to the caller's own verified email by
-- find_pending_invitation_for_email above having found it) rather than by token hash. Deliberately
-- a SEPARATE function rather than an overload/modification of accept_household_invitation itself —
-- migration 0014 is not touched by this migration, per this project's own "never edit an
-- already-shipped migration" discipline.
create or replace function public.accept_household_invitation_by_id(
  p_invitation_id uuid,
  p_requesting_user_id uuid,
  p_requesting_user_email_normalized text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invitation public.household_invitations%rowtype;
  v_household_id uuid;
begin
  select *
    into v_invitation
    from public.household_invitations
    where id = p_invitation_id
    for update;

  if not found then
    raise exception 'accept_household_invitation_by_id: invitation not found.';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'accept_household_invitation_by_id: invitation is not pending.';
  end if;

  if v_invitation.expires_at <= now() then
    raise exception 'accept_household_invitation_by_id: invitation has expired.';
  end if;

  if v_invitation.invited_email_normalized <> p_requesting_user_email_normalized then
    raise exception 'accept_household_invitation_by_id: authenticated email does not match the invited email.';
  end if;

  v_household_id := v_invitation.household_id;

  perform 1 from public.households where id = v_household_id for update;
  if not found then
    raise exception 'accept_household_invitation_by_id: household no longer exists.';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = v_household_id
      and role = 'primary'
      and status = 'active'
  ) then
    raise exception 'accept_household_invitation_by_id: household has no active Primary.';
  end if;

  if exists (
    select 1 from public.household_members
    where household_id = v_household_id
      and role = 'secondary'
      and status = 'active'
  ) then
    raise exception 'accept_household_invitation_by_id: household already has an active Secondary.';
  end if;

  if exists (
    select 1 from public.household_members
    where user_id = p_requesting_user_id
      and status = 'active'
  ) then
    raise exception 'accept_household_invitation_by_id: requesting user already has an active household membership.';
  end if;

  insert into public.household_members (household_id, user_id, role, status)
  values (v_household_id, p_requesting_user_id, 'secondary', 'active');

  update public.household_invitations
    set status = 'accepted',
        accepted_at = now(),
        accepted_by_user_id = p_requesting_user_id
    where id = v_invitation.id;

  return jsonb_build_object('household_id', v_household_id, 'role', 'secondary', 'status', 'active');
end;
$$;

revoke execute on function public.find_pending_invitation_for_email(text) from public, anon, authenticated, service_role;
grant execute on function public.find_pending_invitation_for_email(text) to service_role;

revoke execute on function public.accept_household_invitation_by_id(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.accept_household_invitation_by_id(uuid, uuid, text) to service_role;

-- ============================================================================================
-- Decline (PHASE 8D FOLLOW-UP — same-day addition, before this migration was ever deployed)
-- ============================================================================================
--
-- PROBLEM: migration 0008's original household_invitations.status check constraint only allows
-- 'pending', 'accepted', 'revoked', 'expired' — there is no distinct value for "the invited
-- recipient explicitly declined". Reusing 'revoked' would be incorrect: that value already means
-- something different and unrelated (the PRIMARY superseded/resent the invitation — see 0008's own
-- table comment on supersedes_invitation_id), so a Secondary's decline and a Primary's resend
-- would become indistinguishable to any other code reading status = 'revoked'. This section
-- widens the existing constraint by exactly one value: 'declined'.
--
-- 0008 itself is never edited, per this project's own "never edit an already-shipped migration"
-- discipline — this ALTERs the already-deployed table from a later migration instead. The
-- constraint's name is looked up dynamically (rather than assuming Postgres's default
-- "<table>_<column>_check" naming) so this is not silently ineffective if 0008 ever named it
-- explicitly.
do $$
declare
  v_constraint_name text;
begin
  select conname
    into v_constraint_name
    from pg_constraint
    where conrelid = 'public.household_invitations'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%status%pending%accepted%revoked%expired%';

  if v_constraint_name is not null then
    execute format('alter table public.household_invitations drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.household_invitations
  add constraint household_invitations_status_check
  check (status in ('pending', 'accepted', 'revoked', 'expired', 'declined'));

-- Decline counterpart to accept_household_invitation_by_id above — identical target-row lookup
-- (by primary key, already scoped to the caller's own verified email by
-- find_pending_invitation_for_email having found it) and identical email re-verification
-- discipline. The ONLY effect is marking the invitation row 'declined' — no household_members row
-- is ever created or touched, no household state changes, exactly mirroring the "Decline must use
-- the existing secure server-side decline path" / "the server must remain authoritative" locked
-- requirements this phase's own brief calls for. A row lock (`for update`) is taken for the same
-- concurrent-mutation-safety reason accept_household_invitation_by_id takes one.
create or replace function public.decline_household_invitation_by_id(
  p_invitation_id uuid,
  p_requesting_user_email_normalized text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invitation public.household_invitations%rowtype;
begin
  select *
    into v_invitation
    from public.household_invitations
    where id = p_invitation_id
    for update;

  if not found then
    raise exception 'decline_household_invitation_by_id: invitation not found.';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'decline_household_invitation_by_id: invitation is not pending.';
  end if;

  if v_invitation.invited_email_normalized <> p_requesting_user_email_normalized then
    raise exception 'decline_household_invitation_by_id: authenticated email does not match the invited email.';
  end if;

  update public.household_invitations
    set status = 'declined'
    where id = v_invitation.id;

  return jsonb_build_object('invitation_id', v_invitation.id, 'status', 'declined');
end;
$$;

revoke execute on function public.decline_household_invitation_by_id(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.decline_household_invitation_by_id(uuid, text) to service_role;
