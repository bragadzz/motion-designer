import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, readdirSync, mkdirSync, mkdtempSync, renameSync, rmSync, existsSync, statSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

const FFMPEG = process.env.FFMPEG || (await import("ffmpeg-static").then((m) => m.default, () => null)) || "ffmpeg";
const R = 44100;
const TO_RGB = "in_color_matrix=bt709:in_range=tv:flags=accurate_rnd+full_chroma_int,format=rgb24";
const CLEAN = ["-map_metadata", "-1", "-fflags", "+bitexact", "-movflags", "+faststart+write_colr"];
const TRACES = ["Lavf", "Lavc", "x264", "x265", "FFmpeg", "ffmpeg", "HandBrake"];

const log = (s) => console.log(s);
const die = (s) => { console.error(s); process.exit(1); };
const db = (x) => `${(20 * Math.log10(x)).toFixed(2)} dBFS`;
const pad = (n) => String(n).padStart(5, "0");
const peak = (x) => x.reduce((m, s) => Math.max(m, Math.abs(s)), 0);

function ff(args, { show = false, check = true } = {}) {
  const r = spawnSync(FFMPEG, ["-hide_banner", "-nostdin", "-y", ...args], { maxBuffer: 1 << 30, stdio: show ? ["ignore", "inherit", "inherit"] : "pipe" });
  if (r.error) die(r.error.code === "ENOENT" ? "ffmpeg not found: run npm i ffmpeg-static in this folder" : r.error.message);
  const err = show ? "" : r.stderr.toString();
  if (check && r.status !== 0) die(err.trim().split("\n").slice(-6).join("\n") || `ffmpeg exited with ${r.status}`);
  return { out: r.stdout, err };
}

function pcm(file) {
  const b = ff(["-v", "error", "-i", file, "-map", "0:a:0", "-ac", "1", "-ar", String(R), "-f", "f32le", "-"]).out;
  return new Float32Array(new Uint8Array(b).buffer);
}

function boxes(b, s = 0, e = b.length) {
  const out = [];
  while (s + 8 <= e) {
    let size = b.readUInt32BE(s), h = 8;
    if (size === 1) { size = Number(b.readBigUInt64BE(s + 8)); h = 16; } else if (size === 0) size = e - s;
    if (size < h) break;
    out.push({ type: b.toString("latin1", s + 4, s + 8), at: s + h, end: s + size });
    s += size;
  }
  return out;
}

function mp4(file) {
  const b = readFileSync(file), top = boxes(b);
  const kid = (box, ...path) => path.reduce((x, t) => x && boxes(b, x.at, x.end).find((c) => c.type === t), box);
  const moov = top.find((x) => x.type === "moov");
  if (!moov) die(`${file} has no moov box`);
  const trak = (kind) => boxes(b, moov.at, moov.end).find((t) => t.type === "trak" && b.toString("latin1", kid(t, "mdia", "hdlr").at + 8, kid(t, "mdia", "hdlr").at + 12) === kind);
  const v = trak("vide");
  if (!v) die(`${file} has no video track`);
  const stbl = kid(v, "mdia", "minf", "stbl"), mdhd = kid(v, "mdia", "mdhd");
  const timescale = b.readUInt32BE(mdhd.at + (b[mdhd.at] === 1 ? 20 : 12));
  const frames = b.readUInt32BE(kid(stbl, "stsz").at + 8);
  const fps = timescale / b.readUInt32BE(kid(stbl, "stts").at + 12);
  const stss = kid(stbl, "stss");
  const keyframes = stss ? Array.from({ length: b.readUInt32BE(stss.at + 4) }, (_, i) => b.readUInt32BE(stss.at + 8 + 4 * i) - 1) : [...Array(frames).keys()];
  const a = trak("soun");
  let audio = null;
  if (a) {
    const mvhd = kid(moov, "mvhd"), movieScale = b.readUInt32BE(mvhd.at + (b[mvhd.at] === 1 ? 20 : 12));
    const am = kid(a, "mdia", "mdhd"), v1 = b[am.at] === 1, scale = b.readUInt32BE(am.at + (v1 ? 20 : 12));
    const elst = kid(a, "edts", "elst");
    audio = { start: 0, length: (v1 ? Number(b.readBigUInt64BE(am.at + 24)) : b.readUInt32BE(am.at + 16)) / scale };
    if (elst) {
      const w = b[elst.at] === 1 ? 8 : 4, n = b.readUInt32BE(elst.at + 4);
      const read = (p) => (w === 8 ? Number(b.readBigInt64BE(p)) : b.readInt32BE(p));
      audio.length = 0;
      for (let i = 0, p = elst.at + 8; i < n; i++, p += 2 * w + 4) {
        const seg = read(p) / movieScale;
        if (read(p + w) === -1) audio.start += seg; else audio.length += seg;
      }
    }
  }
  return { b, top, fps, frames, keyframes, duration: frames / fps, audio };
}

