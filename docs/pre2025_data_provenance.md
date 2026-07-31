# Pre-2025 raw-data provenance (Phase 1 acquisition)

**Date:** 2026-07-30. **Scope:** the raw inputs a 2016–2024 statutory build will
need. This is acquisition and verification only — no build, no config change.
Phase plan and locked decisions live in
`docs/internal/pre2025_expansion_scoping_2026-07-28.md`.

Nothing in the 2025–2026 product changes as a result of this work. No archive
binaries are committed: everything lands in a shared store outside the repo, and
the repo carries only the tooling, this note, and the coverage inventory
`resources/pre2025_hts_inventory.csv`.

---

## 1. Where the data lives

Shared store (source of truth), mirroring the `Census-IMDB` pattern:

```
/nfs/roberts/project/pi_nrs36/shared/raw_data/USITC-HTS-Archive/
  json/          hts_<revision_id>.json.gz        HTS editions (gzipped, repo convention)
  zips/          tariff_data_<year>.zip           USITC Annual Tariff Database
  pdf/           ch99_<revision_id>.pdf           Chapter 99, gap-filler
                 change_record_<revision_id>.pdf  per-release change record
  manifest.csv   one row per stored artifact
```

Override with `HTS_ARCHIVE_STORE_DIR` (same shape as `IMDB_STORE_DIR` in
`src/io/build_import_weights.R`).

`manifest.csv` columns: `path, url, key, kind, bytes, md5, retrieved,
origin_url, wayback_timestamp, release_name, revision_id, validation,
n_records, notes`. The first seven match the Census-IMDB manifest; the rest are
the provenance this source needs (which Wayback capture, which USITC release,
what the validator concluded).

**The archives are deliberately NOT copied into `data/hts_archives/`.** That is a
~70 MB, one-way addition to git history; whether to make it is a separate
decision after this coverage report is reviewed.

## 2. Sources and URL patterns

| Source | Host | Reachable from the cluster? | Route used |
|---|---|---|---|
| Release list `reststop/releaseList` | `hts.usitc.gov` | yes | direct |
| Chapter 99 / Change Record `reststop/file?release=<name>&filename=<f>` | `hts.usitc.gov` | yes | direct |
| HTS JSON editions `/sites/default/files/tata/hts/hts_<year>_<edition>*.json` | `www.usitc.gov` | **no — Akamai 403** | Wayback |
| Annual Tariff Database `/tariff_affairs/documents/tariff_data/tariff_data_<year>.zip` | `www.usitc.gov` | **no — Akamai 403** | Wayback |
| Annual-DB year index `assets/content/lists/tariff_annual.json` | `dataweb.usitc.gov` | yes | direct |
| Wayback CDX index `cdx/search/cdx` | `web.archive.org` | yes | direct |

### The Akamai/Wayback routing

`www.usitc.gov` returns Akamai "Access Denied" (HTTP 403) to all automated
access from this cluster — the same block that broke
`src/pipeline/02_download_hts.R` for retrospective revisions in June 2026. Every
`www.usitc.gov` artifact is therefore fetched through the Wayback Machine:

1. enumerate captures from the CDX index, e.g.
   `http://web.archive.org/cdx/search/cdx?url=usitc.gov/sites/default/files/tata/hts/hts_2018*&output=text&fl=original,timestamp,statuscode,length&filter=statuscode:200`
2. fetch the chosen capture with the raw-replay suffix `id_`, e.g.
   `https://web.archive.org/web/20250410141706id_/https://www.usitc.gov/sites/default/files/tata/hts/hts_2018_revision_13_data.json`
   (`id_` returns the original bytes with no Wayback rewriting).

`collapse=` is never passed to CDX: collapsing hides good captures. The CDX
`length` field is the compressed WARC record length, not the uncompressed file
size — it is used only to *rank* candidate captures, never as a size assertion.

`hts.usitc.gov` is a different origin and is **not** blocked, which is why the
Chapter 99 PDFs and Change Records are fetched from it directly. Note the
standing trap: `hts.usitc.gov/reststop/exportList?release=<name>` returns HTTP
200 with **current-release** data — the `release` parameter does not exist in
that API — so it is never used here.

## 3. Naming: USITC releases → tracker revision ids

USITC release names are inconsistent across years
(`2018BasicEdition`, `2018HTSARevision1_1`, `2019HTSABASICA`, `2019HTSAREV8b`,
`2020HTSABasicB`, `2021HTSAPrelimRev2`, `2022HTSABasicRev1B`, `2023HTSARev4a`,
`2024HTSBasic`), and the archived JSON filenames follow a *second*, equally
inconsistent convention (`hts_2018_basic_json_0.json`,
`hts_2019_rev_15_data_json.json`, `hts_2020_revsision_3_json.json` — note the
typo —, `hts_2021_revision_basic_10_json.json`,
`hts_2022_basic_and_revision_1_json.json`, `hts_2023_basic_edition_json.json`).

`tools/pre2025_archive_lib.R` normalises **both** onto one key
`(year, kind, number, subnumber)` and derives the tracker revision id with the
existing convention from `src/model/revisions.R::parse_revision_id` — 2025 is
the unprefixed namespace, every other year is `<year>_<rev>`:

