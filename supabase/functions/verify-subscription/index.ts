// F0.6: the app sends an Apple-signed transaction (StoreKit 2 jwsRepresentation) after a
// purchase, a restore, or at launch while the server's record is missing or expired.
// Body: { signed_transaction }. Verified with Apple's library, then the account's
// subscription expiry is stored. Returns { active, product, expires_at }.
// Works without a subscription (it's how one is recorded); never calls a model.
import "@supabase/functions-js/edge-runtime.d.ts";
import { z } from "npm:zod@4.6.7";
import { endpoint, HttpError } from "../_shared/http.ts";
import { accessFrom, claimedEnvironment, status, store, SubscriptionError, verifierFor } from "../_shared/subscriptions.ts";

const Body = z.object({ signed_transaction: z.string().min(20).max(20_000) });

export default {
  fetch: endpoint("verify-subscription", async ({ userId, supabaseAdmin, body }) => {
    const parsed = Body.safeParse(body);
    if (!parsed.success) throw new HttpError("bad_request", "Send { signed_transaction }.");
    const jws = parsed.data.signed_transaction;
    try {
      const tx = await verifierFor(claimedEnvironment(jws)).verifyAndDecodeTransaction(jws);
      const access = accessFrom(tx, userId);
      if (!(await store(supabaseAdmin, userId, access))) {
        throw new HttpError("bad_request", "This subscription belongs to another account.");
      }
    } catch (e) {
      if (e instanceof HttpError) throw e;
      const reason = e instanceof SubscriptionError ? e.reason : `verification failed (${(e as Error)?.message ?? e})`;
      console.log(JSON.stringify({ fn: "verify-subscription", stage: "rejected", reason }));
      throw new HttpError("bad_request", "Couldn't verify this purchase.");
    }
    return await status(supabaseAdmin, userId);
  }, { ai: false }),
};
