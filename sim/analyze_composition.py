#!/usr/bin/env python3
"""
analyze_composition.py — TEST 10 multi-operation composition classification

Reads composition_analysis.csv and determines whether deterministic residual
structure persists under chained operations.

Usage:
    make composition_analysis
    # or:
    python3 analyze_composition.py [csv_path]
"""

from __future__ import annotations

import csv
import math
import sys
from collections import defaultdict
from pathlib import Path

CSV_DEFAULT = Path("composition_analysis.csv")


def parse_hex(val: str) -> int:
    val = val.strip()
    if val.startswith("0x") or val.startswith("0X"):
        return int(val, 16)
    return int(val)


def parse_row(row: dict) -> dict:
    y_hex = row["y_hex"].strip()
    y = int(y_hex, 16) if y_hex.startswith("0x") else int(y_hex)
    residual = parse_hex(row["residual"])
    pe_acc = parse_hex(row["pe_acc"])
    depth = int(row["chain_depth"])
    perm = int(row["perm_order"])
    return {
        "test": row["test"],
        "subtest": row["subtest"],
        "cycle": int(row["cycle"]),
        "y": y,
        "perm_order": perm,
        "chain_depth": depth,
        "residual": residual,
        "residual_abs": abs(residual),
        "pe_acc": pe_acc,
        "e_y": int(row["e_y"]),
        "f_y": int(row["f_y"]),
        "sat_floor": int(row["sat_floor"]),
        "sat_max": int(row["sat_max"]),
        "uf": int(row["uf"]),
        "ovf": int(row["ovf"]),
    }


def load_csv(path: Path) -> list[dict]:
    rows = []
    with path.open(newline="") as fh:
        for row in csv.DictReader(fh):
            rows.append(parse_row(row))
    return rows


def mean(vals: list[float]) -> float:
    return sum(vals) / len(vals) if vals else 0.0


def variance(vals: list[float]) -> float:
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return sum((v - m) ** 2 for v in vals) / (len(vals) - 1)


def pearson(xs: list[float], ys: list[float]) -> float:
    n = len(xs)
    if n < 2:
        return 0.0
    mx, my = mean(xs), mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den_x = math.sqrt(sum((x - mx) ** 2 for x in xs))
    den_y = math.sqrt(sum((y - my) ** 2 for y in ys))
    if den_x == 0 or den_y == 0:
        return 0.0
    return num / (den_x * den_y)


def bucket_stats(rows: list[dict]) -> dict:
    buckets: dict[tuple[int, int], list[int]] = defaultdict(list)
    for r in rows:
        buckets[(r["e_y"], r["f_y"])].append(r["residual"])

    bucket_mean = {k: mean(v) for k, v in buckets.items()}
    errors = []
    for r in rows:
        pred = bucket_mean[(r["e_y"], r["f_y"])]
        errors.append(abs(r["residual"] - pred))

    pred_err = mean(errors) if errors else 0.0
    raw_mean = mean([float(r["residual_abs"]) for r in rows]) if rows else 0.0
    improvement = 1.0 - (pred_err / raw_mean) if raw_mean > 0 else 0.0
    return {
        "bucket_count": len(buckets),
        "mean_prediction_error": pred_err,
        "mean_abs_residual": raw_mean,
        "prediction_improvement_ratio": improvement,
        "corr_e": abs(pearson([float(r["e_y"]) for r in rows], [float(r["residual"]) for r in rows])),
        "corr_f": abs(pearson([float(r["f_y"]) for r in rows], [float(r["residual"]) for r in rows])),
        "corr_y": abs(pearson([float(r["y"]) for r in rows], [float(r["residual_abs"]) for r in rows])),
    }


def analyze_10a(rows: list[dict]) -> dict:
    sub = [r for r in rows if r["test"] == "10A"]
    by_y: dict[int, list[int]] = defaultdict(list)
    for r in sub:
        by_y[r["y"]].append(r["residual"])

    per_y = {}
    all_std = []
    for y, resids in sorted(by_y.items()):
        v = variance(resids)
        s = math.sqrt(v)
        all_std.append(s)
        per_y[y] = {"mean": mean(resids), "std": s, "n": len(resids)}

    pe_accs = [r["pe_acc"] for r in sub]
    pe_drift = pe_accs[-1] - pe_accs[0] if len(pe_accs) >= 2 else 0

    return {
        "per_y": per_y,
        "max_std": max(all_std) if all_std else 0.0,
        "mean_std": mean(all_std) if all_std else 0.0,
        "pe_acc_start": pe_accs[0] if pe_accs else 0,
        "pe_acc_end": pe_accs[-1] if pe_accs else 0,
        "pe_drift": pe_drift,
        "n": len(sub),
        "bucket": bucket_stats(sub),
    }


