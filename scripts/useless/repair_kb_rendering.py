"""Archived Python replacement for repair_kb_rendering.ps1."""
from __future__ import annotations
import argparse, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kb_common import read_jsonl, repository_root, utc_now, write_json

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--repository-root', default=None); args = parser.parse_args(); repo = repository_root(args.repository_root); build, kb = repo / 'build', repo / 'kb'
    maps = read_jsonl(build / 'kb-source-map.jsonl'); finals = {int(row['topic_id']): row for row in read_jsonl(build / 'llm-kb-hierarchical-synthesis-checkpoint.jsonl') if row['kind'] == 'final'}; rendered, regenerate = [], []
    for topic in range(1, 26):
        rows = [row for row in maps if int(row['topic_id']) == topic and row['assignment_role'] == 'primary']
        if topic not in finals or not rows: regenerate.append(topic); continue
        content = finals[topic]['content']; occurrences = list(re.finditer(r'(?m)^## Overview\s*$', content))
        if not occurrences: regenerate.append(topic); continue
        body = content[occurrences[-1].start():].strip()
        if topic == 16: body = re.sub(r'(?m)^\*\*(Overview|Core ideas|Principles and mental models|Recommended practices|Examples and stories|Tensions and contradictions|Caveats):\*\*', r'## \1', body)
        body = re.sub(r'(?s)\n(?:Check against constraints:|\*\*Check Constraints.*|\d+\.\s+\*\*Check Constraints.*).*$', '', body).strip(); title = rows[0]['topic_title']; sources = {row['source_id']: row['relative_path'].replace('\\','/') for row in rows}
        target = next(path for path in kb.glob('*.md') if re.search(rf'(?m)^topic_id:\s*{topic}\s*$', path.read_text(encoding='utf-8')))
        header = f"---\ntopic_id: {topic}\ntitle: {title}\nstatus: synthesized\nsource_count: {len(sources)}\nsource_scope:\n  - data/texts\n  - data/transcripts\n---\n\n# {title}\n\n"; links = '\n'.join(f'- [{item}](../{sources[item]})' for item in sorted(sources)); target.write_text(header + body + '\n\n## Sources\n\n' + links + '\n', encoding='utf-8', newline='\n'); rendered.append(topic)
    write_json(build / 'kb-rendering-repair-report.json', {'rendered_topic_ids': rendered, 'regeneration_required_topic_ids': regenerate, 'generated_at': utc_now()}); print(f"Re-rendered {len(rendered)} documents. Regeneration required: {', '.join(map(str, regenerate))}.")
if __name__ == '__main__': main()
