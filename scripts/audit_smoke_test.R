#!/usr/bin/env Rscript
# Smoke test for ieepa_exempt_audit_2026-04-28 changes.
# Reads rev_6 snapshot and inspects target cells.

snap <- readRDS("data/timeseries/snapshot_2026_rev_6.rds")
cat("snapshot rows:", nrow(snap), "\n")
cat("columns:", paste(names(snap), collapse = " "), "\n\n")

show_cells <- function(label, hts_codes, country) {
  cat("===", label, "===\n")
  res <- snap[snap$country == country & snap$hts10 %in% hts_codes, ]
  if (nrow(res) == 0) {
    cat("  no rows\n\n")
    return(invisible())
  }
  cols <- intersect(c("hts10","country","base_rate","rate_232","rate_ieepa_recip",
                      "rate_ieepa_fent","rate_301","rate_s122","rate_section_201"),
                    names(res))
  print(res[, cols])
  cat("\n")
}

# rev_32 of 2025 is the latest pre-SCOTUS-invalidation revision (Nov 15, 2025),
# IEEPA Phase 2 + KR floor active. This is where the audit changes should show.
cat("\n--- rev_32 (2025-11-15, pre-SCOTUS, IEEPA Phase 2 active) ---\n\n")
snap <- readRDS("data/timeseries/snapshot_rev_32.rds")

show_cells("Indonesia x PV cells (audit-removed; expect Phase 2 rate)",
           c("8541430010","8541430080","8541420010","8541420080"), "5600")
show_cells("Vietnam x 8541.43.0010 (audit-removed; expect Phase 2 +20%)",
           "8541430010", "5520")
show_cells("China x 8541.43.0010 (audit-removed; expect 301 only — IEEPA suspended for China post-Geneva)",
           "8541430010", "5700")
show_cells("Indonesia x 8523.51.0000 (kept on exempt list; expect 0)",
           "8523510000", "5600")
show_cells("Indonesia x 8523.41.0000 (audit-removed; expect Phase 2 rate)",
           "8523410000", "5600")
show_cells("Vietnam x 8518.30.20.00 (still on exempt list; should remain 0)",
           "8518302000", "5520")
show_cells("Vietnam x 8541.10.00 (kept exempt; should remain 0)",
           c("8541100000","8541100040","8541100050","8541100060"), "5520")
