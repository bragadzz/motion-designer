# Audio

## Narration (ElevenLabs)

Read the key inline in every call and never print it:

```bash
K="$(cat ~/.config/elevenlabs/key)"
```

Before the first call, check the current API in the official docs: model ids, output formats and plan limits all change.

### Pick the voice

- Send the user voice library links in the form `https://elevenlabs.io/app/voice-library?voiceId=<id>`, and let them choose.
- Add the chosen voice to the account with `POST /v1/voices/add/{public_owner_id}/{voice_id}`.

### Write the text

- Write it next to the on-screen words, in the same order.
- Use emotion tags such as `[excited]` and `[happy]`. Ellipses make pauses.
- Spell brand names and acronyms the way they are spoken, for example "OAuth two" for OAuth2.
- Save the text in `narration/text.txt`.

### Generate takes with timestamps

```bash
curl -s -X POST -H "xi-api-key: $K" -H "Content-Type: application/json" --data @req.json "https://api.elevenlabs.io/v1/text-to-speech/<voice_id>/with-timestamps?output_format=mp3_44100_128"
```

`req.json` holds:

```json
{"text": "...", "model_id": "<latest model>", "language_code": "<lang>", "seed": 11, "voice_settings": {"stability": 0.5, "similarity_boost": 0.8, "speed": 1.0}}
```

- The response carries `audio_base64` and `alignment.character_start_times_seconds`.
- Generate 3 seeds (11, 22 and 44) and keep each take's MP3 and JSON.
- The whole speech must fit the video's duration.
- On the Starter plan, `mp3_44100_192` returns 403, so use `mp3_44100_128`. That plan allows commercial use.

### Check pronunciation

Transcribe every take with `POST /v1/speech-to-text` (`model_id=scribe_v1`). Keep the take whose transcript matches the text.

### Measure real word starts

After pauses, the alignment runs 0.1–0.3 s late. To time the video:
1. Take each key word's start from the real audio onset, found in the waveform energy near the alignment time.
2. Write the measured times into the Voice column of `script.md`.

Each key word starts entering on screen at most 0.4 s before it is spoken.

## Sound effects

### Generate

```bash
curl -s -o whoosh-1.mp3 -X POST -H "xi-api-key: $K" -H "Content-Type: application/json" --data @req.json "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_128"
```

`req.json` holds `{"text": "<prompt>", "duration_seconds": <s>, "prompt_influence": 0.6}`. Make two versions of each effect.

| Effect | Prompt | Duration |
|---|---|---|
| whoosh | Fast clean whoosh swoosh transition sound effect for video editing, short air swipe passing by, crisp, dry, no reverb, no music | 0.7 s |
| swish | Very short subtle swish for kinetic typography text appearing, quick light air flick, crisp, dry, no music | 0.5 s |
| impact | Punchy tight cinematic hit impact with short deep sub boom, for a word slamming onto the screen, no long tail, no music | 0.8 s |
| low zoom | Deep low pitched bassy whoosh for a camera zoom in, warm and dark, no high frequencies, no hiss, smooth, dry, no music | 0.7 s |
| riser | Fast rising energy riser building up tension for a progress bar filling, deep warm synth swell with subtle electric shimmer, ends abruptly at the peak, dry, no music, no voice | 1.0 s |
| unlock | Big punchy cinematic boom impact with bright sparkle burst for an achievement unlocked moment, deep sub hit plus short glittering shimmer tail, no music, no voice | 1.2 s |
| confetti | Short festive confetti cannon pop with paper confetti rustle flutter, crisp and clean, celebration, no crowd, no music, no voice | 0.9 s |
| logo | Clean deep boom hit for a logo reveal at the end of a video, short shimmer tail, modern, no music | 1.5 s |

If the product has a real sound, such as a sale chime or a notification sound, use that file.

### Prepare

- Convert each effect: `afconvert -f WAVE -d LEI16@44100 -c 1 in.mp3 out.wav`.
- Measure each effect's energy in frequency bands. A low whoosh with most of its energy above 2 kHz sounds harsh, so prefer the darker version.
- Build an `.m4a` sample (`afconvert -f m4af -d aac -b 160000`), and let the user hear the effects before they go into the video.

## Placement

- **Attack sounds** (impacts, pops, the product chime) start on the event's frame. Place them by onset, not by peak: an effect placed by its peak lands about 0.2 s early.
- **Swelling sounds** (whooshes, rises): the start time subtracts the time to peak, so the peak lands on the beat.
- **Impact timing**: the impact lands in the silence between two spoken phrases, 0.18–0.30 s before the next name is spoken.
- **Product sounds**: a notification's sound peaks on the frame where the banner first shows in full.
- **Ducking**: effects sit 3 dB under the voice for 0.6 s at the start of every key word.
- **Peaks**: the whole mix peaks below −1 dBFS. Starting targets:

  | Effect | Target |
  |---|---|
  | whoosh | −14 dBFS |
  | swish | −16 dBFS |
  | impact | −5 to −9 dBFS |
  | low zoom | −14 dBFS |
  | logo | −10 dBFS |

## Marks file

`sfx/marks.txt` has one line per sound. Fields are separated by spaces or tabs.

- **Effect line**: `<start_s> <name> <peak_dBFS>`. For example, `8.435 chime -16` plays `chime.wav` from the marks file's folder at 8.435 s, scaled so its peak is −16 dBFS.
- **Duck line**: `<start_s> duck <margin_dB>`. For example, `4.700 duck -3` holds the effects 3 dB under the voice, from 30 ms before that time and for 0.6 s, with at most 24 dB of reduction.
- **Comments and blanks**: anything after `#` is ignored, and blank lines are skipped. Use comments to note each line's frame and event.
- **Number formats**: comma decimals (`0,573`) and the Unicode minus (`−14`) are accepted.

```
0.000   whoosh-1   -14
0.573   low-zoom   -14
4.700   duck       -3
8.435   chime      -16
11.267  impact-1   -5.1
11.267  confetti   -15.1
```

To time a line:
1. Find the event's frame in `script.md`.
2. For an attack sound, the start time is the frame divided by fps.
3. For a swelling sound, subtract the effect's own time to peak, measured on the WAV.

## Mix and mux

```bash
./mix ../narration/<take>.mp3 ../sfx/marks.txt ../sfx/track.wav <duration>
```

```bash
./mux ../out/<name>-silent.mp4 ../sfx/track.wav ../out/<name>.mp4
```

`mix` writes a mono, 44.1 kHz track:
- the voice goes in untouched: gain 1, no EQ, no compression;
- each effect has its DC offset removed, with fades of 3 ms in and 10 ms out so it never clicks;
- where the sum would pass −1 dBFS, only the effects come down.

`mix` reads the effect WAVs from the marks file's folder and writes exactly `<duration>` seconds.

`mux`:
- copies the video without re-encoding;
- writes the audio as AAC at 128 kbps;
- removes the MP3 encoder delay. Without that step, the voice lands 13 ms late.

The audio must not be longer than the video. A shorter track is padded with silence.
