<!-- PR body for fix/column2-base-rates — paste into GitHub, then delete this file -->
## What

Two defects on the same country set — the origins HTSUS **General Note 3(b)** denies normal-trade-relations treatment: **Cuba (2390)**, **North Korea (5790)** always, and **Russia (4621)** / **Belarus (4622)** since PL 117-110 (2022-04-09).

**1. They were priced at column 1.** `parse_products()` read only the JSON `general` field, so every origin got column-1 general rates. GN 3(b) makes these four dutiable at **column 2**. Fixed by parsing the `other` field (same S2 no-AVE convention, own inheritance stack) and repointing those origins in a new step 1c.

**2. They were charged the IEEPA reciprocal tariff they are exempt from.** Heading **9903.01.29** — "Articles the product of any country identified in general note 3(b)" — carries an empty `general` and `other` = "The duty provided in the applicable subheading", i.e. no additional duty. The reciprocal program never reached them: already at column 2, already sanctioned. The model charged all four a mean **8.86%** (max 10%) anyway — roughly half their reported total. Fixed in step 2b.

Both resolve the country side from one new config block (`column_2_countries`), because GN 3(b) is prose the JSON does not carry. One block, two consumers — they cannot disagree about who is non-NTR.

## Measured effect (A/B vs the same-commit master vintage `2026-07-29-09`)

Russia, 2025-09-01 partition, mean per row — each fix built and measured separately:

| Vintage | base_rate | rate_ieepa_recip | total_rate |
|---|---|---|---|
| master (reference) | 0.0542 | 0.0886 | 0.1802 |
| + column 2 | **0.3040** | 0.0886 | 0.4300 |
| + GN 3(b) IEEPA exemption | 0.3040 | **0.0000** | **0.3499** |

Net for Russia: **0.1802 → 0.3499**. At 2025-04-05: 0.1601 → 0.3281. All four origins converge to an identical post-fix base (0.3034–0.3042) — as they must, since column 2 is country-agnostic and the preference scaling is now skipped. That convergence is itself a consistency check.

**Headline weighted ETR: 12.2557% → 12.2574% (+0.002pp).** These are tiny, sanctioned/embargoed import shares; the correction matters for per-origin statutory rates, not the aggregate.

## Scope containment — the key gate

A fingerprint of every rate column (n, sum, sum-of-squares) across all **13,680 partition × country cells**:

> **PASS: exactly the four GN 3(b) origins moved; every other country identical.**

Movers per metric: `base_rate`, `statutory_base_rate`, `rate_232`, `rate_ieepa_recip`, `total_rate`, `total_additional` — all four origins, no others. `base_rate_source` splits 4,819,592 `col1_general` / 81,688 `col2_other` (20,422 per origin).

**`rate_232` falls ~0.13pp on these origins, and that is correct.** The §232 annex-3 15% floor is MFN-**inclusive** (`pmax(floor − base_rate, 0)`): against a 30% column-2 base it correctly contributes 0 instead of 13pp, while `total_rate` rises. Flat layers are untouched by construction — Russia's 200% aluminum surcharge, `annex_1a` 50%, §122 and §301 are independent of `base_rate`, and `verify_build.R`'s Russia pins (7320.x `annex_1a` = 0.50, 7308.20 = 2.0) hold.

## Verification

- **125 tests pass, 0 failed** (rate-calculation suite; +9 column-2 fixture cases, +3 GN 3(b) cases). Full CI set green (`preflight`, `daily_series` 72, `weights_resolution` 16).
- Both A/B builds completed with the `verify_build.R` gate passing.
- Scope check above; vintages kept at `.validation/col2-ab/2026-07-29-20` (column 2 only) and `.validation/col2-gn3b/2026-07-29-20` (both).

## Notable secondary finding

The old `mfn_exemption_shares.csv` carried `76,4621,1.0` — a 100% "preference exemption" that was zeroing **Russia's entire aluminum base rate**, plus `91,4621,0.886` and `39/40,2390,1.0` for Cuba. These are artifacts of tiny licensed/humanitarian duty-free entries read as universal preference claiming. Column-2 origins are now excluded from that scaling (losing NTR means losing every preference program), which removes the double-wrongness. It suggests the shares builder may carry similar noise on other thin-trade origins — out of scope here.

## Deliberately NOT fixed (registered as gap F9)

**Heading 9903.82.12** (2026 annex regime): derivative aluminum/steel from GN 3(b) countries carries **+25%**, not the 50% tier those lines otherwise draw. Fixing it needs country-aware annex tier assignment plus the 9903.82.17 / 9903.85.68 exceptions — more than a base-rate PR should carry. Direction is *opposite* to this PR's understatement, and Russia's ch76 is unaffected in practice (the 200% surcharge `pmax`es over any tier). See `docs/statutory_deviations.md` F9 and `docs/assumptions.md` §20a.

## Known limitation

Column 2 is far more specific-duty-heavy than column 1 (~22% vs ~7% of lines). Under the S2 no-AVE convention those cells are numerically 0 with an honest `specific_or_compound` type, so these origins' levels are a **lower bound** until ad-valorem equivalents exist (Phase 4 of the pre-2025 expansion plan). Direction is unambiguous regardless: column 2 is never *below* column 1 on any line.

Docs: `docs/assumptions.md` §20 / §20a, `docs/statutory_deviations.md` S10 / F9.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
