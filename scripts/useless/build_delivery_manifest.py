"""Archived Python replacement for build_delivery_manifest.ps1."""
from __future__ import annotations
import argparse, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kb_common import repository_root, utc_now, write_json

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--repository-root', default=None); args = parser.parse_args(); repo = repository_root(args.repository_root)
    required = ['kb','build/source-manifest.jsonl','build/passage-manifest.jsonl','build/kb-source-map.jsonl','build/kb-validation-report.json','scripts/validate_kb.py']
    artifacts = [{"path": item, "exists": (path := repo / item).exists(), "kind": "directory" if path.is_dir() else "file", "bytes": path.stat().st_size if path.is_file() else None} for item in required]
    files = sorted(item.name for item in (repo / 'kb').glob('*.md'))
    report = __import__('json').loads((repo / 'build' / 'kb-validation-report.json').read_text(encoding='utf-8'))
    result = {"generated_at": utc_now(), "delivery_status": "complete" if report['status'] == 'passed' and len(files) == 25 and all(item['exists'] for item in artifacts) else "incomplete", "kb_document_count": len(files), "kb_documents": files, "validation_report": "build/kb-validation-report.json", "artifacts": artifacts}
    write_json(repo / 'build' / 'delivery-manifest.json', result); print(f"Delivery manifest: {result['delivery_status']}.")
    if result['delivery_status'] != 'complete': raise SystemExit(1)
if __name__ == '__main__': main()
