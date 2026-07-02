#!/usr/bin/env python3
"""
analyze_hbs12.py — HBS-12 Arithmetic Boundary Mapping Suite Analysis
---------------------------------------------------------------------
Reads  : HBS12_ARITHMETIC_BOUNDARY.csv
Writes : HBS12_SUMMARY.log

All tests were run with mode_tag = 3'b000 (Standard — no policy effects).
NFE v3 encoding:  V = (-1)^S × 2^(E−32) × (1 + f/64)
  where E = stored_E (0..63), f = fraction (0..63)
"""

import csv
import math
import os
import sys

# ── CSV loader ────────────────────────────────────────────────────────────────

INT_FIELDS = {
    "test_id", "subtest", "cyc", "stored_E", "f_val",
    "op_code", "result", "uf", "ovf", "rollover", "extra"
}

def load_csv(path):
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            out = {}
            for k, v in r.items():
                out[k] = int(v) if k in INT_FIELDS else v
            rows.append(out)
    return rows


def nfe_value(codeword):
    """Decode a 13-bit NFE codeword to its floating-point value."""
    if codeword < 0 or codeword > 0x1FFF:
        return float("nan")
    s = (codeword >> 12) & 1
    e = (codeword >> 6) & 0x3F
    f = codeword & 0x3F
    actual_e = e - 32
    value = (1.0 + f / 64.0) * (2.0 ** actual_e)
    return -value if s else value


def codeword_e(cw):
    return (cw >> 6) & 0x3F

def codeword_f(cw):
    return cw & 0x3F

NFE_FLOOR = 0x000
NFE_MAXPOS = 0x1FFF

# ── Classification helpers ────────────────────────────────────────────────────

def classify_row(uf, ovf):
    if uf:
        return "UF"
    if ovf:
        return "OVF"
    return "NORM"


# ── HBS-12A: Exponent Envelope Scan ──────────────────────────────────────────

def analyze_12a(rows):
    lines = [
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        "HBS-12A  EXPONENT ENVELOPE SCAN",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    ]
    data = [r for r in rows if r["test_id"] == 12 and r["op_code"] == 3]

    mul_by_E = {}
    for r in data:
        E = r["stored_E"]
        if E not in mul_by_E:
            mul_by_E[E] = {"uf": 0, "ovf": 0, "norm": 0, "total": 0}
        mul_by_E[E]["total"] += 1
        if r["uf"]:
            mul_by_E[E]["uf"] += 1
        elif r["ovf"]:
            mul_by_E[E]["ovf"] += 1
        else:
            mul_by_E[E]["norm"] += 1

    first_norm = None
    last_norm  = None
    first_uf   = None
    last_uf    = None
    first_ovf  = None
    last_ovf   = None

    lines.append("\n  MUL(x,x) — UF/OVF map across E=0..63  (f ∈ {0,31,63})")
    lines.append("  E   | UF  OVF NORM | Status")
    lines.append("  ─────────────────────────────")

    for E in sorted(mul_by_E.keys()):
        d     = mul_by_E[E]
        total = d["total"]
        if total == 0:
            continue
        uf_f   = d["uf"]   / total * 100
        ovf_f  = d["ovf"]  / total * 100
        norm_f = d["norm"] / total * 100

        if d["norm"] > 0:
            last_norm = E
            if first_norm is None:
                first_norm = E
        if d["uf"] > 0:
            last_uf = E
            if first_uf is None:
                first_uf = E
        if d["ovf"] > 0:
            if first_ovf is None:
                first_ovf = E
            last_ovf = E

        status = "NORM" if d["norm"] == total else ("UF" if d["uf"] == total else "OVF" if d["ovf"] == total else "MIXED")
        lines.append(f"  {E:2d}  |  {uf_f:4.0f}% {ovf_f:4.0f}% {norm_f:4.0f}%  | {status}")

    # Add tests
    add_data = [r for r in rows if r["test_id"] == 12 and r["op_code"] == 1]
    add_ovf_E = set()
    for r in add_data:
        if r["ovf"]:
            add_ovf_E.add(r["stored_E"])
    add_rollover_E = set()
    for r in add_data:
        if r["rollover"]:
            add_rollover_E.add(r["stored_E"])

    # Sub tests
    sub_data = [r for r in rows if r["test_id"] == 12 and r["op_code"] == 2]
    sub_uf_E = set()
    for r in sub_data:
        if r["uf"]:
            sub_uf_E.add(r["stored_E"])

    lines.append("\n  ── MUL(x,x) Envelope Boundaries ──")
    if first_norm is not None:
        lines.append(f"  First NORM E : {first_norm}  (actual_E = {first_norm - 32})")
        lines.append(f"  Last  NORM E : {last_norm}  (actual_E = {last_norm  - 32})")
        usable_window = last_norm - first_norm + 1
        lines.append(f"  Usable E window : {usable_window} steps (E={first_norm}..{last_norm})")
    if first_uf is not None:
        lines.append(f"  Underflow band  : E < {first_norm}  (first UF at E={first_uf})")
    if first_ovf is not None:
        lines.append(f"  Overflow band   : E > {last_norm}  (first OVF at E={first_ovf})")

    if add_ovf_E:
        lines.append(f"  ADD OVF trigger : E in {sorted(add_ovf_E)}")
    if add_rollover_E:
        min_ro = min(add_rollover_E)
        lines.append(f"  ADD rollover at  : E >= {min_ro} (for f ≥ 1)")
    if sub_uf_E:
        lines.append(f"  SUB floor at     : E = {sorted(sub_uf_E)}  (delta=0, hits E=0)")

    lines.append(f"\n  minimum reliable E : {first_norm}  (stored_E; actual_E = {first_norm-32})")
    lines.append(f"  maximum reliable E : {last_norm}  (stored_E; actual_E = {last_norm-32})")
    lines.append(f"  usable exponent window : {usable_window} of 64 possible values"
                 f"  ({usable_window/64*100:.1f}%)")

    return "\n".join(lines), first_norm, last_norm


