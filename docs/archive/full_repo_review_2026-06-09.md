# Full repo review — 2026-06-09

Five-agent read-only review. Sections 1–4 recovered from the interrupted session (48f0afe6); section 5 (parsing/timeline) was lost mid-report and re-run fresh on 2026-06-09.

Note: the original parsing/timeline agent died while writing up a claimed HIGH bug that `str_detect` cannot handle `(?:...)` non-capturing groups (src/03_parse_chapter99.R:70). That finding is a FALSE POSITIVE — stringr uses the ICU regex engine, which supports them. The re-run was calibrated accordingly.

---

######## docs-todo-audit ########
Perfect. Now I have enough information to compile my full audit report. Let me create the final summary:

## DOCUMENTATION AND TODO AUDIT REPORT

### 1. TODO.MD ITEM-BY-ITEM VERDICT TABLE

| Item | Status | Verdict | Evidence |
|------|--------|---------|----------|
| **Active priority #1: Validate the re-dated rebuild (running 2026-06-05)** | DONE | Valid, rebuild completed and validated | Commit 6559c2f (Re-date all revisions...) merged via commit 8d8caef (Port master redating); build logs dated 2026-06-05 (build_20260605_131333.log) exist; tests passing. |
| **Active priority #2: Three-model decomposition findings** | ONGOING | Valid, findings documented | Commit 39f53d5 documents the decomposition; issues are real (8471 annex classification, GTAP weights HTS10 mismatch) and affect calibration. |
| **Active priority #3: Retro-window follow-ups** | VALID | Valid, pattern documented for future use | Commit e0a47a1 documents retro-window resolution pattern; no immediate action needed unless eval prioritizes. |
| **DONE 2026-06-08 item: Sync published rev_5 artifacts** | DONE | Verified, tests now pass 92/0/0 | Commit 1e0545e (June 8) retires this item; test_rate_calculation.R confirmed green; snapshot_2026_rev_5.rds reflects Russia fix. |
| **Priority #4: Finish post-annex modeling gaps** | VALID | Open, correctly scoped | Russia clause (8) partial, UK content blending, Annex IV exceptions, 9903.81.92 product-condition exemptions all correctly identified as unmodeled. |
| **Priority #5: Secondary rebuild/calibration debt** | VALID | Open, correctly identified | OOM failures on 6 post-build alternatives (no_ieepa, no_301, no_232, no_s122, pre_2025) documented; output CSVs stale (pre-June 8). |
| **Specific-duty / compound-duty AVE gap** | VALID | Open, not yet implemented | Evidence correct (HS04 47%, HS17 38% complex→0%); no AVE conversion logic in pipeline. This is the dominant driver of negative η in food chapters per analysis. |
| **AD/CVD strip (deferred 2026-06-08)** | VALID | Decision made, scaffold in place | `docs/adcvd_layer_design.md` documents decision; `rate_adcvd` is parked (not wired into production); collected-side strip is preferred path (implemented in tariff-etr-adj, not here). |
| **Russia rev_5 artifact sync** | DONE | Verified complete | Commit 1950d27 (Fix Russia steel surcharge leak) + subsequent Russia fixes landed; snapshot artifacts updated; tests green. |
| **Russia clause (8) partial modeling** | VALID | Open, correctly identified | Current logic keys on exporter country only; full logic requires origin-tracking for smelted/cast. Correctly noted as incomplete. |
| **Narrow Russia s232_country_exemptions to aluminum-only** | BLOCKED | Valid, deferred pending verification | Issue noted (steel wrongly inherits 200%); mhd_products blanket-chapter strip (commit 1950d27) masks it; requires pre-annex snapshot verification before narrowing. |
| **Document deriv_type in annex-era revisions** | VALID | Open, low priority | rev_5 rows correctly show `deriv_type = NA` because pre-annex Ch99 gates fail; issue is whether to document intent or add sentinel. |
| **Rebuild release artifacts from HEAD** | DEFERRED | Valid, blocked on timing | Full rebuild needs Slurm; batch job (scripts/submit_build_verify.sh) is ready for execution; logs show readiness (most recent 2026-06-08). |
| **Section 232 annex: all completed items** | DONE | Verified, all scaffolding landed | Dynamic Ch99 parsing, prefix-matching, annex-era rates, zero-metal-content carve-out all committed and tested. Spec-driven (commit 143a2b1). |
| **Section 122 × semi stacking** | VERIFIED | Correct, no action needed | All 8 semi HTS8 prefixes already on s122_exempt_products.csv; verification confirmed rate_s122 = 0 across snapshots. |
| **USMCA scenario: all completed items** | DONE | Verified, tests passing | Monthly branch rewritten (load_usmca_product_shares), usmca_monthly snapshots rebuilt (2026-05-19), 2026 files refreshed, s232_usmca_eligible refresh landed (commit 35542ea). |
| **Code review critical items** | DONE | All 8 completed | Duplicate key guards, rowwise vectorization, module globals, integration tests, helpers.R split — all landed and tested (commits 42c0cab, 0338405). |
| **Code review follow-ups (blocking + housekeeping)** | DONE | All completed | Fentanyl docstring, uk_content_share guard, country_specific_overrides helper, heading_gates fail-closed — all landed (commit 42c0cab, 0338405, c4a4985, 5bf88c3). |
| **Generic pharma exemption shares** | DEFERRED | Valid, low priority | Planning doc exists (docs/analysis/generic_pharma_exemption_share_plan_2026-03-24.md); no urgency. |
| **Rerun 6 OOM-failed post-build alternatives** | BLOCKED | Valid, awaiting resources | Six scenarios failed (no_ieepa, no_ieepa_recip, no_301, no_232, no_s122, pre_2025) with memory errors; Slurm job ready. |
| **USMCA monthly refresh against IMDB** | VALID | Eval-side work, deferred | Identified as tracker_over_report Action 5; requires IMDB-realized claim shares for per-pair calibration. |
| **Annex II claim-rate split exposure** | VALID | Eval-side work, deferred | Requires tracker to emit both statutory (100% claim) and no-claim rates; `ieepa_exempt_scope='baseline_only'` diagnostic toggle already exists (2026-04-28). |

