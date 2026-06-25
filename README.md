# Tariff Rate Tracker

A project of The Budget Lab at Yale.

Statutory U.S. tariff rates at the `HTS-10 x country` level, built from USITC Harmonized Tariff Schedule archives and related policy resources.

The repository's core product is an interval-encoded tariff panel for the 2025-2026 tariff regime. Daily series and weighted effective tariff rates are derived from that panel. As part of building the tracker, results were compared against prior daily tariff-rate estimates from The Budget Lab's [Tariff-ETRs repository](https://github.com/Budget-Lab-Yale/Tariff-ETRs) and the Tax Policy Center's [Tracking Trump Tariffs](https://taxpolicycenter.org/features/tracking-trump-tariffs). We are grateful to the Tax Policy Center for sharing several snapshots of their model output. These comparisons were used solely for validation and benchmarking, not to construct the production series.

## What this repo produces

The primary output is **`data/timeseries/rate_timeseries.rds`** — a complete `HTS-10 × country` tariff-rate panel with interval encoding (`valid_from` / `valid_until`). This is the full time series of product-country-level statutory tariff rates. To query rates at a specific date:

```r
source('src/core/helpers.R')
ts <- readRDS('data/timeseries/rate_timeseries.rds')
snapshot <- get_rates_at_date(ts, as.Date('2026-06-15'))
```

Additional outputs:

- Per-revision snapshots in `data/timeseries/snapshot_*.rds`
- Daily aggregate series in `output/daily/` (overall, by country, by authority)
- Optional weighted ETR outputs in `output/etr/`
- Validation and diagnostics outputs when benchmark data is available

See [docs/build.md](docs/build.md) for the full output inventory and more query examples.

## Citing this work

If you use this data or build on the methodology, please cite as:

> The Budget Lab at Yale. (2026). *Tariff Rate Tracker*. https://github.com/Budget-Lab-Yale/tariff-rate-tracker

BibTeX:

```bibtex
@software{budget_lab_tariff_tracker_2026,
  author       = {{The Budget Lab at Yale}},
  title        = {Tariff Rate Tracker},
  year         = {2026},
  url          = {https://github.com/Budget-Lab-Yale/tariff-rate-tracker},
  version      = {2026.05.20}
}
```

GitHub's "Cite this repository" widget (top of the repo page) reads
[`CITATION.cff`](CITATION.cff) and offers both APA and BibTeX. If you
need a citable DOI (e.g. for an academic paper), note that Zenodo
integration is deferred.

If you build on this data we'd appreciate hearing about it — open an
issue or email [budgetlab@yale.edu](mailto:budgetlab@yale.edu).

## Start here

- Data sources and provenance: [DATA_SOURCES.md](DATA_SOURCES.md)
- Build and setup: [docs/build.md](docs/build.md)
- Code architecture and data flow: [docs/architecture.md](docs/architecture.md)
- Methodology and tariff-regime history: [docs/methodology.md](docs/methodology.md)
- Non-official assumptions: [docs/assumptions.md](docs/assumptions.md)
- HTS revision chronology: [docs/revision_changelog.md](docs/revision_changelog.md)
- Policy timing vs. HTS dates: [docs/policy_timing.md](docs/policy_timing.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reporting: [SECURITY.md](SECURITY.md)
- Citation metadata: [CITATION.cff](CITATION.cff)

## System requirements

- **R 4.3+** with packages listed in `tools/install_dependencies.R`
- **RAM**: The full pipeline (`--full`) expands a product × country matrix of roughly 19,000 products × 240 countries during rate calculation. **32 GB RAM is recommended.** Machines with 16 GB may run out of memory during the IEEPA broadcasting step in `06_calculate_rates.R`. If you are memory-constrained, you can build individual revisions rather than running `--full`, since each revision is processed independently.
- **Disk**: The `data/` directory (HTS JSON archives + processed snapshots) requires approximately 2 GB.
- **OS**: Tested on Windows 10/11, macOS, and Linux. No platform-specific dependencies.

## Quick start

```bash
Rscript tools/install_dependencies.R --all
Rscript src/pipeline/02_download_hts.R
Rscript src/preflight.R
Rscript src/pipeline/00_build_timeseries.R --full --core-only
```

That sequence builds the core series without requiring private benchmark data or optional weighting inputs.

To publish a build's outputs to the repo (off by default):

- **`--publish-git`** writes a curated subset of outputs to [`release/`](release/) inside the repo, with publication-date suffixes (e.g. `daily_overall_2026-05-21.csv`). Only the latest publication's files are on disk; history is browsable via `git log -- release/`. Public — for downstream consumers reading from GitHub.

```bash
Rscript src/pipeline/00_build_timeseries.R --full --core-only --publish-git
```

Publishing to the Budget Lab's internal shared model-data tree is handled by the
config-driven array flow (`scripts/submit_build_array.sh`), which writes a dated
vintage under `model_data_root`; see [docs/build.md](docs/build.md#publishing)
and [scripts/README.md](scripts/README.md) for layout, vintage rules, and
manifest contents.

## Repository structure

- `src/pipeline/00_build_timeseries.R`: main build orchestrator
- `src/pipeline/09_daily_series.R`: daily aggregate, weighted ETR, and filtered daily export utilities
- `tools/generate_etrs_config.R`: exports tracker rates into Tariff-ETRs-compatible config (`statutory_rates.csv.gz` + `other_params.yaml`)
- `config/policy_params.yaml`: tariff logic and related modeling parameters
- `config/revision_dates.csv`: HTS revision schedule and benchmark date alignment
- `scripts/`: standalone analysis tools (not part of the core pipeline)
- `resources/`: committed supporting datasets and lookup tables

## Current scope

The repo currently models 43 HTS revisions from January 1, 2025 through June 8, 2026, and extends the final interval through December 31, 2026 via the configured series horizon.

## Notes

- The core build does not require TPC or Tariff-ETRs inputs.
- Weighted outputs require local import weights configured in `config/local_paths.yaml`. The build fails loudly if the file is missing and you have not opted out — see [docs/weights.md](docs/weights.md) for how to regenerate the file from Census Bureau monthly imports, or set `weight_mode: unweighted` (or pass `--unweighted`) to skip weighted outputs.
- Some modeling questions remain open, especially around residual floor-country differences versus TPC and the treatment of legacy non-China tariff branches. Those are documented in [docs/methodology.md](docs/methodology.md).
