# planscanR — Output & Sidecar Contract

**Status:** SSOT for the consistency/docs/schema refactor · draft v1 · 2026-06-04
**Scope:** the `planscanR` leaf package. The result tibble and the sidecar JSON
are read by `planscanR.screen`, `planscanR.biogain`, and `planscanR.RAG`, so
both shapes are cross-package contracts.

This document fixes, ahead of the schema/column work in Phases 2–3:

- the columns every `get_assessments_*()` returns and what downstream code may
  rely on;
- the naming convention for portal-native (non-core) columns;
- the on-disk sidecar shape, and the **v3** changes Phase 2 implements.

Where current behaviour (schema **v2**) differs from the v3 target, both are
stated. "v3 target" marks something Phase 2 introduces; everything else
describes code as it stands today.

---

## 1. The result tibble (in-memory contract)

A result is a tibble, one row per **record**. Columns fall into four tiers.

### Tier 1 — Required (schema-enforced)

`bind_results()` → `validate_result_schema()` asserts presence **and type** of
exactly these. A handler that omits one, or returns a wrong type, aborts with
`planscanR_error_bad_schema`. Downstream joins may always rely on these.

| Column | Type | Notes |
|--------|------|-------|
| `country` | character | ISO-3166-1 alpha-2, lowercase (`"nl"`, `"de"`, …) |
| `source_portal` | character | Stable portal identifier |
| `document_id` | character | Portal-stable id; the per-record cache key |
| `url` | character | Canonical detail-page URL |
| `retrieved_at` | POSIXct (UTC) | When the record was fetched |
| `attachment_urls` | list(character) | Attachment URLs for the record |
| `local_path` | list(character) | Downloaded file paths; `NA` entries when not downloaded |

### Tier 2 — Core conventional (guaranteed present, `NA` when unknown)

Not type-checked by `validate_result_schema()` today, but
`read_record_sidecar()` always materialises them, and every handler emits them,
so downstream code may rely on the **column existing** (value may be `NA`).

| Column | Type | Notes |
|--------|------|-------|
| `title` | character | |
| `summary` | character | |
| `competent_authority` | character | |
| `proponent` | character | |
| `date_decision` | Date | First-class date (own sidecar field) |
| `relevance_model` | character | Embedding model used for scoring; `NA` if unscored |
| `download_status` | list(tibble) | Per-attachment download outcome (see below) |

`download_status` is a list-column of a tibble with columns: `url` (chr),
`local_path` (chr), `status` (chr), `size_bytes` (dbl), `sha256` (chr),
`reason` (chr), `source` (chr: `"portal"` | `"discovery"`), `validation_status`
(chr), `validation_signals` (list/chr), `validation_notes` (chr).

> Note: `download_status` is contract-core but **not** in `required_columns()`.
> Tightening `validate_result_schema()` to cover Tier 2 is a candidate follow-up;
> until then the guarantee rests on the reader + handler convention, not the
> validator.

### Tier 3 — Scoring (present only after scoring / classification)

Added by `planscanR.screen` (relevance / classification). Absent on unscored
records; present as a wide set of per-topic / per-label columns when scored.

| Column | Type | Notes |
|--------|------|-------|
| `relevance_score_<topic>` | numeric | Cosine similarity per topic slug |
| `class_label` | character | Top zero-shot label |
| `class_score` | numeric | Top label score |
| `class_relevant` | logical | Relevance verdict |
| `class_model` | character | Classifier model |
| `class_score_<label>` | numeric | Per-label scores |

### Tier 4 — Portal-native (non-core) columns

Country-specific fields kept verbatim from the portal. **Not guaranteed across
countries** — downstream code must not assume their presence.

Convention (enforced in Phase 3.2):

- **English `snake_case` names**, e.g. AT `aktenzahl` → `file_number`,
  `rechtsgrundlagen` → `legal_basis`, `standort_gemeinden` → `municipalities`.
- **Naming only — no value remapping.** The portal's own value is preserved;
  only the column name is anglicised.
- The portal's own document/dossier type label lives under a single
  `native_type` key (see §2 v3 change 3).

### Section-scoped attachment columns

Portals that group attachments into sections expose, per section `<s>`:
`attachment_urls_<s>` (list(character)) and `local_path_<s>` (list(character)).
Sections are portal-defined — NL: `source`, `advice`; DE: `uvp_bericht`,
`berichte`, `auslegung`, `weitere`. These are derived from the sidecar `files[]`
`section` tags on read, so they round-trip without per-country knowledge.

### Other conventional columns

| Column | Type | Notes |
|--------|------|-------|
| `date_published` | Date | Round-trips via `extras` as `YYYY-MM-DD`; coerced back to `Date` on read for `bind_rows()` type-stability. Not a first-class sidecar field. |
| `discovery_log` | list | Audit trail of attachment-discovery activity |
| `geometry_path` | character | (IE) path to the saved `.geometry.geojson` (relative in v3 — see §2) |
| `geometry_crs` | character | (IE) e.g. `"EPSG:2157"` |

### Extensibility rule

A new field lands in `extras{}` with an English `snake_case` key. Promotion to a
first-class column (Tier 1/2) or sidecar field requires **an update to this
contract + a `SCHEMA_VERSION` bump**.

---

## 2. The sidecar JSON (on-disk contract)

