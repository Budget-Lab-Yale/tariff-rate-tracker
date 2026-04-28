# Russia rev_5 fix plan

Date: 2026-04-22

## Goal

Make rev_5+ handling of clause (8) of the April 2, 2026 metals proclamation
policy-accurate, not just artifact-consistent.

Primary source:
- White House proclamation (Apr. 2, 2026): [Strengthening Actions Taken to Adjust Imports of Aluminum, Steel, and Copper Into the United States](https://www.whitehouse.gov/presidential-actions/2026/04/strengthening-actions-taken-to-adjust-imports-of-aluminum-steel-and-copper-into-the-united-states/)

Clause (8), paraphrased:
- Annex I-A, I-B, and III aluminum articles/derivatives stay at 200% when they
  are the product of Russia, or when any primary aluminum used was smelted in
  Russia, or when the article was cast in Russia.

## Current state

- Source code now correctly restores 200% for the direct exporter-country case.
  `section_232_annexes.country_surcharges` plus the post-annex `pmax()` path in
  `src/06_calculate_rates.R` restore `rate_232 = 2.0` for
  `country == '4621'` on Annex I-A/I-B/III aluminum rows in a fresh rev_5
  recompute.
- Saved artifacts are stale. `snapshot_2026_rev_5.rds` and
  `rate_timeseries.rds` still reflect the pre-fix behavior, so the new Russia
  snapshot tests fail against the checked-in rev_5 artifact.
- The legal rule is still incomplete in source. Current logic only keys on the
  exporter country and does not model third-country imports that trigger clause
  (8) because Russian primary aluminum was smelted/cast upstream.

## Recommended plan

### Phase 1: Sync the release artifacts

1. Rebuild `snapshot_2026_rev_5.rds` from current HEAD.
2. Rebuild `rate_timeseries.rds` and `metadata.rds` from the updated snapshot
   set.
3. Re-run `Rscript tests/test_rate_calculation.R` and confirm the Russia rev_5
   snapshot assertions pass.

Outcome:
- Published outputs match the current landed source fix for direct Russia
  exporter rows.

### Phase 2: Split the Russia rule into two policy paths

Keep two distinct mechanisms in the code and config:

1. **Direct exporter-country rule**
   - Keep the current `country_surcharges` path for `country == '4621'`.
   - This handles imports that are straightforwardly "the product of Russia."

2. **Clause (8) provenance rule**
   - Add a separate config/input layer for non-Russia exporters that still
     trigger the 200% duty because Russian primary aluminum was smelted
     upstream or the article was cast in Russia.
   - Do not overload `country_surcharges` for this, because it is an exporter
     rule, not an input-origin rule.

Suggested config split:

```yaml
section_232_annexes:
  country_surcharges: ...
  provenance_surcharges:
    - metal_type: aluminum
      rate: 2.0
      applies_to: [annex_1a, annex_1b, annex_3]
      source: "Apr. 2, 2026 proclamation clause (8)"
      proxy_file: "resources/s232_russia_clause8_proxy.csv"
```

## Data-model decision

This is the key design choice.

The tracker stores one scalar `rate_232` per `(hts10, country, revision)` pair.
Clause (8) is shipment-conditional. Within one pair, some imports may trigger
the 200% rule and others may not.

That means there are two viable approaches:

### Option A: Exact legal encoding

Add conditional-rule metadata to the schema instead of forcing everything into a
single scalar rate.

Example fields:
- `clause8_russia_possible`
- `clause8_russia_reason` (`product_of_russia`, `smelted_in_russia`,
  `cast_in_russia`)

Pros:
- Legally faithful.
- Avoids fake precision.

Cons:
- Requires downstream consumers to understand conditional tariff rules instead
  of only a single scalar `rate_232`.

### Option B: Pair-level effective proxy

Stay within the current scalar-rate architecture by adding a calibrated proxy
share for clause (8)-triggering imports within a pair.

Suggested input file:
- `resources/s232_russia_clause8_proxy.csv`

Suggested columns:
- `hts10_or_prefix`
- `country`
- `clause8_share`
- `basis`
- `source`
- `notes`

Then compute:
- direct Russia exporter rows: `rate_232 = pmax(rate_232, 2.0)`
- third-country provenance rows:
  `rate_232 = clause8_share * 2.0 + (1 - clause8_share) * rate_232`

Pros:
- Fits the current schema.
- Produces a usable effective rate for aggregate ETR work.

Cons:
- This is an approximation, not a pure statutory encoding.
- Needs an explicit assumption or calibration source.

Recommendation:
- If the tracker remains primarily an effective-rate engine, use Option B but
  document it clearly as a calibrated proxy.
- If statutory legal fidelity is the priority, use Option A and let downstream
  code handle the conditional logic explicitly.

## Implementation steps

1. Keep the current direct Russia exporter fix as-is.
2. Add a new loader in `src/data_loaders.R` for the clause (8) proxy/metadata
   file.
3. Apply the provenance rule after annex tier assignment and after UK deal
   rates, but before final reporting/export.
4. Restrict the rule to:
   - `metal_type == aluminum`
   - `s232_annex %in% c("annex_1a", "annex_1b", "annex_3")`
   - never `annex_2`
5. Document the modeling choice in `docs/assumptions.md` and `todo.md`.

## Tests to add

1. Fresh rev_5 recompute: Russia chapter 76 Annex I-A/I-B rows are 200%.
2. Fresh rev_5 recompute: Russia aluminum derivatives in Annex I-B are 200%.
3. Annex II Russia rows remain zero except for the existing semi override.
4. Russia steel/copper rows do not inherit the aluminum rule.
5. Third-country row with `clause8_share = 1` gets full 200% under the proxy
   path.
6. Third-country row with `0 < clause8_share < 1` blends correctly under the
   proxy path, if Option B is chosen.
7. Saved `snapshot_2026_rev_5.rds` passes the Russia tests after rebuild.

## Definition of done

- Source and saved artifacts agree for the direct Russia exporter case.
- The repo has an explicit, documented answer for the clause (8) provenance
  path: either exact conditional metadata or an explicit proxy model.
- Russia rev_5 behavior is no longer tracked as a silent mismatch between code,
  tests, and published artifacts.
