# Scene

## Contract

`render.mjs` expects these things from the page:

- **Size**: the page is 1920×1080.
- **`window.frame(t)`**: a pure function of time in seconds.
  - Every call rebuilds the whole frame from zero.
  - The page uses no CSS `animation` or `transition`, no `requestAnimationFrame`, no timers, and no unseeded `Math.random`.
- **`window.ready`**: a Promise that resolves once every texture, model and font has loaded.
  - The renderer awaits it, then `document.fonts.ready`, then decodes every `<img>`.
  - Frame 0 is the cover image, so it must be complete.
- **Assets**:
  - images live in `<img>` elements or loaded textures;
  - fonts are local woff2 files.
- **Serving**: the renderer serves the project folder over local HTTP, because ES modules and WebGL textures don't load from `file://`.
- **Browser**: the renderer uses Chrome, not WebKit, because headless WebKit doesn't draw `backdrop-filter`. On macOS it draws WebGL through Metal; elsewhere Chrome picks the GPU, or SwiftShader when there is none.

Seed every random value. The confetti and the grain come out the same on every render.

## Layout

Write the grid into `script.md` before animating:

- **Margins**: 96 px on both sides. Nothing crosses them while the camera is still.
- **Columns**: a product column and a text column. The product never enters, leaves or grows across the text column.
- **Text bands** (top, middle, bottom): each band has one job. Example: the number at the top, notifications in the middle, labels at the bottom.
- **Zoom centres**: choose each one so the text in focus stays whole, with room to spare at the edge.

## Reading time

- A word of up to 5 letters stays on screen for at least 0.6 s.
- A word of 6 letters or more stays for at least 0.75 s.
- Every word holds still and whole for at least 0.45 s.
- Entrances take 0.15 s. Exits leave as one block in 0.12 s.
- The old word is invisible 2 frames before the new word starts entering in the same place.
- Count every duration in frames, and check it on the contact sheet.

## Easing

| Name | Formula | Use |
|---|---|---|
| `quint` | `1-(1-x)^5` | Entrances and settles |
| `inout3` | Cubic ease-in-out | Camera moves and turns |
| `in3` | `x^3` | Exits |

## Effects

| Effect | Parameters |
|---|---|
| Scene change (never a hard cut) | The next scene enters 0.06 s early. The current scene exits in 0.18 s on `in3`: it travels 900 px along the next scene's direction, scales 1→0.96, blurs up to 12 px, and fades out over the last 40 %. |
| Slide in | 0.35 s `quint` along a 9° diagonal, 1000–1100 px. Motion blur up to 8 px, proportional to speed. |
| Letters rising from a mask | Each letter: 0.22 s `quint`, rising 1.15× the word's height, starting 15–30 ms after the previous letter. Three trails at 0.30, 0.18 and 0.09 opacity, shown only while the letter moves. The word blurs 5→0 px. |
| Punch with trails | Three copies: trails at 16 % and 32 %, then the main copy, 15 ms apart. Scale 1.25→1 in 0.18 s `quint`, blur 5→0 px, 6 px shake for 4 frames. |
| Impact | Zoom punch to 1.06–1.12, peaking in 3 frames and back in 0.25 s. A 1-frame flash at 40–50 %. The product grows. Confetti bursts from both lower corners, covers the whole screen within 0.35 s, then falls and fades. The headline slams in from 1.3→1 with trails and an 8–14 px shake. Each impact is stronger than the last: more confetti, a bigger punch, a turn or whip on the product. |
| Zoom to a detail | 0.45 s `inout3` to 1.6–2.5×, with motion blur. The detail holds readable for at least 0.6 s while the camera keeps creeping in, then the camera whips back with a light overshoot. |
| Zoom through | The camera dives into product A (scale 1→3, blur 12 px) and comes out on product B, which arrives from depth with scale trails. |
| Whole turn | 360° in Y over 0.6 s `inout3`, with the product's own trails. Compensate the height so the product stays inside the frame. |
| Light sweep | A specular band crosses the product's face over 0.6–0.9 s. It is light on the piece, never a glow in the background. |
| Notification stack | At most 3 visible at once. The newest drops in from the top, and the stack shifts down. The banner peaks on the frame where it first shows in full; that is where its sound peaks too. |
| Closing | The symbol and wordmark rise 200–260 px with blur 8→0 px and scale 1.12→1 in 0.32 s `quint`. The camera keeps a slow push until the last frame. |

## 3D with Three.js

Install the latest stable `three` in the project, checked with `npm view three version`.

**Build from production art.**
- Use the print files, cut lines and real proportions.
- Render stills and compare them side by side with photos or factory footage before animating. Save the comparison image in `review/`.

**Render quality.**
- Draw the canvas at 3840×2160 with 8× MSAA, displayed at 1920×1080. That supersamples every frame.
- Use a physical material and an environment map.

**Light.**
- An orbiting point light runs across the piece.
- Edge glints fade out when the piece is seen side-on.
- The background stays clean.

**Transparent pieces** (acrylic, glass):
- the back print shows through the front;
- relief seen from behind is drawn mirrored;
- no hard-coded flat colour on the back face.

**Controls.** Expose each piece's parameters, such as fill `level` 0→1 and light `sweep` 0→1, and drive them from `t`.

**Alive.** Every piece on screen is always alive: it turns slowly or spins fully, floats, catches light, or the camera orbits it.

## Real UI

**Product screens.**
- Run the product locally from its current main branch.
- Answer the API with sample JSON shaped like the real responses.
- Take screenshots at device scale 3 for phones and 2 for desktop.

**iOS notifications.** This needs a Mac with Xcode. On Windows or Linux, capture real screens from an Android emulator or a phone instead.
- Use the iOS Simulator with the app installed, in dark mode.
- Send the real payload from the product's code: `xcrun simctl push booted <bundle-id> payload.apns`.
- Fix the status bar: `xcrun simctl status_bar booted override --time 9:41 --batteryState discharging --batteryLevel 100 --cellularBars 4 --wifiBars 3`.
- Capture with `xcrun simctl io booted screenshot shot.png`.

**Replicating UI in CSS.**
- Measure in points times the screen scale.
- Build a side-by-side image of the capture and the replica, and keep it as proof.

## Gradients and banding

Smooth dark gradients band after H.264 compression. Fix it in two places:
- **In the scene**: lay a 2 px, fixed-seed grain over the background.
- **In the encode**: lower the CRF.

After posting, look at how the platform recompressed the grain.
