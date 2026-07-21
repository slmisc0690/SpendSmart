-- PHASE 7 — Account Related Options / Primary sharing controls: trusted server functions.
--
-- Adds the trusted, server-authorized operations the Primary-only "Account Related Options" UI
-- needs, layered entirely on top of migration 0008's already-deployed schema
-- (households/household_members/household_invitations/sharing_permissions/user_profiles). This
-- migration creates NO new tables and alters NO existing table — it only adds new
-- SECURITY DEFINER functions, each delegating trust decisions to the same primitives migration
-- 0008 already established (active-Primary-membership checks, the partial unique indexes, the
-- canonical is_effectively_shared_for_user evaluator). Authored as source only per this phase's
-- own instructions — NOT deployed in this task.
--
-- SCOPE:
--   1. create_invitation      — the missing "send the FIRST invitation" counterpart to 0008's
--                                resend_invitation (which only ever resends/supersedes an existing
--                                invitation row).
--   2. revoke_invitation      — revoke a currently-pending invitation without replacing it.
--   3. set_sharing_permission — the single trusted write path for both global (item_id IS NULL)
--                                and per-item sharing_permissions rows, for all three categories.
--   4. get_household_state    — one coherent read of the caller's own household/role/membership/
--                                pending-invitation/sharing-permission state, avoiding a function
--                                per read (per this phase's own "avoid excessive function sprawl"
--                                instruction).
--
-- ONE-SECONDARY LIMIT: per this phase's explicit scope ("Primary can invite ONE Secondary user by
-- email initially"), create_invitation additionally rejects a new invitation while the household
-- already has an active Secondary member OR any other currently-pending invitation — on top of
-- (not instead of) 0008's own per-(household,email) pending-uniqueness index.
--
-- ITEM OWNERSHIP VALIDATION: set_sharing_permission independently re-validates that a per-item
-- p_item_id actually belongs to the requesting Primary before writing any row — for
-- connectedAccounts against public.plaid_accounts (joined through plaid_items.user_id, since
-- plaid_accounts itself carries no owner column), for manualAccounts against
-- public.manual_accounts.owner_user_id. This is defense-in-depth: the calling Edge Function is
-- expected to perform the same check independently before ever calling this function (mirroring
-- the Phase 5B ownership-hijack lesson — see migration 0011's header), but the database-level
-- function must never rely solely on the caller having done so correctly.

-- ============================================================================================
-- 1. create_invitation
-- ============================================================================================
--
-- p_requesting_user_id must ALWAYS be a server-verified identity supplied by the calling Edge
-- Function (requireAuthenticatedUserId()) — never a client-supplied value trusted as-is. Mirrors
-- resend_invitation's own authorization contract (independent Primary-identity + active-Primary-
-- membership re-check) — this function performs the FIRST send for a household that has no
-- currently-pending invitation and no active Secondary yet, resend_invitation remains the only
-- path for replacing an existing pending invitation.
create or replace function public.create_invitation(
  p_household_id uuid,
  p_requesting_user_id uuid,
  p_invited_email_normalized text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_primary_user_id uuid;
  v_new_invitation_id uuid;
begin
  select primary_user_id
    into v_household_primary_user_id
    from public.households
    where id = p_household_id
    for update;

  if not found then
    raise exception 'create_invitation: household % does not exist.', p_household_id;
  end if;

  if p_requesting_user_id <> v_household_primary_user_id then
    raise exception 'create_invitation: requesting user is not the Primary for this household.';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = p_household_id
      and user_id = p_requesting_user_id
      and role = 'primary'
      and status = 'active'
  ) then
    raise exception 'create_invitation: requesting user does not have an active Primary membership for this household.';
  end if;

  if p_invited_email_normalized is null or length(trim(p_invited_email_normalized)) = 0 then
    raise exception 'create_invitation: invited_email_normalized is required.';
  end if;

  -- One-Secondary-initially limit: reject a new invitation if this household already has an
  -- active Secondary member, or ANY other currently-pending invitation (regardless of email) —
  -- the per-(household,email) pending-unique index alone would still allow two different pending
  -- invitations to two different emails, which this phase's scope does not intend.
  if exists (
    select 1 from public.household_members
    where household_id = p_household_id
      and role = 'secondary'
      and status = 'active'
  ) then
    raise exception 'create_invitation: this household already has an active Secondary member.';
  end if;

  if exists (
    select 1 from public.household_invitations
    where household_id = p_household_id
      and status = 'pending'
  ) then
    raise exception 'create_invitation: this household already has a pending invitation.';
  end if;

  insert into public.household_invitations (
    household_id,
    invited_email_normalized,
    invited_by_user_id,
    status,
    expires_at
  )
  values (
    p_household_id,
    lower(trim(p_invited_email_normalized)),
    p_requesting_user_id,
    'pending',
    now() + interval '7 days'
  )
  returning id into v_new_invitation_id;

  return v_new_invitation_id;
