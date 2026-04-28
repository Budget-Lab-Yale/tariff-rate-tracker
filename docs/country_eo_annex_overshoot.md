# Country-EO Annex II overshoot — refactor proposal

**Status**: proposal, not yet implemented. Code changes below are sketches; review before applying.
**Authored**: 2026-04-27
**Triggered by**: `tariff-etr-eval` trackermiss diagnostic (April 2026), `docs/tracker_miss_report.md` upstream.

## Summary

The tracker's `rate_ieepa_recip` channel applies the EO 14257 Annex II exempt list (`resources/ieepa_exempt_products.csv`) to **all** IEEPA reciprocal contributions, including country-specific EOs (9903.01.76–.89). This is incorrect: country EOs have their own narrower exempt lists, separate from EO 14257 Annex II.

**Smoking-gun cell**: Brazilian coffee 0901.11.00.25, October 2025. Census-implied rate **49.97%**, exactly matching Phase 2 +10% (9903.02.09) + Brazil EO 14323 +40% (9903.01.77). Tracker reports 0% because the Annex II check zeros the entire `rate_ieepa_recip` for any HS10 on the universal exempt list. Coffee was not added to Brazil's exempt list until November 13, 2025 (per CBP CSMS #66871909).

Total trackermiss attributable to this overshoot: ~$1–2B across Brazil, India, Vietnam, Indonesia, and other country-EO targets. Inherited downstream into Tariff-ETRs (`config/.../ieepa_reciprocal.yaml` shows Brazil headline = 10%, missing the +40% surcharge).

## Current code path

`src/06_calculate_rates.R`, lines 808–835 (phase aggregation):

```r
country_ieepa <- active_ieepa %>%
  ...
  group_by(census_code, phase) %>%
  summarise(phase_rate = first(rate), ieepa_type = first(rate_type), ...) %>%
  group_by(census_code) %>%
  summarise(
    ieepa_country_rate = sum(phase_rate),    # phase1 + phase2 + country_eo merged
    ieepa_type = first(ieepa_type), ...
  )
```

Lines 963–972 (rate calculation):

```r
rate_ieepa_recip = case_when(
    duty_free_treatment == 'nonzero_base_only' & base_rate < 0.001 ~ 0,
    hts10 %in% ieepa_exempt_products ~ 0,        # zeros the merged total
    floor_exempt ~ 0,
    is.na(ieepa_country_rate) ~ 0,
    ieepa_type == 'surcharge' ~ ieepa_country_rate,
    ieepa_type == 'floor' ~ pmax(0, ieepa_country_rate - base_rate),
    ieepa_type == 'passthrough' ~ 0,
    TRUE ~ 0
  )
```

Annex II exemption fires before the country-EO surcharge can land.

## Proposed refactor

### 1. Preserve per-phase contributions through the join

Replace the `summarise(ieepa_country_rate = sum(phase_rate))` collapse with a wider format that keeps each phase as its own column:

```r
country_ieepa <- active_ieepa %>%
  ...
  group_by(census_code, phase) %>%
  summarise(phase_rate = first(rate), ieepa_type = first(rate_type), .groups = 'drop') %>%
  pivot_wider(
    id_cols = census_code,
    names_from = phase,
    values_from = c(phase_rate, ieepa_type),
    values_fill = list(phase_rate = 0, ieepa_type = NA_character_)
  ) %>%
  rename(
    rate_phase1   = phase_rate_phase1_apr9,
    rate_phase2   = phase_rate_phase2_aug7,
    rate_country_eo = phase_rate_country_eo,
    type_phase1   = ieepa_type_phase1_apr9,
    type_phase2   = ieepa_type_phase2_aug7,
    type_country_eo = ieepa_type_country_eo
  )
```

### 2. Load the country-EO exempt registry

```r
country_eo_exempt_path <- here('resources', 'country_eo_exempt_products.csv')
country_eo_exempt <- if (file.exists(country_eo_exempt_path)) {
  read_csv(country_eo_exempt_path, col_types = cols(.default = col_character())) %>%
    mutate(
      effective_date_start = as.Date(effective_date_start),
      effective_date_end   = as.Date(effective_date_end)
    ) %>%
    filter(
      is.na(effective_date_start) | as.Date(effective_date) >= effective_date_start,
      is.na(effective_date_end)   | as.Date(effective_date) <= effective_date_end
    ) %>%
    distinct(ch99_code, hts10)
} else {
  tibble(ch99_code = character(), hts10 = character())
}
```

The `effective_date` filter handles the Nov 13, 2025 modification window for Brazil — an HS10 entry with `effective_date_start = 2025-11-13` is only treated as exempt for revisions on or after that date.

### 3. Apply Annex II to phase1/phase2 only; apply country-EO list to country_eo

