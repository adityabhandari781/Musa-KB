"""Create cited KB documents from source-map rows with resumable Groq calls."""

from __future__ import annotations

import argparse
import json
import re

from groq_client import PairRotator, completion, content, retry_seconds
from kb_common import display_topic_title, env_value, read_jsonl, repository_root, utc_now, word_count, write_jsonl


EVIDENCE_SYSTEM = "Return concise Markdown evidence notes from the supplied source passages. Every bullet must retain one or more inline [S0001] citations. Capture claims, practices, examples, contradictions, and cautions; distinguish the creator's claims from established facts. Do not add facts or advice. Do not write a title, front matter, Sources section, or code fence."
FINAL_SYSTEM = '''Write a rigorous, source-grounded knowledge-base document from the cited evidence notes. Return Markdown only, beginning with "## Overview"; do not include a title, YAML front matter, a Sources section, or a code fence.
Use exactly these sections in order: ## Overview, ## Core ideas, ## Principles and mental models, ## Recommended practices, ## Examples and stories, ## Tensions and contradictions, ## Caveats.
Synthesize rather than concatenate. Every substantive paragraph needs one or more supplied [S0001] citations. Do not invent facts, advice, evidence, or examples. Attribute contested assertions to the creator. Clearly label speculative health/scientific claims, strongly gendered or misogynistic framing, political claims, and advice that could be unsafe if followed literally. For topic 25, describe exclusions and boundaries without turning promotional, banter, or low-context content into advice.'''
MERGE_SYSTEM = "Return compact Markdown evidence notes from the supplied cited notes. Retain only source-supported category patterns, boundary cases, and caveats. Every bullet must retain one or more [S0001] citations. Do not add facts, a title, front matter, Sources section, or code fence."
SECTIONS = ["## Overview", "## Core ideas", "## Principles and mental models", "## Recommended practices", "## Examples and stories", "## Tensions and contradictions", "## Caveats"]
LINK = r"\[S\d{4}\]\([^\)]+\)"
GAP = r"[ \t\u00A0\u202F]*"
CLUSTER = re.compile(r"(?<!\w)\(*" + GAP + LINK + r"(?:" + GAP + r"\)*" + GAP + r"(?:," + GAP + r")?\(*" + GAP + LINK + r")*" + GAP + r"\)*")


def kb_files(path):
    files = {}
    for file in path.glob("*.md"):
        lines = file.read_text(encoding="utf-8").splitlines()[:8]
        match = next((re.match(r"^topic_id:\s*(\d+)\s*$", line) for line in lines if re.match(r"^topic_id:\s*(\d+)\s*$", line)), None)
        if match: files[int(match.group(1))] = file
    if len(files) != 25: raise ValueError("kb/ must contain exactly 25 topic files.")
    return files


def chunks(rows: list[dict], limit: int) -> list[list[dict]]:
    result, current, count = [], [], 0
    for row in sorted(rows, key=lambda item: (item["source_id"], item["segment_index"])):
        if current and count + int(row["passage_word_count"]) > limit: result.append(current); current, count = [], 0
        current.append(row); count += int(row["passage_word_count"])
    return result + ([current] if current else [])


def format_citation_runs(text: str) -> str:
    return CLUSTER.sub(lambda match: "(" + ", ".join(re.findall(LINK, match.group())) + ")", text)


def write_topic(path, topic, body, rows, source_appendix: str, repo) -> None:
    body = re.sub(r"^```(?:markdown|md)?\s*|\s*```$", "", body.strip())
    sources = {row["source_id"]: row["relative_path"].replace("\\", "/") for row in rows}
    body = re.sub(r"\[(S\d{4})\](?:\([^)]*\))?", lambda match: f"[{match.group(1)}]({source_appendix}#{match.group(1).lower()})", body)
    body = format_citation_runs(body)
    title = display_topic_title(repo, int(topic["topic_id"]), topic["topic_title"])
    header = f"---\ntopic_id: {topic['topic_id']}\ntitle: {title}\nsource_count: {len(sources)}\nsource_scope:\n  - data/texts\n  - data/transcripts\n---\n\n# {title}\n\n"
    path.write_text(header + body + "\n", encoding="utf-8", newline="\n")


