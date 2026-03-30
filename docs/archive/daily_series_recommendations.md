# Recommendations for a Daily HTS-10 x Country Tariff Series Through End-2026

## Purpose

This memo proposes changes to the repository so it can reliably produce a daily tariff-rate series from January 1, 2025 through December 31, 2026 at the `hts10 x country x day` level, while keeping storage and compute costs manageable.

The current codebase is already strong at constructing revision-level `hts10 x country` snapshots. The main gaps are:

1. The built time series stops at the build date rather than extending through the target horizon.
2. The persisted daily outputs are aggregated, not product-country level.
3. The ad hoc daily expansion path does not apply the Section 122 expiry adjustment.
4. Large daily outputs need a storage and access strategy, not just a naive CSV export.

## Recommended Outcome

The repo should support two distinct products:

1. A canonical interval dataset at `hts10 x country` level with `valid_from` and `valid_until`.
2. A derived daily dataset at `date x hts10 x country`, generated either:
   - fully, in a columnar partitioned format, or
   - on demand for requested date/country/product subsets.

The interval dataset should remain the source of truth. The daily dataset should be treated as a delivery artifact optimized for downstream consumption.

## Proposed Changes

### 1. Add an explicit projection horizon

The last revision should not end at `Sys.Date()`. Instead, the build should support a configurable horizon, defaulting to `2026-12-31`.

Recommended changes:

- Add a config value such as `series_horizon.end_date: '2026-12-31'` in [config/policy_params.yaml](config/policy_params.yaml).
- In [src/00_build_timeseries.R](src/00_build_timeseries.R), replace the final `valid_until = Sys.Date()` logic with:
  - `lead(effective_date) - 1` for non-final revisions
  - `series_horizon.end_date` for the last revision
- Add a guard so the horizon cannot be earlier than the final revision’s `effective_date`.

Rationale:

- This makes future dates queryable through the end of 2026.
- It decouples build date from policy horizon.
- It makes the output reproducible across machines and days.

### 2. Keep interval rows as the canonical storage layer

The repository should continue to store the full panel primarily as interval rows, not as fully exploded daily CSVs.

Recommended changes:

- Preserve [data/timeseries/rate_timeseries.rds](data/timeseries/rate_timeseries.rds) as the canonical dataset.
- Consider adding a columnar equivalent such as `rate_timeseries.parquet`.
- Document that the interval form is the authoritative source for all downstream daily products.

Rationale:

- Rates are piecewise constant between revision dates.
- Interval storage is dramatically smaller than daily storage.
- Most analytical workflows can derive daily values from intervals when needed.

### 3. Build a real product-country-day export path

The repo needs a dedicated function for generating a daily `hts10 x country x day` dataset, rather than relying on the current ad hoc `expand_to_daily()` helper.

Recommended changes:

- Add a new function in [src/09_daily_series.R](src/09_daily_series.R), for example:
  - `build_daily_product_country(ts, date_range, countries = NULL, products = NULL, policy_params = NULL, format = 'parquet')`
- This function should:
  - start from the interval dataset
  - clip rows to the requested date range
  - expand only the requested subset, or all rows if explicitly requested
  - apply all post-expansion policy adjustments consistently
  - write output in a scalable format

The function should not default to writing a giant CSV. It should require either:

- a subset request, or
- an explicit `full_export = TRUE` flag.

Rationale:

- The current helper is useful for analysis but not robust enough to be the delivery path.
- A separate explicit export function makes large-output behavior deliberate.

### 4. Apply Section 122 expiry consistently everywhere

Section 122 expiry handling should be centralized and reused by:

- aggregate daily outputs
- point-in-time queries
- product-country daily expansion

Recommended changes:

- Add a helper in [src/helpers.R](src/helpers.R), for example:
  - `apply_post_interval_adjustments(df, query_date = NULL, date_col = NULL, policy_params)`
