"""Use Groq to review uncertain heuristic passage classifications."""

from __future__ import annotations

import argparse
import json

from groq_client import PairRotator, completion, content, retry_seconds
from kb_common import env_value, read_jsonl, repository_root, utc_now, write_jsonl


SYSTEM_PREFIX = '''You independently review knowledge-base topic assignments. Use only the supplied 25 topic definitions and passage text. Return JSON only: {"results":[{"passage_id":"P000001","primary_topic_id":1,"secondary_topic_ids":[2],"confidence":"high|medium|low","rationale":"brief source-grounded reason","routing":"substantive|non_substantive"}]}. Return every requested passage_id exactly once. Topic 25 is only for promotion, banter, low-context material, or commentary that has no broader lesson. Do not rewrite text or add facts.'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    parser.add_argument("--maximum-passages-per-request", type=int, default=1)
    args = parser.parse_args()
    repo = repository_root(args.repository_root); build = repo / "build"
    source = build / "passage-manifest.jsonl"; env = repo / ".env"
    if not source.is_file() or not env.is_file(): raise FileNotFoundError("Missing .env or build/passage-manifest.jsonl.")
    keys = []
    for name in ["GROQ_API_KEY", "GROQ_API_KEY2", "GROQ_API_KEY3", "GROQ_API_KEY4", "GROQ_API_KEY5"]:
        if not (value := env_value(env, name)): raise ValueError(f"Missing {name} in .env.")
        keys.append(value)
    all_rows = read_jsonl(source); flagged = [row for row in all_rows if row["review_required"]]
    checkpoint = build / "llm-topic-review-checkpoint.jsonl"
    completed = {row["passage_id"] for row in read_jsonl(checkpoint)} if checkpoint.is_file() else set()
    pending = [row for row in flagged if row["passage_id"] not in completed]
    system = SYSTEM_PREFIX + "\n\nTOPICS:\n" + (repo / "artifacts" / "topics.md").read_text(encoding="utf-8")
    rotator = PairRotator(keys, ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.6-27b"])
    log = build / "groq-topic-review-requests.jsonl"
    for start in range(0, len(pending), args.maximum_passages_per_request):
        batch = pending[start:start + args.maximum_passages_per_request]
        user = json.dumps({"passages": [{"passage_id": row["passage_id"], "text": row["text"]} for row in batch]}, ensure_ascii=False, separators=(",", ":"))
        while True:
            pair = rotator.next()
            response = completion(pair["key"], pair["model"], system, user, max_tokens=2400, json_output=True)
            write_jsonl(log, [{"timestamp": utc_now(), "key_slot": pair["slot"], "model": pair["model"], "status": response.status, "passage_ids": [row["passage_id"] for row in batch]}], append=True)
            if response.status == 429:
                rotator.cool(pair, retry_seconds(response.headers)); continue
            if not 200 <= response.status < 300:
                rotator.cool(pair, 60 if response.status >= 500 else 300); continue
            try:
                rows = json.loads(content(response))["results"]
                expected = {row["passage_id"] for row in batch}
                if len(rows) != len(batch) or {row.get("passage_id") for row in rows} != expected: raise ValueError("Groq returned an incomplete or mismatched review batch.")
                if any(int(row["primary_topic_id"]) not in range(1, 26) or any(int(item) not in range(1, 25) for item in row.get("secondary_topic_ids", [])) for row in rows): raise ValueError("Invalid topic IDs.")
            except Exception as error:
                print(f"Malformed review from key slot {pair['slot']} on {pair['model']}: {error}")
                rotator.cool(pair, 300); continue
            originals = {row["passage_id"]: row for row in batch}
            output = [{"passage_id": row["passage_id"], "source_id": originals[row["passage_id"]]["source_id"], "primary_topic_id": int(row["primary_topic_id"]), "secondary_topic_ids": row.get("secondary_topic_ids", []), "confidence": row.get("confidence"), "rationale": row.get("rationale"), "routing": row.get("routing", "non_substantive" if int(row["primary_topic_id"]) == 25 else "substantive"), "heuristic_primary_topic_id": originals[row["passage_id"]]["primary_topic_id"], "reviewed_model": pair["model"], "key_slot": pair["slot"], "reviewed_at": utc_now()} for row in rows]
            write_jsonl(checkpoint, output, append=True); completed.update(row["passage_id"] for row in output); rotator.advance(pair)
            print(f"Reviewed {len(batch)} passage(s) with key slot {pair['slot']} on {pair['model']}. Progress: {len(completed)}/{len(flagged)}.")
            break
    print("LLM topic review complete.")


if __name__ == "__main__":
    main()
