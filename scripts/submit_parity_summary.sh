#!/bin/bash
#
# Parity-array reducer: collapse the per-task result TSVs into one gate result.
#
# Launched by scripts/submit_plank3_parity.sh with a dependency on the parity
# task array (afterany), so it runs once every per-file comparison has written
# its output/<results-dir>/task_*.tsv. Exits non-zero if any task drifted.
#
# Expects (exported by the orchestrator):
#   PARITY_MANIFEST      path to the manifest TSV
#   PARITY_RESULTS_DIR   directory holding the per-task result TSVs
#   PARITY_REFERENCE     reference build root (for the summary header)
#
# Not meant to be submitted directly — use submit_plank3_parity.sh.

#SBATCH --job-name=parity-summary
#SBATCH --time=00:15:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --output=/home/%u/slurm-logs/parity-summary-%j.out
#SBATCH --error=/home/%u/slurm-logs/parity-summary-%j.err
# (no --chdir: submit from the repo root; sbatch uses the submission dir)

set -uo pipefail
mkdir -p ~/slurm-logs

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh
else echo "ERROR: no Lmod init script found" >&2; exit 1; fi
module purge
module load R/4.4.2-gfbf-2024a

: "${PARITY_MANIFEST:?PARITY_MANIFEST must be exported by the orchestrator}"
: "${PARITY_RESULTS_DIR:?PARITY_RESULTS_DIR must be exported by the orchestrator}"

REF_ARGS=()
if [ -n "${PARITY_REFERENCE:-}" ]; then REF_ARGS=(--reference "$PARITY_REFERENCE"); fi

echo "parity summary: manifest=$PARITY_MANIFEST results=$PARITY_RESULTS_DIR ref=${PARITY_REFERENCE:-<default>}"
Rscript scripts/summarize_parity_results.R \
  --manifest "$PARITY_MANIFEST" \
  --results-dir "$PARITY_RESULTS_DIR" \
  "${REF_ARGS[@]}"
