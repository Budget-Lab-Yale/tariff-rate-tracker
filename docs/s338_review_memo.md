# §338 Canada implementation review — findings and remediation plan

**Reviewed 2026-07-20** (branch `s338-ca`, at commit `2119810`). Scope: accuracy
of the Section 338 Canada implementation (three proclamations signed 2026-07-20,
+50% ad-valorem on products of Canada over three positive HTS-8 lists, effective
2026-08-19). Method: an 8-angle finder sweep over the branch diff, each candidate
verified against the source proclamation text (`data/s338/text/`) and the code by
an independent adversarial pass.

**Headline: the core mechanics are correct.** Additive stacking, `usmca='none'`,
the +50% rate, the 2026-08-19 date-gate, and the note-51(c) §232 full-exclusion
scope mask (including the "annex_2 still pays" fix from the codex cross-check)
all match the proclamation text. The annex lists (63 alcohol / 52 dairy / 439
motor-vehicles + 554 GN6, 28 mv overlap) parse cleanly and reconcile with the
source PDFs. The defects below are at the edges — a downstream export, a
counterfactual scenario, the GN6 aircraft scaling, and several latent-fragility
gaps — not in the central rate construction.

Findings are ranked by severity. Numbering is stable and is referenced by the
commits that fix each item.

## Live bugs (wrong output on a current build)

### 1. The entire Canada +50% layer is dropped from the ETRs export

