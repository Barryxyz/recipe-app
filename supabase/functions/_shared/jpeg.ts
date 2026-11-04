// Minimal JPEG inspection for scan uploads: dimensions and whether metadata is present.
// Photos must arrive already resized (≤ 1568 px) and stripped of EXIF by the app (F1.1).

export interface JpegInfo {
  bytes: number;
  width: number;
  height: number;
  /** APP1 "Exif" segment present (camera data, possibly GPS). */
  hasExif: boolean;
  /** Any APP1 (EXIF or XMP) or APP13 (IPTC) metadata segment present. */
  hasMetadata: boolean;
}

export function inspectJpeg(data: Uint8Array): JpegInfo | null {
  if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8) return null; // no SOI
  let i = 2;
  let width = 0, height = 0, hasExif = false, hasMetadata = false;
  while (i + 4 <= data.length) {
    if (data[i] !== 0xff) return null;
    const marker = data[i + 1];
    if (marker === 0xd9 || marker === 0xda) break; // EOI or start of scan: headers done
    const len = (data[i + 2] << 8) | data[i + 3];
    if (len < 2 || i + 2 + len > data.length) return null;
    if (marker === 0xe1) {
      hasMetadata = true;
      const id = String.fromCharCode(...data.subarray(i + 4, i + 8));
      if (id === "Exif") hasExif = true;
    }
    if (marker === 0xed) hasMetadata = true;
    // SOF0..SOF15 except DHT (c4), JPG (c8), DAC (cc)
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      height = (data[i + 5] << 8) | data[i + 6];
      width = (data[i + 7] << 8) | data[i + 8];
    }
    i += 2 + len;
  }
  if (!width || !height) return null;
  return { bytes: data.length, width, height, hasExif, hasMetadata };
}

export function decodeBase64(b64: string): Uint8Array | null {
  try {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}
