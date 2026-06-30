#!/bin/bash
#
# Full serial build of the tariff rate timeseries (jar335 workspace).
#
# Used to capture the Phase-0 "serial golden" reference from clean code, and as
# the baseline the parallel (Slurm-array) build is validated against.
#
# Usage:
#   sbatch scripts/submit_build_full.sh              # default: --full
#   BUILD_ARGS="--full --build-only" sbatch scripts/submit_build_full.sh
#
# Logs:
#   ~/slurm-logs/tariff-build-full-<jobid>.{out,err}   (Rscript stdout/stderr)
#   output/logs/build_*.log                            (structured build log)

#SBATCH --job-name=tariff-build-full
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=192G
#SBATCH --output=/home/%u/slurm-logs/tariff-build-full-%j.out
#SBATCH --error=/home/%u/slurm-logs/tariff-build-full-%j.err
# (no #SBATCH --chdir: submit from the repo root — sbatch uses the submission dir)

set -euo pipefail

mkdir -p output/logs ~/slurm-logs

# Top-level R is single-threaded; pin BLAS/OMP so a serial build stays serial.
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
echo "Job:    ${SLURM_JOB_ID:-<none>} on $(hostname)"
echo "Start:  $(date -Iseconds)"
echo "CPUs:   ${SLURM_CPUS_PER_TASK:-?}"
echo "Mem:    ${SLURM_MEM_PER_NODE:-?} MB"
echo "Commit: $(git rev-parse HEAD 2>/dev/null || echo '?')"
echo "Args:   ${BUILD_ARGS:---full}"
echo "=========================================================="

Rscript src/pipeline/00_build_timeseries.R ${BUILD_ARGS:---full}
RC=$?

echo "=========================================================="
echo "End:    $(date -Iseconds)"
echo "Build exit: $RC"
echo "=========================================================="
exit $RC