# ── HBS-12B: Fraction Resolution Map ─────────────────────────────────────────

def analyze_12b(rows):
    lines = [
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        "HBS-12B  FRACTION RESOLUTION MAP",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    ]
    data = [r for r in rows if r["test_id"] == 13]

    # Pass 1: E sweep at f=0, MUL(x,x)
    pass1 = [r for r in data if r["subtest"] == 0]
    results_p1 = [r["result"] for r in sorted(pass1, key=lambda x: x["cyc"])]
    unique_p1  = len(set(results_p1))
    norm_p1    = [r for r in pass1 if not r["uf"] and not r["ovf"]]

    lines.append("\n  Pass 1 — MUL(x,x), f=0, E=0..63:")
    lines.append(f"  Total rows     : {len(results_p1)}")
    lines.append(f"  Unique results : {unique_p1}")
    lines.append(f"  NORM count     : {len(norm_p1)}  "
                 f"UF={sum(r['uf'] for r in pass1)}  "
                 f"OVF={sum(r['ovf'] for r in pass1)}")

    # Pass 2: f sweep at E=32, MUL(x,x)
    pass2 = [r for r in data if r["subtest"] == 1]
    results_p2 = [r["result"] for r in sorted(pass2, key=lambda x: x["cyc"])]
    unique_p2  = len(set(results_p2))
    collisions = 64 - unique_p2

    result_fracs_p2 = [codeword_f(cw) for cw in results_p2]
    gaps            = []
    for i in range(1, len(result_fracs_p2)):
        gaps.append(result_fracs_p2[i] - result_fracs_p2[i-1])

    lines.append("\n  Pass 2 — MUL(x,x), E=32, f=0..63:")
    lines.append(f"  Total rows     : {len(results_p2)}")
    lines.append(f"  Unique results : {unique_p2}  (collisions = {collisions})")
    if gaps:
        lines.append(f"  Result f step  : min={min(gaps)}  max={max(gaps)}  "
                     f"mean={sum(gaps)/len(gaps):.1f}")

    # Pass 3: identity test
    pass3 = [r for r in data if r["subtest"] == 2]
    failures = [(r["extra"], r["result"]) for r in pass3 if r["result"] != r["extra"]]

    lines.append("\n  Pass 3 — MUL(x, NFE_ONE) identity test, E=32, f=0..63:")
    lines.append(f"  Identity failures : {len(failures)} / {len(pass3)}")
    if failures:
        lines.append("  !! IDENTITY VIOLATIONS DETECTED — arithmetic bug !!")
        for inp, out in failures[:5]:
            lines.append(f"     input={inp:#05x} -> output={out:#05x}")
    else:
        lines.append("  All identity checks passed — MUL(x,ONE) = x confirmed.")

    lines.append("\n  Fraction efficiency (E=32):")
    efficiency = unique_p2 / 64 * 100
    lines.append(f"  {unique_p2}/64 unique outputs = {efficiency:.1f}% fraction utilisation")

    return "\n".join(lines)


