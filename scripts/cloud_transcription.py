"""Transcribe incoming audio/video with Groq Whisper Large V3 Turbo.

Successful transcripts are published to data/incoming/transcripts. Their associated
media remains in data/incoming/media until the PowerShell ingestor moves both into
the durable data/ archive together.
"""

import json
import mimetypes
import os
import re
import shutil
import subprocess
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import requests
from dotenv import load_dotenv
import imageio_ffmpeg


REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")
INCOMING_MEDIA_DIR = REPO_ROOT/ "data" / "incoming" / "media"
TRANSCRIPTS_DIR = REPO_ROOT/ "data" / "incoming" / "transcripts"
ARCHIVED_MEDIA_DIR = REPO_ROOT / "data" / "media"
MEDIA_INDEX_PATH = TRANSCRIPTS_DIR / "media-index.jsonl"
API_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
MODEL = "whisper-large-v3-turbo"
LANGUAGE = "en"
TARGET_PREFIXES = ("audio", "video", "video_note", "voice")
KEY_NAMES = ("GROQ_API_KEY", "GROQ_API_KEY2", "GROQ_API_KEY3", "GROQ_API_KEY4", "GROQ_API_KEY5", "GROQ_API_KEY6")
VIDEO_EXTENSIONS = {".mp4", ".mpeg", ".mpg", ".mov", ".webm"}


def read_index() -> dict[str, dict]:
    if not MEDIA_INDEX_PATH.exists():
        return {}
    rows: dict[str, dict] = {}
    for line in MEDIA_INDEX_PATH.read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            rows[row["media_relative_path"]] = row
    return rows


def append_index(row: dict) -> None:
    with MEDIA_INDEX_PATH.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(row, separators=(",", ":")) + "\n")


def transcript_stem(media_path: Path) -> str:
    match = re.search(r"(?:voice|video_note|video|audio)_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:_\d+)?)", media_path.stem, re.IGNORECASE)
    return match.group(1) if match else media_path.stem


def next_transcript_path(media_path: Path, indexed: dict[str, dict]) -> Path:
    base, suffix = transcript_stem(media_path), 0
    occupied = {row["transcript_relative_path"] for row in indexed.values()}
    while True:
        filename = f"{base}{'' if suffix == 0 else f'_{suffix}'}.txt"
        candidate = TRANSCRIPTS_DIR / filename
        if f"data/incoming/transcripts/{filename}" not in occupied and not candidate.exists():
            return candidate
        suffix += 1


def target_media() -> list[Path]:
    if not INCOMING_MEDIA_DIR.exists():
        return []
    return sorted((path for path in INCOMING_MEDIA_DIR.iterdir() if path.is_file() and path.name.lower().startswith(TARGET_PREFIXES)), key=lambda path: path.name.lower())


def archive_nontranscribable_media() -> int:
    ARCHIVED_MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    moved = 0
    for media_path in INCOMING_MEDIA_DIR.iterdir() if INCOMING_MEDIA_DIR.exists() else []:
        if not media_path.is_file() or media_path.name.lower().startswith(TARGET_PREFIXES):
            continue
        target = ARCHIVED_MEDIA_DIR / media_path.name
        index = 1
        while target.exists():
            target = ARCHIVED_MEDIA_DIR / f"{media_path.stem}_{index}{media_path.suffix}"
            index += 1
        shutil.move(str(media_path), str(target))
        moved += 1
    return moved


def wait_seconds(response: requests.Response) -> int:
    for name in ("retry-after", "x-ratelimit-reset-tokens", "x-ratelimit-reset-requests"):
        value = response.headers.get(name, "")
        if value.isdigit():
            return max(1, int(value))
        match = re.fullmatch(r"(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?", value.strip())
        if match:
            return max(1, int((int(match.group(1) or 0) * 60) + float(match.group(2) or 0)))
    return 60


def groq_keys() -> list[tuple[str, str]]:
    pairs = [(name, os.getenv(name, "").strip()) for name in KEY_NAMES]
    missing = [name for name, value in pairs if not value]
    if missing:
        raise SystemExit(f"Missing Groq key(s) in .env: {', '.join(missing)}")
    return pairs


