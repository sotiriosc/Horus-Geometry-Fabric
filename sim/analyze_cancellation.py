#!/usr/bin/env python3
"""
analyze_cancellation.py — TEST 9 cancellation residual classification

Reads cancel_analysis.csv from tb_horus_cancel_analysis.v and determines
whether residuals are structured signal (A), partial structure (B), or noise (C).

Usage:
    make cancel_analysis
    # or:
    python3 analyze_cancellation.py [csv_path]
"""

from __future__ import annotations

import csv
import math
import sys
from collections import defaultdict
from pathlib import Path

CSV_DEFAULT = Path("cancel_analysis.csv")


def parse_row(row: dict) -> dict:
    y_hex = row["y_hex"].strip()
    y = int(y_hex, 16) if y_hex.startswith("0x") else int(y_hex)
    residual = int(row["residual"], 16) if row["residual"].startswith("0x") else int(row["residual"])
    order = int(row["order"])
    e_y = int(row["e_y"])
    f_y = int(row["f_y"])
    return {
        "test": row["test"],
        "subtest": row["subtest"],
        "cycle": int(row["cycle"]),
        "y": y,
        "order": order,
        "residual": residual,
        "residual_abs": abs(residual),
        "e_y": e_y,
        "f_y": f_y,
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


def analyze_9a(rows: list[dict]) -> dict:
    by_y: dict[int, list[int]] = defaultdict(list)
    for r in rows:
        if r["test"] == "9A":
            by_y[r["y"]].append(r["residual"])

    stats = {}
    all_var = []
    for y, resids in sorted(by_y.items()):
        m = mean(resids)
        v = variance(resids)
        all_var.append(v)
        stats[y] = {"mean": m, "variance": v, "n": len(resids), "std": math.sqrt(v)}

    max_std = max((s["std"] for s in stats.values()), default=0)
    mean_var = mean(all_var) if all_var else 0
    return {"per_y": stats, "max_std": max_std, "mean_variance": mean_var}


def analyze_9b(rows: list[dict]) -> dict:
    sub = [r for r in rows if r["test"] == "9B"]
    order0 = [r["residual"] for r in sub if r["order"] == 0]
    order1 = [r["residual"] for r in sub if r["order"] == 1]
    m0, m1 = mean(order0), mean(order1)
    v0, v1 = variance(order0), variance(order1)
    order_shift = abs(m0 - m1)
    pooled_var = mean([v0, v1])
    return {
        "mean_order0": m0,
        "mean_order1": m1,
        "var_order0": v0,
        "var_order1": v1,
        "order_mean_shift": order_shift,
        "ordering_sensitive": order_shift > max(1.0, 0.05 * max(abs(m0), abs(m1), 1)),
    }


def analyze_9c(rows: list[dict]) -> dict:
    sub = [r for r in rows if r["test"] == "9C"]
    y_mag = [float(r["y"]) for r in sub]
    res_abs = [float(r["residual_abs"]) for r in sub]
    e_vals = [float(r["e_y"]) for r in sub]
    f_vals = [float(r["f_y"]) for r in sub]
    res_signed = [float(r["residual"]) for r in sub]

    corr_y = abs(pearson(y_mag, res_abs))
    corr_e = abs(pearson(e_vals, res_signed))
    corr_f = abs(pearson(f_vals, res_signed))
    return {
        "corr_y_magnitude": corr_y,
        "corr_exponent": corr_e,
        "corr_fraction": corr_f,
        "max_corr": max(corr_y, corr_e, corr_f),
        "n": len(sub),
    }


def analyze_9d(rows: list[dict]) -> dict:
    """Bucket prediction: predict residual from (e_y, f_y) mean per bucket."""
    sub = [r for r in rows if r["test"] == "9C"]
    buckets: dict[tuple[int, int], list[int]] = defaultdict(list)
    for r in sub:
        buckets[(r["e_y"], r["f_y"])].append(r["residual"])

    bucket_mean = {k: mean(v) for k, v in buckets.items()}
    errors = []
    for r in sub:
        pred = bucket_mean[(r["e_y"], r["f_y"])]
        errors.append(abs(r["residual"] - pred))

    pred_err = mean(errors) if errors else 0.0
    raw_mean = mean([abs(r["residual"]) for r in sub]) if sub else 0.0
    improvement = 1.0 - (pred_err / raw_mean) if raw_mean > 0 else 0.0
    return {
        "bucket_count": len(buckets),
        "mean_prediction_error": pred_err,
        "mean_abs_residual": raw_mean,
        "prediction_improvement_ratio": improvement,
    }


def classify(a9a: dict, a9b: dict, a9c: dict, a9d: dict) -> tuple[str, str]:
    score_structured = 0
    score_partial = 0

    # Low variance per fixed y → structured bias
    if a9a["max_std"] < 1.0:
        score_structured += 2
    elif a9a["max_std"] < 100:
        score_partial += 1
    else:
        score_partial += 0

    # Order sensitivity
    if not a9b["ordering_sensitive"]:
        score_structured += 1
    else:
        score_partial += 1

    # Correlation strength
    if a9c["max_corr"] > 0.7:
        score_structured += 2
    elif a9c["max_corr"] > 0.3:
        score_partial += 2
    elif a9c["max_corr"] > 0.1:
        score_partial += 1

    # Bucket predictability
    if a9d["prediction_improvement_ratio"] > 0.5 and a9d["bucket_count"] > 5:
        score_structured += 2
    elif a9d["prediction_improvement_ratio"] > 0.2:
        score_partial += 1

    if score_structured >= 4:
        cat = "A"
        action = "exploit — learnable per-(e,f) or per-y bias correction in compiler/QAT"
    elif score_structured + score_partial >= 3:
        cat = "B"
        action = "suppress partially — domain-specific correction tables; monitor operand bands"
    else:
        cat = "C"
        action = "ignore as irreducible noise — do not assume float cancellation in pe_accum"

    return cat, action


def main() -> int:
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else CSV_DEFAULT
    if not csv_path.exists():
        print(f"ERROR: {csv_path} not found. Run: make cancel_analysis")
        return 1

    rows = load_csv(csv_path)
    a9a = analyze_9a(rows)
    a9b = analyze_9b(rows)
    a9c = analyze_9c(rows)
    a9d = analyze_9d(rows)
    cat, action = classify(a9a, a9b, a9c, a9d)

    print("=" * 62)
    print("  TEST 9 SUMMARY — Cancellation Residual Structure")
    print("=" * 62)

    print("\n--- 9A: Fixed-pair repeatability (5 y × 50 repeats) ---")
    for y, s in sorted(a9a["per_y"].items()):
        print(f"  y=0x{y:04X}  mean={s['mean']:.1f}  std={s['std']:.4f}  var={s['variance']:.4f}")
    print(f"  Max std across y: {a9a['max_std']:.4f}")
    print(f"  Mean variance:    {a9a['mean_variance']:.4f}")

    print("\n--- 9B: Ordering sensitivity (y=0x600, 100 pairs) ---")
    print(f"  Mean residual order0 (y then -y): {a9b['mean_order0']:.1f}")
    print(f"  Mean residual order1 (-y then y): {a9b['mean_order1']:.1f}")
    print(f"  Order mean shift:                 {a9b['order_mean_shift']:.1f}")
    print(f"  Ordering sensitive:               {a9b['ordering_sensitive']}")

    print("\n--- 9C: Correlation (1000 random-y pairs) ---")
    print(f"  |corr(y magnitude, |residual|)|: {a9c['corr_y_magnitude']:.4f}")
    print(f"  |corr(stored_E, residual)|:      {a9c['corr_exponent']:.4f}")
    print(f"  |corr(fraction, residual)|:        {a9c['corr_fraction']:.4f}")
    print(f"  Max correlation:                 {a9c['max_corr']:.4f}")

    print("\n--- 9D: Bucket predictability (e,f → mean residual) ---")
    print(f"  Unique (e,f) buckets:     {a9d['bucket_count']}")
    print(f"  Mean |residual|:          {a9d['mean_abs_residual']:.1f}")
    print(f"  Mean prediction error:    {a9d['mean_prediction_error']:.4f}")
    print(f"  Prediction improvement:   {a9d['prediction_improvement_ratio']:.2%}")

    print("\n" + "=" * 62)
    print("TEST 9 SUMMARY")
    print("=" * 62)
    converged = a9a["max_std"] < 1.0
    print(f"Residual behavior:   {'deterministic per-y bias' if converged else 'non-zero structured offset in codeword sum'}")
    print(f"Variance:            max_std={a9a['max_std']:.4f}, mean_var={a9a['mean_variance']:.4f}")
    print(f"Correlation strength: max |r|={a9c['max_corr']:.4f}")
    print(f"Ordering sensitivity: {'YES' if a9b['ordering_sensitive'] else 'NO'} (shift={a9b['order_mean_shift']:.1f})")
    print(f"Classification (A/B/C): {cat}")
    print(f"Recommended action: {action}")
    print("=" * 62)

    out = Path("TEST_09_SUMMARY.log")
    with out.open("w") as fh:
        fh.write("TEST 9 SUMMARY\n")
        fh.write(f"Residual behavior: deterministic={'yes' if converged else 'partial'} codeword-sum offset\n")
        fh.write(f"Variance: max_std={a9a['max_std']:.6f} mean_var={a9a['mean_variance']:.6f}\n")
        fh.write(f"Correlation strength: {a9c['max_corr']:.6f}\n")
        fh.write(f"Ordering sensitivity: {a9b['ordering_sensitive']} shift={a9b['order_mean_shift']:.1f}\n")
        fh.write(f"Classification (A/B/C): {cat}\n")
        fh.write(f"Recommended action: {action}\n")
    print(f"\nWrote {out.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
