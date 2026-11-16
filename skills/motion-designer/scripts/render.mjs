import { chromium } from "playwright-core";
import { mkdirSync, writeFileSync, readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { resolve, join, relative, extname, sep } from "node:path";

const argv = process.argv.slice(2);
const png = argv.includes("--png");
const [html, outDir, fpsArg = "60", durArg = "15", fromArg, toArg] = argv.filter((a) => a !== "--png");
if (!html || !outDir) { console.error("usage: node render.mjs <page.html> <out-dir> [fps=60] [duration=15] [from to] [--png]"); process.exit(1); }
const fps = Number(fpsArg), total = Math.round(fps * Number(durArg));
const from = fromArg ? Number(fromArg) : 0, to = toArg ? Number(toArg) : total - 1;
mkdirSync(outDir, { recursive: true });

const root = resolve(import.meta.dirname, "..");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".woff2": "font/woff2", ".json": "application/json" };
const server = createServer((req, res) => {
  const p = resolve(root, "." + decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (!p.startsWith(root + sep)) { res.writeHead(403).end(); return; }
  try {
    if (!statSync(p).isFile()) throw 0;
    res.writeHead(200, { "content-type": TYPES[extname(p)] || "application/octet-stream" }).end(readFileSync(p));
  } catch { res.writeHead(404).end(); }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const address = `http://127.0.0.1:${server.address().port}/${relative(root, resolve(html)).split(sep).join("/")}`;

const browser = await chromium.launch({ channel: "chrome", args: ["--use-angle=metal", "--ignore-gpu-blocklist"] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1, colorScheme: "dark" });
page.on("pageerror", (e) => { console.error("page error:", e.message); process.exit(1); });
page.on("console", (m) => { if (m.type() === "error" || m.type() === "warning") console.error("console:", m.text()); });
await page.goto(address, { waitUntil: "load" });
await page.waitForFunction(() => typeof window.frame === "function" || "ready" in window, null, { timeout: 120000 });
await page.evaluate(async () => {
  await window.ready;
  if (typeof window.frame !== "function") throw new Error("the page does not define window.frame(t)");
  await document.fonts.ready;
  await Promise.all([...document.images].map((i) => i.decode()));
});

const type = png ? "png" : "jpeg", ext = png ? "png" : "jpg";
const t0 = performance.now();
let writing = Promise.resolve();
for (let i = from; i <= to; i++) {
  await page.evaluate((t) => window.frame(t), i / fps);
  const buf = await page.screenshot({ type, quality: png ? undefined : 92, caret: "initial", scale: "css" });
  await writing;
  writing = Promise.resolve().then(() => writeFileSync(join(outDir, `f${String(i).padStart(5, "0")}.${ext}`), buf));
  if ((i - from + 1) % 120 === 0) console.log(`${i - from + 1}/${to - from + 1} · ${((performance.now() - t0) / (i - from + 1)).toFixed(1)} ms/frame`);
}
await writing;
const n = to - from + 1, s = (performance.now() - t0) / 1000;
console.log(`done: ${n} frames ${ext} in ${s.toFixed(1)} s (${((s * 1000) / n).toFixed(1)} ms/frame) → ${outDir}`);
await browser.close();
server.close();
