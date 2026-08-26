"""Ingest one queued source, update its KB topic, and retain a resumable checkpoint."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import unicodedata
from datetime import datetime
from pathlib import Path

from groq_client import PairRotator, completion, content, retry_seconds
from kb_common import env_value, read_jsonl, repository_root, utc_now, word_count, write_json, write_jsonl


SECTIONS = ["## Overview", "## Core ideas", "## Principles and mental models", "## Recommended practices", "## Examples and stories", "## Tensions and contradictions", "## Caveats"]


def normalized(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).replace("\r\n", "\n").replace("\r", "\n").replace("\u00a0", " ")
    return re.sub(r"\n{3,}", "\n\n", re.sub(r"[ \t]+\n", "\n", text)).strip()


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    write_json(temporary, value); temporary.replace(path)


def oldest(incoming: Path) -> tuple[Path, str] | None:
    choices = []
    for directory, kind in [(incoming / "texts", "text"), (incoming / "transcripts", "transcript")]:
        for file in directory.glob("*.txt") if directory.is_dir() else []:
            match = re.search(r"(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})(?:_\d+)?", file.name)
            date = datetime.strptime(" ".join(match.groups()), "%Y-%m-%d %H-%M-%S") if match else datetime.fromtimestamp(file.stat().st_mtime)
            choices.append((date, file.name, kind, file))
    return (choices[0][3], choices[0][2]) if choices and (choices := sorted(choices)) else None


def recorded_at(file: Path) -> str:
    match = re.search(r"(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})(?:_\d+)?", file.name)
    if match:
        return datetime.strptime(" ".join(match.groups()), "%Y-%m-%d %H-%M-%S").isoformat()
    return datetime.fromtimestamp(file.stat().st_mtime).isoformat()


def topic_file(kb: Path, topic: int) -> Path:
    for file in kb.glob("*.md"):
        if re.search(rf"(?m)^topic_id:\s*{topic}\s*$", "\n".join(file.read_text(encoding="utf-8").splitlines()[:8])): return file
    raise FileNotFoundError(f"Could not find KB document for topic {topic}.")


def body(document: str) -> str:
    document = re.sub(r"(?s)\A---.*?---\s*\r?\n\r?\n# .*?\r?\n\r?\n", "", document)
    return re.split(r"(?m)^## Sources\s*$", document)[0].strip()


def strip_citations(text: str) -> str:
    citation = r"\[S\d{4}\](?:\([^)]*\))?"
    text = re.sub(rf"\s*\((?:\s*{citation}\s*,?)+\s*\)", "", text)
    return re.sub(r"[ \t]+([,.;:!?])", r"\1", re.sub(rf"\s*{citation}", "", text))


def comparison(text: str) -> str:
    return re.sub(r"\s+", " ", strip_citations(text).strip())


def substantive(line: str) -> bool:
    return bool(line.strip()) and not re.match(r"^#{1,6}\s|^(---|\*\*\*|___)$", line.strip())


def difference(original: str, updated: str) -> tuple[int, int]:
    values: dict[str, int] = {}
    original_count = 0
    for line in original.splitlines():
        if substantive(line) and (key := comparison(line)): values[key] = values.get(key, 0) + 1; original_count += 1
    added = 0
    for line in updated.splitlines():
        if not substantive(line): continue
        key = comparison(line)
        if values.get(key, 0): values[key] -= 1
        else: added += 1
    return original_count, added + sum(values.values())


def restore_citations(original: str, updated: str, source_id: str) -> str:
    original_by_key: dict[str, list[str]] = {}
    for line in original.splitlines():
        if key := comparison(line): original_by_key.setdefault(key, []).append(line)
    indexes: dict[str, int] = {}
    citation = f"([{source_id}](26-all-texts.md#{source_id.lower()}))"
    result = []
    for line in updated.splitlines():
        key = comparison(line)
        index = indexes.get(key, 0)
        if key and index < len(original_by_key.get(key, [])):
            result.append(original_by_key[key][index]); indexes[key] = index + 1
        elif substantive(line):
            match = re.match(r"^(.*?)([.!?])([ \t]*)$", line)
            result.append(f"{match.group(1)} {citation}{match.group(2)}{match.group(3)}" if match else f"{line.rstrip()} {citation}")
        else: result.append(line)
    return "\n".join(result).strip()


def groq_json(keys: list[str], system: str, user: str, label: str) -> tuple[dict, dict]:
    # A logical request starts from key 1 / GPT-OSS 120B.  This is deliberately
    # separate from the previous request's pair selection.
    rotator = PairRotator(keys, ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.6-27b"])
    errors = []
    transport_failures = 0
    while True:
        pair = rotator.next(); response = completion(pair["key"], pair["model"], system, user, max_tokens=5000, json_output=True)
        if 200 <= response.status < 300:
            try: value = json.loads(content(response)); return value, pair
            except Exception: rotator.cool(pair, 300); errors.append(f"{pair['slot']}/{pair['model']}: invalid JSON"); continue
        if response.status in (408, 429, 599) or response.status >= 500:
            rotator.cool(pair, retry_seconds(response.headers))
            errors.append(f"{pair['slot']}/{pair['model']}: HTTP {response.status}")
            if response.status == 599:
                transport_failures += 1
                if transport_failures >= len(rotator.pairs):
                    raise RuntimeError(f"Every Groq key/model pair had a transport failure for {label}. Check network connectivity before retrying.")
            continue
        # A client error is specific to the key/model pair and should not be
        # retried later in this logical request.
        rotator.disable(pair); errors.append(f"{pair['slot']}/{pair['model']}: HTTP {response.status}")
        if all(item["disabled"] for item in rotator.pairs):
            raise RuntimeError(f"All Groq key/model pairs failed for {label}. {' | '.join(errors)}")


def assert_citation_free_topic_body(value: str) -> None:
    if re.search(r"<think>|</think>|```|\[S\d{4}\]|github\.com/", value):
        raise ValueError("The KB update response contains forbidden model markup, citations, or source links.")
    headings = re.findall(r"(?m)^## .+?[ \t]*$", value)
    if headings != SECTIONS:
        raise ValueError("The KB update response must contain exactly the seven required sections in order.")
    if not value.lstrip().startswith("## Overview"):
        raise ValueError("The KB update response must begin with ## Overview.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    args = parser.parse_args(); repo = repository_root(args.repository_root)
    incoming, kb, env = repo / "data" / "incoming", repo / "kb", repo / ".env"
    texts, transcripts, media = repo / "data" / "texts", repo / "data" / "transcripts", repo / "data" / "media" / "audio and video"
    longterm, useful = repo / "build" / "longterm", repo / "build" / "useful"
    source_path, passage_path, map_path = longterm / "source-manifest.jsonl", longterm / "passage-manifest.jsonl", longterm / "kb-source-map.jsonl"
    state_path, log_path = useful / "incoming-ingestion-active.json", useful / "incoming-ingestion-log.jsonl"
    for path in [texts, transcripts, media, kb, longterm, useful, source_path, passage_path, map_path, env]:
        if not path.exists(): raise FileNotFoundError(f"Required input is missing: {path}")
    keys = []
    for name in ["GROQ_API_KEY", "GROQ_API_KEY2", "GROQ_API_KEY3", "GROQ_API_KEY4", "GROQ_API_KEY5", "GROQ_API_KEY6"]:
        if not (value := env_value(env, name)): raise ValueError(f"Missing {name} in .env.")
        keys.append(value)
    state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.is_file() else None
    if not state:
        selected = oldest(incoming)
        if not selected: print("No .txt files are waiting in data/incoming/texts or data/incoming/transcripts."); return
        file, source_type = selected; destination = (texts if source_type == "text" else transcripts) / file.name
        if destination.exists(): raise FileExistsError(f"Cannot move {file.name}: destination already contains that file: {destination}")
        state = {"schema_version": 1, "filename": file.name, "source_type": source_type, "incoming_relative_path": f"data/incoming/{source_type}s/{file.name}", "incoming_path": str(file), "relative_path": f"data/{source_type}s/{file.name}", "destination_path": str(destination), "stage": "selected", "started_at": utc_now()}
        if source_type == "transcript":
            index = incoming / "transcripts" / "media-index.jsonl"; entries = [item for item in read_jsonl(index) if item["transcript_relative_path"] == state["incoming_relative_path"]]
            if not entries: raise ValueError(f"Transcript {file.name} has no media-index entry.")
            source_media = repo / entries[-1]["media_relative_path"]; destination_media = media / source_media.name
            if not source_media.is_file() or destination_media.exists(): raise FileExistsError("Transcript media is missing or its destination exists.")
            state.update({"media_incoming_path": str(source_media), "media_relative_path": f"data/media/audio and video/{source_media.name}", "media_destination_path": str(destination_media)})
        atomic_json(state_path, state)
    if state["stage"] == "selected":
        source, destination = Path(state["incoming_path"]), Path(state["destination_path"])
        if source.exists(): shutil.move(str(source), str(destination))
        if state.get("media_incoming_path") and Path(state["media_incoming_path"]).exists(): shutil.move(state["media_incoming_path"], state["media_destination_path"])
        state["stage"] = "moved"; atomic_json(state_path, state)
    sources = read_jsonl(source_path); source_by_id = {item["source_id"]: item for item in sources}
    if state["stage"] == "moved":
        destination = Path(state["destination_path"]); text = normalized(destination.read_text(encoding="utf-8"))
        if not text:
            write_jsonl(log_path, [{"completed_at": utc_now(), "filename": state["filename"], "source_type": state["source_type"], "status": "skipped_empty"}], append=True); state_path.unlink(); return
        existing = next((item for item in sources if item["relative_path"] == state["relative_path"]), None); digest = hashlib.sha256(text.encode()).hexdigest()
        if existing: state.update({"source_id": existing["source_id"], "normalized_text": existing["normalized_text"], "stage": "source_recorded" if existing["included_in_synthesis"] else "duplicate_skipped"})
        else:
            canonical = next((item for item in sources if item["normalized_content_hash_sha256"] == digest and item["included_in_synthesis"]), None); number = max([int(item["source_id"][1:]) for item in sources] or [0]) + 1
            record = {"source_id": f"S{number:04d}", "source_type": state["source_type"], "relative_path": state["relative_path"], "filename": destination.name, "recorded_at": recorded_at(destination), "file_bytes": destination.stat().st_size, "word_count": word_count(text), "character_count": len(text), "file_hash_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(), "normalized_content_hash_sha256": digest, "normalized_text": text, "duplicate_status": "exact_duplicate" if canonical else "unique", "canonical_source_id": canonical["source_id"] if canonical else None, "exact_duplicate_group": None, "included_in_synthesis": not bool(canonical), "near_duplicate_candidates": [], "associations": []}
            write_jsonl(source_path, [record], append=True); sources.append(record); source_by_id[record["source_id"]] = record; state.update({"source_id": record["source_id"], "normalized_text": text, "stage": "duplicate_skipped" if canonical else "source_recorded"})
        atomic_json(state_path, state)
    if state["stage"] in {"source_recorded", "duplicate_skipped"}:
        subprocess.run([sys.executable, str(repo / "scripts" / "build_all_texts.py"), "--repository-root", str(repo)], check=True)
    if state["stage"] == "duplicate_skipped":
        write_jsonl(log_path, [{"completed_at": utc_now(), "filename": state["filename"], "source_id": state["source_id"], "status": "skipped_exact_duplicate"}], append=True); state_path.unlink(); print(f"Skipped exact-duplicate source {state['source_id']}; no LLM calls were made."); return
    if state["stage"] == "source_recorded":
        topics = (repo / "artifacts" / "topics.md").read_text(encoding="utf-8")
        system = 'Classify the supplied text into exactly one of the 25 supplied KB topics. Return JSON only: {"primary_topic_id":1,"confidence":"high|medium|low","rationale":"brief source-grounded reason"}. Do not return secondary topics, ambiguity analysis, rewritten text, or facts not in the input. Topic 25 is only for non-substantive promotion, banter, low-context media, or topical commentary with no self-contained broader lesson.\n\nTOPICS:\n' + topics
        result, pair = groq_json(keys, system, state["normalized_text"], f"classification for {state['filename']}"); topic = int(result.get("primary_topic_id", 0))
        if topic not in range(1, 26) or result.get("confidence") not in {"high", "medium", "low"} or not result.get("rationale"): raise ValueError("Classification response did not match the required schema.")
        passages = read_jsonl(passage_path); passage_id = f"P{max([int(item['passage_id'][1:]) for item in passages] or [0]) + 1:06d}"
        state.update({"primary_topic_id": topic, "confidence": result["confidence"], "rationale": result["rationale"], "passage_id": passage_id, "classification_model": pair["model"], "classification_api_key_slot": pair["slot"], "stage": "classified"})
        source = source_by_id[state["source_id"]]
        write_jsonl(passage_path, [{"passage_id": passage_id, "source_id": state["source_id"], "source_type": state["source_type"], "relative_path": state["relative_path"], "recorded_at": source.get("recorded_at"), "segment_index": 1, "text": state["normalized_text"], "word_count": word_count(state["normalized_text"]), "primary_topic_id": topic, "secondary_topic_ids": [], "candidate_topics": [{"topic_id": topic, "title": None, "score": None, "matched_terms": []}], "non_substantive_signals": [], "routing": "non_substantive" if topic == 25 else "substantive", "routing_reasons": ["single_llm_classification"], "classification_confidence": state["confidence"], "review_required": False}], append=True); atomic_json(state_path, state)
    if state["stage"] == "classified":
        maps = read_jsonl(map_path); source = source_by_id[state["source_id"]]
        if not any(item["passage_id"] == state["passage_id"] and item["assignment_role"] == "primary" for item in maps):
            template = next(item for item in maps if int(item["topic_id"]) == state["primary_topic_id"])
            write_jsonl(map_path, [{"topic_id": state["primary_topic_id"], "topic_title": template["topic_title"], "assignment_role": "primary", "assignment_method": "llm_single_classification", "routing": "non_substantive" if state["primary_topic_id"] == 25 else "substantive", "confidence": state["confidence"], "rationale": state["rationale"], "passage_id": state["passage_id"], "passage_text": state["normalized_text"], "passage_word_count": word_count(state["normalized_text"]), "segment_index": 1, "source_id": source["source_id"], "source_type": source["source_type"], "relative_path": source["relative_path"], "recorded_at": source.get("recorded_at"), "source_sha256": source["file_hash_sha256"], "reviewed_model": state["classification_model"], "reviewed_at": utc_now()}], append=True)
        state["stage"] = "source_mapped"; atomic_json(state_path, state)
    if state["stage"] == "source_mapped":
        maps = read_jsonl(map_path); topic_rows = [item for item in maps if int(item["topic_id"]) == state["primary_topic_id"] and item["assignment_role"] == "primary"]; title = topic_rows[0]["topic_title"]; file = topic_file(kb, state["primary_topic_id"])
        original = body(file.read_text(encoding="utf-8")); current = strip_citations(original); source_count = len({item["source_id"] for item in topic_rows})
        system = 'Return JSON only: {"markdown":"..."}. Update the supplied knowledge-base document with the supplied new source text. The markdown value must start with "## Overview" and contain exactly these sections in order: Overview, Core ideas, Principles and mental models, Recommended practices, Examples and stories, Tensions and contradictions, Caveats. Make the smallest possible line-level change: retain every unaffected line verbatim, and add or revise a line only when the new source directly supports it. Do not rewrite, reorder, summarize, or polish unaffected material. Use the KB\'s established editorial voice: integrate claims directly, and never write source-note phrasing such as "the source states," "the source asserts," or "this source explains." Do not include citations, source IDs, links, YAML, a document title, a Sources section, code fences, or reasoning. Do not invent facts. Attribute contested claims to the creator; label speculative health/scientific claims, strongly gendered framing, political claims, and unsafe advice appropriately.'
        result, pair = groq_json(keys, system, f"INCOMING TEXT:\n{state['normalized_text']}\n\nCURRENT KB DOCUMENT:\n{current}", f"KB update for topic {state['primary_topic_id']}"); updated = result.get("markdown", "")
        assert_citation_free_topic_body(updated)
        total, changed = difference(current, updated)
        if changed > max(5, int(total * .25 + .999)): raise ValueError("The KB update rewrote too much of the document.")
        linked = restore_citations(original, updated, state["source_id"])
        header = f"---\ntopic_id: {state['primary_topic_id']}\ntitle: {title}\nsource_count: {source_count}\nsource_scope:\n  - data/texts\n  - data/transcripts\n---\n\n# {title}\n\n"
        file.write_text(header + linked + "\n", encoding="utf-8", newline="\n"); state.update({"kb_update_model": pair["model"], "kb_update_api_key_slot": pair["slot"], "stage": "kb_updated"}); atomic_json(state_path, state)
    if state["stage"] == "kb_updated":
        subprocess.run([sys.executable, str(repo / "scripts" / "validate_kb.py"), "--repository-root", str(repo)], check=True); state.update({"stage": "validated", "completed_at": utc_now()}); atomic_json(state_path, state)
    if state["stage"] == "validated":
        write_jsonl(log_path, [{"completed_at": state["completed_at"], "filename": state["filename"], "source_id": state["source_id"], "passage_id": state["passage_id"], "topic_id": state["primary_topic_id"], "confidence": state["confidence"], "classification_model": state["classification_model"], "kb_update_model": state["kb_update_model"], "status": "completed"}], append=True); state_path.unlink(); print(f"Ingestion complete: {state['filename']} -> topic {state['primary_topic_id']}.")


if __name__ == "__main__":
    main()