function stills(file, dir, step, width) {
  const { fps, frames } = mp4(file);
  const every = Math.max(1, Math.round(step * fps));
  mkdirSync(dir, { recursive: true });
  const tmp = mkdtempSync(join(dir, ".stills-"));
  ff(["-v", "error", "-i", file, "-vf", `select=not(mod(n\\,${every})),scale=${width ? `${width}:-2:` : ""}${TO_RGB}`, "-fps_mode", "passthrough", join(tmp, "s%05d.png")]);
  const out = readdirSync(tmp).sort().map((f, i) => {
    const q = i * every, name = `f${pad(q)}.png`;
    renameSync(join(tmp, f), join(dir, name));
    return { q, t: q / fps, name };
  });
  rmSync(tmp, { recursive: true });
  if (out.length !== Math.ceil(frames / every)) die(`expected ${Math.ceil(frames / every)} stills, got ${out.length}`);
  return out;
}

function encode([dir, out, fps = "60", crf = "18"]) {
  if (!dir || !out) die("usage: node media.mjs encode <frames-dir> <out.mp4> [fps=60] [crf=18]");
  const files = readdirSync(dir).filter((f) => /\.(png|jpe?g)$/i.test(f)).sort();
  const m = files[0]?.match(/^(.*?)(\d+)(\.\w+)$/);
  if (!m) die(`no numbered frames in ${dir}`);
  const t0 = performance.now();
  ff(["-v", "error", "-stats", "-framerate", fps, "-start_number", String(Number(m[2])), "-i", join(dir, `${m[1]}%0${m[2].length}d${m[3]}`),
    "-frames:v", String(files.length), "-vf", "format=rgb24,scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p",
    "-c:v", "libx264", "-preset", "slow", "-crf", crf, "-profile:v", "high", "-refs", "4", "-g", String(Number(fps) * 2), "-metadata:s:v", "encoder=H.264",
    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
    "-bsf:v", "filter_units=remove_types=6", "-flags:v", "+bitexact", ...CLEAN, out], { show: true });
  const { frames } = mp4(out);
  if (frames !== files.length) die(`encoded ${frames} of ${files.length} frames: the numbering in ${dir} has a gap`);
  log(`done: ${frames} frames, CRF ${crf} → ${out} (${(statSync(out).size / 1e6).toFixed(2)} MB) in ${((performance.now() - t0) / 1000).toFixed(1)} s`);
}

function mux([video, audio, out]) {
  if (!video || !audio || !out) die("usage: node media.mjs mux <video.mp4> <audio> <out.mp4>");
  const { duration } = mp4(video), total = Math.round(duration * R), n = pcm(audio).length;
  if (n > total) die(`the audio (${(n / R).toFixed(3)} s) is longer than the video (${duration.toFixed(3)} s)`);
  ff(["-v", "error", "-i", video, "-i", audio, "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
    "-af", `apad=whole_len=${total}`, "-ar", String(R), "-c:a", "aac", "-b:a", "128k", "-flags:a", "+bitexact", ...CLEAN, out]);
  log(`audio: ${(n / R).toFixed(3)} s · silence to the end: ${((total - n) / R).toFixed(3)} s`);
  log(`done: ${out} (${(statSync(out).size / 1e6).toFixed(2)} MB), video copied without re-encoding + AAC 44.1 kHz 128 kbps`);
}

