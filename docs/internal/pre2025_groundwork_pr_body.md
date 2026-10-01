<!-- PR body for feat/pre2025-phase2-build — paste into GitHub, then delete this file -->
## What

The groundwork for extending the tracker back to 2016 ([plan](docs/pre2025_expansion_plan.md); [scoping + decision record](docs/internal/pre2025_expansion_scoping_2026-07-28.md)), as one changeset. It replaces the three never-opened PRs for Phase 0 (invariance rails), Phase 1 (data acquisition) and Phase 2a (era skeleton). Phase 0b (column 2 / GN 3(b)) already merged separately.

**It changes no published number.** The 2025–26 build is proven identical to master below. The pre-2025 rates the era build produces are knowingly wrong until Phase 2b/2c date the authorities — see the scope warning in `config/policy_params_pre2025.yaml`.

### Phase 0 — invariance rails
- `series_horizon.start_date` (shipped `2025-01-01`) next to the existing `end_date`; `load_revision_dates()` applies both edges, after the policy-date swap. Every build-grid consumer funnels through it; archive-inventory tools (downloader, scrapers, changelog, concordance) opt out with `apply_window = FALSE`.
- `series_window_start()` resolves the window from the active baseline YAML (`TARIFF_POLICY_PARAMS` honored, fails closed on a bad path; overlays may not set `series_horizon`).
- Horizon hard stops on both build paths (`assemble_timeseries()`, `build_gather.R`), both edges; boundary mints exempt on the end side.

### Phase 1 — data acquisition
- 110 of 127 pre-2025 HTS JSON editions (2016–2024), committed gzipped (~70 MB) because `www.usitc.gov` is Akamai-403 and Wayback is the only other copy. Every edition parses with 32,830–35,810 records (no truncated Wayback capture survived) and carries era-appropriate content (§301 List 3 reads 10% in 6 editions, 25% in 97).
- Ch99 PDFs and Change Records for all 127 releases, and 11 annual tariff-database years, in the shared raw store (`raw_data/USITC-HTS-Archive/`, ~1.2 GB) with a manifest. Census IMDB 2015-01..2026-05 verified complete.
- `resources/pre2025_hts_inventory.csv` records the 19 releases with no JSON — 11 in 2018, including `2018_rev_2` (2018-03-23), the §232 metals start.
- Tooling: `tools/pre2025_*.R`, `scripts/submit_pre2025_acquisition.sh` (idempotent via the manifest); provenance in `docs/pre2025_data_provenance.md`.

### Phase 2a — era skeleton
- 110 pre-2025 rows in `config/revision_dates.csv`, dated at the USITC release start; `policy_effective_date` empty pending 2b. Outside the shipped window, so inert for the current build.
- `config/policy_params_pre2025.yaml`: the era's baseline, written as a diff against the 2025–26 baseline through a new `extends:` key (child wins, maps merge, sequences replace; fails closed on a child key the parent lacks, so a typo cannot leave the era on the 2025 window).
- `config/build/pre2025_era.yaml`: unweighted diagnostic vintage under `.validation/`, never repoints `latest`.
- `classify_authority()` no longer aborts a revision on a malformed Ch99 code (USITC's 2021 editions contain `9903.89,61`).
- The era builds end to end: vintage `.validation/pre2025-era/2026-07-31-11`, 118 intervals, 553M rows.

## Invariance evidence

| Proof | Result |
|---|---|
| A/B parity: master @ 5a97772 vs this branch, same-day array builds, weighted, `actual` + `new_301`, snapshots + all daily artifacts incl. `daily_by_hs` | **130/130 artifacts within tolerance** (65 per series: 60 snapshots + 5 daily; Slurm 28003173) |
| 2025–26 rows of `revision_dates.csv` vs master | byte-identical (merge-verified) |
| `verify_build.R` gate on the branch vintage | 11 passed, 0 failed (both vintages); `matched_imports_b == total_imports_b` on all 730 days |
| CI suites on the merged tree | daily-series 84/0, weights-resolution 16/0, annex-parser 17/0, rate-calculation 116/0 |

Vintages kept as evidence: `.validation/pre2025-landing-master/2026-09-30-23` (reference) and `.validation/pre2025-landing/2026-09-30-23` (this branch).

Note on the merge: master's ingests since July broke a Phase 2a test that pinned the current grid at 45 rows. It is re-anchored on a literal 2025-01-01, so it still catches an era leaking into the published grid without encoding today's row count.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
