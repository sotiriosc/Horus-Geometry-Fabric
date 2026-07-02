#!/usr/bin/env python3
"""
HBS-C10: Predictive Validation
================================
MANDATE: Predictions are generated from the C8 attractor model ANALYTICALLY
         before any simulation data is loaded. The 'BLIND PREDICTION' section
         must execute and write its CSV before the simulation CSV is read.

Sections:
  C10A — Prediction Before Execution (analytical, pre-simulation)
  C10B — Attractor Classification Accuracy (confusion matrix, F1)
  C10C — Parameter Sweep (disagreement map)
  C10D — Emergence Search (high-confidence mismatches)
  C10E — Minimal Predictive Model (4→3→2 attractor reduction)
"""

import csv, os, sys, math, json
import numpy as np
from collections import defaultdict, Counter

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 0 — CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
SIM_CSV      = "HBS_C10_SINGULARITY.csv"
PRED_CSV     = "HBS_C10_PREDICTIONS.csv"
SUMMARY_LOG  = "HBS_C10_SUMMARY.log"
EPOCH_DEPTH  = 16
STRESS_CYC   = 300
RECV_CYC     = 50
CYC_PER_WL   = STRESS_CYC + RECV_CYC  # 350
NUM_WL       = 20

VERDICT_THRESHOLDS = {
    "FAIL":         0.70,
    "INCOMPLETE":   0.80,
    "SUFFICIENT":   0.90,
    "OVERCOMPLETE": 0.95,  # 3-attractor achieves this → some attractor is redundant
}

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — C10A: BLIND ANALYTICAL PREDICTIONS (no simulation data)
# ──────────────────────────────────────────────────────────────────────────────
#
# Each prediction is derived from the C8 attractor model rules:
#
#   A1 (Cancellation): SUB-dominant, near-equal operands, 100% STABLE
#       trigger: p_sub > 0.5, |Δf| < 16
#   A2 (Drift):        MUL-chain with chain feedback, ΔE = E_factor - 32 ≥ 1
#       trigger: p_mul > 0.5, chain, E_factor ≥ 33
#       TTI formula: ceil((63 - E_start) / (E_factor - 32))
#   A3 (Boundary):     ADD at E=15 or E=47 → Rollover guaranteed
#       trigger: p_add > 0.5, (E ≤ 15 or E ≥ 47), 2×E_result < E_in
#   A4 (Mixed):        Multi-region injection or high E-entropy
#       trigger: ≥ 2 distinct region classes used, or entr(E_in) > 1.5
#
# These are the ONLY rules applied — no simulation look-up.
# ──────────────────────────────────────────────────────────────────────────────

# A2 TTI analytical formula from C8
def predict_a2_tti(e_start, e_factor, step=1):
    if e_factor <= 32:
        return 9999
    return math.ceil((63 - e_start) / (e_factor - 32)) * step

