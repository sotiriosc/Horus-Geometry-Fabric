#!/usr/bin/env python3
"""
sim/analyze_hbs_c16_causality.py
==================================
HBS-C16: Control Causality Isolation Analysis

Reads HBS_C16_CAUSAL_TRACE.csv and determines at which pipeline stage
mode_tag first causes observable divergence.

Pipeline stages:
  S1 — ALU           : mant_sum, scale_reg
  S2 — Computed      : computed  (post-ALU result)
  S3 — Accum Input   : accum_word (policy-decoded input)
  S4 — Accum State   : accum_reg_pre, accum_reg_post
  S5 — Output        : result, accum_out

Classification:
  A — PRE-ALU DIVERGENCE         : S1 diverges
  B — ACCUMULATION-ONLY          : S3/S4 diverge, S1/S2/S5 (result) do not
  C — POST-COMPUTE / OBS         : only flags or accum_out differ
  D — NO DIVERGENCE              : nothing diverges

Cross-validation metrics:
  - First divergence cycle per stage
  - Cross-mode correlation per stage
  - Entropy difference between modes
  - Stability under accum_clr reset cycles
"""
import csv, os, sys, math
from collections import defaultdict

CSV_PATH = "HBS_C16_CAUSAL_TRACE.csv"
LOG_PATH = "HBS_C16_SUMMARY.log"

MODE_NAMES = {
    0: "000 MODE_STANDARD",
    1: "001 MODE_BIAS_CORR",
    2: "010 MODE_PRE_SCALED",
    3: "011 MODE_SAFE_ACCUM",
}

# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------
def parse_hex(s):
    s = s.strip()
    if s.startswith("0x") or s.startswith("0X"):
        return int(s, 16)
    return int(s)

def load_csv(path):
    rows = []
    with open(path, newline="") as fh:
        rd = csv.DictReader(fh)
        for r in rd:
            rows.append({
                "cycle":           int(r["cycle"]),
                "mode_id":         int(r["mode_id"]),
                "local_cycle":     int(r["local_cycle"]),
                "op_a":            parse_hex(r["op_a"]),
                "op_b":            parse_hex(r["op_b"]),
                "op_sel":          int(r["op_sel"]),
                "mode_tag":        int(r["mode_tag"]),
                "mant_sum":        int(r["mant_sum"]),
                "scale_reg":       int(r["scale_reg"]),
                "computed":        parse_hex(r["computed"]),
                "accum_word":      parse_hex(r["accum_word"]),
                "accum_reg_pre":   int(r["accum_reg_pre"]),
                "accum_reg_post":  int(r["accum_reg_post"]),
                "result":          parse_hex(r["result"]),
                "accum_out":       int(r["accum_out"]),
                "UF":              int(r["UF"]),
                "OVF":             int(r["OVF"]),
                "rollover":        int(r["rollover"]),
                "accum_en_active": int(r["accum_en_active"]),
            })
    return rows


# ---------------------------------------------------------------------------
# Cross-mode comparison per stage
# ---------------------------------------------------------------------------
def compare_stage(by_mode, field, active_only=False):
    """
    For each local_cycle, compare field across all 4 modes.
    Returns:
      divergence_cycle  : first local_cycle where values differ, or None
      n_divergent       : number of cycles with any cross-mode difference
      per_mode_values   : {mode_id: [values by local_cycle]}
    """
    n_modes    = max(by_mode.keys()) + 1
    max_cycles = max(len(by_mode[m]) for m in by_mode)

    divergence_cycle = None
    n_divergent      = 0
    per_mode_values  = {m: [] for m in range(n_modes)}

    for lc in range(max_cycles):
        vals = {}
        for m in range(n_modes):
            if m not in by_mode or lc >= len(by_mode[m]):
                continue
            r = by_mode[m][lc]
            if active_only and not r["accum_en_active"]:
                continue
            vals[m] = r[field]
            per_mode_values[m].append(r[field])

        if len(vals) < 2:
            continue

        unique_vals = set(vals.values())
        if len(unique_vals) > 1:
            n_divergent += 1
            if divergence_cycle is None:
                divergence_cycle = lc

    return divergence_cycle, n_divergent, per_mode_values


def compute_correlation(a_vals, b_vals):
    """Pearson correlation coefficient between two equal-length lists."""
    n = min(len(a_vals), len(b_vals))
    if n < 2:
        return 1.0
    ma = sum(a_vals[:n]) / n
    mb = sum(b_vals[:n]) / n
    num = sum((a-ma)*(b-mb) for a,b in zip(a_vals[:n], b_vals[:n]))
    da  = math.sqrt(sum((a-ma)**2 for a in a_vals[:n]))
    db  = math.sqrt(sum((b-mb)**2 for b in b_vals[:n]))
    if da < 1e-9 or db < 1e-9:
        return 1.0 if da < 1e-9 and db < 1e-9 else 0.0
    return num / (da * db)


