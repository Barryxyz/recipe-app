// F1.2 accuracy evaluation: runs scan-ingredients over labeled photos and reports
// recall, precision, quantity error and latency.
//
//   ./scripts/eval-scan.sh            (signs in a throwaway user, runs this, cleans up)
//
// Env: SCAN_URL, SUPABASE_KEY, ACCESS_TOKEN. Photos are resized with macOS `sips` to
// ≤ 1568 px before upload (the app does the same on the phone). Costs real money:
// about $0.03-0.06 per scan with 4 photos.

interface Label { name: string; quantity?: number; unit?: string }
interface Scan { id: string; location: string; tidy?: boolean; photos: string[]; items: Label[] }
interface Draft { name: string; display_name: string; quantity: number | null; unit: string | null; low_confidence: boolean }

const here = new URL(".", import.meta.url).pathname;
const labels: { scans: Scan[] } = JSON.parse(await Deno.readTextFile(`${here}labels.json`));
const env = (k: string) => Deno.env.get(k) ?? (() => { throw new Error(`${k} not set`); })();
const norm = (s: string) => s.toLowerCase().replace(/\s+/g, " ").trim();

async function prepare(file: string): Promise<string> {
  const tmp = await Deno.makeTempFile({ suffix: ".jpg" });
  try {
    const cmd = new Deno.Command("sips", {
      args: ["-s", "format", "jpeg", "-s", "formatOptions", "80", "-Z", "1568", `${here}photos/${file}`, "--out", tmp],
      stdout: "null", stderr: "piped",
    });
    const r = await cmd.output();
    if (!r.success) throw new Error(`sips failed for ${file}: ${new TextDecoder().decode(r.stderr)}`);
    const bytes = await Deno.readFile(tmp);
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(bin);
  } finally {
    await Deno.remove(tmp).catch(() => {});
  }
}

/** A detected item counts for a label if either its catalog name or the model's own name matches. */
const matches = (d: Draft, l: Label) => norm(d.display_name) === norm(l.name) || norm(d.name) === norm(l.name);

const rows: { id: string; tidy: boolean; labels: number; found: number; predicted: number; correct: number; qtyErrs: number[]; ms: number; misses: string[]; extras: string[] }[] = [];
for (const scan of labels.scans) {
  const images = await Promise.all(scan.photos.map(prepare));
  const started = performance.now();
  const res = await fetch(env("SCAN_URL"), {
    method: "POST",
    headers: { apikey: env("SUPABASE_KEY"), Authorization: `Bearer ${env("ACCESS_TOKEN")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ location: scan.location, images }),
  });
  const ms = performance.now() - started;
  if (!res.ok) { console.error(`${scan.id}: HTTP ${res.status} ${await res.text()}`); continue; }
  const items: Draft[] = (await res.json()).items;

  const found = scan.items.filter((l) => items.some((d) => matches(d, l)));
  const correct = items.filter((d) => scan.items.some((l) => matches(d, l)));
  const qtyErrs = scan.items.flatMap((l) => {
    const d = items.find((x) => matches(x, l));
    if (!d || l.quantity == null || d.quantity == null || (l.unit && d.unit && l.unit !== d.unit)) return [];
    return [Math.abs(d.quantity - l.quantity) / l.quantity];
  });
  rows.push({
    id: scan.id, tidy: scan.tidy ?? false, labels: scan.items.length, found: found.length,
    predicted: items.length, correct: correct.length, qtyErrs, ms,
    misses: scan.items.filter((l) => !found.includes(l)).map((l) => l.name),
    extras: items.filter((d) => !correct.includes(d)).map((d) => d.display_name),
  });
  console.log(`${scan.id}: found ${found.length}/${scan.items.length}, ${correct.length}/${items.length} correct, ${(ms / 1000).toFixed(1)} s`);
}

const pct = (a: number, b: number) => (b ? `${((100 * a) / b).toFixed(0)}%` : "n/a");
function summary(name: string, rs: typeof rows) {
  const sum = (f: (r: typeof rows[0]) => number) => rs.reduce((a, r) => a + f(r), 0);
  const errs = rs.flatMap((r) => r.qtyErrs).sort((a, b) => a - b);
  const times = rs.map((r) => r.ms).sort((a, b) => a - b);
  console.log(`\n${name} (${rs.length} scans)`);
  console.log(`  recall     ${pct(sum((r) => r.found), sum((r) => r.labels))}   (target ≥ 80% on tidy shelves)`);
  console.log(`  precision  ${pct(sum((r) => r.correct), sum((r) => r.predicted))}   (target ≥ 90% on tidy shelves)`);
  console.log(`  quantity   median error ${errs.length ? `${(100 * errs[Math.floor(errs.length / 2)]).toFixed(0)}%` : "n/a"} over ${errs.length} items`);
  console.log(`  latency    p90 ${times.length ? (times[Math.min(times.length - 1, Math.ceil(0.9 * times.length) - 1)] / 1000).toFixed(1) : "n/a"} s   (target < 25 s)`);
}
summary("All", rows);
summary("Tidy", rows.filter((r) => r.tidy));
console.log("\nMisses and extras per scan:");
for (const r of rows) console.log(`  ${r.id}: missed [${r.misses.join(", ")}]  extra [${r.extras.join(", ")}]`);
await Deno.mkdir(`${here}results`, { recursive: true });
await Deno.writeTextFile(`${here}results/${new Date().toISOString().slice(0, 16).replace(":", "")}.json`, JSON.stringify(rows, null, 2));
