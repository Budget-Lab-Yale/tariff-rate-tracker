<!-- PR body for feat/pre2025-phase0-invariance-rails — paste into GitHub, then delete this file -->
## What

First step of the 2016–2024 backfill ([scoping doc + decision record](docs/internal/pre2025_expansion_scoping_2026-07-28.md)): a `series_horizon.start_date` window (shipped as `2025-01-01`) so a future pre-2025 backfill of `revision_dates.csv` **cannot** widen the current 2025–2026 product.

- `load_revision_dates()` filters the grid post-policy-date-swap; every build-grid consumer funnels through it. Archive-inventory consumers (scraper, downloader, Ch99-PDF/floor-exemption scrapers, changelog, HTS concordance) opt out via `apply_window = FALSE`.
- `series_window_start()` resolves the window from the active policy-params YAML (`TARIFF_POLICY_PARAMS` honored; fails closed on a broken env path; overlays may not set `series_horizon`).
- Horizon-start hard stops on both build paths: `assemble_timeseries()` (serial) and `build_gather.R` (array/vintage).
- CLAUDE.md: the 5 GB interactive default and `salloc --mem=16G` guidance.

## Invariance evidence (all on Slurm, this branch vs master @ c4307e5)

| Proof | Result |
|---|---|
| Revision grid dump, both date views | byte-identical |
| `list_revisions.R` output (path-normalized) | identical, 1,726 lines |
| **A/B parity**: full vintage build from master (`.validation/phase0-parity-master/2026-07-29-09`) vs from this branch (`.validation/phase0-parity/2026-07-28-13`), snapshots + all daily artifacts incl. `daily_by_hs` | **62/62 artifacts within tolerance** |
| `verify_build.R` gate on the branch vintage | passed (finalize completed) |
| CI suites (preflight, daily-series incl. 8 new window tests, weights-resolution, rate-calculation) | all passed |

Note: a comparison against production `latest` (2026-07-24-09) is NOT clean — master already drifted from it when PR #21 merged post-bless (tiny FP-level `weighted_etr` shifts from day 1 plus the intended s232 changes). The A/B above isolates this branch's effect: zero.

## Review

An independent adversarial review traced every `load_revision_dates()` call site (verdict: no invariance risk with the shipped config) and its findings are fixed in c74d740: raw-vs-policy date-view hazard in the downloader, four missing inventory opt-outs, the unreachable guard on the array path, fail-open window resolution, overlay enforcement, finalize env plumbing, dead loads, and test hygiene.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