def entropy_of_distribution(vals):
    """Shannon entropy of a list of values (discretized)."""
    if not vals:
        return 0.0
    from collections import Counter
    c = Counter(vals)
    n = len(vals)
    return -sum((v/n) * math.log2(v/n) for v in c.values() if v > 0)


# ---------------------------------------------------------------------------
# Main divergence analysis
# ---------------------------------------------------------------------------
def run_divergence_analysis(by_mode):
    stages = [
        ("S1_mant_sum",      "mant_sum",      False, "ALU (ADD/SUB mantissa intermediate)"),
        ("S1_scale_reg",     "scale_reg",     False, "ALU (MUL product intermediate)"),
        ("S2_computed",      "computed",      False, "Computed (post-ALU NFE result)"),
        ("S3_accum_word",    "accum_word",    True,  "Accum Input (policy-decoded word)"),
        ("S4_accum_pre",     "accum_reg_pre", True,  "Accum State (pre-update)"),
        ("S4_accum_post",    "accum_reg_post",True,  "Accum State (post-update)"),
        ("S5_result",        "result",        False, "Output: result"),
        ("S5_accum_out",     "accum_out",     False, "Output: accum_out"),
    ]

    results = {}
    for stage_id, field, active_only, desc in stages:
        dc, n_div, pvals = compare_stage(by_mode, field, active_only)
        results[stage_id] = {
            "field":            field,
            "desc":             desc,
            "divergence_cycle": dc,
            "n_divergent":      n_div,
            "active_only":      active_only,
            "per_mode_values":  pvals,
        }
    return results


# ---------------------------------------------------------------------------
# Cross-mode correlation matrix
# ---------------------------------------------------------------------------
def correlation_matrix(by_mode, field, n_cycles=200):
    n_modes = max(by_mode.keys()) + 1
    mat = {}
    for m1 in range(n_modes):
        for m2 in range(m1, n_modes):
            a = [r[field] for r in by_mode[m1][:n_cycles]]
            b = [r[field] for r in by_mode[m2][:n_cycles]]
            rho = compute_correlation(a, b)
            mat[(m1, m2)] = rho
            mat[(m2, m1)] = rho
    return mat


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------
def classify_divergence(divergence_map):
    """
    A — PRE-ALU DIVERGENCE      : S1 (mant_sum or scale_reg) diverges
    B — ACCUMULATION-ONLY       : S3/S4 diverge, S1/S2/S5_result do not
    C — POST-COMPUTE / OBS      : only S5_accum_out diverges
    D — NO DIVERGENCE           : nothing diverges
    """
    s1_div  = (divergence_map["S1_mant_sum"]["divergence_cycle"] is not None or
               divergence_map["S1_scale_reg"]["divergence_cycle"] is not None)
    s2_div  = divergence_map["S2_computed"]["divergence_cycle"] is not None
    s3_div  = divergence_map["S3_accum_word"]["divergence_cycle"] is not None
    s4_div  = (divergence_map["S4_accum_post"]["divergence_cycle"] is not None)
    s5r_div = divergence_map["S5_result"]["divergence_cycle"] is not None
    s5a_div = divergence_map["S5_accum_out"]["divergence_cycle"] is not None

    if s1_div or s2_div:
        return "A", "PRE-ALU DIVERGENCE", "mode_tag is causally affecting computation before accumulation"
    elif s3_div or s4_div:
        if not s5r_div:
            return "B", "ACCUMULATION-ONLY DIVERGENCE", "mode_tag affects accumulation policy only; result is mode_tag-independent"
        else:
            return "B", "ACCUMULATION-ONLY DIVERGENCE (result shows lag from accum_out)", (
                "result diverges but only because it mirrors accum_out; computed is identical")
    elif s5a_div and not s5r_div:
        return "C", "POST-COMPUTE / OBSERVATIONAL DIVERGENCE", "mode_tag only affects accum_out reporting, not computation"
    else:
        return "D", "NO DIVERGENCE", "mode_tag has no measurable effect under these fixed inputs"


