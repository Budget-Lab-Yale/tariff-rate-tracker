#!/bin/bash
#
# Re-run the daily series WEIGHTED from the existing snapshots (42 real + 3 bnd_),
# then regenerate the impact report + the old-golden-vs-new chart on the
# import-weighted ETR (the headline number where IEEPA dominates). No rebuild —
# weighting happens in the daily aggregation, the rate snapshots are unchanged.
#
# Usage: sbatch scripts/submit_weighted_daily_chart.sh

#SBATCH --job-name=weighted-daily
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --output=/home/%u/slurm-logs/weighted-daily-%j.out
#SBATCH --error=/home/%u/slurm-logs/weighted-daily-%j.err
#SBATCH --chdir=/nfs/roberts/project/pi_nrs36/jar335/Repositories/tariff-rate-tracker

set -uo pipefail
mkdir -p ~/slurm-logs

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh
else echo "ERROR: no Lmod init" >&2; exit 1; fi
module purge
module load R/4.4.2-gfbf-2024a

export TARIFF_DAILY_CORES=4

echo "=== Weighted daily series from existing snapshots (incl bnd_) ==="
Rscript -e '
suppressPackageStartupMessages({library(here);library(tidyverse)})
suppressMessages({
  source(here("src","00_build_timeseries.R"))
  source(here("src","revisions.R")); source(here("src","policy_params.R"))
  source(here("src","09_daily_series.R")); source(here("src","build_import_weights.R"))
})
dir <- here("data","timeseries")
pp <- load_policy_params(use_policy_dates = TRUE)
rd <- load_revision_dates(use_policy_dates = TRUE)
# Reconstruct the full grid: real revs (CSV, policy) + the minted bnd_ rows (date
# parsed from the snapshot id) — exactly what the gather assembled post-mint.
bnd <- sub("^snapshot_(bnd_.*)\\.rds$","\\1", list.files(dir, "^snapshot_bnd_.*\\.rds$"))
if (length(bnd)) rd <- bind_rows(rd, tibble(revision = bnd, effective_date = as.Date(sub("^bnd_","",bnd))))
cat("grid:", nrow(rd), "revisions (", length(bnd), "minted )\n")
imports <- load_import_weights()              # weighted
run_daily_series(snapshot_dir = dir, rev_dates = rd, policy_params = pp, imports = imports)
' 2>&1 | grep -vE "Rows:|Columns:|Delimiter|^chr |^dbl |^date|cli::|^── Column"

echo; echo "=== Impact report (weighted output) ==="
Rscript scripts/report_timeline_split_impact.R --new output/actual/daily || echo "(impact non-zero)"

echo; echo "=== Chart (weighted ETR: old golden vs new) ==="
Rscript scripts/plot_timeline_split_compare.R --new output/actual/daily || echo "(chart non-zero)"

echo; echo "=== DONE $(date -Iseconds) ==="
ls -la output/timeline_split_impact/daily_rate_old_vs_new.png
