"""Inventory KB text sources and identify exact and near duplicates."""

from __future__ import annotations

import argparse
import hashlib
import re
import unicodedata
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from kb_common import repository_root, utc_now, word_count, write_json, write_jsonl


def normalize(content: str) -> str:
    content = unicodedata.normalize("NFKC", content).replace("\r\n", "\n").replace("\r", "\n").replace("\u00a0", " ")
    content = re.sub(r"[ \t]+\n", "\n", content)
    return re.sub(r"\n{3,}", "\n\n", content).strip()


def digest(value: str | bytes) -> str:
    return hashlib.sha256(value.encode("utf-8") if isinstance(value, str) else value).hexdigest()


def timestamp(filename: str) -> str | None:
    match = re.search(r"(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})(?:_\d+)?", filename)
    if not match:
        return None
    return datetime.strptime(" ".join(match.groups()), "%Y-%m-%d %H-%M-%S").isoformat()


def shingles(content: str) -> set[str]:
    tokens = re.findall(r"[^\W_]+", content.lower(), flags=re.UNICODE)
    return {" ".join(tokens[index:index + 5]) for index in range(len(tokens) - 4)}


def associate(left: dict, right: dict, reason: str) -> None:
    if not any(item["source_id"] == right["source_id"] for item in left["associations"]):
        left["associations"].append({"source_id": right["source_id"], "reason": reason, "confidence": 1.0})
    if not any(item["source_id"] == left["source_id"] for item in right["associations"]):
        right["associations"].append({"source_id": left["source_id"], "reason": reason, "confidence": 1.0})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    parser.add_argument("--near-duplicate-threshold", type=float, default=0.80)
    args = parser.parse_args()
    repo = repository_root(args.repository_root)
    roots = ((repo / "data" / "texts", "text"), (repo / "data" / "transcripts", "transcript"))
    for root, _ in roots:
        if not root.is_dir():
            raise FileNotFoundError(f"Required source directory is missing: {root}")
    records: list[dict] = []
    excluded: list[dict] = []
    source_files = sorted((path, kind) for root, kind in roots for path in root.rglob("*") if path.is_file())
    for path, source_type in source_files:
        raw = path.read_text(encoding="utf-8")
        content = normalize(raw)
        relative = path.relative_to(repo).as_posix()
        if not word_count(content):
            excluded.append({"relative_path": relative, "source_type": source_type, "reason": "empty_after_normalization", "file_hash_sha256": digest(path.read_bytes())})
            continue
        number = len(records) + 1
        records.append({"source_id": f"S{number:04d}", "source_type": source_type, "relative_path": relative, "filename": path.name, "recorded_at": timestamp(path.name), "file_bytes": path.stat().st_size, "word_count": word_count(content), "character_count": len(content), "file_hash_sha256": digest(path.read_bytes()), "normalized_content_hash_sha256": digest(content), "normalized_text": content, "duplicate_status": "unique", "canonical_source_id": None, "exact_duplicate_group": None, "included_in_synthesis": True, "near_duplicate_candidates": [], "associations": []})
    exact_groups: list[dict] = []
    by_hash: dict[str, list[dict]] = defaultdict(list)
    for record in records:
        by_hash[record["normalized_content_hash_sha256"]].append(record)
    for group_number, (_, group) in enumerate(sorted((item for item in by_hash.items() if len(item[1]) > 1)), 1):
        group.sort(key=lambda item: item["source_id"])
        canonical, group_id = group[0], f"D{group_number:03d}"
        for record in group:
            record["canonical_source_id"], record["exact_duplicate_group"] = canonical["source_id"], group_id
            if record is not canonical:
                record["duplicate_status"], record["included_in_synthesis"] = "exact_duplicate", False
            else:
                record["duplicate_status"] = "exact_duplicate_canonical"
        exact_groups.append({"group_id": group_id, "type": "exact", "canonical_source_id": canonical["source_id"], "source_ids": [item["source_id"] for item in group], "normalized_content_hash_sha256": canonical["normalized_content_hash_sha256"]})
    canonical = [record for record in records if record["included_in_synthesis"] and record["word_count"] >= 50]
    shingle_sets = {record["source_id"]: shingles(record["normalized_text"]) for record in canonical}
    near_pairs: list[dict] = []
    for index, left in enumerate(canonical):
        for right in canonical[index + 1:]:
            if min(left["word_count"], right["word_count"]) / max(left["word_count"], right["word_count"]) < .75:
                continue
            a, b = shingle_sets[left["source_id"]], shingle_sets[right["source_id"]]
            if not a or not b:
                continue
            similarity = len(a & b) / len(a | b)
            if similarity >= args.near_duplicate_threshold:
                score = round(similarity, 3)
                left["near_duplicate_candidates"].append({"source_id": right["source_id"], "similarity": score})
                right["near_duplicate_candidates"].append({"source_id": left["source_id"], "similarity": score})
                near_pairs.append({"type": "near", "source_id_a": left["source_id"], "source_id_b": right["source_id"], "shingle_jaccard_similarity": score})
    by_timestamp: dict[str, list[dict]] = defaultdict(list)
    for record in records:
        if record["recorded_at"]:
            by_timestamp[record["recorded_at"]].append(record)
    for group in by_timestamp.values():
        texts, transcripts = [item for item in group if item["source_type"] == "text"], [item for item in group if item["source_type"] == "transcript"]
        for left in texts:
            for right in transcripts:
                associate(left, right, "exact_timestamp")
    for group in by_hash.values():
        texts, transcripts = [item for item in group if item["source_type"] == "text"], [item for item in group if item["source_type"] == "transcript"]
        for left in texts:
            for right in transcripts:
                associate(left, right, "identical_normalized_content")
    build = repo / "build"
    write_jsonl(build / "source-manifest.jsonl", records)
    write_jsonl(build / "excluded-sources.jsonl", excluded)
    write_json(build / "duplicate-groups.json", {"schema_version": 1, "exact_duplicate_groups": exact_groups, "near_duplicate_pairs": near_pairs})
    links = sum(len(record["associations"]) for record in records)
    summary = {"schema_version": 1, "generated_at": utc_now(), "source_directories": ["data/texts", "data/transcripts"], "input_file_count": len(source_files), "included_record_count": len(records), "excluded_empty_count": len(excluded), "canonical_synthesis_record_count": sum(record["included_in_synthesis"] for record in records), "exact_duplicate_group_count": len(exact_groups), "exact_duplicate_copy_count": sum(record["duplicate_status"] == "exact_duplicate" for record in records), "near_duplicate_pair_count": len(near_pairs), "association_pair_count": links / 2, "association_link_count": links, "files": {"manifest": "build/source-manifest.jsonl", "excluded_sources": "build/excluded-sources.jsonl", "duplicate_groups": "build/duplicate-groups.json"}}
    write_json(build / "inventory-summary.json", summary)
    print(f"Inventory complete: {len(records)} non-empty records from {len(source_files)} input files.")


if __name__ == "__main__":
    main()