function clean(x) {
  const mean = x.reduce((a, s) => a + s, 0) / x.length;
  const rc = 1 / (2 * Math.PI * 20), al = rc / (rc + 1 / R), y = new Float32Array(x.length);
  let prev = 0, hp = 0;
  for (let i = 0; i < x.length; i++) { const s = x[i] - mean; hp = al * (hp + s - prev); prev = s; y[i] = hp; }
  const fi = Math.trunc(0.003 * R), fo = Math.trunc(0.01 * R);
  for (let i = 0; i < Math.min(fi, y.length); i++) y[i] *= i / fi;
  for (let i = 0; i < Math.min(fo, y.length); i++) y[y.length - 1 - i] *= i / fo;
  return y;
}

function rms(x, before, after) {
  const b0 = Math.trunc(before * R), a0 = Math.trunc(after * R), pref = new Float64Array(x.length + 1), out = new Float32Array(x.length);
  for (let i = 0; i < x.length; i++) pref[i + 1] = pref[i] + x[i] * x[i];
  for (let i = 0; i < x.length; i++) { const lo = Math.max(0, i - b0), hi = Math.min(x.length, i + a0); out[i] = Math.sqrt((pref[hi] - pref[lo]) / Math.max(1, hi - lo)); }
  return out;
}

function mix([voicePath, marksPath, outPath, durArg = "15"]) {
  if (!voicePath || !marksPath || !outPath) die("usage: node media.mjs mix <voice> <marks.txt> <out.wav> [duration=15]");
  const N = Math.round(Number(durArg) * R), ceiling = 10 ** (-1 / 20);
  const voice = pcm(voicePath);
  if (voice.length > N) die(`the voice (${(voice.length / R).toFixed(3)} s) is longer than the duration`);
  const v = new Float32Array(N);
  v.set(voice);

  const sfx = dirname(marksPath), cache = new Map(), effects = [], ducks = [];
  for (const line of readFileSync(marksPath, "utf8").split("\n")) {
    const c = line.split("#")[0].replaceAll(",", ".").replaceAll("−", "-").trim().split(/[ \t]+/).filter(Boolean);
    if (!c.length) continue;
    const t = Number(c[0]), target = Number(c[2]), name = c[1];
    if (c.length !== 3 || !Number.isFinite(t) || !Number.isFinite(target)) die(`invalid line in marks file: ${line}`);
    if (name === "duck") { ducks.push([t, target]); continue; }
    if (!cache.has(name)) {
      const file = [".wav", ".mp3", ""].map((e) => join(sfx, name + e)).find((f) => existsSync(f) && statSync(f).isFile());
      if (!file) die(`no ${name}.wav or ${name}.mp3 in ${sfx}`);
      cache.set(name, clean(pcm(file)));
    }
    const s = cache.get(name);
    effects.push({ t, name, target, start: Math.round(t * R), s, gain: 10 ** (target / 20) / peak(s) });
  }

  const sumEffects = () => {
    const e = new Float32Array(N);
    for (const ef of effects) for (let i = 0; i < ef.s.length && ef.start + i < N; i++) e[ef.start + i] += ef.gain * ef.s[i];
    return e;
  };

  const ducking = new Float32Array(N).fill(1);
  if (ducks.length) {
    const vAhead = rms(v, 0.01, 0.03), vMid = rms(v, 0.01, 0.01), eEnv = rms(sumEffects(), 0.01, 0.01), minGain = 10 ** (-24 / 20);
    const target = new Float32Array(N).fill(1);
    for (const [t, margin] of ducks) {
      const m = 10 ** (-Math.abs(margin) / 20), i0 = Math.max(0, Math.trunc((t - 0.03) * R)), i1 = Math.min(N, Math.trunc((t + 0.6) * R));
      for (let n = i0; n < i1; n++) if (eEnv[n] > 1e-6) target[n] = Math.min(target[n], Math.max(minGain, Math.min(1, (m * Math.min(vAhead[n], vMid[n])) / eEnv[n])));
    }
    const ah = Math.trunc(0.008 * R), attack = Math.exp(-1 / (0.003 * R)), release = Math.exp(-1 / (0.1 * R));
    let g = 1;
    for (let n = 0; n < N; n++) {
      let ta = target[n];
      for (let k = n + 1; k < Math.min(N, n + ah); k++) if (target[k] < ta) ta = target[k];
      g = ta + (g - ta) * (ta < g ? attack : release);
      ducking[n] = g;
    }
  }

  let out = v, peakBefore = 0;
  for (let pass = 0; pass < 20; pass++) {
    const e = sumEffects();
    out = new Float32Array(N);
    for (let n = 0; n < N; n++) { e[n] *= ducking[n]; out[n] = v[n] + e[n]; }
    if (pass === 0) peakBefore = peak(out);
    const factor = effects.map(() => 1);
    let over = false;
    for (let n = 0; n < N; n++) {
      if (Math.abs(out[n]) <= ceiling) continue;
      over = true;
      const k = Math.max(0, ((out[n] > 0 ? ceiling : -ceiling) - v[n]) / e[n]);
      effects.forEach((ef, j) => { if (n >= ef.start && n < ef.start + ef.s.length && ef.s[n - ef.start] !== 0) factor[j] = Math.min(factor[j], k * 0.999); });
    }
    if (!over) break;
    effects.forEach((ef, j) => { ef.gain *= factor[j]; });
  }

  log(`voice: ${(voice.length / R).toFixed(3)} s, peak ${db(peak(voice))}`);
  for (const ef of effects) {
    const p = 20 * Math.log10(peak(ef.s) * ef.gain), lowered = p - ef.target;
    log(`  ${ef.t.toFixed(2).padStart(6)} s  ${ef.name} peak ${p.toFixed(2).padStart(6)} dBFS${Math.abs(lowered) > 0.01 ? `  (lowered ${(-lowered).toFixed(2)} dB to fit)` : ""}`);
  }
  log(`mix: peak ${db(peak(out))} (before adjustment ${db(peakBefore)}, ceiling −1 dBFS)`);
  if (ducks.length) {
    const vEnv = rms(v, 0.01, 0.01), eEnv = rms(out.map((x, i) => x - v[i]), 0.01, 0.01);
    for (const [t] of ducks) {
      let best = -1;
      for (let n = Math.trunc(t * R); n < Math.min(N, Math.trunc((t + 0.6) * R)); n++) if (vEnv[n] > 0.03 && (best < 0 || eEnv[n] / vEnv[n] > eEnv[best] / vEnv[best])) best = n;
      if (best < 0) continue;
      const rel = 20 * Math.log10(Math.max(eEnv[best], 1e-9) / vEnv[best]);
      log(`  duck ${t.toFixed(2).padStart(6)} s: effects at most ${rel >= 0 ? "+" : ""}${rel.toFixed(1)} dB relative to the voice (${(best / R).toFixed(3)} s, voice ${(20 * Math.log10(vEnv[best])).toFixed(0)} dBFS RMS)`);
    }
  }

  const h = Buffer.alloc(44);
  h.write("RIFF", 0); h.writeUInt32LE(36 + N * 4, 4); h.write("WAVEfmt ", 8); h.writeUInt32LE(16, 16); h.writeUInt16LE(3, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(R, 24); h.writeUInt32LE(R * 4, 28); h.writeUInt16LE(4, 32); h.writeUInt16LE(32, 34); h.write("data", 36); h.writeUInt32LE(N * 4, 40);
  writeFileSync(outPath, Buffer.concat([h, Buffer.from(out.buffer)]));
  log(`done: ${outPath} (${(N / R).toFixed(3)} s, 44.1 kHz mono float32)`);
}

function verify([file, srcDir, ...frameArgs]) {
  if (!file) die("usage: node media.mjs verify <video.mp4> [source-frames-dir] [frames...]");
  const { b, top, fps, frames, keyframes, duration, audio } = mp4(file);
  const probe = ff(["-i", file], { check: false }).err;
  const video = probe.match(/Video: (.+)/)?.[1].replace(/ \(\w+ \/ 0x\w+\)/g, "").replace(/ \(default\)$/, "");
  const avcC = b.indexOf("avcC");
  const level = avcC > 0 ? ` · level ${(b[avcC + 7] / 10).toFixed(1)}` : "";
  log(`video: ${video}${level}`);
  log(`${duration.toFixed(3)} s · ${+fps.toFixed(3)} fps · ${frames} frames · ${(b.length / 1e6).toFixed(2)} MB (${((b.length * 8) / duration / 1e6).toFixed(2)} Mbps)`);
  const atoms = top.map((x) => x.type), mo = atoms.indexOf("moov"), md = atoms.indexOf("mdat");
  log(`keyframes at frames ${keyframes.join(" ")} · atoms: ${atoms.join(" ")}${mo < md ? " (faststart ok)" : " (MOOV AT END)"}`);
  if (audio) {
    const a = pcm(file);
    log(`audio: ${probe.match(/Audio: (.+)/)[1].replace(/ \(\w+ \/ 0x\w+\)/g, "").replace(/ \(default\)$/, "")} · starts at ${audio.start.toFixed(3)} s · lasts ${audio.length.toFixed(3)} s · peak ${db(peak(a))}`);
  } else log("audio: none");
  const head = Buffer.concat(top.map((x) => (x.type === "mdat" ? b.subarray(x.at, Math.min(x.end, x.at + 65536)) : b.subarray(x.at - 8, x.end))));
  const found = TRACES.filter((s) => head.includes(s));
  log(`tool traces: ${found.length ? found.join(", ") : "none"}`);

  const source = srcDir ? readdirSync(srcDir).filter((f) => /\.(png|jpe?g)$/i.test(f)).sort() : [];
  const list = frameArgs.length ? frameArgs.map(Number) : [frames >> 2, frames >> 1, (frames * 3) >> 2];
  const base = file.replace(/\.mp4$/i, "");
  for (const q of list) {
    const png = `${base}-f${pad(q)}.png`;
    ff(["-v", "error", "-ss", String(Math.max(0, (q - 0.5) / fps)), "-i", file, "-frames:v", "1", "-vf", `scale=${TO_RGB}`, png]);
    let line = `frame ${q} (t=${(q / fps).toFixed(4)} s) → ${png}`;
    if (q < source.length) {
      const r = ff(["-i", png, "-i", join(srcDir, source[q]), "-lavfi", "[0:v]format=rgb24[a];[1:v]format=rgb24[b];[a][b]psnr", "-f", "null", "-"]).err;
      line += ` · PSNR ${r.match(/average:(\S+)/)?.[1] ?? "?"} dB`;
    }
    log(line);
  }
}

async function sheet([file, outPng, step = "0.25", cols = "6"]) {
  if (!file || !outPng) die("usage: node media.mjs sheet <video.mp4> <sheet.png> [step=0.25] [columns=6]");
  const tmp = mkdtempSync(join(tmpdir(), "sheet-"));
  const shots = stills(file, tmp, Number(step), 480);
  const cells = shots.map((s) => `<figure><img src="${s.name}"><figcaption>${s.t.toFixed(2)} s · f${s.q}</figcaption></figure>`).join("");
  writeFileSync(join(tmp, "index.html"), `<!doctype html><meta charset="utf-8"><style>body{margin:0;background:#333;color:#e6e6e6;font:bold 18px system-ui,sans-serif}main{display:grid;grid-template-columns:repeat(${cols},480px);gap:6px;padding:6px;width:max-content}figure{margin:0}img{display:block;width:480px}figcaption{height:30px;line-height:30px;padding-left:4px}</style><main>${cells}</main>`);
  const { chromium } = await import("playwright-core");
  const browser = await chromium.launch({ channel: "chrome" });
  const page = await browser.newPage({ viewport: { width: Number(cols) * 486 + 6, height: 300 } });
  await page.goto(pathToFileURL(join(tmp, "index.html")).href, { waitUntil: "load" });
  await page.locator("main").screenshot({ path: resolve(outPng) });
  await browser.close();
  rmSync(tmp, { recursive: true });
  log(`sheet: ${shots.length} frames (every ${step} s) → ${outPng}`);
}

function extract([file, dir, step = "1"]) {
  if (!file || !dir) die("usage: node media.mjs extract <video.mp4> <out-dir> [step=1.0]");
  log(`extract: ${stills(file, dir, Number(step)).length} frames (every ${step} s) → ${dir}`);
}

function ffmpeg(args) {
  const r = spawnSync(FFMPEG, args, { stdio: "inherit" });
  if (r.error) die(r.error.message);
  process.exit(r.status ?? 1);
}

const tools = { encode, mux, mix, verify, sheet, extract, ffmpeg };
const [cmd, ...rest] = process.argv.slice(2);
if (!tools[cmd]) die(`usage: node media.mjs <${Object.keys(tools).join("|")}> ...`);
await tools[cmd](rest);
