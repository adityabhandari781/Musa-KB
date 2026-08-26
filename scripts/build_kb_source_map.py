"""Build topic-to-passage source mappings from classified passages and reviews."""

from __future__ import annotations

import argparse
import re
from collections import defaultdict

from kb_common import read_jsonl, repository_root, utc_now, write_json, write_jsonl


def topic_catalog(path):
    catalog = {}
    expression = re.compile(r"^\s*(\d+)\.\s+(.+?)(?:\s+—\s+.*|:\s*)$")
    for line in path.read_text(encoding="utf-8").splitlines():
        if match := expression.match(line):
            catalog[int(match.group(1))] = match.group(2).strip()
    if set(catalog) != set(range(1, 26)):
        raise ValueError("Could not derive all 25 topic titles from artifacts/topics.md.")
    return catalog


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    args = parser.parse_args()
    repo = repository_root(args.repository_root)
    build = repo / "build"
    paths = [build / "passage-manifest.jsonl", build / "llm-topic-review-checkpoint.jsonl", build / "source-manifest.jsonl", repo / "artifacts" / "topics.md"]
    for path in paths:
        if not path.is_file():
            raise FileNotFoundError(f"Required input is missing: {path}")
    topics = topic_catalog(paths[-1])
    passages, reviews, sources = (read_jsonl(path) for path in paths[:3])
    reviews_by_id = {row["passage_id"]: row for row in reviews}
    if len(reviews_by_id) != len(reviews):
        raise ValueError("Duplicate review for passage.")
    sources_by_id = {row["source_id"]: row for row in sources}
    if len(sources_by_id) != len(sources):
        raise ValueError("Duplicate source ID.")
    flagged = [row for row in passages if row["review_required"]]
    if len(reviews) != len(flagged) or any(row["passage_id"] not in reviews_by_id for row in flagged):
        raise ValueError("Review coverage mismatch.")
    counts = {topic: {"primary_passages": 0, "secondary_passages": 0, "source_ids": set()} for topic in range(1, 26)}
    rows: list[dict] = []
    primary_count = secondary_count = 0
    for passage in passages:
        source = sources_by_id.get(passage["source_id"])
        if source is None:
            raise ValueError(f"Passage {passage['passage_id']} references a missing source.")
        review = reviews_by_id.get(passage["passage_id"])
        primary = int((review or passage)["primary_topic_id"])
        secondary = sorted({int(item) for item in (review or passage).get("secondary_topic_ids", []) if int(item) in range(1, 25) and int(item) != primary})
        if primary not in range(1, 26):
            raise ValueError(f"Invalid primary topic {primary} for {passage['passage_id']}.")
        for topic, role in [(primary, "primary")] + [(item, "secondary") for item in secondary]:
            row = {"topic_id": topic, "topic_title": topics[topic], "assignment_role": role, "assignment_method": "llm_review" if review else "heuristic", "routing": (review or passage).get("routing"), "confidence": (review or passage).get("confidence", passage.get("classification_confidence")), "rationale": (review or passage).get("rationale", "; ".join(passage.get("routing_reasons", []))), "passage_id": passage["passage_id"], "passage_text": passage["text"], "passage_word_count": passage["word_count"], "segment_index": passage["segment_index"], "source_id": source["source_id"], "source_type": source["source_type"], "relative_path": source["relative_path"], "recorded_at": source.get("recorded_at"), "source_sha256": source["file_hash_sha256"], "reviewed_model": review.get("reviewed_model") if review else None, "reviewed_at": review.get("reviewed_at") if review else None}
            rows.append(row)
            counts[topic]["source_ids"].add(source["source_id"])
            if role == "primary":
                counts[topic]["primary_passages"] += 1; primary_count += 1
            else:
                counts[topic]["secondary_passages"] += 1; secondary_count += 1
    write_jsonl(build / "kb-source-map.jsonl", rows)
    summary = {"generated_at": utc_now(), "passage_manifest": "build/passage-manifest.jsonl", "review_checkpoint": "build/llm-topic-review-checkpoint.jsonl", "source_manifest": "build/source-manifest.jsonl", "total_passages": len(passages), "llm_reviewed_passages": len(reviews), "heuristic_passages": len(passages) - len(reviews), "primary_assignments": primary_count, "secondary_assignments": secondary_count, "total_source_map_rows": len(rows), "topics": [{"topic_id": topic, "topic_title": topics[topic], "primary_passages": counts[topic]["primary_passages"], "secondary_passages": counts[topic]["secondary_passages"], "distinct_sources": len(counts[topic]["source_ids"])} for topic in range(1, 26)]}
    write_json(build / "kb-source-map-summary.json", summary)
    print(f"Wrote {len(rows)} topic-to-passage rows to {build / 'kb-source-map.jsonl'}.")


if __name__ == "__main__":
    main()
