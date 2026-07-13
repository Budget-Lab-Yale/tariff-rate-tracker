# What the extreme etas say about the tariff-rate-tracker

June 2026. Cells are (country × HS2) over the training window (2025m5–2026m2),
from `data/processed/panel.rds`. "Statutory" = tracker `usmca_h2avg` rates
day-weighted to months; "collected" = Census IMDB calculated duties. Snapshot
evidence below is from `snapshot_rev_25.rds` (Oct 2025) and
`snapshot_2026_rev_2.rds` (Jan–Feb 2026). Dollar figures are the statutory-vs-
collected gap accumulated over the 10-month window.

A negative eta means collected > statutory (tracker likely **understates**);
an eta near 1 means collected ≈ 0 against positive statutory (tracker likely
**overstates**, or a legal exemption isn't modeled).

## Findings, ranked by money

### 1. Taiwan ch84 — semi-232 qualifying shares look far too low ($17.6B)
Taiwan machinery: statutory ETR 13.5% vs 0.8% collected on $139B of trade.
Snapshots charge `rate_232 = 23.8%` on 8471 computers — i.e. 25% × (1 − a
qualifying share of only ~5%) via `resources/semi_qualifying_shares.csv`.
Census collections imply the *de facto* qualifying (investment-exemption)
share is ~95%+. Companion issue: 8473 computer parts are charged the full 20%
reciprocal, but only 5 of the 8473 lines are on
`resources/ieepa_exempt_products.csv` — check 8473.21/29/30/50 against Annex
II / US Note 2(v)(iii). See also tariff-etr-eval
`docs/tracker_audits/s232_semi_calibration_2026-04-28.md`.

### 2. Country-specific EO layer appears to bypass the IEEPA exemption list — REFUTED / RESOLVED
Original hypothesis: the `country_eo` additions were summed on top of
`rate_ieepa_recip` without passing through the exemption filter, so India pharma
(3004) showed `rate_ieepa_recip = 0.25` and 9801 US-goods-returned showed the
full EO rate (Brazil 40%, India 25%) despite being on the exempt list.

**Refuted in the current code.** The surcharge arm of the `rate_ieepa_recip`
`case_when` (`06_calculate_rates.R:1851-1853`) splits the rate into
`(ieepa_country_rate − country_eo_rate)` — zeroed by the universal Annex II list
via `exempt_active` — plus `country_eo_rate`, which is separately zeroed by
`is_country_eo_exempt`. That flag (line 1837-1841) covers (a) the per-EO annex
(`country_eo_exempt_products.csv`; Brazil 9903.01.77 lists ch27 energy + more),
(b) Annex II inheritance for EOs in `country_eo_annex_ii_inherit` (India
9903.01.84, config default), and (c) the standard ch98 claim paragraph. The
join key is dot-stripped on both sides (`authority_adapter.R:355` vs
`substr(hts10,1,8)`), so there is no key mismatch.

Verified in `snapshot_rev_25.rds` (2025-10-14): Brazil ch27 energy
`rate_ieepa_recip = 0`; India 3004 exempt codes (e.g. 3004.90.92xx) `= 0`;
Brazil and India 9801 US-goods-returned `= 0`. The one India line still at 0.5
(3004.43.00.00, norephedrine medicaments) is **correct**, not a gap: the
reciprocal Annex II list (heading 9903.01.32 / note 2(v)(iii)(a)) as printed in
the HTS enumerates 3004.41/.42/.49 but omits 3004.43 (a consistent omission that
also drops 3003.31 and 3003.43); the tracker faithfully reproduces this. 3004.43
*is* exempt for EU (heading 9903.02.77) and Switzerland (9903.02.86), modeled
via `floor_exempt_products.csv` — and the snapshot confirms EU/DE 3004.43
`rate_ieepa_recip = 0` while non-EU origins (India) correctly pay the full rate.
So there is nothing to add to the universal exempt list; the origin-conditional
behavior matches the law. (Verified 2026-07-08.)

### 3. The IEEPA exempt list is static → November 2025 ag carve-out applied retroactively (negative-eta cluster)
`ieepa_exempt_products.csv` contains coffee (0901: 35 codes), tea (0902),
flowers (0603: 39), cocoa (1801), palm oil (1511) — the Nov 14, 2025
agricultural Annex-II expansion. Because the list is not revision-dated, the
**October 2025** snapshot already shows reciprocal = 0 on Colombia coffee and
flowers, months before the carve-out existed. Result: statutory understated
Apr–Nov 2025, collected ≫ statutory, and the entire negative-eta cluster
(ch06 flowers η≈−4, ch09 coffee, ch18 cocoa, ch15 palm, ch08 fruit, ch21).
Fix: add an `effective_date` to the exemption list (or per-revision lists),
mirroring how floor exemptions are already revision-dated.

### 4. Gold bullion charged Canada/Mexico fentanyl ($0.9B)
7108 is on the IEEPA exempt list (reciprocal correctly 0) but **absent from
`resources/fentanyl_carveout_products.csv`**, so Canada gold carries the full
40% fentanyl rate (Oct 2025 and Jan 2026 snapshots alike). Census: 0.19%
collected on $6.6B — the Sept 2025 bullion clarification holds in practice.
Gaps: Canada ch71 $615M, Mexico ch71 $278M.

### 5. Ch97 (Berman) not on the exempt list ($0.3B+)
Zero 9701 codes on `ieepa_exempt_products.csv`; 15%-floor partners (e.g.
cty 4279) are charged 15% reciprocal on art vs ~0.4% collected. Informational
materials (Berman Amendment) should zero the IEEPA layers on ch97 (and check
ch49). Eval-side notes suggest this was identified before — verify the fix
made it into the tracker's current list and rebuilt snapshots.

### 6. Watch lines (ch91) missing from the product universe ($0.5B+)
High-volume Swiss watch HTS10s (9101.21.50xx, 9102.21.70xx, …) are **not in
the snapshots at all** — these are compound/specific-duty lines, suggesting
the rate parser drops lines it can't convert; the retained ch91 lines also
carry `base_rate = 0`. With the panel treating missing as 0, Switzerland ch91
shows 16.9% collected vs 1.8% statutory (η ≈ −2.3). Even without AVE-ing
specific duties, keeping the lines (base ≈ 0 or a rough AVE) would let the
15% Swiss-framework surcharge attach. Same missing-line issue seen on
8408.20.90.90 (Germany).

### 7. Canada crude USMCA eligibility (part of $1.6B ch27 gap) — RESOLVED 2026-06-04
2709.00.20.10 showed `usmca_eligible = FALSE` → full 10% energy-carve-out
fentanyl on a major crude line, while sibling 2709 lines were ~0 after USMCA
shares. In practice virtually all Canadian crude clears USMCA-compliant.
**Fixed** by the two-part USMCA false-negative repair (see `todo.md` Extreme-eta
review fixes, item 6; commit b3dd1b5): (a) `extract_usmca_eligibility()` now
inherits the parent legal line's `special` field to statistical suffixes via a
legal-line stack, and (b) the share loader falls back HTS10 → HS8 value-weighted
share instead of defaulting absent/zero-trade pairs to 0. Verified in
`snapshot_rev_25.rds` (rebuilt 2026-06-25): 2709.00.20.10/CA now
`usmca_eligible = TRUE`, `statutory_rate_ieepa_fent = 0.10` (correct energy tier)
haircut to an effective `rate_ieepa_fent ≈ 0.0015` by the ~98.5% USMCA share.

### 8. AD/CVD — out of scope by design, but worth documenting
Vietnam ch85 collects $1.26B on lines the tracker correctly models at 0
(solar AD/CVD), and AD/CVD-heavy chapters (91, 06, 31) inflate collections
everywhere. Not a tracker bug; it *is* a reason the eta schedule has genuine
negative entries even after the fixes above.

## Caveat on "zero statutory" cells
The adj panel coalesces cells **missing from the snapshot** to rate 0, so the
zero-statutory-with-duties list mixes (a) modeled-zero (correct or item 2/3
above) with (b) missing lines (item 6) and (c) HTS10 concordance drift across
revisions. A tracker-side completeness check — Census HS10 universe vs
snapshot universe per revision, weighted by duties — would separate these
cheaply (`diagnostics.R` would be a natural home).
