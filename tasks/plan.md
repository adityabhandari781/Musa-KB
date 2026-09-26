# Implementation Plan: Homepage Knowledge-Base Chat

## Overview

Implement the approved [homepage chat spec](../SPEC-homepage-chat.md) as a
small browser-only enhancement to the existing MkDocs site. The implementation
reuses MkDocs' generated search index for lexical retrieval, loads Puter.js only
after a visitor explicitly submits a question with relevant context, and renders
plain-text answers with independently derived source links.

Tasks are tracked in [`tasks/todo.md`](todo.md).

## Dependency Graph

```text
Search-index contract
        │
        ▼
Tested retrieval and bounded prompt logic
        │
        ▼
Homepage form, styles, and UI state integration
        │
        ▼
Production build and real-browser verification
        │
        ▼
Review, simplify, and hand off
```

The work is sequential. Retrieval, prompting, and the UI share one deliberately
small JavaScript module, so parallel edits would add merge coordination without
shortening the critical path.

## Architecture Decisions

- Reuse `search/search_index.json`; do not create a second content index,
  backend, vector store, or build script.
- Keep ranking deterministic and lexical with field-weighted BM25 over the
  eligible topic sections. Measure failures before considering semantic
  retrieval.
- Put pure retrieval and prompt construction functions in the same browser
  script as the UI. Expose only those functions to Node tests; do not add a
  bundler or utility abstraction.
- Load Puter.js dynamically after explicit submission and successful retrieval,
  so normal browsing has no Puter network request or SDK cost.
- Treat search-index text and AI output as untrusted. Context is delimited in
  the prompt, answers use `textContent`, and displayed source URLs come only
  from the MkDocs index.
- Use MkDocs Material theme variables for light/dark styling rather than
  inventing a separate design system.
- Do not pin an AI model. Use Puter's supported default to reduce churn.

## Implementation Sequence

### Phase 1: Retrieval and AI boundary

#### Task 1: Build the tested retrieval slice

**Description:** Inspect a real MkDocs build to confirm the generated search
index shape, then use red-green-refactor to implement only the pure
normalization, filtering, ranking, deduplication, and context-limiting logic.

**Acceptance criteria:**

- [ ] A real generated index confirms the fields and locations used by the
      implementation; no undocumented runtime search internals are required.
- [ ] Retrieval excludes the homepage and appendix, ranks with field-weighted
      BM25 deterministically, and returns at most three distinct locations.
- [ ] Blank, unrelated, oversized, and duplicate inputs respect the spec's
      no-match and 12,000-character boundaries.

**Verification:**

- [ ] RED is observed before implementation for the focused retrieval tests.
- [ ] GREEN passes with `node --test tests/homepage-chat.test.mjs`.
- [ ] `mkdocs build --strict` succeeds and produces `site/search/search_index.json`.

**Dependencies:** None

**Files likely touched:**

- `kb/assets/javascripts/chat.js`
- `tests/homepage-chat.test.mjs`

**Estimated scope:** Small (2 files)

#### Task 2: Add the tested bounded prompt and Puter adapter

**Description:** Extend the same module with a grounded prompt builder, lazy
Puter.js loader, a single-generation adapter, input limits, and normalized
external-error handling. Keep DOM rendering out of this slice.

**Acceptance criteria:**

- [ ] The prompt contains the question, named/delimited bounded excerpts, and
      the grounding, prompt-injection, insufficiency, concision, and
      professional-advice instructions from the spec.
- [ ] Puter.js is not loaded or called for blank/invalid questions or empty
      retrieval results, and concurrent SDK loads share one promise.
- [ ] Authentication, quota, SDK-load, network, and generation failures become
      a safe user-facing error without leaking stack traces or raw responses.

**Verification:**

- [ ] RED is observed for new prompt/boundary tests before implementation.
- [ ] GREEN passes with `node --test tests/homepage-chat.test.mjs`.
- [ ] Review confirms no API key, token, fixed model, or eager Puter load exists.

**Dependencies:** Task 1

**Files likely touched:**

- `kb/assets/javascripts/chat.js`
- `tests/homepage-chat.test.mjs`

**Estimated scope:** Small (2 files)

### Checkpoint: Logic and external boundary

- [ ] All focused tests pass.
- [ ] Retrieval against the generated corpus ranks confidence/resilience content
      for "How do I overcome my fears?".
- [ ] Bounds and the no-match/no-AI-call path are demonstrated by tests.
- [ ] The strict MkDocs build remains clean.

### Phase 2: Homepage experience

#### Task 3: Deliver the accessible homepage chat flow

**Description:** Add the semantic homepage form, disclosure, status/answer/source
regions, Material-native responsive styles, asset registration, and minimal DOM
controller that connects Tasks 1-2 into the complete user flow.

**Acceptance criteria:**

- [ ] The chat appears only on the homepage between the introduction and About
      section, with visible labeling, privacy/sign-in disclosure, a useful
      no-JavaScript fallback, and no UI on article pages.
