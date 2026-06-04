# planscanR — Consistency / Docs / Schema Refactor — Plans.md

Created: 2026-06-04
Scope: the `planscanR` leaf package only (this repo). Branch + commits are
per-package per the family convention. Cross-package touches (sidecar v3 reader)
are called out explicitly and committed in dependency order.

Spec SSOT for this refactor: `docs/spec/contract.md` (created in Task 1.1).

---

## Spec delta

Target: **new file** `docs/spec/contract.md` (the package's Output & Sidecar
product contract — first stable SSOT for what a record looks like in memory and
on disk). It fixes, ahead of any code change:

- **Core columns**: the column set EVERY `get_assessments_*()` is guaranteed to
  return (`country, source_portal, document_id, url, retrieved_at, title,
  summary, competent_authority, proponent, date_decision, attachment_urls,
  local_path, download_status`, + relevance/class columns when scored). Downstream
  joins may rely only on these.
- **Non-core / portal-native columns**: kept, but documented as not guaranteed
  across countries; naming convention = English snake_case (translate
  `aktenzahl`→`file_number`, `rechtsgrundlagen`→`legal_basis`,
  `standort_gemeinden`→`municipalities`, …), no value remapping.
- **Sidecar schema v3**: all on-disk paths (`geometry_path`, `files[].local_path`)
  stored RELATIVE to the cache root and absolutised on read; duplicated
  `relevance_score_*` keys removed from `extras` (the structured
  `relevance_scores[]` array is canonical); `native_type`/`dossier_type`
  de-duplicated; all timestamps ISO-8601 UTC with trailing `Z`.
- **Extensibility rule**: new fields land in `extras{}` with an English
  snake_case key; first-class promotion requires a contract update + schema bump.

Consumer (you) approves or edits this delta; Harness generated it from the scan.

---

## Phase 0: Clean baseline & branch

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 0.1 | Review the 19 uncommitted files on `main` (12 handlers + 6 tests + man/get_assessments_ie.Rd). Track `R/utils_crawl.R`. Relocate `ESTONIA_CHAT.md` → `docs/dev/notes/estonia.md` (or delete). Commit as the in-flight work. `[tdd:skip:in-flight-commit]` | `git status` clean on `main`; one commit captures the in-flight diff; no untracked source files | - | cc:完了 [47b6d9f] |
| 0.2 | Cut branch `refactor/consistency-docs-schema` from the now-clean `main`. `[tdd:skip:scaffold]` | Branch exists, checked out, `git status` clean | 0.1 | cc:完了 [fc2cbe9] |
| 0.3 | Pin the green baseline: run `air format R/` (air.toml present) to record current formatting, capture `R CMD check` result (currently 2 WARNINGs: vignettes not in `inst/doc`) and a `covr::package_coverage()` number into `docs/dev/refactor-baseline.md`. `[tdd:skip:baseline]` | Baseline file lists check status + coverage %; formatter run produces a reviewable diff committed separately | 0.2 | cc:完了 [cdc4c79] |

## Phase 1: Contract spec (write before touching schema/columns)

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 1.1 | Author `docs/spec/contract.md` per the Spec delta above: core columns, non-core convention, sidecar v3 shape, relative-path rule, extras English-key rule, extensibility rule. `[tdd:skip:docs-only]` | File exists; lists every core column with type; states v3 changes; reviewed/approved | 0.3 | cc:完了 [41ae18d] |

## Phase 2: Sidecar schema v3 (cross-package)

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 2.1 | Write failing tests: relative-path round-trip (`geometry_path` + `files[].local_path` stored relative to cache root, absolutised on read back to working paths); `extras` no longer carries `relevance_score_*`; timestamps end in `Z`; v2 + v1 sidecars still read (back-compat). `[tdd:required]` | New `test-sidecar-v3.R` red against current code | 1.1 | cc:完了 [7ba6d58] |
| 2.2 | Implement v3 in `R/utils_sidecar.R`: bump `SCHEMA_VERSION` to 3; write paths relative to cache root; stop copying `relevance_score_*` into `extras`; de-dup `native_type`/`dossier_type`; normalise all timestamps to UTC `Z`. Reader absolutises paths and still accepts v1/v2. `[tdd:required]` | 2.1 tests green; `assert_sidecar_schema` accepts ≤3; round-trip preserves data | 2.1 | cc:完了 [7c762f4] |
| 2.3 | Propagate v3 awareness to the 3 readers: `planscanR.screen`, `planscanR.biogain`, `planscanR.RAG` (assert/read v3, no behaviour change). One commit per package, in dependency order. `[tdd:required]` | Each package's tests green against a v3 sidecar fixture | 2.2 | cc:完了 (verified vs v3; no sibling code change needed) |
| 2.4 | One-shot cache upgrade: `migrate_sidecars_v3()` (or document that the merging writer rewrites v2→v3 lazily on next write). Re-index a tiny cache slice to confirm. `[tdd:required]` | Running it on a v2 fixture cache yields v3 sidecars with relative paths; `index_cache()` still returns identical tibble values | 2.2 | cc:完了 [b2b092a] |

