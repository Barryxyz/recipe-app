// F0.6: App Store Server Notifications V2 (renewals, expiry, grace period, refunds,
// revocation). Apple calls this URL directly, so there's no user JWT: the signed payload is
// the proof, checked with Apple's library. Keeps access right without the app being opened.
// Responds 200 once a notification is verified (even if it changes nothing), so Apple stops
// retrying; 400 for anything that doesn't verify.
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { accessFrom, claimedEnvironment, store, SubscriptionError, verifierFor } from "../_shared/subscriptions.ts";

const log = (o: Record<string, unknown>) => console.log(JSON.stringify({ fn: "appstore-notifications", ...o }));

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Use POST.", { status: 405 });
  let signedPayload: string;
  try {
    signedPayload = (await req.json()).signedPayload;
    if (typeof signedPayload !== "string") throw new Error();
  } catch {
    return new Response("Send { signedPayload }.", { status: 400 });
  }

  try {
    const envName = claimedEnvironment(signedPayload, (p) => (p.data as Record<string, unknown>)?.environment);
    const verifier = verifierFor(envName);
    const n = await verifier.verifyAndDecodeNotification(signedPayload);
    const type = n.notificationType;
    const signedTx = n.data?.signedTransactionInfo;
    if (!signedTx) {
      log({ stage: "ignored", type });                 // e.g. TEST
      return new Response("ok");
    }
    const tx = await verifier.verifyAndDecodeTransaction(signedTx);
    const renewal = n.data?.signedRenewalInfo ? await verifier.verifyAndDecodeRenewalInfo(n.data.signedRenewalInfo) : null;

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false },
    });
    // The account: appAccountToken is the user id (set at purchase); else the stored original transaction.
    let userId = tx.appAccountToken?.toLowerCase();
    if (!userId && tx.originalTransactionId) {
      const { data } = await admin.schema("app").from("users").select("id")
        .eq("original_transaction_id", tx.originalTransactionId).maybeSingle();
      userId = data?.id;
    }
    if (!userId) {
      log({ stage: "no_account", type });
      return new Response("ok");
    }
    // The notification's own date decides which data is newest.
    const access = accessFrom({ ...tx, appAccountToken: userId, signedDate: n.signedDate ?? tx.signedDate }, userId,
      renewal?.gracePeriodExpiresDate);
    await store(admin, userId, access);
    log({ stage: "applied", type, subtype: n.subtype, expires: access.expiresAt.toISOString() });
    return new Response("ok");
  } catch (e) {
    const reason = e instanceof SubscriptionError ? e.reason : (e as Error)?.message ?? String(e);
    log({ stage: "rejected", reason });
    return new Response("Not verified.", { status: 400 });
  }
});
