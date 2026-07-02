#!/usr/bin/env python3
"""
analyze_hbs_c2_live.py — HBS-C2 Live System Observation Analysis

Parses HBS_C2_LIVE_SIM.csv (produced by tb_hbs_c2_live_sim.v) and
reconstructs the HORUS v3 system state-space geometry from continuous-time
observation.

NO SPECULATION. All figures derived directly from the logged CSV data.

Outputs:
    HBS_C2_LIVE_SUMMARY.log     — Human-readable summary (sourced by docs)
    hbs_c2_e_density.png        — E-space occupancy density plot
    hbs_c2_uf_ovf_timeline.png  — UF/OVF event timeline
    hbs_c2_accum_drift.png      — Accumulator drift over time (all streams)
    hbs_c2_mode_region_hm.png   — mode_tag vs region heatmap (observational)
    hbs_c2_state_space_ascii.txt— ASCII state-space map (terminal friendly)
"""

import csv
import sys
import os
import math
from collections import defaultdict, Counter

# ─────────────────────────────────────────────────────────────────────────────
# 1. LOAD CSV
# ─────────────────────────────────────────────────────────────────────────────

CSV_FILE  = "HBS_C2_LIVE_SIM.csv"
LOG_FILE  = "HBS_C2_LIVE_SUMMARY.log"
ASCII_MAP = "hbs_c2_state_space_ascii.txt"

def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "cycle":   int(row["cycle"]),
                "stream":  row["stream"].strip(),
                "A":       int(row["A"], 16),
                "B":       int(row["B"], 16),
                "OP":      row["OP"].strip(),
                "E_est":   int(row["E_est"]),
                "MODE":    int(row["MODE"]),
                "RESULT":  int(row["RESULT"], 16),
                "ACC":     int(row["ACC"], 16),
                "PE_ACC":  int(row["PE_ACC"], 16),
                "UF":      int(row["UF"]),
                "OVF":     int(row["OVF"]),
                "RO":      int(row["RO"]),
                "REGION":  row["REGION"].strip(),
            })
    return rows

# ─────────────────────────────────────────────────────────────────────────────
# 2. REGION OCCUPANCY HISTOGRAM
# ─────────────────────────────────────────────────────────────────────────────

REGIONS = ["STABLE", "TRANSITION", "COLLAPSE", "SATURATE"]
MODES   = {0: "STD", 1: "BIAS", 2: "PRSC", 3: "SAFE"}
STREAMS = ["A", "B", "C"]

def region_occupancy(rows):
    """Per-stream and global region occupancy counts."""
    total   = Counter()
    per_str = {s: Counter() for s in STREAMS}
    for r in rows:
        total[r["REGION"]] += 1
        per_str[r["stream"]][r["REGION"]] += 1
    return total, per_str

def e_histogram(rows):
    """Full 64-bucket E-space occupancy density (0..63)."""
    hist = Counter()
    per_str = {s: Counter() for s in STREAMS}
    for r in rows:
        hist[r["E_est"]] += 1
        per_str[r["stream"]][r["E_est"]] += 1
    return hist, per_str

# ─────────────────────────────────────────────────────────────────────────────
# 3. BOUNDARY CROSSING FREQUENCY
# ─────────────────────────────────────────────────────────────────────────────

def boundary_crossings(rows):
    """
    Detect boundary crossings as consecutive cycles where E_est transitions
    across E=15/16 or E=47/48.
    """
    crossings = {"collapse_entry": 0, "collapse_exit": 0,
                 "saturate_entry": 0, "saturate_exit": 0}
    per_str   = {s: {k: 0 for k in crossings} for s in STREAMS}

    prev_E = {s: None for s in STREAMS}

    for r in rows:
        s = r["stream"]
        e = r["E_est"]
        p = prev_E[s]

        if p is not None:
            # Collapse boundary (15 ↔ 16)
            if p >= 16 and e <= 15:
                crossings["collapse_entry"] += 1
                per_str[s]["collapse_entry"] += 1
            if p <= 15 and e >= 16:
                crossings["collapse_exit"] += 1
                per_str[s]["collapse_exit"] += 1
            # Saturation boundary (47 ↔ 48)
            if p <= 47 and e >= 48:
                crossings["saturate_entry"] += 1
                per_str[s]["saturate_entry"] += 1
            if p >= 48 and e <= 47:
                crossings["saturate_exit"] += 1
                per_str[s]["saturate_exit"] += 1

        prev_E[s] = e

    return crossings, per_str

