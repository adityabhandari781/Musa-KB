"""Validate KB documents, citations, and source-map coverage."""

from __future__ import annotations

import argparse
import re
from collections import defaultdict

from kb_common import display_topic_title, read_jsonl, repository_root, utc_now, write_json


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    args = parser.parse_args()
    repo = repository_root(args.repository_root)
    kb = repo / "kb"
    artifact = repo / "build" / "longterm" if (repo / "build" / "longterm" / "kb-source-map.jsonl").is_file() else repo / "build"
    maps, sources = read_jsonl(artifact / "kb-source-map.jsonl"), read_jsonl(artifact / "source-manifest.jsonl")
    expected_titles = {}
    expected_counts = {}
    for topic in range(1, 26):
        rows = [row for row in maps if int(row["topic_id"]) == topic]
        expected_titles[topic] = display_topic_title(repo, topic, rows[0]["topic_title"])
        expected_counts[topic] = len({row["source_id"] for row in rows if row["assignment_role"] == "primary"})
    source_by_id = {row["source_id"]: row for row in sources}
    errors: list[str] = []
    warnings: list[str] = []
    documents: list[dict] = []
    files = sorted(path for path in kb.glob("*.md") if re.match(r"^(0[1-9]|1\d|2[0-5])-.+\.md$", path.name))
    if len(files) != 25:
        errors.append(f"kb/ contains {len(files)} Markdown files; expected 25.")
    appendix_name, appendix_path = "26-all-texts.md", kb / "26-all-texts.md"
    try:
        appendix_text = appendix_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        appendix_text = ""; errors.append(f"Missing source appendix: kb/{appendix_name}.")
    except UnicodeDecodeError:
        appendix_text = ""; errors.append(f"{appendix_name}: invalid UTF-8.")
    seen: dict[int, str] = {}
    sections = ["## Overview", "## Core ideas", "## Principles and mental models", "## Recommended practices", "## Examples and stories", "## Tensions and contradictions", "## Caveats"]
    link_pattern = re.compile(r"\[(S\d{4})\]\((26-all-texts\.md#s\d{4})\)")
    all_citation_pattern = re.compile(r"\[S\d{4}\]")
    group_pattern = re.compile(r"\(\[S\d{4}\]\(26-all-texts\.md#s\d{4}\)(?:, \[S\d{4}\]\(26-all-texts\.md#s\d{4}\))*\)")
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            errors.append(f"{path.name}: invalid UTF-8."); continue
        identifier = re.search(r"(?m)^topic_id:\s*(\d+)\s*$", text)
        title = re.search(r"(?m)^title:\s*(.+?)\s*$", text)
        if not identifier or not title:
            errors.append(f"{path.name}: missing topic front matter."); continue
        topic = int(identifier.group(1)); seen[topic] = path.name
        if topic not in range(1, 26): errors.append(f"{path.name}: invalid topic ID {topic}.")
        if title.group(1) != expected_titles.get(topic): errors.append(f"{path.name}: title does not match topic {topic}.")
        if len(text) < 500: errors.append(f"{path.name}: document is too short.")
        if re.search(r"<think>|</think>", text): errors.append(f"{path.name}: contains leaked model reasoning.")
        if re.search(r"\[Paragraph with citations\]|\[Bullets/Paragraphs with citations\]|I need to synthesize the (provided )?notes|Check against constraints", text): errors.append(f"{path.name}: contains model-generation boilerplate or placeholders.")
        if re.search(r"(?s)^# [^\r\n]+\s*\r?\n\s*## Overview\s*\r?\n## ", text): errors.append(f"{path.name}: Overview section is empty.")
        for section in sections:
            if section not in text: errors.append(f"{path.name}: missing {section}.")
        if re.search(r"(?m)^## Sources\s*$", text): errors.append(f"{path.name}: contains a deprecated Sources section.")
        source_count = re.search(r"(?m)^source_count:\s*(\d+)\s*$", text)
        if not source_count or int(source_count.group(1)) != expected_counts.get(topic): errors.append(f"{path.name}: source_count does not match its primary source-map entries.")
        links = [{"id": match.group(1), "url": match.group(2)} for match in link_pattern.finditer(text)]
        inline = sorted(set(match.strip("[]") for match in all_citation_pattern.findall(text)))
        if not inline: warnings.append(f"{path.name}: no inline source citations.")
        if len(links) != len(all_citation_pattern.findall(text)): errors.append(f"{path.name}: every inline citation must link to the source appendix.")
        without_groups = group_pattern.sub("", text)
        if link_pattern.search(without_groups): errors.append(f"{path.name}: citations must be enclosed in one complete comma-separated group.")
        for citation in links:
            source = source_by_id.get(citation["id"])
            if source is None: errors.append(f"{path.name}: unknown source {citation['id']}.")
            elif not source["included_in_synthesis"]: errors.append(f"{path.name}: excluded duplicate or empty source {citation['id']} was cited.")
            elif citation["url"] != f"{appendix_name}#{citation['id'].lower()}": errors.append(f"{path.name}: citation {citation['id']} does not link to its source appendix anchor.")
            elif f'<a id="{citation["id"].lower()}"></a>' not in appendix_text: errors.append(f"{path.name}: citation {citation['id']} has no matching appendix anchor.")
        documents.append({"topic_id": topic, "file": path.name, "source_links": len(links), "inline_citations": len(inline), "bytes": len(text)})
    for topic in range(1, 26):
        if topic not in seen: errors.append(f"Missing KB document for topic {topic}.")
    for filename, expression, message in [("25-non-substantive-material.md", r"There are no recommended practices", "Topic 25 lacks an explicit non-advisory boundary."), ("14-health-testosterone-and-vitality.md", r"speculative|unsupported|not supported|not.*clinical", "Health document lacks a speculative/unsupported-claim caution."), ("19-marriage-women-and-gender-dynamics.md", r"gendered|misogyn", "Gender-dynamics document lacks a gendered-framing caution."), ("22-social-conditioning-and-genjutsu.md", r"political|partisan", "Genjutsu document lacks a political-claim caution.")]:
        content = (kb / filename).read_text(encoding="utf-8")
        if not re.search(expression, content, re.IGNORECASE): errors.append(message)
    coverage = []
    for topic in range(1, 26):
        rows = [row for row in maps if int(row["topic_id"]) == topic]
        primary = [row for row in rows if row["assignment_role"] == "primary"]
        coverage.append({"topic_id": topic, "topic_title": expected_titles[topic], "primary_passages": len({row["passage_id"] for row in primary}), "secondary_passages": len({row["passage_id"] for row in rows if row["assignment_role"] == "secondary"}), "distinct_sources": len({row["source_id"] for row in primary}), "low_confidence_passages": len({row["passage_id"] for row in rows if row.get("confidence") == "low"})})
    groups: dict[int, list[dict]] = defaultdict(list)
    for row in maps:
        if row.get("confidence") == "low": groups[int(row["topic_id"])].append(row)
    low_confidence = [{"topic_id": topic, "passage_ids": sorted({row["passage_id"] for row in rows})} for topic, rows in sorted(groups.items())]
    primary_rows = [row for row in maps if row["assignment_role"] == "primary"]
    report = {"generated_at": utc_now(), "status": "failed" if errors else "passed", "source_manifest_summary": {"canonical_sources": sum(row["included_in_synthesis"] for row in sources), "canonical_sources_used": len({row["source_id"] for row in primary_rows}), "excluded_empty_or_duplicate_copies": sum(not row["included_in_synthesis"] for row in sources)}, "passage_coverage": {"total_primary_passages": len({row["passage_id"] for row in primary_rows}), "total_secondary_assignments": sum(row["assignment_role"] == "secondary" for row in maps), "by_topic": coverage}, "unresolved_ambiguities": low_confidence, "documents": sorted(documents, key=lambda row: row["topic_id"]), "errors": errors, "warnings": warnings, "manual_boundary_review": ["Identity vs. confidence", "Ghost Mode vs. brotherhood", "Discipline vs. professionalism", "Masculinity vs. gender dynamics", "Technology vs. Genjutsu", "Spirituality vs. manifestation within goal-setting"]}
    write_json(artifact / "kb-validation-report.json", report)
    print(f"Validation {report['status']}: {len(errors)} error(s), {len(warnings)} warning(s). Report: {artifact / 'kb-validation-report.json'}")
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
