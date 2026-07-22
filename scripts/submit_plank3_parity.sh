#!/bin/bash
#
# Node-parallel parity gate for two published model_data series.
#
# Every work artifact (manifest + per-task results) also lives under the
# external model_data interface. Repository-local builds and legacy golden
# layouts are intentionally unsupported.
#
# Usage:
#   bash scripts/submit_plank3_parity.sh \
#     /.../model_data/Tariff-Rate-Tracker/<reference-vintage> \
#     /.../model_data/Tariff-Rate-Tracker/<candidate-vintage> \
#     /.../model_data/Tariff-Rate-Tracker/.validation/parity \
#     <run-id>
#
# REFERENCE/CANDIDATE may instead name one published series directory, such as
# <vintage>/scenarios/new_301.

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <reference> <candidate> <external-work-root> <run-id>" >&2
  exit 2
fi

REFERENCE="$1"
CANDIDATE="$2"
PARITY_WORK_ROOT="$3"
RUN_ID="$4"

ARTIFACTS="${ARTIFACTS:-snapshot,daily_overall,daily_by_authority,daily_by_country,daily_by_category,daily_by_hs}"
PARITY_CONCURRENCY="${PARITY_CONCURRENCY:-8}"
REPO="$(pwd -P)"
WORK_DIR="$(readlink -m "$PARITY_WORK_ROOT/$RUN_ID")"
case "$WORK_DIR/" in
  "$REPO"/*) echo "REFUSING: parity work directory is inside the repository: $WORK_DIR" >&2; exit 1 ;;
esac

MANIFEST="$WORK_DIR/manifest.tsv"
RESULTS_DIR="$WORK_DIR/results"
mkdir -p "$RESULTS_DIR"

echo "--- Building model_data parity manifest ---"
source /etc/profile.d/z01_lmodinit.sh 2>/dev/null || true
module load R/4.4.2-gfbf-2024a
Rscript scripts/build_parity_manifest.R \
  --reference "$REFERENCE" \
  --candidate "$CANDIDATE" \
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
  --array=0-$((N - 1))%"$PARITY_CONCURRENCY" \
  --export=ALL,PARITY_MANIFEST="$MANIFEST",PARITY_RESULTS_DIR="$RESULTS_DIR" \
  scripts/submit_parity_task.sh)
echo "Array job: $ARRAY_JOB"

echo "--- Submitting parity summary (afterany:$ARRAY_JOB) ---"
SUMMARY_JOB=$(sbatch --parsable \
  --dependency=afterany:"$ARRAY_JOB" \
  --export=ALL,PARITY_MANIFEST="$MANIFEST",PARITY_RESULTS_DIR="$RESULTS_DIR",PARITY_REFERENCE="$REFERENCE",PARITY_CANDIDATE="$CANDIDATE" \
  scripts/submit_parity_summary.sh)
echo "Summary job: $SUMMARY_JOB"

echo
echo "Watch:    squeue -j $ARRAY_JOB,$SUMMARY_JOB"
echo "Inspect:  $RESULTS_DIR/task_*.tsv"
