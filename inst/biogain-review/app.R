# =============================================================================
# planscanR pipeline funnel + human-review tool
# =============================================================================
# A standalone Shiny app (it does NOT modify any planscanR package function).
# It reads the sidecar cache read-only via the package's exported functions
# (index_cache / score_keywords / select_assessments) and writes its review
# decisions to a CSV (reviews.csv) at the cache root, alongside files/.
#
# Two tabs:
#   * Funnel  — how many records survive each pipeline step (indexed -> cosine /
#               classifier / keyword -> ensemble selection -> attachments ->
#               downloaded), with the cosine + keyword thresholds adjustable.
#               If human review exists, shows automated-vs-human agreement.
#   * Review  — triage the corpus by hand (keep / drop / unsure) to build the
#               ground-truth selection to compare the pipeline against.
#
# Launch it with planscanR::run_biogain_review(); the cache dir resolves from
# that function's cache_dir argument, the PLANSCANR_CACHE env var, or the
# planscanR.cache_dir option.
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
COUNTRIES <- c("nl", "de", "at", "dk")
# Where the app's own artefacts live (snapshot + reviews.csv + reviewers list).
# Defaults to the cache ROOT so the human annotations sit alongside the data
# they describe (and travel with any cache sync). They live at the root, not
# under files/, so clear_cache() — which only wipes files/ — leaves them intact.
APP_DATA_DIR <- Sys.getenv("BIOGAIN_REVIEW_DATA", unset = CACHE_DIR)
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
    # A debounced "Loading…" pill, shown whenever Shiny is busy for >250ms (so
    # the slower Review/Random tables clearly read as loading, without flicker
    # on quick interactions). Toggled by the shiny:busy / shiny:idle JS below.
    tags$div(
      id = "busy-indic",
      class = "busy-indic",
      tags$span(class = "busy-spinner"),
      "Loading…"
    ),
    tags$style(HTML(
      ".rev-grp{display:flex;gap:3px;}",
      ".rev-btn{border:1px solid #d0d0d0;background:#fff;border-radius:4px;",
      "font-size:11px;padding:1px 7px;cursor:pointer;line-height:1.5;color:#666;}",
      ".rev-btn:hover{border-color:var(--c);color:var(--c);}",
      ".rev-btn.active{background:var(--c);border-color:var(--c);color:#fff;",
      "font-weight:600;}",
      # BIOGAIN brand: navy->teal->green gradient header, flat cards.
      ".navbar{background:linear-gradient(90deg,#0e3c62 0%,#009aa3 55%,",
      "#92c023 100%)!important;}",
      ".navbar .navbar-brand,.navbar .nav-link{color:#fff!important;}",
      ".navbar .nav-link.active,.navbar .show>.nav-link{color:#fff!important;",
      "font-weight:600;text-decoration:underline;}",
      ".card{border:1px solid #e6e8ea;}",
      "a{color:#0e3c62;}",
      # Sliders in brand navy (instead of the default off-brand blue).
      ".irs-bar{background:#0e3c62;border-color:#0e3c62;}",
      ".irs-handle{border-color:#0e3c62;}",
      ".irs-handle>i:first-child{background:#0e3c62;}",
      ".irs-from,.irs-to,.irs-single{background:#0e3c62;}",
      ".irs-from:before,.irs-to:before,.irs-single:before{",
      "border-top-color:#0e3c62;}",
      # Fixed, centered decision bar for the single-record stepper (offset past
      # the 300px sidebar so it spans only the main content area).
      ".sr-decision-bar{position:fixed;left:300px;right:0;bottom:0;z-index:1030;",
      "background:rgba(255,255,255,0.97);border-top:1px solid #e6e8ea;",
      "box-shadow:0 -2px 10px rgba(0,0,0,.06);padding:12px;text-align:center;}",
      ".sr-decision-bar .btn{min-width:130px;margin:0 6px;}",
      # Drop the checkbox's form-group margin so it aligns with the nav buttons.
      ".sr-inline .shiny-input-container,.sr-inline .form-group{margin-bottom:0;}",
      "@media (max-width:768px){.sr-decision-bar{left:0;}}",
      # Centered "Loading…" pill (hidden until shiny:busy fires for >250ms).
      ".busy-indic{display:none;position:fixed;top:50%;left:50%;",
      "transform:translate(-50%,-50%);z-index:2000;align-items:center;gap:12px;",
      "background:#0e3c62;color:#fff;font-size:18px;font-weight:600;",
      "padding:18px 28px;border-radius:16px;box-shadow:0 6px 28px rgba(0,0,0,.35);}",
      ".busy-spinner{width:20px;height:20px;border:3px solid rgba(255,255,255,.4);",
      "border-top-color:#fff;border-radius:50%;display:inline-block;",
      "animation:busy-spin .7s linear infinite;}",
      "@keyframes busy-spin{to{transform:rotate(360deg);}}",
      # Ring on the reviewer's current choice in the (solid) decision bar.
      ".sr-decision-bar .btn.active{box-shadow:0 0 0 3px rgba(14,60,98,.4);}",
      # Strip inner input margins so the whole control row aligns on one baseline.
      ".ctrl-strip .shiny-input-container{margin-bottom:0!important;}",
      # Breathing room between the All reviews / Random sample radio options
      # (Shiny renders inline choices as label.radio-inline).
      "#eval_on .radio-inline{margin-right:1.75rem;}",
      # White circular info button on metric cards (clear hover affordance).
      ".metric-info:hover,.metric-info:focus{background:rgba(255,255,255,.4)",
      "!important;outline:none;}",
      # Small group label sitting above a value-box metric name. White so it
      # reads cleanly on the coloured (themed) value-box backgrounds.
      ".metric-group{font-size:0.7rem;font-weight:600;letter-spacing:.04em;",
      "text-transform:uppercase;color:#fff;opacity:.85;margin-bottom:1px;}"
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

      // --- click-to-open popovers for the ⓘ icons (table headers + metric
      // cards). reactable re-renders its header DOM on sort/filter/page, which
      // orphans any attached popover, so we (re)initialise via a MutationObserver
      // — every freshly-inserted trigger gets a fresh Bootstrap popover.
      function __initPopovers(){
        if (!window.bootstrap || !bootstrap.Popover) return;
        document.querySelectorAll('[data-bs-toggle=\"popover\"]:not([data-pop-done])')
          .forEach(function(el){
            el.setAttribute('data-pop-done','1');
            try { new bootstrap.Popover(el); } catch(e) {}
          });
      }
      var __popTimer = null;
      var __popObserver = new MutationObserver(function(){
        if (__popTimer) return;
        __popTimer = setTimeout(function(){ __popTimer = null; __initPopovers(); }, 100);
      });
      $(document).on('shiny:connected', function(){
        __initPopovers();
        __popObserver.observe(document.body, {childList: true, subtree: true});
      });

      // --- debounced 'Loading…' indicator on Shiny busy/idle ---
      var __busyTimer = null;
      $(document).on('shiny:busy', function(){
        if (__busyTimer) return;
        __busyTimer = setTimeout(function(){
          var el = document.getElementById('busy-indic');
          if (el) el.style.display = 'flex';
        }, 250);
      });
      $(document).on('shiny:idle', function(){
        if (__busyTimer) { clearTimeout(__busyTimer); __busyTimer = null; }
        var el = document.getElementById('busy-indic');
        if (el) el.style.display = 'none';
        setTimeout(__initPopovers, 60); // wire up any newly-rendered ⓘ icons
      });

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
            summary_en: msg.summary_en};
          document.querySelectorAll('.xlate[data-key=\"' + CSS.escape(msg.key) +
            '\"]').forEach(function(el){ __xlateFill(el, window.__xlate[msg.key]); });
        });
      });"
    ))
  )
}