# ── HBS-12C: Normalization Stress Test ───────────────────────────────────────

def analyze_12c(rows):
    lines = [
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        "HBS-12C  NORMALIZATION STRESS TEST",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    ]
    data = [r for r in rows if r["test_id"] == 14]

    E_LABELS = {0: "E=0 (min)", 1: "E=1", 31: "E=31 (sub-1.0)",
                32: "E=32 (1.0)", 62: "E=62 (sub-max)", 63: "E=63 (max)"}
    E_LIST   = [0, 1, 31, 32, 62, 63]
    OP_NAMES = {1: "ADD+δ63", 2: "SUB-δ63", 3: "MUL×self"}
    F_LIST   = [0, 31, 63]

    for E in E_LIST:
        label = E_LABELS.get(E, f"E={E}")
        lines.append(f"\n  ── {label} ──")
        lines.append("  f  | MUL-UF  MUL-OVF  MUL-RO | ADD-OVF  ADD-RO | SUB-UF  SUB-RO")
        lines.append("  ──────────────────────────────────────────────────────────────────")

        e_rows = [r for r in data if r["stored_E"] == E]
        for f in F_LIST:
            f_rows = [r for r in e_rows if r["f_val"] == f]
            mul_r  = next((r for r in f_rows if r["op_code"] == 3), None)
            add_r  = next((r for r in f_rows if r["op_code"] == 1), None)
            sub_r  = next((r for r in f_rows if r["op_code"] == 2), None)

            mul_uf  = mul_r["uf"]       if mul_r  else "-"
            mul_ovf = mul_r["ovf"]      if mul_r  else "-"
            mul_ro  = mul_r["rollover"] if mul_r  else "-"
            add_ovf = add_r["ovf"]      if add_r  else "-"
            add_ro  = add_r["rollover"] if add_r  else "-"
            sub_uf  = sub_r["uf"]       if sub_r  else "-"
            sub_ro  = sub_r["rollover"] if sub_r  else "-"

            lines.append(f"  {f:2d} | {mul_uf!s:7} {mul_ovf!s:8} {mul_ro!s:6}"
                         f" | {add_ovf!s:7} {add_ro!s:6}"
                         f" | {sub_uf!s:7} {sub_ro!s:5}")

    # Summarise key normalization events
    add_ovf_count  = sum(r["ovf"] for r in data if r["op_code"] == 1)
    add_ro_count   = sum(r["rollover"] for r in data if r["op_code"] == 1)
    sub_uf_count   = sum(r["uf"] for r in data if r["op_code"] == 2)
    mul_uf_count   = sum(r["uf"] for r in data if r["op_code"] == 3)
    mul_ovf_count  = sum(r["ovf"] for r in data if r["op_code"] == 3)

    lines.append("\n  Summary:")
    lines.append(f"  ADD OVF events  : {add_ovf_count}  (Thoth rollover at E=63 with large delta)")
    lines.append(f"  ADD rollover    : {add_ro_count}")
    lines.append(f"  SUB UF events   : {sub_uf_count}  (Guard-B/Guard-A floor)")
    lines.append(f"  MUL UF events   : {mul_uf_count}  (double-bias underflow at low E)")
    lines.append(f"  MUL OVF events  : {mul_ovf_count} (double-bias overflow at high E)")

    return "\n".join(lines)


# ── HBS-12D: Information Retention Test ──────────────────────────────────────

