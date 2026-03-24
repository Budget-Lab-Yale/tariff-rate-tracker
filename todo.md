# Tariff Rate Tracker — TODO

## Pipeline rebuild

- [ ] Full rebuild needed to propagate copper (9903.78) + MHD (9903.74) fixes from d52db4e
- [ ] Re-run `compare_etrs.R` after rebuild to confirm gap closure
- [ ] Regenerate blog figures after rebuild
- [ ] Add generic pharma country-specific exemption shares (per TPC feedback; low priority)

## Open investigations

### rev_16 shows -0.06pp 232 change (expected ~+1pp for 50% increase)

9903.81.87 exists in earlier revisions with a 25% rate (matching the old fallback), so the rate doesn't change at rev_16. The 50% rate may only appear in the HTS JSON at a later revision. Low priority — the rate is correctly 50% by rev_32.

## Blog publication (`blog_april2/`)

- [ ] Regenerate docx from final `.md` before publication

## Low priority

- **Concordance builder**: Matching may overstate splits/merges. Tighten with reciprocal-best or capped matching if needed.
- **Small-country outliers**: Persistent large gaps on low-import countries (Azerbaijan -26pp, Bahrain -22pp, UAE -8pp, Georgia +14pp, New Caledonia +22pp). Not material to aggregates.
