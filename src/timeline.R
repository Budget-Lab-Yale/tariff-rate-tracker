# =============================================================================
# timeline.R — unified schedule-boundary splitter (Phase 3c)
# =============================================================================
# STATUS: standalone + unit-tested. NOT yet wired into the pipeline — the swap-in
# (replacing helpers.R get_expiry_split_points + the calc's per-gate handling)
# is the next step, gated by a baseline parity run.
#
# WHY. Today TWO mechanisms decide when a tariff switches on/off within a
# revision's date window, with OPPOSITE day conventions:
#
#   A. Downstream expiry splitter (helpers.R get_expiry_split_points /
#      apply_expiry_zeroing): splits a revision interval at SECTION_122 / SWISS
#      expiries using `> expiry` — i.e. the expiry date is the LAST LIVE day.
#      It only knows those two hardcoded expiries.
#   B. The calculator's effective_date gates (06): IEEPA invalidation uses
#      `>= until` — i.e. `until` is the FIRST DEAD day; annex activation /
#      annex_3 sunset / Ch99 offsets gate per-revision at the revision's date.
#
# Because A only knows two expiries, any OTHER mid-window switch (the annex
# turning on, a Ch99 offset activating between revision dates) is missed: the
# window carries one rate straight across the switch. And A vs B disagree by a
# day, so naively merging them shifts some tariffs.
#
# CANONICAL CONVENTION (this module). A `boundary` is the FIRST day of a NEW
# state — so (boundary - 1) is the last day of the prior state. Both legacy
# conventions map onto it cleanly:
#   - a "last live day" expiry  E  ->  boundary = E + 1   (first dead day)
#   - a "first dead day" until   U  ->  boundary = U        (already first dead)
# A split at boundary B inside a revision window (valid_from, valid_until] yields
# sub-intervals [.., B-1] and [B, ..]. This reproduces the existing
# get_expiry_split_points() behaviour after the +1 mapping (unit-tested), while
# ALSO admitting the boundaries mechanism A misses.
# =============================================================================

`%||%` <- function(x, y) if (is.null(x)) y else x

#' Canonical boundary from a "last live day" expiry (legacy `> expiry`).
boundary_from_expiry <- function(d) as.Date(d) + 1

#' Canonical boundary from a "first dead day" cutoff (legacy `>= until`).
boundary_from_until <- function(d) as.Date(d)

#' Collect every schedule boundary (FIRST-day-of-new-state convention) relevant
#' to a build. De-duplicated, sorted, NA/NULL dropped.
#'
#' Wired sources so far: IEEPA invalidation, SECTION_122 / SWISS expiries, and
#' spec active.from / active.until windows. The annex effective date, annex_3
#' sunset, and per-entry Ch99 effective_date_offsets are passed via `extra` until
#' the calc-side wiring step exposes them (TODO 3c-wiring) — kept out here rather
#' than guessing policy_params field names.
#'
#' @param policy_params load_policy_params() list, or NULL
#' @param specs         an authority_spec_set, or NULL
#' @param horizon       series horizon date, or NULL
#' @param extra         extra boundary dates (annex / Ch99 / scenario effective_from)
#' @return sorted unique Date vector of boundaries
collect_schedule_boundaries <- function(policy_params = NULL, specs = NULL,
                                        horizon = NULL, extra = NULL) {
  b <- as.Date(character())
  pp <- policy_params
  if (!is.null(pp)) {
    if (!is.null(pp$IEEPA_INVALIDATION_DATE)) {
      b <- c(b, boundary_from_until(pp$IEEPA_INVALIDATION_DATE))
    }
    if (!is.null(pp$SECTION_122) && isFALSE(pp$SECTION_122$finalized) &&
        !is.null(pp$SECTION_122$expiry_date)) {
      b <- c(b, boundary_from_expiry(pp$SECTION_122$expiry_date))
    }
    if (!is.null(pp$SWISS_FRAMEWORK) && isFALSE(pp$SWISS_FRAMEWORK$finalized) &&
        !is.null(pp$SWISS_FRAMEWORK$expiry_date)) {
      if (!is.null(pp$SWISS_FRAMEWORK$effective_date)) {
        b <- c(b, as.Date(pp$SWISS_FRAMEWORK$effective_date))
      }
      b <- c(b, boundary_from_expiry(pp$SWISS_FRAMEWORK$expiry_date))
    }
  }
  if (!is.null(specs)) {
    for (s in specs) {
      af <- s$active$from %||% NA          # first LIVE day == a boundary
      au <- s$active$until %||% NA          # first DEAD day == a boundary
      if (length(af) && !is.na(af)) b <- c(b, as.Date(af))
      if (length(au) && !is.na(au)) b <- c(b, boundary_from_until(au))
    }
  }
  if (!is.null(horizon)) b <- c(b, as.Date(horizon))
  if (!is.null(extra))   b <- c(b, as.Date(extra))
  b <- b[!is.na(b)]
  sort(unique(b))
}

