# §232 derivative triple-check — consolidated fixes (2026-07-24)

Follow-up to `docs/s232_derivative_hs8_overinclusion.md` (commit 585ce25). A
three-way independent audit of that fix (mechanical git-history re-derivation;
code-path/time-line audit; verification against the primary FR sources) plus a
description-matched HTS suffix successor map. **Verdict on 585ce25 itself:
correct and FR-faithful** — nothing in it was reverted. But the audits surfaced
further defects in both directions, all fixed here in one pass so a single
Slurm rebuild + golden re-freeze covers everything.

Sources: FR 2025-15819 (official PDF in `docs/federal-register/`), 90 FR 11249
(steel implementation, Proc 10896 note 16(n)), 90 FR 11251 (aluminum, Proc
10895 note 19(j)/(k)), FR 2025-05884 (beer/cans), FR 2026-06960 (April 2026
restructuring). Confirmed: **no BIS inclusion round after the first ever became
law** (round 2 punted, never issued; the April 2026 proclamation terminated the
process — later additions land in `s232_annex_products.csv`).

## 1. UK derivative overcharge — code BUG (`src/model/authority_adapter.R`)

Rev_14 (2025-06-04) carries explicit UK **derivative** entries at 25%
(9903.81.96-.99 steel, 9903.85.13-.14 aluminum), parsed into
`steel/aluminum_country_overrides` — which the adapter applied only to the
**primary** programs. UK outside-chapter derivatives were charged 50%
(metal-content-scaled) instead of 25% for 2025-06-04 → 2026-04-05. Fix:
`.derivative_country_rates()` now merges the country overrides (exempt zeros
win). Annex era unaffected (own UK handling; derivative gates off).

## 2. `resources/s232_derivative_products.csv` (616 → 655 rows)

a. **Missing Proc 10896 note 16(n) steel list** (90 FR 11249, eff 2025-03-12):
   the CSV had NO steel rows from the original March expansion. Added 12
   8-digit codes @9903.81.91: 84313100 84314200 84314910 84314990 84321000
   84329000 85479000 94032000 94059920 94059940 94062000 94069001. Eight were
   completely uncharged 2025-03-12 → 2026-04-06 (prefab buildings, ag/elevator
   machinery parts); four were partially proxied by the wrong-metal aluminum
   rows.

b. **Beer** (FR 2025-05884, eff 2025-04-04): added 22030000 aluminum. Was
   absent pre-annex (~$7-8B/yr, aluminum-content-scaled ≈ 5.2% BEA share);
   annex era already handled it (annex_2 from 2026-04-06).

c. **Metal-blind HS8 broadenings**: 585ce25's audit keyed on "a bare 8-digit
   entry exists" without splitting by metal. 16 subheadings had one metal
   legally 8-digit and the other listed only at 10-digit lines; the 10-digit
   side stayed broadened. Narrowed the over-broad metal side to the FR lines
   for 9 subheadings (85049096 steel→.9634/.9638/.9642; and aluminum sides of
   87163900→.0040, 85030095→.9520/.9546/.9570 [also de-duped], 87168050→.5010,
   94039910→.1040, 84839050→.5020, 84159080→.8025/.8045/.8085,
   84799095→.9596, 87081030 +.3050 for FR fidelity). The 7 other cases span
   their full subheading (harmless; left at HS8).

d. **Suffix-churn successors** (description-matched across revision JSONs; the
   July-1-2026 484(f) renumber killed 8 active 10-digit prefixes — e.g.
   whole-of-84139190-steel and 8708295160 went to zero coverage on
   current-law revisions):
   - eff 2026-07-01: 2106909993/.94 (steel+alum, from .9998), 8413919020/.29/
     .99/.44/.59 (steel, from .9055/.9060/.9096 incl. the new copper
     carve-out lines), 8479899597+8479899510 (from .9599), 8479909591+
     8479909510 (from .9596), 8708295150+.90 (from .5160).
   - eff 2026-01-30: 8541900010/.80 (from 8541900000 leaf split),
     9401999040/.85 (from .9070; .9081's earlier remap to .30/.70 extends to
     {.30,.40,.85}), 8415908010/.20 (from .8025 copper/other split).
   Dead rows are kept — they simply match nothing after the renumber, and the
   per-revision universe matching makes coexistence safe in both directions.

