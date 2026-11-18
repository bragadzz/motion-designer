# Render, encode and QA

Run every command from `<video>/pipeline/`. The renderer serves the parent folder, so `scene.html` and every asset must live inside `<video>/`.

## Render

```bash
rm -rf ../frames && node render.mjs ../scene.html ../frames 60 <duration>
```

| Need | Command |
|---|---|
| Re-render a range (inclusive frames) | `node render.mjs ../scene.html ../frames 60 <duration> 300 360` |
| Single keyframe | `node render.mjs ../scene.html ../out/keys 60 <duration> 676 676 --png` |
| Lossless frames for the final | Add `--png` |

- Frames are named `f00000.jpg`, or `.png` with `--png`. JPEG frames are saved at quality 92.
- One `console: ... 404` line for the favicon is normal.
- Re-render the whole timeline before every review round. Patched ranges hide drift.
- Run the final render as a fresh lossless render, then compare it with the approved preview's frames. Every frame stays above 45 dB PSNR, and anything lower is a change nobody approved.

## Encode

```bash
node media.mjs encode ../frames ../out/<name>-silent.mp4 60 <crf>
```

The output is:
- H.264 High, level 4.2 at 1080p60;
- BT.709 in video range;
- a keyframe at least every 2 s, plus one at each scene change;
- `moov` at the start (faststart), so platforms play it before it has fully downloaded;
- no encoder name or version anywhere in the file.

`crf` sets the quality: lower is sharper and bigger, and each step of 6 roughly doubles or halves the size. Check the size afterwards.

| Output | CRF | Example result for 22 s of 1080p60 with motion blur and grain |
|---|---|---|
| Final master | 14 | 43 MB |
| Review preview, also the light copy under 28 MB | 18 | 26 MB |
| Under 10 MB, for Discord without Nitro or a GitHub README | 27; raise it until the file fits | 9.6 MB |

Send previews to remote viewers under 28 MB, since uploads above 30 MB don't reach phones.

## Verify

```bash
node media.mjs verify ../out/<name>.mp4 ../frames 0 <frame> <frame>
```

```bash
node media.mjs sheet ../out/<name>.mp4 ../out/sheet-v<N>.png 0.25 6
```

```bash
node media.mjs extract ../out/<name>.mp4 ../review/v<N>/stills 0.5
```

`verify` prints:
- codec, profile and level, pixel format, colour range and colour tags, size and fps;
- duration, frame count, file size and average bitrate;
- keyframe positions and box order (`faststart ok` or `MOOV AT END`);
- the audio track: format, rate, channels, start, length and peak;
- `tool traces`, which scans the header and the first frame for encoder and tool names, and reads `none` when the file is clean.

`verify` also extracts the chosen frames next to the MP4, as `<name>-fNNNNN.png`, and prints each one's PSNR against the source frame. The source folder must start at frame 0. Delete the extracted PNGs before you deliver.

`sheet` takes one frame every step, labelled with its time and frame number. Use it to count reading times and to catch empty frames between scenes. `extract` saves the same frames at full size, named by frame number.

For the sound:
- transcribe the final MP4 with `scribe_v1`, and confirm the transcript matches the narration text;
- confirm the audio peak in `verify` stays below −1 dBFS.

## Reviewer checklist

The reviewer gets the MP4, the contact sheet, `script.md` and the taste rules. It rejects the cut until every item passes. Each defect comes with a frame number and a crop.

- [ ] Every product element is real or matches a real capture side by side.
- [ ] Each word's reading time holds, counted in frames.
- [ ] No hard cut, no empty frame, no frozen frame.
- [ ] Nothing is cut at an edge, including during zooms and drops.
- [ ] No text overlaps the product.
- [ ] Spelling, accents, currency format and every value are correct. Totals add up.
- [ ] No data looks real, and no data looks like a test.
- [ ] Only brand colours appear.
- [ ] No aliasing on 3D edges, no banding in gradients, no blocky cover.
- [ ] Every sound is in sync with its frame:
  - attacks on the event;
  - swells peak on the beat;
  - notification sounds peak when the banner first shows in full.
- [ ] The voice stays intelligible over the effects, and the peak is below −1 dBFS.
- [ ] No click and no harsh high end in any effect.
- [ ] No trace of the tools in the metadata or file names.
- [ ] Every one of the user's taste rules still holds.
- [ ] The file is within the size limit.

The verdict is APPROVE or REJECT, followed by a numbered list of defects.

## Judge rubric

The judge watches as the audience would. It scores each axis from 0 to 10:

| Axis | What it judges |
|---|---|
| Motion | Something is alive in every frame, the energy builds, and the climax lands |
| Timing | Words, voice, impacts and sounds land together |
| Typography | Hierarchy, readability, kinetic quality |
| Product | The pieces look real, desirable and true to the art |
| Sound | Voice clarity, effect choice, the mix |
| Polish | Edges, transitions, banding, cover frame, closing |

The overall score is a weighted judgement, not a plain average. It comes with:
- the 3 changes that would raise the score most;
- a verdict of POSTABLE at 8.5 or more, or NOT YET.

A new version that scores lower than the previous one on any axis has regressed, and goes back to the motion designer.

## Known problems and fixes

| Problem | Fix |
|---|---|
| `backdrop-filter` is missing in the render | Render in Chrome; headless WebKit doesn't draw it |
| Modules or textures don't load | Serve over HTTP; `render.mjs` does it |
| Frame 0 renders before textures arrive | Resolve `window.ready` only after every texture, model and font has loaded |
| Banding in dark gradients | Add fixed-seed 2 px grain, and lower the CRF |
| Jagged 3D edges | Draw the canvas at 2× with 8× MSAA |
| WebGL renders slowly on a machine without a GPU | Chrome falls back to SwiftShader there; iterate with the canvas at 1× and render the final at 2× |
| Voice lands 13 ms late | `mix` and `mux` drop the MP3 encoder delay; never convert the MP3 with another tool first |
| Words on screen land late against the voice | The alignment runs late after pauses; time words from the audio onset |
| An impact sound lands early | It was placed by its peak; place attack sounds by onset |
| An effect clicks | `mix` removes DC and adds fades; never cut a WAV by hand |
| A low whoosh sounds harsh | Measure the bands, and use the darker take |
| A climax hold looks frozen | Keep a slow push on the camera, for example 1.80 → 1.815 |
| An agent undid an approved fix | Diff `scene.html` after every agent |
| An upload doesn't reach the phone | Send a light copy under 28 MB |
| The simulator app never asked for notification permission | Uninstall and reinstall the app, then trigger its permission request (for example with a tiny injected dylib that calls `requestAuthorization`) and tap Allow |
| The ElevenLabs API returns 403 on `mp3_44100_192` | Use `mp3_44100_128` on the Starter plan |
