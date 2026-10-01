#!/bin/bash
#
# Slurm ARRAY task: build one revision's snapshot. One array index -> one
# revision (line index+1 of $REVLIST). Tasks are independent and run
# concurrently across nodes, each with its own memory allocation — this is the
# parallelism that replaces the serial 41-revision loop.
#
# Submitted by scripts/submit_build_array.sh (which sizes --array and exports
# REVLIST). Not meant to be sbatch'd directly.
#
# Per-task sizing: MEASURED MaxRSS 43.0 GB at 60 revisions (vintage 2026-08-31-12,
# job 24307185, peak on task _45); 64 GB gives headroom and lets Slurm pack a few
# tasks per 192 GB node or spread across nodes. The peak tracks the size of the
# heaviest SINGLE revision, not the revision count, so adding revisions does not
# move it -- but a fatter revision would. Re-measure with:
#   sacct -j <arrayjob> --format=JobID,MaxRSS -n -P | grep batch

#SBATCH --job-name=tariff-rev
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=64G
#SBATCH --output=/home/%u/slurm-logs/tariff-rev-%A_%a.out
#SBATCH --error=/home/%u/slurm-logs/tariff-rev-%A_%a.err
# (no #SBATCH --chdir: the orchestrator passes --chdir=$REPO explicitly)

set -euo pipefail
mkdir -p ~/slurm-logs output/logs

export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then
  source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then
  source /etc/profile.d/lmod.sh
fi
module purge
module load R/4.4.2-gfbf-2024a

REVLIST="${REVLIST:-output/build_array_revisions.txt}"
if [ ! -f "$REVLIST" ]; then
  echo "ERROR: revision list not found: $REVLIST" >&2
  exit 1
fi
REV_TIMELINE="${REV_TIMELINE:-output/build_array_timeline.rds}"
if [ ! -f "$REV_TIMELINE" ]; then
  echo "ERROR: revision timeline not found: $REV_TIMELINE" >&2
  exit 1
fi

# Array index is 0-based; revision list lines are 1-based.
REV=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$REVLIST")
if [ -z "${REV:-}" ]; then
  echo "No revision for array task ${SLURM_ARRAY_TASK_ID} (list has $(grep -c . "$REVLIST") entries) — nothing to do."
  exit 0
fi

echo "=========================================================="
echo "Array task ${SLURM_ARRAY_TASK_ID} -> revision ${REV} on $(hostname)"
echo "Start: $(date -Iseconds) | Mem: ${SLURM_MEM_PER_NODE:-?} MB"
echo "=========================================================="

REV_TIMELINE="$REV_TIMELINE" Rscript scripts/build_revision.R "$REV" ${USE_HTS_DATES:+--use-hts-dates} ${BUILD_REVISION_ARGS:-}
RC=$?

echo "Task ${SLURM_ARRAY_TASK_ID} (${REV}) exit: $RC at $(date -Iseconds)"
exit $RC
