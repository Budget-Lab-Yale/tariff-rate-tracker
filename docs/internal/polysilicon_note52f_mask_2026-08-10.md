# Polysilicon §232 wrongly displaces forced-labor §301 in the built series

**Found 2026-08-10**, inspecting build 21852929 (buildclean @ `27c358e`,
60 snapshots, verify 122/0). Follow-up to the stacking section of
`polysilicon_232_review_2026-08-06.md`.

## Verdict

At the `bnd_2026-12-04` boundary the polysilicon ad valorem layer adds
**+0.080pp** of weighted ETR through §232 — matching the review's expectation
(15% × ~0.53% of the panel) — but the same boundary removes **−0.059pp** of
§301 on the same lines, so the published net step is only **+0.021pp**:

```
                 etr_232      etr_301      weighted_etr
2026-12-03      0.054314     0.039999      0.109357
2026-12-04      0.055114     0.039405      0.109563
```

The offset is a modeling artifact, not policy. The Aug-6 proclamation adds
polysilicon to **none** of the §232-overlap exclusion notes — not note 52(f)
(forced-labor §301), not 50(a)(vi) (Brazil §301), not 51(c) (§338).
Re-verified 2026-08-10 against primary sources, independently of the
2026-08-06 review:

- **The exclusion notes are enumerated, not generic.** Note 52(f) as
  extracted from the repo's own `Chapter 99_2026HTSRev14.pdf` lists eight
  categories by specific heading — steel/aluminum/copper (9903.82.02,
  .04–.26), passenger vehicles (9903.94.xx), their parts, wood (9903.76.xx),
  MHD vehicles (9903.74.01–.06), MHD parts (9903.74.08–.10), semiconductors
  (9903.79.01), and patented pharmaceuticals (9903.04.60–.66). There is no
  "any article subject to section 232" catch-all, so a new §232 action does
  not displace FL-301 unless the notes are amended. The same enumerated
  pattern appears in the note 50/51 region.
- **Annex II amends nothing else.** The annex (whitehouse.gov, as signed)
  contains exactly two modification instructions: insert new U.S. note 42,
  and insert headings 9903.45.30–.36. No text touches notes 50/51/52 or any
  other note.
- **Note 42(b) stacks rather than displaces**: duties "collected in addition
  to" FTA special rates, chapter 98 stays eligible, no chapter-99 lower-rate
  claim, AD/CVD continues.

Every other §232 sectoral action in the tracker appears in 52(f)'s
enumeration; polysilicon is the exception, and its duties stack on top of
everything already there.

Corrected numbers: the true polysilicon step is **~+0.08pp of weighted ETR,
~$2.3B/yr statutory** on the matched base; the build understates it by
roughly two-thirds, wrongly dropping **~$1.7B/yr** of forced-labor §301 on
~$15B of solar cells and modules. FL-301 is the only §301 layer with a §232
exclusion, so the whole −0.059pp is its doing; Brazil §301 and §338
components don't move (no meaningful solar trade), but the same latent error
sits in their shared mask.

## Where the displacement lands

Only the four solar cell/module HTS10s move — `8541420010`/`8541420080`
(cells) and `8541430010`/`8541430080` (modules). The other five polysilicon
lines have no FL-301 to displace: raw polysilicon `28046100` and the
`38180000xx` wafer suffixes are already **full common exemptions** in
`resources/s301fl_final_common_exemptions.csv` (and the new wafer suffixes
carry no weight regardless).

By origin (2024 weights × FL-301 tier rate; MFN is Free on these lines, so
net-of-MFN caps bind at full value):

