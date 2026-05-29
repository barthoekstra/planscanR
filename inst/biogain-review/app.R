# =============================================================================
# planscanR pipeline funnel + human-review tool
# =============================================================================
# A standalone Shiny app (it does NOT modify any planscanR package function).
# It reads the sidecar cache read-only via the package's exported functions
# (index_cache / score_keywords / select_assessments) and keeps its own
# review-decision store under review-app/data/.
#
# Two tabs:
#   * Funnel  — how many records survive each pipeline gate (indexed -> cosine /
#               classifier / keyword -> ensemble selection -> attachments ->
#               downloaded), with the cosine + keyword thresholds adjustable.
#               If human review exists, shows automated-vs-human agreement.
#   * Review  — triage the corpus by hand (keep / drop / unsure) to build the
#               ground-truth selection to compare the pipeline against.
#
# Run it:   from the repo root,  R -e 'shiny::runApp("review-app")'
#           or  Rscript review-app/run.R
# Cache dir is taken from the PLANSCANR_CACHE env var (falls back to the
# project default below).
# =============================================================================

library(shiny)
library(bslib)

# planscanR provides the data layer (index_cache / select_assessments / sidecar
# I/O). It's normally launched via planscanR::run_biogain_review(); helper
# functions here reach it through planscanR::, so it only needs to be installed.
if (!requireNamespace("planscanR", quietly = TRUE)) {
  stop("The planscanR package must be installed to run this app.")
}

# --- config ------------------------------------------------------------------
# Cache root (where the sidecar cache lives). Resolution order: PLANSCANR_CACHE
# env (set by the launcher's `cache_dir` arg) -> the package's cache option ->
# the package default user cache dir. Never hard-coded to a personal path.
CACHE_DIR <- Sys.getenv("PLANSCANR_CACHE", unset = "")
if (!nzchar(CACHE_DIR)) {
  CACHE_DIR <- getOption(
    "planscanR.cache_dir",
    tools::R_user_dir("planscanR", "cache")
  )
}
COUNTRIES <- c("nl", "de", "at")
# Where the app's own artefacts live (snapshot + reviews.csv + reviewers list).
# Installed inst/ is read-only, so this is a per-user, writable directory.
APP_DATA_DIR <- Sys.getenv(
  "BIOGAIN_REVIEW_DATA",
  unset = tools::R_user_dir("planscanR", "data")
)
if (!dir.exists(APP_DATA_DIR)) {
  dir.create(APP_DATA_DIR, recursive = TRUE)
}
# Cap rows shown in the (client-side) review table for responsiveness.
MAX_TABLE_ROWS <- 5000L
# Persisted random sample (document_ids), so a drawn sample survives a restart.
RANDOM_SAMPLE_PATH <- file.path(APP_DATA_DIR, "random_sample.rds")
# Records sampled per country in Random review (stratified for balance).
RANDOM_PER_COUNTRY_DEFAULT <- 50L

# Offline translator (Argos Translate). Declared up front so reticulate/uv can
# resolve it; the language-pair models download once on the first translation.
# Force single-threaded CTranslate2: its OpenMP threads otherwise conflict with
# R/Shiny and segfault when a translation runs inside the reactive context.
Sys.setenv(OMP_NUM_THREADS = "1")
reticulate::py_require("argostranslate")

# Build the snapshot at startup if it isn't cached yet (slow on first run:
# reads every sidecar JSON). Subsequent launches load the cached RDS.
if (!file.exists(snapshot_path(APP_DATA_DIR))) {
  message("No snapshot found — building from the sidecar cache (one-off, slow)...")
  load_or_build_snapshot(CACHE_DIR, COUNTRIES, APP_DATA_DIR, rebuild = TRUE)
}

