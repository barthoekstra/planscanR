# Fetch environmental-assessment records from Austria.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Austria. Backed by the UVP-DB run by Umweltbundesamt at
<https://secure.umweltbundesamt.at/uvpdb/public>. Compared to the NL and
DE handlers, the AT portal is **metadata-only**: the procedure register
and per-procedure summary are exposed via open JSON service handlers,
but every document attachment lives behind a Keycloak login and is
therefore **not retrievable** by this version.

## Usage

``` r
get_assessments_at(
  date_range = NULL,
  limit = Inf,
  download = TRUE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  query = NULL,
  jurisdiction = NULL,
  ...
)
```

## Arguments

- date_range:

  Length-2 vector `c(from, to)` of dates or parseable strings. Compared
  against the record's `year`; see *Filter coverage*.

- limit:

  Integer. Maximum records to return. Defaults to `Inf`. The full
  register is small (~500 records), so a cold-cache full crawl completes
  in a few minutes.

- download, cache_dir, overwrite, max_file_size_mb, write_sidecar,
  refresh:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).
  `download`, `overwrite`, and `max_file_size_mb` are accepted but
  ignored — no PDFs are reachable.

- topic, relevance_threshold, relevance_model:

  Forwarded from
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).
  `relevance_threshold` is documented as a download-gate; on AT it has
  no observable effect because there are no downloads to gate.

- query:

  Free-text substring match on `title` + `summary` (client- side). The
  portal has no server-side full-text search.

- jurisdiction:

  Character vector. Substring match against `bundeslaender` (the
  comma-joined Austrian federal-state list).

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## URL enumeration

The public HTML pages of the portal sit behind a Keycloak login wall.
Three JSON service handlers, however, are open:

    https://secure.umweltbundesamt.at/uvpdb/?servicehandler=mapsdata
    https://secure.umweltbundesamt.at/uvpdb/?servicehandler=mapsgeom
    https://secure.umweltbundesamt.at/uvpdb/?servicehandler=vorhabenInfo&v2id=<id>

Enumeration is a single `mapsdata` call that returns ~500 records keyed
by Aktenzahl (AZ), each carrying `v2id`, `province`, `year`, `title`,
and `type`. Per-record detail comes from one `vorhabenInfo` call per
`v2id`. There is no pagination, CSRF, or session requirement; the
typology mapping (`type` integer → German legend) is captured as a
static constant in this file because the portal rarely changes it.

## Filter coverage (v0.1)

- `query` — case-insensitive substring match against `title` +
  `summary`.

- `date_range` — matched against `year`, treating each record's year as
  the full January 1 – December 31 window. `date_decision` is **always
  NA** because the portal does not expose a decision or last-modified
  timestamp to anonymous callers; a synthetic mid-year date would
  pretend to a precision the source lacks.

- `jurisdiction` — substring match against `bundeslaender` (the comma-
  joined Austrian federal-state list, e.g. `jurisdiction = "Bayern"`
  never matches; `jurisdiction = "Wien"` keeps Viennese records).

## Attachments

not available: The Austrian portal does not expose document URLs to
anonymous callers. For every record this handler returns
`attachment_urls = character(0)`, `local_path = character(0)`, and an
empty `download_status` tibble. The `download` argument is accepted for
API symmetry but has no effect. Authenticated access (UBA Keycloak) is
out of scope for v0.1.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_at(limit = 3, download = FALSE)

# Windkraft-only slice
get_assessments_at(query = "Windpark", limit = 20, download = FALSE)

# All Burgenland records from a given year window
get_assessments_at(
  date_range = c("2016-01-01", "2018-12-31"),
  jurisdiction = "Burgenland",
  download = FALSE
)
} # }
```