#' Split points strictly inside a revision window: the dates at which a NEW
#' sub-interval STARTS. A boundary B splits (valid_from, valid_until] when
#' valid_from < B <= valid_until, giving [.., B-1] and [B, ..].
#'
#' Equivalence to the legacy splitter: legacy get_expiry_split_points() returns
#' E (= B - 1, the last live day) and 09 starts the next sub-interval at E + 1.
#' Feeding boundary_from_expiry(E) = E + 1 here returns that same start date, so
#' c(valid_from, timeline_split_points(...)) reproduces the legacy sub-interval
#' starts exactly (unit-tested) — and catches the extra boundaries too.
#'
#' @return sorted unique Date vector of sub-interval start days (empty == no split)
timeline_split_points <- function(valid_from, valid_until, boundaries) {
  vf <- as.Date(valid_from); vu <- as.Date(valid_until)
  b  <- as.Date(boundaries)
  sort(unique(b[!is.na(b) & b > vf & b <= vu]))
}

#' The parity-preserving boundary set for the downstream splitter swap: the legacy
#' expiry adjustments (SECTION_122 / SWISS) as canonical boundaries (last-live-day
#' E -> first-dead-day E+1). Depends on collect_expiry_adjustments() (helpers.R) at
#' call time. This is the bridge set; the mid-interval-activation fix adds the spec
#' active windows / annex / Ch99 offsets on top (via collect_schedule_boundaries).
expiry_boundaries <- function(policy_params) {
  adj <- collect_expiry_adjustments(policy_params)
  if (!length(adj)) return(as.Date(character()))
  e <- as.Date(vapply(adj, function(a) as.character(as.Date(a$expiry_date)), character(1)))
  sort(unique(boundary_from_expiry(e)))
}


# =============================================================================
# Boundary discovery for synthetic mints (Pass-2 unified timeline / P2-1)
# =============================================================================
# discover_boundaries() finds every schedule boundary that falls STRICTLY INSIDE
# a real revision interval and that the CALCULATOR can reproduce by an as-of
# recompute (i.e. a date the calc's own gates re-resolve). Each such boundary is
# minted into a synthetic `bnd_<date>` revision by build_boundary_mints() — the
# owning revision's archive re-run STAMPED at the boundary date, with empty
# operations. assemble_timeseries() then turns the mint into its own interval via
# rev_dates ordering, so the rate switches on the legal effective date rather than
# at the next real revision. See docs/timeline_split_integration.md.
#
# MUTUAL-EXCLUSION RULE (R4/R8: recompute-vs-zeroing drift). A boundary is handled
# by EXACTLY ONE mechanism:
#   - mint  (this module): boundaries the calc re-resolves on recompute — Ch99
#     effective_date_offsets, IEEPA invalidation (06 `>= until` gate), §232
#     country-exemption expiries (authority_adapter `rev_date < expiry` gate), and
#     (since 2026-06-25) the SECTION_122 sunset. S122's calc gate (06 `effective_date
#     <= expiry_date`) re-resolves rate_s122 = 0 on recompute, so a mint EQUALS the
#     old downstream zeroing (tests/test_mint_equals_zeroing.R) — but unlike zeroing
#     it reaches the published snapshot panel that tariff-model reads. So it moved
#     to minting: collect_schedule_boundaries() carries it, expiry_boundaries() no
#     longer lists it (so it is not subtracted below), and boundary_overrides anchors
#     it explicitly.
#   - downstream zeroing (09 + helpers.R apply_expiry_zeroing): the SWISS expiry
#     ONLY. NOT minted: a Swiss recompute reverts CH/LI to the underlying pre-floor
#     surcharge (not stored in the snapshot), whereas apply_expiry_zeroing drops it
#     to 0 — they genuinely differ. discover_boundaries therefore SUBTRACTS
#     expiry_boundaries() (now SWISS-only) from the config set. See
#     tests/test_mint_equals_zeroing.R.

