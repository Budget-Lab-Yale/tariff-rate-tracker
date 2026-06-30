# `rate_adcvd`: an antidumping/countervailing-duty layer for the rate panel

> **Status:** scaffold in progress (2026-06-07). Loader + template + tests exist;
> NOT wired into the production pipeline. Wiring is gated on (1) a curated orders
> file and (2) a decision to add the column to `RATE_SCHEMA`.
>
> **Why:** the tracker has no AD/CVD field, which is the mechanical reason the
> calibrated compliance parameter η goes *negative* for Japan/UK/EU (collected
> duty exceeds modeled statutory, concentrated in HS84/85/90). Census `cal_dut_mo`
> and Treasury `customs_duties` both include AD/CVD deposits; the tracker's
> statutory rate does not. See `docs/analysis/eta_compliance_gap_drivers.md` and
> `docs/analysis/eta_external_data_resources.md` (gitignored working docs).

## Decision (2026-06-08): defer this layer; strip AD/CVD from the *collected* side instead

After reviewing AD/CVD policy over the last ~18 months, the near-term plan is the
**collected-side strip**, not this statutory layer. The two are mutually
exclusive (doing both double-counts — see "Calibration" below); this layer's
scaffold is **kept but parked** as the fallback if the strip proves infeasible.

**Why the strip wins right now:**

1. **The regime is structurally stable — but the *levels* are a moving target.**
   No change to how AD/CVD works or how it appears in the data: it is still the
   Tariff Act of 1930 deposit-at-entry mechanism, additive to MFN, administered by
   Commerce under a Chapter-99 case number, present in Census `cal_dut_mo` and
   Treasury `customs_duties`, and absent from the HTS schedule. What *has* moved is
   the level: two 2024 Commerce final rules (Mar 25 2024, eff. Apr 24 — transnational/
   Belt-and-Road subsidies now countervailable, PMS clarified, labor/environment/IP
   folded into cost distortions; plus the Dec 16 2024 administration rule) broadened
   countervailability and raised margins prospectively, and the 2025-26 docket is
   heavy (solar cells from KH/MY/TH/VN Apr 2025; active anode material from China
   Jul 2025; monomers/oligomers from Taiwan Mar 2026; OCTG circumvention Feb 2026).
2. **A static statutory layer would be perpetually stale.** Because rates are
   firm-specific, scope is by narrative description (HTS "for convenience only"),
   and the order set churns, an HTS×country `rate_adcvd` resource would need
   constant re-curation and still be approximate. The collected strip captures
   *realized* AD/CVD automatically — every new order and the 2024-rule margin
   changes included — without modeling any of it.
3. **The design docs already call the strip the "principled alternative."** η
   should not absorb legally-owed AD/CVD; removing it from the collected numerator
   is the cleaner way to achieve that than adding an approximate statutory rung.

**Caveats to honor when implementing the strip** (in `tariff-etr-adj`, not here):

- **Granularity.** No published HTS- or country-level AD/CVD *collection* breakdown
  exists (`eta_external_data_resources.md` §2). The strip is feasible only at
  aggregate / coarse-partner granularity from CBP's published AD/CVD assessed
  figures (FY2025: Mexico $5.56B, Canada $1.95B, etc., `cbp.gov/newsroom/stats/trade`).
  η is calibrated by partner × chapter, so an aggregate or by-partner strip is a
  coarser correction than a per-cell one.
