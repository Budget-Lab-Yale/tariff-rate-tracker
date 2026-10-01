<!-- PR body for feat/ingest-2026-rev13 (the 2026-08 integration train) — paste into GitHub, then delete this file -->
## What

Integration train on top of the rev_13 ingest: closes the **M0 endnote-collapse
blocker** with evidence, verifies the **rev_13/rev_15 ingest acceptance
criteria** as standing tests, and — found *by* that verification — fixes a
**live rate error**: HTML markup in USITC's `general` field defeats the
base-rate parser, so 21 ch-87 HTS10s carry `base_rate = 0` where real MFN
rates apply. Plus the guards that make each of these failure modes loud in the
future, and one baseline-neutral engine extension.

26 files, +1,855 / −120 vs `master`. The original rev_13 ingest scope is
documented separately in [`docs/internal/rev13_pr_body.md`](rev13_pr_body.md).

## Rate impact — read this first

**Exactly one commit changes computed rates: `6065f3b`.** Everything else is
tests, tooling, docs, or dormant machinery, and the branch's own parity runs
prove it (below).

USITC intermittently ships rate strings with markup, and every rate matcher
anchors on `^[0-9.]+%$`:

```
2.5% <u></u>   ->  base_rate_type 'other', base_rate 0.000    rev_12, rev_15
2.5%           ->  ad_valorem,             base_rate 0.025    rev_13
```

The markup **flickers across revisions** (2025 rev_4/6/10/14; 2026
rev_9/11/12/15), square-waving base/total on 21 HTS10s (8708.\* motor-vehicle
parts, 8712.00.50 bicycles, 8714.9\* parts) — 5,040 rows per affected
partition. Downstream, net-of-MFN arms subtract the zeroed base: `rate_232`
charges 15% where 12.5% is correct. `target_total` programs roughly cancel the
error in the total, which is why it survived until a partition-parity run
flagged `base_rate` moving on exactly one partition — the one owned by rev_13,
the only clean revision in its window.

The fix strips markup in the parse path (`normalize_schedule_text()`, moved
from the changelog tool into `src/core/helpers.R` — one definition). Archives
stay raw. Regression test scans all 47 committed archives, not fixtures
(fixtures are clean — a fixture test would have passed throughout), and is
verified discriminating: against the pre-fix classifier it finds 12 offenders
in rev_12 and rev_15, 0 in rev_13.

**Not yet published**: the fix gets its own vintage + parity review (rebuild in
flight). This PR changes the engine; it does not repoint `latest`.

## M0 (endnote collapse) — resolved, evidence committed

rev_13 dropped 98.8% of the `"See 9903.88.15"`-style cross-reference endnotes
(10,411 → 127). All four required steps closed:

| Step | Evidence |
|---|---|
| Durable §301 exclusion scope | already landed on master (`s301_exclusion_lines.csv`) |
| Parity: no China §301 rate moved | 20,422 rows identical, aggregate delta 0 — **non-vacuous**: same comparison sees `rate_s301fl` go 0 → 1,217,435 rows (`scripts/verify_m0_s301_parity.R`, Slurm 21669551/21669780) |
| Real removal vs serializer defect | **real removal**: per-release ch.1/27/42/63/71/97 PDFs agree with the JSON code-for-code; the deletion is surgical (9903.88 10,319→5 while 9903.90 holds at exactly 680 in the *same footnote class*) |
| Standing assertion | `tools/footnote_audit.R` + `config/footnote_waivers.csv` + test: any unwaived per-class move >10% fails |

## Ingest acceptance (Phase 2 §7) — now standing tests

`tests/test_hts_2026_rev13_rev15_ingest.R` (11 assertions) guards the deliberate
oddity that will otherwise get "fixed" into a bug: **there is no `2026_rev_14`
build row** (its JSON is permanently unobtainable; the pipeline silently skips
archive-less rows), and the July-31 policy state rides on the synthetic
`bnd_2026-07-31` boundary owned by rev_13. Also asserted: all ten
`9903.04.60-.69` pharma headings in both surviving sources, and rev_15's
change record listing exactly one modified item (`9903.04.63`, the UK
correction → config `CTY_UK: 0`).

Partition parity vs published vintage `2026-07-24-09`
(`scripts/verify_partition_parity.R`): **40 identical, 17 differing, 3 new, 0
missing** — every difference attributed (Solar 201 termination from 02-07 with
totals moving by exactly −0.145; pharma/UK activation at 09-29/11-10; the
markup bug at 07-31). Nothing before rev_13 differs for any other reason.

## Also in this train

- **Reststop per-release downloader** (`02_download_hts.R --release-file`):
  the file endpoint honors `release=<ID>` (verified — different md5 per
  release), unlike `exportList` which silently ignores it. Only route to
  archived-release attribution; validates `%PDF` magic since errors come back
  HTTP 200.
- **Changelog markup normalization**: cosmetic-only edits counted and excluded
  (63 at rev_13, 73 at rev_15) instead of drowning the diff.
- **Preflight**: asserts every configured revision has an archive (47/47) —
  a missing one previously meant a silently shorter series.
- **Build sizing re-measured**: 192G OOM'd at 60 revisions (job 21739576,
  killed at 201G); now 384G/6h with the measurement recorded (MaxRSS 234G,
  3h15m, job 21784088).
- **Origin-keyed rate-map machinery** (`b21df19`): `us_auto_content_share`
  accepts an origin-keyed map; `ieepa_fentanyl_rate_caps` caps parsed fentanyl
  rates when configured. Both dormant in the baseline (verified 122/0 + 53/0);
  consumers are scenario overlays outside this repo.
- **Latent, recorded not fixed** (todo.md): two more anchored `^N%$` matchers
  read un-normalised text (`parse_ch99_rate()` bare-`N%` arm; §232 auto floor
  classifier). Empirically safe today — ch99 fields carry zero markup across
  all 47 archives.
- todo.md: MRS replication spec moved to its own workstream (pointer remains);
  CI fix for the polysilicon heading-gate test mirror (the sole failure in
  master run 206).

## Where review effort pays

1. `src/core/helpers.R` — `normalize_schedule_text()` placement and its use in
   `parse_rate()` / `is_simple_rate()` / `classify_rate_type()`. The tag
   pattern is deliberately `<[^>]*>`, not an allowlist (real data contains a
   malformed `</il>`).
2. `config/footnote_waivers.csv` — the waiver *reasons* are load-bearing
   documentation of the M0 finding.
3. `scripts/verify_partition_parity.R` — the zero-comparison and <50%-coverage
   hard-fails exist because the first run keyed on an all-NA column, compared
   nothing, and exited 0.
4. The rev_14-gap test — confirm you agree the missing row is a feature.

## Test status

Full suite on this branch: **40 passed / 0 failed** in CI conditions (the two
local-only failures are a stale ch99-cache mint-set expectation that CI skips,
and pdftools needing the poppler module on the cluster). CI should go green —
including master's currently-red run 206, fixed here.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
