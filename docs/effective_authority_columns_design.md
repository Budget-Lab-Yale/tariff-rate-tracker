# Design: effective per-authority rate columns (self-describing snapshots)

Status: proposal / design sketch (2026-07-15). Not yet implemented.

## The idea in one sentence

Every snapshot should carry, per product×country, an **effective** rate for each
authority that **sums exactly to `total_rate`** — so the by-authority
decomposition is *stored*, not *reconstructed* downstream.

## Why this exists (the problem)

The model has three layers:

1. **Parse** HTS JSONs + config → per-revision snapshots of policy parameters.
2. **Calculate** — per snapshot, per product×country, compute the rate. *All*
   tariff-calculation logic lives here.
3. **Aggregate** — weight by imports → daily / country / authority CSVs. Pure
   aggregation; no policy.

Today the snapshot stores **two tiers that don't reconcile**:

- **Statutory per-authority columns** — `rate_232`, `rate_s122`,
  `rate_ieepa_recip`, … (and their `statutory_rate_*` siblings). These are
  pre-stacking, largely pre-exemption. **They cannot be summed**: naive Σ
  double-counts, because §232 *displaces* the reciprocal/§122 rather than
  stacking on top. (rev_10, weighted: naive Σ = 13.64%.)
- **The effective total** — `total_rate` / `total_additional`. This is the
  truth: post-stacking *and* post-exemption. (rev_10 = 10.82%.)

The step-2 logic that turns the first into the second — displacement plus
exemptions (USMCA/FTA shares, deal caps, §122 waivers, §301 exclusions) —
operates on the **total** (or on intermediate rates that are never written
back), so it is **only partially represented in the columns**.

### Consequences we are living with

- The effective per-authority split is **not stored anywhere**. Step 3 has to
  *reconstruct* it (`compute_net_authority_contributions`), and because that
  reconstruction can't recover the exemptions, it needs the `etr_base` residual
  and the `7799622` scale-to-effective hack to force the parts to sum to the
  total.
- `total_rate` is **not a function of the written columns**. Re-deriving from
  columns (`apply_stacking_rules(columns)`) gives 12.09%, not the stored 10.82%
  — it re-charges the exempted duty. This is exactly the bug behind the daily
  re-derivation (`7adfb27`).
- The two can drift in **both** directions: usually the total is *lower* than
  the columns imply (missing exemptions), but some rows have the total *higher*
  (a rate was stripped from a column after the total was frozen — e.g. Guatemala
  footwear rev_9 stored 0.5 vs columns implying 0.1). Same root cause: the total
  and the columns are produced at different points and never reconciled.
- ~88% of all product-country cells satisfy `total = stacking(columns)`; the
  ~12% that don't (≈37% of import-weighted pairs) are the exemption/deal/waiver
  rows. So the defect is not systemic rot — it is a *representation gap* that
  bites any row carrying an adjustment the columns don't record.

## The proposed design

Add an **effective (stacking-adjusted) tier** of per-authority columns:

```
statutory_rate_<auth>   # pre-stacking statutory rate (already exists)
effective_rate_<auth>   # NEW: this authority's actual contribution to total_rate
```

with a single hard invariant:

> **`base_rate_effective + Σ effective_rate_<auth> == total_rate`**, enforced
> per row at build time.

The `effective_rate_<auth>` columns absorb, per authority, *everything* that
currently only reaches the total:

- **Displacement / mutual exclusion** — §232 displacing reciprocal/§122/fentanyl
  on metal content shows up as a *reduction in the displaced authority's*
  effective column, not as a mystery in the total.
- **Share-based exemptions** — USMCA/FTA, GSP/MFN preference, GN6 utilization,
  §232 content shares. Example: Mexico 90%-USMCA-exempt from a 10% §122 duty →
  `effective_rate_s122 = 0.01`, not a silent reduction residualized into
  `total_rate`.
- **Deal caps / floors** — §232 auto/wood 15% floors, UK surcharge, annex_1c
  framework floor.
- **Full-line zeroings** — §301 exclusions, IEEPA invalidation, §122 sunset.

### The linchpin: the invariant is the deliverable

The columns matter less than the **enforced `Σ effective == total`
assertion**. That invariant:

- makes drift between total and parts *impossible* (build fails otherwise);
- deletes the `etr_base` residual, the scale-to-effective hack, and the daily
  re-derivation — step 3 becomes a pure weighted sum of stored columns;
- would have caught the 06-08 §122 drop at build time.

### Ordering discipline

Compute the effective columns **once, last**, and derive `total_rate` **from
them**. Never edit a rate after the total is set. (The current bidirectional
drift comes from violating this.)

### The hard part: attribution is a *choice*, not a derivation

For **independent** reductions (a share applied to one authority) attribution is
unambiguous. For **interacting** authorities (§232 vs reciprocal/§122
displacement) the split of the jointly-affected value is **not unique** — it is
a modeling decision (priority order vs. Shapley-style split). This
non-uniqueness is *precisely why* the residual exists today. The design must
**pick and document** the convention (the natural one: the displacing authority
takes its full rate on the displaced base; the displaced authority takes the
remainder). A single authority may be hit by multiple reductions
(use-exemption *and* displacement *and* a deal cap) — the attribution rule must
**compose** in a defined order.

## Migration notes

- The **statutory tier already exists** (`statutory_rate_*`). This is "add the
  effective tier + attribution + the invariant," not green-field.
- Roll out behind the invariant as a *test*, initially warning-only, until
  `Σ effective == total` holds on 100% of rows across all revisions; then
  promote to a hard gate.
- Once green, repoint step 3 to sum `effective_rate_*` directly and delete the
  reconstruction path.

## Scope boundary

This is the **representation** question. It is independent of the **substance**
question — *which* rules actually apply and with what parameters (e.g. whether
§122 is really waived for framework-deal countries on 06-08). Substance findings
become the attribution rules encoded here; see the 06-08 §122 investigation
(memory `s122-0608-framework-drop`).
