"""Shared, cross-platform helpers for the Musa KB maintenance scripts."""

from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SCRIPT_ROOT = Path(__file__).resolve().parent
DEFAULT_REPOSITORY_ROOT = SCRIPT_ROOT.parent


def repository_root(value: str | os.PathLike[str] | None) -> Path:
    return Path(value).expanduser().resolve() if value else DEFAULT_REPOSITORY_ROOT


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def write_jsonl(path: Path, rows: Iterable[Any], *, append: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a" if append else "w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def word_count(text: str) -> int:
    return len(re.findall(r"\S+", text))


def env_value(path: Path, name: str) -> str | None:
    if not path.is_file():
        return None
    expression = re.compile(rf"^\s*{re.escape(name)}\s*=(.*)$")
    for line in path.read_text(encoding="utf-8").splitlines():
        match = expression.match(line)
        if match:
            value = match.group(1).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            return value
    return None


def display_topic_title(repo: Path, topic_id: int, canonical_title: str) -> str:
    """Add the configured decorative emoji without changing the canonical title."""
    path = repo / "artifacts" / "topic-emojis.json"
    try:
        emoji = json.loads(path.read_text(encoding="utf-8")).get(str(topic_id), "")
    except FileNotFoundError:
        emoji = ""
    if not isinstance(emoji, str):
        raise ValueError(f"Emoji for topic {topic_id} must be a string.")
    return f"{emoji} {canonical_title}".strip()