# Client-side assets: styling for the per-row decision buttons, plus the JS that
# toggles a decision and syncs it to Shiny WITHOUT re-rendering the whole table
# (reviewSet for single rows; a bulkDecision handler for checkbox bulk actions).
review_assets <- function() {
  tagList(
    tags$style(HTML(
      ".rev-grp{display:flex;gap:3px;}",
      ".rev-btn{border:1px solid #d0d0d0;background:#fff;border-radius:4px;",
      "font-size:11px;padding:1px 7px;cursor:pointer;line-height:1.5;color:#666;}",
      ".rev-btn:hover{border-color:var(--c);color:var(--c);}",
      ".rev-btn.active{background:var(--c);border-color:var(--c);color:#fff;",
      "font-weight:600;}"
    )),
    tags$script(HTML(
      "window.__reviewState = window.__reviewState || {};
      function __revRestyle(key, dec){
        document.querySelectorAll('.rev-grp').forEach(function(g){
          if (g.getAttribute('data-review-id') !== String(key)) return;
          g.querySelectorAll('button').forEach(function(b){
            b.classList.toggle('active', b.getAttribute('data-decision') === dec);
          });
        });
      }
      window.__reviewer = window.__reviewer || '';
      window.reviewSet = function(id, country, decision, source){
        if (!String(window.__reviewer || '').trim()) {
          alert('Enter your name (top of the sidebar) before classifying.');
          return;
        }
        var key = String(country) + '::' + String(id);
        var cur = (window.__reviewState[key] === undefined) ? null
          : window.__reviewState[key];
        var nd = (cur === decision) ? null : decision;
        window.__reviewState[key] = nd;
        __revRestyle(key, nd);
        if (window.Shiny) {
          Shiny.setInputValue('row_decision',
            {id: id, country: country, decision: nd,
             source: source || 'browse', nonce: Math.random()},
            {priority: 'event'});
        }
      };

      // --- lazy translation: fill the right column of an expanded row ---
      window.__xlate = window.__xlate || {};
      function __esc(s){ var d = document.createElement('div');
        d.textContent = String(s); return d.innerHTML; }
      function __xlateFill(el, data){
        if (data && (data.title_en || data.summary_en)) {
          var h = '';
          if (data.title_en) {
            h += '<b>Title</b><p style=\"margin:2px 0 8px;\">' +
              __esc(data.title_en) + '</p>';
          }
          if (data.summary_en) {
            h += '<b>Summary</b><p style=\"margin:2px 0 0;white-space:pre-wrap;\">' +
              __esc(data.summary_en) + '</p>';
          }
          el.innerHTML = h;
        } else if (data && data.quota) {
          el.innerHTML = '<span style=\"color:#b35;\">Daily free translation ' +
            'quota reached — resets in a few hours. (Original text is on the left.)</span>';
        } else {
          el.innerHTML = '<span style=\"color:#b35;\">Translation unavailable ' +
            '(service error or unsupported language).</span>';
        }
        el.setAttribute('data-done', '1');
      }
      function __xlateScan(){
        document.querySelectorAll('.xlate:not([data-done])').forEach(function(el){
          if (el.offsetParent === null) return;            // not visible yet
          var key = el.getAttribute('data-key');
          if (window.__xlate[key]) { __xlateFill(el, window.__xlate[key]); return; }
          if (el.getAttribute('data-requested')) return;   // already in flight
          el.setAttribute('data-requested', '1');
          el.innerHTML = '<span style=\"color:#888;\">Translating…</span>';
          Shiny.setInputValue('translate_request',
            {id: el.getAttribute('data-id'),
             country: el.getAttribute('data-country'), nonce: Math.random()},
            {priority: 'event'});
        });
      }
      document.addEventListener('click', function(){ setTimeout(__xlateScan, 50); });

      // --- arrow-key navigation for the single-record stepper ---
      // Left/Right step prev/next, but only when the stepper is visible and the
      // user isn't typing in a field.
      document.addEventListener('keydown', function(e){
        var t = e.target;
        if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' ||
                  t.tagName === 'SELECT' || t.isContentEditable)) return;
        var nextBtn = document.getElementById('sr_next');
        if (!nextBtn || nextBtn.offsetParent === null) return; // stepper hidden
        if (e.key === 'ArrowRight') { e.preventDefault(); nextBtn.click(); }
        else if (e.key === 'ArrowLeft') {
          var prevBtn = document.getElementById('sr_prev');
          if (prevBtn) { e.preventDefault(); prevBtn.click(); }
        }
      });

      $(document).on('shiny:connected', function(){
        Shiny.addCustomMessageHandler('setReviewer', function(msg){
          window.__reviewer = (msg == null) ? '' : String(msg);
        });
        Shiny.addCustomMessageHandler('bulkDecision', function(msg){
          var dec = (msg.decision === null || msg.decision === undefined)
            ? null : msg.decision;
          (msg.keys || []).forEach(function(key){
            window.__reviewState[key] = dec;
            __revRestyle(key, dec);
          });
        });
        Shiny.addCustomMessageHandler('translation', function(msg){
          window.__xlate[msg.key] = {title_en: msg.title_en,
            summary_en: msg.summary_en, quota: msg.quota};
          document.querySelectorAll('.xlate[data-key=\"' + CSS.escape(msg.key) +
            '\"]').forEach(function(el){ __xlateFill(el, window.__xlate[msg.key]); });
        });
      });"
    ))
  )
}

