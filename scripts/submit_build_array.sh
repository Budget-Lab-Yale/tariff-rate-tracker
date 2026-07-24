#!/bin/bash
#
# Config-driven build orchestrator.
# =============================================================================
# ONE input: a build-config YAML. ONE output: a timestamped vintage on the
# external interface (model_data_root) containing the `actual` series plus a
# subfolder per scenario.
#
# The build writes its outputs STRAIGHT INTO the vintage: the gather lands
# daily/quality under <model_data_root>/<vintage>/{actual,scenarios/<name>}/
# directly — no staging mirror, no copy. The only transient files are the per-
# revision rds caches (snapshot_/ch99_/products_/daily_part_/quality_part_) + logs, which live
# under <model_data_root>/.work/<vintage>/ and are removed by the finalize step.
# The repository working tree is NEVER written to.
#
#   bash scripts/submit_build_array.sh --config config/build/example.yaml
#
# Flow:
#   1. Parse the config (scripts/print_build_config.R) + pin ONE vintage.
#   2. For each series in [actual, <scenarios…>]: list-revs (sbatch --wait, to size
#      the array) -> array build (rds caches into the scratch) -> gather (daily/
#      quality written DIRECTLY into the vintage). afterok-chained; series concurrent.
#   3. ONE finalize job (afterok the last gather; all gathers re-checked via
#      sacct inside the job -- see await_jobs_ok.sh): scripts/publish_vintage.R ->
#      write_build_output() splits the scratch snapshots into the vintage's
#      actual/snapshots parquet, inventories the in-place daily/quality, writes
#      the manifest, repoints `latest`, and removes the scratch.
# =============================================================================

set -euo pipefail
# Repo root: TARIFF_REPO override, else derived from this script's location —
# so any clone (any user) can run the orchestrator without editing it. The
# component batch scripts carry no #SBATCH --chdir; every sbatch below passes
# --chdir="$REPO" explicitly.
REPO="${TARIFF_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO"
mkdir -p "$HOME/slurm-logs"

# ---- args -------------------------------------------------------------------
CONFIG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; echo "usage: $0 --config <build-config.yaml>" >&2; exit 2 ;;
  esac
done
if [ -z "$CONFIG" ]; then
  echo "usage: $0 --config <build-config.yaml>   (e.g. config/build/example.yaml)" >&2
  exit 2
fi
[ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 2; }

# ---- module env (for the Rscript config bridge + job wraps) -----------------
if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh
elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh; fi
module load R/4.4.2-gfbf-2024a 2>/dev/null || true
MODLOAD='if [ -f /etc/profile.d/z01_lmodinit.sh ]; then source /etc/profile.d/z01_lmodinit.sh; elif [ -f /etc/profile.d/lmod.sh ]; then source /etc/profile.d/lmod.sh; fi; module purge; module load R/4.4.2-gfbf-2024a'

# ---- resolve config (single source: bash + R agree) -------------------------
eval "$(Rscript scripts/print_build_config.R "$CONFIG")"
VINTAGE=$(date +%Y-%m-%d-%H)
VINTAGE_DIR="$MODEL_DATA_ROOT/$VINTAGE"        # the output folder — written directly
SCRATCH="$MODEL_DATA_ROOT/.work/$VINTAGE"      # transient rds caches + logs; removed at finalize

echo "=========================================================="
echo "Build config : $CONFIG"
echo "Vintage      : $VINTAGE"
echo "Interface    : $MODEL_DATA_ROOT"
echo "Output dir   : $VINTAGE_DIR   (built into directly)"
echo "Scratch      : $SCRATCH   (rds caches; removed at finalize)"
echo "Series       : actual ${SCENARIOS:-<none>}"
echo "=========================================================="

