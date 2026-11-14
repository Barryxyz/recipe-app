// F0.6: checking Apple-signed subscription data and turning it into an account's access.
// Signature checks use Apple's App Store Server Library (no hand-rolled JWS checks).
import { Buffer } from "node:buffer";
import { Environment, SignedDataVerifier } from "npm:@apple/app-store-server-library@3.1.0";
import { APPLE_ROOT_CA, APPLE_ROOT_CA_G3 } from "./apple_roots.ts";

const env = (k: string) => Deno.env.get(k);

export const BUNDLE_ID = env("APPLE_BUNDLE_ID") ?? "com.barryxyz.fridge";
/** Both subscriptions are in one group; changing between them is handled by Apple. */
export function allowedProducts(): Set<string> {
  return new Set((env("APPLE_PRODUCT_IDS") ?? "com.barryxyz.fridge.monthly,com.barryxyz.fridge.yearly")
    .split(",").map((s) => s.trim()).filter(Boolean));
}

export type AppleEnvironment = "Production" | "Sandbox" | "Xcode";

export class SubscriptionError extends Error {
  constructor(readonly reason: string) {
    super(reason);
  }
}

/** The environment a JWS claims, read without trusting it: it only picks which verifier runs. */
export function claimedEnvironment(jws: string, path: (p: Record<string, unknown>) => unknown = (p) => p.environment):
  AppleEnvironment {
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(new TextDecoder().decode(base64url(jws.split(".")[1] ?? "")));
  } catch {
    throw new SubscriptionError("not a signed App Store value");
  }
  const e = path(payload);
  if (e === "Production" || e === "Sandbox" || e === "Xcode") return e;
  throw new SubscriptionError(`unknown environment ${String(e)}`);
}

