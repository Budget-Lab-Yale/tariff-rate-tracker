"""
Reconstruct the HTS 2026 revision 18 JSON, which USITC no longer serves.

WHY THIS IS NEEDED
------------------
hts.usitc.gov/reststop/exportList serves ONLY the current release (a
`release=` parameter is silently ignored — it returns the current release
byte-for-byte), and the static archive host has returned Akamai 403 for every
revision since June 2026 (see src/pipeline/02_download_hts.R). Revision 18 was
current 2026-09-02 .. 2026-09-14 and was superseded before it was pulled — the
same way revisions 14 and 16 were lost.

WHY RECONSTRUCTION IS SOUND HERE
--------------------------------
Revision 19's change record lists its ENTIRE delta against revision 18:
U.S. note 51(b)(1), 51(b)(3) and 51(c) modified (PP 11064 / PP 11065, the
Section 338 Canada scope changes). All three are legal-note TEXT, which never
reaches the JSON export — no heading record changed. So

    rev_18 == rev_19   (record for record)

That is an identity, not an interpolation. It is checked against a SECOND,
INDEPENDENT source: revision 18's own change record, which states its delta
against revision 17 is exactly

    + 9903.08.20 - 9903.08.26   drone Section 232, U.S. note 43, PP 11055
    + 9903.54.02                lean beef trimmings quota, U.S. note 7, PP 11059
    (no deletions; every other listed item is note text)

The script asserts the reconstruction reproduces that rev_17 -> rev_18 delta.
It tolerates exactly one further record difference, which neither change
record lists because both exclude "minor nonsubstantive format adjustments":
2908.91.00.00's special-rate field drops a duplicated 'L' program code
('...,JO,L,KR,L,...' -> '...,JO,KR,L,...'). The program SET is unchanged, and
the script asserts that. Which of rev_18 / rev_19 made that edit is
unknowable; it is rate-neutral either way.

The output takes the canonical filename so the pipeline's gz-aware path
resolution consumes it like any other archive, and a PROVENANCE sidecar is
written beside it so the file can never be mistaken for an official USITC
download. `config/revision_dates.csv` also carries the flag in `needs_review`.

Usage: python scripts/reconstruct_hts_2026_rev_18.py
"""

import gzip
import io
import json
import os
import sys

ARCHIVES = os.path.join('data', 'hts_archives')
SRC19 = os.path.join(ARCHIVES, 'hts_2026_rev_19.json.gz')
SRC17 = os.path.join(ARCHIVES, 'hts_2026_rev_17.json.gz')
OUT = os.path.join(ARCHIVES, 'hts_2026_rev_18.json.gz')
PROVENANCE = os.path.join(ARCHIVES, 'hts_2026_rev_18.PROVENANCE.txt')

# The rev_18 delta, per its change record (2026-09-02).
REV18_ADDED = ['9903.08.20', '9903.08.21', '9903.08.22', '9903.08.23',
               '9903.08.24', '9903.08.25', '9903.08.26', '9903.54.02']
# Unlisted nonsubstantive edit, tolerated only in the 'special' field.
FORMAT_ONLY = '2908.91.00.00'

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


def program_codes(special):
    inside = special[special.index('(') + 1:special.rindex(')')]
    return [c.strip() for c in inside.split(',')]


