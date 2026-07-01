# Import Weights

Weighted outputs (weighted ETRs, daily weighted series, partner aggregates,
alternative scenarios) require an HS10 × country × GTAP weight file.

The canonical file is `hs10_by_country_gtap_2024_con.rds` and contains 2024
Census Bureau consumption imports rolled up to HS10 × country, joined with the
in-repo GTAP crosswalk.

| Column | Type | Description |
|---|---|---|
| `hs10` | chr | 10-digit Harmonized Tariff Schedule code (zero-padded) |
| `gtap_code` | chr | GTAP sector, lowercase (e.g. `mvh`, `i_s`) |
| `cty_code` | chr | 4-digit Census country code |
| `imports` | dbl | Annual consumption imports, US dollars |

For the 2024 build the file has ~334k rows, 18.6k HS10 codes, 233 countries,
45 GTAP sectors, and totals roughly $3.12T.

## Failure mode

The build pipeline checks for the weight file as a pre-run step. Behavior on
a missing file:

1. **Default (`weight_mode: required`)** — `00_build_timeseries.R` auto-builds
   the weight file at startup by invoking `src/io/build_import_weights.R`. This
   takes 15-20 minutes one-time (downloads 12 monthly Census ZIPs, parses,
   aggregates). Subsequent builds find the cached file via auto-detect and
   skip this step.
2. **Opt out (`weight_mode: unweighted`, or `--unweighted` CLI flag)** — the
   pre-run step is skipped, weighted outputs are skipped, and the core
   series still builds.

The pre-run step is wired in `src/pipeline/00_build_timeseries.R` right after the HTS
JSON download step. It also runs at the top of `--alternatives-only` mode
(which needs weights). Skipped under `--build-only` and `--core-only` since
neither uses weighted outputs.

If the pre-run auto-build fails (e.g., Census Bureau URL changed), the error
is loud and directs you here. Manual fallback:

```bash
Rscript src/io/build_import_weights.R --year 2024
```

…then re-run the build.

## Building the file from scratch

The repo ships `src/io/build_import_weights.R`, which downloads the 12 monthly
Census Bureau IMDByymm.ZIPs, parses the IMP_DETL.TXT fixed-width files,
aggregates HS10 × country consumption imports, and joins the in-repo GTAP
crosswalk.

```bash
# Default: 2024 consumption imports, output to data/weights/hs10_by_country_gtap_2024_con.rds
Rscript src/io/build_import_weights.R --year 2024

# General imports instead of consumption
Rscript src/io/build_import_weights.R --year 2024 --type gen \
    --out data/weights/hs10_by_country_gtap_2024_gen.rds

# Use already-downloaded ZIPs (skips network)
Rscript src/io/build_import_weights.R --year 2024 \
    --raw-dir /path/to/IMDByymm/cache
```

The pipeline auto-detects this file: any `data/weights/hs10_by_country_gtap_<year>_con.rds`
is picked up automatically on the next build with no further configuration
needed. To override (e.g. point at an external cache), set `import_weights:`
explicitly in `config/local_paths.yaml`:

```yaml
import_weights: ../some-other-repo/cache/hs10_by_country_gtap_2024_con.rds
weight_mode: required
```

`data/weights/` is gitignored — these are large derived artifacts, not source.

### What the script does

1. Resolves the URL for each monthly file from a template (default:
   `https://www.census.gov/trade/downloads/{year}/Merch/im_m/IMDB{yy}{mm}.ZIP`).
2. Downloads any missing monthly ZIP into `--raw-dir`
   (default `data/weights/raw/<year>/`).
3. Reads `IMP_DETL.TXT` from each ZIP using the fixed-width column positions
   for `hs10`, `cty_code`, `year`, `month`, `con_val_mo`, `gen_val_mo`.