| Origin      | 2024 imports | FL-301 rate    | §301 wrongly dropped |
|-------------|-------------:|----------------|---------------------:|
| Vietnam     |       $5.61B | 12.5% flat     |            ~$700M/yr |
| Thailand    |       $3.33B | 12.5% flat     |            ~$420M/yr |
| Malaysia    |       $2.57B | 10% flat       |            ~$260M/yr |
| India       |       $1.54B | 10% flat       |            ~$150M/yr |
| Cambodia    |       $1.34B | 10% flat       |            ~$130M/yr |
| South Korea |       $0.68B | 12.5% net-MFN  |             ~$85M/yr |
| Indonesia   |       $0.45B | 10% flat       |             ~$45M/yr |
| Others      |       $0.80B | 10–12.5%       |             ~$85M/yr |

Naive total: **$1.88B/yr** on $16.3B of FL-301-covered trade, vs the
$1.73B/yr implied by the build's −0.0594pp step — the gap is the pipeline's
downstream USMCA/FTA/post-preference-cap adjustments (Mexico, Canada,
Korea), so the two figures corroborate. Laos ($0.35B of modules) is not an
investigated FL-301 origin and correctly has nothing to lose. The error is
concentrated: a ~10–12.5pp understatement on the Southeast Asian module belt
that dominates U.S. solar supply, from 2026-12-04 onward.

## Mechanism

`.s232_in_scope()` (`src/pipeline/06_calculate_rates.R:923`) is the single
scope mask shared by the three chapter-99 overlays whose notes exclude
§232-covered goods. A row is in scope when `statutory_rate_232 > 0`, its
annex tier is 1a/1b/1c/3, or `heading_program` is TRUE. When the polysilicon
program activates (date gate at `:271`, effective 2026-12-04), its nine
HTS10s trip **both** the statutory prong (applied at `:2654`, before the
`statutory_rate_232` snapshot at `:2875`) and the heading prong (included in
`heading_program_products` at `:2981`). All three overlay exclusions then
fire on lines their notes do not exclude.

The mask's docstring says it exists so "a future §232 scope change lands in
one place, not three" — polysilicon is the first §232 scope change that
should *not* have landed in any of them.

## Fix (implemented 2026-08-10)

A required per-program config key, `displaces_overlays`, on every
`section_232_headings` block in `config/policy_params.yaml` — `true` for the
twelve enumerated actions (each annotated with its note 52(f) subdivision),
`false` for polysilicon. Required, not defaulted: the heading loop in
`06_calculate_rates.R` stops on a block that omits it, so every future
proclamation forces an explicit, reviewed answer to "did this action amend
the exclusion notes?" — the silent every-232-displaces assumption is what
caused this bug.

Plumbing: the heading loop accumulates `nondisplacing_products` from
flag-false programs (with two loud guards: only the polysilicon apply path
tracks its rate component, and non-displacing products must not collide with
any displacing product list); `apply_polysilicon_232_adjustments()` persists
its component as `rate_232_nondisplacing`; the main flow marks membership as
`s232_nondisplacing`. `.s232_in_scope()` subtracts the component from the
statutory prong and the membership from the heading prong, so a row whose
only §232 coverage is non-displacing stays overlay-visible, while a row also
covered by a displacing source (e.g. a metals annex tier) stays excluded —
correct, since note 52(f)(1) lists metal articles regardless of what else
applies. All three overlay consumers (FL-301, Brazil §301, §338) share the
mask, so one fix covers them.

Regression tests in `tests/test_rate_calculation.R`: mask truth-table
(non-displacing-only visible, mixed-coverage excluded, column-less frames
byte-identical to old behavior) and component recording under both flag
values. Verified end-to-end by rebuilding the `bnd_2026-12-04` mint from the
rev_15 archive and asserting FL-301 persists on solar modules alongside the
+15% §232 while a displacing control (Japanese autos) keeps FL-301 excluded.

## Watch item

If the codifying HTS revision (or a later proclamation) adds polysilicon to
any of notes 52(f)/50(a)(vi)/51(c), the displacement becomes real — possibly
effective-dated, and possibly for a subset of the three notes, which would
split the shared mask. Reconcile when the headings land in an archive, per
item 6 of the 2026-08-06 review.