# Blocking welcome modal: a reviewer must identify themselves before doing
# anything. They pick an existing name or type a new full name.
reviewer_modal <- function() {
  modalDialog(
    title = "Welcome to the planscanR curation tool",
    selectizeInput(
      "modal_reviewer",
      "Your full name",
      choices = load_reviewers(APP_DATA_DIR),
      selected = "",
      width = "100%",
      options = list(
        create = TRUE,
        placeholder = "Select your name, or type a new full name"
      )
    ),
    helpText(
      "Required before classifying — every review is attributed to you. ",
      "New reviewers start by re-checking records others have already reviewed ",
      "(to measure agreement) before fresh records are sampled."
    ),
    footer = actionButton("modal_ok", "Start curating", class = "btn-primary"),
    easyClose = FALSE,
    fade = FALSE
  )
}

# -----------------------------------------------------------------------------
# UI
# -----------------------------------------------------------------------------
ui <- page_navbar(
  title = "planscanR — Curation",
  id = "nav",
  theme = bs_theme(
    version = 5,
    bootswatch = "flatly",
    primary = "#0e3c62", # BIOGAIN brand navy
    secondary = "#009aa3", # brand teal
    success = "#92c023", # brand green
    "border-radius" = "0.6rem"
  ),
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
    # Countries / thresholds only shape the Funnel view, so they're shown only
    # there to keep the review pages uncluttered.
    conditionalPanel(
      condition = "input.nav == 'Overview'",
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
      )
    ),
    hr(),
    selectInput(
      "learner",
      "Selection model",
      choices = selection_learner_choices(),
      selected = "logistic"
    ),
    actionButton("train_model", "Train selection model", class = "btn-outline-primary btn-sm"),
    helpText(
      "Fits a model on your keep/drop labels (random sample) over the sidecar ",
      "scores. Cross-validated metrics appear on the Overview tab."
    ),
    uiOutput("model_info"),
    sliderInput(
      "model_threshold",
      "Model decision threshold",
      min = 0,
      max = 1,
      value = 0.5,
      step = 0.01
    ),
    actionButton("compute_lc", "Compute learning curve", class = "btn-primary btn-sm"),
    plotly::plotlyOutput("learning_curve_plot", height = "220px"),
    helpText(
      "Repeated held-out resampling on the random sample: F1 vs. number of ",
      "labels. Shows where adding more labels stops helping."
    ),
    hr(),
    actionButton("rebuild", "Rebuild snapshot", class = "btn-outline-secondary btn-sm"),
    helpText("Re-reads the sidecar cache. Slow; only needed after a new pipeline run."),
    uiOutput("snapshot_info")
  ),

  # ---- Funnel tab ----
  nav_panel(
    "Overview",
    layout_columns(
      fill = FALSE,
      value_box("Indexed", textOutput("vb_total"), theme = "secondary"),
      value_box("Selected (heuristic)", textOutput("vb_selected"), theme = "primary"),
      value_box("Selected (model)", textOutput("vb_selected_model"), theme = "primary"),
      value_box("Reviewed", textOutput("vb_reviewed"), theme = "secondary")
    ),
    layout_columns(
      col_widths = c(7, 5),
      card(
        card_header("Pipeline funnel"),
        plotly::plotlyOutput("funnel_plot", height = "100%")
      ),
      # Equal-height with the plot card: as_fill_item makes the table fill the
      # card body, and giving the reactable height = 100% lets IT do the
      # scrolling (so its header stays sticky natively, unlike scrolling an
      # outer div).
      card(
        card_header("Per-country breakdown"),
        bslib::as_fill_item(
          reactable::reactableOutput("funnel_table", height = "100%")
        )
      )
    ),
    card(
      card_header(
        div(
          class = "d-flex justify-content-between align-items-center",
          span("Automated selection vs. human review"),
          actionButton(
            "show_perf_country",
            "Performance by country",
            class = "btn-outline-secondary btn-sm"
          )
        )
      ),
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
      uiOutput("agreement_ui"),
      uiOutput("model_agreement_ui"),
      # Pin top cards + this stats card; only the middle plot/table row grows.
      fill = FALSE
    )
  ),

  # ---- Review tab ----
  nav_panel(
    "Review",
    card(
      card_header("Triage"),
      # One baseline-aligned row: the Show dropdown and the bulk buttons + status
      # all sit on the same bottom edge (ctrl-strip zeroes the select's margin).
      div(
        class = "ctrl-strip d-flex align-items-end flex-wrap gap-2",
        div(
          style = "min-width:300px;",
          selectInput(
            "stage_filter",
            "Show",
            choices = c(
              "All" = "all",
              "Heuristic-selected" = "selected",
              "Heuristic not selected" = "not_selected",
              "Model-selected" = "model_selected",
              "Model not selected" = "model_not_selected",
              "Heuristic vs Model differ" = "model_vs_heuristic",
              "Reviewed" = "reviewed",
              "Unreviewed" = "unreviewed",
              "Disagreements (auto vs human)" = "disagree"
            ),
            selected = "selected",
            width = "100%"
          )
        ),
        actionButton("mark_keep", "Keep", class = "btn-success btn-sm"),
        actionButton("mark_drop", "Drop", class = "btn-danger btn-sm"),
        actionButton("mark_unsure", "Unsure", class = "btn-warning btn-sm"),
        actionButton("mark_clear", "Clear", class = "btn-outline-secondary btn-sm"),
        span(textOutput("review_info", inline = TRUE), style = "margin-left:8px;color:#666;")
      ),
      helpText(
        "Decide per record with the Keep / Drop / Unsure buttons in each row ",
        "(saves instantly; click the active button again to clear). For bulk ",
        "decisions, tick rows with the checkboxes and use the toolbar buttons ",
        "above. Click anywhere on a row to fold down its summary — original on ",
        "the left, English translation on the right."
      ),
      helpText(
        "The blue \"Pre-selected\" column is the heuristic rule; the green ",
        "\"Model\" column is the trained model's decision at the current ",
        "decision threshold (set in the sidebar)."
      ),
      reactable::reactableOutput("review_tbl")
    )
  ),

  # ---- Random Review tab ----
  nav_panel(
    "Random review",
    card(
      card_header("Random sample — unbiased review"),
      # Single-row control strip. `ctrl-strip` zeroes the inner input margins
      # (see CSS) so, with align-items-end, every control — inputs, button,
      # checkbox, radios, and the status text — lines up on one bottom baseline.
      div(
        class = "ctrl-strip d-flex align-items-end flex-wrap gap-3",
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
        actionButton("rnd_draw", "Build queue", class = "btn-primary"),
        div(checkboxInput("rnd_blind", "Blind (hide pipeline signals)", value = TRUE)),
        div(
          radioButtons(
            "rnd_view",
            NULL,
            choices = c("One at a time" = "single", "Table" = "table"),
            selected = "single",
            inline = TRUE
          )
        ),
        span(textOutput("rnd_info", inline = TRUE), style = "color:#666;")
      ),
      helpText(
        "\"Build queue\" first serves records others reviewed but you haven't ",
        "(to measure cross-reviewer agreement); once you're caught up it samples ",
        "fresh records (N per country). Decisions are saved as source = \"random\"."
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
          # `sr-inline` zeroes the checkbox's form-group margin so it lines up
          # vertically with the Previous / Next buttons.
          div(
            class = "ms-2 sr-inline",
            checkboxInput("sr_skip", "Skip already-classified", value = TRUE)
          ),
          span(textOutput("sr_pos", inline = TRUE), style = "color:#666;margin-left:8px;")
        ),
        helpText(
          "← / → arrow keys also navigate. A Keep / Drop / Unsure choice saves ",
          "and jumps to the next unclassified record."
        ),
        # Extra bottom padding so the last record isn't hidden behind the fixed
        # decision bar.
        div(style = "padding-bottom:96px;", uiOutput("sr_record")),
        # Fixed, centered decision bar (like a menu bar) across the main area.
        div(class = "sr-decision-bar", uiOutput("sr_decision"))
      )
    )
  )
)

# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------
server <- function(input, output, session) {
  # Value-box title with a small muted group label above the metric name.
  metric_title <- function(group, label) {
    htmltools::div(htmltools::div(group, class = "metric-group"), label)
  }

  snap <- reactiveVal(load_or_build_snapshot(CACHE_DIR, COUNTRIES, APP_DATA_DIR))
  reviews <- reactiveVal(load_reviews(APP_DATA_DIR))
  sel_model <- reactiveVal(load_app_model(APP_DATA_DIR))

  # #1 — force the reviewer to identify themselves on load.
  showModal(reviewer_modal())
  observeEvent(input$modal_ok, {
    who <- trimws(input$modal_reviewer %||% "")
    if (!nzchar(who)) {
      showNotification("Please enter your name to continue.", type = "warning")
      return()
    }
    if (!who %in% load_reviewers(APP_DATA_DIR)) {
      add_reviewer(APP_DATA_DIR, who)
    }
    updateSelectizeInput(
      session,
      "reviewer",
      choices = load_reviewers(APP_DATA_DIR),
      selected = who
    )
    removeModal()
  })

  # The current reviewer's name ("" if unset), without nagging.
  current_reviewer <- function() trimws(input$reviewer %||% "")

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

  # Train the learned selection model on the current snapshot + reviews, persist
  # it next to reviews.csv, and surface its CV metrics on the Overview tab.
  observeEvent(input$train_model, {
    res <- tryCatch(
      withProgress(message = "Training selection model (cross-validating)...", value = 0.5, {
        train_app_model(snap(), reviews(), input$learner, APP_DATA_DIR)
      }),
      error = function(e) e
    )
    if (inherits(res, "error")) {
      showNotification(
        paste0("Training failed: ", conditionMessage(res)),
        type = "error",
        duration = 8
      )
      return()
    }
    sel_model(res)
    cv <- res$cv
    showNotification(
      sprintf(
        "Model trained on %d labels — CV F1 %.2f (P %.2f / R %.2f).",
        res$n_train,
        cv$f1,
        cv$precision,
        cv$recall
      ),
      type = "message",
      duration = 6
    )
  })

  # Learning curve: held-out F1 vs. number of labels, computed on demand.
  lc_data <- reactiveVal(NULL)
  observeEvent(input$compute_lc, {
    res <- tryCatch(
      withProgress(message = "Computing learning curve (repeated held-out resampling)...", value = 0.5, {
        compute_learning_curve(snap(), reviews(), input$learner)
      }),
      error = function(e) e
    )
    if (inherits(res, "error")) {
      showNotification(
        paste0("Learning curve failed: ", conditionMessage(res)),
        type = "error",
        duration = 8
      )
      return()
    }
    lc_data(res)
  })

  output$learning_curve_plot <- plotly::renderPlotly({
    curve <- lc_data()
    if (is.null(curve)) {
      return(learning_curve_plot(NULL))
    }
    learning_curve_plot(planscanR::learning_curve_summary(curve))
  })

  output$model_info <- renderUI({
    m <- sel_model()
    if (is.null(m)) {
      return(helpText("No model trained yet."))
    }
    helpText(sprintf(
      "Model: %s · %d labels · trained %s",
      m$learner_name,
      m$n_train,
      format(m$trained_at, "%Y-%m-%d %H:%M")
    ))
  })

  # Learned-model metrics row on the Overview dashboard. Always shown for the
  # out-of-fold (random-sample) CV, recomputed at the chosen threshold without
  # retraining, with the F1 delta against the heuristic on the same sample.
  output$model_agreement_ui <- renderUI({
    m <- sel_model()
    if (is.null(m)) {
      return(helpText(
        "No learned model yet — click \"Train selection model\" in the sidebar."
      ))
    }
    cv <- selection_cv_metrics_safe(m, input$model_threshold)
    if (is.null(cv)) {
      return(helpText("Model has no cross-validation data."))
    }
    fmtv <- function(x) if (is.na(x)) "—" else sprintf("%.2f", x)

    # Heuristic F1 on the SAME (random) sample, for an apples-to-apples delta.
    rv_rand <- reviews()
    rv_rand <- rv_rand[rv_rand$source %in% "random", , drop = FALSE]
    base <- selection_vs_human(filtered(), rv_rand)
    delta_ui <- NULL
    if (!is.null(base) && !is.na(base$f1) && !is.na(cv$f1)) {
      d <- cv$f1 - base$f1
      delta_ui <- helpText(sprintf(
        "F1 vs heuristic (random sample): %+.2f (model %.2f vs %.2f).",
        d,
        cv$f1,
        base$f1
      ))
    }
    tagList(
      helpText(
        "Model — the trained selection model, cross-validated (out-of-fold: ",
        "each record is predicted by a model that did not see it in training) ",
        "on the unbiased random sample. These numbers are directly comparable ",
        "to the heuristic row above and aren't inflated by training on the ",
        "test data."
      ),
      layout_columns(
        fill = FALSE,
        value_box(
          metric_title("Model", "CV labels"),
          cv$n_reviewed,
          theme = "secondary"
        ),
        value_box(
          metric_title(
            "Model",
            div(
              class = "d-flex align-items-center",
              style = "gap:4px;",
              span("Precision · Recall · F1"),
              prf_help_ui_model()
            )
          ),
          sprintf("%s · %s · %s", fmtv(cv$precision), fmtv(cv$recall), fmtv(cv$f1)),
          theme = "success"
        ),
        value_box(
          metric_title(
            "Model",
            div(
              class = "d-flex align-items-center",
              style = "gap:4px;",
              span("Confusion (TP/FP/FN/TN)"),
              confusion_help_ui_model()
            )
          ),
          sprintf("%d / %d / %d / %d", cv$tp, cv$fp, cv$fn, cv$tn),
          theme = "secondary"
        )
      ),
      delta_ui
    )
  })

  # Per-country precision/recall/F1 — heuristic vs model — on the random sample.
  # Both evaluate on the same (random) consensus labels; the model figures come
  # from its stored out-of-fold predictions, the heuristic from select_assessments.
  output$perf_by_country <- reactable::renderReactable({
    rvr <- reviews()
    rvr <- rvr[rvr$source %in% "random", , drop = FALSE]
    heur <- selection_vs_human(selected_snap(), rvr, by_country = TRUE)
    if (is.null(heur)) {
      return(reactable::reactable(
        data.frame(Note = "No random-sample keep/drop labels yet.")
      ))
    }
    m <- sel_model()
    mdl <- if (is.null(m)) {
      NULL
    } else {
      selection_cv_metrics_safe(m, input$model_threshold, by_country = TRUE)
    }
    performance_by_country_table(heur, mdl)
  })

  # Open the per-country performance table in a modal (button in the agreement
  # panel header). The reactable binds to the output$perf_by_country above.
  observeEvent(input$show_perf_country, {
    showModal(modalDialog(
      title = "Performance by country",
      size = "l",
      easyClose = TRUE,
      helpText(
        "Per-country precision / recall / F1 on the random sample — heuristic ",
        "vs. model (model figures are out-of-fold). Per-country label counts ",
        "are small, so read these as noisier than the overall numbers (see the ",
        "Labels column)."
      ),
      div(
        style = "font-size:13px;line-height:1.5;margin:4px 0 12px;",
        tags$p(
          style = "margin:0 0 6px;",
          "Each metric compares the automated selection against your reviews, ",
          "treating the records you marked ",
          tags$b("keep"),
          " as correct:"
        ),
        tags$ul(
          style = "margin:0 0 6px;padding-left:18px;",
          tags$li(
            tags$b("Precision"),
            " — of the records the system selected, the share you also kept ",
            "(how much of what it picked was actually wanted). Low = too much junk."
          ),
          tags$li(
            tags$b("Recall"),
            " — of the records you kept, the share the system selected ",
            "(how much of what was wanted it caught). Low = it misses relevant records."
          ),
          tags$li(
            tags$b("F1"),
            " — the harmonic mean of precision and recall; high only when both are."
          )
        ),
        tags$p(
          style = "margin:0;color:#8a949e;",
          "The heuristic is scored directly on the labels (it has no fitted ",
          "parameters); the model is scored out-of-fold — each record is ",
          "predicted by a model that did not see it in training — so the two are ",
          "directly comparable."
        )
      ),
      reactable::reactableOutput("perf_by_country"),
      footer = modalButton("Close")
    ))
  })

  # Model P(keep) over the whole snapshot. Depends only on the snapshot + the
  # trained model (NOT the threshold), so moving the decision slider doesn't
  # re-predict all ~26k rows — the threshold cut is applied cheaply downstream.
  model_scored <- reactive({
    s <- snap()
    m <- sel_model()
    if (is.null(m)) {
      s$select_prob <- NA_real_
      return(s)
    }
    tryCatch(
      {
        s$select_prob <- planscanR::predict_selection(m, s)$select_prob
        s
      },
      error = function(e) {
        s$select_prob <- NA_real_
        s
      }
    )
  })

  # Selection applied to the whole snapshot at the current thresholds. Builds on
  # the model-scored snapshot so it carries both the heuristic `selected` and the
  # model `selected_model` (the latter derived from the model decision threshold).
  selected_snap <- reactive({
    s <- apply_selection(model_scored(), input$threshold, as.integer(input$kw_min))
    thr <- input$model_threshold
    if (is.null(thr) || is.na(thr)) {
      thr <- 0.5
    }
    s$selected_model <- !is.na(s$select_prob) & s$select_prob >= thr
    s
  })

  # Restricted to the chosen countries (used by both tabs).
  filtered <- reactive({
    s <- selected_snap()
    s[s$country %in% input$countries, , drop = FALSE]
  })

  # ---- Funnel tab ----
  output$vb_total <- renderText(format(nrow(filtered()), big.mark = ","))
  # Count + percent in a single card.
  output$vb_selected <- renderText({
    f <- filtered()
    n <- sum(f$selected %in% TRUE)
    if (nrow(f) == 0) {
      return("—")
    }
    sprintf("%s (%.1f%%)", format(n, big.mark = ","), 100 * n / nrow(f))
  })
  output$vb_selected_model <- renderText({
    f <- filtered()
    if (nrow(f) == 0 || !any(!is.na(f$select_prob))) {
      return("—") # no model trained yet
    }
    n <- sum(f$selected_model %in% TRUE)
    sprintf("%s (%.1f%%)", format(n, big.mark = ","), 100 * n / nrow(f))
  })
  output$vb_reviewed <- renderText({
    f <- filtered()
    if (nrow(f) == 0) {
      return("—")
    }
    # Distinct records (any reviewer) — count + percent of the indexed total.
    rkeys <- unique(review_key(reviews()$country, reviews()$document_id))
    n <- sum(review_key(f$country, f$document_id) %in% rkeys)
    sprintf("%s (%.1f%%)", format(n, big.mark = ","), 100 * n / nrow(f))
  })

  output$funnel_plot <- plotly::renderPlotly({
    funnel_plot(compute_funnel(
      filtered(),
      by_country = FALSE,
      has_model = any(!is.na(filtered()$select_prob))
    ))
  })

  output$funnel_table <- reactable::renderReactable({
    fd <- compute_funnel(
      filtered(),
      by_country = TRUE,
      has_model = any(!is.na(filtered()$select_prob))
    )
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
      defaultExpanded = TRUE,
      compact = TRUE,
      pagination = FALSE,
      # Fill the card and scroll internally -> header stays sticky natively.
      height = "100%"
    )
  })

  output$agreement_ui <- renderUI({
    # Cross-reviewer agreement: of records ≥2 people reviewed, how often they
    # gave the same decision (independent of the auto-vs-human comparison).
    irs <- inter_reviewer_summary(reviews())
    irs_ui <- if (!is.null(irs) && irs$n_multi > 0L) {
      helpText(sprintf(
        "Cross-reviewer agreement: %.0f%% — %d of %d records reviewed by ≥ 2 people match.",
        100 * irs$agreement_rate,
        irs$n_agree,
        irs$n_multi
      ))
    }

    rv <- reviews()
    if (identical(input$eval_on, "random")) {
      rv <- rv[rv$source %in% "random", , drop = FALSE]
    }
    cmp <- selection_vs_human(filtered(), rv)
    if (is.null(cmp)) {
      return(tagList(
        irs_ui,
        helpText(
          if (identical(input$eval_on, "random")) {
            "No random-sample keep/drop decisions yet. Use the Random review tab to build a queue."
          } else {
            "No keep/drop decisions yet for the selected countries. Review some records to compare the automated selection against a human ground truth."
          }
        )
      ))
    }
    fmtv <- function(x) if (is.na(x)) "—" else sprintf("%.2f", x)
    tagList(
      irs_ui,
      helpText(
        "Heuristic — the fixed select_assessments() rule (cosine OR classifier ",
        "OR keyword match, minus the confident fossil/nuclear trim) scored ",
        "against the human keep/drop ground truth. It has no fitted parameters, ",
        "so evaluating it directly on the labels is fair."
      ),
      layout_columns(
        fill = FALSE,
        value_box(
          metric_title("Heuristic", "Reviewed (keep/drop)"),
          cmp$n_reviewed,
          theme = "secondary"
        ),
        value_box(
          metric_title(
            "Heuristic",
            div(
              class = "d-flex align-items-center",
              style = "gap:4px;",
              span("Precision · Recall · F1"),
              prf_help_ui()
            )
          ),
          sprintf("%s · %s · %s", fmtv(cmp$precision), fmtv(cmp$recall), fmtv(cmp$f1)),
          theme = "primary"
        ),
        value_box(
          metric_title(
            "Heuristic",
            div(
              class = "d-flex align-items-center",
              style = "gap:4px;",
              span("Confusion (TP/FP/FN/TN)"),
              confusion_help_ui()
            )
          ),
          sprintf("%d / %d / %d / %d", cmp$tp, cmp$fp, cmp$fn, cmp$tn),
          theme = "secondary"
        )
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
      model_selected = s[s$selected_model %in% TRUE, , drop = FALSE],
      model_not_selected = s[!(s$selected_model %in% TRUE), , drop = FALSE],
      model_vs_heuristic = s[(s$selected %in% TRUE) != (s$selected_model %in% TRUE), , drop = FALSE],
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

  # Decision column shows the CURRENT reviewer's own decisions. reviews() is
  # isolated so a new decision doesn't reload the table (the client updates the
  # affected row in place); it re-renders when the reviewer switches.
  output$review_tbl <- reactable::renderReactable({
    rv <- isolate(reviews())
    rv <- rv[rv$reviewer %in% current_reviewer(), , drop = FALSE]
    build_review_table(display_capped(), rv)
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
    who <- require_reviewer()
    if (is.null(who)) {
      return()
    }
    # Prioritise records others reviewed but you haven't (cross-reviewer
    # agreement); only sample fresh records once you've caught up on those.
    samp <- build_review_queue(
      snap(),
      reviews(),
      who,
      input$countries,
      input$rnd_n,
      input$rnd_seed
    )
    mode <- attr(samp, "mode") %||% "empty"
    random_ids(samp)
    rnd_idx(1L) # restart the single-record stepper at the first record
    saveRDS(samp, RANDOM_SAMPLE_PATH)
    msg <- switch(
      mode,
      validate = sprintf(
        "Queued %d records already reviewed by others — re-check them to measure agreement.",
        nrow(samp)
      ),
      fresh = sprintf(
        "You're caught up on others' reviews — drew %d fresh records to expand the set.",
        nrow(samp)
      ),
      "No records to review for this selection."
    )
    showNotification(msg, type = "message")
  })

  # Sampled records in the drawn (random) order, with selection applied so the
  # (non-blind) signals + agreement metrics are available. Joined on the
  # composite (country, document_id) key. Independent of reviews() so recording
  # a decision does not reload the table.
  random_df <- reactive({
    samp <- random_ids()
    base <- selected_snap()
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
      return("No queue yet — click \"Build queue\".")
    }
    mine <- keys_reviewed_by(reviews(), current_reviewer())
    done <- sum(review_key(samp$country, samp$document_id) %in% mine)
    sprintf(
      "%d in queue · %d done by you · %d remaining",
      nrow(samp),
      done,
      nrow(samp) - done
    )
  })

  output$random_tbl <- reactable::renderReactable({
    rv <- isolate(reviews())
    rv <- rv[rv$reviewer %in% current_reviewer(), , drop = FALSE]
    build_review_table(
      random_df(),
      rv,
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

  # The CURRENT reviewer's own decision for a record (NA if they haven't decided
  # it) — others' decisions on the same record don't show here.
  sr_decision_value <- function(row) {
    reviewer_decision(reviews(), row$country, row$document_id, current_reviewer())
  }

  # Which queued records THIS reviewer has already classified.
  sr_validated <- function(d) {
    review_key(d$country, d$document_id) %in%
      keys_reviewed_by(reviews(), current_reviewer())
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

    # Advance to the next record THIS reviewer hasn't classified yet.
    d <- random_df()
    i <- rnd_idx()
    val <- review_key(d$country, d$document_id) %in%
      keys_reviewed_by(rv, who)
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
    # Solid by default; the reviewer's current choice gets the `active` ring.
    btn <- function(id, lab, dec, solid) {
      cls <- paste("btn-lg", solid, if (identical(cur, dec)) "active" else "")
      actionButton(id, lab, class = trimws(cls))
    }
    tagList(
      btn("sr_keep", "Keep", "keep", "btn-success"),
      btn("sr_drop", "Drop", "drop", "btn-danger"),
      btn("sr_unsure", "Unsure", "unsure", "btn-warning")
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
          summary_en = if (is.null(tr)) NULL else ok(tr$summary_en)
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
