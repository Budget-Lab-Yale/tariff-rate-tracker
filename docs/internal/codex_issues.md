# Codex Review Issues

## Findings

1. **High: Swiss/Liechtenstein floor framework still turns on late.**
   `config/policy_params.yaml` sets `swiss_framework.effective_date` to `2025-11-14`, and `src/authority_adapter.R` gates the floor override on `rev_date >= swiss_fw$effective_date`. But `src/timeline.R` only adds the Swiss `expiry_date`, not the `effective_date`, to boundary discovery. Since `2025-11-14` falls inside the `rev_29` interval, no `bnd_2025-11-14` mint is created, so the floor appears only at the next real revision. This can publish wrong CH/LI rates for roughly `2025-11-14` through `2025-11-20`.

2. **Medium: boundary/timeline tests are stale and currently fail.**
   The code now intentionally adds `2026-09-29` as a pharma boundary override in `config/policy_params.yaml`. But `tests/test_boundary_discovery.R` and `tests/test_timeline_realdata.R` still assert the exact old three-boundary set. Both fail because discovery returns four mints: `2025-03-12`, `2026-02-20`, `2026-09-29`, `2026-11-10`.

3. **Low: `list_revisions.R` is no longer a cheap/noisy preflight.**
   `scripts/list_revisions.R` now calls `build_array_revision_timeline()`, which scans archives via `src/timeline.R`. It completed and wrote 46 rows, but it parsed every HTS archive and emitted a large amount of diagnostics. That is operationally risky for a Slurm preflight with a 10-minute walltime.

## Checks Run

Passed:
`test_forced_labor_scenario.R`, `test_resolved_programs.R`, `test_publish_snapshots.R`, `test_timeline_invariants.R`, `test_authority_adapter.R`, `test_stacking.R`, `test_policy_from_specs.R`, `test_scenario_ops.R`, and `scripts/list_revisions.R`.

Failed:
`test_boundary_discovery.R` and `test_timeline_realdata.R`, both due to stale expected boundary sets.

Incomplete:
`test_rate_calculation.R` was killed with exit `137` during the heavier Annex-era section after many earlier assertions passed. That looks like resource pressure, not an assertion failure, but it is not a clean pass.
