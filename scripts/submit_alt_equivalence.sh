#!/bin/bash
#
# Phase 1 acceptance gate: serial vs --parallel --alt-workers 2 output equivalence.
#
# Usage:
#   sbatch scripts/submit_alt_equivalence.sh
#
# What it runs:
#   1. Snapshot the existing output/alternative/ tree as the "serial baseline".
#      The 4 USMCA rebuild alternatives on disk (timestamps 11:49-15:19 on
#      2026-05-09) were produced by the pre-Phase-1 inline run_alternative_series().
#      The pp_override construction is identical to build_rebuild_alt_registry(),
#      so they form a valid byte-comparable baseline.
#   2. Run --alternatives-only --parallel --alt-workers 2. This dispatches all 6
#      rebuild alts (4 USMCA + metal_flat + dutyfree_nonzero) across 2 concurrent
#      future::multisession workers, writing fresh outputs to output/alternative/.
#   3. Diff all 6 rebuild alts' daily/by_authority/by_country CSVs against the
#      baseline.
#
# Walltime sizing:
#   6 alts / 2 workers = 3 batches * ~85 min/batch ~= 4.5 h. Add ~30 min for
#   the snapshot-and-diff stages. 6 h walltime gives modest headroom.
#
# Memory sizing:
#   2 concurrent alt workers * ~40 GB peak = ~80 GB working set + overhead.
#   192 GB matches the production allocation and is conservative.
#
# Phase 1 acceptance:
#   - Serial-baseline diff is empty for all 6 rebuild alts.
#   - One injected alt failure (if we ever add one) is isolated, not fatal.
#
# Log locations:
#   ~/slurm-logs/tariff-alt-eq-<jobid>.{out,err}     (Rscript stdout/stderr)
#   output/logs/alternatives/alt_<variant>.log      (per-alt subprocess logs)

#SBATCH --job-name=tariff-alt-eq
#SBATCH --time=06:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=192G
#SBATCH --output=/home/%u/slurm-logs/tariff-alt-eq-%j.out
#SBATCH --error=/home/%u/slurm-logs/tariff-alt-eq-%j.err
#SBATCH --chdir=/nfs/roberts/project/pi_nrs36/ji252/repos/tariff-rate-tracker

set -euo pipefail

mkdir -p output/logs ~/slurm-logs

# Top-level R is single-threaded; alt workers each pin their own BLAS/OMP
# threads to 1 (see src/core/parallel.R:.alt_runner_parallel).
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then
  source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then
  source /etc/profile.d/lmod.sh
else
  echo "ERROR: no Lmod init script found in /etc/profile.d/" >&2
  exit 1
fi
module purge
module load R/4.4.2-gfbf-2024a

echo "=========================================================="
echo "Job:    $SLURM_JOB_ID on $(hostname)"
echo "Start:  $(date -Iseconds)"
echo "CPUs:   ${SLURM_CPUS_PER_TASK}"
echo "Mem:    ${SLURM_MEM_PER_NODE:-?} MB"
echo "Commit: $(git rev-parse HEAD)"
echo "=========================================================="

BASELINE_DIR="output/alternative_serial_baseline"
PARALLEL_DIR="output/alternative_parallel_run"
DIFF_REPORT="output/alternative_eq_diff_${SLURM_JOB_ID}.txt"

# ---- Step 1: snapshot existing outputs as the serial baseline ----
echo
echo "--- Step 1: snapshotting serial baseline ---"
if [ -d "$BASELINE_DIR" ]; then
  echo "Baseline already snapshotted at $BASELINE_DIR (keeping it)"
else
  cp -a output/scenarios "$BASELINE_DIR"
  echo "Baseline -> $BASELINE_DIR"
fi
ls "$BASELINE_DIR" | wc -l | xargs -I {} echo "Baseline file count: {}"

# ---- Step 2: run --alternatives-only with --parallel --alt-workers 2 ----
echo
echo "--- Step 2: running --alternatives-only --parallel --alt-workers 2 ---"
RC=0
Rscript src/pipeline/00_build_timeseries.R \
  --alternatives-only \
  --parallel \
  --alt-workers 2 || RC=$?

echo "Build exit: $RC"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: build returned non-zero; not running diff."
  exit "$RC"
fi

# Snapshot the parallel-run outputs alongside the baseline so a future job
# can reproduce the comparison without re-running the 5h workload.
rm -rf "$PARALLEL_DIR"
cp -a output/scenarios "$PARALLEL_DIR"
echo "Parallel run -> $PARALLEL_DIR"

# ---- Step 3: diff all 6 rebuild alts against baseline ----
echo
echo "--- Step 3: diffing 6 rebuild alts against baseline ---" | tee "$DIFF_REPORT"
DIFF_RC=0
for variant in usmca_annual usmca_monthly usmca_2024 usmca_dec2025 metal_flat dutyfree_nonzero; do
  for kind in daily_overall by_authority by_country; do
    f="${variant}/${kind}.csv"
    if [ ! -f "$BASELINE_DIR/$f" ] || [ ! -f "$PARALLEL_DIR/$f" ]; then
      echo "  MISSING: $f (baseline=$([ -f $BASELINE_DIR/$f ] && echo yes || echo no), parallel=$([ -f $PARALLEL_DIR/$f ] && echo yes || echo no))" \
        | tee -a "$DIFF_REPORT"
      DIFF_RC=1
      continue
    fi
    if cmp -s "$BASELINE_DIR/$f" "$PARALLEL_DIR/$f"; then
      echo "  OK:    $f (byte-identical)" | tee -a "$DIFF_REPORT"
    else
      echo "  DIFF:  $f" | tee -a "$DIFF_REPORT"
      diff -u "$BASELINE_DIR/$f" "$PARALLEL_DIR/$f" \
        | head -40 \
        | tee -a "$DIFF_REPORT"
      DIFF_RC=1
    fi
  done
done

echo
echo "=========================================================="
echo "End:    $(date -Iseconds)"
echo "Build:  $RC  Diff: $DIFF_RC"
echo "Report: $DIFF_REPORT"
echo "=========================================================="

exit $DIFF_RC
