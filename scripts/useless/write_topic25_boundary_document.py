"""Archived Python replacement for write_topic25_boundary_document.ps1."""
from __future__ import annotations
import argparse, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from kb_common import read_jsonl, repository_root

BODY = '''## Overview

This document records the material intentionally excluded from the substantive knowledge base: promotions, engagement requests, banter, low-context media, and topical commentary that does not contain a self-contained lesson. It remains traceable to the source corpus, but is not presented as practical, scientific, financial, or relationship guidance. {citations}

## Core ideas

- The category preserves source traceability without promoting short, context-dependent, or engagement-driven material into a general principle.
- It separates announcements, giveaways, jokes, reactions, and incomplete media from passages whose substantive lesson belongs in one of Topics 1–24.
- A topical reference may be useful only when its broader lesson is explicit; otherwise it remains here as contextual material.

## Principles and mental models

- **Traceability without endorsement:** retention in the KB does not imply that a claim is supported, advisable, or representative of a broader framework.
- **Context threshold:** a passage needs enough self-contained reasoning to support a topic document; a slogan, title, or reaction clip generally does not meet that threshold.
- **Boundary-first routing:** where a clear lesson exists, it belongs with that lesson's substantive topic rather than being retained here merely because its delivery is humorous or provocative.

## Recommended practices

There are no recommended practices in this category. Treat these entries as source records and review the original material before relying on any claim or anecdote.

## Examples and stories

Representative entries include engagement-led posts, short promotional messages, low-context references, and commentary without sufficient supporting explanation. {citations}

## Tensions and contradictions

Some source items mix commentary with a possible lesson. The source map assigns a passage to a substantive topic when the lesson is clear enough to stand alone; Topic 25 remains a safeguard against turning rhetorical style, publicity, or fragmented context into advice.

## Caveats

This category may contain unverified medical, political, financial, interpersonal, or strongly gendered claims. None should be treated as established fact or followed literally without appropriate independent evidence and context. The category is descriptive of corpus handling, not an endorsement of the creator's rhetoric.'''

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--repository-root', default=None); args = parser.parse_args(); repo = repository_root(args.repository_root)
    rows = [row for row in read_jsonl(repo / 'build' / 'kb-source-map.jsonl') if int(row['topic_id']) == 25 and row['assignment_role'] == 'primary']
    if not rows: raise ValueError('Topic 25 has no primary source-map rows.')
    sources = {row['source_id']: row['relative_path'].replace('\\','/') for row in rows}; examples = sorted(sources)[:4]; citations = ''.join(f'[{item}]' for item in examples)
    header = f"---\ntopic_id: 25\ntitle: Non-substantive material\nstatus: synthesized\nsource_count: {len(sources)}\nsource_scope:\n  - data/texts\n  - data/transcripts\n---\n\n# Non-substantive material\n\n"
    source_list = '\n'.join(f'- [{item}](../{sources[item]})' for item in sorted(sources))
    (repo / 'kb' / '25-non-substantive-material.md').write_text(header + BODY.format(citations=citations) + '\n\n## Sources\n\n' + source_list + '\n', encoding='utf-8', newline='\n')
    print(f'Wrote Topic 25 boundary document with {len(sources)} source links.')
if __name__ == '__main__': main()
