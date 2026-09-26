# Homepage Knowledge-Base Chat Tasks

Source: [implementation plan](plan.md) and
[approved specification](../SPEC-homepage-chat.md).

## Phase 1: Retrieval and AI boundary

- [x] Task 1: Build the tested retrieval slice.
  - Acceptance: Confirm the generated search-index contract; implement
    deterministic field-weighted BM25 ranking, exclusions, deduplication, a
    three-result limit, and a 12,000-character context limit.
  - Verify: Observe RED, then pass
    `node --test tests/homepage-chat.test.mjs` and `mkdocs build --strict`.
  - Dependencies: None.
  - Files: `kb/assets/javascripts/chat.js`,
    `tests/homepage-chat.test.mjs`.
- [x] Task 2: Add the tested bounded prompt and Puter adapter.
  - Acceptance: Build grounded prompts; lazy-load Puter; reject invalid/no-match
    requests; normalize external failures without credentials or a fixed model.
  - Verify: Observe RED for new cases, then pass
    `node --test tests/homepage-chat.test.mjs`; inspect for eager loads/secrets.
  - Dependencies: Task 1.
  - Files: `kb/assets/javascripts/chat.js`,
    `tests/homepage-chat.test.mjs`.

## Checkpoint: Logic and external boundary

- [x] Focused tests pass and the strict MkDocs build is clean.
- [x] The real fear question ranks confidence/resilience content.
- [x] Tests demonstrate bounds and the no-match/no-AI-call path.

## Phase 2: Homepage experience

- [x] Task 3: Deliver the accessible homepage chat flow.
  - Acceptance: Add semantic homepage markup, disclosure, all UI states,
    keyboard behavior, trusted source links, and responsive Material-native
    styles; keep article pages unaffected.
  - Verify: Pass `node --test tests/homepage-chat.test.mjs` and
    `mkdocs build --strict`; inspect the built HTML/assets for form and secrets.
  - Dependencies: Tasks 1 and 2.
  - Files: `kb/index.md`, `kb/assets/stylesheets/chat.css`,
    `kb/assets/javascripts/chat.js`, `mkdocs.yml`.

## Checkpoint: Complete local feature

- [x] Tests and strict build pass.
- [x] Homepage flow is present and article pages remain unaffected.
- [x] No dependency, backend, credential, storage, or unrelated refactor exists.

## Phase 3: Runtime verification and review

- [ ] Task 4: Verify the production flow in a real browser.
  - Acceptance: Verify live retrieval/Puter answer, keyboard/accessibility
    behavior, source links, themes, target widths, no-match/error recovery, and
    clean consoles.
  - Verify: Capture answered/no-match/error evidence; confirm lazy Puter network
    load; rerun focused tests and strict build after any corrective edit.
  - Dependencies: Task 3.
  - Files: None unless a minimal Task 3 correction is required.
  - Note: Homepage, no-match, account-required dialog (Cancel/Proceed), lazy
    Puter sign-in, timeout/error, responsive, theme, accessibility, and
    article-isolation checks passed. A successful AI answer still requires a
    real Puter sign-in and was not performed with credentials.
- [ ] Task 5: Complete final quality and scope review.
  - Acceptance: Meet the spec and Definition of Done with no unnecessary code,
    unsafe rendering, secrets, or unrelated changes; prepare human handoff only.
  - Verify: Pass `node --test tests/homepage-chat.test.mjs`,
    `python scripts/validate_kb.py`, `mkdocs build --strict`,
    `git diff --check`, and the final browser smoke check.
  - Dependencies: Task 4.
  - Files: Existing feature files only if review requires a correction.

## Checkpoint: Ready for human review

- [ ] Every task acceptance criterion and the Definition of Done is met.
- [ ] Automated, validation, build, and browser evidence is recorded.
- [ ] Human review occurs before any merge or deployment.
