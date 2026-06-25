#!/bin/bash
#
# Plank 0 unit gate: the compositional rate schema (src/model/authority_spec.R).
#
# Usage:
#   sbatch scripts/submit_resolve_rate_tests.sh
#
# Runs three pure-logic test files (no build data needed):
#   1. tests/test_resolve_rate.R      — the new reader/semantics/validation tests
#   2. tests/test_authority_spec.R    — existing spec tests still pass (validate_rate
#                                       is now called from validate_authority_spec)
#   3. tests/test_authority_adapter.R — builds the REAL spec set from synthetic raw
#                                       objects and runs validate_spec_set → proves
#                                       validate_rate tolerates the live HOLLOW rate
#                                       fields (from_raw / from_list / ...) end-to-end
# Exit non-zero if any file fails.

#SBATCH --job-name=theseus-plank0
#SBATCH --time=00:10:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/home/%u/slurm-logs/theseus-plank0-%j.out
#SBATCH --error=/home/%u/slurm-logs/theseus-plank0-%j.err
# (no --chdir: submit from the repo root — sbatch uses the submission dir)

set -uo pipefail

mkdir -p ~/slurm-logs

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
echo "Job:    ${SLURM_JOB_ID:-local} on $(hostname)"
echo "Start:  $(date -Iseconds)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD)  Commit: $(git rev-parse --short HEAD)"
echo "=========================================================="

RC=0
for t in test_resolve_rate.R test_authority_spec.R test_authority_adapter.R; do
  echo
  echo "================== tests/$t =================="
  if Rscript "tests/$t"; then
    echo ">>> PASS: tests/$t"
  else
    echo ">>> FAIL: tests/$t"
    RC=1
  fi
done

echo
echo "=========================================================="
echo "End:    $(date -Iseconds)"
echo "Overall: $([ "$RC" -eq 0 ] && echo PASS || echo FAIL)"
echo "=========================================================="
exit $RC
