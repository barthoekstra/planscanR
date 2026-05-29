# reactable builder for the review tab. Friendly, self-documenting column
# headers (label + hover-info icon), value-driven background gradients, and a
# per-row Keep / Drop / Unsure control that persists without re-rendering the
# table (the decision is updated client-side via JS; see review_js() in app.R).
# Bulk decisions still work via the row checkboxes + toolbar buttons.

# Map a 0..1 value to a white -> colour background with readable text colour.
gradient_style <- function(value, palette = c("#f7fbff", "#2c7fb8")) {
  if (is.null(value) || is.na(value)) {
    return(list(color = "#bbb"))
  }
  v <- max(0, min(1, as.numeric(value)))
  rgb <- grDevices::colorRamp(palette)(v)
  bg <- grDevices::rgb(rgb[1], rgb[2], rgb[3], maxColorValue = 255)
  list(background = bg, color = if (v > 0.55) "white" else "#222")
}

# Column header: a friendly label plus a circled-i whose native tooltip (title)
# explains the column on hover. Keeps the table understandable to non-coders.
hdr <- function(label, tip) {
  htmltools::tags$span(
    style = "display:inline-flex;align-items:center;gap:4px;",
    label,
    htmltools::tags$span(
      "ⓘ",
      title = tip,
      style = "color:#999;cursor:help;font-size:13px;"
    )
  )
}

# Truncating cell (single line + ellipsis); full text shown on hover via title.
trunc_cell <- function(value) {
  htmltools::div(
    title = if (is.na(value)) "" else as.character(value),
    style = "white-space:nowrap;overflow:hidden;text-overflow:ellipsis;",
    if (is.na(value)) "" else value
  )
}

# Per-row decision control: three toggle buttons rendered client-side so a click
# updates only that row (no table reload). The decision is seeded from the
# column value; reviewSet() in app.R's JS handles toggling + Shiny sync. `source`
# ("browse" / "random") is passed through so the server can record HOW each
# decision was made.
decision_cell_js <- function(source = "browse") {
  reactable::JS(sprintf(
    "function(cellInfo) {
      var src = '%s';
      var id = cellInfo.row['document_id'];
      var country = cellInfo.row['country'];
      var key = String(country) + '::' + String(id);
      var val = cellInfo.value;
      if (window.__reviewState === undefined) window.__reviewState = {};
      if (!(key in window.__reviewState)) {
        window.__reviewState[key] = (val === null || val === undefined) ? null : val;
      }
      var cur = window.__reviewState[key];
      function esc(s) { return String(s).replace(/'/g, \"\\\\'\"); }
      function btn(dec, label, color) {
        var active = (cur === dec) ? ' active' : '';
        return '<button type=\"button\" class=\"rev-btn' + active + '\"' +
          ' data-decision=\"' + dec + '\" style=\"--c:' + color + '\"' +
          ' onclick=\"event.stopPropagation();reviewSet(\\'' + esc(id) +
          '\\',\\'' + esc(country) + '\\',\\'' + dec + '\\',\\'' + src +
          '\\')\">' + label + '</button>';
      }
      return '<div class=\"rev-grp\" data-review-id=\"' + key + '\">' +
        btn('keep', 'Keep', '#1a9850') +
        btn('drop', 'Drop', '#d73027') +
        btn('unsure', '?', '#fc8d59') +
        '</div>';
    }",
    source
  ))
}

