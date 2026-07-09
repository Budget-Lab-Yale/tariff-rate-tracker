#!/bin/bash
#
# Validation gate for the UK note-16(d) metal-type fix (2026-07-08): rebuild
# 2026_rev_9 from the working tree and diff every rate column against the
# published latest-vintage snapshot (valid_from=2026-05-01, built from
# 6e7a2b1 — a valid pre-fix baseline: no rate-moving commit landed between).
#
# EXPECTED diff: UK (4120) rows ONLY —
#   * annex_1b steel/aluminum cells outside ch72/73/76: rate_232 0.25 -> 0.15
#     (uk_content_qualifying_share = 1.0), statutory_rate_232 + totals follow
#   * annex_1a steel/aluminum outside the metal chapters (if any): 0.50 -> 0.25
#   * UK cells that are heading-program products: previously wiped by the
#     replace-mode override where the old gate reached them — now KEEP their
#     heading rate (companion guard fix; expected to be ch72/73/76 items on
#     the auto-parts/MHD lists, if any)
#   * copper-list cells: UNCHANGED (16(d) excludes copper)
# Any non-UK changed cell = FAIL.
#
# Usage: sbatch scripts/submit_uk_gate_validation.sh

#SBATCH --job-name=uk-gate-validate
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH --output=/home/%u/slurm-logs/uk-gate-validate-%j.out
#SBATCH --error=/home/%u/slurm-logs/uk-gate-validate-%j.err

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

OUT_DIR=data/timeseries/uk_gate_validation
mkdir -p "$OUT_DIR"

echo "=== [$(date +%T)] rebuild 2026_rev_9 (fixed tree) ==="
Rscript scripts/rebuild_one_revision.R 2026_rev_9 "$OUT_DIR" || exit 1

echo "=== [$(date +%T)] diff vs published latest valid_from=2026-05-01 ==="
Rscript - <<'RS'
suppressPackageStartupMessages({library(tidyverse); library(arrow)})
base <- read_parquet(file.path(
  '/nfs/roberts/project/pi_nrs36/shared/model_data/Tariff-Rate-Tracker',
  'latest/actual/snapshots/valid_from=2026-05-01/rates.parquet'))
newd <- readRDS('data/timeseries/uk_gate_validation/snapshot_2026_rev_9.rds')

rate_cols <- intersect(names(base), names(newd))
rate_cols <- rate_cols[grepl('rate|total|share', rate_cols) &
                       sapply(base[rate_cols], is.numeric)]
cat('comparing', length(rate_cols), 'numeric columns on the joined grid\n')

j <- inner_join(
  base %>% select(hts10, country, all_of(rate_cols)),
  newd %>% select(hts10, country, all_of(rate_cols)),
  by = c('hts10', 'country'), suffix = c('_b', '_n'),
  relationship = 'one-to-one')
cat('joined cells:', nrow(j), '(base', nrow(base), '/ new', nrow(newd), ')\n')

changed <- rep(FALSE, nrow(j))
for (cl in rate_cols) {
  d <- abs(coalesce(j[[paste0(cl, '_b')]], 0) - coalesce(j[[paste0(cl, '_n')]], 0))
  changed <- changed | d > 1e-9
}
ch <- j[changed, c('hts10', 'country')]
cat('changed cells:', nrow(ch), '\n')
print(ch %>% count(country, sort = TRUE) %>% head(10) %>% as.data.frame(), row.names = FALSE)

nonuk <- ch %>% filter(country != '4120')
if (nrow(nonuk) > 0) {
  cat('FAIL: ', nrow(nonuk), ' non-UK changed cells\n')
  print(nonuk %>% count(country, ch = substr(hts10, 1, 2), sort = TRUE) %>% head(20) %>% as.data.frame(), row.names = FALSE)
  quit(status = 1)
}

# channel summary on the UK diff
uk <- j[changed & j$country == '4120', ]
cat('\nUK changed cells by chapter x rate_232 move:\n')
uk %>% mutate(ch = substr(hts10, 1, 2)) %>%
  count(ch, r232_b = round(rate_232_b, 3), r232_n = round(rate_232_n, 3)) %>%
  arrange(desc(n)) %>% head(20) %>% as.data.frame() %>% print(row.names = FALSE)
cat('\nPASS: diff confined to UK\n')
RS
rc=$?
echo "=== [$(date +%T)] done rc=$rc ==="
exit $rc
