# Patch pkgdown so its pandoc invocations enable the `+alerts` extension.
#
# pkgdown 2.1.x renders the README/homepage through its internal
# convert_markdown_to_html(), which hard-codes a `--from=markdown+...`
# without `+alerts`. It also overrides each vignette's YAML output
# format, so a `pandoc_args:` in the YAML is silently ignored. Both
# paths therefore emit `> [!WARNING]` blockquotes as literal text.
#
# This script monkey-patches both internals to inject `+alerts` into
# their pandoc invocations. Combined with pkgdown/extra.scss, GFM
# alerts then render as Bootstrap callouts on the pkgdown site.
#
# Source this from any pkgdown entry point — `build_site()`,
# `build_site_github_pages()`, etc. — and the patches stick for the
# rest of the R session. Both entry points must run in the current
# process (e.g. `new_process = FALSE`); a forked callr subprocess will
# not inherit the patches.

local({
  alerts_from <- paste0(
    "--from=markdown",
    "+gfm_auto_identifiers-citations+emoji+autolink_bare_uris+alerts"
  )

  ns <- asNamespace("pkgdown")

  # README / homepage: convert_markdown_to_html() hard-codes its
  # `--from`. Pandoc honours the last `--from` on its command line, so
  # appending a second one through `...` (which becomes additional
  # pandoc options) wins.
  orig_md <- get("convert_markdown_to_html", envir = ns)
  utils::assignInNamespace(
    "convert_markdown_to_html",
    function(pkg, in_path, out_path, ...) {
      orig_md(pkg, in_path, out_path, alerts_from, ...)
    },
    ns = "pkgdown"
  )

  # Vignettes: build_rmarkdown_article() forwards `pandoc_args` to
  # rmarkdown::html_document, which routes them to pandoc. The default
  # is `character(0)`; inject the alerts flag.
  orig_art <- get("build_rmarkdown_article", envir = ns)
  utils::assignInNamespace(
    "build_rmarkdown_article",
    function(pkg, input_file, input_path, output_file, output_path,
             depth, seed = NULL, new_process = TRUE,
             pandoc_args = character(), quiet = TRUE,
             call = rlang::caller_env()) {
      orig_art(
        pkg = pkg, input_file = input_file, input_path = input_path,
        output_file = output_file, output_path = output_path,
        depth = depth, seed = seed, new_process = new_process,
        pandoc_args = c(pandoc_args, alerts_from),
        quiet = quiet, call = call
      )
    },
    ns = "pkgdown"
  )
})
