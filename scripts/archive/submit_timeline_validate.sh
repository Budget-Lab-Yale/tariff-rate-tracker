#!/bin/bash
#
# Post-build validation for the unified-timeline boundary mints (Pass-2 / P2-1).
# Runs on Slurm (snapshots are ~1.3 GB each in RAM — too big for the login alloc).
#   1. diff-vs-owner: what each bnd_ mint actually changes vs its owner snapshot
#   2. statute invariants (tests/test_timeline_invariants.R)
#   3. impact report (scripts/report_timeline_split_impact.R)
#   4. old-golden-vs-new daily rate chart (scripts/plot_timeline_split_compare.R)
# Does NOT abort on a failing step (set +e) — every artifact is produced.
#
# Usage: sbatch scripts/submit_timeline_validate.sh

#SBATCH --job-name=timeline-validate
#SBATCH --time=00:25:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=24G
#SBATCH --output=/home/%u/slurm-logs/timeline-validate-%j.out
#SBATCH --error=/home/%u/slurm-logs/timeline-validate-%j.err
#SBATCH --chdir=/nfs/roberts/project/pi_nrs36/jar335/Repositories/tariff-rate-tracker

set -uo pipefail
mkdir -p ~/slurm-logs

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh
else echo "ERROR: no Lmod init" >&2; exit 1; fi
module purge
module load R/4.4.2-gfbf-2024a

echo "=== 1. DIFF vs OWNER: what each bnd_ mint changes ==="
Rscript -e '
suppressPackageStartupMessages({library(here);library(dplyr)})
dir <- here("data","timeseries")
pairs <- list(c("bnd_2025-03-12","rev_4"), c("bnd_2026-02-20","2026_rev_3"), c("bnd_2026-11-10","2026_rev_9"))
ratecols <- c("rate_232","rate_301","rate_301_cs","rate_ieepa_recip","rate_ieepa_fent","rate_s122","rate_section_201","rate_other","total_rate")
for (p in pairs) {
  b <- readRDS(file.path(dir,paste0("snapshot_",p[1],".rds")))
  o <- readRDS(file.path(dir,paste0("snapshot_",p[2],".rds")))
  cat("\n==", p[1], "vs owner", p[2], "== bnd rows:", nrow(b), " owner rows:", nrow(o), "\n")
  j <- dplyr::full_join(
    o |> dplyr::select(hts10,country,dplyr::all_of(ratecols)) |> dplyr::rename_with(~paste0(.,"_o"), dplyr::all_of(ratecols)),
    b |> dplyr::select(hts10,country,dplyr::all_of(ratecols)) |> dplyr::rename_with(~paste0(.,"_b"), dplyr::all_of(ratecols)),
    by=c("hts10","country"))
  any_changed <- FALSE
  for (rc in ratecols) {
    ov <- j[[paste0(rc,"_o")]]; bv <- j[[paste0(rc,"_b")]]
    ov[is.na(ov)] <- 0; bv[is.na(bv)] <- 0
    nd <- sum(abs(bv-ov) > 1e-9)
    if (nd>0) { any_changed<-TRUE; cat(sprintf("   %-18s rows changed: %d  (owner mean %.4f -> bnd mean %.4f)\n", rc, nd, mean(ov), mean(bv))) }
  }
  if (!any_changed) cat("   >>> NO CHANGE vs owner — this mint is INERT <<<\n")
}'

echo; echo "=== 2. STATUTE INVARIANTS ==="
Rscript tests/test_timeline_invariants.R || echo "(invariants exited non-zero — see above)"

echo; echo "=== 3. IMPACT REPORT ==="
Rscript scripts/report_timeline_split_impact.R || echo "(impact report exited non-zero)"

echo; echo "=== 4. CHART (old golden vs new) ==="
Rscript scripts/plot_timeline_split_compare.R || echo "(chart exited non-zero)"

echo; echo "=== DONE $(date -Iseconds) ==="
