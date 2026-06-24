#!/bin/bash
#
# Re-mint the boundary snapshots after pricing the 2026-11-10 §301 cranes/chassis
# codes (9903.91.12/.14 -> 100% in section_301_rates + s301_product_lists.csv).
# Only bnd_2026-11-10 changes (the codes are gated to 11-10, masked in every real
# rev), but build_boundary_mints re-mints all 3 idempotently (03-12/02-20 identical).
# Then re-run weighted daily + invariants + impact + chart.
#
# Usage: sbatch scripts/submit_reprice_301.sh

#SBATCH --job-name=reprice-301
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --output=/home/%u/slurm-logs/reprice-301-%j.out
#SBATCH --error=/home/%u/slurm-logs/reprice-301-%j.err
#SBATCH --chdir=/nfs/roberts/project/pi_nrs36/jar335/Repositories/tariff-rate-tracker

set -uo pipefail
mkdir -p ~/slurm-logs

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh
else echo "ERROR: no Lmod init" >&2; exit 1; fi
module purge
module load R/4.4.2-gfbf-2024a
export TARIFF_DAILY_CORES=4

echo "=== 1. Re-mint boundary snapshots with the new §301 config ==="
Rscript -e '
suppressPackageStartupMessages({library(here);library(tidyverse);library(jsonlite)})
suppressMessages({
  source(here("src","00_build_timeseries.R"))
  source(here("src","revisions.R")); source(here("src","policy_params.R"))
  source(here("src","09_daily_series.R")); source(here("src","build_import_weights.R"))
})
dir <- here("data","timeseries")
pp <- load_policy_params(use_policy_dates = TRUE)
rd <- load_revision_dates(use_policy_dates = TRUE)
census_codes   <- read_csv(here("resources","census_codes.csv"), col_types = cols(.default = col_character()))
countries      <- census_codes$Code
country_lookup <- build_country_lookup(here("resources","census_codes.csv"))
tpc_path       <- load_local_paths()$tpc_benchmark
b <- discover_boundaries(rd, dir, pp, overrides = pp$BOUNDARY_OVERRIDES, horizon = pp$SERIES_HORIZON_END)
rd <- build_boundary_mints(rd, b, pp, dir,
        country_lookup = country_lookup, countries = countries, census_codes = census_codes,
        archive_dir = here("data","hts_archives"), tpc_path = tpc_path)
cat("\n=== bnd_2026-11-10: China 301 footprint after repricing ===\n")
s <- readRDS(file.path(dir,"snapshot_bnd_2026-11-10.rds"))
cn <- s[s$country=="5700",]
cat("China rows with rate_301>0:", sum(cn$rate_301>0), "\n")
for (h8 in c("87163900","87169030","87169050","84261900")) {
  r <- cn$rate_301[substr(cn$hts10,1,8)==h8]
  if (length(r)) cat("  hts8", h8, ": max rate_301 =", max(r), " (", length(r), "rows )\n")
}
# weighted daily from existing snapshots + the (re-minted) bnd_
imports <- load_import_weights()
run_daily_series(snapshot_dir = dir, rev_dates = rd, policy_params = pp, imports = imports)
' 2>&1 | grep -vE "Rows:|Columns:|Delimiter|^chr |^dbl |^date|cli::|^── Column|TPC valid"

echo; echo "=== 2. Statute invariants ==="
Rscript tests/test_timeline_invariants.R || echo "(invariants non-zero)"
echo; echo "=== 3. Impact report ==="
Rscript scripts/report_timeline_split_impact.R --new output/actual/daily || echo "(impact non-zero)"
echo; echo "=== 4. Weighted chart ==="
Rscript scripts/plot_timeline_split_compare.R --new output/actual/daily || echo "(chart non-zero)"
echo; echo "=== DONE $(date -Iseconds) ==="