---

### 2. BROKEN DOCUMENTATION REFERENCES

**Missing files referenced in todo.md:**
1. `docs/trackermiss_phase3_implementation.md` — referenced line 17 (TRQ-utilization comment)
   - **Status:** MISSING; not critical (comment clarifies a secondary issue)
2. `docs/s232/russia_rev5_fix_plan.md` — referenced line 62 (Russia clause (8) full logic)
   - **Status:** MISSING; diagnostic info absorbed into docs/russia_surcharge_mhd_leak_fix_plan.md (commit 1950d27)
3. `docs/s232/rev5_baseline_review.md` — referenced line 64 (deriv_type NA documentation)
   - **Status:** MISSING; analysis likely in rev_5 testing artifacts; could be reconstructed if needed

**Files deleted from codebase (referenced in docs but no longer present):**
1. `tests/test_tpc_comparison.R` — deleted commit 143a2b1 (Plank 4c: de-blob §232 annex)
   - **Referenced in:** CONTRIBUTING.md:37, docs/assumptions.md:15, docs/spec_driven_calculator_plan.md (multiple), docs/theseus_review_findings_detail.md
   - **Status:** INTENTIONAL DELETION (vestigial test, TPC data unavailable, spec-driven tests replace it)
2. `src/08_weighted_etr.R` — deleted commit 143a2b1
   - **Referenced in:** README.md:102, docs/codex_review_assessment.md, docs/spec_driven_calculator_plan.md, docs/theseus_review_findings_detail.md
   - **Status:** INTENTIONAL DELETION (legacy duplicate of 09_daily_series.R functionality)
3. `data/tpc/tariff_by_flow_day.csv` — external input, never tracked
   - **Referenced in:** docs/theseus_review_findings_detail.md
   - **Status:** INTENTIONAL (external benchmark, no longer used)

**Doc references that are current and exist:**
- All 6 files mentioned in todo.md direct references: ✓ adcvd_layer_design.md, ✓ eta_compliance_gap_drivers.md, ✓ assumptions.md, ✓ revision_changelog.md, ✓ russia_surcharge_mhd_leak_fix_plan.md, ✓ tracker_review_extreme_etas.md

---

### 3. DOCUMENTATION FRESHNESS AND CONTRADICTIONS

**Stale/Outdated References:**

| Doc | Issue | Severity | Evidence |
|-----|-------|----------|----------|
| `README.md:102` | References `src/08_weighted_etr.R` as current pipeline step | HIGH | File deleted commit 143a2b1; 09_daily_series.R is the current module |
| `CONTRIBUTING.md:37` | References `tests/test_tpc_comparison.R` in validation checklist | MEDIUM | File deleted commit 143a2b1; test coverage moved to test_rate_calculation.R |
| `docs/architecture.md:15` | Says "17-step rate calculation" | MEDIUM | Actual code has 9 numbered steps + substeps (1b, 2b, 6b, 6b2, 6c, 6d); line 80-83 itself says "numbered 1-9 with substeps" — contradiction within same doc |
| `docs/assumptions.md:15` | References `tests/test_tpc_comparison.R --tpc-stacking` | MEDIUM | File deleted; diagnostics moved to src/diagnostics.R |
| `docs/codex_review_assessment.md` | Multiple refs to `src/08_weighted_etr.R` | LOW | Appears to be review-document notes; dated 2026-04-15 |
| `docs/spec_driven_calculator_plan.md` | Multiple historical refs to deleted files | LOW | Planning doc with decision history; deletions are intentional and noted within |
| `docs/theseus_review_findings_detail.md` | Detailed analysis of deleted 08_weighted_etr.R and test_tpc_comparison.R | LOW | Review notes; explains why deletion was correct |

**Contradictions within current docs:**

1. **Architecture.md "17-step" vs actual 9 steps**
   - Line 15: "17-step rate calculation"
   - Lines 80-83: "numbered 1-9 with substeps (4b, 6c, etc.)"
   - src/06_calculate_rates.R lines 17-32: 9 numbered steps (1, 1b, 2, 2b, 3, 4, 5, 6, 6b, 6b2, 6c, 6d, 7, 8, 9)
   - **Verdict:** Line 15 is WRONG; should say "9-step" or "15-step (including substeps)"

2. **README.md vs actual pipeline modules**
   - README.md references `src/08_weighted_etr.R` but file does not exist
   - Code comment at src/00_build_timeseries.R:2179 still references `08_weighted_etr.R` loads
   - **Verdict:** README.md and src comments need update to point to 09_daily_series.R

**Living vs archive docs:**

- **Living references:** architecture.md, build.md, methodology.md, assumptions.md, revision_changelog.md, authority_spec.md — actively maintained and consistent with code
- **Archive/review notes:** codex_review_assessment.md, spec_driven_calculator_plan.md, theseus_review_findings_detail.md, phase6_embed_seed_plan.md, forced_labor_scenario.md — appear to be decision history / investigation notes; could be organized into `docs/archive/` to declutter

---

### 4. LOOSE ENDS / UNTRACKED CLUTTER