# ─────────────────────────────────────────────────────────────────────────────
# 4. UF/OVF CLUSTERING
# ─────────────────────────────────────────────────────────────────────────────

def uf_ovf_stats(rows):
    """UF/OVF event counts, clustering, and region correlation."""
    uf_total  = sum(r["UF"]  for r in rows)
    ovf_total = sum(r["OVF"] for r in rows)

    uf_by_stream  = {s: sum(r["UF"]  for r in rows if r["stream"] == s) for s in STREAMS}
    ovf_by_stream = {s: sum(r["OVF"] for r in rows if r["stream"] == s) for s in STREAMS}

    uf_by_region  = Counter(r["REGION"] for r in rows if r["UF"])
    ovf_by_region = Counter(r["REGION"] for r in rows if r["OVF"])

    # Run-length clustering: consecutive UF cycles
    max_uf_run = 0
    cur_run    = 0
    uf_runs    = []
    for r in rows:
        if r["UF"]:
            cur_run += 1
        else:
            if cur_run > 0:
                uf_runs.append(cur_run)
                max_uf_run = max(max_uf_run, cur_run)
            cur_run = 0
    if cur_run > 0:
        uf_runs.append(cur_run)
        max_uf_run = max(max_uf_run, cur_run)

    avg_uf_run = (sum(uf_runs) / len(uf_runs)) if uf_runs else 0.0

    return {
        "uf_total":      uf_total,
        "ovf_total":     ovf_total,
        "uf_by_stream":  uf_by_stream,
        "ovf_by_stream": ovf_by_stream,
        "uf_by_region":  dict(uf_by_region),
        "ovf_by_region": dict(ovf_by_region),
        "max_uf_run":    max_uf_run,
        "avg_uf_run":    avg_uf_run,
        "uf_run_count":  len(uf_runs),
    }

# ─────────────────────────────────────────────────────────────────────────────
# 5. ACCUMULATOR DRIFT
# ─────────────────────────────────────────────────────────────────────────────

def accum_drift(rows):
    """
    Per-stream accumulator trajectory and drift metrics.
    Delta = ACC - PE_ACC per cycle (signed).
    """
    per_str = {s: [] for s in STREAMS}
    for r in rows:
        delta = r["ACC"] - r["PE_ACC"]
        per_str[r["stream"]].append((r["cycle"], r["ACC"], delta))

    stats = {}
    for s, data in per_str.items():
        if not data:
            stats[s] = {}
            continue
        accs    = [d[1] for d in data]
        deltas  = [d[2] for d in data]
        n       = len(deltas)
        mean_d  = sum(deltas) / n
        max_d   = max(deltas)
        min_d   = min(deltas)
        max_acc = max(accs)
        min_acc = min(accs)
        # Monotonic growth check
        growth_cycles = sum(1 for d in deltas if d > 0)
        decay_cycles  = sum(1 for d in deltas if d < 0)
        flat_cycles   = sum(1 for d in deltas if d == 0)
        stats[s] = {
            "mean_delta":    mean_d,
            "max_delta":     max_d,
            "min_delta":     min_d,
            "max_acc":       max_acc,
            "min_acc":       min_acc,
            "growth_cycles": growth_cycles,
            "decay_cycles":  decay_cycles,
            "flat_cycles":   flat_cycles,
            "final_acc":     data[-1][1],
        }
    return stats, per_str

# ─────────────────────────────────────────────────────────────────────────────
# 6. MODE EFFECTIVENESS (OBSERVATIONAL ONLY)
# ─────────────────────────────────────────────────────────────────────────────

