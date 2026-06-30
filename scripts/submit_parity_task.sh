#!/bin/bash
#
# One parity-array task: compare a single file pair from the manifest.
#
# Launched by scripts/submit_plank3_parity.sh as a Slurm array (one task per
# manifest row). Each task runs run_parity_task.R for its 0-based array index
# and writes output/<results-dir>/task_<index>.tsv; the summary job
# (submit_parity_summary.sh) reduces those into one gate result.
#
# Expects (exported by the orchestrator):
#   PARITY_MANIFEST      path to the manifest TSV (build_parity_manifest.R)
#   PARITY_RESULTS_DIR   directory for per-task result TSVs
#
# Not meant to be submitted directly — use submit_plank3_parity.sh.

#SBATCH --job-name=parity-task
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=24G
#SBATCH --output=/home/%u/slurm-logs/parity-task-%A_%a.out
#SBATCH --error=/home/%u/slurm-logs/parity-task-%A_%a.err
# (no --chdir: submit from the repo root; sbatch uses the submission dir)

set -uo pipefail
mkdir -p ~/slurm-logs

export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh
else echo "ERROR: no Lmod init script found" >&2; exit 1; fi
module purge
module load R/4.4.2-gfbf-2024a

: "${PARITY_MANIFEST:?PARITY_MANIFEST must be exported by the orchestrator}"
: "${PARITY_RESULTS_DIR:?PARITY_RESULTS_DIR must be exported by the orchestrator}"
INDEX="${SLURM_ARRAY_TASK_ID:?this script must run as a Slurm array task}"

echo "parity task: index=$INDEX manifest=$PARITY_MANIFEST results=$PARITY_RESULTS_DIR"
Rscript scripts/run_parity_task.R \
  --manifest "$PARITY_MANIFEST" \
  --index "$INDEX" \
  --results-dir "$PARITY_RESULTS_DIR"
