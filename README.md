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
- Policy timing vs. HTS dates: [docs/policy_timing.md](docs/policy_timing.md)

## System requirements

- **R 4.3+** with packages listed in `src/install_dependencies.R`
- **RAM**: The full pipeline (`--full`) expands a product × country matrix of roughly 19,000 products × 240 countries during rate calculation. **32 GB RAM is recommended.** Machines with 16 GB may run out of memory during the IEEPA broadcasting step in `06_calculate_rates.R`. If you are memory-constrained, you can build individual revisions rather than running `--full`, since each revision is processed independently.
- **Disk**: The `data/` directory (HTS JSON archives + processed snapshots) requires approximately 2 GB.
- **OS**: Tested on Windows 10/11, macOS, and Linux. No platform-specific dependencies.

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
- `src/generate_etrs_config.R`: exports tracker rates into Tariff-ETRs-compatible config (`statutory_rates.csv.gz` + `other_params.yaml`)
- `config/policy_params.yaml`: tariff logic and related modeling parameters
- `config/revision_dates.csv`: HTS revision schedule and benchmark date alignment
- `scripts/`: standalone analysis tools (not part of the core pipeline)
- `resources/`: committed supporting datasets and lookup tables

## Current scope

The repo currently models 38 HTS revisions from January 1, 2025 through February 24, 2026, and extends the final interval through December 31, 2026 via the configured series horizon.

## Notes

- The core build does not require TPC or Tariff-ETRs inputs.
- Weighted outputs require local import weights configured in `config/local_paths.yaml`.
- Some modeling questions remain open, especially around residual floor-country differences versus TPC and the treatment of legacy non-China tariff branches. Those are documented in [docs/methodology.md](docs/methodology.md).