def mode_effectiveness(rows):
    """
    For each (region, mode) pair: count UF/OVF frequency.
    NO causal claims. This is pure distribution observation.
    """
    # key: (region, mode) → {uf_count, ovf_count, total}
    stats = defaultdict(lambda: {"uf": 0, "ovf": 0, "total": 0})
    for r in rows:
        key = (r["REGION"], r["MODE"])
        stats[key]["total"] += 1
        stats[key]["uf"]    += r["UF"]
        stats[key]["ovf"]   += r["OVF"]

    result = {}
    for (region, mode), v in stats.items():
        uf_rate  = v["uf"]  / v["total"] if v["total"] else 0
        ovf_rate = v["ovf"] / v["total"] if v["total"] else 0
        result[(region, MODES.get(mode, str(mode)))] = {
            "total":    v["total"],
            "uf_rate":  uf_rate,
            "ovf_rate": ovf_rate,
        }
    return result

# ─────────────────────────────────────────────────────────────────────────────
# 7. TRANSITION CLIFF SHARPNESS
# ─────────────────────────────────────────────────────────────────────────────

def cliff_sharpness(e_hist):
    """
    Measure the density gradient at E=15→16 and E=47→48.
    Cliff sharpness = |density[E_above] - density[E_below]| / max_density
    """
    total   = sum(e_hist.values())
    if total == 0:
        return {"collapse_sharpness": 0.0, "saturate_sharpness": 0.0}

    max_d   = max(e_hist.values()) / total

    d15 = e_hist.get(15, 0) / total
    d16 = e_hist.get(16, 0) / total
    d47 = e_hist.get(47, 0) / total
    d48 = e_hist.get(48, 0) / total

    coll_sharp = abs(d16 - d15) / max_d if max_d > 0 else 0.0
    sat_sharp  = abs(d47 - d48) / max_d if max_d > 0 else 0.0

    return {
        "collapse_sharpness": coll_sharp,
        "saturate_sharpness": sat_sharp,
        "density_E15": d15,
        "density_E16": d16,
        "density_E47": d47,
        "density_E48": d48,
    }

# ─────────────────────────────────────────────────────────────────────────────
# 8. ASCII STATE-SPACE MAP
# ─────────────────────────────────────────────────────────────────────────────

def ascii_state_space_map(e_hist, total_cycles, streams_e_hist):
    """
    ASCII bar chart: E-space occupancy density (E=0..63).
    Shows where the system spends time in exponent space.
    """
    lines = []
    lines.append("=" * 72)
    lines.append("  HORUS v3 E-SPACE OCCUPANCY MAP  (HBS-C2 Live Observation)")
    lines.append("=" * 72)
    lines.append("")
    lines.append("  E     | COLLAPSE  E≤15  | STABLE   E=16-47 | SAT  E≥48 |")
    lines.append("  ──────┼──────────────────┼──────────────────┼────────────┤")

    max_count = max(e_hist.values()) if e_hist else 1
    total     = sum(e_hist.values())

    bar_max  = 40  # maximum bar width in characters
    for e in range(64):
        count   = e_hist.get(e, 0)
        density = count / total if total > 0 else 0
        bar_len = int((count / max_count) * bar_max)
        bar     = "█" * bar_len

        # Region label
        if e <= 15:
            region_marker = "C"
        elif e <= 19:
            region_marker = "T"
        elif e <= 43:
            region_marker = "S"
        elif e <= 47:
            region_marker = "T"
        else:
            region_marker = "X"

        # Cliff markers
        cliff = ""
        if e == 15:  cliff = " ◄ COLLAPSE CLIFF"
        if e == 16:  cliff = " ◄ STABLE ENTRY"
        if e == 47:  cliff = " ◄ SAT APPROACH"
        if e == 48:  cliff = " ◄ SATURATE ENTRY"

        lines.append(f"  E={e:02d} {region_marker} |{bar:<40}| {count:5d} ({density*100:5.2f}%){cliff}")

    lines.append("")
    lines.append("  Legend: C=Collapse  T=Transition  S=Stable  X=Saturate")
    lines.append(f"  Total cycles analyzed: {total}")
    lines.append("")

    # Per-stream breakdown at key E values
    lines.append("  Per-stream density at boundary zones:")
    lines.append("  Stream | E=13..18 (collapse zone) | E=44..50 (sat zone) | E=20..43 (stable core)")
    lines.append("  ───────┼─────────────────────────┼─────────────────────┼────────────────────────")
    for s in STREAMS:
        sh = streams_e_hist[s]
        st = sum(sh.values()) or 1
        cz = sum(sh.get(e, 0) for e in range(13, 19)) / st * 100
        sz = sum(sh.get(e, 0) for e in range(44, 51)) / st * 100
        sb = sum(sh.get(e, 0) for e in range(20, 44)) / st * 100
        lines.append(f"    {s}    | {cz:6.2f}%                  | {sz:6.2f}%              | {sb:6.2f}%")

    lines.append("=" * 72)
    return lines

