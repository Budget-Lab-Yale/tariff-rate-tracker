<!-- PR body for feat/pre2025-phase1-acquisition — paste into GitHub, then delete this file -->
## What

**Phase 1 of the pre-2025 expansion: acquire and validate the raw inputs a 2016–2024 statutory build needs.** Tooling + data + an honest inventory of where the gaps are. No build changes — see "Inertness" below.

## Coverage acquired

| Year | Releases | JSON editions | Ch99 PDF | Change Record |
|---|---|---|---|---|
| 2016 | 2 | 1 | 2 | 2 |
| 2017 | 2 | 1 | 2 | 2 |
| 2018 | 19 | **8** | 19 | 19 |
| 2019 | 21 | 17 | 21 | 21 |
| 2020 | 29 | 29 | 29 | 29 |
| 2021 | 17 | 17 | 17 | 17 |
| 2022 | 14 | 14 | 14 | 14 |
| 2023 | 12 | 12 | 12 | 12 |
| 2024 | 11 | 11 | 11 | 11 |
| **Total** | **127** | **110** | **127** | **127** |

Plus **11 annual tariff-database years** (2015–2025) and a verification pass over the **137 months of Census IMDB weights** (2015-01 … 2026-05, zips + parsed parquet, md5'd, no gaps) that were already in the shared store — not re-downloaded.

## Why this routing

`www.usitc.gov` returns **Akamai 403** to every automated client from the cluster, so every artifact on that host (HTS JSON editions, annual tariff DB zips) is fetched through the **Wayback Machine**, enumerated via the **CDX API**. `hts.usitc.gov` is reachable directly and serves the Chapter 99 PDFs / Change Records. `census.gov` is reachable directly.

## Validation — 0 failures

Two documented traps, both defended against and both demonstrably not present in the result:

1. **Wayback truncates large captures at 1 MiB.** Real hazard: `hts_2019_basic_data.json` has captures at 645 KB, 535 KB *and* 78 KB. The fetcher ranks candidates by CDX `length`, then verifies the download actually parses and has a plausible record count. Result: every edition carries **32,830–35,810 records** (median 34,389) — no truncated capture survived.
2. **Getting *current* data under a historical URL.** (`exportList?release=` silently does exactly this.) Editions are asserted to contain no 2025-era IEEPA codes and to carry era-appropriate positive markers. The strongest evidence it worked: **the §301 List 3 rate reads 10% in 6 editions and 25% in 97** — the 2018-09-24 → 2019-05-09 step is visible in the data itself.

Validation outcomes: 109 `ok`, 1 `ok_with_warnings`, **0 failures**. Release-name matching: 106 exact, 2 number-only, 2 unmatched (editions Wayback holds that correspond to no named release in the API list).

## The 19 releases with no usable JSON

Recorded explicitly in `resources/pre2025_hts_inventory.csv` as `source_for_phase2 = chapter99_pdf+annual_db`. Eleven are in 2018, and the consequential one is **`2018_rev_2` (eff. 2018-03-23) — the Section 232 steel/aluminum start.** The first 2018 edition with JSON is `2018_rev_8_1` (2018-08-07), leaving a **~4.5-month machine-readable blind spot over the §232 launch**. The annual tariff database carries the correct `begin_effect_date` for those provisions, which is why it is the designated spine for the era.

## What lands in the repo vs the shared store

- **Repo:** the acquisition tooling (`tools/pre2025_*.R`, `scripts/submit_pre2025_acquisition.sh`), the inventory CSV, the provenance doc, and the **110 gzipped JSON archives (~70 MB)**.
- **Shared store** (`raw_data/USITC-HTS-Archive/{json,zips,pdf}/` + `manifest.csv`, ~1.2 GB): acquisition source of truth, including the 254 PDFs and 11 annual-DB zips.

Archives are committed for the same reason the 2025–26 archives are: the source host is blocked, so they cannot be re-fetched, and Wayback is a single point of failure. Committing them is what lets a fresh clone build the era at all. Each was verified byte-for-byte against the shared store after copying. Force-added past the `*.json.gz` ignore rule, exactly as the existing archives were.

## Inertness — this PR does not change any output

`config/revision_dates.csv` is **untouched**; curating those rows is Phase 2. The build grid comes from that CSV, not from the archive directory, so the new archives are inert. Verified on-branch:

```
grid rows: 45 | range: 2025-01-01 .. 2026-07-21
pre-2025 rows in grid: 0
archives on disk: 156
PASS: 110 new archives are inert — grid unchanged
```

Test suites: **112 passed, 0 failed** (`preflight`, `daily_series`, `weights_resolution`, `rate_calculation`).

## Re-running

`bash scripts/submit_pre2025_acquisition.sh` (Slurm; interactive sessions are 5 GB capped). The tools are idempotent — already-verified artifacts are skipped via the manifest. See `docs/pre2025_data_provenance.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