## Phase 3: Output column contract (core + namespaced extras)

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 3.1 | Test that all 14 handlers + `empty_result_tibble()` return the guaranteed core columns (use existing fixtures; assert presence + type, and that `bind_rows()` across a mixed-country set is type-stable). `[tdd:required]` | `test-output-contract.R` covers all 14 countries; green | 1.1 | cc:完了 [ec6b68e] |
| 3.2 | Translate/namespace non-English extras keys to English snake_case across handlers (AT `aktenzahl`/`rechtsgrundlagen`/`standort_gemeinden`, BE/EE leaked codes, etc.). Naming only — no value remapping. Update fixtures/tests + sidecar round-trip. `[tdd:required]` | No non-English column names remain (grep clean); fixtures regenerated; tests green | 3.1, 2.2 | cc:完了 [baa706b] |
| 3.3 | Resolve coverage/facet drift: refresh the dated `coverage.R` snapshot note; reconcile DK `annex` (listed but not honoured) and EE `ksh_type` (column not arg) with the handlers; document facets-as-reference vs facets-as-filter. `[tdd:skip:metadata-reconcile]` | `get_assessments_coverage()` matches handler args; note dates current | 3.1 | cc:完了 [1bc2dfd] |

## Phase 4: Light DRY — shared date + slug helpers only

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 4.1 | Tests for shared helpers: `parse_iso_date()`, `parse_dmy()`, `parse_dutch_date()` (NL months), `parse_german_date()`, and `ascii_slug()` (transliterate→lower→collapse). Cover the locale edge cases the 11 current parsers handle. `[tdd:required]` | `test-utils-dates.R` / `test-utils-slug.R` cover every format in use; green against new helpers | 0.3 | cc:完了 [941b45b] |
| 4.2 | Extract the helpers into `R/utils_dates.R` / `R/utils_slug.R`; migrate the ~11 per-handler `*_parse_*_date()` and section-slug call sites to them. Leave per-handler fetch/download loops untouched. Behaviour-preserving. `[tdd:required]` | All country tests still green; duplicate parser/slug definitions removed; `R CMD check` no new notes | 4.1 | cc:完了 [16dfca2] |

