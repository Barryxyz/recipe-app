// F0.6: subscription rules, and Apple's library decoding a StoreKit-testing (Xcode) transaction.
import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { accessFrom, claimedEnvironment, SubscriptionError, type Tx, verifierFor } from "./subscriptions.ts";

const USER = "6f1c2e7a-1111-4222-8333-944455556666";
const NOW = Date.UTC(2026, 10, 13);
const tx = (over: Partial<Tx> = {}): Tx => ({
  productId: "com.barryxyz.fridge.yearly", type: "Auto-Renewable Subscription", appAccountToken: USER.toUpperCase(),
  originalTransactionId: "2000000123", expiresDate: NOW + 365 * 86400e3, signedDate: NOW, environment: "Sandbox",
  bundleId: "com.barryxyz.fridge", ...over,
});

Deno.test("a valid yearly or monthly subscription grants access until it expires", () => {
  const a = accessFrom(tx(), USER);
  assertEquals(a.product, "com.barryxyz.fridge.yearly");
  assertEquals(a.expiresAt.getTime(), NOW + 365 * 86400e3);
  assertEquals(a.environment, "Sandbox");
  assertEquals(accessFrom(tx({ productId: "com.barryxyz.fridge.monthly" }), USER).product, "com.barryxyz.fridge.monthly");
});

Deno.test("another account's transaction, unknown products and non-subscriptions are refused", () => {
  assertThrows(() => accessFrom(tx({ appAccountToken: "00000000-0000-4000-8000-000000000000" }), USER), SubscriptionError,
    "another account");
  assertThrows(() => accessFrom(tx({ appAccountToken: undefined }), USER), SubscriptionError, "another account");
  assertThrows(() => accessFrom(tx({ productId: "com.other.app.yearly" }), USER), SubscriptionError, "unknown product");
  assertThrows(() => accessFrom(tx({ type: "Consumable" }), USER), SubscriptionError, "not a subscription");
});

Deno.test("refunds end access at the revocation date; the grace period extends it", () => {
  assertEquals(accessFrom(tx({ revocationDate: NOW + 1000 }), USER).expiresAt.getTime(), NOW + 1000);
  const grace = NOW + 400 * 86400e3;
  assertEquals(accessFrom(tx(), USER, grace).expiresAt.getTime(), grace);
});

function b64url(o: unknown) {
  return btoa(JSON.stringify(o)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const jws = (payload: Record<string, unknown>) => `${b64url({ alg: "ES256", x5c: [] })}.${b64url(payload)}.c2ln`;

Deno.test("the claimed environment picks the verifier; Xcode only when allowed; Production needs the app id", () => {
  assertEquals(claimedEnvironment(jws({ environment: "Sandbox" })), "Sandbox");
  assertThrows(() => claimedEnvironment("garbage"), SubscriptionError);
  assertThrows(() => claimedEnvironment(jws({ environment: "Elsewhere" })), SubscriptionError);
  Deno.env.delete("ALLOW_XCODE");
  assertThrows(() => verifierFor("Xcode"), SubscriptionError, "Xcode transactions not allowed");
  Deno.env.delete("APP_APPLE_ID");
  assertThrows(() => verifierFor("Production"), SubscriptionError, "APP_APPLE_ID");
});

Deno.test("Apple's library decodes an Xcode transaction (runs on Deno) and checks bundle and environment", async () => {
  Deno.env.set("ALLOW_XCODE", "true");
  const payload = { ...tx({ environment: "Xcode" }), transactionId: "1", purchaseDate: NOW, inAppOwnershipType: "PURCHASED" };
  const decoded = await verifierFor("Xcode").verifyAndDecodeTransaction(jws(payload));
  assertEquals(accessFrom(decoded, USER).environment, "Xcode");
  await assertRejects(() => verifierFor("Xcode").verifyAndDecodeTransaction(jws({ ...payload, bundleId: "com.evil" })));
  // A Sandbox claim goes through the real signature check, which a fake signature fails.
  await assertRejects(() => verifierFor("Sandbox").verifyAndDecodeTransaction(jws({ ...payload, environment: "Sandbox" })));
  Deno.env.delete("ALLOW_XCODE");
});
