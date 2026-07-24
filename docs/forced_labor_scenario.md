# Section 301 forced-labor final action

**Status:** current law in the `actual` baseline, effective July 24, 2026.

USTR's July 23 final action replaced the preliminary action modeled from the
June 5 notice. The baseline `section_301_forced_labor` authority now implements:

- a flat 10% additional duty for 17 economies;
- a total-duty cap of 10%, net of MFN, for EU member states and Taiwan;
- a total-duty cap of 12.5%, net of MFN, for Japan, South Korea, and
  Switzerland;
- a flat 12.5% additional duty for the other investigated economies; and
- the common and country-specific exemptions in final Annex II.

The authority is date-gated in `config/policy_params.yaml` and turns on at the
existing `2026-07-24` synthetic boundary. `rate_s301fl` is now a canonical
baseline rate column; it is zero before the effective date.

## Exemptions and stacking

The generated resources are:

- `resources/s301fl_final_common_exemptions.csv` — Annex II Part A;
- `resources/s301fl_final_country_exemptions.csv` — Annex II Parts B–O.

Rebuild them from a `pdftotext -layout` rendering of the USTR notice with
`scripts/build_s301fl_final_annex.R`.

The model treats full and `Ex` rows as exemptions at the listed HTS granularity.
Aircraft- and pharmaceutical-use rows are utilization-scaled (90% and 50%
exempt shares). Part O textiles carry two legal conditions: unconditional for
Jordan (note 52(j)(13)(i) — Parts N and O are one full-exemption list), and
CAFTA-claim-conditional for the six note-52(i) origins (Costa Rica, Dominican
Republic, El Salvador, Guatemala, Honduras, Nicaragua), which use the model's
existing HS2-by-country preference-utilization proxy. Canada and Mexico
continue through the product-level USMCA share machinery.

The final action stacks additively with other tariff authorities, except that
articles in Section 232 scope are fully excluded under note 52(f). The calculator
implements that as a scope mask rather than a content split. Patented
pharmaceutical products join the Section 232 carve-out on July 31, 2026.

The historical `forced_labor` and `new_301` scenario names remain as empty
compatibility aliases for `actual`.

## Verification

`tests/test_forced_labor_scenario.R` covers baseline/alias identity, all rate
tiers and cap semantics, final-annex counts, date gates, additive stacking,
MFN-net calculations, common and country-specific exclusions, end-use scaling,
the Section 232 exclusion, and patented pharmaceuticals.
