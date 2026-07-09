#!/bin/bash
#
# Build no_232 counterfactual snapshots for the annex-era revisions that the
# §232 annex route calibration needs (T_exit branch: what each cell owes if
# the article legally exits §232 via 9903.82.01/.03 — all other authorities
# apply full-value; see docs/s232/annex_exemption_route_calibration_proposal.md
# §3 and tools/calibrate_s232_annex_routes.R).
#
# Usage:
#   sbatch scripts/submit_no232_annex_snapshots.sh [rev ...]
#     default revs: 2026_rev_5 2026_rev_6 2026_rev_7 2026_rev_9
#     (April 2026 = rev_5/6/7 windows; May 2026 = rev_9, valid to Jun 7)
#
# Output: data/timeseries/no_232/snapshot_<rev>.rds (one full unweighted
# product x country snapshot per revision, built via TARIFF_SCENARIO=no_232 —
# rebuild_one_revision.R picks the scenario up through load_policy_params()).
#
# Resource sizing: each revision is one ~4.7M-row grid; 64G is comfortable
# (the 192G full-build number is driven by combine-snapshots, not one grid).

#SBATCH --job-name=no232-annex-snaps
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH --output=/home/%u/slurm-logs/no232-annex-snaps-%j.out
#SBATCH --error=/home/%u/slurm-logs/no232-annex-snaps-%j.err
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

REVS=("$@")
if [ ${#REVS[@]} -eq 0 ]; then
  REVS=(2026_rev_5 2026_rev_6 2026_rev_7 2026_rev_9)
fi

OUT_DIR=data/timeseries/no_232
mkdir -p "$OUT_DIR"

fail=0
for rev in "${REVS[@]}"; do
  echo "=== [$(date +%T)] no_232 rebuild: $rev ==="
  if ! TARIFF_SCENARIO=no_232 Rscript scripts/rebuild_one_revision.R "$rev" "$OUT_DIR"; then
    echo "FAILED: $rev" >&2
    fail=1
  fi
done

echo "=== [$(date +%T)] done (fail=$fail); contents of $OUT_DIR ==="
ls -la "$OUT_DIR"
exit $fail
