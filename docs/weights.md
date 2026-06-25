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