# Inline fold-down detail for a record: ID line on top, then two columns —
# ORIGINAL (left) and ENGLISH translation (right). Columns wrap to stacked when
# the row is too narrow. The translation is fetched lazily on expand: the right
# column is an empty `.xlate` placeholder that the client fills via a Shiny
# round-trip (see review_assets()'s translate-on-expand JS). This keeps the
# eager (all-rows) details render cheap — no network at build time.
record_detail_inline <- function(row) {
  has <- function(x) !is.null(x) && length(x) == 1L && !is.na(x) && nzchar(x)
  lbl <- "color:#888;font-size:11px;font-weight:600;text-transform:uppercase;"
  col <- "flex:1;min-width:300px;"
  key <- review_key(row$country, row$document_id)

  htmltools::div(
    style = "padding:12px 16px;background:#fafafa;",
    htmltools::div(
      style = "color:#888;font-size:12px;margin-bottom:8px;",
      sprintf("ID: %s · %s", row$document_id, toupper(row$country))
    ),
    htmltools::div(
      style = "display:flex;gap:20px;flex-wrap:wrap;",
      # left: original
      htmltools::div(
        style = col,
        htmltools::div("Original", style = lbl),
        htmltools::tags$b("Title"),
        htmltools::p(
          style = "margin:2px 0 8px;",
          if (has(row$title)) row$title else "(no title)"
        ),
        htmltools::tags$b("Summary"),
        htmltools::p(
          style = "margin:2px 0 0;white-space:pre-wrap;",
          if (has(row$summary)) row$summary else "(no summary)"
        )
      ),
      # right: English (filled lazily by JS on expand)
      htmltools::div(
        style = paste0(col, "border-left:1px solid #e3e3e3;padding-left:20px;"),
        htmltools::div("English", style = lbl),
        htmltools::div(
          class = "xlate",
          `data-key` = key,
          `data-id` = row$document_id,
          `data-country` = row$country,
          htmltools::span("Expand to translate…", style = "color:#aaa;")
        )
      )
    ),
    if (has(row$url)) {
      htmltools::div(
        style = "margin-top:10px;",
        htmltools::tags$a(href = row$url, target = "_blank", "Open portal page ↗")
      )
    }
  )
}

# `df`      : the snapshot slice to display (selection already applied).
# `reviews` : reviews tibble, read once to seed each row's current decision.
# `source`  : "browse" or "random" — tags decisions made from this table.
# `blind`   : if TRUE, hide the pipeline signals (topic match / category /
#             confidence / keywords / pre-selected) so the reviewer judges from
#             the title + summary alone — an unbiased "blind" review.
build_review_table <- function(df, reviews, source = "browse", blind = FALSE) {
  dec_lookup <- stats::setNames(
    reviews$decision,
    review_key(reviews$country, reviews$document_id)
  )
  df$decision <- unname(dec_lookup[review_key(df$country, df$document_id)])

  cols <- list(
    decision = reactable::colDef(
      header = hdr(
        "Review",
        "Your decision for this record. Click a button to set keep / drop / unsure; click the active button again to clear. Changes save instantly."
      ),
      sticky = "left",
      width = 150,
      sortable = FALSE,
      filterable = FALSE,
      html = TRUE,
      cell = decision_cell_js(source)
    ),
    country = reactable::colDef(
      header = hdr("Country", "Source portal country: nl = Netherlands, de = Germany, at = Austria."),
      width = 80,
      align = "center"
    ),
    title = reactable::colDef(
      header = hdr("Title", "Record title as published by the portal."),
      minWidth = 240,
      cell = trunc_cell
    ),
    cosine_max = reactable::colDef(
      header = hdr(
        "Topic match",
        "How closely the title + summary matches any BIOGAIN energy topic (0–1, semantic similarity). Higher = more on-topic. Darker blue = higher."
      ),
      width = 110,
      format = reactable::colFormat(digits = 3),
      style = function(value) gradient_style(value)
    ),
    class_label = reactable::colDef(
      header = hdr(
        "Category",
        "Best-guess category from the automatic classifier (e.g. wind, solar, water, land_use)."
      ),
      width = 140
    ),
    class_score = reactable::colDef(
      header = hdr(
        "Category confidence",
        "How confident the classifier is in the category (0–1). Darker orange = more confident."
      ),
      width = 110,
      format = reactable::colFormat(digits = 2),
      style = function(value) gradient_style(value, c("#fff7ec", "#d94801"))
    ),
    kw_total = reactable::colDef(
      header = hdr("Keyword hits", "Number of BIOGAIN energy keywords found in the title + summary."),
      width = 90,
      align = "center"
    ),
    selected = reactable::colDef(
      header = hdr(
        "Pre-selected",
        "Whether the automated pipeline keeps this record (topic match OR category OR keywords, minus confident non-renewables). This is what your review is compared against."
      ),
      width = 110,
      align = "center",
      cell = function(value) {
        if (isTRUE(value)) {
          htmltools::span(
            "Yes",
            style = "background:#3182bd;color:white;padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600;"
          )
        } else {
          htmltools::span("No", style = "color:#aaa;")
        }
      }
    ),
    n_attachments = reactable::colDef(
      header = hdr("Attachments", "Number of document files (PDFs etc.) attached to this record."),
      width = 110,
      align = "center"
    )
  )

  # Blind review: drop the pipeline-signal columns so they can't anchor the
  # reviewer's judgement.
  if (blind) {
    for (sig in c("cosine_max", "class_label", "class_score", "kw_total", "selected")) {
      cols[[sig]] <- NULL
    }
  }

  # Only declare columns that exist; hide everything else.
  present <- intersect(names(cols), names(df))
  show_cols <- c("decision", present[present != "decision"])
  hidden <- setdiff(names(df), show_cols)
  for (h in hidden) {
    cols[[h]] <- reactable::colDef(show = FALSE)
  }

  reactable::reactable(
    df,
    columns = cols,
    selection = "multiple",
    onClick = "expand",
    details = function(index) record_detail_inline(df[index, ]),
    highlight = TRUE,
    compact = TRUE,
    searchable = TRUE,
    filterable = TRUE,
    resizable = TRUE,
    defaultPageSize = 25,
    showPageSizeOptions = TRUE,
    pageSizeOptions = c(25, 50, 100, 250),
    rowStyle = if (blind) {
      NULL
    } else {
      function(index) {
        if (isTRUE(df$selected[index])) {
          list(borderLeft = "3px solid #3182bd")
        } else {
          list(borderLeft = "3px solid transparent")
        }
      }
    },
    theme = reactable::reactableTheme(
      borderColor = "#eee",
      highlightColor = "#eef6fb",
      cellPadding = "6px 8px"
    )
  )
}

