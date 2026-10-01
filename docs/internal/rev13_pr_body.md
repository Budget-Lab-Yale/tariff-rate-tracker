<!-- PR body for feat/ingest-2026-rev13 — paste into GitHub, then delete this file -->
## What

Ingests **HTS 2026 revision 13** (published 2026-07-28), which codifies the **Section 301 forced-labor final action** into the tariff schedule as headings `9903.05.20`–`.84` under a new **U.S. note 52**. Duty effective **2026-07-24**.

Full review: [`docs/internal/hts_2026_rev13_review.md`](docs/internal/hts_2026_rev13_review.md).

## What rev_13 changes

| Dimension | rev_12 → rev_13 |
|---|---|
| Records | 35,677 → 35,779 |
| Chapter 99 headings | 511 → 612 (**+101 added, 0 removed, 0 modified**) |
| HTS8 established / deleted | **0 / 0** |
| HTS10 established / deleted | **0 / 0** — no 484(f) churn at all |
| `general` rate changes on ch.1–97 | **0** |
| `special` field changes | 25, every one whitespace normalisation (embedded newline → space); no programme code added or removed |
| `other` (column 2) changes | 0 |

The 101 additions are **64 country charging headings** (40 at `+12.5%`, 19 at `+10%`, plus the bifurcated EU pair), **15 exemption headings** (`.85`–`.99`), and **21 per-country product carve-outs** (`9903.06.01`–`.21`).

## Why this is rate-neutral

The tracker **already models this action as a baseline authority**, implemented from the Federal Register notice ahead of HTS codification: `config/policy_params.yaml::section_301_forced_labor`, `effective_date: '2026-07-24'`, citing headings 9903.05.20-.84 and note 52.

Every one of the 64 charging headings was mapped to its Census origin code and its published rate compared against the tier the config assigns:

> **0 mismatches.**

Three names required manual confirmation, all correct:
- `9903.05.38` / `.39` — "European Union" as collective headings; the config enumerates the 27 member states individually (net-10 tier = EU-27 + Taiwan = 28 entries).
- `9903.05.79` — "Türkiye", spelled "Turkey" in `resources/census_codes.csv` (4890). In no explicit tier, so it falls to the implicit flat 12.5% — which is exactly what the HTS charges.

The 2026-07-24 turn-on is already live in the published series (`valid_from=2026-07-24` exists in the current vintage).

**`policy_effective_date` is deliberately left NA.** The duty already turns on at 07-24 through the config date and its existing boundary mint; dating this row 07-24 would collide with that boundary to no purpose. `effective_date` is the HTS release date, 07-28.

## Worth knowing: one Phase 1 assumption corrected

This archive downloaded **straight from `www.usitc.gov/sites/default/files/tata/hts/`** — the host our Phase 1 provenance documents as Akamai-403. Probing a historical edition on the same path returns **404, not 403**: those files are *deleted*, not blocked. The 403 is specific to the `/tariff_affairs/documents/` path.

Conclusion for the backfill is unchanged (Wayback remains the only route to historical editions) but the reason is different from what we recorded.

## Implementation detail worth flagging

**CBP implements the net-of-MFN cap by bifurcating headings, not by arithmetic**: `9903.05.38` covers EU lines whose column-1 rate is at or above the threshold ("the duty provided in the applicable subheading" — no additional duty), and `9903.05.39` covers those below it with a flat `10%` *replacing* column 1. That is equivalent to the tracker's `max(10% − MFN, 0)`, but a naive per-heading rate read would see "0%" and "10%" and mean something different. This is recorded in `todo.md` as a trap for the rate-re-sourcing follow-up.

## Verification

- Archive validated on ingest: 35,779 records, 612 Chapter 99 headings, 70 forced-labor charging headings, note-52 marker present.
- CI suites run (`preflight`, `daily_series`, `weights_resolution`, `rate_calculation`).
- Candidate build via `config/build/rev13_ingest.yaml`, which records falsifiable expectations: **one new partition at 2026-07-28, every earlier partition unchanged, no new boundary mints.** A rate difference on any pre-07-28 partition would mean rev_13 changed something the review missed.
- Publishes a vintage but does **not** repoint `latest` — bless deliberately after a parity comparison against the current `latest`.

## Follow-ups added to `todo.md`

Both refinements, not corrections:
1. Re-source the forced-labor rates from the HTS (the pattern rev_12 applied to Brazil §301), with the bifurcation trap noted above.
2. Cross-check the 21 `9903.06.xx` carve-outs against `resources/s301fl_final_country_exemptions.csv` (4,921 rows, built from the FR annex) — USITC's enumeration is an independent check on ours.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