# ─────────────────────────────────────────────────────────────────────────────
# 9. MATPLOTLIB PLOTS
# ─────────────────────────────────────────────────────────────────────────────

def try_matplotlib():
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        return plt
    except ImportError:
        return None

def plot_e_density(e_hist, total, plt):
    fig, axes = plt.subplots(1, 1, figsize=(14, 5))
    ax = axes

    E_vals   = list(range(64))
    counts   = [e_hist.get(e, 0) for e in E_vals]
    density  = [c / total if total > 0 else 0 for c in counts]

    colors = []
    for e in E_vals:
        if   e <= 15:   colors.append("#c0392b")  # red   — collapse
        elif e <= 19:   colors.append("#e67e22")  # orange — transition low
        elif e <= 43:   colors.append("#27ae60")  # green — stable
        elif e <= 47:   colors.append("#e67e22")  # orange — transition high
        else:           colors.append("#8e44ad")  # purple — saturate

    ax.bar(E_vals, density, color=colors, width=0.85, edgecolor="none")
    ax.axvline(x=15.5, color="black", linestyle="--", linewidth=1.5, label="Collapse cliff (15/16)")
    ax.axvline(x=47.5, color="black", linestyle=":",  linewidth=1.5, label="Saturate cliff (47/48)")
    ax.set_xlabel("Stored Exponent (E_est)", fontsize=11)
    ax.set_ylabel("Relative Frequency", fontsize=11)
    ax.set_title("HORUS v3 E-Space Occupancy Density  [HBS-C2 Live Observation]", fontsize=12)
    ax.legend(fontsize=9)
    ax.set_xlim(-0.5, 63.5)

    # Region annotations
    ax.axvspan(-0.5, 15.5,  alpha=0.08, color="#c0392b", label="_collapse_bg")
    ax.axvspan(15.5, 19.5,  alpha=0.08, color="#e67e22")
    ax.axvspan(19.5, 43.5,  alpha=0.08, color="#27ae60")
    ax.axvspan(43.5, 47.5,  alpha=0.08, color="#e67e22")
    ax.axvspan(47.5, 63.5,  alpha=0.08, color="#8e44ad")

    for label, x, ha in [("COLLAPSE", 7, "center"), ("TRANS", 17, "center"),
                          ("STABLE", 31, "center"), ("TRANS", 45, "center"),
                          ("SAT", 55, "center")]:
        ax.text(x, ax.get_ylim()[1] * 0.90, label, ha=ha, va="top",
                fontsize=8, alpha=0.6)

    fig.tight_layout()
    fig.savefig("hbs_c2_e_density.png", dpi=120)
    plt.close(fig)

def plot_uf_ovf_timeline(rows, plt):
    cycles = [r["cycle"] for r in rows]
    uf_cy  = [r["cycle"] for r in rows if r["UF"]]
    ovf_cy = [r["cycle"] for r in rows if r["OVF"]]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 5), sharex=True)

    ax1.bar(uf_cy,  [1]*len(uf_cy),  width=1.5, color="#c0392b", alpha=0.8)
    ax1.set_ylabel("UF Events", fontsize=10)
    ax1.set_title("UF / OVF Event Timeline  [HBS-C2]", fontsize=11)
    ax1.set_yticks([0, 1])

    ax2.bar(ovf_cy, [1]*len(ovf_cy), width=1.5, color="#8e44ad", alpha=0.8)
    ax2.set_ylabel("OVF Events", fontsize=10)
    ax2.set_xlabel("Cycle", fontsize=10)
    ax2.set_yticks([0, 1])

    # Shade stream regions
    for ax in (ax1, ax2):
        for cy in range(0, max(cycles)+1, 3):
            if cy % 3 == 0:  ax.axvspan(cy, cy+1, alpha=0.04, color="#3498db")
            elif cy % 3 == 1: ax.axvspan(cy, cy+1, alpha=0.04, color="#e74c3c")
            else:             ax.axvspan(cy, cy+1, alpha=0.04, color="#2ecc71")

    fig.tight_layout()
    fig.savefig("hbs_c2_uf_ovf_timeline.png", dpi=120)
    plt.close(fig)

