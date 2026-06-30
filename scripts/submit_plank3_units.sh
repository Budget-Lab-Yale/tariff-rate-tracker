#!/bin/bash
#
# Plank 3 unit gate: Section 122 de-blobbed into the compositional rate$default layer.
#
# Usage:
#   sbatch scripts/submit_plank3_units.sh
#
# Pure-logic tests (no build data). Plank 3 moves the s122 blanket rate out of the
# opaque rate$resolved blob into rate$default; the calc reads it via resolve_rate()
# (value>0 = the has_s122 gate), and scenario_ops set_rate/disable mutate that
# scalar. The parity rebuild (build array + run_parity_check) is the separate gate
# that confirms the calc change is bit-identical to tests/golden/9f9837d.
#   1. tests/test_authority_spec.R    — resolve_rate / validate_rate on the default layer
#   2. tests/test_authority_adapter.R — adapter structures s122 into rate$default end-to-end
# (The scenario_ops verb test was removed with the verb API in 54cc662.)
# Exit non-zero if any file fails.

#SBATCH --job-name=theseus-plank3u
#SBATCH --time=00:10:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/home/%u/slurm-logs/theseus-plank3u-%j.out
#SBATCH --error=/home/%u/slurm-logs/theseus-plank3u-%j.err
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
for t in test_authority_spec.R test_authority_adapter.R; do
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