# ---------------------------------------------------------------------------
# Earliest divergence finder
# ---------------------------------------------------------------------------
def earliest_divergence(divergence_map):
    earliest = None
    stage    = None
    for sid, r in divergence_map.items():
        dc = r["divergence_cycle"]
        if dc is not None:
            if earliest is None or dc < earliest:
                earliest = dc
                stage    = sid
    return earliest, stage


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(CSV_PATH):
        print(f"ERROR: {CSV_PATH} not found. Run simulation first.")
        sys.exit(1)

    print("=" * 64)
    print("HBS-C16: Control Causality Isolation Analysis")
    print("=" * 64)

    rows = load_csv(CSV_PATH)
    print(f"  Loaded {len(rows):,} rows from {CSV_PATH}")

    # Split by mode
    by_mode = defaultdict(list)
    for r in rows:
        by_mode[r["mode_id"]].append(r)

    print(f"  Modes: {[f'{m}({len(by_mode[m])} cyc)' for m in sorted(by_mode)]}")

    # ── Per-mode first-cycle snapshot ────────────────────────────────────────
    print(f"\n[First-cycle values per mode (local_cycle=0)]")
    hdr = f"  {'Mode':<22}  {'mant_sum':>8}  {'computed':>10}  "
    hdr += f"{'accum_word':>10}  {'result':>8}  {'accum_post':>12}"
    print(hdr)
    print(f"  {'-'*22}  {'-'*8}  {'-'*10}  {'-'*10}  {'-'*8}  {'-'*12}")
    for m in sorted(by_mode):
        r = by_mode[m][0]
        print(f"  {MODE_NAMES[m]:<22}  "
              f"{r['mant_sum']:>8d}  "
              f"0x{r['computed']:>08x}  "
              f"0x{r['accum_word']:>08x}  "
              f"0x{r['result']:>06x}  "
              f"{r['accum_reg_post']:>12d}")

    # ── Stage divergence analysis ─────────────────────────────────────────────
    print(f"\n[Stage Divergence Detection]")
    divergence_map = run_divergence_analysis(by_mode)

    print(f"\n  {'Stage':<20}  {'Field':<16}  {'First Div Cycle':>16}  {'N Div Cycs':>11}")
    print(f"  {'-'*20}  {'-'*16}  {'-'*16}  {'-'*11}")
    for sid, r in divergence_map.items():
        dc   = r["divergence_cycle"]
        ndiv = r["n_divergent"]
        dc_s = str(dc) if dc is not None else "NEVER"
        print(f"  {sid:<20}  {r['field']:<16}  {dc_s:>16}  {ndiv:>11d}")

    # ── Which mode pairs diverge ───────────────────────────────────────────────
    print(f"\n[Mode-Pair Divergence — accum_word (S3)]")
    for m1 in range(4):
        for m2 in range(m1+1, 4):
            dc, _, _ = compare_stage(
                {0: by_mode[m1], 1: by_mode[m2]}, "accum_word", active_only=True)
            dc_s = str(dc) if dc is not None else "NEVER"
            print(f"  mode{m1}({m1:03b}) vs mode{m2}({m2:03b}): first divergence at cycle {dc_s}")

    print(f"\n[Mode-Pair Divergence — result (S5)]")
    for m1 in range(4):
        for m2 in range(m1+1, 4):
            dc, _, _ = compare_stage(
                {0: by_mode[m1], 1: by_mode[m2]}, "result", active_only=False)
            dc_s = str(dc) if dc is not None else "NEVER"
            print(f"  mode{m1}({m1:03b}) vs mode{m2}({m2:03b}): first divergence at cycle {dc_s}")

    # ── Correlation matrix (accum_word vs computed) ───────────────────────────
    print(f"\n[Cross-mode Correlation: computed vs accum_word (first 200 active cycles)]")
    for field, label in [("computed", "computed"), ("accum_word", "accum_word")]:
        mat = correlation_matrix(by_mode, field, n_cycles=200)
        print(f"\n  {label}:")
        print(f"  {'':>10}  " + "  ".join(f"mode{m}" for m in range(4)))
        for m1 in range(4):
            row = f"  mode{m1}({m1:03b})  "
            row += "  ".join(f"{mat[(m1,m2)]:>6.3f}" for m2 in range(4))
            print(row)

    # ── Entropy per stage per mode ─────────────────────────────────────────────
    print(f"\n[Entropy Analysis: H(field) across modes]")
    for field in ["mant_sum", "computed", "accum_word", "accum_reg_post", "result"]:
        entropies = {m: entropy_of_distribution([r[field] for r in by_mode[m][:200]])
                     for m in range(4)}
        vals_str = "  ".join(f"M{m}={entropies[m]:.3f}" for m in range(4))
        print(f"  {field:<18}: {vals_str}")

    # ── Accum_reg divergence profile (first 70 active cycles) ─────────────────
    print(f"\n[Accum_reg_post profile — first 70 cycles per mode]")
    print(f"  {'Cycle':>5}  " + "  ".join(f"{'M'+str(m)+'('+str(m)[:3]+')':>12}" for m in range(4)))
    for lc in range(0, min(70, min(len(by_mode[m]) for m in range(4))), 5):
        line = f"  {lc:>5}  "
        for m in range(4):
            line += f"{by_mode[m][lc]['accum_reg_post']:>12d}  "
        print(line)

    # ── Earliest divergence summary ───────────────────────────────────────────
    ec, es = earliest_divergence(divergence_map)
    print(f"\n[Earliest Divergence Point]")
    if ec is not None:
        print(f"  Stage: {es}  |  First divergence at local cycle: {ec}")
        dc_m = divergence_map[es]
        print(f"  Description: {dc_m['desc']}")
    else:
        print(f"  NO DIVERGENCE detected at any stage")

    # ── Classification ───────────────────────────────────────────────────────
    verdict, label, reason = classify_divergence(divergence_map)

    print(f"\n{'='*64}")
    print(f"  DIVERGENCE CLASSIFICATION: ({verdict}) {label}")
    print(f"{'='*64}")
    print(f"  Reason: {reason}")
    print(f"\n  Stage summary:")
    stages_short = [
        ("S1 ALU (mant_sum)",   "S1_mant_sum"),
        ("S1 ALU (scale_reg)",  "S1_scale_reg"),
        ("S2 Computed",         "S2_computed"),
        ("S3 Accum Input",      "S3_accum_word"),
        ("S4 Accum State",      "S4_accum_post"),
        ("S5 Result",           "S5_result"),
        ("S5 Accum Out",        "S5_accum_out"),
    ]
    for label_s, sid in stages_short:
        dc = divergence_map[sid]["divergence_cycle"]
        status = f"diverges at cycle {dc}" if dc is not None else "IDENTICAL across all modes"
        print(f"    {label_s:<22}: {status}")

    # ── Accum_word deep-dive ───────────────────────────────────────────────────
    print(f"\n[accum_word Values (active cycles 0–9)]")
    print(f"  {'Cycle':>5}  " + "  ".join(f"{'M'+str(m)+'('+str(m)[:3]+')':>12}" for m in range(4)))
    for lc in range(min(10, min(len(by_mode[m]) for m in range(4)))):
        line = f"  {lc:>5}  "
        for m in range(4):
            r = by_mode[m][lc]
            if r["accum_en_active"]:
                line += f"  0x{r['accum_word']:03x}({r['accum_word']:4d})"
            else:
                line += f"  {'[gate off]':>12}"
        print(line)

    # ── Write log ─────────────────────────────────────────────────────────────
    earliest_div, earliest_stage = earliest_divergence(divergence_map)
    with open(LOG_PATH, "w") as f:
        f.write(f"HBS_C16_VERDICT={verdict}\n")
        f.write(f"HBS_C16_LABEL={label}\n")
        f.write(f"EARLIEST_DIVERGENCE_CYCLE={earliest_div if earliest_div is not None else 'NONE'}\n")
        f.write(f"EARLIEST_DIVERGENCE_STAGE={earliest_stage if earliest_stage else 'NONE'}\n")
        f.write("\nPER_STAGE_DIVERGENCE\n")
        for sid, r in divergence_map.items():
            dc = r["divergence_cycle"]
            f.write(f"  {sid}: {dc if dc is not None else 'NONE'} ({r['n_divergent']} divergent cycles)\n")
        f.write(f"\nS1_ALU_DIVERGES={'YES' if divergence_map['S1_mant_sum']['divergence_cycle'] is not None else 'NO'}\n")
        f.write(f"S2_COMPUTED_DIVERGES={'YES' if divergence_map['S2_computed']['divergence_cycle'] is not None else 'NO'}\n")
        f.write(f"S3_ACCUM_WORD_DIVERGES={'YES' if divergence_map['S3_accum_word']['divergence_cycle'] is not None else 'NO'}\n")
        f.write(f"S4_ACCUM_STATE_DIVERGES={'YES' if divergence_map['S4_accum_post']['divergence_cycle'] is not None else 'NO'}\n")
        f.write(f"S5_RESULT_DIVERGES={'YES' if divergence_map['S5_result']['divergence_cycle'] is not None else 'NO'}\n")

    print(f"\n  Log written to {LOG_PATH}")
    return verdict


if __name__ == "__main__":
    main()
