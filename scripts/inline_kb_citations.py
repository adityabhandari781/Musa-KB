"""Link source IDs in KB documents to the generated source appendix."""

from __future__ import annotations

import argparse
import re

from kb_common import read_jsonl, repository_root


LINK = r"\[S\d{4}\]\([^\)]+\)"
GAP = r"[ \t\u00A0\u202F]*"
CLUSTER = re.compile(r"(?<!\w)\(*" + GAP + LINK + r"(?:" + GAP + r"\)*" + GAP + r"(?:," + GAP + r")?\(*" + GAP + LINK + r")*" + GAP + r"\)*")


def format_citation_runs(text: str) -> str:
    return CLUSTER.sub(lambda match: "(" + ", ".join(re.findall(LINK, match.group())) + ")", text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    parser.add_argument("--source-appendix", default="26-all-texts.md")
    args = parser.parse_args()
    repo = repository_root(args.repository_root)
    artifact = repo / "build" / "longterm" if (repo / "build" / "longterm" / "source-manifest.jsonl").is_file() else repo / "build"
    source_ids = {row["source_id"] for row in read_jsonl(artifact / "source-manifest.jsonl")}
    files = sorted(path for path in (repo / "kb").glob("*.md") if re.match(r"^(0[1-9]|1\d|2[0-5])-.+\.md$", path.name))
    if len(files) != 25:
        raise ValueError(f"Expected 25 numbered topic documents; found {len(files)}.")
    citation = re.compile(r"\[(S\d{4})\](?:\([^\)]*\))?")
    for path in files:
        text = re.sub(r"(?ms)^## Sources\s*$.*\Z", "", path.read_text(encoding="utf-8")).rstrip()
        unknown: list[str] = []
        def replace(match: re.Match[str]) -> str:
            source_id = match.group(1)
            if source_id not in source_ids:
                unknown.append(source_id); return match.group()
            return f"[{source_id}]({args.source_appendix}#{source_id.lower()})"
        text = format_citation_runs(citation.sub(replace, text))
        if unknown:
            raise ValueError(f"{path.name} contains unknown source ID(s): {', '.join(unknown)}.")
        path.write_text(text.rstrip() + "\n", encoding="utf-8", newline="\n")
        print(f"Linked citations and removed Sources: {path.name}")


if __name__ == "__main__":
    main()
