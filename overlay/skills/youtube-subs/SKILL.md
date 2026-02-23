---
name: youtube-subs
description: Download subtitles from YouTube videos or playlists in prioritized order: original-language subtitles first, then Korean subtitles (manual and auto-generated included).
metadata: { "openclaw": { "requires": { "bins": ["python", "yt-dlp"] } } }
allowed-tools: ["shell_command"]
---

# YouTube Subtitles

Download subtitles from a YouTube video or playlist with this priority:

1. Original language subtitles (manual first if present, then auto-generated)
2. Korean subtitles (manual first if present, then auto-generated)

## Usage

```bash
python {baseDir}/scripts/download_subs.py "<youtube-url>" --out "./subs"
```

Options:

- `--out <dir>`: output directory (default: `./subs`)
- `--format <fmt>`: subtitle format preference (`vtt/srt/best`, default)

## Notes

- Works for both single videos and playlists.
- Downloads subtitle files only (`--skip-download`), no video media.
- If original language cannot be inferred, falls back to `en` then `ko`.
