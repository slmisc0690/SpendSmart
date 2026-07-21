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
// Request body: { token: string } — ONLY the raw acceptance token. No household_id, no
// user_id/email field of any kind — every other fact this function needs is derived either from
// the verified session (caller identity/email) or from the token-matched invitation row itself
// (household_id). A client cannot supply, and therefore cannot spoof, any of those.
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
  const { token } = body;
  if (!isValidAcceptanceToken(token)) {
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

    const tokenHash = await hashAcceptanceToken(token);

    const { data, error } = await supabase.rpc("accept_household_invitation", {
      p_acceptance_token_hash: tokenHash,
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