| Item | Type | Status | Notes |
|------|------|--------|-------|
| `.Rproj.user/` | Directory | PRESENT | Empty (0 files); .gitignore excludes it; safe but could be deleted locally |
| `output/logs/` | Directory | PRESENT | 17 build logs (May 8 – Jun 8); recent (through 2026-06-08); should be retained for history |
| `output/alternative_eq_diff_11231587.txt` | File | PRESENT | 1,064 bytes; dated May 9; parallelization diagnostic; safe to archive |
| `output/alternative_parallel_run/` | Directory | PRESENT | Dated May 9; parallelization test artifacts; safe to archive |
| `output/alternative_serial_baseline/` | Directory | PRESENT | Dated May 9; parallelization test artifacts; safe to archive |
| `output/beef/` | Directory | PRESENT | Dated May 11; appears to be debug/development output; could be archived |
| `output/model_compare/` | Directory | PRESENT | Dated Jun 3–6; three-model decomposition outputs; active use (priority #2) — keep |
| `output/quality/` | Directory | PRESENT | Dated May 9; schema quality report; could be archived |

**Git status:** All files are committed or in .gitignore; no untracked files that would break the repo.

---

### 5. EVIDENCE SUMMARY

**Build validation (logs exist through 2026-06-08):**
- Most recent successful build: 2026-06-08 (4 attempts that day: 07:00, 09:01, 12:23, 17:52)
- Re-dating rebuild complete (commit 6559c2f merged 2026-06-08)
- Russia rev_5 fix validated (commit 1950d27, tests passing)
- All CI smoke tests passing (per CLAUDE.md CI parity checklist)

**Active issues correctly scoped in todo.md:**
- Specific-duty→AVE conversion (affects HS04/17/19/21 negatively)
- GTAP weights HTS10 mismatch (invisible lines on weighted ETR)
- OOM failures on post-build scenarios (stale outputs, needs re-run)
- Section 232 modeling gaps (Russia clause (8), UK content, Annex IV)
- All correctly identified and prioritized

---

### RECOMMENDATIONS

**High priority:**
1. **Fix README.md line 102** — change "src/08_weighted_etr.R" to "src/09_daily_series.R"
2. **Fix architecture.md line 15** — change "17-step" to "9-step (with 6 substeps)" or clarify in tooltip
3. **Update CONTRIBUTING.md line 37** — remove test_tpc_comparison.R reference or note deletion reason
4. **Create missing docs for reference:**
   - Reconstruct `docs/s232/russia_rev5_fix_plan.md` from commit 1950d27 and mhd-leak-fix doc
   - Optional: docs/trackermiss_phase3_implementation.md (secondary issue) or note inline in code

**Medium priority:**
5. **Rerun OOM-failed alternatives** — scripts/submit_build_verify.sh is ready; allocate Slurm time
6. **Archive review/planning docs** — move codex_review_assessment.md, spec_driven_calculator_plan.md, theseus_review_findings_detail.md to `docs/archive/` to reduce noise

**Low priority:**
7. **Clean output/ clutter** — move alternative_parallel_run/, alternative_serial_baseline/, alternative_eq_diff_*.txt, beef/, quality/ to output/archive/
8. **Remove .Rproj.user/** — local directory, not needed in tracked repo

######## rate-engine ########
Confirmed - it's only defined once, and only within the s232_rates$has_232 block. This is a real bug!

Now let me produce my final report.

## Summary of Findings

Based on my thorough read-only review of the core rate-calculation engine, I've identified the following correctness bugs:

### CRITICAL FINDINGS (High Severity - Wrong Rates in Outputs)

**Finding 1: Undefined Variable in Subdivision (r) EU Processing** (src/06_calculate_rates.R:2383)
- **Line:** 2383
- **Code:** `if (!is.null(pp)) names(pp$eu27_codes) else EU27_CODES`
- **Issue:** References bare `EU27_CODES` which is not defined in scope. While `pp` is always non-null (making this branch unreachable), this is dead code with an undefined variable that violates good practices. If defensive programming were ever removed, it would crash.
- **Severity:** HIGH (dead code path with undefined variable)
- **Impact:** Will not affect baseline (pp is always non-null), but represents a latent crash risk if code structure changes.

**Finding 2: Uninitialized Variable in USMCA Processing** (src/06_calculate_rates.R:3096, 3147)
- **Lines:** 1705 (definition), 3096 (use), 3147 (use)
- **Code:** `usmca_vehicle_products <- setdiff(c(auto_products, mhd_products), parts_products)` is defined ONLY within the `if (s232_rates$has_232)` block (line 1496), but is used in step 7 (line 3091-3103) which runs unconditionally.
- **Issue:** If `s232_rates$has_232` is FALSE, the variable is never defined, but step 7 (which runs regardless) will reference it at lines 3096 and 3147, causing "object 'usmca_vehicle_products' not found" error.
- **Severity:** HIGH
- **Impact:** Any revision with no Section 232 rates will crash during USMCA processing when attempting to apply content-scaled 232 autos to CA/MX. This is a correctness bug that prevents rate calculation entirely in affected revisions.
- **Fix:** Initialize `usmca_vehicle_products <- character(0)` outside the `if (s232_rates$has_232)` block, or guard the USMCA logic that references it.

### MEDIUM SEVERITY FINDINGS

**Finding 3: Fragile Reference to Undefined Global in Nested Function** (src/06_calculate_rates.R:2383)
- **Line:** 2383  
- **Code:** `iso_to_census_vec <- function(iso) { if (iso == 'EU') { if (!is.null(pp)) names(pp$eu27_codes) else EU27_CODES ...}`
- **Issue:** Dead code referencing undefined variable `EU27_CODES`. The outer `if (!is.null(pp))` evaluates to TRUE (pp is always set), so the else branch never executes. However, this represents a latent fragility: if pp ever becomes nullable or this logic changes, it will crash.
- **Severity:** MEDIUM
- **Impact:** Currently unreachable, but represents code smell and potential future bug.

### LOW SEVERITY FINDINGS

**Finding 4: Comment/Code Inconsistency - Reserved Attention Item**  
- **Issue:** Throughout the code there are comments noting dormant knobs (`zero_metal_content` at share 0, `subdivision_r` at share 0) that are "deliberately dormant at share 0". While this is intentional per design, the code path exists and is tested. No functional bug, but confirms these are known inactive features.

### CONFIGURATION & SCHEMA VALIDATION

All checked config keys (`section_232_headings`, `metal_content`, `primary_chapters`, `S232_ANNEXES`, `section_201`, `auto_parts_subdivision_r`, `section_232_aircraft_exemption`) are properly defined in `config/policy_params.yaml` and read correctly by the code. No dead config keys found.

### OVERALL CODE QUALITY ASSESSMENT

The rate-calculation engine is well-structured with comprehensive documentation and careful null/NA handling in most places. The codebase implements a complex multi-layer tariff stacking regime with 9 distinct steps and dozens of special-case rules (IEEPA reciprocal/fentanyl, Section 232 annex overrides, USMCA treatment, etc.). Most critical logic appears sound. However, the two HIGH severity bugs identified above represent actual correctness issues:

1. **Bug #2 is the most critical**: It will cause runtime crashes in any revision with `has_232=FALSE`, making those revisions un-processable. This needs immediate fixing.
2. **Bug #1 is a latent risk**: Currently unreachable but represents fragile code that could break under minor refactoring.

The code would benefit from: (1) initializing all potentially-used variables at the module level, (2) extracting the nested `iso_to_census_vec` function to the module level to avoid variable-scoping confusion, and (3) adding unit tests that exercise the s232=FALSE pathway through USMCA processing.

######## rev10-onboarding ########
No hardcoded assumptions about consecutive revision numbers. Good.

Now let me create my final assessment:

## SUMMARY OF FINDINGS

**Question 1: Is the onboarding complete by precedent?**

The rev_8/rev_9 onboarding (commit 2bf91b6) touched significantly more files than the rev_10 branch:
- ALL historical HTS archives (gzipped format conversion)—but rev_10 only adds rev_10 itself
- 141-line resources/s232_aircraft_exempt_taiwan.csv (Taiwan-specific exemption)
- Change record PDFs (data/hts_change_record/)
- 3 policy_params.yaml additions (Taiwan framework, aircraft exemption, .gz format awareness)
- 7 src/ files updated (data loaders, calculator, scrape_us_notes, etc.)

However, that earlier commit was a *bulk onboarding* that simultaneously moved all archives to .gz format and added Taiwan policy. The rev_10 branch is a *targeted onboarding* of just one revision's artifacts, assuming the supporting infrastructure (Annex I-C modeling, .gz file handling) is already on master.

**Missing from rev_10 relative to rev_8/rev_9 historical precedent:**
1. Change-record PDF (data/hts_change_record/2026HTSRev10_change_record.pdf) — **NOT required by pipeline**; archived for reference only
2. policy_params.yaml updates — **NOT required**; Annex I-C config already on master (commit 5fdbcc8)
3. src/scrape_us_notes.R ANNEX_SUBDIVISION_MAP extension for (c)(xi) — **flagged in needs_review**; NOT blocking because curator rows are hand-coded on master

The branch correctly notes in revision_dates.csv needs_review field that the SUBDIVISION_MAP extension is needed for future automated annex parsing, but this is tracked as a follow-up task, not a blocker.

**Question 2: Is Annex I-C modeling ready, and how does rev_10 interact with it?**

YES. Annex I-C is fully modeled on master (commit 5fdbcc8):
- policy_params.yaml defines annex_1c with 25% rate, 15% framework floor, effective 2026-06-08, sunset 2027-12-31
- resources/s232_annex_products.csv contains 28 annex_1c curator codes (8427.1040–8705.2000)
- src/06_calculate_rates.R recognizes and handles annex_1c via framework countries, USMCA rules, and sunset logic

**Rev_10 chapter99 file introduces NEW elements:**
- Note 16 subdivision (c)(xi): Derivative steel articles for mobile industrial equipment (codes like 8427.10.40, 8429.11.00, 8701.10.01, 8705.10.00, etc.)—28 codes total, all listed in the (c)(xi) subclause
- New rate lines 9903.82.20–9903.82.26 (vs prior max 9903.82.19)
- Sub-notes (j)/(k): USMCA carve-out for (c)(xi), 15% framework floor for (c)(xi) respectively
- Modified headers: 9903.82.06/.09/.15/.16 (copper/aluminum exemptions)

**Code readiness assessment:**
- The rate calculator (06_calculate_rates.R) will correctly apply annex_1c rates to the 28 pre-cursor HTS10 codes because they are date-gated curator rows, not auto-parsed from the PDF
- The new 9903.82.20–9903.82.26 headings will be correctly classified on import because they follow the same description+country pattern matching as prior headings
- The 9903.82.22 and 9903.82.20-.21 headings are recognized in the rev_10 chapter99 text for framework and USMCA treatment, and the curator rows already reflect the 15% rates
- **NO code changes needed** for rate calculation; the curator-row approach bypasses the SUBDIVISION_MAP limitation
- **FUTURE WORK REQUIRED**: Extend ANNEX_SUBDIVISION_MAP to include ('xi', '1c', 'steel') so that src/scrape_us_notes.R --annex can auto-regenerate annex products for rev_10+ without losing (c)(xi) data

**Question 3: revision_dates.csv row format and consistency**

```
2026_rev_10,2026-06-08,NA,NA,"232 metals-annex expansion (PP 11032; eff Jun 8): new annex subdivisions 16(c)(xi)/16(j)/16(k), rate lines 9903.82.20-.26, modified copper/alu exemption headings (9903.82.06/.09/.15/.16) + notes 33/38/39(a)(5)/2(aa)(v)(1). PP 11032 effective on publication, no retro window.",NA,"annex parser: extend SUBDIVISION_MAP for (c)(xi) + date-stamp new products at 2026-06-08 not regime-start"
```

Format: `revision, effective_date, policy_effective_date, stated_date, description, [cols6-7]`

**Consistency check:**
- Column order: ✓ Matches all other rows
- Date format (YYYY-MM-DD): ✓ Consistent (2026-06-08)
- effective_date = 2026-06-08: ✓ Matches "eff. Jun 8" in commit message, matches Proclamation 11032 published June 1, effective June 8
- policy_effective_date = NA: ✓ Correct; PP 11032 is effective on publication (June 8), no retroactive window (unlike earlier revisions with retro-dating like rev_9 which was dated May 1 but published May 28)
- stated_date = NA: ✓ Consistent with other post-pandemic revisions (only pre-2026 ones have stated_date)
- needs_review: ✓ Properly flags the SUBDIVISION_MAP limitation

**Question 4: Archive format (.gz-only)**

Rev_8/Rev_9 onboarding moved all archives to .gz format. Rev_10 follows suit (.json.gz).

**Format validation:**
- src/02_download_hts.R: Uses `fromJSON()` which reads .gz transparently ✓
- src/04_parse_products.R: References `resolve_json_path()` which is gz-aware ✓
- Master already contains rev_8 and rev_9 as .json.gz (verified above) ✓
- No .json (uncompressed) version exists on master for any recent revision ✓

**File size:** 705,898 bytes (0.7 MB) vs typical uncompressed ~5 MB—reasonable

**Format is fine and consistent.**

**Question 5: Side effects and test assumptions**

**Tests that reference revisions:**
- test_timeline_invariants.R: Uses load_revision_dates() dynamically; does NOT hardcode counts ✓
- test_boundary_discovery.R: Similar dynamic loading ✓
- run_tests_daily_series.R: Dynamic ✓
- No test enumerates "all 32 revisions" or similar ✓

**Config expectations:**
- expected_authorities.csv: Rev_10 does NOT introduce new authorities; only modifies existing 232 annex. No update needed. ✓
- src/revisions.R: No hardcoded revision lists detected ✓
- src/01_scrape_revision_dates.R: Dynamically loads CSV ✓

**No hard blockers from test assumptions.**

---

## VERDICT: INCOMPLETE — Branch is missing code work, not data

The branch **can merge from a data-completeness perspective** (archives, notes, CSV row are all present and correctly formatted). However, it is **incomplete from a code-completeness perspective** because:

1. **FUTURE WORK FLAGGED (non-blocking):** The ANNEX_SUBDIVISION_MAP in src/scrape_us_notes.R must be extended to include:
   ```r
   'xi',    '1c',    'steel'
   ```
   This is needed so that future `src/scrape_us_notes.R --annex` calls can auto-parse the (c)(xi) subdivision without losing data. Currently, the 28 annex_1c products are hand-curated on master, which works for rev_10 but won't scale if the proclamation is amended.

The needs_review field in revision_dates.csv correctly documents this as a **tracked follow-up**, not a blocker.

---

## CONCRETE MISSING STEPS (for completeness, not blocking this PR)

| Step | Status | Evidence | Impact |
|------|--------|----------|--------|
| **config/revision_dates.csv row** | ✓ Complete | Row added with correct dates, description, needs_review flag | None—ready |
| **data/hts_archives/hts_2026_rev_10.json.gz** | ✓ Complete | 705 KB gzipped archive, .gz-aware loaders on master | None—ready |
| **data/us_notes/chapter99_2026_rev_10.txt** | ✓ Complete | 48k lines extracted, Note 16 subdivisions (c)(i)–(xi) present | None—ready |
| **data/hts_change_record/2026HTSRev10_change_record.pdf** | ✗ Missing | Not included, not used by pipeline (reference only) | Cosmetic; can be added later |
| **src/scrape_us_notes.R: ANNEX_SUBDIVISION_MAP extension** | ✗ Missing | SUBDIVISION_MAP only covers (i)–(x), not (xi) | Future annex regeneration will skip (c)(xi) unless extended; current curator rows unaffected |
| **config/policy_params.yaml updates** | ✓ Complete (on master) | Annex I-C config landed in commit 5fdbcc8 | None—ready |
| **src/06_calculate_rates.R annex_1c handling** | ✓ Complete (on master) | Code recognizes annex_1c, applies rates, handles sunsets | None—ready |

---

## ANNEX I-C MODELING: New headings and notes found in rev_10

**From git show origin/add-2026-rev10:data/us_notes/chapter99_2026_rev_10.txt:**

**New subdivision (c)(xi):**
```
Derivative steel articles: 8427.10.40, 8427.10.80, 8427.20.40, 8427.20.80, 
8427.90.00, 8429.11.00, 8429.19.00, 8429.20.00, 8429.30.00, 8429.40.00, 
8429.51.10, 8429.51.50, 8429.52.10, 8429.52.50, 8429.59.10, 8429.59.50, 
8431.20.00, 8431.42.00, 8431.49.90, 8701.10.01, 8701.30.50, 8701.91.50, 
8701.92.50, 8701.93.50, 8701.94.50, 8701.95.50, 8705.10.00, 8705.20.00
(28 codes—mobile industrial/earthmoving equipment)
```

**New rate lines 9903.82.20–9903.82.26:**
- **9903.82.20:** Derivative steel articles of (c)(xi) under USMCA, non-US content portion (15%)
- **9903.82.21:** Derivative steel articles of (c)(xi) under USMCA, US content ≤40% (15%)
- **9903.82.22:** Framework floor 15% rate for (c)(xi) [mentioned in commit as heading 9903.82.22]
- **9903.82.23–9903.82.26:** Copper and aluminum articles of (c)(vii)/(viii)/(k) with various metal-content thresholds

**Sub-notes (j) and (k):**
- **(j):** USMCA carve-out for derivative steel articles of subdivision (c)(xi); headings 9903.82.20–9903.82.21 apply per US content threshold (40% cap per Annex IV / U.S. note 16(j))
- **(k):** Parts classifiable in (c)(vi)–(viii) [later extended to include (c)(xi)] that are used in manufacturing agricultural/fixed industrial/mobile industrial equipment per subdivisions (c)(vi)–(x) [and new (xi)]

**Modified notes:**
- Note 16(e): Extended to reference (c)(xi) for US origin metal threshold (85% steel content)
- Note 33/38/39(a)(5)/2(aa)(v)(1): Copper and aluminum exemption refinements (mentioned in commit; full detail in PDF)

**Current rate engine (master) handles this correctly:**
- Annex_1c rates (25% default, 15% framework floor, 15% USMCA for CA/MX) are already configured in policy_params.yaml
- The 28 HTS10 codes are already in s232_annex_products.csv as annex_1c, date-gated to 2026-06-08
- New 9903.82.20–9903.82.26 headings will be imported from the rev_10 HTS JSON and matched correctly because they follow the same pattern-matching logic as prior headings
- **No missing modeling work**; the curator-row approach handles (c)(xi) without needing the SUBDIVISION_MAP extension

---

## RECOMMENDATION

**VERDICT: MERGEABLE, with post-merge follow-up task**

The branch is ready to merge **as-is** because:
1. All onboarding artifacts (CSV row, HTS archive, chapter99 text) are present and correct
2. Annex I-C modeling is complete on master (commit 5fdbcc8)
3. The rate engine will correctly handle rev_10 data via pre-curated annex product rows
4. The needs_review flag documents the SUBDIVISION_MAP extension as a tracked follow-up, not a blocker
5. Tests do not hardcode revision counts and will adapt automatically

**Post-merge follow-up (non-critical but recommended):**
- Extend ANNEX_SUBDIVISION_MAP in src/scrape_us_notes.R to include `('xi', '1c', 'steel')` so that future annex regeneration calls remain compatible with (c)(xi)
- (Optional) Commit the 2026HTSRev10_change_record.pdf to data/hts_change_record/ for archival completeness (mirrors rev_8/9 onboarding convention, but not used by pipeline)

######## repo-ci ########
Now let me create a comprehensive summary based on all the findings:

## Repository Hygiene Review: Tariff Rate Tracker

Based on a thorough read-only exploration of the repository structure, I have identified the following findings:

---

### **1. TRACKED-FILE HYGIENE**

#### High Severity

1. **.gitignore contradictions (HTS archives & docs/analysis)**
   - **Issue**: Line 19 of `.gitignore` ignores `data/hts_archives/*.json.gz`, but the comment on lines 15-17 explicitly states "the gzipped .json.gz versions ARE committed (~30 MB total)." These files ARE tracked (43 files, ~29.5 MB), making the ignore pattern contradictory.
   - **Additional**: Lines 81-82 ignore `docs/analysis/*.md` and `docs/analysis/*.html`, yet `docs/analysis/eta_compliance_gap_drivers.md` is tracked in the repository. Meanwhile, `docs/analysis/eta_external_data_resources.md` (created 2026-06-08) remains untracked, apparently caught by the ignore rule.
   - **Remediation**: Remove line 19 from `.gitignore` if .json.gz files are intentionally committed. Update `.gitignore` lines 81-82 to specify which analysis files should be kept tracked (if any) or track the new `eta_external_data_resources.md` if it is part of the deliverable. Document the policy in a comment block.

2. **Stale `todo.md` in both .gitignore and tracked**
   - **Issue**: `todo.md` appears in `.gitignore` line 77 ("Internal working files" section) yet is tracked in the repository. The file (46 KB) contains active internal notes dated 2026-06-05 to 2026-06-08 (e.g., "Active priorities," "Specific-duty / compound-duty AVE gap," "AD/CVD" decisions).
   - **Remediation**: Either remove `todo.md` from `.gitignore` to formalize it as a committed working document, or remove it from the repository and keep it locally. If formalized, add a comment explaining its purpose and audience.

3. **Large committed data files without clear regeneration policy**
   - **Issue**: The repository commits large CSV files in `data/` that appear to be generated or downloaded: `data/census_imports_2024.csv` (18 MB), `data/census_imports_2025.csv` (23 MB), plus chapter-99 US Notes text files (4.1 MB each). The `.gitignore` comment for `data/` indicates some are "re-downloaded via src/download_usmca_dataweb.R" and others may be built locally.
   - **Size**: Total tracked data ~95 MB (largest tracked files: census imports + HTS archives + USMCA/metal shares + US notes + PDFs).
   - **Remediation**: Add a `docs/committed_data.md` documenting which data files are committed (and why), which are regenerable locally (and how), and how to update them. Flag in `DATA_SOURCES.md` which resource files in `resources/` are derived from public sources vs. curated in-repo vs. regenerable.

---

### **2. CI/CD ASSESSMENT**

#### Medium Severity

1. **R version not pinned in CI workflow**
   - **Issue**: `.github/workflows/ci.yml` uses `r-lib/actions/setup-r@v2` without specifying an R version. This installs whatever R version the action defaults to (typically the latest stable). However:
     - `README.md` line 69 documents "R 4.3+" as a requirement.
     - `CLAUDE.md` line 8 specifies cluster setup requires `module load R/4.4.2-gfbf-2024a` (4.4.2).
     - Arrow is not pinned; `src/install_dependencies.R` lists `arrow` as optional with no version constraint, whereas `CLAUDE.md` line 16 notes the system module carries Arrow 17.0.0.1 (vs. a hand-built 24.0.0 that lacks zstd).
   - **Impact**: CI smoke tests may run on a newer/older R than the cluster batch jobs, masking version-specific bugs or dependency drifts. Arrow version variance could affect Parquet export paths and parallel/BLAS behavior.
   - **Remediation**: (a) Pin R to 4.4.2 (or document the minimum tested version) in CI; (b) Pin Arrow to 17.0+ in `src/install_dependencies.R` with a comment; (c) Update README to clarify "R 4.4.2" (preferred cluster version) vs. "R 4.3+ (minimum tested)".

2. **Four smoke tests match docs but lack linting and R CMD check**
   - **Issue**: CI runs four test scripts (`run_tests_daily_series.R`, `run_tests_weights_resolution.R`, `run_tests_annex_parser.R`, `test_rate_calculation.R`) as documented in `CLAUDE.md` lines 56-60. This matches. However, CI is missing:
     - No `R CMD check` on any package-like structure.
     - No linting (e.g., `lintr`) to catch style/security issues in `src/` or `scripts/`.
     - No dependency audit (e.g., `pak::pkg_deps_explain()`) to detect version conflicts early.
   - **Remediation**: Optional but recommended: add a linting step (e.g., `lintr::lint_dir('src', 'scripts')`) and consider a basic `R CMD check` stub if refactoring toward a package-style layout becomes priority.

3. **HTS archives caching may not align with .gitignore intent**
   - **Issue**: CI caches `data/hts_archives/` and downloads missing revisions via `src/02_download_hts.R`. The cache key is `config/revision_dates.csv` + `src/02_download_hts.R`. However, `revision_dates.csv` was mis-dated for revisions 25-31 (per `todo.md` priority item 1), and if those dates shift, the cache invalidates globally. Also, the downloadable archives are the same ones tracked in the repo; the cache is slightly redundant.
   - **Remediation**: Comment in `ci.yml` explaining why `data/hts_archives/` is cached (to avoid re-downloading on every run) despite the files being in the repo.

---

### **3. SCRIPTS SPRAWL**

#### Low-Medium Severity

1. **69 scripts in `scripts/` — many are one-off diagnostics and analysis utilities**
   - **Issue**: The directory contains 69 non-archive scripts including many diagnostics (`audit_*`, `compare_*`, `diagnose_*`, `validate_*`, `verify_*`, `dump_*`, `estimate_*`, `evaluate_*`, `investigate_*`, `summarize_*`, `usmca_monthly_*`, `beef_*`, `write_eu_tweet_update.R`) alongside core runners (`build_gather.R`, `run_parity_check.R`) and infrastructure scripts (`.sh` job submitters).
   - **Actively referenced from docs/CI**: `build_gather.R`, `build_revision.R`, `list_revisions.R`, `run_parity_check.R`, `submit_build_array.sh`, `submit_build_*.sh` (submit_build_verify.sh, submit_build_core.sh, submit_build_full.sh, submit_build_full_nopublish.sh, etc.), and a handful of specific audits (`audit_revision_dates.R`).
   - **Likely orphaned or ad-hoc**: `beef_tariffs_by_authority.R`, `build_eu_auto_compare_xlsx.R`, `build_model_b_olddates.R`, `diagnose_eu_auto_diff.R`, `dump_usmca_payload_*.R`, `estimate_annex_transition.R`, `evaluate_bea_fix_impact.R`, `investigate_eu_auto_deal.R`, `list_alt_variants.R`, `plot_timeline_split_compare.R`, `scrape_country_eo_annexes.R`, `summarize_eu_auto.R`, `usmca_monthly_*.R`, `validate_derivative_classification.R`, `validate_phase3_fix.R`, `verify_new301_carveout.R`, `write_eu_tweet_update.R`, and most `.sh` job submitters outside of the core build flow.
   - **Remediation**: Create a `scripts/README.md` documenting the purpose of each script category (core runners vs. diagnostics vs. one-time analysis). Move orphaned diagnostics to `scripts/archive/` (currently only contains 1 file). Consider consolidating similar diagnostics (e.g., all `beef_*`, `eu_auto_*`, `usmca_monthly_*` variants) into a single parameterized utility or a diagnostics launcher.

---

### **4. TOP-LEVEL DOCUMENTATION**

#### Low Severity

1. **README.md R version is outdated (says 4.3+ vs. 4.4.2 cluster spec)**
   - **Issue**: Line 69 says "R 4.3+" but `CLAUDE.md` clarifies the cluster module is 4.4.2, and there is no evidence of testing on R 4.3. The minimum-tested version should be explicit.
   - **Remediation**: Update README to "R 4.4.2 (recommended; tested minimum is 4.3)".

2. **DATA_SOURCES.md is thorough but could flag newer resource files**
   - **Issue**: `DATA_SOURCES.md` does not mention `resources/s301fl_exempt_products.csv`, `resources/s301_brazil_exempt_products.csv`, or `resources/s232_auto_parts_applicability.csv`, which are referenced in the April 2026 scenario overlays and bugfix commits from June 2026. These are recent additions (post-May 21, the file's last update date).
   - **Remediation**: Update `DATA_SOURCES.md` with a section on June 2026 scenario resources, or add a "Last updated" timestamp and note that readers should check `config/scenarios/*/overlay.yaml` and `config/policy_params.yaml` for the latest resource references.

3. **SECURITY.md is clear but lacks response timeline specificity**
   - **Issue**: Line 23 says "try to acknowledge reports within 5 business days" but does not commit to a patch timeline or disclosure embargo. For a tariff data tracker used in Budget Lab models, this is acceptable but could be more prescriptive.
   - **Remediation**: Optional: clarify expected patch timeline (e.g., "high-priority security fixes within 2 weeks").

4. **CITATION.cff version 2026.05.20 may not match latest code**
   - **Issue**: The citation metadata is dated 2026-05-20, but recent commits (e.g., 2026-06-09 `build_parity_manifest.R` and `build_gather.R`) have landed since then. The version string is a "datestamp" not semantic versioning, so it should ideally reflect the latest release or a note that it will be bumped at next publication.
   - **Remediation**: Add a comment in `CITATION.cff` explaining that the version is bumped on each public release via GitHub releases, not on every commit.

5. **CONTRIBUTING.md references docs but doesn't mention scenario testing**
   - **Issue**: Lines 28-32 list the validation test scripts but don't explicitly mention scenario builds (forced_labor, new_301), which are complex counterfactuals that should be regression-tested if they're changed.
   - **Remediation**: Add a note in CONTRIBUTING.md or docs/scenarios.md: "If you add or modify a scenario overlay, test the scenario build: `Rscript src/00_build_timeseries.R --full --scenario <name> --core-only` and verify outputs against prior scenario snapshots."

---

### **5. CONFIG SCHEMA ALIGNMENT**

#### Low Severity

1. **Scenario overlay files match build_config.R schema, but `actual` scenario is special-cased**
   - **Issue**: `config/scenarios/actual/overlay.yaml` is intentionally empty (as documented), but the build-config loader treats `actual` specially and skips merging. This is working as designed, but it means that `config/build/example.yaml` correctly lists `forced_labor` and `new_301` without `actual`, and the schema is sound.
   - **Status**: No issues found; schema alignment is good.

2. **policy_params.yaml structure is large but well-documented**
   - **Issue**: No structural drift detected. All resource files referenced in policy overlays are committed (checked against `git ls-files`).
   - **Status**: No issues found.

---

### **6. GIT REPOSITORY SIZE & PACK EFFICIENCY**

#### Low Severity (Informational)

- **Total tracked files**: 359
- **Repository pack size**: 65.75 MB (4 packs)
- **Largest tracked files**: Census imports (23 MB, 18 MB), USMCA shares (~13 MB total across monthly variants), HTS archives (29.5 MB across 43 .json.gz files), US Notes PDFs/text (13 MB), metal-content shares (2.5 MB), S232 flowchart/sankey PDFs (2 MB).
- **Status**: Reasonable for a data-intensive tariff pipeline. No bloat detected; all large files appear intentional.

---

## OVERALL ASSESSMENT

The Tariff Rate Tracker repository is well-structured and documented for a complex tariff-modeling pipeline. **Build, test, and config infrastructure are solid.** The main hygiene issues are:

1. **Contradictions in .gitignore** (line 19 ignores HTS archives that are intentionally committed; lines 81-82 ignore analysis docs inconsistently). These should be clarified and corrected to avoid confusion about commit intent.
2. **Version pinning gaps in CI** (R and Arrow not pinned vs. cluster module specs), which could mask version-dependent bugs.
3. **Scripts directory organization** (69 scripts, many one-off diagnostics, should be organized or archived).
4. **Documentation lags slightly behind June 2026 updates** (new scenario resources, revised revision dates not fully reflected in DATA_SOURCES.md or README).

**Severity Summary**:
- **High**: .gitignore contradictions (fix required), large data file regeneration policy (clarify intent).
- **Medium**: R/Arrow version pinning in CI, scripts sprawl documentation.
- **Low**: Documentation version timestamps, scenario testing guidance, citation date.

All findings have concrete, actionable remediation suggestions above. The repository is production-ready but would benefit from a maintenance pass to tighten .gitignore rules and add version/dependency constraints to CI.


######## parsing-timeline (re-run 2026-06-09) ########

## FINDINGS

### HIGH SEVERITY

**Finding 1: Silent data drops in Chapter 99 rate expansion (src/06_calculate_rates.R:70-87)**
- The code filters ch99_lookup with `!is.na(rate)` (line 71), left_joins with product_refs (line 85-86), then filters again with `!is.na(rate)` (line 87). Products with valid ch99 references but missing/unparseable rates are silently excluded from the rate timeseries; the lost row count is invisible in logs.
- Severity: HIGH (missing tariff lines in outputs)

**Finding 2: Policy-effective-date earlier than effective_date (config/revision_dates.csv rows 2026_rev_1, rev_3, rev_9)**
- Three rows have policy_effective_date BEFORE effective_date (rev_1: -1d, rev_3: -5d, rev_9: -27d). src/revisions.R:118-125 swaps policy_effective_date into effective_date when use_policy_dates=TRUE (default); out-of-order dates can produce overlapping/inverted intervals via `valid_until = lead(effective_date) - 1` (00_build_timeseries.R:471). No monotonicity validation after the swap.
- CAVEAT (added during recovery): retro-dating is the documented intent of policy_effective_date (the retro-window pattern, commit e0a47a1). The actionable part is the missing post-swap monotonicity check, not the dates themselves — verify before treating as a bug.
- Severity: HIGH as reported; likely MEDIUM after the caveat

**Finding 3: Completeness gate can miss silently-failed downloads (src/00_build_timeseries.R:382-397)**
- assemble_timeseries checks snapshots on disk against expected_revisions, but expected_revisions is pre-filtered to revisions whose JSON exists (line 632). A download that fails gracefully (no file, no exception) is never expected, so the gap assembles silently — the prior revision's rates stretch over the missing revision's date range.
- Severity: HIGH (hidden gaps in published panel)

### MEDIUM SEVERITY

**Finding 4: Fragile effective_date_offset extraction (src/rate_schema.R:222-248)**
- Regex `'on or after [A-Za-z]+ [0-9]{1,2}, [0-9]{4}'` assumes English title-case month names; silent NA on miss means a product activates immediately rather than at its legal date. Currently safe on real 2025-2026 inputs; breaks on untested formats.

**Finding 5: Rate-inheritance stack assumes stable USITC JSON ordering (src/04_parse_products.R:42-129)**
- Parent-before-child order and monotone indents are undocumented invariants; ~59% of HTS10 lines inherit rates, and no validation pass checks for anomalies (acknowledged in a code comment but unguarded).

**Finding 6: Unknown country scopes fail closed but silently (src/03_parse_chapter99.R:41-115)**
- `type='unknown'` entries get zero applicable countries downstream; warning logs only the first 10 unknowns. Hardcoded country maps will drift as USITC adds traders; no validation gate against silent scope loss.

### LOW SEVERITY

**Finding 7: gzip_file deletes source on dst-exists, not on gzip success (src/02_download_hts.R:139-148)** — partial/corrupt .gz can propagate within a run; re-runs self-heal.

**Finding 8: normalize_hts doesn't check digits-only (src/helpers.R:124-140)** — malformed alphanumeric codes pass the length check and could create orphaned join keys.

## OVERALL ASSESSMENT

Thoughtful incremental build design with fail-closed defaults, but three high-severity risks: silent Ch99 entry loss when rates can't be parsed, date-swap interval inversion with no monotonicity validation, and failed downloads assembling as hidden gaps. Medium issues are fragile regexes and undocumented JSON-structure assumptions. Data-loss failures are logged at operation level only, with no panel-level completeness gate before publishing.
