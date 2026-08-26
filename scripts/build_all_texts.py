"""Build the source appendix used by inline KB citations."""

from __future__ import annotations

import argparse
from pathlib import Path

from kb_common import read_jsonl, repository_root


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    args = parser.parse_args()
    repo = repository_root(args.repository_root)
    kb = repo / "kb"
    artifact_root = repo / "build" / "longterm" if (repo / "build" / "longterm" / "source-manifest.jsonl").is_file() else repo / "build"
    sources = sorted(read_jsonl(artifact_root / "source-manifest.jsonl"), key=lambda row: int(row["source_id"][1:]))
    text_files = sorted((repo / "data" / "texts").glob("*.txt")) + sorted((repo / "data" / "transcripts").glob("*.txt"))
    lines = ["# All texts and transcripts", "", "This appendix contains the full corpus used by the knowledge base. Topic citations link to the matching S#### anchor below.", ""]
    written: set[str] = set()
    for source in sources:
        relative = source["relative_path"]
        path = repo / Path(relative)
        if not path.is_file():
            continue
        written.add(relative)
        content = path.read_text(encoding="utf-8").rstrip()
        lines += [f'<a id="{source["source_id"].lower()}"></a>', f'## {source["source_id"]} — {relative}', "", f"Source file: {relative}", "", content or "_Empty file._", "", "---", ""]
    for path in text_files:
        relative = path.relative_to(repo).as_posix()
        if relative in written:
            continue
        content = path.read_text(encoding="utf-8").rstrip()
        lines += [f"## Unmapped file — {relative}", "", f"Source file: {relative}", "", content or "_Empty file._", "", "---", ""]
    output = kb / "26-all-texts.md"
    output.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8", newline="\n")
    print(f"Built {output} with {len(sources)} mapped sources and {len(text_files) - len(written)} unmapped files.")


if __name__ == "__main__":
    main()
