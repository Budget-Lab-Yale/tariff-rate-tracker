#!/bin/bash
#
# Submit the pre-2025 (Phase 1) raw-archive acquisition as a single Slurm job.
#
# Usage:
#   sbatch scripts/submit_pre2025_acquisition.sh              # full sweep
#   sbatch scripts/submit_pre2025_acquisition.sh --dry-run    # enumerate only
#
# Steps (each is independently re-runnable and idempotent — already-verified
# artifacts are skipped via the store manifest):
#   1. tools/pre2025_fetch_hts_json.R      HTS JSON editions 2016-2024 (Wayback)
#   2. tools/pre2025_fetch_annual_db.R     Annual Tariff DB zips 2015-2026 (Wayback)
#   3. tools/pre2025_fetch_chapter99.R     Chapter 99 PDFs for JSON gaps + all
#                                          Change Records (hts.usitc.gov direct)
#   4. tools/pre2025_build_inventory.R     resources/pre2025_hts_inventory.csv
#
# Why Slurm and not the login shell: interactive sessions are capped at 5 GB and
# this parses ~110 HTS JSON editions (~13 MB raw each) plus ~1.5 GB of downloads.
# It is network-bound and deliberately throttled (~1.5 s between requests, with
# exponential backoff), so wall time dominates — budget 4 h.
#
# Artifacts land in the SHARED store, not the repo:
#   /nfs/roberts/project/pi_nrs36/shared/raw_data/USITC-HTS-Archive
# (override with HTS_ARCHIVE_STORE_DIR).

#SBATCH --job-name=pre2025-acquire
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --output=/home/%u/slurm-logs/pre2025-acquire-%j.out
#SBATCH --error=/home/%u/slurm-logs/pre2025-acquire-%j.err
# (no #SBATCH --chdir: submit from the repo root — sbatch uses the submission dir)

set -uo pipefail

mkdir -p ~/slurm-logs

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

EXTRA_ARGS="$@"

echo "=========================================================="
echo "Job:    ${SLURM_JOB_ID:-none} on $(hostname)"
echo "Start:  $(date -Iseconds)"
echo "Store:  ${HTS_ARCHIVE_STORE_DIR:-/nfs/roberts/project/pi_nrs36/shared/raw_data/USITC-HTS-Archive}"
echo "Args:   ${EXTRA_ARGS}"
echo "=========================================================="

RC=0

echo ">>> STEP 1: HTS JSON editions 2016-2024 (Wayback)"
Rscript tools/pre2025_fetch_hts_json.R ${EXTRA_ARGS} || RC=$?
echo ">>> step 1 exit: $RC"

echo ">>> STEP 2: Annual Tariff Database zips 2015-2026 (Wayback)"
Rscript tools/pre2025_fetch_annual_db.R ${EXTRA_ARGS} || RC=$?
echo ">>> step 2 exit: $RC"

echo ">>> STEP 3: Chapter 99 PDFs + Change Records (hts.usitc.gov)"
Rscript tools/pre2025_fetch_chapter99.R ${EXTRA_ARGS} || RC=$?
echo ">>> step 3 exit: $RC"

if [[ "${EXTRA_ARGS}" == *"--dry-run"* ]]; then
  echo ">>> STEP 4: skipped (--dry-run would rewrite the inventory from an unfetched store)"
else
  echo ">>> STEP 4: inventory CSV"
  Rscript tools/pre2025_build_inventory.R || RC=$?
  echo ">>> step 4 exit: $RC"
fi

echo "=========================================================="
echo "End:    $(date -Iseconds)   rc=$RC"
echo "=========================================================="
exit $RC