## Phase 5: Cruft removal

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 5.1 | Remove dead micro-helpers (e.g. inline `nl_lookup`), confirm no commented-out code blocks remain, verify error handling is uniformly `cli_abort`/`warn_partial` (already mostly true — assert, don't churn). Ensure `ESTONIA_CHAT.md` handled (0.1) and no stray scratch files in repo root. `[tdd:skip:cleanup]` | `grep` finds no TODO/FIXME/dead helpers; repo root has no dev-scratch md; check still green | 4.2 | cc:完了 [0618c40] |

## Phase 6: End-user documentation

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 6.1 | Add a terminology glossary (vignette section + README) and apply it consistently: **record** = one result row, **assessment** = the EIA/SEA case type, **document/attachment** = the PDF, **offline metadata cache** instead of bare "sidecar" in user-facing text. `[tdd:skip:docs-only]` | Glossary present; one term per concept across README/vignettes/roxygen | 1.1 | cc:完了 [f146f1f] |
| 6.2 | De-jargon exported roxygen: drop/explain "load-bearing contract", "fan out", "round-trip", unexplained "Aktenzahl". Add runnable `@examples` to `get_assessments()`, `discover_attachments()`, `bind_results()` (the 3 exported fns missing them). `[tdd:skip:docs-only]` | `devtools::document()` clean; every exported fn has `@examples`; check `examples` OK | 6.1 | cc:完了 [4d11d80] |
| 6.3 | Condense `NEWS.md` (308 lines of pre-release handler churn → ~40 user-facing lines). Move per-country implementation detail into `vignettes/supported_sources.Rmd`. `[tdd:skip:docs-only]` | NEWS ≤ ~50 lines, user-facing; no implementation notes; supported_sources holds the per-country detail | 6.1 | cc:完了 [25a6634] |
| 6.4 | Vignettes: clarify the optional scoring section (show score columns), and mark each country's filters honestly as **working** vs **warned/aspirational** (NL already honest; align DE/others). Fix the `inst/doc` vignette WARNING so `R CMD check` is clean. `[tdd:skip:docs-only]` | `R CMD check` 0 WARNINGs on vignettes; filter status accurate per country | 6.1 | cc:完了 [66c6e86] |
| 6.5 | README: separate planscanR (fetcher) from planscanR.screen (scorer) clearly in the scoring section; tighten the landing page. `[tdd:skip:docs-only]` | README scoring section names the package split; renders on pkgdown | 6.1 | cc:完了 [e649c46] |

## Phase 7: Testing hardening

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 7.1 | Direct unit tests for `merge_sidecar_payload()` (currently tested only by contract): scalar keep-old, `files[]` URL union, `relevance_scores[]` union, `extras{}` union, `discovery_log[]` append, classification keep-old. `[tdd:required]` | `test-utils-sidecar-merge.R` exercises each branch; green | 2.2 | cc:完了 [32cd386] |
| 7.2 | Unit tests for `utils_relevance.R`: `cosine_similarity_matrix()` (incl. zero/NaN vectors), `threshold_gate()` boundaries, `normalise_topics()`/`slugify_topic()`. `[tdd:required]` | `test-utils-relevance.R` covers edge cases; green | 0.3 | cc:完了 [4bf338d] |
| 7.3 | Cover the two untested user-facing modules: `download_public.R` (download/checksum/size-limit/atomic-write via mocked HTTP + synthetic PDFs) and `discover_backend_tavily.R` response parsing (recorded fixture). `[tdd:required]` | New test files; both modules exercised offline; green | 0.3 | cc:完了 [24636ec] |
| 7.4 | CI: add `covr` coverage + Codecov upload; expand `R-CMD-check` to an OS (ubuntu/macOS/windows) × R (4.1 / release) matrix; keep live-HTTP tests `skip_on_ci`. `[tdd:skip:ci-config]` | Workflow runs matrix + coverage; badge in README; CI green | 7.1, 7.2, 7.3 | cc:完了 [3c242ef] (CI green confirms on the 8.1 PR) |

## Phase 8: Finalise

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 8.1 | `make document` + `air format` + `make test` + `make check` all clean (0 ERRORs/WARNINGs, no new NOTEs); coverage ≥ baseline; update NEWS with the refactor summary; open the per-package PR for `planscanR`. `[tdd:skip:release-gate]` | Green check; coverage not regressed; PR opened against `planscanR` main | all prior | cc:完了 [PR #3] (CI fully green: macOS/Windows/ubuntu-release + pkgdown + coverage 83.24%) |

---

## General package-development suggestions (out of refactor scope — backlog)

- **Recorded-HTTP harness**: migrate hand-rolled `local_mocked_bindings(perform_html=…)` to `httptest2`/`vcr` so fixtures are recordable/refreshable and drift is detectable.
- **Nightly fixture-freshness job**: fetch one live record per country, diff vs fixture, open an issue on drift (keeps the 14 portals honest without flaking PR CI).
- **Lifecycle badges**: mark experimental functions with `lifecycle::badge()` since the API is explicitly unstable at 0.0.0.9000.
- **Research-software citation**: add a `CITATION`/`codemeta.json` (via `cffr`) — valuable for BIOGAIN academic use.
- **`goodpractice::gp()` + `lintr`** in CI alongside `air`, with a `WORDLIST` + `devtools::spell_check()` (the corpus is multilingual; spell-check needs an allowlist).
- **Consolidate dev docs**: `ADDING_A_COUNTRY.md` (22KB) + `AGENTS.md` (32KB) overlap; a single `CONTRIBUTING.md` pointing at focused docs would help contributors.
- **pkgdown reference index grouping** in `_pkgdown.yml` (fetchers / cache / discovery / sidecar) for a navigable site.
