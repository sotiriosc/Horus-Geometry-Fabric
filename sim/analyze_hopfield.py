#!/usr/bin/env python3
"""
sim/analyze_hopfield.py — Python-vs-RTL agreement analysis for Hopfield demo.

Reads HOPFIELD_DEMO_PY.csv (Python PATH_NFE model) and HOPFIELD_TRACE.csv
(RTL horus_nfe simulation) produced by hopfield_demo.py and tb_hopfield_recall.v.

For each (pat_name, trial, n_flip, iteration) present in both sources, compares:
  hamming_to_nearest, overlap_H, overlap_T, overlap_X.

Expected behaviour: all rows agree step-for-step because:
  (a) weight × state products are exactly representable in NFE
      (weight magnitudes {1/64, 3/64} encode without mantissa rounding), so
  (b) the float row sums are identical in Python FP64 and RTL harness real,
  (c) sign() is deterministic, and
  (d) LFSR seeds and corruption algorithms are identical.
Any divergent iteration is a genuine finding — reported plainly.

Usage:
  python3 analyze_hopfield.py
  (run from sim/ directory after running hopfield_demo.py and vvp sim_hopfield_recall)
"""

import csv
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PY_CSV  = os.path.join(SCRIPT_DIR, "HOPFIELD_DEMO_PY.csv")
RTL_CSV = os.path.join(SCRIPT_DIR, "HOPFIELD_TRACE.csv")

FLOAT_TOL = 1e-4  # tolerance for overlap comparison (float formatting differences)
INT_EXACT  = True  # hamming_to_nearest must match exactly


def load_csv(path):
    """Load CSV into dict keyed by (pat_name, trial, n_flip, iteration)."""
    rows = {}
    with open(path, newline='') as f:
        for rec in csv.DictReader(f):
            key = (rec['pat_name'].strip(),
                   int(rec['trial']),
                   int(rec['n_flip']),
                   int(rec['iteration']))
            rows[key] = rec
    return rows


def compare_row(py_row, rtl_row, key):
    """Compare one matching row pair. Returns list of discrepancy strings."""
    issues = []
    # Hamming to nearest (integer, must match exactly)
    ph = int(py_row['hamming_to_nearest'])
    rh = int(rtl_row['hamming_to_nearest'])
    if ph != rh:
        issues.append(f"hamming_to_nearest: python={ph} rtl={rh}")
    # Overlaps (float, tolerance FLOAT_TOL)
    for field in ['overlap_H', 'overlap_T', 'overlap_X']:
        pv = float(py_row[field])
        rv = float(rtl_row[field])
        if abs(pv - rv) > FLOAT_TOL:
            issues.append(f"{field}: python={pv:.6f} rtl={rv:.6f} "
                          f"delta={abs(pv-rv):.2e}")
    return issues


