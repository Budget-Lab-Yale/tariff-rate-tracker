"""
Reconstruct the HTS 2026 revision 20 JSON, which USITC no longer serves.

WHY THIS IS NEEDED
------------------
hts.usitc.gov/reststop/exportList serves ONLY the current release (a
`release=` parameter is silently ignored), and the static archive host has
returned Akamai 403 for every revision since June 2026 (see
src/pipeline/02_download_hts.R). Revision 20 was current 2026-09-28 ..
2026-10-08 and was superseded by revision 21 before it was pulled -- the same
way revisions 14, 16 and 18 were lost.

WHY RECONSTRUCTION IS SOUND HERE
--------------------------------
Revision 21's change record lists its ENTIRE delta against revision 20:
subheading note 1 to chapter 38 (errata) and U.S. note 20(vvv)(i)(20) to
chapter 99 (modified). Both are legal-note TEXT, which never reaches the JSON
export -- no heading record changed. So

    rev_20 == rev_21   (record for record)

That is an identity, not an interpolation. It is checked against a SECOND,
INDEPENDENT source: revision 20's own change record, which states its delta
against revision 19 is exactly

    + 9903.04.70   pharma Section 232 clinical-trial / R&D / non-commercial
                   carve-out, U.S. note 40, effective 2026-09-29
    (no deletions; every other listed item is note 40 text)

The script asserts the reconstruction reproduces that rev_19 -> rev_20 delta
with no other record difference.

The output takes the canonical filename so the pipeline's gz-aware path
resolution consumes it like any other archive, and a PROVENANCE sidecar is
written beside it so the file can never be mistaken for an official USITC
download. `config/revision_dates.csv` also carries the flag in `needs_review`.

Usage: python scripts/reconstruct_hts_2026_rev_20.py
"""

import gzip
import io
import json
import os
import sys

ARCHIVES = os.path.join('data', 'hts_archives')
SRC21 = os.path.join(ARCHIVES, 'hts_2026_rev_21.json.gz')
SRC19 = os.path.join(ARCHIVES, 'hts_2026_rev_19.json.gz')
OUT = os.path.join(ARCHIVES, 'hts_2026_rev_20.json.gz')
PROVENANCE = os.path.join(ARCHIVES, 'hts_2026_rev_20.PROVENANCE.txt')

# The rev_20 delta, per its change record (2026-09-28).
REV20_ADDED = ['9903.04.70']

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
    for p in (SRC21, SRC19):
        if not os.path.exists(p):
            fail('missing input archive: %s' % p)

    rev21 = load(SRC21)
    rev19 = load(SRC19)

    # --- build rev_20 = rev_21 (its change record touches only note text) ----
    rev20 = rev21

    # --- verify against rev_20's OWN change record ---------------------------
    i19, i20 = index(rev19), index(rev20)
    added = sorted(set(i20) - set(i19))
    gone = sorted(set(i19) - set(i20))

    if added != sorted(REV20_ADDED):
        fail('rev_19 -> reconstructed rev_20 added %s, change record says %s'
             % (added, sorted(REV20_ADDED)))
    if gone:
        fail('rev_19 -> reconstructed rev_20 removed %s; the change record '
             'lists no deletions' % gone)
    if len(rev20) != len(rev19) + len(REV20_ADDED):
        fail('record count %d != rev_19 %d + %d added -- an unlisted record '
             'changed' % (len(rev20), len(rev19), len(REV20_ADDED)))

    # Unkeyed rows (superior/heading text, htsno '') must match in order too.
    unkeyed19 = [r for r in rev19 if not r.get('htsno')]
    unkeyed20 = [r for r in rev20 if not r.get('htsno')]
    if unkeyed19 != unkeyed20:
        fail('rev_19 -> reconstructed rev_20 changed an unnumbered text row')

    modified = {}
    for h in sorted(set(i19) & set(i20)):
        a, b = i19[h][0], i20[h][0]
        diff = [f for f in FIELDS if json.dumps(a.get(f), sort_keys=True) !=
                json.dumps(b.get(f), sort_keys=True)]
        if diff:
            modified[h] = diff
    if modified:
        fail('rev_19 -> reconstructed rev_20 modified %s; the change record '
             'lists no heading modifications' % modified)

    # --- write ---------------------------------------------------------------
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', compresslevel=9, mtime=0) as gz:
        gz.write(json.dumps(rev20, ensure_ascii=False).encode('utf-8'))
    with open(OUT, 'wb') as fh:
        fh.write(buf.getvalue())

    title = 'HTS 2026 REVISION 20 -- RECONSTRUCTED, NOT AN OFFICIAL USITC DOWNLOAD'
    prov = (
        title + '\n' + '=' * len(title) + '\n\n'
        'hts_2026_rev_20.json.gz in this directory was NOT downloaded from USITC.\n'
        'Revision 20 was current 2026-09-28..2026-10-08 and was superseded before\n'
        'its JSON was pulled; hts.usitc.gov/reststop/exportList serves only the\n'
        'CURRENT release, and the static archive host has 403d since June 2026.\n\n'
        'It was derived by scripts/reconstruct_hts_2026_rev_20.py as:\n\n'
        '    rev_20 = rev_21, record for record\n\n'
        'because revision 21\'s change record lists only subheading note 1 to\n'
        'chapter 38 (errata) and U.S. note 20(vvv)(i)(20) to chapter 99\n'
        '(modified) -- legal-note text that never reaches the JSON export.\n\n'
        'The result is verified against a SECOND, INDEPENDENT source -- revision\n'
        '20\'s own change record -- which states its delta against revision 19 is\n'
        'exactly:\n\n'
        '    + 9903.04.70   pharma Section 232 clinical-trial / R&D carve-out,\n'
        '                   U.S. note 40, effective 2026-09-29\n'
        '    (no deletions, no heading modifications)\n\n'
        'No other record differs (asserted, including unnumbered text rows).\n\n'
        'Records: rev_19 %d, reconstructed rev_20 %d, rev_21 %d.\n\n'
        'Re-derive at any time with:\n'
        '    python scripts/reconstruct_hts_2026_rev_20.py\n'
        % (len(rev19), len(rev20), len(rev21))
    )
    with io.open(PROVENANCE, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(prov)

    print('rev_19 records          : %d' % len(rev19))
    print('rev_21 records          : %d' % len(rev21))
    print('reconstructed rev_20    : %d  (== rev_21)' % len(rev20))
    print('')
    print('VERIFIED against the rev_20 change record:')
    print('  added    : %s' % ', '.join(added))
    print('  modified : (none)')
    print('  removed  : (none)')
    print('')
    print('wrote %s' % OUT)
    print('wrote %s' % PROVENANCE)


if __name__ == '__main__':
    main()