- **It does not fully fix HS84/85/90.** AD/CVD over-collection shares the *same
  residual* as Section 232 derivative-content under-capture (`eta_external_data_resources.md`
  §8 open #2). Stripping AD/CVD alone will not zero the machinery negative η; the
  232-derivative piece is separate and is **tracker-side** (reconcile `metal_share`).
- **Do exactly one.** If the strip is adopted, keep this `rate_adcvd` layer dormant;
  do not wire it in. Modeling on the statutory side *and* stripping from collected
  double-counts.

The remainder of this doc describes the parked statutory-layer design.

## What this layer is — and is not

`rate_adcvd` is an **order-average, ad-valorem-equivalent, cash-deposit-rate**
rung at `HTS-10 × country`, added to `total_additional` alongside `rate_232`,
`rate_301`, etc. Three structural limits are intrinsic (not fixable by better
engineering):

1. **Scope is narrative, not HTS.** Commerce defines an order's scope by written
   product description; the HTS codes in an order are "for convenience only" and
   non-dispositive. Any HTS-10 mapping is an approximation.
2. **Rates are firm-specific.** Each producer/exporter has its own margin plus an
   "all-others" rate. The panel carries an **order average** (all-others, or a
   trade-weighted blend) — there is no single legally-correct per-line rate.
3. **Lag.** Deposit rate at entry ≠ final liquidated liability (avg ~2.6-year
   lag, up to 14). `rate_adcvd` models the **deposit** rate (what `cal_dut_mo`
   carries), so it does not reconcile period-by-period against collections.

These mean the layer is the right way to stop η from absorbing legally-owed
AD/CVD, but it is an **estimate** and should be labeled as one wherever it
surfaces (statutory ETR, diagnostics).

## Schema

Add one rung to `src/model/rate_schema.R`:

```r
RATE_SCHEMA <- c(
  'hts10', 'country', 'base_rate', 'statutory_base_rate',
  'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
  'rate_s122', 'rate_section_201', 'rate_other',
  'rate_adcvd',                      # <-- NEW: order-average AD/CVD deposit rate
  'metal_share',
  'total_additional', 'total_rate',
  'usmca_eligible', 'revision', 'effective_date',
  'valid_from', 'valid_until'
)
# defaults:  rate_adcvd = 0
# rate_cols: add 'rate_adcvd' to the NA-fill vector
```

`rate_adcvd` defaults to 0, so adding the column is inert until the orders file
exists and Step 6b is wired in — every existing snapshot/series is unchanged.

## Data model — `resources/adcvd_orders.csv`

One row per (order × covered-HTS-prefix). Columns: `case_number`, `country`,
`hts`, `rate`, `effective_date`, `revoked_date`. See
`resources/adcvd_orders.TEMPLATE.csv` for the header, column docs, and the
acquisition recipe. `#` comment lines are supported (loader uses `comment='#'`).

- `case_number` — `A-###` antidumping or `C-###` countervailing. Both an A- and
  a C- case can cover the same line; the loader **stacks them additively**.
- `country` — tracker country code (map the order's country *name* via
  `resources/census_codes.csv` / `country_partner_mapping.csv`).
- `hts` — covered prefix at whatever depth the order publishes (2-10 digits).
- `rate` — all-others (or trade-weighted) AVE deposit rate, e.g. `0.21`.
- `effective_date` / `revoked_date` — gate the rung to the snapshot's interval.

## Loader — `src/experimental/load_adcvd_layer.R`

`load_adcvd_layer(effective_date, product_universe, import_weights, path)`:

1. Read orders (skip `#` comments). Empty/missing → empty layer (rate 0).
2. **Date-gate** to orders active on `effective_date`.
3. **Expand** each order prefix to panel HTS-10s via `expand_hts_prefixes()`
   (`startsWith` fan-out against `product_universe = unique(rates$hts10)`).
4. Within a case, collapse overlapping prefixes per HTS-10 by `max(rate)`
   (most-specific scope wins).
5. **Stack distinct cases additively** per `(hts10, country)`.
6. Return `hts10, country, rate_adcvd`.

`import_weights` is reserved for a future value-weighted blend (diluting an
all-others rate by in-scope trade share); additive stacking does not need it.

## Wiring (deferred — gated on the orders file)

In `src/pipeline/06_calculate_rates.R`, a new **Step 6b** after the program rungs and
before `total_additional` / `total_rate` are summed:

```r
adcvd <- load_adcvd_layer(effective_date  = effective_date,
                          product_universe = unique(rates$hts10))
rates <- rates %>%
  left_join(adcvd, by = c('hts10', 'country')) %>%
  mutate(rate_adcvd = coalesce(rate_adcvd, 0))
# rate_adcvd flows into total_additional like rate_232 etc.
```

Interaction notes:
- **Stacking.** AD/CVD is owed *in addition to* MFN, 232, 301, IEEPA — it is not
  subject to the 232/IEEPA mutual-exclusion logic. It should add to
  `total_additional` unconditionally (confirm against `stacking.R` so it isn't
  accidentally scaled by `metal_share`/`nonmetal_share`).
- **USMCA.** AD/CVD orders generally still apply to USMCA-origin goods (USMCA does
  not waive trade-remedy duties), so `rate_adcvd` should **not** be reduced by
  `usmca_share`. Verify per-order, but the default is no USMCA haircut.
- **Calibration.** Adding `rate_adcvd` raises modeled statutory for Japan/UK/EU
  (pulling negative η toward zero) and modestly for CA/MX/China. The **principled
  alternative** is to strip AD/CVD out of the *collected* side (`cal_dut_mo`)
  before calibrating in `tariff-etr-adj`, so η never carries legally-owed AD/CVD.
  **Do exactly one** — modeling it on the statutory side *and* stripping it from
  collected would double-count.

## Acquisition (the real work)

The loader is mechanical; the curated `adcvd_orders.csv` is the effort:

1. **Coverage** — active orders × country × covered HTS: Commerce ITA "Products
   Subject to AD/CVD Orders" (`data.commerce.gov`, ID ITA-0039; stale at
   2020-06-17 so cross-check current orders), or `access.trade.gov/ADCVD_Search`.
2. **Rates** — all-others / trade-weighted deposit rates: ACCESS order pages or
   CBP ACE AD/CVD messages (`trade.cbp.dhs.gov/ace/adcvd/`).
3. **Country mapping** — order country name → tracker code.
4. **Scope review** — for wide prefixes, sanity-check the fan-out against the
   narrative scope; record exclusions.

Prioritize the negative-η chapters (HS72/73 steel, HS84/85 machinery/bearings,
HS90 instruments, chemicals) and the high-AD/CVD countries (China, Korea, Japan,
EU) first — that is where the layer moves the calibration most.

## Tests

`tests/test_adcvd_layer.R` exercises the loader on synthetic fixtures:
prefix expansion, date-gating, additive A-/C- stacking, most-specific-prefix
collapse, and the empty/missing-file path. These run without any real data and
should pass now (loader logic only).

## Open items

- Confirm `rate_adcvd` does not get `metal_share`-scaled in `stacking.R`.
- Decide statutory-layer vs collected-strip approach with `tariff-etr-adj`.
- Per-order USMCA applicability flag (rare exceptions where an order is scoped
  to exclude USMCA-origin goods).
- A `revoked_date`-aware refresh cadence (orders sunset on 5-year reviews).
