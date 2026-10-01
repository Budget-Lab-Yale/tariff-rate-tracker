#!/bin/bash
#
# M0 step 2: prove the rev_13 Chapter 99 endnote deletion moves no computed
# China Section 301 rate.
#
# Usage:
#   sbatch scripts/submit_m0_s301_parity.sh
#
# What it runs:
#   1. Rscript scripts/rebuild_one_revision.R 2026_rev_12   (snapshot -> scratch)
#   2. Rscript scripts/rebuild_one_revision.R 2026_rev_13
#   3. Rscript scripts/verify_m0_s301_parity.R              (gate; nonzero on any diff)
#
# Background: rev_13 dropped the "See 9903.88.15."-style cross-reference
# endnotes (9903.88.* fell 10,319 -> 5 across ch1-97 footnotes). M0 step 3
# established that as a real upstream removal rather than an export defect, so
# the archives are complete; step 2 is whether any rate moved. See
# config/footnote_waivers.csv and docs/proposed_mod_combined_2026_08_07.md §0.2.
#
# Resource sizing:
#   - Mem 32G: MEASURED — job 21669551 (2026-08-07) peaked at MaxRSS 10.5G for
#     both rebuilds plus the verify, having been over-requested at 128G. A
#     single-revision rebuild does OOM in a 5G interactive session (exit 137),
#     so this cannot run locally; 32G leaves ~3x headroom over the measurement.
#   - Walltime 30m: MEASURED — the same job ran both rebuilds and the verify in
#     6m31s.
#   - CPUs 4: build is single-threaded R; 4 covers BLAS/Arrow/OS overhead.

#SBATCH --job-name=tariff-m0-s301-parity
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --output=/home/%u/slurm-logs/tariff-m0-s301-parity-%j.out
#SBATCH --error=/home/%u/slurm-logs/tariff-m0-s301-parity-%j.err
# (no #SBATCH --chdir: submit from the repo root — sbatch uses the submission dir)

set -uo pipefail

module load R/4.4.2-gfbf-2024a

# Build is single-threaded R; keep BLAS/OpenMP from oversubscribing the 4 CPUs.
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

echo "=== M0 step 2 parity — job ${SLURM_JOB_ID:-local} ==="
echo "Repo: $(pwd)"
echo "Started: $(date)"

for rev in 2026_rev_12 2026_rev_13; do
  echo ""
  echo "--- Rebuilding ${rev} ---"
  Rscript scripts/rebuild_one_revision.R "${rev}"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAILED: rebuild of ${rev} exited ${rc}"
    exit $rc
  fi
done

echo ""
echo "--- Verifying §301 parity ---"
Rscript scripts/verify_m0_s301_parity.R
verify_rc=$?

echo ""
echo "Finished: $(date)"
echo "=== Accounting (record MaxRSS in this script's sizing note) ==="
sacct -j "${SLURM_JOB_ID:-0}" --format=JobID,JobName%28,State,Elapsed,MaxRSS,ReqMem 2>/dev/null

if [ $verify_rc -ne 0 ]; then
  echo "RESULT: FAILED — §301 rates moved across the ingest (see diffs above)"
  exit $verify_rc
fi
echo "RESULT: PASSED — no China §301 rate moved across the rev_12 -> rev_13 ingest"