def plot_accum_drift(accum_data_per_str, plt):
    fig, axes = plt.subplots(3, 1, figsize=(14, 8), sharex=False)
    colors = {"A": "#3498db", "B": "#e74c3c", "C": "#2ecc71"}

    for i, s in enumerate(STREAMS):
        ax   = axes[i]
        data = accum_data_per_str[s]
        if not data:
            ax.text(0.5, 0.5, f"Stream {s}: no data", transform=ax.transAxes, ha="center")
            continue
        cycs = [d[0] for d in data]
        accs = [d[1] for d in data]
        ax.plot(cycs, accs, color=colors[s], linewidth=0.7, alpha=0.85)
        ax.set_ylabel(f"Stream {s}\naccum_out", fontsize=9)
        ax.set_xlabel("Cycle" if i == 2 else "", fontsize=9)
        if i == 0:
            ax.set_title("Accumulator Trajectory Over Time  [HBS-C2]", fontsize=11)

    fig.tight_layout()
    fig.savefig("hbs_c2_accum_drift.png", dpi=120)
    plt.close(fig)

def plot_mode_region_heatmap(mode_eff, plt):
    region_order = ["STABLE", "TRANSITION", "COLLAPSE", "SATURATE"]
    mode_order   = ["STD", "BIAS", "PRSC", "SAFE"]

    uf_mat  = [[0.0]*4 for _ in range(4)]
    ovf_mat = [[0.0]*4 for _ in range(4)]

    for (region, mode), stats in mode_eff.items():
        if region in region_order and mode in mode_order:
            ri = region_order.index(region)
            mi = mode_order.index(mode)
            uf_mat[ri][mi]  = stats["uf_rate"]
            ovf_mat[ri][mi] = stats["ovf_rate"]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4))

    for ax, mat, title, cmap in [
        (ax1, uf_mat,  "UF Rate by (Region, Mode)",  "Reds"),
        (ax2, ovf_mat, "OVF Rate by (Region, Mode)", "Purples")
    ]:
        import numpy as np
        data = np.array(mat)
        im = ax.imshow(data, cmap=cmap, aspect="auto", vmin=0, vmax=1)
        ax.set_xticks(range(4)); ax.set_xticklabels(mode_order, fontsize=9)
        ax.set_yticks(range(4)); ax.set_yticklabels(region_order, fontsize=9)
        ax.set_xlabel("mode_tag", fontsize=9)
        ax.set_ylabel("Region",   fontsize=9)
        ax.set_title(title + "\n[observational — no causal claims]", fontsize=9)
        fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
        for ri in range(4):
            for mi in range(4):
                v = data[ri, mi]
                ax.text(mi, ri, f"{v:.2f}", ha="center", va="center",
                        color="white" if v > 0.5 else "black", fontsize=8)

    fig.tight_layout()
    fig.savefig("hbs_c2_mode_region_hm.png", dpi=120)
    plt.close(fig)

# ─────────────────────────────────────────────────────────────────────────────
# 10. SUMMARY LOG WRITER
# ─────────────────────────────────────────────────────────────────────────────