# Unobtrusive ⓘ affordance explaining the performance metrics in plain language.
# Click-to-open popover so a non-expert can understand precision / recall / F1
# and the confusion-matrix counts. Drops inline next to a card header / title.
metrics_help_ui <- function() {
  icon <- htmltools::tags$span(
    "ⓘ",
    style = "color:#999;cursor:pointer;font-size:13px;margin-left:6px;"
  )
  bslib::popover(
    icon,
    title = "What do these metrics mean?",
    htmltools::div(
      style = "font-size:13px;line-height:1.4;max-width:320px;",
      htmltools::p(
        style = "margin:0 0 8px;",
        "We compare the pipeline's automatic pre-selection against your review, treating the records you marked “keep” as the correct answer."
      ),
      htmltools::tags$ul(
        style = "margin:0 0 8px;padding-left:18px;",
        htmltools::tags$li(
          htmltools::tags$b("Precision"),
          " — of the records the pipeline pre-selected, the share you also kept (how much of what it picked was actually wanted)."
        ),
        htmltools::tags$li(
          htmltools::tags$b("Recall"),
          " — of the records you kept, the share the pipeline also pre-selected (how much of what was wanted it caught)."
        ),
        htmltools::tags$li(
          htmltools::tags$b("F1"),
          " — one score balancing precision and recall (their harmonic mean); high only when both are high."
        )
      ),
      htmltools::p(
        style = "margin:0;",
        htmltools::tags$b("Confusion:"),
        " TP = both kept; FP = pipeline kept, you dropped; FN = pipeline dropped, you kept; TN = both dropped."
      )
    )
  )
}

