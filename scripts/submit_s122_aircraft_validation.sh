#!/bin/bash
#
# Hook-on/off validation for the §122 civil-aircraft utilization fix
# (docs/s122_aircraft_exemption_audit.md). Builds 2026_rev_9 twice —
#   BASE  = worktree at HEAD 5736b8d (pre-fix: s122 CSV has no condition
#           column, no utilization file -> legacy FULL-LINE aircraft exemption)
#   FIXED = the main working tree (condition split + GN6 utilization scaling)
# — and diffs every rate column. The trees differ ONLY by the s122 fix, so the
# diff isolates it.
#
# EXPECTED: changes confined to rate_s122 (and downstream statutory_rate_s122 /
# total_rate via stacking) on note-2(aa)(iv) civil-aircraft HTS8 lines, ALL
# countries, rate_s122 rising 0 -> s122_rate*(1-share). ch88 aircraft barely
# move (share ~1); ch85/90/39 move most. NO change on non-aircraft lines and
# NO change to rate_232/301/ieepa. Any change outside rate_s122/statutory_s122/
# total_* channels, or on a non-(aa)(iv) hts8, = FAIL.
#
# Usage: sbatch scripts/submit_s122_aircraft_validation.sh <base_worktree_path>

#SBATCH --job-name=s122-air-validate
#SBATCH --time=01:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=96G
#SBATCH --output=/home/%u/slurm-logs/s122-air-validate-%j.out
#SBATCH --error=/home/%u/slurm-logs/s122-air-validate-%j.err

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
  echo "ERROR: no Lmod init script found" >&2; exit 1
fi
module purge
module load R/4.4.2-gfbf-2024a

BASE_WT="${1:?usage: sbatch submit_s122_aircraft_validation.sh <base_worktree_path>}"
MAIN=$(pwd)
FIXED_OUT="$MAIN/data/timeseries/s122_validation_fixed"
BASE_OUT="$BASE_WT/data/timeseries/s122_validation_base"
mkdir -p "$FIXED_OUT" "$BASE_OUT"

echo "=== [$(date +%T)] build rev_9 FIXED (main tree) ==="
Rscript scripts/rebuild_one_revision.R 2026_rev_9 "$FIXED_OUT" || exit 1

echo "=== [$(date +%T)] build rev_9 BASE (worktree $BASE_WT) ==="
( cd "$BASE_WT" && Rscript scripts/rebuild_one_revision.R 2026_rev_9 "$BASE_OUT" ) || exit 1

echo "=== [$(date +%T)] diff ==="
BASE_RDS="$BASE_OUT/snapshot_2026_rev_9.rds" \
FIXED_RDS="$FIXED_OUT/snapshot_2026_rev_9.rds" \
Rscript - <<'RS'
suppressPackageStartupMessages({library(tidyverse); library(here)})
base  <- readRDS(Sys.getenv('BASE_RDS'))
fixed <- readRDS(Sys.getenv('FIXED_RDS'))

rate_cols <- intersect(names(base), names(fixed))
rate_cols <- rate_cols[grepl('rate|total', rate_cols) & sapply(base[rate_cols], is.numeric)]
cat('comparing', length(rate_cols), 'numeric cols\n')

j <- inner_join(
  base  %>% select(hts10, country, all_of(rate_cols)),
  fixed %>% select(hts10, country, all_of(rate_cols)),
  by = c('hts10','country'), suffix = c('_b','_f'), relationship = 'one-to-one')
cat('joined', nrow(j), '(base', nrow(base), '/ fixed', nrow(fixed), ')\n')
cat('rows only in fixed (new GN6 residual materializations):',
    nrow(fixed) - nrow(j), '\n')

# which columns changed, and where
changed_cols <- c()
for (cl in rate_cols) {
  d <- abs(coalesce(j[[paste0(cl,'_b')]],0) - coalesce(j[[paste0(cl,'_f')]],0))
  if (any(d > 1e-9)) changed_cols <- c(changed_cols, cl)
}
cat('changed columns:', paste(changed_cols, collapse=', '), '\n')

allowed <- c('rate_s122','statutory_rate_s122','total_additional','total_rate')
bad_cols <- setdiff(changed_cols, allowed)
if (length(bad_cols) > 0) { cat('FAIL: unexpected changed columns:', paste(bad_cols, collapse=', '), '\n'); quit(status=1) }

# every changed cell must be on a (aa)(iv) hts8; load that set from the FIXED csv
ex <- read_csv(here('resources','s122_exempt_products.csv'), show_col_types = FALSE)
gn6 <- ex$hts8[ex$condition == 'gn6_civil_aircraft']
j$chg <- abs(coalesce(j$rate_s122_b,0) - coalesce(j$rate_s122_f,0)) > 1e-9
ch <- j %>% filter(chg)
cat('\nchanged cells (rate_s122):', nrow(ch), '\n')
offlist <- ch %>% filter(!substr(hts10,1,8) %in% gn6)
if (nrow(offlist) > 0) {
  cat('FAIL:', nrow(offlist), 'changed cells NOT on the (aa)(iv) list\n')
  print(offlist %>% count(hs8=substr(hts10,1,8), sort=TRUE) %>% head(10) %>% as.data.frame(), row.names=FALSE)
  quit(status=1)
}
# direction: rate_s122 must RISE (0 -> positive) on aircraft lines
if (any(coalesce(ch$rate_s122_f,0) < coalesce(ch$rate_s122_b,0) - 1e-9)) {
  cat('FAIL: some aircraft cells had rate_s122 DECREASE\n'); quit(status=1)
}

cat('\n=== s122 rise by chapter (value-unweighted mean over changed cells) ===\n')
ch %>% mutate(hs2 = substr(hts10,1,2)) %>% group_by(hs2) %>%
  summarise(n = n(), mean_s122_new = round(mean(rate_s122_f),4), .groups='drop') %>%
  arrange(desc(n)) %>% head(12) %>% as.data.frame() %>% print(row.names=FALSE)

cat('\nch88 aircraft mean new rate_s122 (should be ~0):',
    round(mean(ch$rate_s122_f[substr(ch$hts10,1,2)=='88']),4), '\n')
cat('PASS: diff confined to rate_s122 on (aa)(iv) aircraft lines, all rises\n')
RS
rc=$?
echo "=== [$(date +%T)] done rc=$rc ==="
exit $rc