@contextmanager
def audio_upload_path(media_path: Path):
    """Yield the original audio file or a temporary audio-only MP3 for video."""
    if media_path.suffix.lower() not in VIDEO_EXTENSIONS:
        yield media_path
        return

    with tempfile.TemporaryDirectory(prefix="musa-groq-audio-") as temporary_directory:
        output = Path(temporary_directory) / f"{media_path.stem}.mp3"
        command = [
            imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-i", str(media_path),
            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "libmp3lame", "-b:a", "64k", str(output),
        ]
        try:
            subprocess.run(command, capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(f"Could not extract audio from {media_path.name}: {exc.stderr.strip()}") from exc
        if not output.exists() or output.stat().st_size == 0:
            raise RuntimeError(f"Audio extraction produced no audio for {media_path.name}.")
        yield output


def transcribe(media_path: Path, keys: list[tuple[str, str]]) -> tuple[str, str]:
    """Try keys in order; if all rate-limit/timeout, wait for the shortest slot."""
    states = [{"name": name, "key": key, "available": 0.0, "disabled": False} for name, key in keys]
    errors: list[str] = []
    with audio_upload_path(media_path) as upload_path:
        if upload_path != media_path:
            print(f"Extracted audio-only upload for {media_path.name}: {upload_path.name}.")
        while True:
            now = time.monotonic()
            available = next((state for state in states if not state["disabled"] and state["available"] <= now), None)
            if available is None:
                usable = [state for state in states if not state["disabled"]]
                if not usable:
                    raise RuntimeError("All Groq keys failed: " + " | ".join(errors))
                soonest = min(usable, key=lambda state: state["available"])
                delay = max(1.0, soonest["available"] - now)
                print(f"All Groq keys are cooling down; waiting {delay:.0f}s for {soonest['name']}.")
                time.sleep(delay)
                continue
            print(f"Uploading {upload_path.name} with {available['name']} / {MODEL}.")
            try:
                with upload_path.open("rb") as handle:
                    response = requests.post(
                        API_URL,
                        headers={"Authorization": f"Bearer {available['key']}"},
                        data={"model": MODEL, "language": LANGUAGE, "response_format": "json", "temperature": "0"},
                        files={"file": (upload_path.name, handle, mimetypes.guess_type(upload_path.name)[0] or "application/octet-stream")},
                        timeout=180,
                    )
            except requests.Timeout:
                available["available"] = time.monotonic() + 60
                errors.append(f"{available['name']}: timeout")
                continue
            except requests.RequestException as exc:
                available["available"] = time.monotonic() + 60
                errors.append(f"{available['name']}: {exc}")
                continue
            if response.ok:
                text = response.json().get("text", "").strip()
                return text, available["name"]
            if response.status_code == 429 or response.status_code >= 500:
                delay = wait_seconds(response)
                available["available"] = time.monotonic() + delay
                errors.append(f"{available['name']}: HTTP {response.status_code}, retry in {delay}s")
                continue
            available["disabled"] = True
            errors.append(f"{available['name']}: HTTP {response.status_code}")


def main() -> None:
    files = target_media()
    if not files:
        print(f"No incoming audio/video files. Archived {archive_nontranscribable_media()} non-transcribable media file(s).")
        return
    TRANSCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
    indexed, keys = read_index(), groq_keys()
    pending = [path for path in files if f"data/incoming/media/{path.name}" not in indexed]
    failures = []
    for number, media_path in enumerate(pending, start=1):
        media_relative_path = f"data/incoming/media/{media_path.name}"
        target = next_transcript_path(media_path, indexed)
        try:
            text, key_name = transcribe(media_path, keys)
            target.write_text(text + "\n", encoding="utf-8")
            row = {"media_relative_path": media_relative_path, "transcript_relative_path": f"data/incoming/transcripts/{target.name}", "model": MODEL, "api_key_name": key_name, "created_at": datetime.now(timezone.utc).isoformat()}
            append_index(row)
            indexed[media_relative_path] = row
        except Exception as exc:
            failures.append((media_path, exc))
            print(f"[{number}/{len(pending)}] Failed {media_path.name}: {exc}")
    archived = archive_nontranscribable_media()
    print(f"Cloud transcription complete: {len(pending) - len(failures)} succeeded, {len(failures)} failed, {archived} non-transcribable media archived.")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