| Edition | Revision id |
|---|---|
| basic edition | `2018_basic` |
| revision N | `2019_rev_7` |
| revision N sub-revision M (2018 only) | `2018_rev_1_1` |
| preliminary edition (2021, 2022) | `2021_prelim` |
| preliminary revision N (2021) | `2021_prelim_rev_2` |
| pre-2018 named releases | `2016_chapter98`, `2017_nte`, … |

Filename→release matching is exact on all four key parts where possible. Where a
JSON filename carries only the base revision number but USITC's release list has
only a re-issued sub-revision (`hts_2018_revision_11_data.json` vs release
`2018HTSARevision11_1`), the match falls back to `(year, kind, number)` when
that is unique. The fallback is recorded per row in the inventory as
`json_release_match = number_only` so Phase 2 can see which mappings are
inferred rather than exact.

**Phase 2 caveat:** `build_release_name()` in `src/model/revisions.R` returns
`NA` for any year < 2025 and parses `rev_N` with `as.integer()`, so the
sub-revision ids (`2018_rev_1_1`) and the preliminary ids (`2021_prelim`) will
not round-trip through it. Nothing in the current build calls it for those
years; generalising it is Phase 2 work.

## 4. Validation rules, and why each exists

Applied by `validate_hts_json()` to every candidate capture before it is stored.
The per-file outcome is recorded in `manifest.csv` (`validation`, `n_records`,
and the marker counts in `notes`) and surfaced in the inventory.

| Rule | Action | Why |
|---|---|---|
| File must parse as a JSON record array | reject `unparseable` | **Wayback truncates large captures at exactly 1 MiB.** A truncated JSON array cannot parse, so this is the primary truncation detector. Ranking candidates largest-first means the truncated ones are usually never reached. |
| Must carry `htsno, indent, description, general, special, other` | reject `missing_cols_*` | Guards against a capture of some other JSON (search index, error body) served under the same path. |
| `n_records >= 20000` | reject `too_few_records_N` | Genuine editions are ~33–36k records (2016 supplemental: 32,830). A "200" capture of a few hundred records is a stub. |
| No `9903.01.25` / `9903.01.63` heading | reject `current_era_ieepa_headings` | **The content assertion.** Those are 2025 IEEPA headings; their presence in a pre-2025 file means we were silently served current data (the `exportList?release=` trap, or a bad Wayback redirect). Any `9903.01.*` at all is additionally counted and warned about. |
| Edition in force ≥ 2018-07-06 must contain `9903.88.*` | reject `missing_s301_headings` | Positive era marker: Section 301 List 1 headings appear from that date. Absence means the capture is from an earlier era than its filename claims. Skipped when the file has no Chapter 99 rows at all (warned instead). |
| Edition in force < 2018-07-06 must **not** contain `9903.88.*` | reject `unexpected_s301_headings` | The mirror check: catches a later edition served under an earlier name. |
| Edition in force ≥ 2018-03-23 should contain `9903.80.*` | warn | Section 232 steel marker. Warn, not reject, because heading renumbering across editions could produce false negatives. |
| `9903.88.03` rate = +10% before 2019-05-10, +25% after | warn, value recorded | List 3 stepped up on 2019-05-10. A file whose List-3 rate disagrees with its own in-force window is a strong signal of an era mix-up; the heading text is free-form so it is reported, not enforced. |
| gzip round-trip reads back completely | drop the file | Catches a corrupt/truncated compressed member at write time rather than at Phase-2 build time. |
| md5 of the stored artifact | recorded | Idempotency: a re-run re-fetches anything whose md5 no longer matches the manifest. |

Zips get a structural check only (must open as a zip with ≥1 member); PDFs must
begin with `%PDF-`. Semantic validation of the Annual Tariff Database is Phase 2's
per-year sniffing loader.

**Politeness and retries.** ~1.5 s between requests, 4 attempts with 5/20/60 s
backoff, and a single failure is always treated as retryable rather than as
absence — the same lesson the Census IMDB sweep produced (census.gov throttling
generates spurious non-200s that look like gaps). A year that yields zero CDX
captures aborts the run rather than silently recording "no JSON".

## 5. Coverage

<!-- COVERAGE-START -->
| Year | Releases | JSON editions | Ch99 PDF | Change Record |
|---|---|---|---|---|
| 2016 | 2 | 1 | 2 | 2 |
| 2017 | 2 | 1 | 2 | 2 |
| 2018 | 19 | 8 | 19 | 19 |
| 2019 | 21 | 17 | 21 | 21 |
| 2020 | 29 | 29 | 29 | 29 |
| 2021 | 17 | 17 | 17 | 17 |
| 2022 | 14 | 14 | 14 | 14 |
| 2023 | 12 | 12 | 12 | 12 |
| 2024 | 11 | 11 | 11 | 11 |
| **Total** | **127** | **110** | **127** | **127** |

