# Build the pkgdown site locally with GitHub-style alert support.
#
# Applies the alert-rendering patches from tools/pkgdown-alerts.R and
# calls pkgdown::build_site() in-process. For the GitHub Pages CI
# deploy, see .github/workflows/pkgdown.yaml — it sources the same
# patch file before calling build_site_github_pages().

source("tools/pkgdown-alerts.R")

# Keep the build in the current R process so the namespace patches
# survive — pkgdown::build_site() otherwise forks a callr subprocess
# that does not inherit them. `install = TRUE` still installs planscanR
# into a temp library so vignettes' `library(planscanR)` calls resolve.
pkgdown::build_site(new_process = FALSE, install = TRUE)