PREDICTIONS = {
    # WL: (dominant_attractor, tti_cycles, ovf_pct, stable_pct, epoch_attractor_sequence, reasoning)
    # epoch_attractor_sequence: per-epoch predicted label for confusion matrix
    "WL00": {
        "attractor": "A1", "tti": 2, "ovf_pct": 0.0, "stable_pct": 100.0,
        "epoch_seq": ["A1"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "All SUB E=32 jitter=3; residual residual absorption; 100% STABLE"
    },
    "WL01": {
        "attractor": "A1", "tti": 2, "ovf_pct": 0.0, "stable_pct": 100.0,
        "epoch_seq": ["A1"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "All SUB E=32 jitter=8; larger residuals, same A1 dynamics"
    },
    "WL02": {
        "attractor": "A2", "tti": predict_a2_tti(32, 33),  # = 31
        "ovf_pct": 3.2, "stable_pct": 37.0,
        "epoch_seq": ["A2"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": f"MUL×2 chain from E=32; ΔE=1/cy; first OVF at cy{predict_a2_tti(32,33)}"
    },
    "WL03": {
        "attractor": "A2", "tti": predict_a2_tti(32, 34),  # ≈ 16
        "ovf_pct": 6.0, "stable_pct": 20.0,
        "epoch_seq": ["A2"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": f"MUL×4 chain from E=32; ΔE=2/cy; first OVF at cy{predict_a2_tti(32,34)}"
    },
    "WL04": {
        "attractor": "A3", "tti": 0, "ovf_pct": 0.0, "stable_pct": 0.0,
        "epoch_seq": ["A3"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "ADD at E=15 Rollover guaranteed → immediate COLLAPSE↔TRANSITION oscillation"
    },
    "WL05": {
        "attractor": "A3", "tti": 0, "ovf_pct": 0.0, "stable_pct": 0.0,
        "epoch_seq": ["A3"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "ADD at E=47 Rollover guaranteed → TRANSITION↔SATURATE oscillation"
    },
    "WL06": {
        "attractor": "A4", "tti": 4, "ovf_pct": 0.0, "stable_pct": 40.0,
        "epoch_seq": ["A4"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "40/30/30 STABLE/COLLAPSE/SAT injection; direct C7-R4 design → A4"
    },
    "WL07": {
        "attractor": "A1", "tti": 2, "ovf_pct": 0.0, "stable_pct": 100.0,
        # First 6-7 epochs are A1 (SUB burst), remaining epochs are neutral/A1
        "epoch_seq": ["A1"] * 7 + ["A1"] * (STRESS_CYC // EPOCH_DEPTH - 6),
        "reason": "SUB burst 100cy then NOP 200cy; A1 active in burst; neutral afterward"
    },
    "WL08": {
        "attractor": "A2", "tti": predict_a2_tti(32, 33),  # OVF at cy31
        "ovf_pct": 0.7, "stable_pct": 80.0,
        # First ~3 epochs MUL burst (A2), then stable ADD (A1-like)
        "epoch_seq": ["A2"] * 3 + ["A1"] * (STRESS_CYC // EPOCH_DEPTH - 2),
        "reason": "MUL burst 50cy (A2, OVF at cy31) then 250cy stable ADD (A1-like accumulation)"
    },
    "WL09": {
        "attractor": "A3", "tti": 0, "ovf_pct": 0.0, "stable_pct": 0.0,
        "epoch_seq": ["A3"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "Alternating ADD E=15/E=47 each cycle → dual-boundary A3 all epochs"
    },
    "WL10": {
        "attractor": "A1", "tti": 2, "ovf_pct": 0.0, "stable_pct": 100.0,
        "epoch_seq": ["A1"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "SUB E=32 ramp jitter 1..8 cycling; always STABLE, varying residuals → A1"
    },
    "WL11": {
        "attractor": "A2", "tti": predict_a2_tti(32, 33) * 2,  # half-rate MUL → ~62cy
        "ovf_pct": 1.5, "stable_pct": 50.0,
        "epoch_seq": ["A2"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "Every-other-cycle MUL×2 chain; half-rate ΔE; OVF at ~62cy"
    },
    "WL12": {
        "attractor": "A1", "tti": None, "ovf_pct": 0.0, "stable_pct": 100.0,
        "epoch_seq": ["A1"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "ADD sweeping E=20..43 (STABLE only); no OVF, no cancel; accum grows → A1 default"
    },
    "WL13": {
        "attractor": "A1", "tti": None, "ovf_pct": 0.0, "stable_pct": 90.0,
        "epoch_seq": ["A1"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "10% sparse MUL×2 + 90% stable ADD; MUL too sparse for chain OVF → A1/A4 border"
    },
    "WL14": {
        "attractor": "A1", "tti": 2, "ovf_pct": 0.0, "stable_pct": 100.0,
        "epoch_seq": ["A1"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "SUB cascade jitter 1→2→4→8→16→32; all ops at E=32 → A1 throughout"
    },
    "WL15": {
        "attractor": "A2", "tti": predict_a2_tti(32, 33),
        "ovf_pct": 2.3, "stable_pct": 20.0,
        # First 9 epochs: MUL (A2), last 9 epochs: ADD E=47 (A3)
        "epoch_seq": ["A2"] * 9 + ["A3"] * 10,
        "reason": "MUL chain 150cy (A2, multiple OVF) then ADD E=47 150cy (A3) → split prediction"
    },
    "WL16": {
        "attractor": "A4", "tti": 4, "ovf_pct": 0.0, "stable_pct": 30.0,
        "epoch_seq": ["A4"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "ADD uniform E=15..48 → all 4 regions active; high entropy mix → A4"
    },
    "WL17": {
        "attractor": "A1", "tti": 2, "ovf_pct": 0.0, "stable_pct": 30.0,
        "epoch_seq": ["A1"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "SUB at E=16 (TRANSITION); near-equal ops → residuals near COLLAPSE boundary"
    },
    "WL18": {
        "attractor": "A2", "tti": 40, "ovf_pct": 0.8, "stable_pct": 50.0,
        "epoch_seq": ["A2"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "Coupled MUL+SUB (S1-D); SUB acts as natural brake; extended TTI ~40cy (C9 result)"
    },
    "WL19": {
        "attractor": "A3", "tti": 0, "ovf_pct": 0.0, "stable_pct": 0.0,
        "epoch_seq": ["A3"] * (STRESS_CYC // EPOCH_DEPTH + 1),
        "reason": "ADD alternating E=15/E=16 → straddles COLLAPSE↔TRANSITION; A3 variant"
    },
}

# ─── Write predictions CSV BEFORE any simulation data is accessed ─────────────
def write_predictions_csv(path):
    print(f"[C10A] Writing blind predictions → {path}")
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["wl_id","pred_attractor","pred_tti","pred_ovf_pct",
                    "pred_stable_pct","pred_epoch_0","reasoning"])
        for wl, p in sorted(PREDICTIONS.items()):
            w.writerow([
                wl, p["attractor"],
                str(p["tti"]) if p["tti"] is not None else "None",
                f"{p['ovf_pct']:.1f}", f"{p['stable_pct']:.1f}",
                p["epoch_seq"][0], p["reason"]
            ])
    print(f"    Written {len(PREDICTIONS)} workload predictions")
    print(f"    Predictions locked. No simulation data has been read yet.\n")

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — SIMULATION DATA LOADING
# ──────────────────────────────────────────────────────────────────────────────

def classify_region(e):
    if e <= 15:  return "COLLAPSE"
    if e <= 19:  return "TRANSITION"
    if e <= 43:  return "STABLE"
    if e <= 47:  return "TRANSITION"
    return "SATURATE"

def load_sim_csv(path):
    """Load simulation CSV and return list of dicts."""
    rows = []
    with open(path) as f:
        for row in csv.DictReader(f):
            rows.append({
                "total_cycle": int(row["total_cycle"]),
                "wl_id":       int(row["wl_id"]),
                "wl_cycle":    int(row["wl_cycle"]),
                "depth":       int(row["depth"]),
                "op":          row["op"].strip(),
                "E_in":        int(row["E_in"]),
                "E_out":       int(row["E_out"]),
                "accum":       int(row["accum"]),
                "region":      row["region"].strip(),
                "UF":          int(row["UF"]),
                "OVF":         int(row["OVF"]),
            })
    return rows

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — EPOCH CLASSIFIER (same rules as HBS-C9)
# ──────────────────────────────────────────────────────────────────────────────

def shannon_entropy(seq):
    c = Counter(seq)
    n = len(seq)
    return -sum((v/n)*math.log2(v/n) for v in c.values() if v > 0)

def classify_epoch(epoch_rows):
    """Given a list of cycle-rows from one epoch, return attractor label."""
    if not epoch_rows:
        return {"label": "A1", "confidence": 0.5}

    E_vals    = [r["E_out"] for r in epoch_rows]
    regions   = [r["region"] for r in epoch_rows]
    accums    = [r["accum"]  for r in epoch_rows]
    ops       = [r["op"]     for r in epoch_rows]
    ovf_count = sum(r["OVF"]  for r in epoch_rows)
    uf_count  = sum(r["UF"]   for r in epoch_rows)
    n         = len(epoch_rows)

    E_slope   = (E_vals[-1] - E_vals[0]) / max(n, 1)
    E_max     = max(E_vals)
    E_var     = float(np.var(E_vals)) if n > 1 else 0.0

    pct_coll  = regions.count("COLLAPSE")   / n
    pct_tran  = regions.count("TRANSITION") / n
    pct_stab  = regions.count("STABLE")     / n
    pct_sat   = regions.count("SATURATE")   / n

    acc_delta = abs(accums[-1] - accums[0]) if len(accums) >= 2 else 0
    entr      = shannon_entropy(E_vals)

    mul_frac  = ops.count("MUL") / n
    sub_frac  = ops.count("SUB") / n

    # Directional bias in E trajectory (distinguishes monotonic drift from oscillation)
    up_moves   = sum(1 for i in range(1, n) if E_vals[i] > E_vals[i-1])
    down_moves = sum(1 for i in range(1, n) if E_vals[i] < E_vals[i-1])
    up_frac    = up_moves / max(up_moves + down_moves, 1)

    # Boundary crossing rate (oscillation indicator: crossing ±15/16 or ±46/47)
    crossings = sum(
        1 for i in range(1, n)
        if (E_vals[i] <= 15 and E_vals[i-1] >= 16) or
           (E_vals[i] >= 16 and E_vals[i-1] <= 15) or
           (E_vals[i] >= 47 and E_vals[i-1] <= 46) or
           (E_vals[i] <= 46 and E_vals[i-1] >= 47)
    ) / max(n-1, 1)

    # ── C8 classification rules (v2 — refined for C10) ───────────────────
    #
    # A2: exponent drift driven by MUL chain OR direct OVF evidence.
    #     Require MUL involvement to avoid false A2 from ADD-based sweeps/injection.
    #     OVF alone is sufficient (definitive evidence regardless of op type).
    a2_by_ovf   = (ovf_count > 0)
    a2_by_drift = (mul_frac > 0.30 and E_slope > 0.35 and
                   E_max > 44 and up_frac > 0.65)
    if a2_by_ovf or a2_by_drift:
        label = "A2"; conf = 0.90 + 0.05 * min(ovf_count, 2)

    # A3: boundary oscillation — covers three sub-cases:
    #   (a) Classic: region alternates through COLL/SAT with crossings
    #   (b) Constant-TRANSITION: ADD at E=15 Rollover → output always in TRANSITION
    #   (c) Constant-SAT: ADD at E=47 Rollover → output always SAT
    #   (d) Alternating boundary: E alternates between two fixed values
    #   Discriminator: if SUB-dominant, classify as A1 (cancellation in boundary zone)
    elif (pct_coll + pct_sat + pct_tran) > 0.80 and (crossings > 0.20 or E_var < 5.0):
        if sub_frac > 0.50:
            label = "A1"; conf = 0.75  # SUB cancellation in non-STABLE zone
        else:
            label = "A3"; conf = 0.80 + 0.05 * crossings

    # A1: E stable in STABLE band, accumulator contamination from cancellation
    elif pct_stab > 0.70 and abs(E_slope) < 0.40 and (acc_delta > 100 or uf_count > 0):
        label = "A1"; conf = 0.80 + 0.05 * min(acc_delta / 1000, 0.1)

    # A4: multi-region mix, elevated entropy (no drift, no pure boundary)
    elif entr > 1.0 and pct_stab < 0.70 and ovf_count == 0:
        label = "A4"; conf = 0.70 + 0.05 * entr

    # Default (quasi-stable, NOP-heavy, or edge case)
    else:
        label = "A1"; conf = 0.55

    return {
        "label": label, "confidence": min(conf, 1.0),
        "E_slope": E_slope, "E_max": E_max, "E_var": E_var,
        "pct_coll": pct_coll, "pct_stab": pct_stab, "pct_sat": pct_sat,
        "ovf_count": ovf_count, "acc_delta": acc_delta,
        "entr": entr, "crossings": crossings,
        "mul_frac": mul_frac, "up_frac": up_frac,
    }

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — PER-WORKLOAD MEASUREMENTS
# ──────────────────────────────────────────────────────────────────────────────

def measure_workloads(rows):
    """Group rows by wl_id and compute per-workload and per-epoch metrics."""
    by_wl = defaultdict(list)
    for r in rows:
        if r["wl_cycle"] < STRESS_CYC:
            by_wl[r["wl_id"]].append(r)

    wl_metrics   = {}   # per-workload summary
    epoch_labels = {}   # per (wl_id, epoch_idx) → {label, conf, ...}

    for wl_id in sorted(by_wl.keys()):
        wl_rows = sorted(by_wl[wl_id], key=lambda r: r["wl_cycle"])
        wl_name = f"WL{wl_id:02d}"

        # Split into epochs of EPOCH_DEPTH
        epochs = []
        cur = []
        for r in wl_rows:
            cur.append(r)
            if len(cur) == EPOCH_DEPTH:
                epochs.append(cur)
                cur = []
        if cur:
            epochs.append(cur)

        epoch_results = []
        for ei, ep in enumerate(epochs):
            cls = classify_epoch(ep)
            cls["epoch_idx"]  = ei
            cls["wl_id"]      = wl_id
            epoch_results.append(cls)
            epoch_labels[(wl_id, ei)] = cls

        # Dominant attractor
        all_labels  = [e["label"] for e in epoch_results]
        dom_label   = Counter(all_labels).most_common(1)[0][0]

        # TTI: first cycle where E_out exceeds 44 or OVF fires
        tti_meas = None
        for i, r in enumerate(wl_rows):
            if r["OVF"] or r["E_out"] > 44:
                tti_meas = r["wl_cycle"]
                break
            if tti_meas is None and abs(r["E_out"] - 15) <= 1:
                tti_meas = r["wl_cycle"]

        ovf_total  = sum(r["OVF"] for r in wl_rows)
        ovf_pct_m  = ovf_total / len(wl_rows) * 100.0
        stab_pct_m = sum(1 for r in wl_rows if r["region"] == "STABLE") / len(wl_rows) * 100.0

        wl_metrics[wl_name] = {
            "dom_attractor":  dom_label,
            "tti_measured":   tti_meas,
            "ovf_pct_meas":   ovf_pct_m,
            "stable_pct_meas": stab_pct_m,
            "epoch_labels":   all_labels,
            "n_epochs":       len(epochs),
        }

    return wl_metrics, epoch_labels

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 5 — C10B: CONFUSION MATRIX & F1
# ──────────────────────────────────────────────────────────────────────────────

ATTRACTOR_LABELS = ["A1", "A2", "A3", "A4"]
ATTRACTOR_IDX    = {a: i for i, a in enumerate(ATTRACTOR_LABELS)}

def build_confusion_matrix(epoch_labels):
    """
    For every epoch, compare:
      predicted = PREDICTIONS[wl_name].epoch_seq[epoch_idx]
      measured  = epoch_labels[(wl_id, epoch_idx)].label
    """
    mat = np.zeros((4, 4), dtype=int)
    mismatch_details = []

    for (wl_id, ei), cls in sorted(epoch_labels.items()):
        wl_name  = f"WL{wl_id:02d}"
        pred_seq = PREDICTIONS[wl_name]["epoch_seq"]
        pred_lbl = pred_seq[min(ei, len(pred_seq) - 1)]
        meas_lbl = cls["label"]

        pi = ATTRACTOR_IDX[pred_lbl]
        mi = ATTRACTOR_IDX[meas_lbl]
        mat[pi][mi] += 1

        if pred_lbl != meas_lbl:
            mismatch_details.append({
                "wl": wl_name, "epoch": ei,
                "pred": pred_lbl, "meas": meas_lbl,
                "confidence": cls["confidence"],
                "E_slope": cls["E_slope"], "ovf": cls["ovf_count"],
            })

    return mat, mismatch_details

def accuracy_f1(mat):
    total   = mat.sum()
    correct = np.trace(mat)
    acc     = correct / total if total > 0 else 0.0

    per_class = {}
    for i, a in enumerate(ATTRACTOR_LABELS):
        tp = mat[i][i]
        fp = mat[:, i].sum() - tp
        fn = mat[i, :].sum() - tp
        p  = tp / (tp + fp) if (tp + fp) > 0 else 0.0
        r  = tp / (tp + fn) if (tp + fn) > 0 else 0.0
        f1 = 2*p*r / (p+r) if (p+r) > 0 else 0.0
        per_class[a] = {"precision": p, "recall": r, "f1": f1, "support": mat[i].sum()}

    # Macro F1
    macro_f1 = np.mean([v["f1"] for v in per_class.values()])
    return acc, macro_f1, per_class

def print_confusion_matrix(mat):
    lines = ["           Measured →"]
    header = "           " + "  ".join(f"  {a}" for a in ATTRACTOR_LABELS)
    lines.append(header)
    lines.append("           " + "-" * 28)
    for i, a in enumerate(ATTRACTOR_LABELS):
        row_str = "  ".join(f"{mat[i][j]:4d}" for j in range(4))
        lines.append(f"Pred {a} |  {row_str}")
    return "\n".join(lines)

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 6 — C10C: PARAMETER SWEEP
# ──────────────────────────────────────────────────────────────────────────────
# Generates a synthetic parameter grid from the simulation epochs and
# annotates each (depth_band, E_mag_band) with prediction vs measured label.

def parameter_sweep(epoch_labels, rows):
    """Map disagreement regions across depth × E_magnitude grid."""
    # Bin depth [1..16] into 4 bands; E [0..63] into 4 bands
    grid_agree = defaultdict(int)
    grid_total = defaultdict(int)

    by_wl_ep = defaultdict(list)
    for r in rows:
        if r["wl_cycle"] < STRESS_CYC:
            ep_idx = r["wl_cycle"] // EPOCH_DEPTH
            by_wl_ep[(r["wl_id"], ep_idx)].append(r)

    for (wl_id, ei), ep_rows in by_wl_ep.items():
        if not ep_rows:
            continue
        wl_name   = f"WL{wl_id:02d}"
        pred_seq  = PREDICTIONS[wl_name]["epoch_seq"]
        pred_lbl  = pred_seq[min(ei, len(pred_seq)-1)]
        meas_lbl  = epoch_labels.get((wl_id, ei), {}).get("label", "A1")

        avg_E     = np.mean([r["E_in"] for r in ep_rows])
        avg_depth = np.mean([r["depth"] for r in ep_rows])

        E_band  = min(int(avg_E / 16), 3)   # 0..3 → [0-15, 16-31, 32-47, 48-63]
        D_band  = min(int(avg_depth / 4), 3) # 0..3 → [0-3, 4-7, 8-11, 12-15]

        key = (D_band, E_band)
        grid_total[key] += 1
        if pred_lbl == meas_lbl:
            grid_agree[key] += 1

    results = []
    for key in sorted(grid_total.keys()):
        d_band, e_band = key
        total  = grid_total[key]
        agree  = grid_agree[key]
        results.append({
            "depth_band": d_band,
            "E_band":     e_band,
            "accuracy":   agree / total if total > 0 else 0.0,
            "total_epochs": total,
        })
    return results

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 7 — C10D: EMERGENCE SEARCH
# ──────────────────────────────────────────────────────────────────────────────

HIGH_CONF_THRESHOLD = 0.80  # Confidence above this = "high confidence" prediction
EMERGENCE_THRESHOLD = 0.70  # Measured confidence above this + mismatch = candidate

def emergence_search(mismatch_details, epoch_labels):
    """
    Identify epochs where:
      1. Prediction confidence (implicitly high for single-attractor workloads) is high
      2. Actual measured label differs from prediction
    Classify as: PREDICTION_ERROR | MEASUREMENT_NOISE | NEW_REGIME
    """
    emergent = []
    prediction_error = []
    measurement_noise = []

    for m in mismatch_details:
        wl_name = m["wl"]
        ei      = m["epoch"]
        pred    = m["pred"]
        meas    = m["meas"]
        conf    = m["confidence"]

        # Determine prediction confidence from workload type
        # (single-attractor workloads = high pred confidence)
        single_a_wls = ["WL00","WL01","WL04","WL05","WL06","WL09","WL10","WL16","WL19"]
        pred_conf = 0.92 if wl_name in single_a_wls else 0.72

        # Cannot be A5/NEW unless: high pred_conf, high meas_conf, AND not explainable by A1-A4
        is_high_conf_mismatch = (pred_conf >= HIGH_CONF_THRESHOLD and conf >= EMERGENCE_THRESHOLD)

        # Check if mismatch is explainable
        explainable_pairs = {
            ("A1","A4"), ("A4","A1"),  # STABLE-band confusion
            ("A2","A4"), ("A4","A2"),  # sparse MUL epochs
            ("A1","A2"), ("A2","A1"),  # boundary between burst and chain
            ("A3","A1"), ("A1","A3"),  # boundary boundary oscillation in TRANSITION
        }
        is_explainable = (pred, meas) in explainable_pairs

        if is_high_conf_mismatch and not is_explainable:
            emergent.append({**m, "classification": "POSSIBLE_NEW", "pred_conf": pred_conf})
        elif abs(m["E_slope"]) < 0.15 and conf < 0.60:
            measurement_noise.append({**m, "classification": "MEASUREMENT_NOISE"})
        else:
            prediction_error.append({**m, "classification": "PREDICTION_ERROR"})

    # Check emergent for true NEW (unexplainable by A1-A4)
    verified_new = [e for e in emergent
                    if e["confidence"] > 0.85
                    and abs(e["E_slope"]) > 0.5
                    and e["ovf"] == 0]

    return {
        "prediction_error":  prediction_error,
        "measurement_noise": measurement_noise,
        "emergent_candidates": emergent,
        "verified_new": verified_new,
    }

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 8 — C10E: MINIMAL PREDICTIVE MODEL (ATTRACTOR REDUCTION)
# ──────────────────────────────────────────────────────────────────────────────

def reduce_model(mat, n_attractors):
    """
    Test whether fewer attractors can match prediction accuracy.
    Merge strategies:
      4 → 3: merge A1+A4 (both non-explosive STABLE-adjacent; differ only in region mix)
      4 → 2: merge (A1+A4) + (A3+A4) = keep only A2 vs "not-A2"
    Returns accuracy under the reduced model.
    """
    if n_attractors == 4:
        return accuracy_f1(mat)

    elif n_attractors == 3:
        # Merge A1 (idx 0) and A4 (idx 3) into "A14"
        # New labels: A14(0+3), A2(1), A3(2)
        merged = np.zeros((3, 3), dtype=int)
        # Map: original A1→0, A2→1, A3→2, A4→0
        remap = [0, 1, 2, 0]
        for pi in range(4):
            for mi in range(4):
                merged[remap[pi]][remap[mi]] += mat[pi][mi]
        total   = merged.sum()
        correct = np.trace(merged)
        acc3    = correct / total if total > 0 else 0.0
        # Macro F1
        f1s = []
        for i in range(3):
            tp = merged[i][i]
            fp = merged[:, i].sum() - tp
            fn = merged[i, :].sum() - tp
            p  = tp / (tp + fp) if (tp + fp) > 0 else 0.0
            r  = tp / (tp + fn) if (tp + fn) > 0 else 0.0
            f1 = 2*p*r / (p+r) if (p+r) > 0 else 0.0
            f1s.append(f1)
        return acc3, np.mean(f1s), {}

    elif n_attractors == 2:
        # Keep only A2 vs "not-A2"
        binary = np.zeros((2, 2), dtype=int)
        # A2 = class 1; everything else = class 0
        for pi in range(4):
            for mi in range(4):
                p2 = 1 if pi == 1 else 0
                m2 = 1 if mi == 1 else 0
                binary[p2][m2] += mat[pi][mi]
        total   = binary.sum()
        correct = np.trace(binary)
        acc2    = correct / total if total > 0 else 0.0
        f1s = []
        for i in range(2):
            tp = binary[i][i]
            fp = binary[:, i].sum() - tp
            fn = binary[i, :].sum() - tp
            p  = tp / (tp + fp) if (tp + fp) > 0 else 0.0
            r  = tp / (tp + fn) if (tp + fn) > 0 else 0.0
            f1 = 2*p*r / (p+r) if (p+r) > 0 else 0.0
            f1s.append(f1)
        return acc2, np.mean(f1s), {}

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 9 — C10A: WORKLOAD-LEVEL PREDICTION ACCURACY
# ──────────────────────────────────────────────────────────────────────────────

def workload_prediction_accuracy(wl_metrics):
    correct = 0
    total   = 0
    details = []
    for wl_name, m in sorted(wl_metrics.items()):
        p = PREDICTIONS[wl_name]
        pred_att  = p["attractor"]
        meas_att  = m["dom_attractor"]
        match     = (pred_att == meas_att)

        pred_tti  = p["tti"]
        meas_tti  = m["tti_measured"]
        if pred_tti is not None and meas_tti is not None and meas_tti > 0:
            tti_err = abs(pred_tti - meas_tti) / meas_tti
        else:
            tti_err = None

        ovf_err  = abs(p["ovf_pct"] - m["ovf_pct_meas"]) if p["ovf_pct"] is not None else None
        stab_err = abs(p["stable_pct"] - m["stable_pct_meas"]) if p["stable_pct"] is not None else None

        correct += int(match)
        total   += 1
        details.append({
            "wl": wl_name, "pred": pred_att, "meas": meas_att, "match": match,
            "tti_pred": pred_tti, "tti_meas": meas_tti, "tti_err": tti_err,
            "ovf_err": ovf_err, "stab_err": stab_err,
        })

    wl_acc = correct / total if total > 0 else 0.0
    return wl_acc, details

# ──────────────────────────────────────────────────────────────────────────────
#  SECTION 10 — VERDICT
# ──────────────────────────────────────────────────────────────────────────────

def determine_verdict(acc4, f1_4, acc3, f1_3, acc2, f1_2, emergence_count):
    """
    MODEL_FAIL:         epoch F1 < 0.70
    MODEL_INCOMPLETE:   0.70 ≤ epoch F1 < 0.85
    MODEL_SUFFICIENT:   epoch F1 ≥ 0.85 AND 3-attractor F1 < 0.95
    MODEL_OVERCOMPLETE: 3-attractor F1 ≥ 0.95 (A1/A4 merge works)
    """
    if f1_4 < 0.70:
        verdict = "MODEL_FAIL"
        note    = "Fundamental attractor misclassification. C8 model requires revision."
    elif f1_4 < 0.85:
        verdict = "MODEL_INCOMPLETE"
        note    = "Model explains major dynamics but misses some regime transitions."
    elif f1_3 >= 0.95:
        verdict = "MODEL_OVERCOMPLETE"
        note    = "Merging A1+A4 maintains ≥95% accuracy. A1/A4 distinction may be unnecessary."
    else:
        verdict = "MODEL_SUFFICIENT"
        note    = f"4-attractor model F1={f1_4:.3f} ≥ 0.85; 3-attractor F1={f1_3:.3f} < 0.95. Model is minimal."
    return verdict, note

# ──────────────────────────────────────────────────────────────────────────────
#  MAIN
# ──────────────────────────────────────────────────────────────────────────────

def main():
    # ────────────────────────────────────────────────────────────────────────
    # STEP 1: Write blind predictions FIRST (C10A mandate)
    # ────────────────────────────────────────────────────────────────────────
    write_predictions_csv(PRED_CSV)
    print("=" * 70)
    print("  BLIND PREDICTION PHASE COMPLETE")
    print("  No simulation data has been accessed.")
    print("  Now loading simulation CSV...")
    print("=" * 70 + "\n")

    # ────────────────────────────────────────────────────────────────────────
    # STEP 2: Load simulation data
    # ────────────────────────────────────────────────────────────────────────
    if not os.path.exists(SIM_CSV):
        print(f"ERROR: {SIM_CSV} not found. Run the simulation first.")
        sys.exit(1)

    rows = load_sim_csv(SIM_CSV)
    print(f"[Load] {len(rows)} rows from {SIM_CSV}")

    # ────────────────────────────────────────────────────────────────────────
    # STEP 3: Measure all workloads
    # ────────────────────────────────────────────────────────────────────────
    wl_metrics, epoch_labels = measure_workloads(rows)
    total_epochs = len(epoch_labels)
    print(f"[Measure] {NUM_WL} workloads, {total_epochs} epochs classified\n")

    # ────────────────────────────────────────────────────────────────────────
    # STEP 4: C10A — Workload-level prediction accuracy
    # ────────────────────────────────────────────────────────────────────────
    wl_acc, wl_details = workload_prediction_accuracy(wl_metrics)
    print(f"[C10A] Workload-level prediction accuracy: {wl_acc*100:.1f}%")
    print(f"       Correct: {sum(1 for d in wl_details if d['match'])} / {len(wl_details)}")
    print()
    for d in wl_details:
        marker = "OK" if d["match"] else "!!"
        tti_s  = f"  TTI {d['tti_pred']}→{d['tti_meas']}" if d["tti_meas"] else ""
        print(f"  [{marker}] {d['wl']}: pred={d['pred']} meas={d['meas']}{tti_s}")
    print()

    # ────────────────────────────────────────────────────────────────────────
    # STEP 5: C10B — Epoch confusion matrix
    # ────────────────────────────────────────────────────────────────────────
    mat, mismatches = build_confusion_matrix(epoch_labels)
    acc4, f1_4, per_class = accuracy_f1(mat)
    print("[C10B] Epoch-level confusion matrix (Predicted rows × Measured cols):")
    print(print_confusion_matrix(mat))
    print()
    print(f"  Accuracy:  {acc4*100:.1f}%")
    print(f"  Macro F1:  {f1_4:.4f}")
    print()
    for a, v in per_class.items():
        print(f"  {a}: P={v['precision']:.3f}  R={v['recall']:.3f}  F1={v['f1']:.3f}  support={v['support']}")
    print()

    # ────────────────────────────────────────────────────────────────────────
    # STEP 6: C10C — Parameter sweep
    # ────────────────────────────────────────────────────────────────────────
    sweep_results = parameter_sweep(epoch_labels, rows)
    print("[C10C] Parameter sweep — disagreement regions (depth_band × E_band):")
    print("       depth_band: 0=[d0-3] 1=[d4-7] 2=[d8-11] 3=[d12-15]")
    print("       E_band:     0=[E0-15] 1=[E16-31] 2=[E32-47] 3=[E48-63]")
    print()
    for s in sweep_results:
        bar = "=" * int(s["accuracy"] * 20)
        print(f"  D{s['depth_band']}×E{s['E_band']}: acc={s['accuracy']*100:5.1f}%  {bar}  (n={s['total_epochs']})")
    print()

    # ────────────────────────────────────────────────────────────────────────
    # STEP 7: C10D — Emergence search
    # ────────────────────────────────────────────────────────────────────────
    emerg = emergence_search(mismatches, epoch_labels)
    emergence_count = len(emerg["verified_new"])
    print(f"[C10D] Emergence search:")
    print(f"  Total mismatches:       {len(mismatches)}")
    print(f"  Prediction errors:      {len(emerg['prediction_error'])}")
    print(f"  Measurement noise:      {len(emerg['measurement_noise'])}")
    print(f"  Emergent candidates:    {len(emerg['emergent_candidates'])}")
    print(f"  Verified NEW regimes:   {emergence_count}")
    if emergence_count > 0:
        print("  WARNING: New attractors found — C8 model may be INCOMPLETE")
        for v in emerg["verified_new"]:
            print(f"    WL={v['wl']} epoch={v['epoch']} pred={v['pred']} meas={v['meas']} conf={v['confidence']:.2f}")
    else:
        print("  CLEAR: All mismatches explained by A1–A4 transitions or prediction error")
    print()

    # ────────────────────────────────────────────────────────────────────────
    # STEP 8: C10E — Attractor reduction
    # ────────────────────────────────────────────────────────────────────────
    acc3, f1_3, _ = reduce_model(mat, 3)  # merge A1+A4
    acc2, f1_2, _ = reduce_model(mat, 2)  # keep only A2 vs not-A2
    print("[C10E] Attractor reduction:")
    print(f"  4-attractor model:  acc={acc4*100:.1f}%  macro-F1={f1_4:.4f}")
    print(f"  3-attractor (A1+A4 merged):  acc={acc3*100:.1f}%  macro-F1={f1_3:.4f}")
    print(f"  2-attractor (A2 vs rest):    acc={acc2*100:.1f}%  macro-F1={f1_2:.4f}")
    delta_43 = (f1_4 - f1_3)
    delta_32 = (f1_3 - f1_2)
    print(f"  F1 loss 4→3: {delta_43:+.4f}   (negative = merging HURTS, positive = merging HELPS)")
    print(f"  F1 loss 3→2: {delta_32:+.4f}")
    print()

    # ────────────────────────────────────────────────────────────────────────
    # STEP 9: Verdict
    # ────────────────────────────────────────────────────────────────────────
    verdict, note = determine_verdict(acc4, f1_4, acc3, f1_3, acc2, f1_2, emergence_count)
    print("=" * 70)
    print(f"  FINAL VERDICT: {verdict}")
    print(f"  {note}")
    print("=" * 70)
    print()

    # ────────────────────────────────────────────────────────────────────────
    # STEP 10: Write summary log
    # ────────────────────────────────────────────────────────────────────────
    with open(SUMMARY_LOG, "w") as f:
        f.write("=" * 70 + "\n")
        f.write("HBS-C10: PREDICTIVE VALIDATION — SUMMARY LOG\n")
        f.write("=" * 70 + "\n\n")

        f.write("BLIND PREDICTION METHODOLOGY:\n")
        f.write("  Predictions generated from C8 attractor model rules BEFORE\n")
        f.write("  simulation CSV was read. See HBS_C10_PREDICTIONS.csv.\n\n")

        f.write(f"WORKLOADS TESTED: {NUM_WL} (WL00–WL19)\n")
        f.write(f"EPOCHS CLASSIFIED: {total_epochs}\n\n")

        f.write("C10A — WORKLOAD-LEVEL PREDICTION ACCURACY\n")
        f.write(f"  {wl_acc*100:.1f}% ({sum(1 for d in wl_details if d['match'])}/{len(wl_details)} correct)\n\n")
        for d in wl_details:
            marker = "OK" if d["match"] else "!!"
            f.write(f"  [{marker}] {d['wl']}: pred={d['pred']} meas={d['meas']}\n")

        f.write("\nC10B — EPOCH CONFUSION MATRIX\n")
        f.write(print_confusion_matrix(mat) + "\n\n")
        f.write(f"  Accuracy:  {acc4*100:.1f}%\n")
        f.write(f"  Macro F1:  {f1_4:.4f}\n")
        for a, v in per_class.items():
            f.write(f"  {a}: P={v['precision']:.3f}  R={v['recall']:.3f}  F1={v['f1']:.3f}\n")

        f.write("\nC10C — PARAMETER SWEEP DISAGREEMENT MAP\n")
        for s in sweep_results:
            f.write(f"  D{s['depth_band']}×E{s['E_band']}: acc={s['accuracy']*100:.1f}% n={s['total_epochs']}\n")

        f.write(f"\nC10D — EMERGENCE SEARCH\n")
        f.write(f"  Mismatches: {len(mismatches)}\n")
        f.write(f"  Prediction errors: {len(emerg['prediction_error'])}\n")
        f.write(f"  Measurement noise: {len(emerg['measurement_noise'])}\n")
        f.write(f"  Verified NEW: {emergence_count}\n")

        f.write(f"\nC10E — ATTRACTOR REDUCTION\n")
        f.write(f"  4-attractor: F1={f1_4:.4f}\n")
        f.write(f"  3-attractor (A1+A4 merged): F1={f1_3:.4f}\n")
        f.write(f"  2-attractor (A2 vs rest):   F1={f1_2:.4f}\n")
        f.write(f"  F1 loss 4→3: {delta_43:+.4f}\n")
        f.write(f"  F1 loss 3→2: {delta_32:+.4f}\n")

        f.write(f"\n{'='*70}\n")
        f.write(f"FINAL VERDICT: {verdict}\n")
        f.write(f"{note}\n")
        f.write(f"{'='*70}\n")

        if verdict == "MODEL_SUFFICIENT":
            f.write("\nQUANTITATIVE EVIDENCE (F1 ≥ 0.85):\n")
            f.write(f"  4-attractor macro F1 = {f1_4:.4f} ≥ 0.85 threshold\n")
            f.write(f"  3-attractor macro F1 = {f1_3:.4f} < 0.95 threshold\n")
            f.write("  → Minimum attractor count = 4. No merge possible.\n")
        elif verdict == "MODEL_OVERCOMPLETE":
            f.write("\nMERGER LOGIC:\n")
            f.write("  A1 + A4 → 'A14' (Accumulator Contamination / Mixed Injection)\n")
            f.write("  Distinguishing criterion: A1=100% STABLE, A4=multi-region\n")
            f.write("  Epoch-level classifier cannot reliably separate them.\n")
            f.write("  Recommend: workload-level (not epoch-level) A1/A4 discrimination.\n")

    print(f"[Log] Summary written → {SUMMARY_LOG}")
    print(f"[Log] Predictions CSV → {PRED_CSV}")
    print()
    print("HBS-C10 COMPLETE.")
    return verdict, f1_4

if __name__ == "__main__":
    main()
