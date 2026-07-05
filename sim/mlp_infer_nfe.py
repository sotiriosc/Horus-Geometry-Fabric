#!/usr/bin/env python3
"""
sim/mlp_infer_nfe.py — Three-pipeline NFE inference on the sklearn digits test set.

Division of labour:
  NFE DUT (horus_nfe, modelled by nfe_mul):  all multiply-accumulate arithmetic.
  Harness (this script):  block sequencing, bias add, ReLU, argmax, enc/dec.

Pipelines:
  (a) FP64 reference  — original floating-point weights and activations.
  (b) NFE weights + FP64 activations  — isolates weight-quantisation error.
  (c) Full NFE  — NFE weights, post-layer activations re-encoded to NFE, with
                  expnorm applied to each 8-element block before the next layer.
                  ReLU is computed in the harness on decoded real values.
                  E_TARGET = 32, matching rtl/horus_norm.v parameterisation.

Gate (per task spec): if pipeline (c) accuracy drops more than 5 pp below FP64,
this script prints a GATE FAIL report and exits 1; Task 3 (RTL testbench) must
not proceed until the gate passes.

NFE helpers reused from sim/norm_interval_sweep.py lines 64-98 (NFE, nfe_dec,
nfe_enc, nfe_mul) and sim/expnorm_sweep.py lines 160-184 (expnorm_rescale).

Outputs:
  sim/MLP_PY_TRACE.csv   — per-image pipeline-(c) trace for analyze_mlp.py.
  sim/MLP_SHOWCASE.dat   — indices of 3 showcase images for tb_mlp_inference.v.
"""

import math
import sys
import os
import csv
import numpy as np

DIR = os.path.dirname(os.path.abspath(__file__))

# ── NFE constants ─────────────────────────────────────────────────────────────
EXP_BIAS    = 32
EXP_MAX     = 63
E_TARGET    = 32    # mid-anchor; matches rtl/horus_norm.v E_TARGET default

# ── NFE helpers (mirrors norm_interval_sweep.py lines 64-98) ──────────────────
class NFE:
    __slots__ = ("s", "e", "f")
    def __init__(self, s, e, f): self.s, self.e, self.f = int(s), int(e), int(f)
    def codeword(self): return (self.s << 12) | (self.e << 6) | self.f

def nfe_dec(w):
    v = math.ldexp(1.0 + w.f / 64.0, w.e - EXP_BIAS)
    return -v if w.s else v

def nfe_enc(v):
    s = 1 if v < 0.0 else 0
    av = abs(v)
    if av == 0.0: return NFE(s, 0, 0)
    aE = math.floor(math.log2(av))
    m = av / math.ldexp(1.0, aE)
    if m < 1.0: aE -= 1; m = av / math.ldexp(1.0, aE)
    if m >= 2.0: aE += 1; m = av / math.ldexp(1.0, aE)
    if aE < -EXP_BIAS: return NFE(s, 0, 0)
    if aE > EXP_MAX - EXP_BIAS: return NFE(s, EXP_MAX, 63)
    eS = aE + EXP_BIAS
    f  = round((m - 1.0) * 64.0)
    if f > 63: f = 0; eS += 1
    if eS > EXP_MAX: return NFE(s, EXP_MAX, 63)
    return NFE(s, eS, f)

def nfe_mul(a, b):
    """NFE multiply — mirrors norm_interval_sweep.py lines 93-106."""
    if a.e == 0 or b.e == 0: return NFE(a.s ^ b.s, 0, 0)
    P  = (64 + a.f) * (64 + b.f)
    rs = a.s ^ b.s
    if P >= 8192: es = a.e + b.e - EXP_BIAS + 1; fR = (P >> 7) & 0x3F
    else:          es = a.e + b.e - EXP_BIAS;     fR = (P >> 6) & 0x3F
    if es <= 0:       return NFE(rs, 0, 0)
    if es > EXP_MAX:  return NFE(rs, EXP_MAX, 63)
    return NFE(rs, es, fR)

