#!/bin/bash
#
# Plank 1 fast unit gate (pure-logic; no build data). Run BEFORE the expensive
# full build to catch regressions cheaply.
#
#   sbatch scripts/submit_plank1_units.sh
#
# Covers:
#   test_resolve_rate.R     — rate schema/reader/semantics (+ the `flat` allowed key)
#   test_authority_spec.R   — spec datatype + validate_rate
#   test_authority_adapter.R— adapter builds the real spec set (now with 301 by_product_tier)
#   test_stacking.R         — class-based stacking (301 additive)
#   test_rate_calculation.R — core rate engine on synthetic data (specs-less fallback path)

#SBATCH --job-name=theseus-p1-units
#SBATCH --time=00:20:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --output=/home/%u/slurm-logs/theseus-p1-units-%j.out
#SBATCH --error=/home/%u/slurm-logs/theseus-p1-units-%j.err
# (no --chdir: submit from the repo root — sbatch uses the submission dir)

set -uo pipefail
mkdir -p ~/slurm-logs

if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh
else echo "ERROR: no Lmod init script found" >&2; exit 1; fi
module purge
module load R/4.4.2-gfbf-2024a

echo "=========================================================="
echo "Job:    ${SLURM_JOB_ID:-local} on $(hostname)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD)  Commit: $(git rev-parse --short HEAD)"
echo "=========================================================="

RC=0
for t in test_resolve_rate.R test_authority_spec.R test_authority_adapter.R \
         test_stacking.R test_rate_calculation.R; do
  echo; echo "================== tests/$t =================="
  if Rscript "tests/$t"; then echo ">>> PASS: tests/$t"; else echo ">>> FAIL: tests/$t"; RC=1; fi
done

echo; echo "Overall: $([ "$RC" -eq 0 ] && echo PASS || echo FAIL)"
exit $RC
