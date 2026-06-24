#!/bin/bash
#
# Plank 3 parity gate: node-parallel compare of the rebuilt snapshots + daily
# artifacts against the frozen golden (tests/golden/9f9837d).
#
# This uses a Slurm array:
#   1. build a manifest of shared parity file pairs
#   2. launch one parity compare per file pair on its own task/node
#   3. reduce the task outputs to one gate result
#
# Usage:
#   REFERENCE=tests/golden/9f9837d sbatch scripts/submit_plank3_parity.sh

set -euo pipefail
# Run from the repo root (the sbatch submission directory); no hardcoded path.

REFERENCE="${REFERENCE:-tests/golden/9f9837d}"
ARTIFACTS="${ARTIFACTS:-snapshot,daily_overall,daily_by_authority,daily_by_country,daily_by_category}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
MANIFEST="output/parity_manifest_${RUN_ID}.tsv"
RESULTS_DIR="output/parity_results_${RUN_ID}"
mkdir -p output "$RESULTS_DIR"

echo "--- Building parity manifest ---"
source /etc/profile.d/z01_lmodinit.sh 2>/dev/null || true
module load R/4.4.2-gfbf-2024a
Rscript scripts/build_parity_manifest.R \
  --reference "$REFERENCE" \
  --artifacts "$ARTIFACTS" \
  --manifest "$MANIFEST"

N=$(tail -n +2 "$MANIFEST" | grep -c . || true)
if [ "$N" -lt 1 ]; then
  echo "ERROR: no shared parity files found in $MANIFEST" >&2
  exit 1
fi
echo "Parity tasks: $N"
echo "  manifest: $MANIFEST"
echo "  results:  $RESULTS_DIR"

echo "--- Submitting node-parallel parity array ---"
ARRAY_JOB=$(sbatch --parsable \
  --array=0-$((N - 1)) \
  --export=ALL,PARITY_MANIFEST="$MANIFEST",PARITY_RESULTS_DIR="$RESULTS_DIR" \
  scripts/submit_parity_task.sh)
echo "Array job: $ARRAY_JOB"

echo "--- Submitting parity summary (afterany:$ARRAY_JOB) ---"
SUMMARY_JOB=$(sbatch --parsable \
  --dependency=afterany:"$ARRAY_JOB" \
  --export=ALL,PARITY_MANIFEST="$MANIFEST",PARITY_RESULTS_DIR="$RESULTS_DIR",PARITY_REFERENCE="$REFERENCE" \
  scripts/submit_parity_summary.sh)
echo "Summary job: $SUMMARY_JOB"

echo
echo "Watch:    squeue -j $ARRAY_JOB,$SUMMARY_JOB"
echo "Inspect:  output/parity_results_${RUN_ID}/task_*.tsv"