`tools/generate_etrs_config.R` (`export_statutory_rates`, the "lossless
interface" that writes `statutory_rates.csv.gz`) was never updated for §338 —
the string `s338` appears nowhere in the file. `statutory_rate_s338` is missing
from the required-column check (`:175`), the export `transmute` (`:371`), and the
sparse-row filter's `rate_cols` (`:463`). For any snapshot dated ≥ 2026-08-19
the Canada duty is silently absent downstream, **and** the
`filter(if_any(all_of(rate_cols), ~ . > 0))` step drops every Canada row whose
only positive duty is §338 (whisky, dairy, the 439 mv-list codes) — so those
rows do not even appear in the export. Most severe finding: the new tariff is
invisible to the ETRs consumer.

### 2. The `pre_2025` counterfactual applies the 2026 duty

`config/scenarios/pre_2025/overlay.yaml` lists
`disabled_authorities: [ieepa_reciprocal, ieepa_fentanyl, section_122]` but omits
`section_338`. §338 is a baseline authority, zeroed only by the step-7g
kill-switch reading that list; the scenario spans 2025–26 by design ("pre-2025
authorities, not pre-2025 rates"), so a `pre_2025` build applies the Canada +50%
from 2026-08-19, inflating a series meant to be flat. The overlay predates the
§338 commit and was never updated. Other scenarios are unaffected — they are
single-authority removals whose intent does not require disabling §338.

### 3. GN6 aircraft scaling understates the duty on consumer electronics (~9pp)

In `apply_section338` (`src/pipeline/06_calculate_rates.R`), the unmeasured-code
GN6 fallback resolves *measured HTS10 → unweighted HS2-chapter mean → 0*. The
four unmeasured covered∩GN6 codes — routers (8517.62.00), monitors (8528.52.00),
smartphones (8517.13.00), and 8414.80.05 — never reach the `→0` tier because
their chapters (84/85) are saturated with genuine aircraft lines, so they inherit
a ~17–18% exemption and are charged **~0.41 instead of 0.50**. This directly
contradicts the documented rationale for the `→0` fallback ("these codes are
overwhelmingly NOT aircraft entries"). The `→0` tier is in fact dead for all 28
overlap codes; every involved chapter contains measured aircraft lines.

### 4. Chapter-98 carve-backs are uncharged, and the docs claim otherwise

Note 51(a) (text in `data/s338/text/s338_alcohol_annex2.txt`) carves subchapter
XXIII and 9802.00.40/.50/.60/.80 **back in**: those entries of covered Canadian
goods legally pay the 50% (on repair/processing/assembly value for the 9802
codes). But `rate_s338` is only ever assigned on covered HTS8 in chapters 4–97,
so every ch98 row carries zero — making the shared ch98 zeroing and 9802
value-basis steps provable no-ops for §338. Materiality is small (real autos are
§232-excluded anyway; the exposure is ch98 dairy/alcohol/mv-list entries under
9802.00.50 repairs or 9802.00.80 assembly). But `docs/statutory_deviations.md` S7
and `docs/methodology.md` state these mechanics "are modeled," which is false.

## Latent bugs (real, but currently masked or untriggered)

### 5. The new baseline column is not propagated to every authority-column list

`add_blanket_pairs` (`src/model/rate_schema.R:536`) omits `rate_s338` from its
zero-fill, so §201-seeded pairs (step 6b1, which runs *after* step 6b-338) land
with `rate_s338 = NA`. Two `ensure_cols` guards — `stacking.R:277` and
`resolved_programs.R:77` (whose comment claims it "mirrors" the stacking guard) —
also omit it. The build survives only because of the single coalesce this branch
added at `06_calculate_rates.R:4010`; remove it, or reorder §201 after it, and
stacking receives NA → `enforce_rate_schema`'s NA-total contract hard-stops the
build. Root cause: ~10 hardcoded authority-column vectors each require a manual
edit per authority. The durable fix is to derive them from `RESOLVED_AUTHORITIES`.

### 6. The step-6b-338 ordering docstring is factually wrong

The call-site comment says `apply_section338` "runs AFTER every §232 step … so
the mask reads settled values." False: steps 6e/6f/7c/7d still mutate
`statutory_rate_232` / `s232_annex` afterward (`:3618`, `:3638`, `:3896`,
`:3942`, `:3980`). No covered code flips scope membership today, so it is latent
— but `scripts/verify_s338_snapshot.R` rebuilds the mask from *final* column
values, so a future semiconductor/aircraft code on a covered list would produce
either a spurious verify FAIL or a real mischarge.

### 7. The GN6 list has no row-count guard

`scripts/build_s338_annex.R` hard-checks 63/52/439 for the three covered lists
but has no count assertion for the 554-code GN6 list, and `extract_block` breaks
at the first blank line once started. A re-extraction under a different
`pdftotext`/poppler could silently truncate the GN6 list, dropping utilization
scaling on the overlap codes. The committed CSV is correct; the gap is
regeneration robustness.

### 8. `DAILY_PART_SCHEMA_VERSION` was not bumped

`src/pipeline/09_daily_series.R:1371` still reads `2L` despite the new
`mean_s338`/`etr_s338` columns and a changed `etr_base` residual. Mitigated in
practice because the orchestrator wipes per-vintage scratch, but per the
codebase's own convention a daily-part schema change warrants the bump to force a
rebuild on any manual gather that reuses stale parts.

### 9. `classify_authority` exact-match is suffix-fragile

`src/model/rate_schema.R:264` uses `%in% sprintf('9903.03.%02d', 12:16)`, which
misses 10-digit statistical-suffix forms; those would fall through to the
`section_122` bucket the guard exists to protect against. Weak in practice — no
10-digit chapter-99 code has ever appeared in any archive — but a prefix match is
strictly more robust and matches the comment's stated intent.

### 10. The whisky spot-check targets the wrong line

`scripts/verify_s338_snapshot.R` and `tests/test_s338.R` label 2208.30.30
"Canadian whisky," but per the annex that is *Irish and Scotch* whisky; Canadian
whisky classifies under 2208.30.60. Both codes are on the alcohol list, so no
rate is wrong — but the highest-trade Canadian line has no dedicated check, and a
regression isolated to 2208.30.60 would pass unnoticed.

## Considered and dismissed

- **`heading_program` over-excluding 8414.80.05 / 8537.10.91** — the mask
  correctly mirrors the §232 auto-parts scope (which charges those full-line);
  removing it would double-charge. Any over-breadth is a pre-existing §232 scope
  issue, not a §338 defect.
- **Missing-pair seeder lacking the `statutory_rate_232 > 0` arm** — a real code
  asymmetry vs. the existing-row mask, but effectively unreachable: the Canada
  grid is already dense before step 6b-338 (fentanyl/IEEPA seeding), and the
  covered lists barely touch statutory-metals chapters.
- **Parity gate flags the new columns as `schema_extra_column`** — real, but
  `run_parity_check.R` is a manually-invoked tool, not part of the documented
  `verify: true` build/finalize workflow, so it does not block the build.

## Cleanup theme (not bugs)

The GN6 share-resolution block, the GN6 seeding block, and `.build_section_338`
are near-verbatim copies of their §122 / Brazil-§301 counterparts. The
divergences (the `→0` vs `→1` fallback, a missing clamp on the §122 side) are
exactly where finding #3 lives. Factoring out a shared
`build_gn6_share_tbl(products, gn6_hts8, util, fallback_share)` helper would both
deduplicate and prevent the two GN6 consumers from drifting.
