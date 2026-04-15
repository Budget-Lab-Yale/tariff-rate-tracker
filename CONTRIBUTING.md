# Contributing

Thanks for taking a look at the Tariff Rate Tracker.

This repository mixes core tariff logic, committed resource files, and large regenerated artifacts. A small amount of setup and review discipline goes a long way toward keeping changes reproducible and easy to verify.

## Before you start

- Read [README.md](README.md) for the repo overview.
- Use [docs/build.md](docs/build.md) for setup and build modes.
- Read [docs/architecture.md](docs/architecture.md) for the code structure, data flow, and how to add a new tariff authority.
- Review [docs/methodology.md](docs/methodology.md) and [docs/assumptions.md](docs/assumptions.md) before changing tariff logic or committed resource files.
- For provenance questions, start with [DATA_SOURCES.md](DATA_SOURCES.md).

## Development setup

```bash
Rscript src/install_dependencies.R --all
Rscript src/02_download_hts.R
Rscript src/preflight.R
```

Optional local-only inputs live in `config/local_paths.yaml`. Start from `config/local_paths.yaml.example` if you need weighted outputs or comparison workflows.

## Validation

Before opening a pull request, run the full test suite:

```bash
Rscript src/preflight.R
Rscript tests/run_tests_daily_series.R
Rscript tests/test_rate_calculation.R
```

If your change affects benchmark comparison logic or methodology-sensitive outputs, also run the most relevant deeper checks for that area. Examples include:

- `Rscript tests/test_tpc_comparison.R`
- `Rscript src/00_build_timeseries.R --full --core-only`
- targeted scrapers or diagnostics under `src/` and `scripts/`

## Pull requests

- Keep pull requests focused on one topic when possible.
- Include a short explanation of the policy or data change, not just the code change.
- If you change tariff logic, note the affected authority, dates, or product scope.
- If you update a committed resource file, describe where the new data came from and how it was regenerated.
- If you change outputs or methodology, update the relevant docs in `docs/`.

## Data and generated files

- Do not commit secrets, API tokens, or local config such as `.env` and `config/local_paths.yaml`.
- Do not commit ad hoc scratch scripts or local analysis notes unless they are intended to become part of the maintained repo.
- Large generated artifacts under `data/processed/`, `data/timeseries/`, and `output/` are usually rebuildable and should only be committed when the project intentionally tracks them.
- Comparison-only inputs from external projects or unpublished snapshots should not be redistributed unless their terms clearly allow it.

## Style notes

- Prefer small, explicit changes over broad refactors.
- Keep file paths repo-relative in docs.
- When behavior changes, add or update tests close to the affected code path.
- Preserve existing naming and tidyverse-oriented style unless there is a strong reason to standardize differently.

## Questions and proposals

For straightforward bugs or doc fixes, opening an issue or pull request directly is fine.

For broader methodology changes, new data sources, or major refactors, open an issue first so the policy, provenance, and maintenance tradeoffs can be discussed before implementation.
