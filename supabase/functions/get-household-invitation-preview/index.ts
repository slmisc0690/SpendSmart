// Supabase Edge Function: get-household-invitation-preview
//
// PHASE 8 — SECONDARY INVITATION ACCEPTANCE FLOW. Authored as backend foundation work; NOT
// deployed in this task.
//
// READ-ONLY. Lets the Secondary invitation screen show safe pre-acceptance information — status,
// expiry, and the Primary's own (optional) display name — before the user commits to Accept.
// Delegates entirely to migration 0014's preview_household_invitation, which returns
// `{"found": false}` uniformly for both "no invitation has this token" and "an invitation has
// this token but isn't addressed to the caller's own verified email" (see that function's own
// header) — this Edge Function adds no additional logic on top of that anti-enumeration design.
//
// Request body: { token: string } — same shape/trust boundary as accept-household-invitation
// (caller identity/email derived from the verified session, never the client).
//
// NEVER RETURNS: household internals, sharing_permissions, Plaid account data, Manual Account
// data, or Monthly Plan data — none of that is in scope for this phase, and
// preview_household_invitation's own return shape structurally cannot carry any of it.

import {
  createPrivilegedClient,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";
import { hashAcceptanceToken, isValidAcceptanceToken } from "../_shared/household.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[get-household-invitation-preview] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-household-invitation-preview auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const { token } = body;
  if (!isValidAcceptanceToken(token)) {
    return jsonResponse({ found: false });
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
      return jsonResponse({ found: false });
    }

    const tokenHash = await hashAcceptanceToken(token);

    const { data, error } = await supabase.rpc("preview_household_invitation", {
      p_acceptance_token_hash: tokenHash,
      p_requesting_user_email_normalized: normalizedEmail,
    });
    if (error) throw error;

    const result = data as Record<string, unknown>;
    logPlaidOperation({
      operation: "get-household-invitation-preview",
      outcome: result.found ? "found" : "not_found",
    });

    if (!result.found) {
      return jsonResponse({ found: false });
    }

    return jsonResponse({
      found: true,
      status: result.status,
      is_expired: result.is_expired,
      expires_at: result.expires_at,
      primary_display_name: result.primary_display_name,
      invited_email: result.invited_email,
    });
  } catch (error) {
    logSafeError("get-household-invitation-preview failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ found: false });
  }
});