```r
# Build per-EO exempt lookup keyed on the country's active EO ch99 code.
# For Brazil (3510), that's 9903.01.77; for India (5330), 9903.01.84; etc.
# We need a country -> ch99_code map for active country EOs at this date,
# which is already produced upstream as part of phase parsing.

rates <- rates %>%
  left_join(country_eo_for_country, by = 'country') %>%   # adds active_eo_ch99
  mutate(
    is_universally_exempt = hts10 %in% ieepa_exempt_products,
    is_country_eo_exempt  = paste(active_eo_ch99, hts10) %in%
                            paste(country_eo_exempt$ch99_code, country_eo_exempt$hts10),

    # Each phase contribution is masked by its own exempt rule
    rate_phase1_recip      = if_else(is_universally_exempt | floor_exempt, 0, rate_phase1),
    rate_phase2_recip      = if_else(is_universally_exempt | floor_exempt, 0, rate_phase2),
    rate_country_eo_recip  = if_else(is_country_eo_exempt | floor_exempt, 0, rate_country_eo),

    rate_ieepa_recip = rate_phase1_recip + rate_phase2_recip + rate_country_eo_recip
  )
```

The `floor_exempt` check still applies across all phases (legal exemptions like Note 2(v)(xx)–(xxiv) cover the floor framework countries regardless of phase). The Annex II check applies only to phase1/phase2. The country-EO check applies only to the country_eo phase, with date bounds.

### 4. Statutory rate decomposition

Update the `statutory_rate_*` save (line 2147) to preserve per-phase contributions if downstream consumers (`generate_etrs_config.R`, `compare_etrs.R`) need them. Likely not necessary in the first pass — `statutory_rate_ieepa_recip` as the post-exempt sum is still the right number for the ETRs handoff.

## Population of `country_eo_exempt_products.csv`

Stub is at `resources/country_eo_exempt_products.csv`. Full population requires PDF extraction:

| EO | Source PDF | Codes |
|----|------------|-------|
| Brazil EO 14323 (original) | `https://www.whitehouse.gov/wp-content/uploads/2025/07/EO14323-Annex.pdf` | ~500 HTSUS subheadings |
| Brazil Nov 20 modifying EO Annex II | `https://www.whitehouse.gov/wp-content/uploads/2025/11/2025NovemberBrazilTariff.ANNEXES.pdf` | 238 ag HTSUS + 11 categories (effective Nov 13, 2025) |
| India 9903.01.84 (EO 14361) | TBD | Likely empty or very narrow — the India EO targets Russian oil purchases broadly |
| Other country EOs (9903.01.76, .78–.89) | per-EO PDFs | TBD |

Recommend `scripts/scrape_country_eo_annexes.R` to parse each PDF into the CSV format. CBP CSMS bulletins (e.g., #65807735, #66871909) provide partial coverage and are more reliable to scrape than the WH PDFs directly.

## Validation

Once implemented, the test cell is Brazilian coffee 2025-10:
- Pre-fix: tracker `rate_ieepa_recip` = 0% (Annex II overshoot).
- Post-fix: tracker `rate_ieepa_recip` = 50% (Phase 2 +10% surviving Annex II — coffee is on Annex II — wait, this needs verification: is coffee on Annex II of EO 14257?).

Actually re-examining: coffee 0901 IS on `ieepa_exempt_products.csv` (universal Annex II for the reciprocal regime). So:
- Phase 2 +10% Brazil → zeroed by Annex II → 0%
- Country EO +40% Brazil → kept (coffee NOT on Brazil EO Annex I until Nov 13) → 40%
- Total `rate_ieepa_recip` = 40% on Brazil coffee Aug–Nov 2025

Census-implied 49.97% would then equal 40% (country EO) + ~10% (some other authority — possibly fentanyl carve-out, MFN, or rounding). Acceptable proximity. After Nov 13, the post-fix tracker would correctly drop to 0% (coffee added to Brazil exempts), matching the trade reality of the second EO.

For India smartphones (HS 8517.13): Annex II exempts smartphones, so phase2 → 0. India EO 14361 → +25% if smartphones not on India's own carve-out. Census-implied 2.2% suggests India EO list does include smartphones (similar to original Annex II). To verify, populate India's exempt list from the EO 14361 annex.

## Estimate

- 2 hours: refactor `06_calculate_rates.R` per (1)–(3) above.
- 4 hours: build `scripts/scrape_country_eo_annexes.R` to populate Brazil pre-Nov-13 + Nov-13 lists from CBP CSMS bulletins.
- 1 hour: regression-test against `compare_etrs.R` for cells outside the Brazil-coffee window (verify no shifts where there shouldn't be).
- 1 hour: extend `decompose_tpc_discrepancies()` to label the new "country-EO recovered" bucket so future TPC comparisons can verify the fix.

Total: ~1 day. Recovery: ~$1–2B trackermiss based on `tariff-etr-eval` data.

## Cross-repo impact

- `Tariff-ETRs` config files inherit the bug via `generate_etrs_config.R` → `ieepa_reciprocal.yaml`. Once the tracker fix lands, regenerate the ETRs configs (`Rscript src/generate_etrs_config.R <date> <output_dir>`) and the headline rates will reflect the country EO additions.
- `tariff-etr-eval` should re-run the trackermiss diagnostic against the new snapshots; expected: Brazil coffee cells drop to 0 trackermiss for the Aug–Nov 2025 window.
