"""Ask Groq for semantic source-passage boundaries and persist resumable results."""

from __future__ import annotations

import argparse
import json
import re
import time

from groq_client import completion, content, retry_seconds
from kb_common import env_value, read_jsonl, repository_root, utc_now, word_count, write_json, write_jsonl


def atomic_units(text: str, maximum: int) -> list[dict]:
    flat = re.sub(r"\s+", " ", text).strip()
    sentences = [item.strip() for item in re.findall(r"(?s).+?(?:[.!?]+(?=\s|$)|$)", flat) if item.strip()]
    units = []
    for sentence in sentences:
        for clause in filter(None, re.split(r"(?<=[,;:])\s+", sentence)):
            words = clause.split()
            units.extend(" ".join(words[index:index + maximum]) for index in range(0, len(words), maximum))
    return [{"index": index, "text": text} for index, text in enumerate(units)]


def ranges_from_response(body: str, batch: list[dict]) -> list[dict]:
    value = json.loads(body)["choices"][0]["message"]["content"]
    value = re.sub(r"^```(?:json)?\s*|\s*```$", "", value.strip())
    results = json.loads(value).get("results", [])
    by_id = {}
    for result in results:
        identifier = result.get("source_id")
        if not identifier: raise ValueError("The model returned a missing source_id.")
        if identifier in by_id and by_id[identifier].get("passages") != result.get("passages"): raise ValueError(f"The model returned conflicting duplicate ranges for {identifier}.")
        by_id[identifier] = result
    validated = []
    for source in batch:
        if source["source_id"] not in by_id: raise ValueError(f"The model omitted {source['source_id']}.")
        unit_count = len(source["units"])
        if unit_count == 1: validated.append({"source": source, "ranges": [{"start": 0, "end": 0}]}); continue
        ranges = by_id[source["source_id"]].get("passages", [])
        if not ranges: raise ValueError(f"The model returned no passages for {source['source_id']}.")
        if len(ranges) == 1 and int(ranges[0].get("start", -1)) == 0: validated.append({"source": source, "ranges": [{"start": 0, "end": unit_count - 1}]}); continue
        expected, contiguous = 0, []
        for entry in ranges:
            end = min(int(entry["end"]), unit_count - 1)
            if end < expected: continue
            contiguous.append({"start": expected, "end": end}); expected = end + 1
        if expected < unit_count: contiguous.append({"start": expected, "end": unit_count - 1})
        validated.append({"source": source, "ranges": contiguous})
    return validated


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    parser.add_argument("--maximum-batch-words", type=int, default=1200)
    parser.add_argument("--maximum-sources-per-request", type=int, default=1)
    parser.add_argument("--maximum-atomic-unit-words", type=int, default=80)
    args = parser.parse_args()
    repo = repository_root(args.repository_root); build = repo / "build"; env, manifest = repo / ".env", build / "source-manifest.jsonl"
    if not env.is_file(): raise FileNotFoundError("Missing .env file.")
    if not manifest.is_file(): raise FileNotFoundError("Missing build/source-manifest.jsonl. Run inventory first.")
    keys = []
    for name in ["GROQ_API_KEY", "GROQ_API_KEY2", "GROQ_API_KEY3"]:
        if not (value := env_value(env, name)): raise ValueError(f"Missing {name} in .env.")
        keys.append(value)
    records = [row for row in read_jsonl(manifest) if row["included_in_synthesis"]]
    checkpoint_path, log_path = build / "llm-segmentation-checkpoint.jsonl", build / "groq-segmentation-requests.jsonl"
    completed = {row["source_id"]: row for row in read_jsonl(checkpoint_path)} if checkpoint_path.is_file() else {}
    pending = [row for row in records if row["source_id"] not in completed]
    system = 'You segment source text for a knowledge base. Return JSON only: {"results":[{"source_id":"...","passages":[{"start":0,"end":2}]}]}. Every source_id supplied must appear exactly once. For each source, group every contiguous unit index exactly once, from 0 through its final index. Never rewrite, omit, reorder, or combine units across sources. Choose boundaries only where the idea changes; keep short posts as one passage and aim for coherent 100–250 word passages when the source length permits.'
    models, model_index, key_cursor, exhausted = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"], 0, 0, set()
    index = 0
    while index < len(pending):
        batch, words = [], 0
        while index < len(pending) and len(batch) < args.maximum_sources_per_request:
            record = pending[index]; units = atomic_units(record["normalized_text"], args.maximum_atomic_unit_words)
            if not units: raise ValueError(f"No units generated for {record['source_id']}.")
            if batch and words + record["word_count"] > args.maximum_batch_words: break
            batch.append({"source_id": record["source_id"], "source_type": record["source_type"], "relative_path": record["relative_path"], "recorded_at": record.get("recorded_at"), "units": units}); words += record["word_count"]; index += 1
        user = json.dumps({"sources": [{"source_id": item["source_id"], "units": item["units"]} for item in batch]}, ensure_ascii=False, separators=(",", ":"))
        while True:
            model = models[model_index]
            slots = [slot for slot in range(len(keys)) if (model, slot) not in exhausted]
            if not slots:
                if model_index == 0: model_index = 1; print("All configured keys exhausted their GPT-OSS 120B daily quota; switching to GPT-OSS 20B."); continue
                raise RuntimeError("All configured keys are exhausted for GPT-OSS 20B.")
            slot = next((slot for slot in slots if slot >= key_cursor), slots[0])
            response = completion(keys[slot], model, system, user, max_tokens=1800, json_output=True)
            write_jsonl(log_path, [{"timestamp": utc_now(), "model": model, "key_slot": slot + 1, "status_code": response.status, "source_ids": [item["source_id"] for item in batch], "batch_words": words}], append=True)
            if 200 <= response.status < 300:
                try: validated = ranges_from_response(response.body, batch)
                except Exception as error:
                    (build / "llm-last-invalid-response.json").write_text(response.body, encoding="utf-8"); raise ValueError(f"Invalid model response for batch beginning {batch[0]['source_id']}: {error}") from error
                entries = [{"source_id": item["source"]["source_id"], "source_type": item["source"]["source_type"], "relative_path": item["source"]["relative_path"], "recorded_at": item["source"].get("recorded_at"), "model": model, "key_slot": slot + 1, "unit_count": len(item["source"]["units"]), "passage_ranges": item["ranges"], "completed_at": utc_now()} for item in validated]
                write_jsonl(checkpoint_path, entries, append=True); completed.update({item["source_id"]: item for item in entries}); key_cursor = (slot + 1) % len(keys)
                print(f"Segmented {len(batch)} source(s) with {model} using key slot {slot + 1}. Progress: {len(completed)}/{len(records)}."); break
            if response.status == 429:
                body = response.body.lower(); remaining = response.headers.get("x-ratelimit-remaining-requests", "") if response.headers else ""
                if any(term in body for term in ["per day", "daily", "tpd", "rpd", "daily quota"]) or remaining == "0": exhausted.add((model, slot)); key_cursor = (slot + 1) % len(keys); continue
                seconds = retry_seconds(response.headers); print(f"Rate limited; waiting {seconds} second(s) before retrying."); time.sleep(seconds); continue
            if response.status in (401, 403): raise RuntimeError(f"Groq rejected key slot {slot + 1} with HTTP {response.status}.")
            detail = re.sub(r"\s+", " ", response.body).strip()[:600]
            raise RuntimeError(f"Groq request failed with HTTP {response.status}: {detail}")
    completed = {row["source_id"]: row for row in read_jsonl(checkpoint_path)}
    if len(completed) != len(records): raise RuntimeError("Segmentation checkpoint is incomplete; rerun this script to resume.")
    output, passage_number = [], 0
    for record in records:
        units, checkpoint = atomic_units(record["normalized_text"], args.maximum_atomic_unit_words), completed[record["source_id"]]
        for segment_index, item in enumerate(checkpoint["passage_ranges"], 1):
            passage_number += 1; text = " ".join(unit["text"] for unit in units[item["start"]:item["end"] + 1])
            output.append({"llm_passage_id": f"LP{passage_number:06d}", "source_id": record["source_id"], "source_type": record["source_type"], "relative_path": record["relative_path"], "recorded_at": record.get("recorded_at"), "segment_index": segment_index, "unit_start": item["start"], "unit_end": item["end"], "word_count": word_count(text), "text": text, "model": checkpoint["model"], "key_slot": checkpoint["key_slot"]})
    write_jsonl(build / "llm-passage-manifest.jsonl", output)
    write_json(build / "llm-segmentation-summary.json", {"schema_version": 1, "generated_at": utc_now(), "canonical_source_count": len(records), "segmented_source_count": len(completed), "llm_passage_count": passage_number, "primary_model": models[0], "fallback_model": models[1], "files": {"checkpoint": "build/llm-segmentation-checkpoint.jsonl", "request_log": "build/groq-segmentation-requests.jsonl", "passage_manifest": "build/llm-passage-manifest.jsonl"}})
    print(f"LLM segmentation complete: {passage_number} passages from {len(records)} sources.")


if __name__ == "__main__":
    main()
