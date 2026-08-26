"""Direct Groq chat-completions transport for the PowerShell ingestion script.

Uses Python's HTTPS stack and deliberately ignores proxy environment variables.
The request, including its API key, is accepted only on standard input so it
does not appear in a process command line.
"""

from __future__ import annotations

import base64
import json
import re
import sys
import urllib.error
import urllib.request


def retry_seconds(headers: object) -> int:
    for name in (
        "retry-after",
        "x-ratelimit-reset-tokens",
        "x-ratelimit-reset-requests",
    ):
        value = headers.get(name, "") if headers else ""
        if re.fullmatch(r"\s*\d+(?:\.\d+)?\s*", value):
            return max(1, int(float(value)))
        match = re.fullmatch(r"\s*(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?\s*", value)
        if match:
            minutes = float(match.group(1) or 0)
            seconds = float(match.group(2) or 0)
            return max(1, int(minutes * 60 + seconds + 0.999))
    return 60


def emit(status: int, body: str, headers: object = None) -> None:
    print(
        json.dumps(
            {
                "status": status,
                "body": body,
                "retry_seconds": retry_seconds(headers),
            },
            # PowerShell's redirected stdout can use a legacy Windows code
            # page. Escaping non-ASCII keeps the transport envelope reliable;
            # ConvertFrom-Json restores the original Unicode string locally.
            ensure_ascii=True,
        )
    )


def main() -> None:
    request_input = json.loads(base64.b64decode(sys.stdin.buffer.read()).decode("utf-8"))
    payload = {
        "model": request_input["model"],
        "reasoning_effort": request_input["reasoning_effort"],
        "temperature": 0,
        "max_completion_tokens": 5000,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": request_input["system"]},
            {"role": "user", "content": request_input["user"]},
        ],
    }
    request = urllib.request.Request(
        "https://api.groq.com/openai/v1/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {request_input['api_key']}",
            "Content-Type": "application/json",
            # Groq's edge rejects Python's default urllib user agent (CF 1010).
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Musa-KB-Ingestor/1.0",
        },
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=request_input.get("timeout_seconds", 90)) as response:
            emit(response.status, response.read().decode("utf-8"), response.headers)
    except urllib.error.HTTPError as error:
        emit(error.code, error.read().decode("utf-8", errors="replace"), error.headers)
    except Exception as error:  # The PowerShell layer handles 599 as a retryable transport failure.
        emit(599, f"{type(error).__name__}: {error}", None)


if __name__ == "__main__":
    main()
