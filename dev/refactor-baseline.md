# Refactor baseline — planscanR

Green baseline pinned at the start of the consistency/docs/schema refactor, so
later phases can prove they did not regress check status or coverage.

| Field | Value |
|-------|-------|
| Date | 2026-06-04 |
| Branch | `refactor/consistency-docs-schema` |
| Commit | `1e8a620` (after `air format R/`) |
| Package version | 0.0.0.9000 |
| R version | 4.5.0 |

## `R CMD check`

Run the same way CI does (`r-lib/actions/check-r-package@v2` defaults):

```r
rcmdcheck::rcmdcheck(args = c("--no-manual", "--as-cran"), error_on = "never")
```

**Result: 0 errors · 0 warnings · 2 notes.** CI uses `error_on = "warning"`, so
this is green.

The 2 NOTES are informational and pre-existing:

1. **CRAN incoming feasibility** — new submission; `0.0.0.9000` has "large
   components"; non-standard `Remotes` field; `Suggests: planscanR.screen` not
   on a mainstream repo (expected — this is a family package installed via
   `Remotes`); Title field not in title case (`From` → `from`); a few moved/404
   URLs in docs (`portal.cenia.cz/eiasea/` 404, `skipulagsgatt.is/graphql` 404,
   `www.github.com/BIOGAIN` and `ymparisto.fi/` moved-but-200).
2. **Non-standard top-level files** — `Plans.md`, `out`, `pkgdown` flagged
   because they are not in `.Rbuildignore` (candidates for Phase 5 cleanup).

## Coverage

```r
covr::percent_coverage(covr::package_coverage())
```

**Result: 80.87%.**

## Deviation from the plan note

The Phase 0.3 task line expected "2 WARNINGs: vignettes not in `inst/doc`". The
current tree has **no warnings** and **no vignette/`inst/doc` issue** — the
build populates `inst/doc`, so that warning does not fire. The remaining noise
is the 2 NOTES above. Task 6.4 ("fix the `inst/doc` vignette WARNING") therefore
appears moot as written; revisit whether it still has a target.
