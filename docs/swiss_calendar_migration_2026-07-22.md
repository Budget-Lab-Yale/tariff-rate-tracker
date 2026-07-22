# Swiss calendar migration validation — 2026-07-22

- Reference: `post-merge/2026-07-22-13`.
- Sealed candidate: `swiss-calendar-candidate/2026-07-22-16`.
- Independent rebuild: `swiss-calendar-parity/2026-07-22-17`.
- Local regression suite: 36/36 files passed; zero failures.
- Candidate production checks: 91 passed, 22 data-dependent skips, zero failures; external verifier 11/11.
- Migration structure checks: 132/132 passed.
- Migration parity: actual 59/59 and `new_301` 59/59 passed.
- Intended migration delta: four Swiss metadata columns and `valid_from=2026-04-01/rates.parquet`.
- Daily outputs were unchanged.
- Independent strict parity: actual 60/60 and `new_301` 60/60 passed, with no exclusions or schema allowances.