4. Filters to the target year, drops chapters 98–99 (special provisions and
   Chapter 99 lines that don't represent ordinary import flows), and aggregates
   to HS10 × country.
5. Left-joins `resources/hs10_gtap_crosswalk.csv` for GTAP sector mapping,
   lowercases the GTAP code, and drops the small residual of HS10 codes that
   don't match the crosswalk.
6. Writes the RDS and (unless `--keep-zips`) deletes the source ZIPs.

### If Census moves the files

The Census Foreign Trade Reference catalog publishes the URL pattern. If they
re-organize it (this has happened before), override the template:

```bash
Rscript src/io/build_import_weights.R --year 2024 \
    --url-template 'https://example.gov/.../IMDB{yy}{mm}.ZIP'
```

The placeholders are `{year}` (4-digit), `{yy}` (2-digit), `{mm}` (2-digit
month). You can also download the ZIPs manually and pass `--raw-dir` pointing
at the cache directory.

The Census foreign-trade landing page is:
<https://www.census.gov/foreign-trade/data/index.html>.

### Crosswalk maintenance

`resources/hs10_gtap_crosswalk.csv` covers ~18.7k HS10 codes mapped to 53 GTAP
sectors. New HS10 codes appearing in a future year's import data may be
unmapped — the build script will warn about the count of unmapped rows.

To extend the crosswalk, the upstream Tariff-ETRs repo has
`scripts/update_crosswalk.R` which fills in missing codes via HS6 → HS4 → HS2
fallback. Re-run it there, then copy the updated CSV into
`resources/hs10_gtap_crosswalk.csv`.

## Validation

A reasonable sanity check after building:

```r
x <- readRDS('data/weights/hs10_by_country_gtap_2024_con.rds')
stopifnot(
  is.character(x$hs10), all(nchar(x$hs10) == 10),
  is.character(x$cty_code),
  sum(x$imports) > 2e12  # 2024 consumption imports are ~$3.1T
)
```

---

# Published panel-keyed import weights (`<vintage>/weights/`)

The file above (`hs10_by_country_gtap_2024_con.rds`) is keyed on the HTS
statistical-suffix vintage that *traded in 2024*. The published rate panel is
enumerated from the *current* HTS revision. USITC/Census split, merge, and
renumber 10th-digit suffixes between vintages, so a chunk of 2024 import value
sits on retired 10-digit codes with no exact match in the current panel
(~5.2% / ~$164B against the current vintage). A downstream model that wants to
import-weight the rate panel up to GTAP/BEA can't join the two cleanly.

So each published vintage also ships an import-weight base **re-keyed to the
tracker's own current HTS10 universe**, under `<vintage>/weights/`:

| File | Contents |
|---|---|
| `import_weights_hs10_country.parquet` | the weight base (primary) |
| `import_weights_hs10_country.csv.gz` | identical rows, CSV fallback |
| `hts10_revision_crosswalk.csv` | the forward map applied to retired codes (audit / reuse) |

`import_weights_hs10_country.parquet` schema:

| Column | Type | Description |
|---|---|---|
| `hts10` | chr | 10-digit code, drawn from the **current** rate-panel vintage |
| `country` | chr | 4-digit U.S. Census `cty_code` — same code system as the rate panel's `country` |
| `imports` | dbl | 2024 customs-value imports, **raw USD** |
| `import_value_year` | int | `2024` |
| `hts_vintage` | chr | revision the codes are keyed to (the latest interval's revision) |

No GTAP/BEA codes are added — that bucketing stays on the consumer's side by
design. Zero-import panel pairs are omitted (a consumer treats a missing pair
as weight 0).

## The forward-map

Built by `src/io/build_panel_import_weights.R`, called automatically from
`src/io/write_output.R` when a vintage is published. It is deterministic:

1. **Target universe = the current vintage's codes** — the *latest* interval's
   HS10 set (`current_panel_codes()`), i.e. "the current HTS codes". A vintage
   is a time series of snapshots whose code set drifts as suffixes renumber, so
   the union of all intervals is *not* a single point in time; only the tip is.
2. Every 2024 code that **exists** in that universe is kept verbatim.
3. Every 2024 code that **doesn't** (a retired suffix) has its value
   redistributed onto the panel codes sharing its longest common HTS prefix —
   **HS8 heading first**, then HS6 subheading, HS4 heading, HS2 chapter, and a
   whole-panel split as a last resort. Within a prefix group the split is
   proportional to each target's own directly-matched 2024 value (the suffixes
   that actually absorb the trade); even split if none traded. Country is
   preserved throughout.

This **conserves the dollar total exactly** (orphan value is moved, never
dropped) and guarantees **every output code is in the current panel**. Against
the live current vintage: 94.75% of value matches exactly, ~99.8% recovers at
the HS8 heading, and the cascade lands the remainder within the correct
chapter — so the rollup joins the current rate panel **100%** on
`(hts10, country)`. Older intervals match ≥99.6% (their codes predate later
renumbering — inherent to one frozen 2024 base, not a defect).

`hts10_revision_crosswalk.csv` (`old_hts10, new_hts10, split_weight, level`)
records only the remapped (retired) codes; `split_weight` sums to 1 per
`old_hts10`. Codes absent from it mapped to themselves. A consumer can apply it
to its own copy of the 2024 base to reproduce the re-keying.

## (Re)building for an already-published vintage

`publish_internal.R` emits `weights/` on every publish, but you can (re)build it
against an existing published vintage without a rebuild:

```bash
module load R/4.4.2-gfbf-2024a
Rscript src/io/build_panel_import_weights.R \
    --vintage-dir /nfs/.../Tariff-Rate-Tracker/latest
# --base <rds>  override the 2024 base (default: auto-detect data/weights/)
# --out-dir <dir>  default <vintage-dir>/weights ; --dry-run to validate only
```

The builder hard-fails if value is not conserved or any output code falls
outside the panel, so a bad run can't publish silently.