- This helper should:
  - zero `rate_s122` after the configured expiry date when `finalized = false`
  - recompute `total_additional` and `total_rate` using `apply_stacking_rules()`
- Refactor:
  - `get_rates_at_date()`
  - `build_daily_aggregates()`
  - the future daily product-country export function
  so they all use the same helper.

Rationale:

- This removes drift between aggregate and product-level outputs.
- It reduces the risk of future policy-expiry bugs.

### 5. Decide and document the post-last-revision assumption

If no new HTS revisions arrive after February 24, 2026, the system must make an explicit assumption for the remainder of 2026.

Recommended approach:

- Treat the last known revision as remaining in force through the configured horizon.
- Continue to apply date-bounded overrides after expansion:
  - Section 122 expires on July 23, 2026 unless `finalized = true`
  - any other temporary program windows should be handled the same way
- Add this assumption prominently to methodology docs and output metadata.

Suggested metadata fields:

- `projection_horizon_end`
- `last_observed_revision`
- `last_observed_revision_date`
- `projected_beyond_last_revision`
- `policy_params_hash`

Rationale:

- Consumers need to know where observed HTS revisions end and projection begins.
- This improves transparency without blocking use of the dataset.

## Large Dataset Strategy

## Why the full daily panel is large

A full panel is roughly:

- about 19,000 to 20,000 products
- about 240 countries
- 730 days for 2025-01-01 through 2026-12-31

That implies on the order of 3.3 to 3.5 billion rows if fully expanded.

Even with narrow columns, this is too large for routine CSV workflows and inconvenient as a single monolithic RDS.

## Recommended storage approach

### Preferred: partitioned Parquet dataset

Write the daily panel as partitioned Parquet, for example:

- `output/daily_product_country/year=2025/month=01/*.parquet`
- `output/daily_product_country/year=2025/month=02/*.parquet`
- `output/daily_product_country/year=2026/month=12/*.parquet`

Recommended partition keys:

- `year`
- `month`

Optional secondary partitioning if needed:

- partner group
- country

Avoid partitioning by day or product because that will create too many tiny files.

Rationale:

- Parquet is much smaller than CSV.
- Downstream tools can read only the needed partitions and columns.
- It works well with R, Python, DuckDB, Arrow, and Spark-like workflows.

### Keep column set narrow

The daily export should include only fields needed for downstream use by default:

- `date`
- `hts10`
- `country`
- `base_rate`
- `rate_232`
- `rate_301`
- `rate_ieepa_recip`
- `rate_ieepa_fent`
- `rate_s122`
- `rate_section_201`
- `rate_other`
- `total_additional`
- `total_rate`
- `revision`

Optional fields should be excluded unless explicitly requested:

- `metal_share`
- `usmca_eligible`
- audit columns
- descriptive labels joined from lookup tables

Rationale:

- A narrow schema materially reduces file size.
- Labels can be joined later from dimension tables.

### Publish dimensions separately

Instead of repeating descriptions on every row, publish lookup tables:

- product dimension: `hts10`, description, chapter, hs8, hs6
- country dimension: `country`, country_name, partner_group
- revision dimension: revision metadata and effective dates

Rationale:

- Star-schema style outputs are smaller and easier to maintain.

## Recommended access patterns

### Tier 1: canonical interval file

Use for:

- rebuilding downstream products
- auditing policy logic
- precise point-in-time queries

Format:

- `RDS` for native R workflows
- `Parquet` for cross-tool access

### Tier 2: precomputed daily aggregates

Use for:

- dashboards
- high-level charts
- country-level and authority-level monitoring

Current outputs already fit this tier well:

- [output/daily/daily_overall.csv](output/daily/daily_overall.csv)
- [output/daily/daily_by_country.csv](output/daily/daily_by_country.csv)
- [output/daily/daily_by_authority.csv](output/daily/daily_by_authority.csv)

