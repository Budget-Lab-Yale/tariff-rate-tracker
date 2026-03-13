# Tariff Rate Tracker

A project of The Budget Lab at Yale.

Statutory U.S. tariff rates at the `HTS-10 x country` level, built from USITC Harmonized Tariff Schedule archives and related policy resources.

The repository's core product is an interval-encoded tariff panel for the 2025-2026 tariff regime. Daily series and weighted effective tariff rates are derived from that panel. As part of building the tracker, results were compared against prior daily tariff-rate estimates from The Budget Lab's [Tariff-ETRs repository](https://github.com/Budget-Lab-Yale/Tariff-ETRs) and the Tax Policy Center's [Tracking Trump Tariffs](https://taxpolicycenter.org/features/tracking-trump-tariffs). We are grateful to the Tax Policy Center for sharing several snapshots of their model output. These comparisons were used solely for validation and benchmarking, not to construct the production series.

## What this repo produces

- A revision-by-revision tariff panel in `data/timeseries/`
- Daily aggregate series in `output/daily/`
- Optional daily product-country extracts
- Optional weighted ETR outputs in `output/etr/`
- Validation and diagnostics outputs when benchmark data is available

## Start here

- Build and setup: [docs/build.md](docs/build.md)
- Methodology and tariff-regime history: [docs/methodology.md](docs/methodology.md)
- Non-official assumptions: [docs/assumptions.md](docs/assumptions.md)
- HTS revision chronology: [docs/revision_changelog.md](docs/revision_changelog.md)

## Quick start

```bash
Rscript src/preflight.R
Rscript src/install_dependencies.R --all
Rscript src/02_download_hts.R
Rscript src/00_build_timeseries.R --full --core-only
```

That sequence builds the core series without requiring private benchmark data or optional weighting inputs.

## Repository structure

- `src/00_build_timeseries.R`: main build orchestrator
- `src/09_daily_series.R`: daily aggregate and filtered daily export utilities
- `src/08_weighted_etr.R`: weighted ETR outputs when import weights are configured
- `config/policy_params.yaml`: tariff logic and related modeling parameters
- `config/revision_dates.csv`: HTS revision schedule and benchmark date alignment
- `resources/`: committed supporting datasets and lookup tables

## Current scope

The repo currently models 39 HTS revisions from January 1, 2025 through February 25, 2026, and extends the final interval through December 31, 2026 via the configured series horizon.

## Notes

- The core build does not require TPC or Tariff-ETRs inputs.
- Weighted outputs require local import weights configured in `config/local_paths.yaml`.
- Some modeling questions remain open, especially around residual floor-country differences versus TPC and the treatment of legacy non-China tariff branches. Those are documented in [docs/methodology.md](docs/methodology.md).
