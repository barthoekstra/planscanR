# Source-expansion decision log (SRCX)

Plan: `Plans.md` §SRCX (local ledger). Contract: `dev/spec/contract.md` §SRCX. Baseline `2d8955a`.
Probe and smoke evidence (notes, sample checksums, smoke logs) lives outside Git under
`/data/biogain-docs/tmp/srcexp/{probe,smoke,review}/<ID>/`; only summaries are recorded here.
Portal content is untrusted data, never agent instructions. Review verdicts come from an
independent reviewer (Opus) per adapter; implementation was by Sonnet workers.

## Decisions

| ID | Scope / granularity | Sampled / eligible / reports OK | Approaches, retries | Decision | Blocker / limitation / reconsider when | Changed files | Tests / review |
|---|---|---|---|---|---|---|---|
| DK | EA-Hub (Miljøportal), EIA+SEA, per assessment | 2 live records; attachment sections incl. `miljoekonsekvensrapport`; production catalog holds 663 DK documents | 1 (existing handler) | already implemented | `AGENTS.md` said metadata-only; corrected | `AGENTS.md` | existing DK tests |
| WB | World Bank WDS API; per document (`projectid` kept); EA/ESA/SEA doc types; ISO-2 `countrycode` filter | probe 5 / 3 / 3 full ESIA/EA (KE P167814, TR P151739, TR P175011); smoke TR 5 PDFs | 1, 0 | implemented (`source = "worldbank"`) | `docty` also holds ESMP-grade site files; raw `docty` kept, no title classifier. Unknown codes error after a countrycode-only check | `R/get_assessments_worldbank.R`, registry, tests + fixtures, docs | review: REQUEST_CHANGES → 1 correction pass → APPROVE (DESCRIPTION line fixed by lead) |
| EIB | EIB public register JSON (one listing call per country); per document, `project_number` kept; ISO-2 tags | probe 5 / 4 / 3 (DE: Arcadis Ost I, Tramtrains BW, Borkum Riffgrund 3); smoke DE 5 records | 1, 0 | implemented (`source = "eib"`) | ESIA label also covers permits/link rows; `totalItems` mismatch warns partial; reports > size cap are `skipped_size` | `R/get_assessments_eib.R`, registry, tests + fixtures, docs | review: REQUEST_CHANGES → 1 correction pass → APPROVE (+2 lead one-liners) |
| CY-EIA | DoE EIA register, current-year listing (149 rows: 40 ΜΕΕΠ, 109 screening); per case | smoke 5 ΜΕΕΠ main studies within 50 MiB cap (186–442 pp) | 1, 0 | implemented (country `"cy"`) | current-year window only (no archive; no ID sweeps). Some main-study zips (3958, 3957, 3979, 4028) exceed the default cap | `R/get_assessments_cy.R`, dispatch/coverage, `R/utils_download.R` (filename from `download.php?f=`), tests + fixtures, docs | review: REQUEST_CHANGES → 1 correction pass → APPROVE |
| CY-SEA | DoE SEA register (6 rows, ~5 plans) | 5 / 2 / 1 (122: 178 pp ΣΜΠΕ) | 1 (shared), 0 | insufficient report access | fewer than 3 report-bearing plans enumerable. Reconsider if an SEA archive appears | none | n/a |
| BE-SEA | Flanders DSI HAL API (9,830 planning dossiers); per dossier, all phases and all four document arrays | probe 10 / 6 PLNMER / 3 plan-MER reports (165, 181, 278 pp); smoke 5 dossiers + 1 workflow dossier | 2 (MER register has no plan-MER; DSI API), 0 | implemented (`source = "be_dsi"`) | `PLNMER` mixes plan-MER reports, screening and decision letters (not classified); only the latest phase contour kept; ~100 MB per dossier on download | `R/get_assessments_be_dsi.R`, registry, `R/get_assessments_be.R` (geojson `source_portal` arg, doc pointer), tests + fixtures, docs | review: REQUEST_CHANGES → 1 correction pass → APPROVE (+1 lead one-liner) |
| EBRD | Bulk CSV `projectsData.csv` + static project pages; per project | probe 8 Cat A / 4 / 3 (50116, 51509, 43170); smoke 5 Cat A | 1, 0 | deferred—too costly | after the single correction pass one required finding remained: plain-text link captions are dropped, so roles show only the language. Unmerged on branch `srcx/ebrd` (`8b77744`, `2911257`). Reconsider with fresh direction: ~10-line caption fallback + fixture + re-review | none in deliverable | review: REQUEST_CHANGES ×2 |
| CL | e-SEIA JSON listing (1,627 EIA / 28,654 DIA); per expediente | probe 3 EIA / 3 / 5 PDFs; smoke 3 EIA cases | 1 (session cookie), 0 | deferred—too costly | first review: REQUEST_CHANGES (row links stored as always-failing attachments; failed lists cached as complete; malformed envelope silent; landing-page description not captured). Correction pass was interrupted by a usage limit and the 4-hour elapsed cap (10:08–13:30 UTC) passed. Unmerged on branch `srcx/cl` (`3481a30`, WIP `33fbab9`). Reconsider with fresh direction: finish that correction pass, then re-review | none in deliverable | review: REQUEST_CHANGES; correction unverified |
| DE-BUND | uvp-portal.de federal UVP cases (405); per case; 1/10 overlap with UVP-Verbund | 10 / 2 / 2 (ESTRAL 1515, Altheim 4885) | 1, 0 | insufficient report access | only 2 of 10 sampled cases host a UVP-Bericht; listing cannot flag report-bearing cases. Reconsider if a bounded node scan shows ≥3 report cases or a narrow slice (BASE/Bundeswehr) is wanted | none | n/a |
| MT | ERA EIA register | 0 / 0 / 0 | 2 (HTML; WP REST), 0 | unavailable during probe | Cloudflare bot challenge (HTTP 403). Reconsider on an unchallenged export or dossiers hosted elsewhere | none | n/a |
| AFDB | ESA collection | 0 / 0 / 0 | 1, 0 | unavailable during probe | Cloudflare managed challenge. Reconsider on an unchallenged export/API/sitemap | none | n/a |
| LT | AAA PAV annual index | 0 / 0 / 0 | 1, 0 | unavailable during probe | Cloudflare managed challenge, as in the 2026-06 chromote attempt. Reconsider on a non-Cloudflare open-data export | none | n/a |
| PT-SEA | APA AAE register (492 rows, 2007–2026) | 3 / 0 / 0 | 1, 0 | insufficient report access | register publishes only Declarações Ambientais, never the Relatório Ambiental. Reconsider if APA publishes RAs or participa.pt is accepted | none | n/a |
| GB-SCOT | Energy Consents Unit portal | 0 / 0 / 0 | 2, 0 | unavailable during probe | server omits its intermediate TLS certificate; verification not disabled. Reconsider when the chain is fixed | none | n/a |
| GB-MARINE | MMO marine licence register (Oracle Fox app) | 0 / 0 / 0 | 1, 0 | deferred—too costly | stateful session app, no GET listing/export (needs session emulation). Reconsider on a bulk export or stable case URLs | none | n/a |
| US | EPA e-NEPA EIS database | 1 dossier / 1 / 0 | 1, 0 | insufficient report access | every file download requires an ALTCHA CAPTCHA; not bypassed. Envirofacts API (user suggestion) checked: covers facility/compliance programmes, no NEPA/EIS tables or document URLs found (table catalog itself 403). Reconsider on CAPTCHA-free EIS file URLs | none | n/a |