def analyze_10b(rows: list[dict]) -> dict:
    sub = [r for r in rows if r["test"] == "10B"]
    by_perm: dict[int, list[int]] = defaultdict(list)
    for r in sub:
        by_perm[r["perm_order"]].append(r["residual"])

    perm_means = {p: mean(v) for p, v in sorted(by_perm.items())}
    perm_vars = {p: variance(v) for p, v in sorted(by_perm.items())}
    means = list(perm_means.values())
    perm_spread = max(means) - min(means) if means else 0.0
    ordering_sensitive = perm_spread > max(100.0, 0.05 * max(abs(m) for m in means) if means else 1)

    return {
        "perm_means": perm_means,
        "perm_vars": perm_vars,
        "perm_spread": perm_spread,
        "ordering_sensitive": ordering_sensitive,
        "bucket": bucket_stats(sub),
    }


def analyze_10c(rows: list[dict]) -> dict:
    sub = [r for r in rows if r["test"] == "10C"]
    resids = [r["residual"] for r in sub]
    sat_floor_total = sum(r["sat_floor"] for r in sub)
    sat_max_total = sum(r["sat_max"] for r in sub)
    uf_total = sum(r["uf"] for r in sub)
    ov_total = sum(r["ovf"] for r in sub)

    # Bounded vs drift: check if |residual| stays within shallow-chain range
    shallow_ref = mean([abs(r["residual"]) for r in rows if r["test"] == "10A"]) if rows else 1
    deep_mean_abs = mean([float(r["residual_abs"]) for r in sub]) if sub else 0
    exponential_like = deep_mean_abs > 10 * shallow_ref

    return {
        "mean_abs_residual": deep_mean_abs,
        "max_abs_residual": max((r["residual_abs"] for r in sub), default=0),
        "sat_floor_total": sat_floor_total,
        "sat_max_total": sat_max_total,
        "uf_total": uf_total,
        "ov_total": ov_total,
        "exponential_like": exponential_like,
        "bucket": bucket_stats(sub),
        "n": len(sub),
    }


def analyze_10d(rows: list[dict]) -> dict:
    sub = [r for r in rows if r["test"] == "10D"]
    shallow = [r for r in sub if r["chain_depth"] <= 4]
    deep = [r for r in sub if r["chain_depth"] > 4]

    shallow_b = bucket_stats(shallow)
    deep_b = bucket_stats(deep)
    full_b = bucket_stats(sub)

    return {
        "shallow": shallow_b,
        "deep": deep_b,
        "full": full_b,
        "n_shallow": len(shallow),
        "n_deep": len(deep),
    }


def classify(a10a: dict, a10b: dict, a10c: dict, a10d: dict) -> tuple[str, str, str | None]:
    shallow_stable = a10a["max_std"] < 1.0 and a10a["bucket"]["prediction_improvement_ratio"] > 0.5
    deep_stable = a10c["bucket"]["prediction_improvement_ratio"] > 0.5 and a10c["max_abs_residual"] < 1e6
    model_persists = a10d["full"]["prediction_improvement_ratio"] > 0.5

    breakdown_depth = None
    if shallow_stable and not deep_stable:
        breakdown_depth = "4 < depth <= 30"
    elif not shallow_stable:
        breakdown_depth = "depth <= 4"

    if shallow_stable and deep_stable and model_persists and not a10b["ordering_sensitive"]:
        cat = "A"
        action = "exploit — composition-stable bias model; extend Test 9 tables to chain outputs"
    elif shallow_stable and (not deep_stable or a10b["ordering_sensitive"]):
        cat = "B"
        action = "constrain depth — learnable model holds for shallow chains (depth<=4); cap or special-case deep composition"
    else:
        cat = "C"
        action = "suppress composition — residual geometry breaks under chaining; avoid deep unguarded operator fusion"

    return cat, action, breakdown_depth