end;
$$;

-- ============================================================================================
-- 2. revoke_invitation
-- ============================================================================================
--
-- Revokes a currently-pending invitation without replacing it (unlike resend_invitation, which
-- always inserts a new pending row). No-op-safe: raises if the invitation is not currently
-- pending, rather than silently succeeding, so the Edge Function can surface a clear error.
create or replace function public.revoke_invitation(
  p_invitation_id uuid,
  p_requesting_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_status text;
  v_household_primary_user_id uuid;
begin
  select household_id, status
    into v_household_id, v_status
    from public.household_invitations
    where id = p_invitation_id
    for update;

  if not found then
    raise exception 'revoke_invitation: invitation % does not exist.', p_invitation_id;
  end if;

  select primary_user_id
    into v_household_primary_user_id
    from public.households
    where id = v_household_id;

  if p_requesting_user_id <> v_household_primary_user_id then
    raise exception 'revoke_invitation: requesting user is not the Primary for this household.';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = v_household_id
      and user_id = p_requesting_user_id
      and role = 'primary'
      and status = 'active'
  ) then
    raise exception 'revoke_invitation: requesting user does not have an active Primary membership for this household.';
  end if;

  if v_status <> 'pending' then
    raise exception 'revoke_invitation: invitation % is not currently pending.', p_invitation_id;
  end if;

  update public.household_invitations
    set status = 'revoked',
        revoked_at = now()
    where id = p_invitation_id;
end;
$$;

-- ============================================================================================
-- 3. set_sharing_permission
-- ============================================================================================
--
-- The single trusted write path for sharing_permissions — both global rows (p_item_id NULL) and
-- per-item override rows. owner_user_id is ALWAYS p_requesting_user_id itself: only the Primary
-- shares their OWN data in this design (a Secondary has no data-sharing controls of their own in
-- this phase), so there is no separate owner parameter to (mis)trust.
--
-- Upserts on the same partial-unique-index conflict targets migration 0008 already declared
-- (sharing_permissions_global_unique for item_id IS NULL, sharing_permissions_item_unique for
-- item_id IS NOT NULL) — never a raw INSERT, so calling this twice for the same
-- (household,owner,category,item) updates the same row instead of violating those indexes.
create or replace function public.set_sharing_permission(
  p_household_id uuid,
  p_requesting_user_id uuid,
  p_category text,
  p_item_id uuid,
  p_is_shared boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_primary_user_id uuid;
  v_result_id uuid;
begin
  select primary_user_id
    into v_household_primary_user_id
    from public.households
    where id = p_household_id;

  if not found then
    raise exception 'set_sharing_permission: household % does not exist.', p_household_id;
  end if;

  if p_requesting_user_id <> v_household_primary_user_id then
    raise exception 'set_sharing_permission: requesting user is not the Primary for this household.';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = p_household_id
      and user_id = p_requesting_user_id
      and role = 'primary'
      and status = 'active'
  ) then
    raise exception 'set_sharing_permission: requesting user does not have an active Primary membership for this household.';
  end if;

  if p_category not in ('connectedAccounts', 'manualAccounts', 'monthlyPlan') then
    raise exception 'set_sharing_permission: invalid category %.', p_category;
  end if;

  if p_category = 'monthlyPlan' and p_item_id is not null then
    raise exception 'set_sharing_permission: monthlyPlan is a global-only category; item_id must be null.';
  end if;

  -- Per-item ownership re-validation (defense-in-depth — the calling Edge Function is expected
  -- to have already checked this independently).
  if p_item_id is not null then
    if p_category = 'connectedAccounts' then
      if not exists (
        select 1
        from public.plaid_accounts pa
        join public.plaid_items pi on pi.id = pa.plaid_item_id
        where pa.id = p_item_id
          and pi.user_id = p_requesting_user_id
      ) then
        raise exception 'set_sharing_permission: item % is not a Connected Account owned by the requesting user.', p_item_id;
      end if;
    elsif p_category = 'manualAccounts' then
      if not exists (
        select 1
        from public.manual_accounts ma
        where ma.id = p_item_id
          and ma.owner_user_id = p_requesting_user_id
      ) then
        raise exception 'set_sharing_permission: item % is not a Manual Account owned by the requesting user.', p_item_id;
      end if;
    end if;
  end if;

  if p_item_id is null then
    insert into public.sharing_permissions (household_id, owner_user_id, category, item_id, is_shared)
    values (p_household_id, p_requesting_user_id, p_category, null, p_is_shared)
    on conflict (household_id, owner_user_id, category) where item_id is null
    do update set is_shared = excluded.is_shared, updated_at = now()
    returning id into v_result_id;
  else
    insert into public.sharing_permissions (household_id, owner_user_id, category, item_id, is_shared)
    values (p_household_id, p_requesting_user_id, p_category, p_item_id, p_is_shared)
    on conflict (household_id, owner_user_id, category, item_id) where item_id is not null
    do update set is_shared = excluded.is_shared, updated_at = now()
    returning id into v_result_id;
  end if;

  return v_result_id;
