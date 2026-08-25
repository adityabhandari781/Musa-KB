"""Transcribe incoming media without publishing it to data/media prematurely."""

import json
import re
import shutil
import subprocess
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path

import imageio_ffmpeg
import numpy as np
import torch
import whisper
import whisper.audio


REPO_ROOT = Path(__file__).resolve().parent.parent
INCOMING_MEDIA_DIR = REPO_ROOT / "incoming" / "media"
TRANSCRIPTS_DIR = REPO_ROOT / "incoming" / "transcripts"
ARCHIVED_MEDIA_DIR = REPO_ROOT / "data" / "media"
MEDIA_INDEX_PATH = TRANSCRIPTS_DIR / "media-index.jsonl"
TARGET_PREFIXES = ("audio", "video", "video_note", "voice")
MODEL = "small"
LANGUAGE = "English"
FORCE = False


def patch_whisper_ffmpeg() -> None:
    ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
    original = whisper.audio.load_audio

    @wraps(original)
    def load_audio(file: str, sr: int = whisper.audio.SAMPLE_RATE) -> np.ndarray:
        result = subprocess.run([ffmpeg_exe, "-nostdin", "-threads", "0", "-i", file, "-f", "s16le", "-ac", "1", "-acodec", "pcm_s16le", "-ar", str(sr), "-"], capture_output=True, check=True)
        return np.frombuffer(result.stdout, np.int16).flatten().astype(np.float32) / 32768.0

    whisper.audio.load_audio = load_audio
    whisper.load_audio = load_audio


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
        relative = f"incoming/transcripts/{filename}"
        candidate = TRANSCRIPTS_DIR / filename
        if relative not in occupied and not candidate.exists():
            return candidate
        suffix += 1


def target_media() -> list[Path]:
    if not INCOMING_MEDIA_DIR.exists():
        return []
    return sorted((path for path in INCOMING_MEDIA_DIR.iterdir() if path.is_file() and path.name.lower().startswith(TARGET_PREFIXES)), key=lambda path: path.name.lower())


def archive_nontranscribable_media() -> int:
    """Archive media that cannot produce a text source (photos, GIFs, stickers)."""
    ARCHIVED_MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    moved = 0
    for media_path in INCOMING_MEDIA_DIR.iterdir() if INCOMING_MEDIA_DIR.exists() else []:
        if not media_path.is_file() or media_path.name.lower().startswith(TARGET_PREFIXES):
            continue
        target = ARCHIVED_MEDIA_DIR / media_path.name
        if target.exists():
            stem, suffix, index = media_path.stem, media_path.suffix, 1
            while target.exists():
                target = ARCHIVED_MEDIA_DIR / f"{stem}_{index}{suffix}"
                index += 1
        shutil.move(str(media_path), str(target))
        moved += 1
    return moved


def main() -> None:
    patch_whisper_ffmpeg()
    TRANSCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
    files, indexed = target_media(), read_index()
    pending = [path for path in files if f"incoming/media/{path.name}" not in indexed or FORCE]
    if not pending:
        print(f"No untranscribed incoming audio/video files. Archived {archive_nontranscribable_media()} non-transcribable media file(s).")
        return
    use_fp16 = torch.cuda.is_available()
    print(f"Loading Whisper model: {MODEL}; transcribing {len(pending)} file(s).")
    model = whisper.load_model(MODEL)
    failures = []
    for number, media_path in enumerate(pending, start=1):
        media_relative_path = f"incoming/media/{media_path.name}"
        target = next_transcript_path(media_path, indexed)
        print(f"[{number}/{len(pending)}] Transcribing {media_path.name} -> {target.name}")
        try:
            result = model.transcribe(str(media_path), language=LANGUAGE, fp16=use_fp16)
            target.write_text(((result.get("text") or "").strip() + "\n"), encoding="utf-8")
            row = {"media_relative_path": media_relative_path, "transcript_relative_path": f"incoming/transcripts/{target.name}", "created_at": datetime.now(timezone.utc).isoformat()}
            append_index(row)
            indexed[media_relative_path] = row
        except Exception as exc:
            failures.append((media_path, exc))
            print(f"    Failed: {exc}")
    archived = archive_nontranscribable_media()
    print(f"Transcription complete: {len(pending) - len(failures)} succeeded, {len(failures)} failed. Archived {archived} non-transcribable media file(s); transcribed media remain in incoming/media until their transcripts are ingested.")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
