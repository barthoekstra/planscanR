# planscanR — SI attachment pagination fix (issue #17) — Plans.md

Created: 2026-06-11
Scope: the `planscanR` leaf package only (this repo). Branch + commits
per-package per the family convention. Suggested branch: `fix/si-cpvo-pagination`.

Fixes GitHub issue #17 "SI Not all attachments are fetched due to pagination".

---

## Root cause (confirmed by live probing, 2026-06-11)

`get_assessments_si()` crawls three registers. They are **not** structurally
identical, and the current attachment logic only fits one of them:

| Register | JSON export | Detail URL `<base>/<URLSegment>/` | Attachments live on… |
|----------|-------------|-----------------------------------|----------------------|
| `predhodni-postopek` (EIA, 336) | unpaginated, full | **HTTP 200** — real per-record page | the detail page ✅ current code works |
| `cpvo-drzavni` (SEA, 25) | unpaginated, full | **HTTP 302 → listing** | a paginated listing table ❌ broken |
| `cpvo-obcinski` (SEA, 190) | unpaginated, full | **HTTP 302 → listing** | a paginated listing table ❌ broken |

For both **CPVO/SEA** registers there is **no per-record detail page**. Each
record is a row in a single HTML `<table>` (`Naziv | Občina | Datum | Datoteka |
Odločitev`), **10 rows/page**, paginated via `?start=0,10,20,…`. The download
links live in each row's **Datoteka** cell.

The current code (`si_fetch_attachments()` → `si_parse_attachments()`,
`R/get_assessments_si.R:365-387`) fetches the per-record URL, follows the 302 to
**listing page 1**, scrapes every `a[href^="/assets/seznami/"]` on that page, and
attributes that **same page-1 set to every CPVO record**. Consequences:

1. Only page-1 attachments are ever seen (the pagination bug in the title).
2. Attachments are **mis-attributed** — every record gets page 1's links.
3. `/assets/ministrstva/…` PDF links in the Datoteka cell are missed entirely
   (the `seznami`-only prefix filter is too narrow).

The JSON bulk export (`<base>/export/json/`) is authoritative and unpaginated
(190 records, all `Title` values unique) but its `Datoteka` field is a list of
**opaque integer file-IDs that do not appear anywhere in the listing HTML**, so
it cannot be used to resolve attachment URLs directly. The fix must therefore
**join** JSON records to listing-table rows.

## Fix architecture (validated via subagent Architecture + QA/Skeptic review)

Keep the **JSON export as the record spine** (preserves `URLSegment` →
`document_id` + canonical `url`, so sidecar cache keys and download paths stay
stable — no migration of existing on-disk ids). For CPVO registers, replace the
broken per-record detail fetch with a **register-level attachment index**:

1. Crawl **all** listing pages of the register **once** (not once per record).
2. Parse the table; for each row capture `{title, datum, attachment_urls}` where
   `attachment_urls` = **all `/assets/…` links scoped to that row's Datoteka
   cell** (not page-wide — page-wide would vacuum up logos/CSS/icons).
3. Build a map keyed by **normalised title (+ Datum)** → attachment URLs.
4. For each JSON record, look up its attachments from the index.

EIA (`predhodni-postopek`) keeps the existing per-record detail-page path.

## SSOTs this fix must honour

- **Cache / sidecar SSOT**: `R/utils_sidecar.R` — `SCHEMA_VERSION <- 3L`.
  **No schema bump** (no on-disk shape change). `document_id`/`url` derivation
  stays tied to JSON `URLSegment` → existing ids and downloads are unaffected.
- **Output contract SSOT**: `dev/spec/contract.md` — `attachment_urls` is an
  existing Tier-1 column. This is a **fidelity bugfix**, not a contract change.
- **Reuse, don't re-implement**: `req_planscanr()`/`perform_html()` (throttled
  HTTP), `ascii_slug()`, `sidecar_url_index()`, `warn_partial()`,
  `bind_results()`, `validate_result_schema()`.

## Spec status

- **Spec skip reason**: product contract (`dev/spec/contract.md`) is unchanged —
  `attachment_urls` already exists; this restores its fidelity for SI CPVO
  records. No schema/column change. The **mechanism description** in `AGENTS.md`
  and the `get_assessments_si()` roxygen is now factually wrong for CPVO and is
  corrected as task 1.6 (docs only, no contract delta).

## Decision surfaced for approval

