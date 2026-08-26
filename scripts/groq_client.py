"""Small dependency-free Groq chat-completions client shared by Python scripts."""

from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


def retry_seconds(headers: Any) -> int:
    for name in ("retry-after", "x-ratelimit-reset-tokens", "x-ratelimit-reset-requests"):
        value = headers.get(name, "") if headers else ""
        if re.fullmatch(r"\s*\d+(?:\.\d+)?\s*", value): return max(1, int(float(value) + .999))
        match = re.fullmatch(r"\s*(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?\s*", value)
        if match: return max(1, int(float(match.group(1) or 0) * 60 + float(match.group(2) or 0) + .999))
    return 60


@dataclass
class Response:
    status: int
    body: str
    headers: Any = None


def completion(api_key: str, model: str, system: str, user: str, *, max_tokens: int, temperature: float = 0, json_output: bool = False, timeout: int = 90) -> Response:
    payload: dict[str, Any] = {"model": model, "reasoning_effort": "default" if model.startswith("qwen/") else "low", "temperature": temperature, "max_completion_tokens": max_tokens, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    if json_output: payload["response_format"] = {"type": "json_object"}
    request = urllib.request.Request("https://api.groq.com/openai/v1/chat/completions", data=json.dumps(payload, ensure_ascii=False).encode("utf-8"), headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json", "User-Agent": "Musa-KB/1.0"}, method="POST")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as response:
            return Response(response.status, response.read().decode("utf-8"), response.headers)
    except urllib.error.HTTPError as error:
        return Response(error.code, error.read().decode("utf-8", errors="replace"), error.headers)
    except Exception as error:
        return Response(599, f"{type(error).__name__}: {error}")


def content(response: Response) -> str:
    return json.loads(response.body)["choices"][0]["message"]["content"]


class PairRotator:
    """Rotate model/key pairs and only wait when every pair is cooling down."""

    def __init__(self, keys: list[str], models: list[str]) -> None:
        self.pairs = [{"key": key, "slot": slot, "model": model, "available": 0.0, "disabled": False} for slot, key in enumerate(keys, 1) for model in models]
        self.cursor = 0

    def next(self) -> dict[str, Any]:
        while True:
            now = time.monotonic()
            for offset in range(len(self.pairs)):
                index = (self.cursor + offset) % len(self.pairs)
                if not self.pairs[index]["disabled"] and self.pairs[index]["available"] <= now:
                    self.cursor = index
                    return self.pairs[index]
            usable = [pair for pair in self.pairs if not pair["disabled"]]
            if not usable:
                raise RuntimeError("No configured Groq key/model pair remains usable.")
            seconds = max(1, int(min(pair["available"] for pair in usable) - now + .999))
            print(f"All key/model pairs are cooling down; waiting {seconds} second(s).")
            time.sleep(seconds)

    def cool(self, pair: dict[str, Any], seconds: int) -> None:
        pair["available"] = time.monotonic() + max(1, seconds)
        self.cursor = (self.pairs.index(pair) + 1) % len(self.pairs)

    def advance(self, pair: dict[str, Any]) -> None:
        self.cursor = (self.pairs.index(pair) + 1) % len(self.pairs)

    def disable(self, pair: dict[str, Any]) -> None:
        pair["disabled"] = True
        self.cursor = (self.pairs.index(pair) + 1) % len(self.pairs)
