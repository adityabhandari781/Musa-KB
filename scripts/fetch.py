"""Fetch new Telegram messages into the repository's incoming queues.

Files are staged under data/incoming/temp and become visible to later pipeline stages
only after every configured channel has finished downloading successfully.
"""

import asyncio
import os
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv
from telethon import TelegramClient, utils
from telethon.errors import FloodWaitError


REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(REPO_ROOT / ".env")

IST = timezone(timedelta(hours=5, minutes=30))
CHANNELS = ["@MusaRAW", "@UnchainedReality"]
INCOMING_DIR = REPO_ROOT / "data" / "incoming"
TEMP_DIR = INCOMING_DIR / "temp"
TEMP_MEDIA_DIR = TEMP_DIR / "media"
TEMP_TEXTS_DIR = TEMP_DIR / "texts"
MEDIA_DIR = INCOMING_DIR / "media"
TEXT_DIR = INCOMING_DIR / "texts"
# Telethon stores telegram_export.session beside the repository files, as requested.
SESSION = str(REPO_ROOT / "telegram_export")
# Keep using the existing export cursor so moving the incoming queue does not
# cause a first-run re-download of the historical channel archive.
LAST_TIMESTAMP_FILE = REPO_ROOT / "data" / "last_timestamp.txt"
TIMESTAMP_FORMAT = "%Y-%m-%d_%H-%M-%S"
LIMIT = None
START_DATE = "14-04-2026"


def get_api_credentials() -> tuple[int, str]:
    api_id, api_hash = os.getenv("TELEGRAM_API_ID"), os.getenv("TELEGRAM_API_HASH")
    if not api_id or not api_hash:
        raise SystemExit("Missing TELEGRAM_API_ID or TELEGRAM_API_HASH in this repository's .env file.")
    try:
        return int(api_id), api_hash
    except ValueError as exc:
        raise SystemExit("TELEGRAM_API_ID must be an integer.") from exc


def get_start_datetime() -> datetime:
    if LAST_TIMESTAMP_FILE.exists():
        value = LAST_TIMESTAMP_FILE.read_text(encoding="utf-8").splitlines()[0].strip()
        try:
            return datetime.strptime(value, TIMESTAMP_FORMAT).replace(tzinfo=IST) + timedelta(seconds=1)
        except ValueError as exc:
            raise SystemExit(f"Invalid timestamp in {LAST_TIMESTAMP_FILE}.") from exc
    try:
        return datetime.strptime(START_DATE, "%d-%m-%Y").replace(tzinfo=IST)
    except ValueError as exc:
        raise SystemExit("START_DATE must be DD-MM-YYYY.") from exc


def unique_path(directory: Path, base: str, extension: str, counts: dict[str, int]) -> Path:
    key, index = f"{base}{extension}", counts.get(f"{base}{extension}", 0)
    while True:
        suffix = "" if index == 0 else f"_{index}"
        candidate = directory / f"{base}{suffix}{extension}"
        if not candidate.exists():
            counts[key] = index + 1
            return candidate
        index += 1


def reset_directory(directory: Path) -> None:
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True, exist_ok=True)


def move_files(source: Path, destination: Path) -> int:
    destination.mkdir(parents=True, exist_ok=True)
    counts: dict[str, int] = {}
    moved = 0
    for path in sorted(source.iterdir()):
        if not path.is_file():
            continue
        target = unique_path(destination, path.stem, path.suffix, counts)
        shutil.move(str(path), str(target))
        moved += 1
    return moved


def media_type_name(message) -> str:
    if message.photo: return "photo"
    if message.voice: return "voice"
    if message.video_note: return "video_note"
    if message.gif: return "gif"
    if message.sticker: return "sticker"
    if message.video: return "video"
    if message.audio: return "audio"
    if message.document: return "document"
    return "media"


async def download_media(client: TelegramClient, message, output: Path, counts: dict[str, int]) -> None:
    if not message.media:
        return
    local_time = message.date.astimezone(IST) if message.date else datetime.now(IST)
    target = unique_path(output, f"{media_type_name(message)}_{local_time.strftime(TIMESTAMP_FORMAT)}", utils.get_extension(message.media) or "", counts)
    while True:
        try:
            await client.download_media(message, file=str(target))
            return
        except FloodWaitError as exc:
            print(f"Telegram media rate limit; waiting {int(exc.seconds) + 1} seconds.")
            await asyncio.sleep(int(exc.seconds) + 1)


def save_text(message, output: Path, counts: dict[str, int]) -> None:
    if not message.message:
        return
    local_time = message.date.astimezone(IST) if message.date else datetime.now(IST)
    target = unique_path(output, local_time.strftime(TIMESTAMP_FORMAT), ".txt", counts)
    target.write_text(message.message, encoding="utf-8")


async def export_channel(client: TelegramClient, channel: str, start: datetime, media_counts: dict[str, int], text_counts: dict[str, int]) -> tuple[int, datetime | None]:
    entity = await client.get_entity(channel)
    count, last_time = 0, None
    async for message in client.iter_messages(entity, limit=LIMIT, reverse=True):
        if not message.date or message.date < start:
            continue
        await download_media(client, message, TEMP_MEDIA_DIR, media_counts)
        save_text(message, TEMP_TEXTS_DIR, text_counts)
        last_time = message.date
        count += 1
    print(f"Fetched {count} messages from {getattr(entity, 'title', channel)}.")
    return count, last_time


async def main_async() -> None:
    api_id, api_hash = get_api_credentials()
    start = get_start_datetime()
    reset_directory(TEMP_MEDIA_DIR)
    reset_directory(TEMP_TEXTS_DIR)
    media_counts: dict[str, int] = {}
    text_counts: dict[str, int] = {}
    client = TelegramClient(SESSION, api_id, api_hash)
    await client.start()
    try:
        latest, total = None, 0
        for channel in CHANNELS:
            count, last_time = await export_channel(client, channel, start, media_counts, text_counts)
            total += count
            if last_time and (latest is None or last_time > latest):
                latest = last_time
        moved_texts = move_files(TEMP_TEXTS_DIR, TEXT_DIR)
        moved_media = move_files(TEMP_MEDIA_DIR, MEDIA_DIR)
        shutil.rmtree(TEMP_DIR, ignore_errors=True)
        if latest:
            LAST_TIMESTAMP_FILE.write_text(latest.astimezone(IST).strftime(TIMESTAMP_FORMAT) + "\n", encoding="utf-8")
        print(f"Fetch complete: {total} messages; published {moved_texts} texts and {moved_media} media files.")
    finally:
        await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main_async())
