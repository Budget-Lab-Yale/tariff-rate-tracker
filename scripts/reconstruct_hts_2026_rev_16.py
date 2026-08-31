"""
Reconstruct the HTS 2026 revision 16 JSON, which USITC no longer serves.

WHY THIS IS NEEDED
------------------
hts.usitc.gov/reststop/exportList serves ONLY the current release, and the
static archive host has returned Akamai 403 for every revision since June 2026
(see src/pipeline/02_download_hts.R). So a revision's JSON is obtainable only
while it is current. Revision 16 was current 2026-08-14 .. 2026-08-23 and was
superseded before it was pulled — the same way revision 14's JSON was lost.

WHY RECONSTRUCTION IS SOUND HERE (AND WAS NOT FOR REV 14)
---------------------------------------------------------
Revision 17's change record lists its ENTIRE delta against revision 16: U.S.
note 51 plus headings 9903.03.12-.16, all sourced to PP 11046/11047/11048 as
amended by PP 11056. Nothing else changed. So

    rev_16 == rev_17 minus those five chapter-99 heading records.

That is a deletion of five known records, not an interpolation. It is then
checked against a SECOND, INDEPENDENT source: revision 16's own change record,
which states its delta against revision 15 is exactly

    + 9903.45.30, + 9903.45.31   (quartz safeguard, U.S. note 41, PP 11051)
    ~ 7020.00.6000               (unit of quantity, 484(f))

The script asserts the reconstruction reproduces that rev_15 -> rev_16 delta
exactly. Both change records must agree with the JSON arithmetic or it stops.

The output takes the canonical filename so the pipeline's gz-aware path
resolution consumes it like any other archive, and a PROVENANCE sidecar is
written beside it so the file can never be mistaken for an official USITC
download. `config/revision_dates.csv` also carries the flag in `needs_review`.

Usage: python scripts/reconstruct_hts_2026_rev_16.py
"""

import gzip
import io
import json
import os
import sys

ARCHIVES = os.path.join('data', 'hts_archives')
SRC17 = os.path.join(ARCHIVES, 'hts_2026_rev_17.json.gz')
SRC15 = os.path.join(ARCHIVES, 'hts_2026_rev_15.json.gz')
OUT = os.path.join(ARCHIVES, 'hts_2026_rev_16.json.gz')
PROVENANCE = os.path.join(ARCHIVES, 'hts_2026_rev_16.PROVENANCE.txt')

# The rev_17 delta, per its change record (2026-08-24).
REV17_ADDED = ['9903.03.12', '9903.03.13', '9903.03.14', '9903.03.15', '9903.03.16']
# The rev_16 delta, per its change record (2026-08-14).
REV16_ADDED = ['9903.45.30', '9903.45.31']
REV16_MODIFIED = ['7020.00.60.00']

FIELDS = ['htsno', 'indent', 'description', 'superior', 'units', 'general',
          'special', 'other', 'footnotes', 'quotaQuantity', 'additionalDuties']


def load(path):
    with gzip.open(path, 'rt', encoding='utf-8') as fh:
        return json.load(fh)


def index(rows):
    out = {}
    for r in rows:
        h = r.get('htsno')
        if h:
            out.setdefault(h, []).append(r)
    return out


def fail(msg):
    sys.stderr.write('RECONSTRUCTION ABORTED: %s\n' % msg)
    sys.exit(1)


