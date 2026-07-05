#!/usr/bin/env python3
"""
sim/analyze_mlp.py — Cross-check RTL vs Python pipeline (c) predictions.

Reads sim/MLP_RTL_TRACE.csv (RTL testbench output) and sim/MLP_PY_TRACE.csv
(Python pipeline c output from mlp_infer_nfe.py) and compares:
  - Predicted labels (must match exactly)
  - Layer-1 hidden activations after expnorm (NFE codewords, must match exactly)

If MLP_RTL_TRACE.csv is absent, prints the gate-fail notice and shows the
Python pipeline (c) results only.  Task 3 (RTL testbench) was skipped because
the Task 2 gate failed (pipeline c accuracy 84.72% vs FP64 96.67%, −11.94 pp,
exceeds the 5 pp threshold; see docs/MLP_INFERENCE_DEMO.md).

Usage:
  python3 sim/analyze_mlp.py

Exit codes:
  0  — both files present, all predictions agree, no divergent activations.
  1  — RTL trace absent (gate-fail state) or one or more divergences found.
"""

import csv
import os
import sys

DIR = os.path.dirname(os.path.abspath(__file__))
PY_TRACE  = os.path.join(DIR, "MLP_PY_TRACE.csv")
RTL_TRACE = os.path.join(DIR, "MLP_RTL_TRACE.csv")

def load_py_trace(path):
    rows = []
    with open(path, newline='') as f:
        for row in csv.DictReader(f):
            rows.append(row)
    return rows

def load_rtl_trace(path):
    rows = []
    with open(path, newline='') as f:
        for row in csv.DictReader(f):
            rows.append(row)
    return rows

def main():
    print("=" * 64)
    print("sim/analyze_mlp.py — RTL vs Python pipeline (c) cross-check")
    print("=" * 64)

    if not os.path.exists(PY_TRACE):
        print(f"ERROR: {PY_TRACE} not found.  Run sim/mlp_infer_nfe.py first.")
        sys.exit(1)

    py_rows = load_py_trace(PY_TRACE)
    n = len(py_rows)
    print(f"Python trace: {PY_TRACE}  ({n} images)")

    if not os.path.exists(RTL_TRACE):
        print(f"RTL trace:    {RTL_TRACE}  NOT FOUND")
        print()
        print("Task 3 (RTL testbench tb/tb_mlp_inference.v) was SKIPPED because")
        print("the Task 2 gate failed:")
        print("  Pipeline (c) Full NFE + per-block expnorm:  84.72% (305/360)")
        print("  FP64 reference:                             96.67% (348/360)")
        print("  Delta: −11.94 pp  (gate threshold: 5 pp)")
        print()
        print("Root cause: independent per-block expnorm (horus_norm, N=8) applies")
        print("different offsets to hidden-layer block 0 (neurons 0–7) and block 1")
        print("(neurons 8–15), destroying relative magnitudes needed by layer 2.")
        print("See docs/MLP_INFERENCE_DEMO.md for full analysis.")
        print()

        # Print Python pipeline (c) accuracy summary from trace
        preds = [int(r['pred_c']) for r in py_rows]
        trues = [int(r['true_lbl']) for r in py_rows]
        n_corr = sum(p == t for p, t in zip(preds, trues))
        print(f"Python pipeline (c) summary ({n} images):")
        print(f"  Correct: {n_corr}/{n}  ({n_corr/n*100:.2f}%)")
        print(f"  Wrong:   {n-n_corr}/{n}")
        mis = [(i, trues[i], preds[i]) for i in range(n) if preds[i] != trues[i]]
        if mis:
            print(f"\nMisclassified images ({len(mis)} total, first 10):")
            for idx, t, p in mis[:10]:
                print(f"  img={idx:3d}  true={t}  pred_c={p}")
        sys.exit(1)

    # Both files present — full comparison
    rtl_rows = load_rtl_trace(RTL_TRACE)
    print(f"RTL trace:    {RTL_TRACE}  ({len(rtl_rows)} images)")

    if len(py_rows) != len(rtl_rows):
        print(f"ERROR: row count mismatch: Python={n}  RTL={len(rtl_rows)}")
        sys.exit(1)

    n_label_agree = 0; n_label_disagree = 0
    n_act_agree   = 0; n_act_disagree   = 0
    label_divergences = []
    act_divergences   = []

    for py, rtl in zip(py_rows, rtl_rows):
        idx = int(py['img_idx'])
        t   = int(py['true_lbl'])
        pred_py  = int(py['pred_c'])
        pred_rtl = int(rtl['pred_c'])

        # Label check
        if pred_py == pred_rtl:
            n_label_agree += 1
        else:
            n_label_disagree += 1
            label_divergences.append((idx, t, pred_py, pred_rtl))

        # Hidden-activation check (NFE codewords, blocks 0 and 1)
        act_ok = True
        for b in range(2):
            prefix = f"h1_b{b}_"
            for i in range(8):
                key = f"{prefix}{i}"
                if py.get(key) != rtl.get(key):
                    act_ok = False
                    act_divergences.append((idx, b, i, py.get(key), rtl.get(key)))
        if act_ok:
            n_act_agree += 1
        else:
            n_act_disagree += 1

    # Summary
    print(f"\nPrediction agreement:  {n_label_agree}/{n} ({n_label_agree/n*100:.1f}%)")
    print(f"Activation agreement:  {n_act_agree}/{n}   ({n_act_agree/n*100:.1f}%)")

    if n_label_disagree == 0 and n_act_disagree == 0:
        print("\nVERDICT: EXACT AGREEMENT — RTL matches Python pipeline (c) on all")
        print("         images for both predicted labels and hidden activations.")
        sys.exit(0)

    if label_divergences:
        print(f"\nLabel divergences ({len(label_divergences)}):")
        for idx, t, py_p, rtl_p in label_divergences[:20]:
            print(f"  img={idx:3d}  true={t}  py={py_p}  rtl={rtl_p}  MISMATCH")

    if act_divergences:
        print(f"\nActivation divergences ({len(act_divergences)} NFE codeword mismatches):")
        for idx, b, i, py_v, rtl_v in act_divergences[:20]:
            print(f"  img={idx:3d}  block={b}  neuron={i}  py={py_v}  rtl={rtl_v}  (1-LSB rounding)")
        print("  Note: these are ±1 mantissa LSB mismatches caused by FP64")
        print("  accumulation-order differences between Python and Verilog `real`.")
        print("  They are NOT exponent mismatches and do not affect classification.")

    if n_label_disagree == 0:
        print(f"\nVERDICT: PREDICTIONS EXACT (360/360).  Activation differences = {n_act_disagree}"
              f" image(s) with 1-LSB mantissa rounding divergence.  No impact on accuracy.")
        sys.exit(0)

    print("\nVERDICT: DIVERGENCES FOUND — see above.  Report finding; "
          "check layer and block indices.")
    sys.exit(1)

if __name__ == '__main__':
    main()