# -----------------------------------------------------------------------------
# UI
# -----------------------------------------------------------------------------
ui <- page_navbar(
  title = "planscanR — pipeline funnel & review",
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  header = review_assets(),
  sidebar = sidebar(
    width = 300,
    selectizeInput(
      "reviewer",
      "Your name (required to classify)",
      choices = load_reviewers(APP_DATA_DIR),
      selected = "",
      options = list(
        create = TRUE,
        placeholder = "Select or type your name",
        plugins = list("remove_button")
      )
    ),
    selectInput(
      "countries",
      "Countries",
      choices = COUNTRIES,
      selected = COUNTRIES,
      multiple = TRUE
    ),
    sliderInput(
      "threshold",
      "Cosine threshold",
      min = 0,
      max = 1,
      value = 0.5,
      step = 0.01
    ),
    sliderInput(
      "kw_min",
      "Min keyword hits",
      min = 0,
      max = 6,
      value = 2,
      step = 1
    ),
    hr(),
    actionButton("rebuild", "Rebuild snapshot", class = "btn-outline-secondary btn-sm"),
    helpText("Re-reads the sidecar cache. Slow; only needed after a new pipeline run."),
    uiOutput("snapshot_info")
  ),

  # ---- Funnel tab ----
  nav_panel(
    "Funnel",
    layout_columns(
      fill = FALSE,
      value_box("Indexed", textOutput("vb_total"), theme = "secondary"),
      value_box("Selected", textOutput("vb_selected"), theme = "primary"),
      value_box("Selected %", textOutput("vb_selected_pct"), theme = "primary"),
      value_box("Reviewed", textOutput("vb_reviewed"), theme = "success")
    ),
    layout_columns(
      col_widths = c(7, 5),
      card(
        card_header("Pipeline funnel"),
        plotly::plotlyOutput("funnel_plot", height = "300px")
      ),
      card(
        card_header("Per-country breakdown"),
        # Bounded height + scroll so the breakdown never pushes the metrics
        # panel below off-screen.
        div(
          style = "max-height:300px;overflow:auto;",
          reactable::reactableOutput("funnel_table")
        )
      )
    ),
    card(
      card_header("Automated selection vs. human review", metrics_help_ui()),
      radioButtons(
        "eval_on",
        NULL,
        inline = TRUE,
        choices = c(
          "All reviews" = "all",
          "Random sample only (unbiased)" = "random"
        ),
        selected = "all"
      ),
      uiOutput("agreement_ui")
    )
  ),

  # ---- Review tab ----
  nav_panel(
    "Review",
    card(
      card_header("Triage"),
      layout_columns(
        fill = FALSE,
        col_widths = c(4, 8),
        selectInput(
          "stage_filter",
          "Show",
          choices = c(
            "All" = "all",
            "Selected only" = "selected",
            "Not selected" = "not_selected",
            "Reviewed" = "reviewed",
            "Unreviewed" = "unreviewed",
            "Disagreements (auto vs human)" = "disagree"
          ),
          selected = "selected"
        ),
        div(
          style = "padding-top:28px;",
          actionButton("mark_keep", "Keep", class = "btn-success btn-sm"),
          actionButton("mark_drop", "Drop", class = "btn-danger btn-sm"),
          actionButton("mark_unsure", "Unsure", class = "btn-warning btn-sm"),
          actionButton("mark_clear", "Clear", class = "btn-outline-secondary btn-sm"),
          span(textOutput("review_info", inline = TRUE), style = "margin-left:12px;color:#666;")
        )
      ),
      helpText(
        "Decide per record with the Keep / Drop / Unsure buttons in each row ",
        "(saves instantly; click the active button again to clear). For bulk ",
        "decisions, tick rows with the checkboxes and use the toolbar buttons ",
        "above. Click anywhere on a row to fold down its summary — original on ",
        "the left, English translation on the right."
      ),
      reactable::reactableOutput("review_tbl")
    )
  ),

  # ---- Random Review tab ----
  nav_panel(
    "Random review",
    card(
      card_header("Random sample — unbiased review"),
      # Compact single-row control strip (keeps the table/record area high up).
      div(
        class = "d-flex align-items-end flex-wrap gap-3",
        div(
          style = "width:140px;",
          numericInput(
            "rnd_n",
            "Records / country",
            value = RANDOM_PER_COUNTRY_DEFAULT,
            min = 1,
            step = 10
          )
        ),
        div(
          style = "width:120px;",
          numericInput("rnd_seed", "Seed (optional)", value = NA, min = 0)
        ),
        actionButton("rnd_draw", "Draw sample", class = "btn-primary btn-sm mb-1"),
        div(class = "mb-1", checkboxInput("rnd_blind", "Blind (hide pipeline signals)", value = TRUE)),
        div(
          class = "mb-1",
          radioButtons(
            "rnd_view",
            NULL,
            choices = c("One at a time" = "single", "Table" = "table"),
            selected = "single",
            inline = TRUE
          )
        ),
        span(textOutput("rnd_info", inline = TRUE), class = "mb-2", style = "color:#666;")
      ),
      helpText(
        "Balanced random sample (N per country) — a fair estimate of the ",
        "filter's precision/recall. Decisions are saved as source = \"random\"."
      ),

      # Table view: bulk toolbar + the reactable.
      conditionalPanel(
        condition = "input.rnd_view == 'table'",
        div(
          style = "padding-bottom:8px;",
          actionButton("rnd_keep", "Keep", class = "btn-success btn-sm"),
          actionButton("rnd_drop", "Drop", class = "btn-danger btn-sm"),
          actionButton("rnd_unsure", "Unsure", class = "btn-warning btn-sm"),
          actionButton("rnd_clear", "Clear", class = "btn-outline-secondary btn-sm")
        ),
        reactable::reactableOutput("random_tbl")
      ),

      # Single-record stepper view: one record, decide-and-advance, prev/next.
      conditionalPanel(
        condition = "input.rnd_view == 'single'",
        div(
          class = "d-flex align-items-center gap-2",
          style = "margin:4px 0 10px;",
          actionButton("sr_prev", "← Previous", class = "btn-outline-secondary btn-sm"),
          actionButton("sr_next", "Next →", class = "btn-outline-secondary btn-sm"),
          div(
            class = "ms-2",
            checkboxInput("sr_skip", "Skip already-classified", value = TRUE)
          ),
          span(textOutput("sr_pos", inline = TRUE), style = "color:#666;margin-left:8px;"),
          span(style = "flex:1;"),
          uiOutput("sr_decision", inline = TRUE)
        ),
        helpText(
          "← / → arrow keys also navigate. A Keep / Drop / Unsure choice saves ",
          "and jumps to the next unclassified record."
        ),
        uiOutput("sr_record")
      )
    )
  )
)

# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------
server <- function(input, output, session) {
  snap <- reactiveVal(load_or_build_snapshot(CACHE_DIR, COUNTRIES, APP_DATA_DIR))
  reviews <- reactiveVal(load_reviews(APP_DATA_DIR))

  # Reviewer identity. A name is REQUIRED before any keep/drop/unsure is
  # recorded. require_reviewer() returns the trimmed name or NULL (and nags).
  require_reviewer <- function() {
    who <- trimws(input$reviewer %||% "")
    if (!nzchar(who)) {
      showNotification(
        "Enter your name (top of the sidebar) before classifying.",
        type = "warning"
      )
      return(NULL)
    }
    who
  }
  # Persist newly-typed names so they're offered in the dropdown next time, and
  # mirror the current name to the client so the in-table buttons can refuse to
  # classify until a name is set.
  observeEvent(
    input$reviewer,
    {
      who <- trimws(input$reviewer %||% "")
      session$sendCustomMessage("setReviewer", who)
      if (nzchar(who) && !who %in% load_reviewers(APP_DATA_DIR)) {
        add_reviewer(APP_DATA_DIR, who)
        updateSelectizeInput(session, "reviewer", choices = load_reviewers(APP_DATA_DIR), selected = who)
      }
    },
    ignoreNULL = FALSE
  )

  observeEvent(input$rebuild, {
    withProgress(message = "Rebuilding snapshot from cache...", value = 0.5, {
      snap(load_or_build_snapshot(CACHE_DIR, COUNTRIES, APP_DATA_DIR, rebuild = TRUE))
    })
    showNotification("Snapshot rebuilt.", type = "message")
  })

  # Selection applied to the whole snapshot at the current thresholds.
  selected_snap <- reactive({
    apply_selection(snap(), input$threshold, as.integer(input$kw_min))
  })

  # Restricted to the chosen countries (used by both tabs).
  filtered <- reactive({
    s <- selected_snap()
    s[s$country %in% input$countries, , drop = FALSE]
  })

  # ---- Funnel tab ----
  output$vb_total <- renderText(format(nrow(filtered()), big.mark = ","))
  output$vb_selected <- renderText({
    format(sum(filtered()$selected %in% TRUE), big.mark = ",")
  })
  output$vb_selected_pct <- renderText({
    f <- filtered()
    if (nrow(f) == 0) {
      return("—")
    }
    sprintf("%.1f%%", 100 * sum(f$selected %in% TRUE) / nrow(f))
  })
  output$vb_reviewed <- renderText({
    rv <- reviews()
    fids <- filtered()$document_id
    format(sum(rv$document_id %in% fids), big.mark = ",")
  })

  output$funnel_plot <- plotly::renderPlotly({
    funnel_plot(compute_funnel(filtered(), by_country = FALSE))
  })

  output$funnel_table <- reactable::renderReactable({
    fd <- compute_funnel(filtered(), by_country = TRUE)
    fd <- fd[order(fd$country, fd$order), ]
    reactable::reactable(
      fd[, c("country", "stage", "n", "pct")],
      groupBy = "country",
      columns = list(
        country = reactable::colDef(name = "Country"),
        stage = reactable::colDef(name = "Stage"),
        n = reactable::colDef(name = "Records", aggregate = "max"),
        pct = reactable::colDef(
          name = "% of indexed",
          format = reactable::colFormat(digits = 1, suffix = "%"),
          aggregate = "max"
        )
      ),
      defaultExpanded = FALSE,
      compact = TRUE,
      pagination = FALSE
    )
  })

  output$agreement_ui <- renderUI({
    rv <- reviews()
    if (identical(input$eval_on, "random")) {
      rv <- rv[rv$source %in% "random", , drop = FALSE]
    }
    cmp <- selection_vs_human(filtered(), rv)
    if (is.null(cmp)) {
      return(helpText(
        if (identical(input$eval_on, "random")) {
          "No random-sample keep/drop decisions yet. Use the Random review tab to build an unbiased sample."
        } else {
          "No keep/drop decisions yet for the selected countries. Review some records to compare the automated selection against a human ground truth."
        }
      ))
    }
    layout_columns(
      fill = FALSE,
      value_box("Reviewed (keep/drop)", cmp$n_reviewed, theme = "secondary"),
      value_box("Precision", sprintf("%.2f", cmp$precision), theme = "primary"),
      value_box("Recall", sprintf("%.2f", cmp$recall), theme = "primary"),
      value_box("F1", sprintf("%.2f", cmp$f1), theme = "info"),
      value_box(
        "Confusion (TP/FP/FN/TN)",
        sprintf("%d / %d / %d / %d", cmp$tp, cmp$fp, cmp$fn, cmp$tn),
        theme = "secondary"
      )
    )
  })

  # ---- Review tab ----
  # Reviews are read with isolate() here so that recording a decision does NOT
  # re-run this reactive (and thus does not reload the table). The filters that
  # depend on reviews still pick up the current value whenever the country /
  # threshold / stage-filter inputs change.
  display_df <- reactive({
    s <- filtered()
    rv <- isolate(reviews())
    s_key <- review_key(s$country, s$document_id)
    reviewed_keys <- review_key(rv$country, rv$document_id)
    f <- input$stage_filter
    s <- switch(
      f,
      all = s,
      selected = s[s$selected %in% TRUE, , drop = FALSE],
      not_selected = s[!(s$selected %in% TRUE), , drop = FALSE],
      reviewed = s[s_key %in% reviewed_keys, , drop = FALSE],
      unreviewed = s[!s_key %in% reviewed_keys, , drop = FALSE],
      disagree = {
        dec <- stats::setNames(rv$decision, reviewed_keys)
        hk <- dec[s_key]
        keep_h <- !is.na(hk) & hk == "keep"
        drop_h <- !is.na(hk) & hk == "drop"
        auto <- s$selected %in% TRUE
        s[(auto & drop_h) | (!auto & keep_h), , drop = FALSE]
      },
      s
    )
    # selected first, then by descending cosine.
    cm <- s$cosine_max
    cm[is.na(cm)] <- -1
    s[order(-(s$selected %in% TRUE), -cm), , drop = FALSE]
  })

  # Capped slice actually rendered (also the index basis for bulk actions).
  display_capped <- reactive({
    d <- display_df()
    if (nrow(d) > MAX_TABLE_ROWS) {
      attr(d, "truncated") <- nrow(d)
      d <- d[seq_len(MAX_TABLE_ROWS), , drop = FALSE]
    }
    d
  })

  output$review_info <- renderText({
    d <- display_capped()
    tot <- attr(d, "truncated")
    if (!is.null(tot)) {
      sprintf("showing %d of %d (capped)", nrow(d), tot)
    } else {
      sprintf("%d rows", nrow(d))
    }
  })

  # Decision column is seeded from reviews via isolate() so a new decision does
  # not invalidate this render — the table stays put; the client updates the
  # affected row(s) in place (see review_assets()).
  output$review_tbl <- reactable::renderReactable({
    build_review_table(display_capped(), isolate(reviews()))
  })

  # Persist a single-row decision (fired by reviewSet() in the browser). No
  # table re-render: the button state was already updated client-side; here we
  # only write to disk and refresh the funnel/agreement panels. `source` records
  # whether it came from the Review (browse) or Random review table.
  observeEvent(
    input$row_decision,
    {
      info <- input$row_decision
      if (is.null(info) || is.null(info$id)) {
        return()
      }
      dec <- if (is.null(info$decision)) NA_character_ else info$decision
      src <- if (is.null(info$source)) "browse" else info$source
      cc <- if (is.null(info$country)) NA_character_ else info$country
      who <- NA_character_
      if (!is.na(dec)) {
        who <- require_reviewer()
        if (is.null(who)) {
          return()
        }
      }
      rv <- upsert_reviews(reviews(), info$id, cc, dec, source = src, reviewer = who)
      save_reviews(rv, APP_DATA_DIR)
      reviews(rv)
    },
    ignoreInit = TRUE
  )

  # Bulk decision on the checkbox-selected rows of `output_id`'s table. Persists,
  # then pushes the new state to the browser (bulkDecision) so the visible rows
  # update without a full table reload, and clears the selection. Shared by the
  # Review and Random review tables.
  apply_bulk <- function(decision, output_id, data_df, source) {
    idx <- reactable::getReactableState(output_id, "selected")
    if (length(idx) == 0L) {
      showNotification("No rows ticked.", type = "warning")
      return(invisible())
    }
    who <- NA_character_
    if (!is.na(decision)) {
      who <- require_reviewer()
      if (is.null(who)) {
        return(invisible())
      }
    }
    ids <- data_df$document_id[idx]
    ccs <- data_df$country[idx]
    rv <- upsert_reviews(reviews(), ids, ccs, decision, source = source, reviewer = who)
    save_reviews(rv, APP_DATA_DIR)
    reviews(rv)
    session$sendCustomMessage(
      "bulkDecision",
      list(
        keys = as.list(review_key(ccs, ids)),
        decision = if (is.na(decision)) NULL else decision
      )
    )
    reactable::updateReactable(output_id, selected = NA)
    showNotification(
      sprintf(
        "%d record(s) marked %s.",
        length(ids),
        if (is.na(decision)) "cleared" else decision
      ),
      type = "message"
    )
  }

  observeEvent(input$mark_keep, apply_bulk("keep", "review_tbl", display_capped(), "browse"))
  observeEvent(input$mark_drop, apply_bulk("drop", "review_tbl", display_capped(), "browse"))
  observeEvent(input$mark_unsure, apply_bulk("unsure", "review_tbl", display_capped(), "browse"))
  observeEvent(input$mark_clear, apply_bulk(NA_character_, "review_tbl", display_capped(), "browse"))

  # ---- Random Review tab ----
  # The sample is a tibble of (document_id, country), persisted across restarts.
  empty_sample <- function() {
    tibble::tibble(document_id = character(0), country = character(0))
  }
  random_ids <- reactiveVal({
    if (file.exists(RANDOM_SAMPLE_PATH)) {
      x <- readRDS(RANDOM_SAMPLE_PATH)
      if (is.data.frame(x)) x else empty_sample()
    } else {
      empty_sample()
    }
  })
  rnd_idx <- reactiveVal(1L) # position in the single-record stepper

  observeEvent(input$rnd_draw, {
    samp <- draw_random_sample(snap(), input$countries, input$rnd_n, input$rnd_seed)
    random_ids(samp)
    rnd_idx(1L) # restart the single-record stepper at the first record
    saveRDS(samp, RANDOM_SAMPLE_PATH)
    showNotification(
      sprintf("Drew a random sample of %d records.", nrow(samp)),
      type = "message"
    )
  })

  # Sampled records in the drawn (random) order, with selection applied so the
  # (non-blind) signals + agreement metrics are available. Joined on the
  # composite (country, document_id) key. Independent of reviews() so recording
  # a decision does not reload the table.
  random_df <- reactive({
    samp <- random_ids()
    base <- apply_selection(snap(), input$threshold, as.integer(input$kw_min))
    if (nrow(samp) == 0L) {
      return(base[0, , drop = FALSE])
    }
    base_key <- review_key(base$country, base$document_id)
    samp_key <- review_key(samp$country, samp$document_id)
    out <- base[match(samp_key, base_key), , drop = FALSE]
    out[!is.na(out$document_id), , drop = FALSE]
  })

  output$rnd_info <- renderText({
    samp <- random_ids()
    if (nrow(samp) == 0L) {
      return("No sample yet — click \"Draw sample\".")
    }
    rv <- reviews()
    done <- sum(
      review_key(samp$country, samp$document_id) %in%
        review_key(rv$country, rv$document_id)
    )
    sprintf(
      "%d in sample · %d reviewed · %d remaining",
      nrow(samp),
      done,
      nrow(samp) - done
    )
  })

  output$random_tbl <- reactable::renderReactable({
    build_review_table(
      random_df(),
      isolate(reviews()),
      source = "random",
      blind = isTRUE(input$rnd_blind)
    )
  })

  observeEvent(input$rnd_keep, apply_bulk("keep", "random_tbl", random_df(), "random"))
  observeEvent(input$rnd_drop, apply_bulk("drop", "random_tbl", random_df(), "random"))
  observeEvent(input$rnd_unsure, apply_bulk("unsure", "random_tbl", random_df(), "random"))
  observeEvent(input$rnd_clear, apply_bulk(NA_character_, "random_tbl", random_df(), "random"))

  # ---- Single-record stepper (Random review, "One at a time") ----
  # The record currently in focus (random order, clamped to bounds). Independent
  # of reviews() so recording a decision does not re-render / re-translate it.
  sr_current <- reactive({
    d <- random_df()
    if (nrow(d) == 0L) {
      return(NULL)
    }
    d[max(1L, min(rnd_idx(), nrow(d))), ]
  })

  sr_decision_value <- function(row) {
    rv <- reviews()
    v <- rv$decision[match(
      review_key(row$country, row$document_id),
      review_key(rv$country, rv$document_id)
    )]
    if (length(v) == 0L || is.na(v)) NA_character_ else v
  }

  # Which sampled records already have a decision (validated).
  sr_validated <- function(d) {
    rv <- reviews()
    review_key(d$country, d$document_id) %in% review_key(rv$country, rv$document_id)
  }

  # Record the decision (requires a reviewer name) and jump to the next
  # still-unclassified record — the fast validation path.
  sr_set <- function(dec) {
    who <- require_reviewer()
    if (is.null(who)) {
      return(invisible())
    }
    row <- sr_current()
    if (is.null(row)) {
      return(invisible())
    }
    rv <- upsert_reviews(
      reviews(),
      row$document_id,
      row$country,
      dec,
      source = "random",
      reviewer = who
    )
    save_reviews(rv, APP_DATA_DIR)
    reviews(rv)

    d <- random_df()
    i <- rnd_idx()
    val <- review_key(d$country, d$document_id) %in%
      review_key(rv$country, rv$document_id)
    nxt <- which(!val & seq_len(nrow(d)) > i)
    if (length(nxt)) {
      rnd_idx(nxt[1])
    } else {
      remaining <- which(!val)
      if (length(remaining)) {
        rnd_idx(remaining[1])
      } else {
        showNotification("All sampled records classified.", type = "message")
      }
    }
  }
  observeEvent(input$sr_keep, sr_set("keep"))
  observeEvent(input$sr_drop, sr_set("drop"))
  observeEvent(input$sr_unsure, sr_set("unsure"))

  # Prev/Next honour the "skip already-classified" toggle.
  observeEvent(input$sr_next, {
    d <- random_df()
    if (nrow(d) == 0L) {
      return()
    }
    i <- rnd_idx()
    if (isTRUE(input$sr_skip)) {
      j <- which(!sr_validated(d) & seq_len(nrow(d)) > i)
      rnd_idx(if (length(j)) j[1] else min(nrow(d), i + 1L))
    } else {
      rnd_idx(min(nrow(d), i + 1L))
    }
  })
  observeEvent(input$sr_prev, {
    d <- random_df()
    if (nrow(d) == 0L) {
      return()
    }
    i <- rnd_idx()
    if (isTRUE(input$sr_skip)) {
      j <- which(!sr_validated(d) & seq_len(nrow(d)) < i)
      rnd_idx(if (length(j)) j[length(j)] else max(1L, i - 1L))
    } else {
      rnd_idx(max(1L, i - 1L))
    }
  })

  # When skip is enabled, jump to the first unclassified record.
  observeEvent(input$sr_skip, {
    if (!isTRUE(input$sr_skip)) {
      return()
    }
    d <- random_df()
    if (nrow(d) == 0L) {
      return()
    }
    j <- which(!sr_validated(d))
    if (length(j)) {
      rnd_idx(j[1])
    }
  })

  output$sr_pos <- renderText({
    d <- random_df()
    if (nrow(d) == 0L) {
      return("no sample")
    }
    i <- max(1L, min(rnd_idx(), nrow(d)))
    row <- d[i, ]
    dec <- sr_decision_value(row)
    sprintf(
      "Record %d of %d · %s%s",
      i,
      nrow(d),
      toupper(row$country),
      if (!is.na(dec)) paste0(" · ", toupper(dec)) else ""
    )
  })

  output$sr_decision <- renderUI({
    row <- sr_current()
    if (is.null(row)) {
      return(NULL)
    }
    cur <- sr_decision_value(row)
    btn <- function(id, lab, dec, solid, outline) {
      cls <- if (identical(cur, dec)) solid else outline
      actionButton(id, lab, class = paste("btn-sm", cls))
    }
    tagList(
      btn("sr_keep", "Keep", "keep", "btn-success", "btn-outline-success"),
      btn("sr_drop", "Drop", "drop", "btn-danger", "btn-outline-danger"),
      btn("sr_unsure", "Unsure", "unsure", "btn-warning", "btn-outline-warning")
    )
  })

  # Re-renders only on navigation (not on a decision), translating the focused
  # record on the fly (cached in the sidecar after the first visit).
  output$sr_record <- renderUI({
    row <- sr_current()
    if (is.null(row)) {
      return(helpText("Draw a sample, then step through the records here."))
    }
    tr <- withProgress(message = "Translating (offline)…", value = 0.5, {
      tryCatch(
        ensure_translation(
          CACHE_DIR,
          row$country,
          row$document_id,
          row$title,
          row$summary
        ),
        error = function(e) NULL
      )
    })
    single_record_ui(row, tr)
  })

  # Expanding a row's fold-down fires this (once per record): translate title +
  # summary to English offline (Argos), cache in the sidecar, and push the
  # result back to fill the row's right-hand column. The first translation of a
  # session can be slow (model download / load), hence the progress indicator.
  # Shared by both the Review and Random review tables.
  observeEvent(
    input$translate_request,
    {
      info <- input$translate_request
      if (is.null(info) || is.null(info$id)) {
        return()
      }
      sn <- snap()
      i <- match(
        review_key(info$country, info$id),
        review_key(sn$country, sn$document_id)
      )
      if (is.na(i)) {
        return()
      }
      row <- sn[i, ]
      tr <- withProgress(
        message = "Translating (offline)…",
        value = 0.5,
        {
          tryCatch(
            ensure_translation(
              CACHE_DIR,
              row$country,
              row$document_id,
              row$title,
              row$summary
            ),
            error = function(e) NULL
          )
        }
      )
      ok <- function(x) if (!is.null(x) && !is.na(x) && nzchar(x)) x else NULL
      session$sendCustomMessage(
        "translation",
        list(
          key = review_key(row$country, row$document_id),
          title_en = if (is.null(tr)) NULL else ok(tr$title_en),
          summary_en = if (is.null(tr)) NULL else ok(tr$summary_en),
          quota = !is.null(tr) && isTRUE(tr$quota)
        )
      )
    },
    ignoreInit = TRUE
  )

  output$snapshot_info <- renderUI({
    p <- snapshot_path(APP_DATA_DIR)
    if (!file.exists(p)) {
      return(NULL)
    }
    helpText(sprintf(
      "Snapshot: %s records, built %s",
      format(nrow(snap()), big.mark = ","),
      format(file.info(p)$mtime, "%Y-%m-%d %H:%M")
    ))
  })
}

shinyApp(ui, server)
