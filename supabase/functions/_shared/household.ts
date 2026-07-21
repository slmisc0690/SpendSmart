// Shared pure-function helpers for PHASE 7 — Account Related Options / Primary sharing controls.
// Mirrors this project's existing _shared/monthlyPlan.ts convention: pure, dependency-free
// functions here so they can be unit-tested with `deno test` without a live database or network.
// All trust/authorization decisions still live in the SQL functions (migration 0013) and are
// never duplicated here — this file only validates request-body SHAPE before those functions are
// ever called.

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Trims and lowercases an email exactly like migration 0008's sync_user_profile()/
 * resend_invitation() do (`lower(trim(NEW.email))`) — kept in sync deliberately so the value an
 * Edge Function sends to create_invitation always matches what the database itself would derive. */
export function normalizeEmail(value: string): string {
  return value.trim().toLowerCase();
}

/** Deliberately simple format guard (not a full RFC 5322 validator) — same bar as this project's
 * other lightweight input guards (isValidUuid, isValidBareDate in _shared/manual.ts). Rejects
 * empty/whitespace-only and anything missing an "@" and a "." in the domain part. */
export function isValidEmail(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > 320) return false;
  return EMAIL_PATTERN.test(trimmed);
}

export type SharingCategory = "connectedAccounts" | "manualAccounts" | "monthlyPlan";

const VALID_CATEGORIES: readonly SharingCategory[] = ["connectedAccounts", "manualAccounts", "monthlyPlan"];

export function isValidSharingCategory(value: unknown): value is SharingCategory {
  return typeof value === "string" && (VALID_CATEGORIES as readonly string[]).includes(value);
}

/** monthlyPlan is global-only — enforced independently here (before ever reaching the database
 * CHECK constraint / set_sharing_permission's own re-validation) so a malformed request gets a
 * clean 400 instead of a raw Postgres error surfaced to the client. */
export function isValidSharingPermissionRequest(
  category: unknown,
  itemId: unknown,
): { valid: true; category: SharingCategory; itemId: string | null } | { valid: false; reason: string } {
  if (!isValidSharingCategory(category)) {
    return { valid: false, reason: "category must be one of connectedAccounts, manualAccounts, monthlyPlan" };
  }
  if (itemId === null || itemId === undefined) {
    return { valid: true, category, itemId: null };
  }
  if (typeof itemId !== "string") {
    return { valid: false, reason: "item_id must be a string UUID or null" };
  }
  if (category === "monthlyPlan") {
    return { valid: false, reason: "monthlyPlan is a global-only category; item_id must be null" };
  }
  return { valid: true, category, itemId };
}

export type InvitationAction = "invite" | "resend" | "revoke";

const VALID_INVITATION_ACTIONS: readonly InvitationAction[] = ["invite", "resend", "revoke"];

export function isValidInvitationAction(value: unknown): value is InvitationAction {
  return typeof value === "string" && (VALID_INVITATION_ACTIONS as readonly string[]).includes(value);
}

// ================================================================================================
// PHASE 8 — invitation acceptance token generation/hashing.
//
// The RAW token is a 256-bit value from Deno's Web Crypto `crypto.getRandomValues` (a CSPRNG,
// not Math.random) — high entropy, unguessable, and generated entirely OUTSIDE the database so
// the plaintext value never needs to touch (or be logged by) Postgres at all. Only its SHA-256
// hex digest is ever stored (migration 0014's `acceptance_token_hash` column) or sent to the
// accept_household_invitation/preview_household_invitation SQL functions — the raw token itself
// is returned to the Primary exactly once (manage-household-invitation's own response) and must
// never appear in a log line anywhere in this codebase (see every Edge Function's own
// no-token-logging discipline).
// ================================================================================================

const ACCEPTANCE_TOKEN_BYTE_LENGTH = 32; // 256 bits

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Hex(value: string): Promise<string> {
  const data = new TextEncoder().encode(value);
  const digestBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digestBuffer))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/** Generates a fresh raw acceptance token and its SHA-256 hash in one call — the hash is what
 * gets persisted (via set_invitation_acceptance_token), the raw token is what gets embedded in
 * the invitation link and returned to the Primary. */
export async function generateAcceptanceToken(): Promise<{ token: string; tokenHash: string }> {
  const randomBytes = new Uint8Array(ACCEPTANCE_TOKEN_BYTE_LENGTH);
  crypto.getRandomValues(randomBytes);
  const token = base64UrlEncode(randomBytes);
  const tokenHash = await sha256Hex(token);
  return { token, tokenHash };
}

/** Hashes a client-supplied raw token the exact same way, for comparison against the stored
 * `acceptance_token_hash` — used by accept-household-invitation/get-household-invitation-preview. */
export async function hashAcceptanceToken(token: string): Promise<string> {
  return sha256Hex(token);
}

/** Deliberately simple non-empty-string guard — the actual validity check (does a matching hash
 * exist, is it still pending/unexpired) always happens server-side in SQL, never here. */
export function isValidAcceptanceToken(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 512;
}

/** The scheme/host every invitation link uses — `spendsmart://household-invitation?token=...`.
 * Kept here (not just in the iOS app) so the Edge Function that builds the link and the app's own
 * deep-link matcher can never drift apart on the exact string. */
export const HOUSEHOLD_INVITATION_URL_SCHEME = "spendsmart";
export const HOUSEHOLD_INVITATION_URL_HOST = "household-invitation";

export function buildInvitationUrl(token: string): string {
  return `${HOUSEHOLD_INVITATION_URL_SCHEME}://${HOUSEHOLD_INVITATION_URL_HOST}?token=${encodeURIComponent(token)}`;
}