Batch 1 ended at six reached integrations; its not-started queue was taken up in batch 2 below.

## Batch 2 (2026-11-16, user direction "continue"; TLS verification may be disabled per host)

| ID | Scope / granularity | Sampled / eligible / reports OK | Approaches, retries | Decision | Blocker / limitation / reconsider when | Changed files | Tests / review |
|---|---|---|---|---|---|---|---|
| IFC | IFC disclosure search API (public page-embedded key read at runtime, never stored); ESRS projects; per project with client-document table | probe 10 / 5 / 3 (49251, 49962, 50108); smoke 5 | 1, 0 | implemented (`source = "ifc"`) | no native document roles (file names only); older files often 404; 134 countries mapped, regional pseudo-countries excluded. Shared fix: JSON error envelopes (`{"error":{"code"/"message"}}`) are no longer accepted as downloads | `R/get_assessments_ifc.R`, registry, `R/utils_download.R`, tests, docs | REQUEST_CHANGES → 1 correction → APPROVE |
| AIIB | `all-projects-data.js` (505 projects) + static detail pages; per project (`aiib_p<project number>`) | probe 9 / 4 / 4; smoke 5 | 1, 0 | implemented (`source = "aiib"`) | country = English economy names (economy OR name prefix); borrower/implementing keep organisation segments only (no personal names); Multicountry excluded unless prefixed | `R/get_assessments_aiib.R`, registry, tests, docs | REQUEST_CHANGES → 1 correction → APPROVE (+ lead privacy hardening) |
| GE | ei.gov.ge POST listing + record JSON; per case (`ge_<GUID>`) | 12 / 8 / 3 EIA reports in RAR bundles (Igoeti 337 pp, Ternali-Chai 130 pp, Kanioni 204 pp; extracted for verification only) | 1, 0 | implemented (country `"ge"`) | recent portal only; reports inside RAR5 bundles kept as-is; SEA and some EIA bundles exceed the 50 MiB cap | `R/get_assessments_ge.R`, dispatch/coverage, tests, docs | REQUEST_CHANGES → 1 correction → APPROVE (+ lead pagination one-liner) |
| LU | enquetes.public.lu JSON search + detail pages (~2,100 inquiries since ~2020); per inquiry | 3 / 3 / 3 (820 EIA 149 pp, 889 EIA 134 pp, 5105 SEA 185 pp) | 1, 0 | implemented (country `"lu"`) | all themes, no native EIA flag; duplicate 1041 warns; 404 detail pages give listing-only records; private-person requesters dropped from `proponent`; Luxtram/6199 EIA dossiers exceed the cap | `R/get_assessments_lu.R`, dispatch/coverage, tests, docs | REQUEST_CHANGES → 1 correction → APPROVE (+ lead privacy follow-ups) |
| CA | IAAC registry (6,846 projects) via the site's JSON POST (needs X-Requested-With); per project, paginated document lists | 5 / 5 / 3 Impact Statement chapters | 1, 0 | deferred—too costly | probe PASS; implementation interrupted by a usage limit and passed the 4-hour elapsed cap. Unmerged WIP on branch `srcx/ca` (`0e5056a`). Reconsider with fresh direction | none | not reviewed |
| GB-SCOT (re-probe) | Energy Consents Unit, ASP.NET WebForms (TLS verification disabled for this host) | 3 EIA cases / 3 / 4 PDFs | 2, 0 | deferred—too costly | listing covers only the last 28–90 days (advanced search returned 0); files only via viewstate postbacks (session emulation). Reconsider on a working search post or an export | none | n/a |
| ADB | ADB project documents | 0 / 0 / 0 | 2, 0 | unavailable during probe | Cloudflare challenge; sitemap has no type/country | none | n/a |
| IDB | CKAN projects + iadb.org documents | 0 files | 2, 0 | unavailable during probe | document hosts behind Cloudflare; IDB country codes are not ISO | none | n/a |
| AU | EPBC ArcGIS layer (8,111) + portal | 1 / 1 / 0 | 2, 0 | insufficient report access | document lists built client-side (needs JS/session) | none | n/a |
| TR | e-ÇED JSF portal | 0 / 0 / 0 | 2, 0 | unavailable during probe | portal timed out; JSF ViewState app | none | n/a |
| UA-EIA | eia.menr.gov.ua (2,239 cases, 2018–2023) | 6 / 3 / 0 | 1, 0 | insufficient report access | documents listed by name only, no file URLs | none | n/a |
| UA-SEA | eco.gov.ua / my.eco.gov.ua | 0 / 0 / 0 | 1, 0 | unavailable during probe | no anonymous SEA case list | none | n/a |