#' Discover the mintable boundary set for a build.
#'
#' @param rev_dates    load_revision_dates() tibble (real grid; any pre-existing
#'   sched_/bnd_ rows are ignored when computing the real intervals).
#' @param snapshot_dir directory holding the cached `ch99_<rev>.rds` parses
#'   (data/timeseries or a scenario dir). Missing dir/caches => Ch99 scan is a
#'   no-op (config + exemption boundaries still resolve).
#' @param policy_params load_policy_params() list (drives the config boundaries,
#'   the §232 country-exemption expiries, and the horizon).
#' @param specs        optional authority_spec_set, forwarded to
#'   collect_schedule_boundaries for spec active windows (none populated today).
#' @param overrides    curated extra boundary dates (pp$BOUNDARY_OVERRIDES) — a
#'   backstop for config dates the scan can't see. Empty in baseline.
#' @param horizon      series horizon (defaults to pp$SERIES_HORIZON_END).
#' @return tibble(date, owner_rev, revision = "bnd_<date>", source), one row per
#'   boundary strictly interior to a real interval and <= horizon, sorted by date.
#'   Empty tibble (0 rows, same columns) when nothing is discovered.
discover_boundaries <- function(rev_dates, snapshot_dir = NULL, policy_params = NULL,
                                specs = NULL, overrides = NULL, horizon = NULL,
                                archive_dir = NULL) {
  empty <- tibble::tibble(date = as.Date(character()), owner_rev = character(),
                          revision = character(), source = character())
  horizon <- as.Date(horizon %||%
                     (if (!is.null(policy_params)) policy_params$SERIES_HORIZON_END else NULL) %||%
                     Sys.Date())

  # Real-revision grid: exclude any synthetic rows so intervals are the OWNER
  # archives' windows. valid_until = next_rev - 1, tip -> horizon (mirrors
  # assemble_timeseries / build_snapshot_intervals_for_daily).
  real <- rev_dates %>%
    dplyr::filter(!grepl('^(sched_|bnd_)', revision)) %>%
    dplyr::arrange(effective_date)
  if (nrow(real) == 0) return(empty)
  intervals <- real %>%
    dplyr::transmute(revision,
                     valid_from  = as.Date(effective_date),
                     valid_until = dplyr::lead(as.Date(effective_date)) - 1) %>%
    dplyr::mutate(valid_until = dplyr::if_else(is.na(valid_until), horizon, valid_until))

  # Interval owner of a date D (latest real revision with eff < D <= next_eff-1),
  # i.e. the unique interval strictly containing D. NA when D is edge-coincident
  # or outside every interval (R1 mitigation: edge boundaries never mint).
  owner_of <- function(D) {
    hit <- which(intervals$valid_from < D & D <= intervals$valid_until)
    if (length(hit) == 0) return(NA_character_)
    intervals$revision[hit[length(hit)]]
  }

  recs <- list()
  add_rec <- function(date, owner, source) {
    if (length(date) == 0 || is.na(date) || is.na(owner) || !nzchar(owner)) return(invisible())
    recs[[length(recs) + 1L]] <<- tibble::tibble(date = as.Date(date),
                                                 owner_rev = owner, source = source)
  }

  # (a) Ch99 effective_date_offset scan. For each real revision, an offset is a
  #     boundary iff it is STRICTLY INTERIOR to THAT revision's own interval —
  #     i.e. masked at the revision's effective_date (filter_active_ch99) and
  #     active by the offset. The scanning revision is the owner by construction
  #     (its archive carries the gated entry AND its interval contains the date),
  #     which is exactly the "owner-archive carries the entry" requirement: an
  #     offset interior to a LATER revision whose archive lacks it is NOT emitted.
  for (i in seq_len(nrow(intervals))) {
    rev_id <- intervals$revision[i]
    ch99 <- if (!is.null(archive_dir)) {
      tryCatch(parse_chapter99(resolve_json_path(rev_id, archive_dir)),
               error = function(e) NULL)
    } else {
      ch99_p <- file.path(snapshot_dir, paste0('ch99_', rev_id, '.rds'))
      if (!file.exists(ch99_p)) next
      tryCatch(readRDS(ch99_p), error = function(e) NULL)
    }
    if (is.null(ch99) || !'effective_date_offset' %in% names(ch99)) next
    offs <- unique(ch99$effective_date_offset)
    offs <- offs[!is.na(offs)]
    offs <- offs[offs > intervals$valid_from[i] & offs <= intervals$valid_until[i]]
    for (o in offs) add_rec(o, rev_id, paste0('ch99:', rev_id))

    # Expiry mirror: a rate-less heading active at the revision's effective_date
    # whose window ENDS interior to the interval changes state on expiry + 1
    # (the first day filter_active_ch99's expiry gate drops it, releasing the
    # §301 exclusion hook's scaling). Same owner-archive logic as the start
    # scan. Rate-bearing expiries are excluded — the calc RETAINS those rows
    # (see filter_active_ch99), so no recompute would change state.
    if ('expiry_date_offset' %in% names(ch99)) {
      exps <- unique(ch99$expiry_date_offset[is.na(ch99$rate)])
      exps <- exps[!is.na(exps)] + 1L
      exps <- exps[exps > intervals$valid_from[i] & exps <= intervals$valid_until[i]]
      for (o in exps) add_rec(o, rev_id, paste0('ch99_expiry:', rev_id))
    }
  }

  # (b) Config boundaries the CALC re-resolves on recompute: collect_schedule_
  #     boundaries() minus the SWISS expiry only (still handled downstream; see
  #     mutual-exclusion note above). Today this leaves the IEEPA invalidation date,
  #     the SECTION_122 sunset (now minted), and the Swiss effective date (+ any
  #     spec active windows, none populated).
  cfg <- collect_schedule_boundaries(policy_params = policy_params, specs = specs)
  cfg <- setdiff(as.Date(cfg), expiry_boundaries(policy_params))
  for (d in cfg) add_rec(as.Date(d, origin = '1970-01-01'), owner_of(as.Date(d, origin = '1970-01-01')),
                         'config')

  # (c) §232 country-exemption expiries. The adapter gate is `rev_date < expiry`,
  #     so `expiry` is the first day the exemption is GONE (a first-day-of-new-state
  #     boundary). collect_schedule_boundaries does NOT carry these, so add them
  #     here — this is the real signal for the 2025-03-12 metal-exemption cluster
  #     (there is no Ch99 offset for it; the derivative lines are ungated).
  if (!is.null(policy_params) && !is.null(policy_params$S232_COUNTRY_EXEMPTIONS)) {
    for (ex in policy_params$S232_COUNTRY_EXEMPTIONS) {
      if (is.null(ex$expiry_date) || length(ex$expiry_date) == 0 || is.na(ex$expiry_date)) next
      E <- as.Date(ex$expiry_date)
      add_rec(E, owner_of(E), 's232_exemption_expiry')
    }
  }

  # (d) Curated overrides backstop.
  if (!is.null(overrides) && length(overrides) > 0) {
    for (o in as.Date(overrides)) add_rec(o, owner_of(o), 'override')
  }

  if (length(recs) == 0) return(empty)
  df <- dplyr::bind_rows(recs) %>%
    dplyr::filter(!is.na(owner_rev), date <= horizon) %>%
    dplyr::group_by(date) %>%
    dplyr::summarise(owner_rev = dplyr::first(owner_rev),
                     source = paste(sort(unique(source)), collapse = '+'),
                     .groups = 'drop') %>%
    dplyr::arrange(date) %>%
    dplyr::mutate(revision = paste0('bnd_', format(date, '%Y-%m-%d'))) %>%
    dplyr::select(date, owner_rev, revision, source)
  df
}