e. **Date-gate corrections**:
   - 110 formerly-NA rows @9903.85.07/.08 (Proc 10895 note 19(j)/(k)) now
     dated **2025-03-12** — they previously activated 5 days early via rev_4's
     2025-03-07 policy date. The 6 @9903.85.04 rows (Proc 9980) stay NA.
   - 9401999030/.9070: 2025-08-18 → **2025-07-01** (FR-15819 Annex II.C
     technical correction, not an inclusions addition).
   - 9403999020 steel: 2025-08-18 → **2025-03-12** (it is the note 16(n)
     anchor line; steel-derivative status predates the inclusions round).
   - Deleted `73029000,aluminum` — a mis-transcription of the **steel
     in-chapter** addition 7302.90.9000 (already covered by the 730290 mill
     row in `s232_metal_chapter_products.csv`); it wrongly aluminum-typed the
     whole rail-track subheading.

Validation: every active (prefix, revision) pair matches ≥1 line of that
revision's HTS10 universe across rev_5/10/19/28, 2026_basic/rev_2/5/10/11/12
(zero misses; known-dead prefixes hand off to their successors exactly at the
renumber revisions).

## 3. Audited and left alone

- **In-chapter derivative "stacking leak" — false positive**: primary-chapter
  rows are force-reset to metal_share 1.0 / type shares 0
  (`data_loaders.R:938-948`) regardless of the derivative flag, so §122/IEEPA
  cannot fill a phantom non-metal fraction there. Verified empirically.
- Class B six (84129090 84834050 73082000 83099000 85016401 86073010): FR
  suffixes confirmed dead in the current HTS; HS8 proxy stands (~$5B residual
  over-inclusion, deliberate).
- Annex-era interaction: the annex map cannot re-broaden the narrowed
  subheadings (only 3 derivative lines rely on the inference arm; the rest are
  the proclamation's own 4/6/8-digit annex scope).
- **Known remaining gap (documented, not fixed)**: Proc 9980-era derivative
  coverage 2025-01-01 → 2025-03-06 (codes 9903.80.03 @25% steel / 9903.85.03
  @10% aluminum are not in the program gate lists, and the 9980 steel list
  (nails, bumper/body stampings) was never ingested). ~9 weeks at panel start,
  small trade base, low rates; fixing requires new gate codes + rate plumbing.
  Also: 2025-03-07→03-11 the 6 Proc-9980 aluminum rows are charged at the
  rev_4 25% rate for all countries (legally 10% with TRQ-country carve-outs).

Expected build impact: UK derivative fix lowers UK ~10 months of derivative
charges by half; (n)-list + beer add coverage 2025-03/04 → 2026-04; churn
successors restore current-law coverage from 2026-01-30/07-01 (notably
84139190 steel and 8708295160 → successors); metal-blind narrowings remove
residual spurious base from 2025-03-12 on. Golden-changing: one Slurm rebuild
+ re-freeze.

## Build outcome (vintage 2026-07-24-09 — GOLDEN reference as of 2026-07-24)

Verified (verify_build.R gates + 112/112 tests) and `latest` repointed.
Measured deltas vs 2026-07-24-08, matching the predictions above:

- Overall: +0.01 to +0.02pp through the pre-annex window (mean +0.014pp
  2025-03-12..2026-04-05 — (n)-list + beer, displacement-damped, net of the
  narrowings); +0.023pp on current-law dates (churn successors). Cleanest
  signature: exactly −0.08pp on 2025-03-07..11 only (the 5-day early-start
  date fix), flipping to +0.006 on 2025-03-12.
- UK: −0.35pp from ~Aug 2025 (when the inclusions list built its derivative
  base) through 2026-04-05; ~0 in the annex era. The 50%→25% fix.
- Switzerland/Hungary/pharma origins: no movement (the 585ce25 narrowing was
  not disturbed). Remaining top movers are micro-importers (Kosovo furniture
  via 9403.20.00, etc.) where one restored line swings a tiny denominator.

This vintage supersedes 2026-07-24-08 as the parity reference ("golden") for
future candidate builds. Also first build with the quality-part gather
speedup: gathers 13.5–16 min → 1:38–2:04.
