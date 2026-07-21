// Supabase Edge Function: manage-household-invitation
//
// PHASE 7 — ACCOUNT RELATED OPTIONS / PRIMARY SHARING CONTROLS. Authored as backend foundation
// work; NOT deployed in this task.
//
// PHASE 8 UPDATE — invite/resend now also mint a fresh acceptance token (see
// _shared/household.ts's own header) via migration 0014's set_invitation_acceptance_token, and
// return `invitation_url` (the raw token embedded in a `spendsmart://household-invitation` deep
// link) so the Primary can share it with the Secondary through any channel they choose (Messages,
// Mail, AirDrop, ...) via the OS share sheet — this project has no transactional email-sending
// infrastructure today (no SMTP/email-provider secret exists in any environment; see this
// project's own Production secrets list), so automated email dispatch is explicitly deferred, not
// implemented here. The raw token is NEVER logged — only structural outcome (`invited`/`resent`)
// is ever passed to logPlaidOperation, exactly as before this change.
//
// One function covering all three Primary-invitation write operations (invite / resend / revoke)
// — per this phase's own "consolidate where safe" instruction, mirroring sync-manual-data's own
// precedent of one function covering multiple related write operations behind a single
// authenticated call. Each action delegates entirely to migration 0013's SQL functions
// (create_invitation / resend_invitation / revoke_invitation), which independently re-verify the
// caller is the household's active Primary — this function never trusts a client-supplied
// household_id/requesting-user identity for authorization, only for "which invitation" (resend/
// revoke) or "who to invite" (invite).
//
// Request body:
//   { action: "invite",  household_id: string, email: string }
//   { action: "resend",  invitation_id: string }
//   { action: "revoke",  invitation_id: string }
//
// ANTI-ENUMERATION: this endpoint is Primary-only by construction (every SQL function it calls
// re-verifies active Primary membership) — it never discloses whether an arbitrary email
// corresponds to an existing SpendSmart account; only the normalized email string is stored, and
// no lookup against auth.users/user_profiles by email is ever performed here.

import {
  createPrivilegedClient,
  isValidUuid,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";
import {
  buildInvitationUrl,
  generateAcceptanceToken,
  isValidEmail,
  isValidInvitationAction,
  normalizeEmail,
} from "../_shared/household.ts";

/** Generates a fresh acceptance token, persists only its hash (via migration 0014's
 * set_invitation_acceptance_token, which independently re-verifies the caller is this
 * household's active Primary), and returns the invitation URL containing the RAW token — the one
 * and only place the plaintext token is ever produced or returned. Never logs the token itself. */
async function attachAcceptanceToken(
  supabase: ReturnType<typeof createPrivilegedClient>,
  invitationId: string,
  requestingUserId: string,
): Promise<string> {
  const { token, tokenHash } = await generateAcceptanceToken();
  const { error } = await supabase.rpc("set_invitation_acceptance_token", {
    p_invitation_id: invitationId,
    p_requesting_user_id: requestingUserId,
    p_acceptance_token_hash: tokenHash,
  });
  if (error) throw error;
  return buildInvitationUrl(token);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[manage-household-invitation] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("manage-household-invitation auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const { action } = body;

  if (!isValidInvitationAction(action)) {
    return jsonResponse({ error: "action must be one of invite, resend, revoke" }, 400);
  }

  try {
    if (action === "invite") {
      const { household_id, email } = body;
      if (!isValidUuid(household_id)) {
        return jsonResponse({ error: "household_id (a valid UUID) is required" }, 400);
      }
      if (!isValidEmail(email)) {
        return jsonResponse({ error: "A valid email is required" }, 400);
      }
      const { data, error } = await supabase.rpc("create_invitation", {
        p_household_id: household_id,
        p_requesting_user_id: userId,
        p_invited_email_normalized: normalizeEmail(email),
      });
      if (error) throw error;
      const invitationUrl = await attachAcceptanceToken(supabase, data as string, userId);
      logPlaidOperation({ operation: "manage-household-invitation", outcome: "invited" });
      return jsonResponse({ invitation_id: data, invitation_url: invitationUrl });
    }

    if (action === "resend") {
      const { invitation_id } = body;
      if (!isValidUuid(invitation_id)) {
        return jsonResponse({ error: "invitation_id (a valid UUID) is required" }, 400);
      }
      const { data, error } = await supabase.rpc("resend_invitation", {
        p_invitation_id: invitation_id,
        p_requesting_user_id: userId,
      });
      if (error) throw error;
      const invitationUrl = await attachAcceptanceToken(supabase, data as string, userId);
      logPlaidOperation({ operation: "manage-household-invitation", outcome: "resent" });
      return jsonResponse({ invitation_id: data, invitation_url: invitationUrl });
    }

    // action === "revoke"
    const { invitation_id } = body;
    if (!isValidUuid(invitation_id)) {
      return jsonResponse({ error: "invitation_id (a valid UUID) is required" }, 400);
    }
    const { error } = await supabase.rpc("revoke_invitation", {
      p_invitation_id: invitation_id,
      p_requesting_user_id: userId,
    });
    if (error) throw error;
    logPlaidOperation({ operation: "manage-household-invitation", outcome: "revoked" });
    return jsonResponse({ revoked: true });
  } catch (error) {
    logSafeError("manage-household-invitation failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    // The SQL functions raise plain exceptions (not SafeError) for authorization/validation
    // failures (e.g. "not the Primary", "already has a pending invitation") — surfaced as a 400
    // rather than a generic 500, without echoing the raw Postgres error text back to the client.
    return jsonResponse({ error: "Request could not be completed" }, 400);
  }
});