Each fully-processed record is persisted to
`<cache>/files/<country>/<document_id>/<document_id>.meta.json`. The sidecar is
the canonical offline record: re-indexing a cache (`index_cache()`) reconstructs
the result tibble from sidecars without re-fetching.

Writes are **atomic** (temp file + rename) and **non-destructive**: a new payload
is merged over whatever is on disk (`merge_sidecar_payload()`) — scalars keep the
old value when the writer omits them; `files[]` union by URL; `relevance_scores[]`
union by topic; `extras{}` union by key; `discovery_log[]` appended;
`classification` kept when the writer carries none.

### Top-level shape (v2, current)

```
schema_version        integer
country, source_portal, document_id, url        string
retrieved_at          string  (ISO-8601 UTC, trailing Z)
title, summary, competent_authority, proponent  string | null
date_decision         string  (YYYY-MM-DD) | null
relevance_model       string | null
relevance_scores[]    { topic, score, model, scored_at }
classification        { label, score, relevant, model, classified_at, scores[] } | null
extras{}              portal-native scalar columns (English snake_case keys)
files[]               { url, section, source, filename, local_path, status,
                        size_bytes, sha256, reason,
                        validation_status, validation_notes, validation_signals[] }
discovery_log[]       discovery audit entries
```

### v3 changes (implemented in Phase 2)

1. **Relative on-disk paths.** `files[].local_path` and any `geometry_path` are
   stored **relative to the cache root** and **absolutised on read** back to
   working paths. (Today they are stored verbatim, i.e. effectively absolute, so
   a relocated cache breaks them.) The derived `local_path`, `local_path_<s>`
   columns inherit this since they come from `files[].local_path`.
2. **`extras{}` no longer carries `relevance_score_*`.** The structured
   `relevance_scores[]` array is canonical. Today these columns leak into
   **both** `relevance_scores[]` and `extras{}` because the writer's `reserved`
   set doesn't exclude `^relevance_score_`; v3 adds them to `reserved`.
3. **One canonical portal-native type key.** The portal's document/dossier type
   label is stored once under `native_type`; no second key (e.g. a redundant
   `dossier_type` carrying the same value) is duplicated alongside it.
4. **Timestamp invariant.** All datetime fields are ISO-8601 UTC with a trailing
   `Z` (`retrieved_at`, `scored_at`, `classified_at`). The current writer already
   emits `Z`; v3 makes it an asserted invariant and reads legacy non-`Z` values
   tolerantly. Date-only fields (`date_decision`, `date_published`) remain
   `YYYY-MM-DD` (no time component).

### Schema version & back-compat

`SCHEMA_VERSION` is **2** today; v3 bumps it to **3**. `assert_sidecar_schema()`
rejects any sidecar whose `schema_version` is **greater** than the running
package's (fail loud rather than misread). A missing `schema_version` field is a
legacy **v1** sidecar and reads cleanly; **v1 and v2 sidecars must still read**
under v3 (back-compat is part of the contract).

---

## 3. Cross-package notes

- I/O goes through the exported `planscanR::write_record_sidecar()` /
  `planscanR::read_record_sidecar()`; downstream packages do not parse the JSON
  themselves.
- The cache root resolves through `planscanR::cache_dir_default()`.
- A `SCHEMA_VERSION` bump must be matched by reads in `planscanR.screen`,
  `planscanR.biogain`, and `planscanR.RAG`, committed in dependency order
  (Task 2.3).

---

## 4. Final-batch conventions (2026-06-04)

Conventions over the **existing v3 shape** introduced with the final batch of
handlers (IT, PT, SI, UK, SK, NO, ES, LV). **No `SCHEMA_VERSION` change** — these
fix recurring patterns so they are not mistaken for out-of-pattern hacks.

1. **Bulk-export enumeration is a first-class enumeration pattern.** A handler
   may enumerate records from a single downloaded bulk file — UK Planning
   Inspectorate `/api/applications-download` (CSV), Slovenia gov.si
   `…/export/json/` (JSON) — instead of crawling paginated detail pages. The
   result tibble and the sidecar are unchanged; only the enumeration step
   differs. Per-record attachment/detail enrichment may still require a
   per-record detail fetch (sidecar-first as usual).

2. **`assessment_type` / `register` is the cross-country dual-register
   convention** (not EE-specific). When one portal (or one portal family)
   publishes both project-level EIA and plan/programme-level SEA:
   - `assessment_type` tags each row `"EIA"` or `"SEA"`;
   - `register` carries the raw portal register label;
   - `document_id` is **prefixed per register** so the two never collide on disk.
   An `assessment_type` argument (`"All"` default / `"EIA"` / `"SEA"`) selects
   which register(s) to crawl. Reused by EE (KMH/KSH), IT (VIA/VAS),
   SK (`isEia`), SI (screening vs CPVO), LV (EIA register vs SEA hub),
   ES (proyectos vs planes).

3. **Metadata-only status drives discovery — no new machinery.** Portals that
   expose records but no directly-downloadable PDFs (LV's EIA half; any portal
   whose PDFs prove tokened/auth-gated) set the coverage row
   `status = "supported (metadata-only…)"`. `get_assessments()` already reads
   that prefix (`metadata_only_countries()`) to nudge `discover = TRUE` (Tavily).
   Such handlers return empty `attachment_urls` for the affected records;
   downstream discovery fills them.