JSON editions carry **32,830–35,810 records** (median 34,389) — every file a
full edition; no truncated capture survived validation. §301 headings
(`9903.88.*`) appear in 106 of 110 editions, and the **List 3 rate reads 10% in
6 editions and 25% in 97** — the 2018-09-24 → 2019-05-09 step is visible in the
data, which is the strongest available evidence that these are genuine
historical captures rather than current-release data served under a historical
URL.

Validation outcomes: 109 `ok`, 1 `ok_with_warnings`, **0 failures**. Release-name
matching: 106 exact, 2 number-only, 2 unmatched (`2016_supplemental`, `2017_prelim` — real
editions Wayback holds that correspond to no named release in the API list).

### The 19 releases with NO usable JSON

Phase 2 must build these from the Chapter 99 PDF + annual tariff database
(`source_for_phase2 = chapter99_pdf+annual_db` in the inventory):

- `2016_chapter98` (chapter98, eff. 2016-05-17)
- `2016_chapter99` (Chapter99, eff. 2016-11-17)
- `2017_basiccorrections2` (basicCorrections2, eff. 2017-02-09)
- `2017_nte` (NTE, eff. 2017-10-30)
- `2018_rev_1_1` (2018HTSARevision1_1, eff. 2018-02-08)
- `2018_rev_1_2` (2018HTSARevision1_2, eff. 2018-02-28)
- `2018_rev_2` (2018HTSARevision2, eff. 2018-03-23)
- `2018_rev_2_1` (2018HTSARevision2_1, eff. 2018-03-29)
- `2018_rev_3` (2018HTSARevision3, eff. 2018-04-25)
- `2018_rev_4` (2018HTSARevision4, eff. 2018-05-01)
- `2018_rev_4_1` (2018HTSARevision4_1, eff. 2018-05-15)
- `2018_rev_5_1` (2018HTSARevision5_1, eff. 2018-06-06)
- `2018_rev_6` (2018HTSARevision6, eff. 2018-06-29)
- `2018_rev_7_1` (2018HTSARevision7_1, eff. 2018-07-11)
- `2018_rev_9` (2018HTSARevision9, eff. 2018-08-16)
- `2019_rev_3` (2019HTSAREV3, eff. 2019-04-18)
- `2019_rev_10` (2019HTSARev10, eff. 2019-07-31)
- `2019_rev_12` (2019HTSARev12, eff. 2019-08-30)
- `2019_rev_18` (2019HTSARev18, eff. 2019-11-29)

The 2018 gap is the consequential one: **`2018_rev_2` (eff. 2018-03-23) is the
§232 steel/aluminum start**, and the first 2018 edition with JSON is
`2018_rev_8_1` (2018-08-07) — a ~4.5-month blind spot in machine-readable form.
The annual tariff database carries the correct `begin_effect_date` for those
provisions, which is why it is the designated spine for the era.
<!-- COVERAGE-END -->

## 6. Census IMDB monthly weights — verification only

The monthly Census merchandise-import files were acquired in a prior sweep and
were **not** re-downloaded here. Verified 2026-07-30 against
`/nfs/roberts/project/pi_nrs36/shared/raw_data/Census-IMDB/manifest.csv` and the
directory contents:

- **137 of 137 months present, 2015-01 through 2026-05, with no gaps** (the
  expected month sequence matches the manifest exactly — no missing, no extras).
- **274 artifacts**: one source `zips/IMDB<yy><mm>.ZIP` and one parsed
  `detail/imdb_detail_<YYYY>-<MM>.parquet` for every month.
- **All 274 rows carry an md5**; the files are present on disk (137 zips, 137
  parquet).
- **24,450,273,616 bytes total (24.5 GB)**; retrieved 2026-07-15 … 2026-07-27.

Source pattern:
`https://www.census.gov/trade/downloads/<YYYY>/Merch/im_m/IMDB<yy><mm>.ZIP`
(`www.census.gov` is reachable from the cluster). The store is already wired
into the build through `IMDB_STORE_DIR` in `src/io/build_import_weights.R`.
Re-downloading it would cost ~17 GB of transfer for no new information.

## 7. How to re-run

Everything is idempotent: an artifact that is present, md5-matched and validated
is skipped, so a re-run only fills gaps or repairs damage.

```bash
# Full sweep (Slurm — interactive sessions are 5 GB capped and would OOM)
sbatch scripts/submit_pre2025_acquisition.sh

# Enumerate only, no downloads
sbatch scripts/submit_pre2025_acquisition.sh --dry-run

# Individual steps (from the repo root, after: module load R/4.4.2-gfbf-2024a)
Rscript tools/pre2025_fetch_hts_json.R --years 2018,2019
Rscript tools/pre2025_fetch_annual_db.R --years 2015,2016
Rscript tools/pre2025_fetch_chapter99.R --years 2018 --all-ch99
Rscript tools/pre2025_build_inventory.R
```

Logs land in `~/slurm-logs/pre2025-acquire-<jobid>.{out,err}`; the R progress
messages go to **stderr**, so the `.err` file is the interesting one.

To force a re-fetch of a single artifact, delete its row from
`manifest.csv` (or the file itself) and re-run the relevant step.