def main():
    for p in (SRC19, SRC17):
        if not os.path.exists(p):
            fail('missing input archive: %s' % p)

    rev19 = load(SRC19)
    rev17 = load(SRC17)

    # --- build rev_18 = rev_19 (its change record touches only note text) ----
    rev18 = rev19

    # --- verify against rev_18's OWN change record ---------------------------
    i17, i18 = index(rev17), index(rev18)
    added = sorted(set(i18) - set(i17))
    gone = sorted(set(i17) - set(i18))

    if added != sorted(REV18_ADDED):
        fail('rev_17 -> reconstructed rev_18 added %s, change record says %s'
             % (added, sorted(REV18_ADDED)))
    if gone:
        fail('rev_17 -> reconstructed rev_18 removed %s; the change record '
             'lists no deletions' % gone)
    if len(rev18) != len(rev17) + len(REV18_ADDED):
        fail('record count %d != rev_17 %d + %d added — an unlisted record '
             'changed' % (len(rev18), len(rev17), len(REV18_ADDED)))

    modified = {}
    for h in sorted(set(i17) & set(i18)):
        a, b = i17[h][0], i18[h][0]
        diff = [f for f in FIELDS if json.dumps(a.get(f), sort_keys=True) !=
                json.dumps(b.get(f), sort_keys=True)]
        if diff:
            modified[h] = diff
    if sorted(modified) != [FORMAT_ONLY] or modified[FORMAT_ONLY] != ['special']:
        fail('rev_17 -> reconstructed rev_18 modified %s; the change record '
             'lists no heading modifications (only %s special is tolerated)'
             % (modified, FORMAT_ONLY))

    before = i17[FORMAT_ONLY][0]['special']
    after = i18[FORMAT_ONLY][0]['special']
    if set(program_codes(before)) != set(program_codes(after)):
        fail('%s special-program SET changed %r -> %r — not format-only'
             % (FORMAT_ONLY, before, after))

    # --- write ---------------------------------------------------------------
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', compresslevel=9, mtime=0) as gz:
        gz.write(json.dumps(rev18, ensure_ascii=False).encode('utf-8'))
    with open(OUT, 'wb') as fh:
        fh.write(buf.getvalue())

    title = 'HTS 2026 REVISION 18 -- RECONSTRUCTED, NOT AN OFFICIAL USITC DOWNLOAD'
    prov = (
        title + '\n' + '=' * len(title) + '\n\n'
        'hts_2026_rev_18.json.gz in this directory was NOT downloaded from USITC.\n'
        'Revision 18 was current 2026-09-02..2026-09-14 and was superseded before\n'
        'its JSON was pulled; hts.usitc.gov/reststop/exportList serves only the\n'
        'CURRENT release, and the static archive host has 403d since June 2026.\n\n'
        'It was derived by scripts/reconstruct_hts_2026_rev_18.py as:\n\n'
        '    rev_18 = rev_19, record for record\n\n'
        'because revision 19\'s change record lists only U.S. note 51(b)(1),\n'
        '51(b)(3) and 51(c) as modified (PP 11064 / 11065, Section 338 Canada\n'
        'scope) -- legal-note text that never reaches the JSON export.\n\n'
        'The result is verified against a SECOND, INDEPENDENT source -- revision\n'
        '18\'s own change record -- which states its delta against revision 17 is\n'
        'exactly:\n\n'
        '    + 9903.08.20 - .26   drone Section 232, U.S. note 43, PP 11055\n'
        '    + 9903.54.02         lean beef trimmings quota, note 7, PP 11059\n'
        '    (no deletions, no heading modifications)\n\n'
        'One unlisted, nonsubstantive record edit is tolerated: 2908.91.00.00\'s\n'
        'special-rate field drops a duplicated \'L\' program code (same program\n'
        'set, asserted). Both change records exclude "minor nonsubstantive format\n'
        'adjustments", so which revision made it is unknowable; rate-neutral.\n\n'
        'Records: rev_17 %d, reconstructed rev_18 %d, rev_19 %d.\n\n'
        'Re-derive at any time with:\n'
        '    python scripts/reconstruct_hts_2026_rev_18.py\n'
        % (len(rev17), len(rev18), len(rev19))
    )
    with io.open(PROVENANCE, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(prov)

    print('rev_17 records          : %d' % len(rev17))
    print('rev_19 records          : %d' % len(rev19))
    print('reconstructed rev_18    : %d  (== rev_19)' % len(rev18))
    print('')
    print('VERIFIED against the rev_18 change record:')
    print('  added    : %s' % ', '.join(added))
    print('  modified : (none; %s special format-only: %r -> %r)'
          % (FORMAT_ONLY, before, after))
    print('  removed  : (none)')
    print('')
    print('wrote %s' % OUT)
    print('wrote %s' % PROVENANCE)


if __name__ == '__main__':
    main()