def write_summary(log_path, rows, region_total, region_per_str,
                  e_hist, e_per_str, crossings, crossings_per_str,
                  uf_stats, drift_stats, mode_eff, cliff):

    N = len(rows)
    with open(log_path, "w") as f:

        def w(s=""): f.write(s + "\n")

        w("=" * 72)
        w("  HBS-C2: LIVE SYSTEM OBSERVATION SUMMARY")
        w("  HORUS v3 — Continuous Stimulus + Per-Cycle Trace Analysis")
        w(f"  Total cycles analyzed: {N}")
        w("=" * 72)
        w()

        # ── Section 1: Observed State Geometry ────────────────────────────
        w("─" * 72)
        w("  1. OBSERVED STATE GEOMETRY  (where system spends time)")
        w("─" * 72)
        w()
        w("  Global region occupancy:")
        for reg in REGIONS:
            cnt  = region_total.get(reg, 0)
            pct  = cnt / N * 100 if N else 0
            bar  = "▪" * int(pct / 2)
            w(f"    {reg:<12}  {cnt:5d} / {N}  ({pct:5.1f}%)  {bar}")
        w()
        w("  Per-stream region occupancy (% of stream cycles):")
        hdr = "  {:>12}".format("Region") + "".join(f"  Stream {s:>4}" for s in STREAMS)
        w(hdr)
        w("  " + "-" * (len(hdr) - 2))
        for reg in REGIONS:
            row_str = f"  {reg:<12}"
            for s in STREAMS:
                cnt_s = region_per_str[s].get(reg, 0)
                tot_s = sum(region_per_str[s].values()) or 1
                row_str += f"  {cnt_s/tot_s*100:9.1f}%"
            w(row_str)
        w()

        # ── Section 2: Boundary Interaction Map ───────────────────────────
        w("─" * 72)
        w("  2. BOUNDARY INTERACTION MAP  (crossing frequency by stream)")
        w("─" * 72)
        w()
        w("  Global crossings:")
        for k, v in crossings.items():
            w(f"    {k:<22}  {v:4d}")
        w()
        w("  Per-stream crossings:")
        for s in STREAMS:
            w(f"    Stream {s}:")
            for k, v in crossings_per_str[s].items():
                w(f"      {k:<22}  {v:4d}")
        w()
        w("  Cliff sharpness (density gradient at cliffs, normalized):")
        w(f"    Collapse cliff (E=15↔16):   {cliff['collapse_sharpness']:.4f}")
        w(f"    Saturation cliff (E=47↔48): {cliff['saturate_sharpness']:.4f}")
        w(f"    Density at E=15: {cliff['density_E15']*100:.3f}%  "
          f"E=16: {cliff['density_E16']*100:.3f}%  "
          f"|Δ|: {abs(cliff['density_E16']-cliff['density_E15'])*100:.3f}%")
        w(f"    Density at E=47: {cliff['density_E47']*100:.3f}%  "
          f"E=48: {cliff['density_E48']*100:.3f}%  "
          f"|Δ|: {abs(cliff['density_E48']-cliff['density_E47'])*100:.3f}%")
        w()

        # ── Section 3: Collapse Dynamics ──────────────────────────────────
        w("─" * 72)
        w("  3. COLLAPSE DYNAMICS  (UF event frequency + clustering)")
        w("─" * 72)
        w()
        uf_rate = uf_stats["uf_total"] / N * 100 if N else 0
        w(f"  Total UF events:      {uf_stats['uf_total']:5d}  ({uf_rate:.2f}% of cycles)")
        w(f"  UF run count:         {uf_stats['uf_run_count']:5d}  (distinct UF bursts)")
        w(f"  Max consecutive UF:   {uf_stats['max_uf_run']:5d}")
        w(f"  Avg run length:       {uf_stats['avg_uf_run']:.2f}")
        w()
        w("  UF by stream:")
        for s in STREAMS:
            cnt  = uf_stats["uf_by_stream"].get(s, 0)
            tot_s = sum(1 for r in rows if r["stream"] == s) or 1
            w(f"    Stream {s}: {cnt:5d}  ({cnt/tot_s*100:.2f}% of stream cycles)")
        w()
        w("  UF by region (region of result at time of UF):")
        for reg in REGIONS:
            cnt = uf_stats["uf_by_region"].get(reg, 0)
            w(f"    {reg:<12}  {cnt:4d}")
        w()

        # ── Section 4: Saturation Behavior ────────────────────────────────
        w("─" * 72)
        w("  4. SATURATION BEHAVIOR  (OVF distribution)")
        w("─" * 72)
        w()
        ovf_rate = uf_stats["ovf_total"] / N * 100 if N else 0
        w(f"  Total OVF events:     {uf_stats['ovf_total']:5d}  ({ovf_rate:.2f}% of cycles)")
        w()
        w("  OVF by stream:")
        for s in STREAMS:
            cnt  = uf_stats["ovf_by_stream"].get(s, 0)
            tot_s = sum(1 for r in rows if r["stream"] == s) or 1
            w(f"    Stream {s}: {cnt:5d}  ({cnt/tot_s*100:.2f}% of stream cycles)")
        w()
        w("  OVF by region:")
        for reg in REGIONS:
            cnt = uf_stats["ovf_by_region"].get(reg, 0)
            w(f"    {reg:<12}  {cnt:4d}")
        w()

        # ── Section 5: Mode Effectiveness (observational only) ─────────────
        w("─" * 72)
        w("  5. MODE EFFECTIVENESS  (observational distribution only)")
        w("     NO CAUSAL CLAIMS. Distribution only.")
        w("─" * 72)
        w()
        w(f"  {'Region':<12}  {'Mode':<6}  {'Total':>6}  {'UF rate':>8}  {'OVF rate':>8}")
        w("  " + "-" * 50)
        for (region, mode) in sorted(mode_eff.keys()):
            v = mode_eff[(region, mode)]
            if v["total"] > 0:
                w(f"  {region:<12}  {mode:<6}  {v['total']:>6}  "
                  f"{v['uf_rate']:>7.4f}   {v['ovf_rate']:>7.4f}")
        w()
        w("  Observation: does mode_tag change UF/OVF distribution?")
        all_modes = {mode for (_, mode) in mode_eff.keys()}
        for reg in REGIONS:
            uf_rates = {mode: mode_eff.get((reg, mode), {}).get("uf_rate", None)
                        for mode in all_modes}
            non_null = {m: v for m, v in uf_rates.items() if v is not None}
            if len(non_null) > 1:
                max_uf = max(non_null.values())
                min_uf = min(non_null.values())
                spread = max_uf - min_uf
                note = "NO SPREAD (mode-invariant)" if spread < 0.001 else f"spread={spread:.4f}"
                w(f"    {reg:<12}: UF rate range [{min_uf:.4f} .. {max_uf:.4f}]  → {note}")
        w()

        # ── Accumulator Drift ──────────────────────────────────────────────
        w("─" * 72)
        w("  6. ACCUMULATOR DRIFT")
        w("─" * 72)
        w()
        for s in STREAMS:
            d = drift_stats.get(s, {})
            if not d:
                w(f"  Stream {s}: no data"); continue
            w(f"  Stream {s}:")
            w(f"    Final accum_out:     0x{d['final_acc']:08X}  ({d['final_acc']})")
            w(f"    Max accum_out:       0x{d['max_acc']:08X}")
            w(f"    Mean delta/cycle:    {d['mean_delta']:.2f}")
            w(f"    Growth/Decay/Flat:   {d['growth_cycles']}/{d['decay_cycles']}/{d['flat_cycles']}")
        w()

        # ── Final classification ───────────────────────────────────────────
        w("=" * 72)
        w("  HORUS v3 LIVE SYSTEM STATUS  (HBS-C2 CLASSIFICATION)")
        w("=" * 72)
        w()
        stable_pct = region_total.get("STABLE", 0) / N * 100 if N else 0
        trans_pct  = region_total.get("TRANSITION", 0) / N * 100 if N else 0
        coll_pct   = region_total.get("COLLAPSE", 0)  / N * 100 if N else 0
        sat_pct    = region_total.get("SATURATE", 0)  / N * 100 if N else 0

        w(f"  Stable band dominance:     {stable_pct:.1f}%")
        w(f"  Transition zone occupancy: {trans_pct:.1f}%")
        w(f"  Collapse zone occupancy:   {coll_pct:.1f}%")
        w(f"  Saturation zone occupancy: {sat_pct:.1f}%")
        w()
        if stable_pct > 60:
            w("  VERDICT: STABLE BAND IS DOMINANT (>60% occupancy)")
        elif stable_pct > 40:
            w("  VERDICT: STABLE BAND IS MAJORITY (40-60% occupancy)")
        else:
            w("  VERDICT: BOUNDARY ZONES DOMINANT — stable band is theoretical minority")
        w()
        if uf_stats["uf_total"] == 0:
            w("  COLLAPSE: ZERO UF EVENTS — collapse zone never reached at runtime")
        elif uf_stats["uf_total"] < N * 0.01:
            w("  COLLAPSE: RARE (< 1% of cycles) — boundary wall behavior confirmed")
        elif uf_stats["uf_total"] < N * 0.10:
            w("  COLLAPSE: MODERATE (1-10% of cycles) — boundary zone is active")
        else:
            w("  COLLAPSE: FREQUENT (> 10%) — collapse zone is structurally central")
        w()
        if uf_stats["ovf_total"] == 0:
            w("  SATURATION: ZERO OVF EVENTS — saturation cliff not reached")
        elif uf_stats["ovf_total"] < N * 0.01:
            w("  SATURATION: RARE (< 1%) — ceiling cliff behavior confirmed")
        else:
            w("  SATURATION: ACTIVE (> 1%) — saturation zone is structurally present")
        w()

        # Mode invariance conclusion
        any_mode_effect = False
        for reg in REGIONS:
            all_modes_for_reg = [mode_eff.get((reg, m), {}).get("uf_rate", 0)
                                 for m in ["STD","BIAS","PRSC","SAFE"]
                                 if mode_eff.get((reg, m), {}).get("total", 0) > 0]
            if len(all_modes_for_reg) > 1:
                if max(all_modes_for_reg) - min(all_modes_for_reg) > 0.001:
                    any_mode_effect = True
        if any_mode_effect:
            w("  MODE DISTRIBUTION: Varying UF rates observed across modes in some regions.")
            w("  NOTE: This is a distribution observation, NOT evidence of arithmetic modification.")
            w("  Likely explained by: different mode assignments by stream/region routing.")
        else:
            w("  MODE DISTRIBUTION: No meaningful UF rate variation across modes.")
            w("  CONFIRMED: mode_tag does not alter UF/OVF distribution in this dataset.")
        w()
        w("  (All figures derived from HBS_C2_LIVE_SIM.csv. No speculation.)")
        w("=" * 72)

