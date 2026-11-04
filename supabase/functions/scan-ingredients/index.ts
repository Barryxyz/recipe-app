// scan-ingredients. F1.1 PLACEHOLDER: checks the uploaded photos and reports what arrived.
// No AI call. F1.2 replaces the body with real detection (Sonnet 5.5 via _shared/ai.ts).
// Photos live only in memory for the length of the request and are never logged or stored.
import "@supabase/functions-js/edge-runtime.d.ts";
import { z } from "npm:zod@4.6.7";
import { aiEndpoint, HttpError } from "../_shared/http.ts";
import { decodeBase64, inspectJpeg } from "../_shared/jpeg.ts";

const MAX_EDGE = 1568;

const Body = z.object({
  location: z.enum(["fridge", "freezer", "pantry", "staples"]),
  images: z.array(z.string().min(1)).min(1).max(4),
});

export default {
  fetch: aiEndpoint("scan-ingredients", async ({ body }) => {
    const parsed = Body.safeParse(body);
    if (!parsed.success) throw new HttpError("bad_request", "Send a location and 1-4 photos.");

    const images = parsed.data.images.map((b64, index) => {
      const bytes = decodeBase64(b64);
      const info = bytes ? inspectJpeg(bytes) : null;
      if (!info) throw new HttpError("bad_request", `Photo ${index + 1} isn't a JPEG.`);
      return {
        index,
        bytes: info.bytes,
        width: info.width,
        height: info.height,
        has_exif: info.hasExif,
        has_metadata: info.hasMetadata,
        within_limits: Math.max(info.width, info.height) <= MAX_EDGE && !info.hasMetadata,
      };
    });

    return { placeholder: true, location: parsed.data.location, images, items: [] };
  }),
};
