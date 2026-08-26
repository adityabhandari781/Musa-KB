## Implementation plan

I inspected the corpus:

- 1,096 files in `data/texts/` — mostly short captions/posts
- 605 files in `data/transcripts/` — mostly substantive long-form material
- About 200,000 words total
- 23 empty transcripts
- 25 groups of exact duplicates
- `data/media/` will remain out of scope unless explicitly requested

### 1. Define the output contract

Create exactly 25 files under `kb/`, numbered to match [topics.md](C:/Users/adity/Desktop/code/GitHub/Musa-KB-New/data/topics.md):

```text
kb/
├── 01-identity-and-self-reinvention.md
├── 02-ghost-mode-and-environmental-separation.md
├── ...
├── 24-community-and-alternative-living.md
└── 25-non-substantive-material.md
```

Each topic file will use a consistent structure:

```markdown
---
topic_id: 1
title: Identity and self-reinvention
source_count: 42
---

# Identity and self-reinvention

## Overview
## Core ideas
## Principles and mental models
## Recommended practices
## Examples and stories
## Tensions and contradictions
## Caveats
## Sources
```

Topic 25 will instead summarize and classify promotional, banter, low-context, and topical-commentary material.

### 2. Inventory and normalize the sources

Build a source manifest for every file in `texts/` and `transcripts/`, recording:

- Stable source ID
- Original relative path
- Date/time derived from filename
- Source type
- Word count
- Content hash
- Associated caption/transcript when identifiable

Normalize all content to UTF-8, line endings, whitespace, and typographic characters. Empty files are excluded, while duplicate files are represented once with all original paths recorded.

### 3. Divide sources into coherent passages

Long transcripts will be segmented by paragraph or semantic boundary so one recording can contribute to multiple topics. Short text posts will normally remain single passages.

Each passage retains its source ID and original path, ensuring later summaries remain traceable.

### 4. Classify passages against the 25 topics

Use multi-label classification because one passage may cover several topics—for example, discipline, masculinity, and fitness.

For each passage, record:

- Primary topic
- Optional secondary topics
- Relevance/confidence score
- Short classification rationale
- Whether it is substantive or belongs primarily in topic 25

Ambiguous and low-confidence assignments receive a separate review pass.

### 5. Build a traceable source map

Create a temporary build artifact outside `kb/`, such as:

```text
build/kb-source-map.jsonl
```

This maps every topic to its supporting passages. It prevents information loss, makes reruns reproducible, and allows every important claim in the KB to cite one or more source files.

### 6. Synthesize the topic documents

For each topic:

- Consolidate repeated ideas instead of concatenating transcripts.
- Extract principles, frameworks, exercises, examples, and recurring arguments.
- Preserve meaningful disagreements or evolution over time.
- Distinguish the creator’s claims from established facts.
- Avoid inventing conclusions absent from the corpus.
- Add explicit cautions around speculative health claims, misogynistic framing, political claims, and similar sensitive content.
- Reference sources using stable IDs linked to their original files.

Raw profanity can be paraphrased unless its exact wording is important to the idea.

### 7. Quality-control pass

Validate automatically that:

- `kb/` contains exactly 25 Markdown files.
- Every topic from `topics.md` has one corresponding file.
- No topic document is empty.
- All cited source paths exist.
- Empty and duplicate sources did not create duplicate knowledge.
- Topic 25 has not absorbed substantive lessons merely because they use commentary or humor.
- Unsupported medical or scientific claims are clearly labeled.
- Markdown and UTF-8 encoding are valid.

Then manually review topic boundaries, especially:

- Identity vs. confidence
- Ghost Mode vs. brotherhood
- Discipline vs. professionalism
- Masculinity vs. gender dynamics
- Technology vs. Genjutsu
- Spirituality vs. manifestation within goal-setting

### 8. Deliverables

The implementation should produce:

- `kb/` containing exactly the 25 final topic documents
- A reproducible source manifest/classification map under `build/`
- A small build/validation script under `scripts/`
- A validation report showing source coverage, duplicates removed, passages per topic, and unresolved ambiguities

No files have been changed yet; this is the proposed implementation plan.