function base64url(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

/**
 * A verifier for one environment. Production needs APP_APPLE_ID (from App Store Connect).
 * Sandbox is what TestFlight and App Review use, so it's always accepted. Xcode (StoreKit
 * testing, signed by a local key and not checked) only with ALLOW_XCODE=true.
 */
export function verifierFor(e: AppleEnvironment): SignedDataVerifier {
  const roots = [Buffer.from(APPLE_ROOT_CA_G3, "base64"), Buffer.from(APPLE_ROOT_CA, "base64")];
  switch (e) {
    case "Production": {
      const id = Number(env("APP_APPLE_ID"));
      if (!Number.isInteger(id) || id <= 0) throw new SubscriptionError("production not configured (APP_APPLE_ID)");
      return new SignedDataVerifier(roots, true, Environment.PRODUCTION, BUNDLE_ID, id);
    }
    case "Sandbox":
      return new SignedDataVerifier(roots, true, Environment.SANDBOX, BUNDLE_ID);
    case "Xcode":
      if (env("ALLOW_XCODE")?.toLowerCase() !== "true") throw new SubscriptionError("Xcode transactions not allowed");
      return new SignedDataVerifier(roots, false, Environment.XCODE, BUNDLE_ID);
  }
}

/** The fields we use from a decoded transaction (JWSTransactionDecodedPayload). */
export interface Tx {
  productId?: string;
  type?: string;
  appAccountToken?: string;
  originalTransactionId?: string;
  expiresDate?: number;
  revocationDate?: number;
  signedDate?: number;
  environment?: string;
  bundleId?: string;
}

export interface Access {
  product: string;
  expiresAt: Date;
  environment: AppleEnvironment;
  originalTransactionId: string;
  signedAt: Date;
}

/**
 * What a verified transaction grants this account, or why it grants nothing.
 * - the product must be one of ours, an auto-renewable subscription
 * - appAccountToken must be this user's id (set at purchase), so a transaction can't be
 *   replayed onto another account
 * - a refunded / revoked transaction ends access at its revocation date
 * `graceUntil` (renewal info) extends access during Apple's billing grace period.
 * `transferred`: the server already tied this subscription to this account (its first account
 * was deleted, see `claim`), so appAccountToken naming the old account is expected.
 */
export const ANOTHER_ACCOUNT = "transaction belongs to another account";

export function accessFrom(tx: Tx, userId: string, graceUntil?: number, { transferred = false } = {}): Access {
  if (!tx.productId || !allowedProducts().has(tx.productId)) throw new SubscriptionError(`unknown product ${tx.productId}`);
  if (tx.type !== "Auto-Renewable Subscription") throw new SubscriptionError(`not a subscription (${tx.type})`);
  if (!transferred && (!tx.appAccountToken || tx.appAccountToken.toLowerCase() !== userId.toLowerCase())) {
    throw new SubscriptionError(ANOTHER_ACCOUNT);
  }
  if (!tx.originalTransactionId || !tx.expiresDate) throw new SubscriptionError("transaction has no expiry");
  const end = tx.revocationDate ?? Math.max(tx.expiresDate, graceUntil ?? 0);
  return {
    product: tx.productId,
    expiresAt: new Date(end),
    environment: tx.environment as AppleEnvironment,
    originalTransactionId: tx.originalTransactionId,
    signedAt: new Date(tx.signedDate ?? Date.now()),
  };
}

/** The app.users columns for an Access. */
export function columns(a: Access) {
  return {
    subscription_product: a.product,
    subscription_expires_at: a.expiresAt.toISOString(),
    subscription_environment: a.environment,
    original_transaction_id: a.originalTransactionId,
    subscription_updated_at: a.signedAt.toISOString(),
  };
}

// ---------------------------------------------------------------- storing

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";

/**
 * Writes the access to the user's row unless newer Apple data is already stored (an old,
 * retried notification can't undo a newer one). Returns false if the transaction already
 * belongs to another account.
 */
export async function store(admin: SupabaseClient, userId: string, a: Access): Promise<boolean> {
  const { error } = await admin.schema("app").from("users")
    .update(columns(a))
    .eq("id", userId)
    .or(`subscription_updated_at.is.null,subscription_updated_at.lte.${a.signedAt.toISOString()}`);
  if (error?.code === "23505") return false;      // original_transaction_id is another user's
  if (error) throw error;
  return true;
}

export async function status(admin: SupabaseClient, userId: string) {
  const { data, error } = await admin.schema("app").from("users")
    .select("subscription_product, subscription_expires_at").eq("id", userId).maybeSingle();
  if (error) throw error;
  const expires = data?.subscription_expires_at ? new Date(data.subscription_expires_at) : null;
  return {
    active: expires != null && expires.getTime() > Date.now(),
    product: data?.subscription_product ?? null,
    expires_at: expires?.toISOString() ?? null,
  };
}

// ---------------------------------------------------------------- after Delete account

/**
 * Whether this account may use a subscription whose appAccountToken names another account:
 * "owned" when it was already moved here, "released" when its account was deleted
 * (app.released_subscriptions, written by app.delete_my_account), else null.
 */
export async function claim(admin: SupabaseClient, userId: string, originalTransactionId: string):
  Promise<"owned" | "released" | null> {
  const { data: owner, error } = await admin.schema("app").from("users").select("id")
    .eq("original_transaction_id", originalTransactionId).maybeSingle();
  if (error) throw error;
  if (owner) return owner.id === userId ? "owned" : null;
  const { data: released, error: e2 } = await admin.schema("app").from("released_subscriptions")
    .select("original_transaction_id").eq("original_transaction_id", originalTransactionId).maybeSingle();
  if (e2) throw e2;
  return released ? "released" : null;
}

/** Once claimed, the subscription belongs to the new account (the unique index guards races). */
export async function forgetReleased(admin: SupabaseClient, originalTransactionId: string) {
  const { error } = await admin.schema("app").from("released_subscriptions").delete()
    .eq("original_transaction_id", originalTransactionId);
  if (error) throw error;
}

/** The account that holds this subscription now, if any. */
export async function ownerOf(admin: SupabaseClient, originalTransactionId: string): Promise<string | undefined> {
  const { data } = await admin.schema("app").from("users").select("id")
    .eq("original_transaction_id", originalTransactionId).maybeSingle();
  return data?.id;
}