# ─────────────────────────────────────────────────────────────────────────────
# 11. MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  HBS-C2 Live System Analysis")
    print("=" * 60)

    if not os.path.isfile(CSV_FILE):
        print(f"ERROR: {CSV_FILE} not found. Run simulation first.")
        sys.exit(1)

    print(f"  Loading {CSV_FILE}...")
    rows = load_csv(CSV_FILE)
    N    = len(rows)
    print(f"  {N} rows loaded.")

    # Compute all metrics
    region_total, region_per_str = region_occupancy(rows)
    e_hist, e_per_str            = e_histogram(rows)
    crossings, cross_per_str     = boundary_crossings(rows)
    uf_stats                     = uf_ovf_stats(rows)
    drift_stats, drift_raw       = accum_drift(rows)
    mode_eff                     = mode_effectiveness(rows)
    cliff                        = cliff_sharpness(e_hist)

    # ASCII state-space map
    ascii_lines = ascii_state_space_map(e_hist, N, e_per_str)
    with open(ASCII_MAP, "w") as f:
        f.write("\n".join(ascii_lines) + "\n")
    print(f"  ASCII map → {ASCII_MAP}")

    # Print ASCII map to console
    for line in ascii_lines:
        print(line)

    # Write summary log
    write_summary(LOG_FILE, rows, region_total, region_per_str,
                  e_hist, e_per_str, crossings, cross_per_str,
                  uf_stats, drift_stats, mode_eff, cliff)
    print(f"  Summary log → {LOG_FILE}")

    # Matplotlib plots
    plt = try_matplotlib()
    if plt is not None:
        print("  Generating plots...")
        plot_e_density(e_hist, N, plt)
        print("    hbs_c2_e_density.png")
        plot_uf_ovf_timeline(rows, plt)
        print("    hbs_c2_uf_ovf_timeline.png")
        plot_accum_drift(drift_raw, plt)
        print("    hbs_c2_accum_drift.png")
        plot_mode_region_heatmap(mode_eff, plt)
        print("    hbs_c2_mode_region_hm.png")
    else:
        print("  matplotlib not available — skipping plots (text outputs complete).")

    print()
    print("  HBS-C2 analysis complete.")
    print("=" * 60)

if __name__ == "__main__":
    main()
