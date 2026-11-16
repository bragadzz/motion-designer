---
name: motion-designer
description: Directs and produces short motion-design videos end to end, from brief to a verified MP4, covering the reference board, frame-accurate script, narration, a deterministic HTML/Three.js scene rendered frame by frame, H.264 encode, sound design and mix, and a reviewer and judge loop that repeats until the cut passes. Use when asked to make, edit, fix or polish a trailer, teaser, product reveal, launch video, animated ad or social video cut.
---

# Motion Designer

Turn a brief into a polished, narrated video. The video is a web page that draws any moment of the timeline on demand; a headless Chrome photographs it frame by frame, and native macOS tools encode, mix and verify the result. Every frame is reproducible and every timing is counted in frames.

## Requirements

- macOS with the Xcode command line tools (`swiftc`, AVFoundation, `afconvert`, `xcrun simctl`).
- Node 20 or newer and Google Chrome.
- For narration and sound effects: an ElevenLabs key saved in `~/.config/elevenlabs/key`.
- No ffmpeg.

## Rules

- **The user approves at fixed stops, and nowhere else.** The stops are:
  1. the reference board;
  2. the script with the narration;
  3. the keyframes;
  4. every narrated preview.

  Between stops, work end to end without asking. Render the final only after the user approves a preview.
- **Everything shown is real.**
  - Product screens, notifications and UI come from the real product.
  - A replica is allowed only after a side-by-side image proves it matches a real capture.
  - Never invent something that poses as product data, such as a revenue card, a counter or a progress bar.
- **Use sample data only.** Fictional names, `@example.test` e-mails and made-up IDs. No real person, document number, key or customer.
- **Keep secrets in files.**
  - Read a secret inline, for example `K="$(cat ~/.config/elevenlabs/key)"`.
  - Never print it, log it, or write it anywhere else.
- **Take only the style from references.**
  - Link to a reference and show its thumbnail. Never download someone else's video.
  - Borrow the style, never the art.
- **Clear licences only.**
  - Music needs a clear commercial licence and the user's OK. The default is no music.
  - Name any asset with an unknown licence in the final report.
- **Deliverables carry no trace of the tools that made them**, in file names, metadata, captions and copy alike.
- **Work outside every code repository.** Use `~/Documents/<video-name>/` and commit nothing.
- **Render one at a time, in the foreground.**

## Setup

```bash
mkdir -p ~/Documents/<video>/{references,assets,narration,sfx,pipeline,frames,out,review}
```

```bash
cp "${CLAUDE_SKILL_DIR}"/scripts/* ~/Documents/<video>/pipeline/
```

```bash
cd ~/Documents/<video>/pipeline && npm i playwright-core@"$(npm view playwright-core version)" && for s in encode mux mix verify sheet extract; do swiftc -O $s.swift -o $s; done
```

| Path | Holds |
|---|---|
| `script.md` | The frame table, layout, type, colours, and the user's taste rules |
| `scene.html` | The animation |
| `assets/` | Fonts as woff2, logos as SVG, production art, real captures |
| `narration/` | The text, takes as MP3, and alignment JSON |
| `sfx/` | Effects as WAV, `marks.txt`, and the mixed `track.wav` |
| `frames/` | Rendered frames |
| `out/` | Previews, contact sheets and the final |
| `review/v<N>/` | Reviewer and judge evidence for each version |

## Workflow

### 1. Brief

In one message, ask for everything that is missing:
- format: resolution, fps, duration, aspect;
- where it will be posted, and that platform's size limit;
- what must appear;
- brand: logo SVG, colours, forbidden colours, fonts;
- product art;
- voice language and style;
- closing line.

Defaults when the user doesn't say: 1920×1080, 60 fps, 15–25 s, narrated, no music.

### 2. References

1. Find 15–25 references across themes: product reveal, category peers, kinetic type, UI motion, unlock and celebration moments.
2. For each one, record the title, author, link, thumbnail URL, and one sentence on what to take from it.
3. Build one numbered HTML board, send it, and let the user answer with numbers.

**Done when:** the user picks the numbers.

### 3. Script and narration

Write `script.md` with one table row per beat:

| Time (s · frames) | On screen | Effect (ref) | Image, and what is alive | Voice |
|---|---|---|---|---|

Add the layout grid, type, colours and the always-alive list. Then generate narration takes, so the user hears the voice alongside the script. See [references/audio.md](references/audio.md).

**Done when:** the user approves the script and the voice.

### 4. Scene

1. Build `scene.html` following [references/scene.md](references/scene.md).
2. Before you animate everything, send 3–5 keyframes of the key moments. Render each one alone, with the same frame number twice:
   ```bash
   node render.mjs ../scene.html ../out/keys 60 <duration> <frame> <frame> --png
   ```

**Done when:** the user approves the keyframes.

### 5. Sound

Place every effect from the real audio, not from the plan. See [references/audio.md](references/audio.md).

### 6. Render, encode, verify

Follow [references/render-and-qa.md](references/render-and-qa.md).

### 7. Review loop

Run one subagent per front. Brief each agent fresh, with the files it needs and the taste rules:

| Agent | Owns |
|---|---|
| Script writer | `script.md` and the narration text |
| Motion designer | `scene.html` |
| Reviewer | Skeptical QA. Returns APPROVE or REJECT with numbered defects, each with a frame number and a crop saved in `review/v<N>/` |
| Judge | Scores 0–10 on fixed axes and says whether the cut is postable |

For each version:
1. The motion designer fixes the defects.
2. Render the frames and encode the narrated preview.
3. Run the reviewer and the judge in parallel.
4. Repeat until both of these hold:
   - the reviewer approves;
   - the judge scores 8.5 or more, and nothing is worse than in the previous version.
5. Send the preview to the user, along with a light copy that fits phone viewing.

After each agent finishes, diff `scene.html` and `script.md`: agents undo each other's approved fixes.

When the user gives feedback, apply it, add it as a rule to the taste list in `script.md`, and have the reviewer check that list every round.

### 8. Final

Only after the user approves a preview:
1. Render lossless with `--png`.
2. Encode at a high-quality setting and mux.
3. Run `verify` and build the contact sheet.
4. Check the metadata.
5. Deliver the main file plus a light copy under the upload limit.

The final report contains:
- what was made;
- the judge's last score;
- what was left out, and why;
- every asset with an unknown licence.

## Taste defaults

- **Motion comes from the content**: the product, the camera, the typography, and real UI. Something is moving in every frame.
- **No decorative chrome.** Leave out:
  - corner brackets and HUD rings;
  - rings or colour swatches under the product;
  - particles, stars and spotlights;
  - diagonal stripes;
  - fake cards and counters;
  - outline letters or text over the product.

  The product appears alone.
- **Background**: near-black, with a soft gradient in the scene's colour and fixed-seed 2 px grain against banding.
- **Cuts**: never hard, never an empty frame, never a frozen frame. A hold keeps a slow camera push.
- **Zooms**: fast, with a strong ease and motion blur proportional to speed. The zoom scales the whole camera, so text never lands on the product.
- **Impacts**: each one is bigger than the last. The final one is the climax.
- **Closing**: the brand alone, with nothing dimmed behind it.
- **Without sound**: the video still reads.