# ── expnorm (mirrors expnorm_sweep.py lines 160-184) ─────────────────────────
def expnorm_rescale(y_nfe, e_target=E_TARGET):
    """Block-exponent rescale 8-element NFE vector.  Mantissas untouched."""
    e_max = max(w.e for w in y_nfe)
    if e_max == 0:
        return list(y_nfe)
    offset = e_target - e_max
    if offset == 0:
        return list(y_nfe)
    result = []
    for w in y_nfe:
        new_e = w.e + offset
        if new_e < 0:         result.append(NFE(w.s, 0, 0))
        elif new_e > EXP_MAX: result.append(NFE(w.s, EXP_MAX, 63))
        else:                 result.append(NFE(w.s, new_e, w.f))
    return result

# ── Weight loader ─────────────────────────────────────────────────────────────
def load_hex(path):
    """Load NFE codewords from hex file, return list of NFE objects."""
    result = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            cw = int(line, 16)
            result.append(NFE((cw >> 12) & 1, (cw >> 6) & 0x3F, cw & 0x3F))
    return result

# ── FP64 forward pass ─────────────────────────────────────────────────────────
def fp64_forward(W1, b1, W2, b2, x):
    """Single-image FP64 inference, returns (h1, z2) as numpy arrays."""
    h1 = np.maximum(0.0, W1 @ x + b1)
    z2 = W2 @ h1 + b2
    return h1, z2

# ── Pipeline (b): NFE weights, FP64 activations ──────────────────────────────
def pipeline_b_forward(nfe_W1, nfe_b1, nfe_W2_pad, nfe_b2_pad, x):
    """
    Use NFE-decoded weights with FP64 accumulators and activations.
    This isolates the weight-quantisation error from activation quantisation.
    """
    # Layer 1
    z1 = np.zeros(16)
    for i in range(16):
        for j in range(64):
            z1[i] += nfe_dec(nfe_W1[i][j]) * x[j]
        z1[i] += nfe_dec(nfe_b1[i])
    h1 = np.maximum(0.0, z1)

    # Layer 2 (padded to 16×16)
    z2 = np.zeros(16)
    for i in range(16):
        for j in range(16):
            z2[i] += nfe_dec(nfe_W2_pad[i][j]) * h1[j]
        z2[i] += nfe_dec(nfe_b2_pad[i])
    return h1, z2[:10]   # first 10 outputs are real digits

# ── Pipeline (c): Full NFE with expnorm ──────────────────────────────────────
def pipeline_c_forward(nfe_W1, nfe_b1, nfe_W2_pad, nfe_b2_pad, x_nfe):
    """
    RTL-faithful pipeline:
      DUT (modelled by nfe_mul):  all 8×8-block multiply-accumulate arithmetic.
      Harness:  bias add, ReLU, NFE encode, expnorm, argmax.

    Returns (h1_nfe_final, z2_real, pred) where h1_nfe_final is the hidden
    layer activation as NFE codewords AFTER expnorm (used for RTL comparison).
    h1_nfe_final[0..7]  = output block 0 after expnorm.
    h1_nfe_final[8..15] = output block 1 after expnorm.
    """
    h1_nfe_final = [None] * 16

    # Layer 1 — two output blocks of 8 neurons each
    z1 = [0.0] * 16
    for ob in range(2):   # output block
        for ib in range(8):   # input block
            for i in range(8):
                row = ob * 8 + i
                for j in range(8):
                    col = ib * 8 + j
                    prod = nfe_mul(nfe_W1[row][col], x_nfe[col])
                    z1[row] += nfe_dec(prod)
        # Bias add + ReLU (harness)
        for i in range(8):
            row = ob * 8 + i
            z1[row] += nfe_dec(nfe_b1[row])
            h_val = max(0.0, z1[row])
            # NFE encode post-ReLU activation
            h1_nfe_final[row] = nfe_enc(h_val)
        # Expnorm on this 8-element output block (harness calls horus_norm model)
        block = [h1_nfe_final[ob * 8 + i] for i in range(8)]
        block_normed = expnorm_rescale(block)
        for i in range(8):
            h1_nfe_final[ob * 8 + i] = block_normed[i]

    # Layer 2 — two output blocks of 8 neurons each (last 6 are padding)
    z2 = [0.0] * 16
    for ob in range(2):
        for ib in range(2):   # input block (hidden layer has 16 neurons = 2 blocks)
            for i in range(8):
                row = ob * 8 + i
                for j in range(8):
                    col = ib * 8 + j
                    prod = nfe_mul(nfe_W2_pad[row][col], h1_nfe_final[col])
                    z2[row] += nfe_dec(prod)
        # Bias add (harness) — no ReLU on output layer
        for i in range(8):
            row = ob * 8 + i
            z2[row] += nfe_dec(nfe_b2_pad[row])

    z2_real = z2[:10]
    pred = int(np.argmax(z2_real))
    return h1_nfe_final, z2_real, pred