def main():
    for p in (SRC17, SRC15):
        if not os.path.exists(p):
            fail('missing input archive: %s' % p)

    rev17 = load(SRC17)
    rev15 = load(SRC15)

    # --- build rev_16 = rev_17 minus the five note-51 headings ---------------
    drop = set(REV17_ADDED)
    present = {r.get('htsno') for r in rev17} & drop
    if present != drop:
        fail('rev_17 does not carry all five note-51 headings; missing %s'
             % sorted(drop - present))

    rev16 = [r for r in rev17 if r.get('htsno') not in drop]
    removed = len(rev17) - len(rev16)
    if removed != len(REV17_ADDED):
        fail('expected to drop %d records, dropped %d — a heading appears more '
             'than once' % (len(REV17_ADDED), removed))

    # --- verify against rev_16's OWN change record ---------------------------
    i15, i16 = index(rev15), index(rev16)
    added = sorted(set(i16) - set(i15))
    gone = sorted(set(i15) - set(i16))

    if added != sorted(REV16_ADDED):
        fail('rev_15 -> reconstructed rev_16 added %s, change record says %s'
             % (added, sorted(REV16_ADDED)))
    if gone:
        fail('rev_15 -> reconstructed rev_16 removed %s; the change record '
             'lists no deletions' % gone)

    modified = []
    for h in sorted(set(i15) & set(i16)):
        a, b = i15[h][0], i16[h][0]
        if any(json.dumps(a.get(f), sort_keys=True) !=
               json.dumps(b.get(f), sort_keys=True) for f in FIELDS):
            modified.append(h)
    if modified != sorted(REV16_MODIFIED):
        fail('rev_15 -> reconstructed rev_16 modified %s, change record says %s'
             % (modified, sorted(REV16_MODIFIED)))

    # the one modification must be the documented 484(f) unit-of-quantity change
    before = i15['7020.00.60.00'][0].get('units')
    after = i16['7020.00.60.00'][0].get('units')
    if not (before == ['No.'] and after == ['No.', 'm<sup>2</sup>']):
        fail('7020.00.60.00 units changed %r -> %r, expected the 484(f) m2 '
             'addition' % (before, after))

    # --- write ---------------------------------------------------------------
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', compresslevel=9, mtime=0) as gz:
        gz.write(json.dumps(rev16, ensure_ascii=False).encode('utf-8'))
    with open(OUT, 'wb') as fh:
        fh.write(buf.getvalue())

    prov = (
        'HTS 2026 REVISION 16 -- RECONSTRUCTED, NOT AN OFFICIAL USITC DOWNLOAD\n'
        '=' * 70 + '\n\n'
        'hts_2026_rev_16.json.gz in this directory was NOT downloaded from USITC.\n'
        'Revision 16 was current 2026-08-14..2026-08-23 and was superseded before\n'
        'its JSON was pulled; hts.usitc.gov/reststop/exportList serves only the\n'
        'CURRENT release, and the static archive host has 403d since June 2026.\n\n'
        'It was derived by scripts/reconstruct_hts_2026_rev_16.py as:\n\n'
        '    rev_16 = rev_17 minus headings 9903.03.12, .13, .14, .15, .16\n\n'
        'which is revision 17\'s complete delta per its change record (U.S. note 51\n'
        '+ those five headings, PP 11046/11047/11048 as amended by PP 11056;\n'
        'nothing else changed).\n\n'
        'The result is verified against a SECOND, INDEPENDENT source -- revision\n'
        '16\'s own change record -- which states its delta against revision 15 is\n'
        'exactly:\n\n'
        '    + 9903.45.30, + 9903.45.31   quartz safeguard, U.S. note 41, PP 11051\n'
        '    ~ 7020.00.6000               unit of quantity, 484(f): No. -> No., m2\n'
        '    (no deletions)\n\n'
        'The script asserts that delta and aborts if it does not hold, so both\n'
        'change records and the JSON arithmetic must agree. This is a deletion of\n'
        'five known records, not an interpolation -- unlike revision 14, for which\n'
        'no JSON is reconstructed and only the Chapter 99 PDF and change record\n'
        'are preserved.\n\n'
        'Records: rev_15 %d, reconstructed rev_16 %d, rev_17 %d.\n\n'
        'Re-derive at any time with:\n'
        '    python scripts/reconstruct_hts_2026_rev_16.py\n'
        % (len(rev15), len(rev16), len(rev17))
    )
    with io.open(PROVENANCE, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(prov)

    print('rev_17 records          : %d' % len(rev17))
    print('rev_15 records          : %d' % len(rev15))
    print('reconstructed rev_16    : %d  (rev_17 minus %d note-51 headings)'
          % (len(rev16), removed))
    print('')
    print('VERIFIED against the rev_16 change record:')
    print('  added    : %s' % ', '.join(added))
    print('  modified : %s  units %r -> %r' % (', '.join(modified), before, after))
    print('  removed  : (none)')
    print('')
    print('wrote %s' % OUT)
    print('wrote %s' % PROVENANCE)


if __name__ == '__main__':
    main()