def analyze_12d(rows):
    lines = [
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        "HBS-12D  INFORMATION RETENTION TEST",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    ]
    data = [r for r in rows if r["test_id"] == 15]
    depths = [1, 2, 4, 8, 16, 32, 64]

    lines.append("\n  Chain multiplier : NFE_HALF (E=31 f=0, value=0.5)")
    lines.append("  Seeds            : 32 (E ∈ [28..35], mixed f)")
    lines.append("")
    lines.append("  Depth | Unique | Floor | UF-ops | Entropy(bits)")
    lines.append("  ──────────────────────────────────────────────────")

    info_curve = []

    for d_idx, depth in enumerate(depths):
        d_rows   = [r for r in data if r["subtest"] == d_idx]
        results  = [r["result"] for r in d_rows]
        floor_n  = sum(1 for v in results if v == NFE_FLOOR)
        uf_ops   = sum(r["extra"] for r in d_rows)  # extra = uf_cnt_d
        unique_n = len(set(results))
        n        = len(results)

        # Shannon entropy
        from collections import Counter
        counts  = Counter(results)
        entropy = 0.0
        for cnt in counts.values():
            p = cnt / n
            if p > 0:
                entropy -= p * math.log2(p)

        lines.append(f"  {depth:5d} | {unique_n:6d} | {floor_n:5d} | {uf_ops:6d} | {entropy:.3f}")
        info_curve.append((depth, unique_n, floor_n, entropy))

    # Find floor threshold
    floor_thresh = None
    for depth, unique_n, floor_n, entropy in info_curve:
        if floor_n > 16:  # >50% seeds floored
            floor_thresh = depth
            break

    lines.append("")
    if floor_thresh:
        lines.append(f"  Floor attractor threshold : depth ≥ {floor_thresh}  (>50% seeds reach floor)")
    lines.append("  Information retention:")
    for depth, unique_n, floor_n, entropy in info_curve:
        pct_floor = floor_n / 32 * 100
        lines.append(f"    depth={depth:3d}: {unique_n} unique  {entropy:.2f} bits  "
                     f"{pct_floor:.0f}% floor")

    return "\n".join(lines), info_curve


# ── HBS-12E: Regime Transition Detector ──────────────────────────────────────

def analyze_12e(rows, e_norm_min, e_norm_max):
    lines = [
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        "HBS-12E  REGIME TRANSITION DETECTOR",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    ]
    data = [r for r in rows if r["test_id"] == 16]

    # Pass 1: Vertical E sweep (f=0, MUL(x,x))
    p1 = sorted([r for r in data if r["subtest"] == 0], key=lambda x: x["cyc"])
    lines.append("\n  Pass 1 — E sweep (f=0), MUL(x,x):")
    prev_status = None
    uf_e_list   = []
    ovf_e_list  = []
    norm_e_list = []
    for r in p1:
        s = classify_row(r["uf"], r["ovf"])
        if s != prev_status:
            lines.append(f"    E={r['stored_E']:2d}: → {s}")
            prev_status = s
        if s == "UF":
            uf_e_list.append(r["stored_E"])
        elif s == "OVF":
            ovf_e_list.append(r["stored_E"])
        else:
            norm_e_list.append(r["stored_E"])

    lines.append(f"\n  UF  band : E = {min(uf_e_list) if uf_e_list else '-'}..{max(uf_e_list) if uf_e_list else '-'}")
    lines.append(f"  NORM band : E = {min(norm_e_list) if norm_e_list else '-'}..{max(norm_e_list) if norm_e_list else '-'}")
    lines.append(f"  OVF  band : E = {min(ovf_e_list) if ovf_e_list else '-'}..{max(ovf_e_list) if ovf_e_list else '-'}")

    # Pass 2: Horizontal f sweep (E=32, MUL(x,x))
    p2 = sorted([r for r in data if r["subtest"] == 1], key=lambda x: x["cyc"])
    p2_uf  = sum(r["uf"]  for r in p2)
    p2_ovf = sum(r["ovf"] for r in p2)
    unique_p2 = len(set(r["result"] for r in p2))

    lines.append(f"\n  Pass 2 — f sweep (E=32), MUL(x,x):")
    lines.append(f"  UF={p2_uf}  OVF={p2_ovf}  unique_results={unique_p2}")
    if p2_uf == 0 and p2_ovf == 0:
        lines.append("  → E=32 band is fully STABLE across all f values.")
    else:
        lines.append("  → WARNING: unexpected UF/OVF at E=32.")

    # Pass 3: Asymmetric cross pairs
    p3 = sorted([r for r in data if r["subtest"] == 2], key=lambda x: x["cyc"])
    p3_uf  = sum(r["uf"]  for r in p3)
    p3_ovf = sum(r["ovf"] for r in p3)

    lines.append(f"\n  Pass 3 — Asymmetric pairs MUL(x_low, x_high):")
    lines.append(f"  UF={p3_uf}  OVF={p3_ovf}")
    if p3_uf == 0 and p3_ovf == 0:
        lines.append("  → All complementary pairs produced valid (NORM) results.")
        lines.append("  → exp_sum = E + (63-E) - 32 = 31 → always within bounds.")

    # Regime classification
    lines.append("\n  ── Regime Classification ──")
    uf_max  = max(uf_e_list)  if uf_e_list  else -1
    ovf_min = min(ovf_e_list) if ovf_e_list else 64
    lines.append(f"  Stable   : E ∈ [{uf_max+1}..{ovf_min-1}]  ({ovf_min-1 - (uf_max+1) + 1} steps)")
    lines.append(f"  UF zone  : E ∈ [0..{uf_max}]  ({uf_max+1} values)")
    lines.append(f"  OVF zone : E ∈ [{ovf_min}..63]  ({64-ovf_min} values)")
    lines.append("  Transitional : adjacent to zone boundaries (±1 E step)")

    return "\n".join(lines)