- [ ] Button and Ctrl/Cmd+Enter submission implement ready, searching, waiting,
      answered, no-match, and safe error states; duplicate submission is
      disabled and failed questions remain editable.
- [ ] AI output uses `textContent`, source links use index locations, status is
      announced with `aria-live`, focus is visible, and the layout works from
      320px upward in both Material palettes.

**Verification:**

- [ ] `node --test tests/homepage-chat.test.mjs` passes.
- [ ] `mkdocs build --strict` succeeds.
- [ ] Static inspection of the built homepage confirms the form, local assets,
      and no embedded credential.

**Dependencies:** Tasks 1 and 2

**Files likely touched:**

- `kb/index.md`
- `kb/assets/stylesheets/chat.css`
- `kb/assets/javascripts/chat.js`
- `mkdocs.yml`

**Estimated scope:** Medium (4 files)

### Checkpoint: Complete local feature

- [ ] Automated tests and strict build pass.
- [ ] The built homepage contains the full chat flow and article pages remain
      unaffected.
- [ ] The diff contains no new dependency, backend, credential, conversation
      storage, or unrelated refactor.

### Phase 3: Runtime verification and review

#### Task 4: Verify the production flow in a real browser

**Description:** Serve the production-equivalent site and exercise the critical
path and failure paths in a real browser. Fix only defects required by the spec,
rerunning the affected check after each fix.

**Acceptance criteria:**

- [ ] The example fear question retrieves and links confidence/resilience
      material, then obtains a grounded answer through Puter after any required
      visitor sign-in.
- [ ] Keyboard behavior, focus, live status, retry behavior, source navigation,
      light/dark mode, and 320/768/1024/1440px layouts match the spec.
- [ ] No-match and simulated network/service failure leave the knowledge base
      usable, and homepage/article consoles contain no application errors.

**Verification:**

- [ ] Capture browser evidence for the answered, no-match, and error states.
- [ ] Inspect network activity to confirm Puter loads only after a relevant
      submitted question.
- [ ] Run `node --test tests/homepage-chat.test.mjs` and
      `mkdocs build --strict` after any runtime-driven code change.

**Dependencies:** Task 3

**Files likely touched:**

- No files unless runtime verification exposes a spec defect; then only the
  smallest relevant file from Task 3.

**Estimated scope:** Small (verification, 0-2 corrective files)

#### Task 5: Complete final quality and scope review

**Description:** Review the final diff for correctness, accessibility, security,
simplicity, and scope; remove unnecessary code without changing behavior, then
run the complete repository checks and prepare the handoff.

**Acceptance criteria:**

- [ ] The final diff satisfies every spec success criterion and contains no
      avoidable abstraction, dead/debug code, unsafe rendering, secret, or
      unrelated change.
- [ ] User-facing behavior is documented by the homepage copy and the spec;
      source and external-service boundaries are clear.
- [ ] Repository status and the exact changed files are reported for human
      review; no commit, push, or deployment occurs without a separate request.

**Verification:**

- [ ] `node --test tests/homepage-chat.test.mjs` passes.
- [ ] `python scripts/validate_kb.py` passes.
- [ ] `mkdocs build --strict` passes.
- [ ] `git diff --check` passes and the final browser smoke check is clean.

**Dependencies:** Task 4

**Files likely touched:**

- Existing feature files only if review finds a required simplification or fix.

**Estimated scope:** Small (review, 0-2 corrective files)

### Checkpoint: Ready for human review

- [ ] All task acceptance criteria and the project Definition of Done are met.
- [ ] Automated, build, validation, and browser evidence are recorded.
- [ ] The implementation matches the approved scope and is ready for human
      review before merge or deployment.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Generated search-index schema or URLs differ from assumptions | High | Inspect an actual strict build before implementing retrieval; test filtering and base-path-safe locations. |
| Lexical retrieval misses synonyms such as "fear" vs. "confidence" | Medium | Test the real example early; use BM25 over titles and article bodies. Do not add embeddings without measured need. |
| Puter authentication, quota, or availability interrupts answers | High | Keep retrieval local, load Puter lazily, expose actionable errors, preserve the question, and leave site search/navigation usable. |
| Corpus text attempts prompt injection | Medium | Delimit context, explicitly classify it as untrusted reference material, bound it, and never execute or render it as HTML. |
| AI generates fabricated citations or unsafe markup | High | Render answer text with `textContent`; construct source links solely from trusted index locations. |
| MkDocs instant navigation initializes the script more than once | Medium | Make initialization idempotent and no-op without the homepage root; verify navigation in browser. |
| Third-party SDK slows ordinary page loads | Low | Do not include Puter globally at build time; inject it only after a relevant explicit submission. |
| Browser-only AI is mistaken for anonymous/free unlimited service | Medium | Keep the pre-submit Puter sign-in and user-pays disclosure visible. |

## Open Questions

None. The approved spec resolves the product and architecture choices. Any need
for a dependency, backend, conversation history, analytics, semantic index, or
expanded third-party data requires a new approval before implementation.