end;
$$;

-- ============================================================================================
-- 4. get_household_state
-- ============================================================================================
--
-- One coherent, role-aware read of the caller's own household state — never accepts a
-- caller-suppliable "whose household" parameter; p_requesting_user_id (server-verified) is always
-- both the identity being looked up AND the identity being authorized, so there is no
-- cross-household disclosure surface here at all. Returns a single jsonb object:
--
--   { "household_id": uuid|null, "role": text|null, "status": text|null }
--
-- when the caller has no active membership (household_id is null), or, additionally, when the
-- caller IS the active Primary of a household:
--
--   { ..., "secondary_member": {...}|null, "pending_invitation": {...}|null,
--     "sharing_permissions": [ {category, item_id, is_shared}, ... ] }
--
-- A Secondary caller intentionally receives ONLY household_id/role/status — no sharing_permissions
-- or invitation detail — since Account Related Options / sharing controls are Primary-only by this
-- phase's own locked requirement; a Secondary has no legitimate use for that detail yet (shared-
-- data browsing is a future phase with its own read path).
create or replace function public.get_household_state(
  p_requesting_user_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_role text;
  v_status text;
  v_result jsonb;
begin
  select household_id, role, status
    into v_household_id, v_role, v_status
    from public.household_members
    where user_id = p_requesting_user_id
      and status = 'active'
    limit 1;

  if not found then
    return jsonb_build_object('household_id', null, 'role', null, 'status', null);
  end if;

  v_result := jsonb_build_object('household_id', v_household_id, 'role', v_role, 'status', v_status);

  if v_role <> 'primary' then
    return v_result;
  end if;

  v_result := v_result || jsonb_build_object(
    'secondary_member',
    (
      select jsonb_build_object(
        'user_id', hm.user_id,
        'email', up.normalized_email,
        'status', hm.status,
        'joined_at', hm.joined_at
      )
      from public.household_members hm
      left join public.user_profiles up on up.user_id = hm.user_id
      where hm.household_id = v_household_id
        and hm.role = 'secondary'
        and hm.status = 'active'
      limit 1
    ),
    'pending_invitation',
    (
      select jsonb_build_object(
        'id', hi.id,
        'invited_email', hi.invited_email_normalized,
        'status', hi.status,
        'expires_at', hi.expires_at,
        'created_at', hi.created_at
      )
      from public.household_invitations hi
      where hi.household_id = v_household_id
        and hi.status = 'pending'
      order by hi.created_at desc
      limit 1
    ),
    'sharing_permissions',
    (
      select coalesce(jsonb_agg(jsonb_build_object(
        'category', sp.category,
        'item_id', sp.item_id,
        'is_shared', sp.is_shared
      )), '[]'::jsonb)
      from public.sharing_permissions sp
      where sp.household_id = v_household_id
        and sp.owner_user_id = p_requesting_user_id
    )
  );

  return v_result;
end;
$$;

-- ============================================================================================
-- 5. EXECUTE privilege lockdown
-- ============================================================================================
--
-- Same discipline as migration 0008: every function above is explicitly reset to zero access,
-- then granted back only to service_role, which is the only role any Edge Function in this
-- repository ever authenticates to Postgres as.

revoke execute on function public.create_invitation(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.create_invitation(uuid, uuid, text) to service_role;

revoke execute on function public.revoke_invitation(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.revoke_invitation(uuid, uuid) to service_role;

revoke execute on function public.set_sharing_permission(uuid, uuid, text, uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.set_sharing_permission(uuid, uuid, text, uuid, boolean) to service_role;

revoke execute on function public.get_household_state(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_household_state(uuid) to service_role;