**Stale CPVO sidecars** already on disk hold the wrong `attachment_urls`. With
the default `refresh = FALSE`, sidecar-first will keep serving the bad data
silently. Recommended (task 1.5): **document a one-time `refresh = TRUE` mandate**
in `NEWS.md` + `AGENTS.md` rather than bumping `SCHEMA_VERSION` (a bump would
force every country to re-fetch — overkill for a dev-stage, SI-only fix). Confirm
or override before 1.5.

---

## Phase 1: Fix SI CPVO attachment pagination

| Task | 内容 | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 1.1 | Failing tests + fixtures (TDD). Add `fixtures/si/cpvo_listing_page1.html` + `_page2.html` (real `Naziv\|Občina\|Datum\|Datoteka\|Odločitev` table, ≥1 row whose Datoteka cell mixes `/assets/seznami/` and `/assets/ministrstva/` links) and a multi-page JSON-export fixture. Write tests asserting: (a) a record sourced from page 2 gets ITS OWN attachments, not page-1's; (b) every listing page is crawled (pagination stops on empty page); (c) `/assets/ministrstva/` links are captured; (d) title-join matches across case/diacritic differences ("Občinskega" vs "občinskega"). `[tdd:required]` | New tests exist and **FAIL** on current `HEAD` (`devtools::test(filter="get_assessments_si")` shows the 4 new expectations red; pre-existing SI tests still green) | - | cc:完了 [299f9b3] |
| 1.2 | Listing crawler + table parser. Add `si_crawl_listing_pages(register)` (paginate `?start=0,10,…` via `req_planscanr()`/`perform_html()`, stop on first page with 0 data rows) and `si_parse_listing_table(html)` → tibble of `{title, datum, attachment_urls}`, capturing **all `/assets/…` links scoped to each row's Datoteka cell**. `[tdd:required]` | Parser turns the page1 fixture into the exact N rows with correct per-row attachment URL sets (incl. `ministrstva` + `seznami`); crawler stops at the empty page and never loops; row-scoped capture excludes non-Datoteka assets | 1.1 | cc:完了 [299f9b3] |
| 1.3 | Title-join + wire into the fetch path. Add `si_normalise_title()` (NFC + case-fold + whitespace-collapse via `stringi`); build a per-CPVO-register normalised-title(+Datum)→attachments index once; for CPVO records look attachments up from the index instead of fetching a (nonexistent) detail page. Unmatched JSON record → empty `attachment_urls` + `warn_partial()` (non-silent); duplicate-title collision → warn + union. EIA path untouched. `[tdd:required]` | All 1.1 tests pass; EIA mock tests in `test-get_assessments_si.R` unchanged and green; sidecar-first warm-run path still short-circuits network | 1.2 | cc:完了 [299f9b3] |
| 1.4 | Stale-cache invalidation (per the approved decision). Default: add `NEWS.md` entry + `AGENTS.md` note instructing a one-time `get_assessments_si(refresh=TRUE)` to heal pre-fix CPVO sidecars; **no** `SCHEMA_VERSION` bump. `[tdd:skip:docs-and-policy]` | `NEWS.md` + `AGENTS.md` carry the refresh note; `grep SCHEMA_VERSION R/utils_sidecar.R` still `3L` | 1.3 | cc:完了 [299f9b3] |
| 1.5 | Docs correctness. Fix the `get_assessments_si()` roxygen "URL enumeration"/"Attachments" sections and the `AGENTS.md` Slovenia block to describe the real mechanism (EIA = per-record detail page; CPVO = paginated listing-table crawl + title-join). `[tdd:skip:docs-only]` | `AGENTS.md` + roxygen match the implemented behaviour; `devtools::document()` produces no diff beyond intended | 1.3 | cc:完了 [299f9b3] |
| 1.6 | Live verification + full gate. Run `get_assessments_si(assessment_type="SEA", limit=5, download=FALSE)` against live gov.si; confirm distinct records carry distinct, non-empty attachment sets and ≥95% of CPVO records title-join successfully (log the unmatched). Run formatter + tests + check. | Live SEA sample shows per-record distinct attachments; `air format --check` clean; `devtools::test()` all green; `devtools::check()` 0 errors / 0 warnings | 1.4, 1.5 | cc:完了 [299f9b3] |

## Out of scope (verified, not bugs)

- **EIA `predhodni-postopek`** — has real per-record detail pages (HTTP 200);
  current scraping is correct. 1.6 spot-checks one EIA detail page is not itself
  a paginated listing, but no code change is expected.
- The opaque `Datoteka` integer file-IDs in the JSON export — not resolvable to
  URLs; deliberately unused (the listing-table links are authoritative).