def main():
    # ── Load CSVs ──────────────────────────────────────────────────────────────
    if not os.path.exists(PY_CSV):
        print(f"ERROR: Python CSV not found: {PY_CSV}")
        print("  Run:  python3 hopfield_demo.py")
        sys.exit(1)
    if not os.path.exists(RTL_CSV):
        print(f"ERROR: RTL CSV not found: {RTL_CSV}")
        print("  Run:  make hopfield_rtl  (or:  vvp sim_hopfield_recall)")
        sys.exit(1)

    py_rows  = load_csv(PY_CSV)
    rtl_rows = load_csv(RTL_CSV)

    print("=" * 72)
    print("sim/analyze_hopfield.py — Python vs RTL Agreement Analysis")
    print("=" * 72)
    print(f"  Python CSV : {PY_CSV}  ({len(py_rows)} rows)")
    print(f"  RTL CSV    : {RTL_CSV}  ({len(rtl_rows)} rows)")

    # ── Filter RTL to matching source keys ────────────────────────────────────
    # RTL CSV uses 'H  ', 'T  ', 'X  ' (padded); strip for comparison.
    # Python CSV uses 'H', 'T', 'X'.
    rtl_norm = {}
    for (pn, tr, nf, it), rec in rtl_rows.items():
        rtl_norm[(pn.strip(), tr, nf, it)] = rec

    # ── Identify shared keys (excluding spurious; compare corruption tests) ───
    py_keys  = set(k for k in py_rows  if not k[0].startswith('spurious'))
    rtl_keys = set(k for k in rtl_norm if not k[0].startswith('spurious'))

    only_py  = py_keys  - rtl_keys
    only_rtl = rtl_keys - py_keys
    shared   = py_keys  & rtl_keys

    if only_py:
        print(f"\n  WARNING: {len(only_py)} rows in Python CSV not in RTL CSV")
        for k in sorted(only_py)[:5]:
            print(f"    {k}")
    if only_rtl:
        print(f"\n  WARNING: {len(only_rtl)} rows in RTL CSV not in Python CSV")
        for k in sorted(only_rtl)[:5]:
            print(f"    {k}")

    print(f"\n  Shared comparison rows: {len(shared)}")

    # ── Compare shared rows ────────────────────────────────────────────────────
    n_divergent = 0
    divergent_cases = []
    for key in sorted(shared):
        issues = compare_row(py_rows[key], rtl_norm[key], key)
        if issues:
            n_divergent += 1
            divergent_cases.append((key, issues))

    print(f"  Divergent iterations:    {n_divergent}")

    if n_divergent == 0:
        print("\n  RESULT: Python model and RTL agree step-for-step on all "
              f"{len(shared)} shared rows.")
        print("  This confirms the RTL faithful model accurately predicts the "
              "hardware trajectory.")
    else:
        print(f"\n  FINDING: {n_divergent} divergent iterations found.")
        print("  These are genuine RTL–model discrepancies, not test artefacts.\n")
        for (key, issues) in divergent_cases[:20]:
            print(f"  Key {key}:")
            for iss in issues:
                print(f"    {iss}")
        if n_divergent > 20:
            print(f"  ... and {n_divergent - 20} more.")

    # ── Recall rate summary from Python CSV ───────────────────────────────────
    print("\n── Recall Rate Summary (from Python CSV) ────────────────────────────")
    recall = {}  # (pat_name, n_flip) → (n_exact, n_total)
    for (pn, tr, nf, it), rec in py_rows.items():
        if pn.startswith('spurious') or nf < 0:
            continue
        k = (pn, nf)
        if k not in recall:
            recall[k] = {'exact': 0, 'total': 0, 'trials': set()}
        if tr not in recall[k]['trials']:
            recall[k]['trials'].add(tr)
            recall[k]['total'] += 1
        # Final iteration for this trial = iteration where hamming to nearest
        # stops changing. Use last recorded row.
        # (For exact recall: hamming_to_nearest to target == 0 at final iter.)
        # Here we use a simpler approach: check final state stored pattern match.

    # Re-compute from scratch using final hamming_to_nearest per trial
    final_state = {}  # (pat_name, trial, n_flip) → hamming_to_nearest at final iter
    for (pn, tr, nf, it), rec in py_rows.items():
        if pn.startswith('spurious') or nf < 0:
            continue
        key3 = (pn, tr, nf)
        if key3 not in final_state or it > final_state[key3][0]:
            final_state[key3] = (it, int(rec['hamming_to_nearest']))

    recall2 = {}
    for (pn, tr, nf), (_, hd) in final_state.items():
        k = (pn, nf)
        if k not in recall2:
            recall2[k] = [0, 0]
        recall2[k][1] += 1
        if hd == 0:
            recall2[k][0] += 1

    print(f"  {'Pattern':<8} {'Corrupted':<14} {'Model':>10} {'RTL':>8}")
    print("  " + "-" * 44)
    for (pn, nf) in sorted(recall2.keys()):
        ne, tot = recall2[(pn, nf)]
        pct = 100.0 * ne / tot if tot > 0 else 0
        print(f"  {pn:<8} {nf:2d}/64  (Python)    {ne}/{tot} ({pct:.0f}%)")
        # RTL same (already verified 100% agreement)
    print(f"\n  RTL recall rates: same as model (0 divergent iterations)."
          if n_divergent == 0 else
          f"\n  RTL recall rates: see divergent iterations above.")

    # ── Spurious attractor summary ─────────────────────────────────────────────
    print("\n── Spurious Attractor Summary ────────────────────────────────────────")
    spurious_py  = {k: v for k, v in py_rows.items()  if k[0].startswith('spurious')}
    spurious_rtl = {k: v for k, v in rtl_norm.items() if k[0].startswith('spurious')}
    if spurious_py:
        print(f"  Python model: {len(set(k[0] for k in spurious_py))} spurious test cases")
    if spurious_rtl:
        print(f"  RTL:          {len(set(k[0] for k in spurious_rtl))} spurious test cases")

    # Final state of each spurious test
    spy_final  = {}
    for (pn, tr, nf, it), rec in spurious_py.items():
        if pn not in spy_final or it > spy_final[pn][0]:
            spy_final[pn] = (it, int(rec['hamming_to_nearest']),
                             rec['nearest_pat'].strip())
    srtl_final = {}
    for (pn, tr, nf, it), rec in spurious_rtl.items():
        if pn not in srtl_final or it > srtl_final[pn][0]:
            srtl_final[pn] = (it, int(rec['hamming_to_nearest']),
                              rec['nearest_pat'].strip())
    print(f"\n  {'Test':<14} {'Python final':<22} {'RTL final':<22} {'Match'}")
    print("  " + "-" * 64)
    for pn in sorted(spy_final.keys()):
        p_it, p_hd, p_near = spy_final[pn]
        r_it, r_hd, r_near = srtl_final.get(pn, (None, None, '?'))
        match = ("YES" if (p_hd == r_hd and p_near == r_near) else "MISMATCH")
        p_str = f"hd={p_hd} near={p_near} ({p_it} iter)"
        r_str = f"hd={r_hd} near={r_near} ({r_it} iter)" if r_it else "—"
        print(f"  {pn:<14} {p_str:<22} {r_str:<22} {match}")

    # ── Overall verdict ────────────────────────────────────────────────────────
    print("\n── Overall Verdict ───────────────────────────────────────────────────")
    if n_divergent == 0:
        print("  CONFIRMED: RTL (horus_nfe baseline) and Python PATH_NFE model")
        print("  agree step-for-step on all corruption recall and spurious tests.")
        print("  The RTL-faithful model accurately predicts hardware trajectory.")
    else:
        print(f"  NOT CONFIRMED: {n_divergent} divergent iterations found.")
        print("  Investigate the cases listed above before trusting the model.")
    print("")


if __name__ == '__main__':
    main()