# Full-width "one record at a time" card body for the stepper view. Mirrors
# record_detail_inline's two-column ORIGINAL / ENGLISH layout, but renders the
# translation eagerly from `translation` (a list with $title_en / $summary_en,
# either possibly NA) rather than lazily via JS. No decision / nav buttons —
# the caller (app.R) adds those.
single_record_ui <- function(row, translation = NULL) {
  has <- function(x) !is.null(x) && length(x) == 1L && !is.na(x) && nzchar(x)
  lbl <- "color:#888;font-size:11px;font-weight:600;text-transform:uppercase;"
  col <- "flex:1;min-width:320px;"

  title_en <- if (!is.null(translation)) translation$title_en else NULL
  summary_en <- if (!is.null(translation)) translation$summary_en else NULL
  have_xlate <- has(title_en) || has(summary_en)

  # Metadata chips — only those the portal actually provides for this record
  # (e.g. NL: date + authority + proponent; DE: date + category + authority;
  # AT: year + category + status). val() handles Date/numeric, not just text.
  val <- function(x) {
    if (is.null(x) || length(x) != 1L || is.na(x)) {
      return(NULL)
    }
    s <- trimws(as.character(x))
    if (nzchar(s)) s else NULL
  }
  date_decision <- val(row$date_decision %||% NULL)
  date_label <- if (!is.null(date_decision)) "Date" else "Year"
  date_val <- date_decision %||% val(row$year %||% NULL)
  meta <- list(
    list(date_label, date_val),
    list("Category", val(row$native_type %||% NULL)),
    list("Status", val(row$status %||% NULL)),
    list("Authority", val(row$competent_authority %||% NULL)),
    list("Proponent", val(row$proponent %||% NULL)),
    list("Jurisdiction", val(row$jurisdiction %||% NULL))
  )
  meta <- Filter(function(m) !is.null(m[[2]]), meta)
  meta_ui <- if (length(meta) > 0L) {
    htmltools::div(
      style = "display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px;",
      lapply(meta, function(m) {
        htmltools::span(
          style = paste0(
            "background:#eef2f5;border-radius:10px;padding:2px 10px;",
            "font-size:12px;color:#333;"
          ),
          htmltools::tags$span(
            paste0(m[[1]], ": "),
            style = "color:#888;font-weight:600;"
          ),
          m[[2]]
        )
      })
    )
  }

  htmltools::div(
    style = "font-size:15px;line-height:1.5;",
    htmltools::div(
      style = "color:#888;font-size:12px;margin-bottom:8px;",
      sprintf("ID: %s · %s", row$document_id, toupper(row$country))
    ),
    meta_ui,
    htmltools::div(
      style = "display:flex;gap:24px;flex-wrap:wrap;",
      # left: original
      htmltools::div(
        style = col,
        htmltools::div("Original", style = lbl),
        htmltools::tags$b("Title"),
        htmltools::p(
          style = "margin:2px 0 8px;",
          if (has(row$title)) row$title else "(no title)"
        ),
        htmltools::tags$b("Summary"),
        htmltools::p(
          style = "margin:2px 0 0;white-space:pre-wrap;",
          if (has(row$summary)) row$summary else "(no summary)"
        )
      ),
      # right: English translation (rendered eagerly from `translation`)
      htmltools::div(
        style = col,
        htmltools::div(
          "English",
          style = paste0(lbl, "color:#2c7fb8;")
        ),
        if (have_xlate) {
          htmltools::tagList(
            htmltools::tags$b("Title"),
            htmltools::p(
              style = "margin:2px 0 8px;",
              if (has(title_en)) title_en else "(no title)"
            ),
            htmltools::tags$b("Summary"),
            htmltools::p(
              style = "margin:2px 0 0;white-space:pre-wrap;",
              if (has(summary_en)) summary_en else "(no summary)"
            )
          )
        } else {
          htmltools::p(
            style = "margin:2px 0 0;color:#aaa;",
            "Translation not available yet."
          )
        }
      )
    ),
    if (has(row$url)) {
      htmltools::div(
        style = "margin-top:14px;",
        htmltools::tags$a(href = row$url, target = "_blank", "Open portal page ↗")
      )
    }
  )
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a