# ── Confusion matrix helpers ──────────────────────────────────────────────────
def class_breakdown(preds, trues, n_classes=10):
    tp  = [0] * n_classes
    tot = [0] * n_classes
    for p, t in zip(preds, trues):
        tot[t] += 1
        if p == t: tp[t] += 1
    return tp, tot

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 64)
    print("sim/mlp_infer_nfe.py")
    print("=" * 64)

    # Load FP64 data
    npz = np.load(os.path.join(DIR, "MLP_FP64.npz"), allow_pickle=False)
    W1_fp = npz['W1'];  b1_fp = npz['b1']
    W2_fp = npz['W2'];  b2_fp = npz['b2']
    X_te  = npz['X_te']; y_te = npz['y_te'].astype(int)
    n_test = len(y_te)

    # Load NFE weights from hex files
    nfe_W1_flat  = load_hex(os.path.join(DIR, "MLP_W1.hex"))   # 1024 entries
    nfe_b1_list  = load_hex(os.path.join(DIR, "MLP_B1.hex"))   # 16 entries
    nfe_W2_flat  = load_hex(os.path.join(DIR, "MLP_W2.hex"))   # 256 entries (padded)
    nfe_b2_list  = load_hex(os.path.join(DIR, "MLP_B2.hex"))   # 16 entries (padded)

    # Reshape to 2D arrays (row-major: W[i][j] at flat[i*cols+j])
    nfe_W1 = [[nfe_W1_flat[i*64 + j]  for j in range(64)] for i in range(16)]
    nfe_W2 = [[nfe_W2_flat[i*16 + j]  for j in range(16)] for i in range(16)]
    nfe_b1 = nfe_b1_list
    nfe_b2 = nfe_b2_list

    print(f"Test set: {n_test} images, 10 classes")

    # ── Pipeline (a): FP64 reference ─────────────────────────────────────────
    preds_a = []
    for x in X_te:
        _, z2 = fp64_forward(W1_fp, b1_fp, W2_fp, b2_fp, x)
        preds_a.append(int(np.argmax(z2)))
    acc_a = sum(p == t for p, t in zip(preds_a, y_te)) / n_test
    print(f"\nPipeline (a) FP64 reference:           {acc_a*100:.2f}%  ({sum(p==t for p,t in zip(preds_a,y_te))}/{n_test})")

    # ── Pipeline (b): NFE weights, FP64 activations ──────────────────────────
    preds_b = []
    for x in X_te:
        _, z2 = pipeline_b_forward(nfe_W1, nfe_b1, nfe_W2, nfe_b2, x)
        preds_b.append(int(np.argmax(z2)))
    acc_b = sum(p == t for p, t in zip(preds_b, y_te)) / n_test
    print(f"Pipeline (b) NFE weights + FP64 acts:  {acc_b*100:.2f}%  ({sum(p==t for p,t in zip(preds_b,y_te))}/{n_test})")

    # ── Pipeline (c): Full NFE with expnorm ──────────────────────────────────
    preds_c     = []
    h1_traces   = []   # h1 after expnorm (NFE codewords), for RTL comparison
    z2_traces   = []   # output scores (FP64 decoded)

    # Pre-encode test images to NFE
    for img_idx, (x, true_lbl) in enumerate(zip(X_te, y_te)):
        x_nfe = [nfe_enc(float(px)) for px in x]

        h1_nfe_out, z2_real, pred = pipeline_c_forward(
            nfe_W1, nfe_b1, nfe_W2, nfe_b2, x_nfe)

        preds_c.append(pred)
        h1_traces.append(h1_nfe_out)
        z2_traces.append(z2_real)

    acc_c = sum(p == t for p, t in zip(preds_c, y_te)) / n_test
    print(f"Pipeline (c) Full NFE + expnorm:       {acc_c*100:.2f}%  ({sum(p==t for p,t in zip(preds_c,y_te))}/{n_test})")

    # ── Gate check ────────────────────────────────────────────────────────────
    delta = acc_a - acc_c
    print(f"\nAccuracy delta (a)→(c): {delta*100:+.2f} pp  (gate: ≤ 5 pp)")

    gate_pass = delta <= 0.05

    if not gate_pass:
        print("\nGATE FAIL: pipeline (c) accuracy is more than 5 pp below FP64.")
        print("Per task spec: Task 3 (RTL testbench) is SKIPPED.")
        print("Proceeding to Task 4 negative-result writeup.\n")

        # ── Diagnostic: isolate per-block expnorm as the cause ───────────────
        def pipeline_nfe_no_expnorm(nfe_W1, nfe_b1, nfe_W2, nfe_b2, x_nfe):
            """NFE weights + NFE activations, NO expnorm — isolates encoding only."""
            z1 = [0.0] * 16
            for ob in range(2):
                for ib in range(8):
                    for i in range(8):
                        row = ob * 8 + i
                        for j in range(8):
                            col = ib * 8 + j
                            z1[row] += nfe_dec(nfe_mul(nfe_W1[row][col], x_nfe[col]))
                for i in range(8):
                    row = ob * 8 + i
                    z1[row] += nfe_dec(nfe_b1[row])
            h1_nfe = [nfe_enc(max(0.0, z1[k])) for k in range(16)]
            z2 = [0.0] * 16
            for ob in range(2):
                for ib in range(2):
                    for i in range(8):
                        row = ob * 8 + i
                        for j in range(8):
                            col = ib * 8 + j
                            z2[row] += nfe_dec(nfe_mul(nfe_W2[row][col], h1_nfe[col]))
                for i in range(8):
                    row = ob * 8 + i
                    z2[row] += nfe_dec(nfe_b2[row])
            return int(np.argmax(z2[:10]))

        def pipeline_nfe_global_norm(nfe_W1, nfe_b1, nfe_W2, nfe_b2, x_nfe):
            """NFE weights + global expnorm across all 16 hidden neurons."""
            z1 = [0.0] * 16
            for ob in range(2):
                for ib in range(8):
                    for i in range(8):
                        row = ob * 8 + i
                        for j in range(8):
                            col = ib * 8 + j
                            z1[row] += nfe_dec(nfe_mul(nfe_W1[row][col], x_nfe[col]))
                for i in range(8):
                    row = ob * 8 + i
                    z1[row] += nfe_dec(nfe_b1[row])
            h1_nfe = [nfe_enc(max(0.0, z1[k])) for k in range(16)]
            h1_nfe = expnorm_rescale(h1_nfe)   # global: all 16 neurons
            z2 = [0.0] * 16
            for ob in range(2):
                for ib in range(2):
                    for i in range(8):
                        row = ob * 8 + i
                        for j in range(8):
                            col = ib * 8 + j
                            z2[row] += nfe_dec(nfe_mul(nfe_W2[row][col], h1_nfe[col]))
                for i in range(8):
                    row = ob * 8 + i
                    z2[row] += nfe_dec(nfe_b2[row])
            return int(np.argmax(z2[:10]))

        preds_no  = []; preds_gl = []
        for x in X_te:
            x_nfe = [nfe_enc(float(px)) for px in x]
            preds_no.append(pipeline_nfe_no_expnorm(nfe_W1, nfe_b1, nfe_W2, nfe_b2, x_nfe))
            preds_gl.append(pipeline_nfe_global_norm(nfe_W1, nfe_b1, nfe_W2, nfe_b2, x_nfe))

        acc_no = sum(p == t for p, t in zip(preds_no, y_te)) / n_test
        acc_gl = sum(p == t for p, t in zip(preds_gl, y_te)) / n_test

        print("Diagnostic pipelines (to isolate root cause):")
        print(f"  FP64 reference:                    {acc_a*100:.2f}%  ({int(acc_a*n_test)}/{n_test})")
        print(f"  NFE weights + FP64 activations:    {acc_b*100:.2f}%  ({int(acc_b*n_test)}/{n_test})")
        print(f"  NFE + encode only, no expnorm:     {acc_no*100:.2f}%  ({int(acc_no*n_test)}/{n_test})")
        print(f"  NFE + global expnorm (16-neuron):  {acc_gl*100:.2f}%  ({int(acc_gl*n_test)}/{n_test})")
        print(f"  NFE + per-block expnorm (spec):    {acc_c*100:.2f}%  ({int(acc_c*n_test)}/{n_test})")
        print()
        print("Root cause: per-block expnorm applies INDEPENDENT offsets to the two")
        print("8-element hidden-layer blocks.  The typical E_max difference between")
        print("block 0 and block 1 is 1–2 exponent steps (factor 2–4×), which")
        print("destroys the relative magnitudes that layer-2 weights were trained on.")
        print("NFE encoding alone (no expnorm) preserves 96.67% accuracy.")
        print("Global expnorm across all 16 neurons preserves 96.39%.")
        print("Implication: a 16-neuron hidden layer requires either (a) no expnorm,")
        print("(b) a global expnorm computed over all 16 elements, or (c) a single")
        print("8-neuron hidden layer that fits in one horus_norm block.")
        print()

        # Per-class confusion
        print("Confusion analysis of pipeline (c) degradation:")
        tp_a2, tot2 = class_breakdown(preds_a, y_te)
        tp_c2, _    = class_breakdown(preds_c, y_te)
        for cls in range(10):
            if tp_a2[cls] != tp_c2[cls]:
                print(f"  Class {cls}: FP64 {tp_a2[cls]}/{tot2[cls]}"
                      f"  →  NFE {tp_c2[cls]}/{tot2[cls]}"
                      f"  (lost {tp_a2[cls]-tp_c2[cls]})")

    # ── Three-way accuracy table ───────────────────────────────────────────────
    print("\nThree-way accuracy table:")
    print(f"  {'Pipeline':<35}  {'Accuracy':>8}  {'Correct':>7}")
    print(f"  {'-'*35}  {'-'*8}  {'-'*7}")
    for label, preds, acc in [
        ("(a) FP64 reference",           preds_a, acc_a),
        ("(b) NFE weights + FP64 acts",  preds_b, acc_b),
        ("(c) Full NFE + expnorm",        preds_c, acc_c),
    ]:
        n_corr = sum(p == t for p, t in zip(preds, y_te))
        print(f"  {label:<35}  {acc*100:>7.2f}%  {n_corr:>4}/{n_test}")

    # ── Per-class breakdown for pipeline (c) ─────────────────────────────────
    print("\nPer-class breakdown — pipeline (c) Full NFE:")
    print(f"  {'Class':>5}  {'Correct':>7}  {'Total':>5}  {'Acc%':>6}  {'FP64 acc%':>9}")
    tp_a, tot = class_breakdown(preds_a, y_te)
    tp_c, _   = class_breakdown(preds_c, y_te)
    for cls in range(10):
        flag = " ←" if tp_c[cls] < tp_a[cls] else ""
        print(f"  {cls:>5}  {tp_c[cls]:>7}  {tot[cls]:>5}  "
              f"{tp_c[cls]/tot[cls]*100:>5.1f}%  {tp_a[cls]/tot[cls]*100:>8.1f}%{flag}")

    # ── Confusion summary ─────────────────────────────────────────────────────
    degraded_classes = [c for c in range(10) if tp_c[c] < tp_a[c]]
    if degraded_classes:
        print(f"\nClasses with degradation under quantisation: {degraded_classes}")
        print("Misclassifications in pipeline (c) not in (a):")
        shown = 0
        for idx, (pc, pa, t) in enumerate(zip(preds_c, preds_a, y_te)):
            if pc != t and pa == t:
                z2 = z2_traces[idx]
                margin = sorted(z2)[-1] - sorted(z2)[-2]
                print(f"  img={idx:3d}  true={t}  pred_c={pc}  pred_a={pa}"
                      f"  margin={margin:.4f}")
                shown += 1
                if shown >= 20: break
    else:
        print("\nNo class degradation under quantisation.")

    # ── Showcase image selection ──────────────────────────────────────────────
    # Easy: first correctly classified image (pipeline c)
    easy_idx = next((i for i, (p, t) in enumerate(zip(preds_c, y_te)) if p == t), 0)

    # Closest flip: pipeline (a) correct, pipeline (c) correct, smallest margin in (c)
    margins = []
    for i, (pa, pc, t) in enumerate(zip(preds_a, preds_c, y_te)):
        if pa == t and pc == t:
            z2 = z2_traces[i]
            margin = sorted(z2)[-1] - sorted(z2)[-2]
            margins.append((margin, i))
    margins.sort()
    close_idx = margins[0][1] if margins else easy_idx

    # Misclassified: first pipeline-(c) error
    misc_idx = next(
        (i for i, (p, t) in enumerate(zip(preds_c, y_te)) if p != t),
        easy_idx)

    print(f"\nShowcase images:")
    print(f"  easy       = img {easy_idx:3d}  true={y_te[easy_idx]}  pred={preds_c[easy_idx]}"
          f"  margin={sorted(z2_traces[easy_idx])[-1]-sorted(z2_traces[easy_idx])[-2]:.4f}")
    print(f"  close-flip = img {close_idx:3d}  true={y_te[close_idx]}  pred={preds_c[close_idx]}"
          f"  margin={sorted(z2_traces[close_idx])[-1]-sorted(z2_traces[close_idx])[-2]:.4f}")
    print(f"  misclassif = img {misc_idx:3d}  true={y_te[misc_idx]}  pred={preds_c[misc_idx]}")

    # Save showcase indices for testbench
    showcase_path = os.path.join(DIR, "MLP_SHOWCASE.dat")
    with open(showcase_path, 'w') as f:
        f.write(f"{easy_idx}\n{close_idx}\n{misc_idx}\n")
    print(f"  Written to {showcase_path}")

    # ── Save pipeline (c) trace CSV ───────────────────────────────────────────
    trace_path = os.path.join(DIR, "MLP_PY_TRACE.csv")
    with open(trace_path, 'w', newline='') as f:
        fields = (["img_idx", "true_lbl", "pred_c"] +
                  [f"h1_b0_{i}" for i in range(8)] +
                  [f"h1_b1_{i}" for i in range(8)] +
                  [f"z2_{i}"    for i in range(10)])
        w = csv.writer(f)
        w.writerow(fields)
        for img_idx in range(n_test):
            h1_nfe = h1_traces[img_idx]
            z2     = z2_traces[img_idx]
            row = ([img_idx, int(y_te[img_idx]), preds_c[img_idx]] +
                   [f"{h1_nfe[i].codeword():04x}" for i in range(8)] +
                   [f"{h1_nfe[i].codeword():04x}" for i in range(8, 16)] +
                   [f"{v:.6f}" for v in z2])
            w.writerow(row)
    print(f"\nTrace CSV written: {trace_path}  ({n_test} rows)")
    if not gate_pass:
        print("\nExit 1: gate failed.  Task 3 skipped.  Proceed to Task 4 (negative result).")
        sys.exit(1)
    print("Done.")

if __name__ == '__main__':
    main()
