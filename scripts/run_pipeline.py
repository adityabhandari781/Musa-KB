"""Run the portable fetch, transcription, and incoming-source ingestion pipeline."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys

from kb_common import repository_root


def run(repo, script, *arguments):
    subprocess.run([sys.executable, str(repo / "scripts" / script), *arguments], cwd=repo, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    parser.add_argument("--transcription-mode", choices=["cloud", "local"], default="cloud")
    args = parser.parse_args(); repo = repository_root(args.repository_root)
    run(repo, "fetch.py")
    run(repo, "cloud_transcription.py" if args.transcription_mode == "cloud" else "local_transcription.py")
    incoming = repo / "data" / "incoming"
    while any(directory.is_dir() and any(directory.glob("*.txt")) for directory in [incoming / "texts", incoming / "transcripts"]):
        run(repo, "ingest_oldest_incoming.py", "--repository-root", str(repo))
    if incoming.exists():
        expected = (repo / "data" / "incoming").resolve()
        if incoming.resolve() != expected: raise RuntimeError(f"Refusing to delete unexpected incoming path: {incoming}")
        shutil.rmtree(incoming)
        print("Removed completed data/incoming queue.")
    print("Integrated pipeline complete.")


if __name__ == "__main__":
    main()