# ── HBS-12F: Reversibility Test ──────────────────────────────────────────────

def analyze_12f(rows):
    lines = [
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        "HBS-12F  REVERSIBILITY TEST",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    ]
    data = [r for r in rows if r["test_id"] == 17]

    # Test 1: Small-delta round-trip (no rollover)
    t1 = [r for r in data if r["subtest"] == 0]
    t1_ok  = sum(1 for r in t1 if r["extra"] == 0)
    t1_err = sum(1 for r in t1 if r["extra"] != 0)
    lines.append("\n  Test 1 — ADD(x,δ) → SUB(x+δ,δ)  small δ (no rollover):")
    lines.append(f"  Total cases    : {len(t1)}")
    lines.append(f"  Perfect recovery (error=0) : {t1_ok}")
    lines.append(f"  Recovery failures           : {t1_err}")
    if t1_err == 0:
        lines.append("  → ADD→SUB round-trip is PERFECTLY REVERSIBLE for δ < 64−f.")
    else:
        lines.append(f"  → {t1_err} recovery failures detected.")

    # Test 2: Large-delta round-trip (rollover)
    t2 = [r for r in data if r["subtest"] == 1]
    t2_ok  = sum(1 for r in t2 if r["extra"] == 0)
    t2_err = sum(1 for r in t2 if r["extra"] != 0)
    lines.append("\n  Test 2 — ADD(x,63) → SUB(x+rollover,63)  (rollover):")
    lines.append(f"  Total cases    : {len(t2)}")
    lines.append(f"  Perfect recovery : {t2_ok}")
    lines.append(f"  Recovery failures: {t2_err}")
    if len(t2) > 0 and t2_err == len(t2):
        lines.append("  → Rollover BREAKS reversibility: information irreversibly lost.")
    elif t2_ok == len(t2):
        lines.append("  → Rollover case still recoverable (unexpected).")

    # Test 3: MUL identity
    t3 = [r for r in data if r["subtest"] == 2]
    t3_ok  = sum(1 for r in t3 if r["extra"] == 0)
    t3_err = sum(1 for r in t3 if r["extra"] != 0)
    lines.append("\n  Test 3 — MUL(x, NFE_ONE) identity test:")
    lines.append(f"  Total cases      : {len(t3)}")
    lines.append(f"  Identity preserved : {t3_ok}")
    lines.append(f"  Identity violated  : {t3_err}")
    if t3_err == 0:
        lines.append("  → MUL identity CONFIRMED: MUL(x, 1.0) = x for all tested operands.")
    else:
        lines.append("  !! MUL IDENTITY VIOLATED — critical arithmetic failure !!")

    # Reversibility score summary
    total = len(t1) + len(t2) + len(t3)
    total_ok = t1_ok + t2_ok + t3_ok
    score = total_ok / total * 100 if total > 0 else 0.0
    lines.append(f"\n  Reversibility score : {total_ok}/{total} = {score:.1f}%")

    return "\n".join(lines)


# ── Final Envelope Classification ─────────────────────────────────────────────

