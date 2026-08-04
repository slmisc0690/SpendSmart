// Supabase Edge Function: decline-household-invitation
//
// PHASE 8D FOLLOW-UP — SELF-DISCOVERED INVITATION DECLINE. Authored as backend foundation work;
// NOT deployed in this task.
//
// Counterpart to accept-household-invitation's own `{ invitation_id }` shape — declines a
// self-discovered invitation (from get-my-pending-household-invitation) rather than accepting it.
// Trust boundary is identical: iOS -> this function -> requireAuthenticatedUserId() ->
// server-verified caller UID -> that caller's own user_profiles.normalized_email (never a
// client-supplied email) -> migration 0015's decline_household_invitation_by_id, via this
// function's own privileged (service_role) client.
//
// Request body: { invitation_id: string } — no token, no household_id, no user_id/email field of
// any kind. Every other fact this function needs is derived either from the verified session
// (caller identity/email) or from the matched invitation row itself — a client cannot supply, and
// therefore cannot spoof, any of those.
//
// ANTI-ENUMERATION: every rejection reason (unknown id, wrong email, not pending) is collapsed to
// the SAME generic error message/status here — the raw exception text from
// decline_household_invitation_by_id (which does differ per reason, for the database's own
// debuggability) is deliberately never passed through to the client, matching
// accept-household-invitation's own established convention.
//
// NO TOKEN INVOLVED: this path only ever operates on an invitation id the caller already learned
// about via their own authenticated get-my-pending-household-invitation call — there is nothing
// token-shaped here to avoid logging in the first place.

import {
  createPrivilegedClient,
  isValidUuid,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";

const GENERIC_INVITATION_ERROR = "This invitation is invalid or no longer available.";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[decline-household-invitation] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("decline-household-invitation auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const { invitation_id } = body;
  if (!isValidUuid(invitation_id)) {
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

    const { data, error } = await supabase.rpc("decline_household_invitation_by_id", {
      p_invitation_id: invitation_id,
      p_requesting_user_email_normalized: normalizedEmail,
    });
    if (error) throw error;

    logPlaidOperation({ operation: "decline-household-invitation", outcome: "declined" });
    const result = data as Record<string, unknown>;
    return jsonResponse({
      invitation_id: result.invitation_id,
      status: result.status,
    });
  } catch (error) {
    logSafeError("decline-household-invitation failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: GENERIC_INVITATION_ERROR }, 400);
  }
});