### Tier 3: partitioned daily product-country dataset

Use for:

- model inputs
- event studies
- tariff incidence analysis
- partner and product filtering

Format:

- partitioned Parquet dataset, not CSV

### Tier 4: on-demand extraction tools

Provide helpers for users who need only slices:

- one country across all products and days
- one product across all countries and days
- one date across all products and countries
- one revision interval only

Recommended functions:

- `get_rates_at_date(ts, date, policy_params)`
- `export_daily_slice(ts, start_date, end_date, countries = NULL, products = NULL, out_path)`

Rationale:

- Most users do not need the full 3B+ row panel.
- Sliced extraction will be much faster and cheaper.

## Additional Logic Changes

### 6. Include Section 201 in authority decomposition outputs

Current total-rate logic includes Section 201, but authority decompositions do not expose it cleanly.

Recommended changes:

- In [src/helpers.R](src/helpers.R), extend `compute_net_authority_contributions()` to include `net_section_201`.
- In [src/09_daily_series.R](src/09_daily_series.R), add `mean_section_201` and `etr_section_201` to authority outputs.
- In [src/08_weighted_etr.R](src/08_weighted_etr.R), ensure authority-level summaries and plots include Section 201.

Rationale:

- Authority totals should reconcile to `total_additional`.
- Missing authority buckets make interpretation harder.

### 7. Add horizon and expiry tests

This area needs direct tests because the bugs are temporal and easy to miss.

Recommended tests:

1. Final revision gets `valid_until = 2026-12-31`, not `Sys.Date()`.
2. `get_rates_at_date()` returns non-empty results for a future date such as `2026-12-15`.
3. Product-country daily expansion zeroes `rate_s122` on `2026-07-24` and later when `finalized = false`.
4. Daily aggregate and daily product-country outputs agree on dates around `2026-07-23`.
5. Authority decomposition sums to `total_additional`, including Section 201.

Recommended test style:

- small synthetic fixtures
- one or two revisions
- one country with S122 and one without
- one product with 232 interaction and one without

## Suggested Implementation Order

### Phase 1: correctness

1. Add `series_horizon.end_date` config.
2. Extend the final interval through `2026-12-31`.
3. Centralize Section 122 expiry adjustments.
4. Add tests for future-date queries and expiry behavior.

### Phase 2: delivery

1. Create a dedicated daily `hts10 x country x day` export function.
2. Write output as partitioned Parquet.
3. Add metadata and dimension tables.
4. Update README and methodology docs.

### Phase 3: performance

1. Benchmark full expansion by month.
2. Tune partition sizes and file counts.
3. Add slice-based export helpers.
4. Consider DuckDB or Arrow-backed workflows for user queries.

## Practical Export Options

To keep usage flexible, I recommend supporting three export modes:

### Mode A: full build

- Builds the entire `2025-01-01` to `2026-12-31` daily panel
- Writes partitioned Parquet
- Intended for batch pipelines only

### Mode B: monthly build

- Builds and writes one month at a time
- Better for memory control and resumability
- Recommended default for the full export job

### Mode C: slice build

- Builds only requested countries/products/dates
- Best for research workflows and debugging

Monthly build is likely the best default implementation because it avoids holding the entire expanded dataset in memory at once.

## Documentation Changes

Update:

- [README.md](README.md)
- [docs/methodology.md](docs/methodology.md)

Add documentation for:

- projection horizon behavior
- the distinction between observed revisions and projected validity windows
- available output tiers
- recommended query patterns for large data
- Parquet partition layout

## Bottom Line

The repo does not need a new tariff-construction methodology. It needs:

- a configurable future horizon
- consistent post-expiry adjustment logic
- a first-class product-country daily export path
- a storage strategy built around interval data plus partitioned Parquet delivery

That combination will make the project capable of serving the requested `country x product x day` dataset through December 31, 2026 without forcing all users into an unmanageable flat file workflow.
