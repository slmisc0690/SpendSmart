// Supabase Edge Function: get-my-pending-household-invitation
//
// PHASE 8D — AUTOMATIC PENDING INVITATION DISCOVERY. Authored as backend foundation work; NOT
// deployed in this task.
//
// Solves the discovery gap the manual invitation_url/token flow (Phase 8) left: a Secondary who
// simply signs into SpendSmart never learns they have a pending invitation unless they separately
// receive and open the link. This endpoint lets an already-authenticated session ask "do I have a
// pending invitation?" using ONLY its own verified identity — no token, no email, no invitation id
// is ever accepted from the client.
//
// Request body: {} — no fields whatsoever. The caller's own verified UID (via
// requireAuthenticatedUserId) and their own user_profiles.normalized_email are the only inputs to
// migration 0015's find_pending_invitation_for_email, exactly mirroring
// accept-household-invitation's own email-derivation. Because no client-suppliable parameter
// narrows the lookup at all, a caller can only ever discover an invitation addressed to their own
// identity — there is no enumeration surface to close here (unlike
// get-household-invitation-preview, which does still need one, since it accepts an
// attacker-suppliable token).
//
// Response mirrors get-household-invitation-preview's own safe shape, plus `invitation_id` (safe
// to return here specifically because it is already scoped to the caller's own verified email —
// see migration 0015's own header for the full reasoning) — never a token or token hash.

import {
  createPrivilegedClient,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[get-my-pending-household-invitation] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-my-pending-household-invitation auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
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
      throw new Error("caller has no resolvable verified email");
    }

    const { data, error } = await supabase.rpc("find_pending_invitation_for_email", {
      p_requesting_user_email_normalized: normalizedEmail,
    });
    if (error) throw error;

    const result = (data as Record<string, unknown>) ?? { found: false };
    logPlaidOperation({ operation: "get-my-pending-household-invitation", outcome: result.found ? "found" : "none" });

    if (!result.found) {
      return jsonResponse({ found: false });
    }

    return jsonResponse({
      found: true,
      invitation_id: result.invitation_id,
      status: result.status,
      is_expired: result.is_expired,
      expires_at: result.expires_at,
      primary_display_name: result.primary_display_name,
      invited_email: result.invited_email,
    });
  } catch (error) {
    logSafeError("get-my-pending-household-invitation failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to check for pending invitations" }, 500);
  }
});
