-- PHASE 8 — Secondary invitation acceptance flow: acceptance token storage + trusted server
-- functions. Adds ONE new nullable column to the already-deployed household_invitations table
-- (migration 0008) and three new SECURITY DEFINER functions — no other schema object from any
-- prior migration is touched. Authored as source only per this phase's own instructions — NOT
-- deployed in this task.
--
-- TOKEN DESIGN: household_invitations has no acceptance token today — its own primary key `id`
-- is a random UUID (gen_random_uuid()), but reusing a row's own primary key as a public,
-- link-embeddable capability token would conflate "row identifier" with "bearer secret" (the id
-- can appear in ordinary joins/logs/admin queries elsewhere without that ever being a leak of a
-- capability). Instead: a dedicated 256-bit random token is generated CLIENT-SIDE OF THE
-- DATABASE (in the Edge Function, using Deno's Web Crypto `crypto.getRandomValues`) and only its
-- SHA-256 hash is ever stored here, in the new `acceptance_token_hash` column — mirroring
-- password-hashing practice (the raw token is a high-entropy random secret, not low-entropy user
-- input, so a fast general-purpose hash is appropriate; this is not a password-hashing use case
-- needing bcrypt/argon2's deliberate slowness). The raw token is returned to the Primary exactly
-- once (in `manage-household-invitation`'s own response) and is never persisted in plaintext
-- anywhere, never logged (see each Edge Function's own header for the no-logging discipline).
--
-- SCOPE:
--   1. household_invitations.acceptance_token_hash — new nullable column + a partial unique
--      index (defense-in-depth against an accidental hash collision, which is astronomically
--      unlikely with a 256-bit random token, but free to enforce).
--   2. set_invitation_acceptance_token — called once, immediately after create_invitation/
--      resend_invitation (both already exist, migration 0008/0013 — neither is modified by this
--      migration), to attach a freshly-generated token hash to the newly-pending row. A separate,
--      narrow function rather than changing create_invitation/resend_invitation's own signatures
--      — avoids touching either already-deployed function (this migration creates NO overloads of
--      them and leaves both files/definitions completely alone).
--   3. accept_household_invitation — the sole mutation: verifies token/email/expiry/status/
--      household validity, then atomically inserts the Secondary's household_members row and
--      marks the invitation accepted.
--   4. preview_household_invitation — read-only, pre-acceptance preview; returns `found = false`
--      uniformly for "token does not exist" AND "token exists but caller's authenticated email
--      does not match" so an unrelated caller can never distinguish the two (anti-enumeration —
--      see this migration's own EXECUTE lockdown section and each function's own header).
--
-- TRUST BOUNDARY (identical shape to every prior phase): iOS -> Edge Function ->
-- requireAuthenticatedUserId() -> server-verified caller UID -> this migration's functions, via
-- the Edge Function's own privileged (service_role) client. p_requesting_user_id/
-- p_requesting_user_email_normalized are ALWAYS Edge-Function-supplied from verified identity —
-- the authenticated caller's own `auth.users`/`user_profiles` row — never trusted from the
-- request body. household_id is NEVER a parameter to accept_household_invitation/
-- preview_household_invitation at all — both derive it exclusively from the token-matched
-- invitation row, so a client cannot even attempt to target a household by id.

-- ============================================================================================
-- 1. household_invitations.acceptance_token_hash
-- ============================================================================================

alter table public.household_invitations
  add column if not exists acceptance_token_hash text;

comment on column public.household_invitations.acceptance_token_hash is
  'SHA-256 hex digest of a 256-bit random token generated in the Edge Function, never the raw
   token itself. NULL for any row created before this column existed (none, in practice — this
   migration ships alongside the acceptance feature itself) or if set_invitation_acceptance_token
   was never called for some reason; a NULL value can never match an incoming request (a real
   token''s hash is never NULL), so such a row is simply unacceptable, not a security hole.';

-- Defense-in-depth only — a 256-bit random value colliding is not a realistic risk, but this
-- costs nothing and also serves as the lookup index for accept_household_invitation/
-- preview_household_invitation's own WHERE clause.
create unique index if not exists household_invitations_acceptance_token_hash_unique
  on public.household_invitations (acceptance_token_hash)
  where acceptance_token_hash is not null;

-- ============================================================================================
-- 2. set_invitation_acceptance_token
-- ============================================================================================
--
-- Called immediately after create_invitation/resend_invitation (both existing, unmodified) return
-- a new pending invitation id. Re-verifies the requesting user is the household's active Primary
-- independently (defense-in-depth — the calling Edge Function has already gone through
-- create_invitation/resend_invitation's own identical check moments earlier in the same request,
-- but this function must never rely on that alone) and only ever touches a row that is currently
-- `status = 'pending'`.
create or replace function public.set_invitation_acceptance_token(
  p_invitation_id uuid,
  p_requesting_user_id uuid,
  p_acceptance_token_hash text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated_count integer;
begin
  if p_acceptance_token_hash is null or length(p_acceptance_token_hash) = 0 then
    raise exception 'set_invitation_acceptance_token: acceptance_token_hash is required.';
  end if;

  update public.household_invitations hi
  set acceptance_token_hash = p_acceptance_token_hash
  from public.households h
  where hi.id = p_invitation_id
    and hi.household_id = h.id
    and h.primary_user_id = p_requesting_user_id
    and hi.status = 'pending'
    and exists (
      select 1 from public.household_members hm
      where hm.household_id = h.id
        and hm.user_id = p_requesting_user_id
        and hm.role = 'primary'
        and hm.status = 'active'
    );

  get diagnostics v_updated_count = row_count;
  if v_updated_count = 0 then
    raise exception 'set_invitation_acceptance_token: invitation not found, not pending, or requester is not the active Primary.';
  end if;
end;
$$;

-- ============================================================================================
-- 3. accept_household_invitation
-- ============================================================================================
--
-- The sole mutation for Phase 8. `for update` row locks on both the invitation and household rows
-- make concurrent acceptance attempts for the SAME token safe: the second transaction blocks on
-- the invitation lock until the first commits, then re-reads a `status` that has already flipped
-- to 'accepted' and cleanly raises. Concurrent acceptance attempts for DIFFERENT tokens landing on
-- the same target user are additionally caught by household_members_one_active_membership_per_user_idx
-- (migration 0008) as a database-level backstop even if the explicit check below somehow raced —
-- one INSERT wins, the other violates that unique index and rolls back.
--
-- Never creates or alters a Primary membership row, never touches households.primary_user_id, and
-- never accepts a household_id parameter at all — every fact used here is derived exclusively from
-- the token-matched invitation row itself.
create or replace function public.accept_household_invitation(
  p_acceptance_token_hash text,
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
  if p_acceptance_token_hash is null or length(p_acceptance_token_hash) = 0 then
    raise exception 'accept_household_invitation: token is required.';
  end if;

  select *
    into v_invitation
    from public.household_invitations
    where acceptance_token_hash = p_acceptance_token_hash
    for update;

  if not found then
    raise exception 'accept_household_invitation: invitation not found.';
  end if;

  if v_invitation.status <> 'pending' then
    raise exception 'accept_household_invitation: invitation is not pending.';
  end if;

  if v_invitation.expires_at <= now() then
    raise exception 'accept_household_invitation: invitation has expired.';
  end if;

  if v_invitation.invited_email_normalized <> p_requesting_user_email_normalized then
    raise exception 'accept_household_invitation: authenticated email does not match the invited email.';
  end if;

  v_household_id := v_invitation.household_id;

  -- Locks the household row too, so a concurrent Primary-removal/household-delete during
  -- acceptance (Phase 13's own race scenario) is serialized against this transaction rather than
  -- racing it.
  perform 1 from public.households where id = v_household_id for update;
  if not found then
    raise exception 'accept_household_invitation: household no longer exists.';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = v_household_id
      and role = 'primary'
      and status = 'active'
  ) then
    raise exception 'accept_household_invitation: household has no active Primary.';
  end if;

  if exists (
    select 1 from public.household_members
    where household_id = v_household_id
      and role = 'secondary'
      and status = 'active'
  ) then
    raise exception 'accept_household_invitation: household already has an active Secondary.';
  end if;

  if exists (
    select 1 from public.household_members
    where user_id = p_requesting_user_id
      and status = 'active'
  ) then
    raise exception 'accept_household_invitation: requesting user already has an active household membership.';
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

-- ============================================================================================
-- 4. preview_household_invitation
-- ============================================================================================
--
-- Read-only. Returns `{"found": false}` uniformly for BOTH "no invitation has this token" AND
-- "an invitation has this token but it is not addressed to the caller's own verified email" — an
-- unrelated caller (including one who has merely guessed or intercepted a token not meant for
-- them) can never distinguish those two cases, closing the enumeration surface Phase 13 calls out.
-- Only once the email match succeeds does this reveal status/expiry/the household Primary's own
-- (optional, never-auto-populated) display_name — never any sharing_permissions, Plaid data,
-- Manual Account data, or Monthly Plan data, all of which remain out of scope for this phase.
create or replace function public.preview_household_invitation(
  p_acceptance_token_hash text,
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
  if p_acceptance_token_hash is null or length(p_acceptance_token_hash) = 0 then
    return jsonb_build_object('found', false);
  end if;

  select *
    into v_invitation
    from public.household_invitations
    where acceptance_token_hash = p_acceptance_token_hash;

  if not found or v_invitation.invited_email_normalized <> p_requesting_user_email_normalized then
    return jsonb_build_object('found', false);
  end if;

  select up.display_name
    into v_primary_display_name
    from public.households h
    join public.user_profiles up on up.user_id = h.primary_user_id
    where h.id = v_invitation.household_id;

  return jsonb_build_object(
    'found', true,
    'status', v_invitation.status,
    'is_expired', v_invitation.expires_at <= now(),
    'expires_at', v_invitation.expires_at,
    'primary_display_name', v_primary_display_name,
    'invited_email', v_invitation.invited_email_normalized
  );
end;
$$;

-- ============================================================================================
-- 5. EXECUTE privilege lockdown
-- ============================================================================================

revoke execute on function public.set_invitation_acceptance_token(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.set_invitation_acceptance_token(uuid, uuid, text) to service_role;

revoke execute on function public.accept_household_invitation(text, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.accept_household_invitation(text, uuid, text) to service_role;

revoke execute on function public.preview_household_invitation(text, text) from public, anon, authenticated, service_role;
grant execute on function public.preview_household_invitation(text, text) to service_role;