def main() -> int:
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else CSV_DEFAULT
    if not csv_path.exists():
        print(f"ERROR: {csv_path} not found. Run: make composition_analysis")
        return 1

    rows = load_csv(csv_path)
    a10a = analyze_10a(rows)
    a10b = analyze_10b(rows)
    a10c = analyze_10c(rows)
    a10d = analyze_10d(rows)
    cat, action, breakdown = classify(a10a, a10b, a10c, a10d)

    model_persists = a10d["full"]["prediction_improvement_ratio"] > 0.5 and a10a["max_std"] < 10.0

    print("=" * 62)
    print("  TEST 10 SUMMARY — Composition Residual Stability")
    print("=" * 62)

    print("\n--- 10A: Short chain stability (200 cycles, depth=4) ---")
    print(f"  Max std across y buckets:     {a10a['max_std']:.4f}")
    print(f"  Mean std:                     {a10a['mean_std']:.4f}")
    print(f"  pe_acc drift (cycle 0→199):   {a10a['pe_drift']}")
    print(f"  Bucket prediction error:      {a10a['bucket']['mean_prediction_error']:.4f}")
    print(f"  |corr(E, residual)|:          {a10a['bucket']['corr_e']:.4f}")

    print("\n--- 10B: Order perturbation (200 cycles, 3 permutations) ---")
    for p, m in sorted(a10b["perm_means"].items()):
        print(f"  perm={p}  mean_residual={m:.1f}  var={a10b['perm_vars'][p]:.1f}")
    print(f"  Permutation spread:           {a10b['perm_spread']:.1f}")
    print(f"  Ordering sensitive:           {a10b['ordering_sensitive']}")

    print("\n--- 10C: Deep chain (100 cycles, depth=30) ---")
    print(f"  Mean |residual|:              {a10c['mean_abs_residual']:.1f}")
    print(f"  Max |residual|:               {a10c['max_abs_residual']}")
    print(f"  Floor saturation events:      {a10c['sat_floor_total']}")
    print(f"  Max saturation events:        {a10c['sat_max_total']}")
    print(f"  UF flags:                     {a10c['uf_total']}")
    print(f"  Exponential drift signature:  {a10c['exponential_like']}")
    print(f"  Bucket prediction error:      {a10c['bucket']['mean_prediction_error']:.4f}")
    print(f"  Prediction improvement:       {a10c['bucket']['prediction_improvement_ratio']:.2%}")

    print("\n--- 10D: Model breakpoint (1000 mixed compositions) ---")
    print(f"  Shallow (n={a10d['n_shallow']}): pred_err={a10d['shallow']['mean_prediction_error']:.4f}  |r|_E={a10d['shallow']['corr_e']:.4f}")
    print(f"  Deep    (n={a10d['n_deep']}): pred_err={a10d['deep']['mean_prediction_error']:.4f}  |r|_E={a10d['deep']['corr_e']:.4f}")
    print(f"  Full mix: pred_err={a10d['full']['mean_prediction_error']:.4f}  improve={a10d['full']['prediction_improvement_ratio']:.2%}")

    print("\n" + "=" * 62)
    print("TEST 10 SUMMARY")
    print("=" * 62)
    residual_stable = a10a["max_std"] < 1.0 and a10c["bucket"]["prediction_improvement_ratio"] > 0.3
    print(f"Residual stability:     {'deterministic at shallow depth' if a10a['max_std'] < 1.0 else 'variance detected in shallow chains'}")
    print(f"Composition sensitivity: {'YES' if a10b['ordering_sensitive'] else 'NO'} (perm spread={a10b['perm_spread']:.1f})")
    drift = "bounded" if not a10c["exponential_like"] else "exponential/unbounded"
    if a10c["sat_floor_total"] > 0:
        drift += f"; floor collapse {a10c['sat_floor_total']} inner-iter events"
    print(f"Drift behavior:         {drift}")
    print(f"Model persistence (Yes/No): {'Yes' if model_persists else 'No'}")
    print(f"Breakdown depth (if any): {breakdown if breakdown else 'none observed'}")
    print(f"Classification (A/B/C): {cat}")
    print(f"Recommended action: {action}")
    print("=" * 62)

    out = Path("TEST_10_SUMMARY.log")
    with out.open("w") as fh:
        fh.write("TEST 10 SUMMARY\n")
        fh.write(f"Residual stability: {residual_stable}\n")
        fh.write(f"Composition sensitivity: {a10b['ordering_sensitive']} spread={a10b['perm_spread']:.1f}\n")
        fh.write(f"Drift behavior: {drift}\n")
        fh.write(f"Model persistence: {model_persists}\n")
        fh.write(f"Breakdown depth: {breakdown}\n")
        fh.write(f"Classification (A/B/C): {cat}\n")
        fh.write(f"Recommended action: {action}\n")
    print(f"\nWrote {out.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
