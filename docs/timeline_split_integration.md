# Unified timeline splitter — integration note (Pass-2 / P2-1)

**Status:** code + unit tests landed on `theseus`; golden re-freeze pending the array
build. This is a **behavior-changing** plank (it moves in-window numbers on 2025-03-12),
so it is validated by **statute invariants + a golden re-freeze**, NOT by parity vs the
old golden. Plan: `bright-gathering-waterfall.md`; supersedes the P2-1 stub in
`docs/archive/spec_driven_calculator_plan.md`.

## What changed

The daily series was a step function over dated revision snapshots: a rate whose legal
effective date fell *between* two revisions could only turn on at the next revision —
late. Manual redating (`config/revision_dates.csv` `policy_effective_date`) hand-aligned
each revision to its *headline* event, but missed effective dates that aren't a
revision's headline.

We now make the timeline emerge from the snapshots. After the per-revision snapshots are
built, `discover_boundaries()` (`src/model/timeline.R`) finds every schedule boundary that
(a) falls **strictly inside** a real revision interval on the build grid, and (b) the
calculator's own date gates **re-resolve** on an as-of recompute. `build_boundary_mints()`
(`src/pipeline/00_build_timeseries.R`) mints one synthetic `bnd_<date>` revision per boundary — the
owning revision's archive re-run **stamped at the boundary date**, with empty operations —
and `assemble_timeseries()` turns each mint into its own `[D, next]` interval via
`rev_dates` ordering (auto-shortening the owner to `D-1`). No calculator change: the date
gates already do the work.

This is the baseline-eligible generalisation of `build_scheduled_activations()` (the
future turn-ON mechanism): arbitrary owner archive (not just the tip), empty operations
allowed (the change is the as-of date itself), a distinct `bnd_` prefix, idempotent, and
**part of the baseline/golden** (scheduled activations are scenario-only).

## The mintable set (verified on the production policy grid, 2026-06-06)

A systematic scan of the cached `ch99_<rev>.rds` parses + the config dates produced
**exactly three** boundaries:

| boundary    | owner        | source                              | window | what it fixes |
|-------------|--------------|-------------------------------------|--------|---------------|
| 2025-03-12  | `rev_4`      | §232 country-exemption expiry       | IN     | CA/MX/EU/UK/JP/KR/AU/BR/AR/UA steel+aluminum jump 0→25% on 03-12, not at rev_5 (03-14) |
| 2026-02-20  | `2026_rev_3` | IEEPA invalidation (SCOTUS)         | out    | reciprocal + fentanyl → 0 on 02-20, not at 2026_rev_4 (02-24); opens the genuine 4-day [02-20,02-23] window where IEEPA **and** S122 are both 0 (S122 starts 02-24) |
| 2026-11-10  | `2026_rev_9` | §301 Ch99 `effective_date_offset`   | out    | 9903.91.12–.16 (intermodal chassis + ship-to-shore gantry cranes, China) turn ON 2026-11-10 — previously masked **forever** by `filter_active_ch99` (no real revision is dated ≥ 11-10) |

Two findings corrected the plan's assumptions:

1. **2025-03-12 is NOT a Ch99 offset.** The plan expected a "Mar-12 derivative offset" to
   auto-discover it; the scan found none, and the §232 derivative codes (9903.81.89–.93,
   9903.85.04/.07/.08) are present in `rev_4` **ungated** (already active). The real signal
   is the `section_232_country_exemptions` `expiry_date` (the adapter gate
   `rev_date < expiry`, `authority_adapter.R`), which `collect_schedule_boundaries()` does
   not carry — so `discover_boundaries()` adds §232 country-exemption expiries as a
   first-class source.
2. **2026-11-10 is a real discovery** (not in the plan). It is the genuine
   scheduled-turn-ON gap (`scheduled-activations-gap`): real §301 entries dated "on or
   after November 10, 2026" that the current pipeline never activates.

### The 2026-11-10 §301 codes were a discovered data gap — now PRICED

The systematic scan surfaced that the §301 crane/chassis codes `9903.91.12`/`.14` carry a
parsed **100%** rate in the Ch99 text but were **absent from `section_301_rates`** (the calc
assigns `rate_301` only from that config lookup, `06: s301_rate_lookup` inner-join), so the
2026-11-10 mint was initially **daily-inert**. We then **priced them**:
- `config/policy_params.yaml` `section_301_rates` += `9903.91.12 → 1.00` (chassis, US note
  31(k)(i)) and `9903.91.14 → 1.00` (ship-to-shore gantry cranes, note 31(l)).
- `resources/s301_product_lists.csv` += the covered hts8 → code mappings: `87163900`,
  `87169030`, `87169050` → `9903.91.12`; `84261900` → `9903.91.14`.

Result on `bnd_2026-11-10` (verified): China cranes `8426.19` + chassis `8716.39/.90`
`rate_301` rises **0.25 → 1.00** (bumped via `MAX`-per-hts8 from the pre-11-10 listing — e.g.
cranes `9903.92.10` = 0.25). The mint is now meaningful: it moves the daily series across its
whole priced interval `[2026-11-10, horizon]`. Final impact vs `70b6b97`: **58 daily rows move,
all inside the boundary windows, 0 outside** (regression guard green) — 2 for 2025-03-12/13
(§232, +0.22pp), 4 for 2026-02-20→23 (IEEPA, −9.2pp unweighted / weighted_etr 13.1%→7.5%), and
52 for `[2026-11-10, 12-31]` (small in aggregate — `etr_301` +0.016pp — as it is a handful of
products). `tests/test_timeline_invariants.R` asserts `rate_301 == 1.00` on 2026-11-10 (was
0.25 on 11-09).

