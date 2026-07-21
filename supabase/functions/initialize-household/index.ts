// Supabase Edge Function: initialize-household
//
// PHASE 7 — ACCOUNT RELATED OPTIONS / PRIMARY SHARING CONTROLS. Authored as backend foundation
// work; NOT deployed in this task (see this phase's own scope).
//
// The only way an authenticated user becomes a household Primary: creates a household via
// migration 0008's create_household(p_user_id), using the server-verified caller identity from
// requireAuthenticatedUserId — never a client-supplied uid. Idempotent by design: if the caller
// already has an active household membership (Primary OR Secondary), this returns that existing
// household's state instead of attempting a second create_household call (which would fail
// anyway, since household_members_one_active_membership_per_user_idx allows only one active
// membership per user across all households — see migration 0008).
//
// Request body: {} (no fields — the caller's own identity is the only input, and it comes
// entirely from the verified access token, never the body).

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

  console.log("[initialize-household] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("initialize-household auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    const { data: existingState, error: existingStateError } = await supabase.rpc("get_household_state", {
      p_requesting_user_id: userId,
    });
    if (existingStateError) throw existingStateError;

    const existing = existingState as Record<string, unknown> | null;
    if (existing?.household_id) {
      // Already an active member somewhere — do not attempt to create a second household.
      logPlaidOperation({ operation: "initialize-household", outcome: "already_member" });
      return jsonResponse({ household_id: existing.household_id, role: existing.role, status: existing.status });
    }

    const { data: newHouseholdId, error: createError } = await supabase.rpc("create_household", {
      p_user_id: userId,
    });
    if (createError) throw createError;

    logPlaidOperation({ operation: "initialize-household", outcome: "created" });
    return jsonResponse({ household_id: newHouseholdId, role: "primary", status: "active" });
  } catch (error) {
    logSafeError("initialize-household failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to initialize household" }, 500);
  }
});
