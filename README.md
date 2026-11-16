# Motion Designer

A Claude Code skill that directs and produces short motion videos, such as trailers, product reveals, launch teasers and animated ads, from a brief to a verified MP4.

What it does:
- builds a reference board for you to pick from;
- writes a frame-accurate script with narration;
- animates a deterministic HTML and Three.js scene, then renders it frame by frame in Chrome;
- encodes H.264 1080p60 and mixes voice and sound effects in sync;
- runs a reviewer and a judge loop until the cut passes;
- stops for your approval at each preview.

## Install

As a plugin:

```
/plugin marketplace add bragadzz/motion-designer
/plugin install motion-designer@bragadzz
```

As a personal skill:

```bash
git clone https://github.com/bragadzz/motion-designer.git /tmp/motion-designer && cp -R /tmp/motion-designer/skills/motion-designer ~/.claude/skills/
```

## Requirements

- macOS with the Xcode command line tools
- Node 20.11+ and Google Chrome
- Optional, for narration and sound effects: an ElevenLabs API key in `~/.config/elevenlabs/key`

## Use

Ask Claude Code for a video, for example:

> Make a 20 s narrated launch trailer for our new card, 1080p60.

You can also run the skill directly with `/motion-designer` (as a personal skill) or `/motion-designer:motion-designer` (as a plugin).

## License

MIT