def request(rotator, logger, work_id, topic_id, system, user, rows, max_tokens, required):
    valid_sources = {row["source_id"] for row in rows}
    while True:
        pair = rotator.next(); response = completion(pair["key"], pair["model"], system, user, max_tokens=max_tokens, temperature=.2, timeout=45)
        write_jsonl(logger, [{"timestamp": utc_now(), "work_id": work_id, "topic_id": topic_id, "key_slot": pair["slot"], "model": pair["model"], "status": response.status, "source_passages": len(rows)}], append=True)
        if response.status == 429: rotator.cool(pair, retry_seconds(response.headers)); continue
        if not 200 <= response.status < 300: rotator.cool(pair, 60 if response.status >= 500 else 300); continue
        try:
            text = content(response).strip()
            if len(text) < 180: raise ValueError("Response is too short.")
            if any(section not in text for section in required): raise ValueError("Missing required section.")
            cited = set(re.findall(r"\[(S\d{4})\]", text))
            text = re.sub(r"\[(S\d{4})\]", lambda match: match.group() if match.group(1) in valid_sources else "", text)
            if not set(re.findall(r"\[(S\d{4})\]", text)): raise ValueError("Response has no valid source citations.")
        except Exception as error:
            print(f"Malformed response for {work_id} from key slot {pair['slot']} / {pair['model']}: {error}"); rotator.cool(pair, 300); continue
        # Keep using the healthy successful pair, matching the PowerShell
        # cursor policy.  Rotation happens only after rate limiting or failure.
        return text, pair


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    parser.add_argument("--evidence-chunk-words", type=int, default=3500)
    parser.add_argument("--source-appendix", default="26-all-texts.md")
    args = parser.parse_args()
    repo = repository_root(args.repository_root); build, kb, env = repo / "build", repo / "kb", repo / ".env"
    mapping, checkpoint, log = build / "kb-source-map.jsonl", build / "llm-kb-hierarchical-synthesis-checkpoint.jsonl", build / "groq-kb-hierarchical-synthesis-requests.jsonl"
    for path in [env, mapping, kb]:
        if not path.exists(): raise FileNotFoundError(f"Required input is missing: {path}")
    key = env_value(env, "GROQ_API_KEY6")
    if not key: raise ValueError("Missing GROQ_API_KEY6 in .env.")
    files, rows = kb_files(kb), read_jsonl(mapping)
    topic_rows = {topic: [row for row in rows if int(row["topic_id"]) == topic and row["assignment_role"] == "primary"] for topic in range(1, 26)}
    if any(not value for value in topic_rows.values()): raise ValueError("No primary passages for one or more topics.")
    done = {row["work_id"]: row for row in read_jsonl(checkpoint)} if checkpoint.is_file() else {}
    for topic in range(1, 26):
        final_id = f"T{topic:02d}-FINAL"
        if final_id in done: write_topic(files[topic], topic_rows[topic][0], done[final_id]["content"], topic_rows[topic], args.source_appendix, repo)
    rotator = PairRotator([key], ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.6-27b"])
    for topic_id in range(1, 26):
        rows = topic_rows[topic_id]; topic = rows[0]; pieces = chunks(rows, 800 if topic_id == 25 else args.evidence_chunk_words)
        for index, piece in enumerate(pieces, 1):
            work_id = f"T{topic_id:02d}-E{index:03d}"
            if work_id in done: continue
            supplied = "\n\n".join(f"[{row['source_id']}] ({row['relative_path']})\n{row['passage_text']}" for row in piece)
            text, pair = request(rotator, log, work_id, topic_id, EVIDENCE_SYSTEM, f"Topic {topic_id}: {topic['topic_title']}\n\nSource passages:\n\n{supplied}", piece, 450 if topic_id == 25 else 900, [])
            entry = {"work_id": work_id, "kind": "evidence", "topic_id": topic_id, "chunk_index": index, "content": text, "model": pair["model"], "key_slot": pair["slot"], "completed_at": utc_now()}; write_jsonl(checkpoint, [entry], append=True); done[work_id] = entry
        evidence = [done[f"T{topic_id:02d}-E{index:03d}"]["content"] for index in range(1, len(pieces) + 1)]
        if topic_id == 25:
            merged = []
            for start in range(0, len(evidence), 4):
                work_id = f"T25-M{start // 4 + 1:03d}"
                if work_id not in done:
                    text, pair = request(rotator, log, work_id, topic_id, MERGE_SYSTEM, f"Topic 25: {topic['topic_title']}\n\nCited evidence notes:\n\n" + "\n\n---\n\n".join(evidence[start:start + 4]), rows, 300, [])
                    entry = {"work_id": work_id, "kind": "merge", "topic_id": topic_id, "content": text, "model": pair["model"], "key_slot": pair["slot"], "completed_at": utc_now()}; write_jsonl(checkpoint, [entry], append=True); done[work_id] = entry
                merged.append(done[work_id]["content"])
            evidence = merged
        final_id = f"T{topic_id:02d}-FINAL"
        if final_id in done: continue
        text, pair = request(rotator, log, final_id, topic_id, FINAL_SYSTEM, f"Topic {topic_id}: {topic['topic_title']}\n\nCited evidence notes:\n\n" + "\n\n---\n\n".join(evidence), rows, 3000, SECTIONS)
        write_topic(files[topic_id], topic, text, rows, args.source_appendix, repo)
        entry = {"work_id": final_id, "kind": "final", "topic_id": topic_id, "content": text, "model": pair["model"], "key_slot": pair["slot"], "completed_at": utc_now()}; write_jsonl(checkpoint, [entry], append=True); done[final_id] = entry
        print(f"Synthesized topic {topic_id}/25 with key slot {pair['slot']} on {pair['model']}.")
    print("Hierarchical LLM KB synthesis complete.")


if __name__ == "__main__":
    main()
