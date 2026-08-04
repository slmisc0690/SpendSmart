// Supabase Edge Function: accept-household-invitation
//
// PHASE 8 — SECONDARY INVITATION ACCEPTANCE FLOW. Authored as backend foundation work; NOT
// deployed in this task.
//
// The single mutation this phase introduces. Trust boundary: iOS -> this function ->
// requireAuthenticatedUserId() -> server-verified caller UID -> that caller's own
// user_profiles.normalized_email (never a client-supplied email) -> migration 0014's
// accept_household_invitation, via this function's own privileged (service_role) client.
//
// Request body — exactly ONE of:
//   { token: string }          — the original manual-link flow (Phase 8), unchanged.
//   { invitation_id: string }  — PHASE 8D: accepts a SELF-DISCOVERED invitation (from
//                                 get-my-pending-household-invitation) by id instead of token. See
//                                 migration 0015's own header for why this is an equally-secure,
//                                 differently-shaped acceptance path, not a weakening of the
//                                 original one — the invitation id here was already scoped to the
//                                 caller's own verified email by that discovery call, and this
//                                 function independently re-verifies that match again regardless.
// No household_id, no user_id/email field of any kind in either shape — every other fact this
// function needs is derived either from the verified session (caller identity/email) or from the
// matched invitation row itself (household_id). A client cannot supply, and therefore cannot
// spoof, any of those.
//
// ANTI-ENUMERATION: every rejection reason (unknown token, wrong email, expired, revoked,
// accepted, household invalid, household already has a Secondary, caller already has another
// membership) is collapsed to the SAME generic error message/status here — the raw exception text
// from accept_household_invitation (which does differ per reason, for the database's own
// debuggability) is deliberately never passed through to the client. This matches
// preview_household_invitation's own uniform `found: false` design (see migration 0014's header)
// and this project's established anti-enumeration convention.
//
// TOKEN NEVER LOGGED: logSafeError/logPlaidOperation are only ever given structural outcome
// strings here, never the request body or the token itself.

import {
  createPrivilegedClient,
  isValidUuid,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";
import { hashAcceptanceToken, isValidAcceptanceToken } from "../_shared/household.ts";

const GENERIC_INVITATION_ERROR = "This invitation is invalid or no longer available.";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[accept-household-invitation] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("accept-household-invitation auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const { token, invitation_id } = body;
  const usingInvitationId = invitation_id !== undefined && invitation_id !== null;

  if (usingInvitationId) {
    if (!isValidUuid(invitation_id)) {
      return jsonResponse({ error: GENERIC_INVITATION_ERROR }, 400);
    }
  } else if (!isValidAcceptanceToken(token)) {
    return jsonResponse({ error: GENERIC_INVITATION_ERROR }, 400);
  }

  try {
    const { data: profile, error: profileError } = await supabase
      .from("user_profiles")
      .select("normalized_email")
      .eq("user_id", userId)
      .maybeSingle();
    if (profileError) throw profileError;
    const normalizedEmail = (profile?.normalized_email as string | null) ?? null;
    if (!normalizedEmail) {
      // Every auth.users row gets a user_profiles row via migration 0008's own INSERT trigger —
      // a missing/null email here means something is structurally wrong, not a normal rejection.
      throw new Error("caller has no resolvable verified email");
    }

    // PHASE 8D — self-discovered invitations are accepted by id (migration 0015's
    // accept_household_invitation_by_id); the original manual-link flow still accepts by token
    // hash (migration 0014's accept_household_invitation, completely unmodified). See this file's
    // own header for why both are equally secure, differently-shaped paths.
    const { data, error } = usingInvitationId
      ? await supabase.rpc("accept_household_invitation_by_id", {
          p_invitation_id: invitation_id,
          p_requesting_user_id: userId,
          p_requesting_user_email_normalized: normalizedEmail,
        })
      : await supabase.rpc("accept_household_invitation", {
          p_acceptance_token_hash: await hashAcceptanceToken(token),
          p_requesting_user_id: userId,
          p_requesting_user_email_normalized: normalizedEmail,
        });
    if (error) throw error;

    logPlaidOperation({ operation: "accept-household-invitation", outcome: "accepted" });
    const result = data as Record<string, unknown>;
    return jsonResponse({
      household_id: result.household_id,
      role: result.role,
      status: result.status,
    });
  } catch (error) {
    logSafeError("accept-household-invitation failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: GENERIC_INVITATION_ERROR }, 400);
  }
});