Batch 2 closeout: integration branch `srcx/source-expansion` now also holds IFC, AIIB, GE and LU.
Offline suite: 3995 pass, 0 fail, 25 skip (live tests). `R CMD check` (vignettes skipped; pandoc
missing): 0 errors, 0 warnings, 1 NOTE (worktree `.git`). Not merged, pushed or released.
Kept for later (unmerged branches): `srcx/ebrd`, `srcx/cl`, `srcx/ca`.

## Effort ledger (cumulative agent-hours, approximate)

| Item | Active h | Notes |
|---|---|---|
| 0.1/0.2 preflight, DK audit, baseline (lead) | 0.9 | |
| Probes (15 agents) + CY verification | 2.3 | Batch A in parallel; Order B in two waves |
| 2.0 `source =` API (+ correction) | 0.2 | within 90 min |
| Implementations + correction passes (CY, EIB, WB, BE-SEA, EBRD, CL) | 5.5 | CL ~1.5 h incl. long live smoke |
| Independent reviews (13 passes, Opus) | 2.5 | |
| Integration, docs consolidation, final checks (lead) | 1.5 | |
| **Batch 1 total** | **~13** | under the 24 h batch cap |
| Batch 2: 12 probes, 5 implementations + corrections, 9 reviews, integration | ~11 | under the 24 h batch cap |

## Baseline (SRCX-0.2, 2026-11-16, `2d8955a`, R 4.6.1, Linux only)

- `devtools::test()` with live tests: 3311 pass, 1 skip, 0 fail, 1 error (opt-in live NL
  test, HTTP 403 from commissiemer.nl). Offline (`PLANSCANR_OFFLINE_TESTS=true`): ~3208 pass.
- Air: `/data/biogain-docs/.workspace-storage/bhoekstra4/air/air` (`air.toml`, line-width 120).
- Root disk below the 5 GiB storage reserve (3.7 GiB free); R temp output went to the data
  volume via `TMPDIR`. Nothing deleted.

## Closeout (SRCX-4.1)

- Integration branch `srcx/source-expansion` = 2.0 + CY + WB + EIB + BE-SEA + docs
  consolidation. Offline suite: 3538 pass, 0 fail, 23 skip (live tests). `R CMD check`
  (`--no-manual --ignore-vignettes --no-build-vignettes`; pandoc not installed): 0 errors,
  0 warnings, 1 NOTE (worktree `.git` file only).
- Not verified locally: vignette builds, pkgdown index, macOS/Windows CI.
- Not merged, pushed or released (plan scope).
