# Fetch public-inquiry records from Luxembourg.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Luxembourg. Backed by the national **public-inquiry portal**
(<https://enquetes.public.lu>, "Enquêtes publiques"). Records are listed
through the portal's own anonymous JSON search endpoint
(`/ctie/searchresults`, 21 items per page) and enriched from each
inquiry's detail page (parsed with `rvest`). Language is French (`fr`);
portal-native values are kept verbatim.

## Usage

``` r
get_assessments_lu(
  date_range = NULL,
  limit = Inf,
  download = FALSE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  query = NULL,
  theme = NULL,
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- query:

  Optional free-text query, matched client-side as a case-insensitive
  substring of the record title.

- theme:

  Optional native theme slug: one of `"etablissement"`, `"gestion_eau"`,
  `"environement"` (sic), `"agriculture"`, `"amenagement"`, `"energie"`,
  `"patrimoine"`, `"autres"`.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Scope

all inquiries, not only EIAs: The portal lists **every** public inquiry
(about 2,100 since 2020: classified establishments, water permits,
environment, ...). The handler returns all of them by default and keeps
the native theme(s) (`theme`, `theme_label`, `theme_tags`) and inquiry
type (`survey_type`) as columns. **The portal has no native "EIA report"
flag**, and the handler does not guess which inquiries are EIAs from
title keywords: `assessment_type` is `NA`. Filter on the native `theme`
(for example `"environement"`, the portal's spelling) or on the title
(`query`) instead. Only the "environement" theme (about 57 inquiries)
mixes EIAs with Natura 2000, plans and permits; most
classified-establishment and water inquiries carry no EIA report.

## Listing and completeness

The search endpoint needs a constant `data-id` that the handler reads
from the `<cmp-search-results>` element of `/fr/enquetes.html` (never
hardcoded). Pages are requested from 1 until an empty page or until the
reported `totalMatches` is reached; ids are de-duplicated and the number
of UNIQUE ids is compared with the total. A malformed envelope or a
failed first page is an error; a failed, short, empty-too-early or
repeated later page, three consecutive failed pages, or fewer unique ids
than the total (the warning names ids listed more than once, which
suggests a shifted listing) raise a `planscanR_warning_partial` instead
of returning a silently complete result. Known case: the portal lists
inquiry 1041 twice, so a full crawl of all themes warns that one fewer
unique inquiry than the total was retrieved (e.g. 56 of 57 for the
"environement" theme). Inquiries closed or archived since about 2020
remain listed; earlier ones are not on the portal.

## Records

`document_id` is `"lu_"` plus the native inquiry id (stable, also the
last number in the title). Every native listing field is kept in the
`listing_json` column (the raw search item). `date_published` is the
opening date and `date_close` the closing date (both as shown on the
detail page; the listing's timestamps are shifted by one or two hours);
`date_decision` is `NA` (the portal exposes no decision date).
`competent_authority` is the authority organising the inquiry (as
written on the page; several are joined with `"; "`),
`supervising_authority` the authority following the file, `jurisdiction`
the municipalities. `proponent` is the requester ("Requérant : ...")
line of the description when the page has one and it is not a private
person (lines starting with a personal title such as "Monsieur" become
`NA`), else `NA`. Also kept: `native_id`, `reference_number`,
`status_native`, `survey_type`, `nb_contributions`,
`last_modified_native`, `procedure_type`, `municipalities_concerned`,
`neighbouring_municipalities`, `related_links` (opinions and meetings
linked from the page) and every text section of the page in
`detail_sections` (JSON). No geometry (locations are municipality names
only).

## Attachments

The detail page is fetched for every returned record (sidecar-first; a
record whose detail fetch failed, or whose page looks unexpected, e.g.
the few listed items whose page returns 404, is returned as a
**listing-only record** (`detail_fetched = FALSE`: title, theme, status,
dates, municipalities, reference number and `listing_json`, no
attachments) with a `planscanR_warning_partial`; it is not cached and is
retried next run, except a page that returns HTTP 404 (about 330 listed
inquiries): that listing-only record is cached with
`detail_not_found = TRUE` and only rechecked with `refresh = TRUE`).
Every file link on the page (host `*download.public.lu`) is captured
with its native label, grouped by the portal's own grouping into
`attachment_urls_<slug>` columns: the accordion headings (normally
`fichiers`), the per-case "Tout télécharger" archive
(`tout_telecharger`, a zip that duplicates the other files) and links
embedded in the description (`description`, for example a 7z dossier).
Native labels per slug are in `attachment_labels_native`. Zip and 7z
files are downloaded as-is, never unpacked, and bounded by
`max_file_size_mb` (oversized files are reported as `skipped_size`); the
main EIA report is often inside a zip.

## Filter coverage

`theme` (a native theme slug, see
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md);
sent to the portal and re-checked client-side), `query`
(case-insensitive title substring), and `date_range` (against the
opening date of the listing, the same calendar day as `date_published`)
are applied before the detail fetch; `limit` caps the result. Requests
are throttled to 5 req/s (`getOption("planscanR.lu_throttle_rate")`).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
get_assessments_lu(theme = "environement", limit = 3, download = FALSE)
} # }
```
