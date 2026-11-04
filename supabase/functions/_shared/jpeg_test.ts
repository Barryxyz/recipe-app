// deno test supabase/functions/_shared/jpeg_test.ts
import { decodeBase64, inspectJpeg } from "./jpeg.ts";

function assertEquals(a: unknown, b: unknown, msg = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

/** A header-only JPEG: SOI, optional segments, SOF0 (w×h), SOS. */
function jpeg(w: number, h: number, segments: number[][] = []): Uint8Array {
  const sof = [0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1];
  const sos = [0xff, 0xda, 0x00, 0x0c, 0x03, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3f, 0];
  return new Uint8Array([0xff, 0xd8, ...segments.flat(), ...sof, ...sos, 0x12, 0x34, 0xff, 0xd9]);
}
const exif = [0xff, 0xe1, 0x00, 0x0a, ..."Exif".split("").map((c) => c.charCodeAt(0)), 0, 0, 0, 0];
const xmp = [0xff, 0xe1, 0x00, 0x06, 0x68, 0x74, 0x74, 0x70];
const jfif = [0xff, 0xe0, 0x00, 0x07, 0x4a, 0x46, 0x49, 0x46, 0x00];

Deno.test("reads dimensions from a clean JPEG", () => {
  const info = inspectJpeg(jpeg(1568, 1176, [jfif]));
  assertEquals([info?.width, info?.height, info?.hasExif, info?.hasMetadata], [1568, 1176, false, false]);
});

Deno.test("flags EXIF and other metadata", () => {
  assertEquals(inspectJpeg(jpeg(800, 600, [exif]))?.hasExif, true);
  const x = inspectJpeg(jpeg(800, 600, [xmp]));
  assertEquals([x?.hasExif, x?.hasMetadata], [false, true]);
});

Deno.test("rejects things that aren't JPEGs", () => {
  assertEquals(inspectJpeg(new TextEncoder().encode("PNG not jpeg")), null);
  assertEquals(inspectJpeg(new Uint8Array([0xff, 0xd8, 0xff])), null, "truncated");
  assertEquals(inspectJpeg(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xff])), null, "segment longer than file");
});

Deno.test("base64 round trip and bad input", () => {
  assertEquals(Array.from(decodeBase64(btoa("\xff\xd8")) ?? []), [0xff, 0xd8]);
  assertEquals(decodeBase64("%%%not base64%%%"), null);
});
