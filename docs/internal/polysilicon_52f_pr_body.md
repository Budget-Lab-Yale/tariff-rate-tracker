# PR: Exclude non-displacing §232 actions from the overlay scope mask

Branch: `fix/polysilicon-52f-displacement` → `master` (single commit)

## The bug

The polysilicon §232 action (PP 2026-08-06, effective 2026-12-04) amends **no
overlay exclusion note**: Annex II inserts U.S. note 42 and headings
9903.45.30–.36 and nothing else, and the exclusion notes — 52(f) (forced-labor
§301), 50(a)(vi) (Brazil §301), 51(c) (§338) — **enumerate** their excluded
§232 actions by heading, with no generic any-§232 clause. Verified against the
rev_14 Chapter 99 PDF in-repo and the signed Annex II (whitehouse.gov).

The shared `.s232_in_scope()` mask instead treated *any* §232 coverage as
displacing. From the `bnd_2026-12-04` boundary, builds silently dropped
**~$1.7B/yr of forced-labor §301** on solar cells/modules — Vietnam, Thailand,
Malaysia, Cambodia, and India carry ~90% of it — so the published net ETR step
was +0.021pp instead of the true ~+0.08pp. Raw polysilicon (`28046100`) and
the wafer lines (`38180000xx`) were unaffected: they are already FL-301 common
exemptions.

## The fix

- Every `section_232_headings` block in `config/policy_params.yaml` now
  declares `displaces_overlays` (**required, not defaulted** — the heading
  loop stops on an undeclared block, so every future proclamation forces an
  explicit answer to "did this action amend the exclusion notes?"). True for
  the twelve enumerated actions, each annotated with its 52(f) subdivision;
  false for polysilicon.
- Non-displacing programs persist their rate component
  (`rate_232_nondisplacing`, set in `apply_polysilicon_232_adjustments()`)
  and membership (`s232_nondisplacing`); `.s232_in_scope()` subtracts both,
  so a row whose only §232 coverage is non-displacing stays overlay-visible,
  while a row also covered by a displacing source (e.g. a metals annex tier)
  stays excluded — correct, per 52(f)(1). Two loud guards: component tracking
  exists only for the polysilicon apply path, and non-displacing products must
  not collide with any displacing product list.
- One shared mask fix covers all three overlay consumers (FL-301, Brazil
  §301, §338).

## Verification

- Three regression tests in `tests/test_rate_calculation.R`: mask
  truth-table, column-less back-compat, component recording under both flag
  values. Commit state alone: 138 passed / 0 failed; CI-parity suites green.
- End-to-end on a Slurm-rebuilt `bnd_2026-12-04` mint (job 21898264): Vietnam
  modules carry **both** the +15% §232 and 12.5% FL-301; Japan/Korea modules
  show the note-42(c) 15% total cap with FL-301 intact; Japanese autos keep
  FL-301 excluded per 52(f)(2) (no over-correction).
- Full analysis: `docs/internal/polysilicon_note52f_mask_2026-08-10.md`
  (in this PR).

## Interactions & follow-ups

- **No conflict with `feat/fl301-hts-rates`** (FL-301 rates read off the HTS):
  trial-merged both onto master — conflict-free, combined suites green. Merge
  order is irrelevant.
- The 2026-08-10 full build predates this fix and understates post-Dec-4 ETR;
  **rebuild before the next publish**.
- Watch item: if the codifying HTS revision or a later proclamation adds
  polysilicon to any exclusion note, flip the flag (possibly date-gated).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
