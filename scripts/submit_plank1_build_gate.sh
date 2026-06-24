#!/bin/bash
#
# Plank 1 parity gate: full --core-only build on `theseus`, then compare the
# candidate panel + daily series against the frozen golden tests/golden/9f9837d
# (the native-format twin of the published 2026-06-04_2 vintage; same commit,
# config-md5 matches the manifest).
#
#   sbatch scripts/submit_plank1_build_gate.sh
#
# --core-only builds the rate panel + daily series (09) and SKIPS the weighted
# ETR (08) — which the parity harness intentionally does not gate. That is
# exactly the gated artifact set (snapshots + rate_timeseries + 4 daily CSVs).
#
# Green => Plank 1's spec-driven 301 reproduces the baseline within tolerance.

#SBATCH --job-name=theseus-p1-gate
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=192G
#SBATCH --output=/home/%u/slurm-logs/theseus-p1-gate-%j.out
#SBATCH --error=/home/%u/slurm-logs/theseus-p1-gate-%j.err
# (no --chdir: submit from the repo root — sbatch uses the submission dir)

set -uo pipefail
mkdir -p ~/slurm-logs output/logs

export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh
else echo "ERROR: no Lmod init script found" >&2; exit 1; fi
module purge
module load R/4.4.2-gfbf-2024a

echo "=========================================================="
echo "Job:    ${SLURM_JOB_ID:-local} on $(hostname)"
echo "Start:  $(date -Iseconds)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD)  Commit: $(git rev-parse --short HEAD)"
echo "=========================================================="

echo; echo "--- Step 0: clear stale snapshots to FORCE a fresh full rebuild ---"
# The golden is frozen in tests/golden/9f9837d, so deleting the working copies is
# safe. This guarantees every candidate snapshot is rebuilt with the Plank 1 code:
# a rebuild failure then shows up as a MISSING file in the gate, never a false green.
rm -f data/timeseries/snapshot_*.rds data/timeseries/rate_timeseries.rds
echo "remaining snapshots after clear: $(ls data/timeseries/snapshot_*.rds 2>/dev/null | wc -l)"

echo; echo "--- Step 1: --full --core-only build (recompute all 43 revisions) ---"
RC=0
Rscript src/00_build_timeseries.R --full --core-only || RC=$?
echo "Build exit: $RC"
if [ "$RC" -ne 0 ]; then echo "FAIL: build returned non-zero; skipping parity check."; exit "$RC"; fi
echo "snapshots rebuilt: $(ls data/timeseries/snapshot_*.rds 2>/dev/null | wc -l) (expect 43)"

REFERENCE="${REFERENCE:-tests/golden/9f9837d}"
echo; echo "--- Step 2: parity check vs ${REFERENCE} (skip monolithic timeseries to avoid OOM) ---"
# The 43 per-snapshot comparisons cover the SAME data as rate_timeseries.rds (its
# concatenation), one file at a time => memory-safe. timeseries omitted only to
# dodge the 2x1.38GB+join OOM; coverage is unchanged.
# Override the golden with: REFERENCE=<dir> sbatch scripts/submit_plank1_build_gate.sh
GATE=0
Rscript scripts/run_parity_check.R --golden "$REFERENCE" \
  --artifacts snapshot,daily_overall,daily_by_authority,daily_by_country,daily_by_category || GATE=$?

echo; echo "=========================================================="
echo "End:    $(date -Iseconds)"
echo "Build:  $RC   Parity gate: $([ "$GATE" -eq 0 ] && echo GREEN || echo RED)"
echo "=========================================================="
exit $GATE
