#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from pathlib import Path


def run_json(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "command failed")
    return json.loads(p.stdout)


def run(cmd):
    p = subprocess.run(cmd)
    if p.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}")


def video_urls(url):
    info = run_json(["yt-dlp", "--dump-single-json", "--flat-playlist", url])
    entries = info.get("entries")
    if not entries:
        return [url]
    urls = []
    for e in entries:
        vid = e.get("id")
        if vid:
            urls.append(f"https://www.youtube.com/watch?v={vid}")
    return urls or [url]


def guess_lang(info):
    lang = info.get("language")
    if lang:
        return lang.split("-")[0]

    for key in ("subtitles", "automatic_captions"):
        obj = info.get(key) or {}
        for code in obj.keys():
            if code and code != "live_chat":
                return code.split("-")[0]
    return "en"


def download_for_video(url, out_dir, sub_format):
    info = run_json(["yt-dlp", "--dump-single-json", "--skip-download", url])
    orig = guess_lang(info)
    sub_langs = f"{orig}.*,ko.*,{orig},ko"

    cmd = [
        "yt-dlp",
        "--skip-download",
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs",
        sub_langs,
        "--sub-format",
        sub_format,
        "-P",
        str(out_dir),
        "-o",
        "%(playlist_title,NA)s/%(title)s [%(id)s].%(ext)s",
        url,
    ]
    run(cmd)


def main():
    parser = argparse.ArgumentParser(description="Download YouTube subtitles with language priority")
    parser.add_argument("url", help="YouTube video or playlist URL")
    parser.add_argument("--out", default="./subs", help="output directory")
    parser.add_argument("--format", default="vtt/srt/best", help="subtitle format preference")
    args = parser.parse_args()

    out_dir = Path(args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    urls = video_urls(args.url)
    for u in urls:
        print(f"[youtube-subs] downloading subtitles for: {u}")
        download_for_video(u, out_dir, args.format)

    print(f"[youtube-subs] done. output: {out_dir}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