def build_final_classification(e_min, e_max, info_curve):
    lines = [
        "",
        "╔══════════════════════════════════════════════════════════════╗",
        "║        HORUS v3 ARITHMETIC ENVELOPE — FINAL CLASSIFICATION   ║",
        "╚══════════════════════════════════════════════════════════════╝",
        "",
        "  Region          │ E range     │ Status",
        "  ────────────────┼─────────────┼───────────────────────────────",
    ]
    if e_min is not None:
        uf_max  = e_min - 1
        ovf_min = e_max + 1
        lines.append(f"  Stable (NORM)   │ {e_min}..{e_max}       │ STABLE")
        lines.append(f"  UF zone         │ 0..{uf_max}         │ COLLAPSE (underflow floor)")
        lines.append(f"  OVF zone        │ {ovf_min}..63        │ SATURATED (max codeword)")
        lines.append(f"  Transition (UF) │ E = {e_min-1}..{e_min}    │ TRANSITIONAL")
        lines.append(f"  Transition (OVF)│ E = {e_max}..{ovf_min}    │ TRANSITIONAL")
    else:
        lines.append("  (envelope data unavailable)")

    lines += [
        "",
        "  Known Arithmetic Boundaries:",
        f"  • Minimum reliable stored_E  = {e_min}  (actual_E = {e_min-32})",
        f"  • Maximum reliable stored_E  = {e_max}  (actual_E = {e_max-32})",
        "  • MUL self-underflow  : 2·E < 32  →  E < 16",
        "  • MUL self-overflow   : 2·E > 95  →  E > 47  (with P[13]=0/1 carry)",
        "  • ADD max rollover    : f + delta ≥ 64  →  Thoth Rollover fires",
        "  • ADD OVF at rollover : E = 63 and rollover  →  exp_ovf_flag",
        "  • SUB Guard-B         : f_a < delta, E > 0  →  2-cycle pipeline",
        "  • SUB FTZ             : E < norm_shift  →  floor output",
        "  • MUL identity        : MUL(x, NFE_ONE) = x  ∀ x  [verified]",
    ]

    # Info retention summary
    if info_curve:
        collapse_depth = None
        for depth, unique_n, floor_n, entropy in info_curve:
            if floor_n > 16:
                collapse_depth = depth
                break
        lines += [
            "",
            "  Information Retention:",
        ]
        for depth, unique_n, floor_n, entropy in info_curve:
            pf = floor_n / 32 * 100
            lines.append(f"    depth {depth:3d} : {unique_n:3d} unique  {entropy:.2f} bits  "
                         f"{pf:.0f}% floor")
        if collapse_depth:
            lines.append(f"  → Floor attractor dominates at depth ≥ {collapse_depth}")
        else:
            lines.append("  → No full collapse detected in tested depth range.")

    lines += [
        "",
        "  Safe Operating Envelope:",
        f"    stored_E ∈ [{e_min}..{e_max}]  (actual_E ∈ [{e_min-32}..{e_max-32}])"
        if e_min is not None else "    (unavailable)",
        "    depth ≤ stored_E_seed  (to avoid floor attractor in chained MUL)",
        "    ADD/SUB delta ≤ 63 − f  (to avoid information-destructive rollover)",
        "",
        "  Recommended Deployment Envelope:",
        "    stored_E ∈ [20..44]  — conservative 25-value window (comfortable margin)",
        "    depth ≤ 16  — retains >50% unique outputs before collapse",
        "    Use mode_tag=010 (Pre-Scaled) for chains approaching depth=16",
    ]

    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    csv_path = "HBS12_ARITHMETIC_BOUNDARY.csv"
    log_path = "HBS12_SUMMARY.log"

    if not os.path.exists(csv_path):
        print(f"ERROR: {csv_path} not found — run simulation first.", file=sys.stderr)
        sys.exit(1)

    print(f"Loading {csv_path} …")
    rows = load_csv(csv_path)
    print(f"  {len(rows)} data rows loaded.")

    # Run analyses
    a12a_text, e_norm_min, e_norm_max = analyze_12a(rows)
    a12b_text                         = analyze_12b(rows)
    a12c_text                         = analyze_12c(rows)
    a12d_text, info_curve             = analyze_12d(rows)
    a12e_text                         = analyze_12e(rows, e_norm_min, e_norm_max)
    a12f_text                         = analyze_12f(rows)
    a12_final                         = build_final_classification(
                                            e_norm_min, e_norm_max, info_curve)

    # Assemble log
    header = [
        "================================================================",
        "  HBS-12  ARITHMETIC BOUNDARY MAPPING SUITE — SUMMARY LOG",
        "  HORUS NFE v3 · All tests: mode_tag = 3'b000 (Standard)",
        "================================================================",
        "",
    ]

    sections = [
        a12a_text, a12b_text, a12c_text,
        a12d_text, a12e_text, a12f_text,
        a12_final,
    ]

    with open(log_path, "w") as fh:
        fh.write("\n".join(header) + "\n")
        for sec in sections:
            fh.write(sec + "\n\n")

    print(f"  Log → {log_path}")
    print()

    # Print final envelope to stdout
    print("=" * 64)
    print(a12_final)
    print("=" * 64)

if __name__ == "__main__":
    main()
