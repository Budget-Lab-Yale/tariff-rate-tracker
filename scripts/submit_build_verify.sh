#!/bin/bash
#
# Submit a full Tariff Rate Tracker build (no publish) + the rate-calculation
# test suite + Russia annex sanity checks, as a single reviewable Slurm job.
#
# Usage:
#   sbatch scripts/submit_build_verify.sh
#
# What it runs:
#   1. Rscript src/pipeline/00_build_timeseries.R --full          (rebuild all snapshots + downstream)
#   2. Rscript scripts/verify_build.R                    (shared verification gate:
#      rate-calculation test suite + Russia rev_5 + rev_10/Annex I-C + panel
#      NA-interval checks — see verify_build.R for the full expectation list)
#
# NOTE (2026-06-10, unification Phase 2): the sanity checks used to be inline
# here and informational-only (the job's exit code gated only on the test
# suite). They now live in scripts/verify_build.R and every check is a gate —
# a sanity regression fails this job.
#
# The validation profile: full rebuild of the timeseries + downstream
# daily/ETR/quality, no alternatives, no publish. (The shared-filer route is
# the array flow — see scripts/README.md.)
#
# Resource sizing (grows with the series — re-measure when revisions are added):
#   - Mem 384G: MEASURED MaxRSS 234G at 60 revisions / 292M rows (job 21784088,
#     2026-08-09). The previous 192G is NO LONGER ENOUGH — job 21739576 the same
#     day was OOM-killed at 201G, and note it died AFTER combine-snapshots
#     succeeded, in the downstream daily/ETR stage. The historical 96G
#     combine-snapshots OOM (job 11189086, 2026-05-08) is what set the old
#     figure; the binding constraint has since moved downstream. 384G is ~1.6x
#     the measurement, deliberate headroom because each added revision raises
#     the peak and an OOM costs a full ~3h run.
#   - Walltime 6h: MEASURED 3h15m for build + verify (same job). The prior 4h
#     would still fit but leaves little room as the series grows.
#   - CPUs 4: build is single-threaded R; 4 covers BLAS/Arrow/OS overhead.

#SBATCH --job-name=tariff-build-verify
#SBATCH --time=06:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=384G
#SBATCH --output=/home/%u/slurm-logs/tariff-build-verify-%j.out
#SBATCH --error=/home/%u/slurm-logs/tariff-build-verify-%j.err
# (no #SBATCH --chdir: submit from the repo root — sbatch uses the submission dir)

set -uo pipefail

mkdir -p output/logs ~/slurm-logs

export OPENBLAS_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export MKL_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

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
echo "CPUs:   ${SLURM_CPUS_PER_TASK}   Mem: ${SLURM_MEM_PER_NODE:-?} MB"
echo "R:      $(Rscript --version 2>&1)"
echo "=========================================================="

echo ">>> STEP 1: full rebuild (--full)"
BUILD_RC=0
Rscript src/pipeline/00_build_timeseries.R --full || BUILD_RC=$?
echo ">>> build exit: $BUILD_RC"

if [ "$BUILD_RC" -ne 0 ]; then
  echo "!!! Build failed (exit $BUILD_RC) — skipping tests/sanity. Check OOM / release gate."
  echo "End: $(date -Iseconds)"
  exit $BUILD_RC
fi

echo ">>> STEP 2: scripts/verify_build.R (test suite + sanity gates)"
VERIFY_RC=0
Rscript scripts/verify_build.R || VERIFY_RC=$?
echo ">>> verify exit: $VERIFY_RC"

echo "=========================================================="
echo "End:    $(date -Iseconds)   build=$BUILD_RC verify=$VERIFY_RC"
echo "=========================================================="
exit $VERIFY_RC