**Two modeling judgment calls** (documented in the `section_301_rates` config comment; refine
if calibrated):
1. **Omitted `.13/.15/.16`** — "duty provided in the applicable subheading" = **+0%** (the
   chassis note 31(k)(ii) complement + the crane attestation exemptions for non-China-origin /
   grandfathered cranes). `MAX`-per-hts8 would moot 0% entries, and modeling these carve-outs
   needs an exemption-*share* mechanism (uncalibrated/out-of-scope).
2. **hts8 over-application** — `.12` legally targets only `8716390090`, but the 301 list is
   hts8-keyed, so all of `87163900` (6 product lines) gets 100%; likewise the (k)(i)/(k)(ii)
   split within an hts8 cannot be represented. Same hts8-granularity limitation as the
   tracker's other 301 lists.

Edge-coincident boundaries correctly produce **no extra mint** (they sit on a real
revision's date): 2025-04-09 (Phase-1 country rates = `rev_8`), 2025-05-03
(auto parts = `rev_11`), and 2026-04-06 (§232 annex = `2026_rev_5`). The Swiss
and S122 first-dead-day boundaries, 2026-04-01 and 2026-07-24, are minted because
no real revision owns those dates.

## Calendar ownership rule

Every policy start or first-dead-day boundary is handled by **one mechanism**:
the calculator mints a snapshot. S122 re-resolves to zero after its sunset. The
Swiss framework re-resolves from the temporary floor to the underlying reciprocal
rate, which is now retained in the snapshot together with the floor and its dates.

There is no downstream expiry splitter or zeroing pass. Daily reports and point
queries select the minted interval, so the published snapshot, a one-date lookup,
and every daily aggregate use the same policy state. The boundary and transition
invariants are covered by `tests/test_mint_equals_zeroing.R` and
`tests/run_tests_daily_series.R`.

## Wiring

`discover_boundaries()` + `build_boundary_mints()` run immediately **before**
`build_scheduled_activations()` in both post-array sites:
`build_full_timeseries()` (`src/pipeline/00_build_timeseries.R`) and
`scripts/build_gather.R`. `09_daily_series.R` consumes the minted intervals directly.
`build_scheduled_activations()`'s tip selection was hardened to
pick the latest **real** revision (a `bnd_` row can now hold the latest `effective_date`).

`config/policy_params.yaml` gains an empty `boundary_overrides: []` block (a curated
backstop, loaded as `pp$BOUNDARY_OVERRIDES`) — empty because all three boundaries are
auto-discovered.

## Tests

- `tests/test_boundary_discovery.R` — discovery includes the Swiss first-dead-day
  boundary with the correct owner and source.
- `tests/test_mint_equals_zeroing.R` — the Swiss floor is live on its expiry date,
  its underlying surcharge resumes on the next day, and both expiries mint.
- `tests/test_timeline_realdata.R` — the live calendar emits the expected boundary set.
- `tests/test_timeline_invariants.R` — absolute rate-state assertions on the built
  snapshots (skips until a build produces the `bnd_` snapshots): §232 exemption flip on
  03-12, IEEPA+fentanyl=0 on 02-20, the 02-20→02-24 both-zero window, S122 on 02-24, §301
  cranes on 11-10, and no-spurious-split positive controls.

## Golden re-freeze (after the array build lands + invariants pass)

Stage 1 moves in-window numbers (the 03-12 cluster, 2 days × the exempted countries'
steel/aluminum), so the golden must be re-frozen:
1. `GATHER_ARGS="--unweighted" bash scripts/submit_build_array.sh` → `afterok` gather (now
   mints the three `bnd_` snapshots post-array).
2. Run `tests/test_timeline_invariants.R` against the new build (must be green).
3. `scripts/report_timeline_split_impact.R` → `output/timeline_split_impact/` (expect the
   §232 bump on CA/MX/EU/UK/JP/KR around 2025-03-12; 2026 IEEPA/301 changes out-of-window).
4. Re-capture the golden via `scripts/capture_parity_golden.R` (+ `build_parity_manifest.R`)
   into `tests/golden/<new_sha>/`; update `policy_params_md5` and `n_snapshots`. **The
   capture must contain exactly the real + three `bnd_` snapshots.** R5 safety net:
   `scripts/summarize_parity_results.R` fails the parity run (exit 1) on any golden-only OR
   candidate-only artifact — so a stale golden missing the `bnd_` snapshots, or an
   unexpected synthetic snapshot in the candidate, turns parity RED rather than green-on-bad.
   (`build_parity_manifest.R` itself only compares the shared intersection; the refusal lives
   in the summarizer.) Retain `70b6b97` for provenance.

**Current golden: `tests/golden/52dab78`** (2026-06-06, commit `52dab78` — after pricing the
§301 cranes/chassis). 45 snapshots (42 real + the 3 `bnd_` mints, manifest lists exactly
`bnd_2025-03-12` / `bnd_2026-02-20` / `bnd_2026-11-10`), weighted daily CSVs,
`policy_params_md5 = 4afe9508aa0aef78e443fcf1a86ee757`, `use_policy_dates = true`,
`src_config_dirty = false`, `has_timeseries = false` (array path skips the monolith).
Validated surgical: **58 daily rows move, all inside the boundary windows, 0 outside.**
Supersedes `tests/golden/6ec81b9` (the pre-pricing re-freeze, when 2026-11-10 was inert).
Prior production golden **`70b6b97` retained** for provenance.