# ---- guard: nothing may resolve inside the repo working tree ----------------
assert_external() {  # $1=path  $2=label
  local rp; rp="$(readlink -m "$1")"
  case "$rp/" in
    "$REPO"/*) echo "REFUSING: $2 ($1 -> $rp) is inside the repo working tree" >&2; exit 1 ;;
  esac
}
assert_external "$VINTAGE_DIR" VINTAGE_DIR
assert_external "$SCRATCH" SCRATCH

# Hour-aligned: this run OWNS its vintage for the hour. Clear any prior vintage +
# scratch up front so a same-hour rebuild starts clean (the finalize no longer
# wipes the vintage — the gather writes into it directly). Both are external
# (asserted above); the repo working tree is untouched.
rm -rf "$VINTAGE_DIR" "$SCRATCH"
mkdir -p "$VINTAGE_DIR" "$SCRATCH"

# ---- per-step flags from config ---------------------------------------------
LIST_ARGS=""; BUILD_REVISION_ARGS=""; GATHER_ARGS=""
if [ "${USE_HTS_DATES:-0}" = "1" ]; then
  LIST_ARGS+=" --use-hts-dates"; BUILD_REVISION_ARGS+=" --use-hts-dates"; GATHER_ARGS+=" --use-hts-dates"
fi
if [ "${WEIGHT_MODE:-required}" = "unweighted" ]; then
  BUILD_REVISION_ARGS+=" --unweighted"; GATHER_ARGS+=" --unweighted"
fi
[ "${ALLOW_PARTIAL:-0}" = "1" ] && GATHER_ARGS+=" --allow-partial"

# ---- build each series ------------------------------------------------------
# Per-revision rds caches go to the scratch (TARIFF_TS_DIR); the gather writes
# daily/quality straight into the vintage (TARIFF_OUTPUT_DIR = the vintage dir,
# so series_section_dir lands them at <vintage>/actual/<section> or
# <vintage>/scenarios/<name>/<section>). Logs go to the scratch (TARIFF_LOG_DIR)
# so the published vintage stays clean.
SERIES_LIST=(actual ${SCENARIOS:-})
GATHER_JOBS=()
BASELINE_TS_DIR="$SCRATCH"                       # the actual-series snapshots scenarios reuse
LOG_DIR="$SCRATCH/logs"
OUT_DIR="$VINTAGE_DIR"                            # all series write into the one vintage dir
assert_external "$OUT_DIR" TARIFF_OUTPUT_DIR
mkdir -p "$LOG_DIR"

series_scen() { [ "$1" = "actual" ] && echo "" || echo "$1"; }
series_ts_dir() { [ "$1" = "actual" ] && echo "$SCRATCH" || echo "$SCRATCH/$1"; }

# ---- Phase A: list-revisions for ALL series, IN PARALLEL ---------------------
# Each series' list-revs is independent (isolated REVLIST/REV_TIMELINE under the
# scratch) and exists only to size that series' array. Nothing couples them, so
# run them concurrently instead of one-at-a-time: background each `sbatch --wait`
# and wait for all. This collapses the serial per-series stairstep (N x ~list-revs
# wall-clock) into a single bar (~one list-revs). `sbatch --wait` exits with the
# JOB's code, so a failed list-revs (e.g. OOM) is caught here and fails loud
# instead of silently dropping that series. The per-archive ch99 scan inside each
# is itself parallel (parallel::mclapply, TARIFF_LIST_CORES); output is
# byte-identical to the serial scan.
LIST_CORES=8
declare -A LR_PID
for series in "${SERIES_LIST[@]}"; do
  SCEN="$(series_scen "$series")"
  RL="$SCRATCH/revlist_${series}.txt"; RT="$SCRATCH/timeline_${series}.rds"
  echo "--- [$series] list revisions (parallel) ---"
  TARIFF_SCENARIO="$SCEN" TARIFF_POLICY_PARAMS="$POLICY_PARAMS_PATH" REVLIST="$RL" REV_TIMELINE="$RT" \
  TARIFF_LIST_CORES="$LIST_CORES" \
    sbatch --wait --job-name="lr-$series" --time=00:15:00 --nodes=1 --ntasks=1 --cpus-per-task="$LIST_CORES" --mem=16G \
      --output="$HOME/slurm-logs/lr-$series-%j.out" --error="$HOME/slurm-logs/lr-$series-%j.err" --chdir="$REPO" \
      --wrap="$MODLOAD; Rscript scripts/list_revisions.R$LIST_ARGS" >/dev/null &
  LR_PID[$series]=$!
done
LR_FAIL=0
for series in "${SERIES_LIST[@]}"; do
  if ! wait "${LR_PID[$series]}"; then
    echo "ERROR: list-revisions failed for series '$series' (see $HOME/slurm-logs/lr-$series-*.err)" >&2
    LR_FAIL=1
  fi
done
[ "$LR_FAIL" = "0" ] || exit 1

# ---- Phase B: array build + gather per series (arrays fan out concurrently) --
for series in "${SERIES_LIST[@]}"; do
  SCEN="$(series_scen "$series")"; TS_DIR="$(series_ts_dir "$series")"
  RL="$SCRATCH/revlist_${series}.txt"; RT="$SCRATCH/timeline_${series}.rds"
  assert_external "$TS_DIR" "TARIFF_TS_DIR[$series]"
  mkdir -p "$TS_DIR"
  N=$(grep -c . "$RL" || true)
  [ "${N:-0}" -ge 1 ] || { echo "ERROR: no revisions for series '$series' in $RL" >&2; exit 1; }
  echo "    $series: $N revisions ($(head -1 "$RL") .. $(tail -1 "$RL"))"

  echo "--- [$series] array build (0-$((N-1))) ---"
  ARRAY_JOB=$(TARIFF_SCENARIO="$SCEN" TARIFF_SERIES="$series" TARIFF_POLICY_PARAMS="$POLICY_PARAMS_PATH" \
    TARIFF_TS_DIR="$TS_DIR" TARIFF_OUTPUT_DIR="$OUT_DIR" TARIFF_LOG_DIR="$LOG_DIR" REVLIST="$RL" REV_TIMELINE="$RT" \
    BUILD_REVISION_ARGS="$BUILD_REVISION_ARGS" \
    sbatch --parsable --chdir="$REPO" --array=0-$((N-1)) scripts/build_array_task.sh)

  echo "--- [$series] gather (afterok:$ARRAY_JOB) ---"
  GJOB=$(TARIFF_SCENARIO="$SCEN" TARIFF_SERIES="$series" TARIFF_POLICY_PARAMS="$POLICY_PARAMS_PATH" \
    TARIFF_TS_DIR="$TS_DIR" TARIFF_OUTPUT_DIR="$OUT_DIR" TARIFF_LOG_DIR="$LOG_DIR" TARIFF_BASELINE_TS_DIR="$BASELINE_TS_DIR" \
    REV_TIMELINE="$RT" GATHER_ARGS="$GATHER_ARGS" \
    sbatch --parsable --chdir="$REPO" --dependency=afterok:"$ARRAY_JOB" scripts/submit_build_gather.sh)
  echo "    array=$ARRAY_JOB gather=$GJOB"
  GATHER_JOBS+=("$GJOB")
done

# ---- single finalize, gated on ALL series' gathers ---------------------------
# Splits the scratch snapshots into <vintage>/{actual,scenarios/<name>}/snapshots
# parquet, inventories the daily/quality the gather already wrote into the vintage,
# writes the manifest, repoints `latest`, then removes the scratch on success.
#
# The scheduler dependency covers only the LAST gather: with many series the
# loop above outlasts MinJobAge (5 min), so earlier gathers are purged from the
# controller by now and an afterok on their IDs is rejected at submission
# ("Job dependency problem" -- this silently killed the 2026-06-10-22 finalize).
# The last gather was submitted milliseconds ago, so its ID is always valid;
# scripts/await_jobs_ok.sh re-checks ALL gathers via sacct inside the finalize
# job before anything is published.
#
# With verify: true (config default) the finalize is GATED: publish WITHOUT
# moving `latest`, run scripts/verify_build.R against the vintage (test suite +
# sanity checks), and only repoint `latest` + remove the scratch if it passes.
# A verify failure leaves the vintage on disk for inspection, `latest` on the
# previous good vintage, and the scratch intact.
GUARD="bash scripts/await_jobs_ok.sh ${GATHER_JOBS[*]}"
if [ "${VERIFY:-1}" = "1" ]; then
  FIN_CMD="$MODLOAD; $GUARD"
  FIN_CMD+=" && TARIFF_UPDATE_LATEST=0 Rscript scripts/publish_vintage.R"
  FIN_CMD+=" && Rscript scripts/verify_build.R --output-root '$VINTAGE_DIR'"
  if [ "${UPDATE_LATEST:-1}" = "1" ]; then
    FIN_CMD+=" && Rscript scripts/publish_vintage.R --latest-only"
  fi
else
  FIN_CMD="$MODLOAD; $GUARD && Rscript scripts/publish_vintage.R"
fi
FIN_CMD+=" && rm -rf '$SCRATCH' && echo 'removed scratch $SCRATCH'"

DEP="${GATHER_JOBS[-1]}"
echo "--- finalize vintage $VINTAGE (afterok:$DEP, verify=${VERIFY:-1}) ---"
FIN_JOB=$(TARIFF_SCRATCH="$SCRATCH" TARIFF_VINTAGE="$VINTAGE" TARIFF_MODEL_DATA_ROOT="$MODEL_DATA_ROOT" \
  TARIFF_UPDATE_LATEST="${UPDATE_LATEST:-1}" \
  sbatch --parsable --dependency=afterok:"$DEP" --job-name="finalize-$VINTAGE" \
    --time=01:00:00 --nodes=1 --ntasks=1 --cpus-per-task=4 --mem=48G \
    --output="$HOME/slurm-logs/finalize-$VINTAGE-%j.out" --error="$HOME/slurm-logs/finalize-$VINTAGE-%j.err" \
    --chdir="$REPO" \
    --wrap="$FIN_CMD")

echo "=========================================================="
echo "Submitted. finalize=$FIN_JOB"
echo "Watch:   squeue -u $USER"
echo "Result:  $VINTAGE_DIR/{actual,scenarios/<name>}/  (latest -> $VINTAGE on success)"
echo "Verify:  ${VERIFY:-1} (verify_build.R gates the latest repoint when 1)"
echo "Scratch $SCRATCH is removed only if finalize (incl. verify) succeeds (kept for debug otherwise)."
echo "=========================================================="
