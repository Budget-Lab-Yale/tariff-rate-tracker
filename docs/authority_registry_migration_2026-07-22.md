# Authority registry migration validation — 2026-07-22

- Change: one R-code registry now owns shared authority rate/net columns, spec
  keys, default stacking classes, panel/schema placement, and reporting census.
- Intended result: structural simplification only; no policy or numerical change.
- Local regression suite: 37/37 files passed; zero failures.
- Production candidate: `authority-registry-candidate/2026-07-22-19`.
- Production verifier: 11/11 passed.
- Strict parity reference: `swiss-calendar-parity/2026-07-22-17`.
- Strict parity: actual 60/60 and `new_301` 60/60 artifacts passed.
- Coverage per series: 55 snapshots plus all five daily report families.
- No ignored columns, schema allowances, or intentional deltas.
