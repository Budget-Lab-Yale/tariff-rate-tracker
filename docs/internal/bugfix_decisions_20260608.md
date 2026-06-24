# Bugfix decisions, 2026-06-08

Scope: Russia 200% Section 232 treatment, Swiss IEEPA floor timing, aircraft
exclusions, and China/CA/MX fentanyl stacking.

## Russia 200%

Decision: the pre-annex Russia override is aluminum-only.

Implementation: `S232_COUNTRY_OVERRIDES_PRE_ANNEX` now applies the 200% Russia
rate only to `aluminum`, not to `steel`.

## Swiss timing

Decision: the Swiss framework needs its own synthetic boundary on its effective
date while the framework is active.

Implementation: boundary discovery now mints the framework `effective_date`
when the Swiss framework has an expiry and is not finalized. The expiry boundary
is still suppressed when downstream logic zeroes the framework effect.

## Aircraft exclusions

Decision: parsed floor-country civil aircraft exclusions are applied as Section
232 metals-annex carve-outs where the relevant floor-country Ch99 actions are
present. Taiwan remains handled by its existing parsed resource.

Implementation: `floor_exempt_products.csv` civil-aircraft rows now expand EU,
Korea, Swiss, and Japan country groups to census codes and zero Section 232 only
for matching `(country, hts8)` pairs that have active metals-annex provenance.

Call not implemented: UK `9903.96.01` was not added because this repo does not
currently contain a parsed UK civil-aircraft product/country resource comparable
to the Taiwan or floor-country lists.

## Fentanyl stacking

Decision: IEEPA fentanyl is content-split by default on Section 232 products,
with a China additive exception.

Rationale: Tariff-ETRs computes China fentanyl at the full rate even when
Section 232 applies, but scales other fentanyl countries by `nonmetal_share`
when Section 232 is present.

Implementation: `ieepa_fentanyl` has stacking class `content_split` in both the
default stacking policy and authority specs, with `5700` (China) listed as an
additive exception.
