#!/usr/bin/env python3
"""
sim/mlp_train.py — Train and quantize a 64→16→10 MLP on the sklearn digits
                   dataset, then export NFE-encoded weights and test images.

Dataset:  sklearn.datasets.load_digits (1797 samples, 8×8 grayscale, 10 classes).
          Pixel values 0–16; normalised to [0,1] by /16.
          sklearn was available in this environment and used directly (not a fallback).

Architecture (NFE block-tiling note):
  Input   64 = 8×8 — one 8-element group per spatial block of the digit image.
  Hidden  16 = 2×8 — tiles into 2 output blocks × 8 input blocks for Layer 1.
  Output  10 padded to 16 = 2×8 — tiles into 2 output blocks × 2 input blocks for Layer 2.
  Zero-padding: Layer 2 has rows 10–15 set to zero (dead outputs; documented).

Training:
  Split  : 80/20 train/test, random_state=42 (fixed seed throughout).
  Init   : Xavier uniform ±sqrt(6/(n_in+n_out)).
  Optim  : Adam (lr=0.003, β₁=0.9, β₂=0.999).
  Epochs : 300, mini-batch 32.

NFE quantization:
  NORM band: stored E ∈ [16..47]  (HBS-12A, nfe_matvec2.c lines 65-66).
  Power-of-2 per-layer scale factors chosen so every weight falls in NORM band.
  Scale is exact in NFE (adding k to every E field = multiply all values by 2^k).
  Expnorm between layers (E_TARGET=32) removes scale bias at inference time.

Output files (all in sim/):
  MLP_W1.hex          — W1 NFE codewords, 1024 lines (row-major W1[i][j], i=0..15,j=0..63)
  MLP_B1.hex          — b1 NFE codewords, 16 lines
  MLP_W2.hex          — W2 NFE codewords, 256 lines (padded, rows 10..15 are zeros)
  MLP_B2.hex          — b2 NFE codewords, 16 lines (entries 10..15 are zeros)
  MLP_TEST_IMAGES.hex — test images NFE-encoded, N_test×64 lines
  MLP_TEST_LABELS.dat — test labels, one integer per line
  MLP_FP64.npz        — numpy archive of FP64 weights + test data (for mlp_infer_nfe.py)

NFE helpers reused from sim/norm_interval_sweep.py lines 64-98 (nfe_dec, nfe_enc, nfe_mul).
"""

import math
import sys
import os
import csv
import numpy as np

# ── Dataset ───────────────────────────────────────────────────────────────────
try:
    from sklearn.datasets import load_digits
    from sklearn.model_selection import train_test_split
    SKLEARN = True
    print("Dataset path: sklearn.datasets.load_digits (installed, used directly)")
except ImportError:
    SKLEARN = False
    print("ERROR: sklearn not available.")
    sys.exit(1)

# ── NFE constants ─────────────────────────────────────────────────────────────
EXP_BIAS    = 32
EXP_MAX     = 63
E_NORM_LO   = 16   # HBS-12A log line 79; nfe_matvec2.c line 65
E_NORM_HI   = 47   # HBS-12A log line 80; nfe_matvec2.c line 66
E_TARGET    = 32   # mid-anchor; nfe_matvec2.c lines 67-68

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

def check_norm_band(w):
    """Return True if the NFE codeword is in NORM band [E_NORM_LO..E_NORM_HI]."""
    return E_NORM_LO <= w.e <= E_NORM_HI

# ── MLP helpers ───────────────────────────────────────────────────────────────
def xavier_uniform(n_in, n_out, rng):
    lim = math.sqrt(6.0 / (n_in + n_out))
    return rng.uniform(-lim, lim, (n_out, n_in))

def relu(x):     return np.maximum(0.0, x)
def relu_grad(x): return (x > 0).astype(float)

def softmax(x):
    e = np.exp(x - x.max(axis=1, keepdims=True))
    return e / e.sum(axis=1, keepdims=True)

def forward(W1, b1, W2, b2, X):
    h1_pre = X @ W1.T + b1          # (n, 16)
    h1     = relu(h1_pre)            # (n, 16)
    out    = h1 @ W2.T + b2          # (n, 10)
    return h1_pre, h1, out

def cross_entropy_loss(out, y):
    p = softmax(out)
    n = len(y)
    return -np.log(p[np.arange(n), y] + 1e-12).mean()

def accuracy(out, y):
    return (np.argmax(out, axis=1) == y).mean()

# Adam optimizer state
class Adam:
    def __init__(self, lr=0.003, b1=0.9, b2=0.999, eps=1e-8):
        self.lr, self.b1, self.b2, self.eps = lr, b1, b2, eps
        self.t = 0; self.m = {}; self.v = {}
    def update(self, name, param, grad):
        self.t += 1
        if name not in self.m:
            self.m[name] = np.zeros_like(grad)
            self.v[name] = np.zeros_like(grad)
        self.m[name] = self.b1 * self.m[name] + (1 - self.b1) * grad
        self.v[name] = self.b2 * self.v[name] + (1 - self.b2) * grad * grad
        mh = self.m[name] / (1 - self.b1 ** self.t)
        vh = self.v[name] / (1 - self.b2 ** self.t)
        return param - self.lr * mh / (np.sqrt(vh) + self.eps)

# ── Data ──────────────────────────────────────────────────────────────────────
def load_data():
    digits = load_digits()
    X = digits.data.astype(float) / 16.0   # normalise [0, 1]
    y = digits.target
    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=0.20, random_state=42, stratify=y)
    return X_tr, X_te, y_tr, y_te

# ── Training ─────────────────────────────────────────────────────────────────
def train(X_tr, y_tr, X_te, y_te, seed=42, epochs=300, batch=32, lr=0.003):
    rng = np.random.default_rng(seed)
    n_in, n_hid, n_out = 64, 16, 10

    W1 = xavier_uniform(n_in,  n_hid, rng)    # (16, 64)
    b1 = np.zeros(n_hid)
    W2 = xavier_uniform(n_hid, n_out, rng)    # (10, 16)
    b2 = np.zeros(n_out)

    opt = Adam(lr=lr)
    n_tr = len(y_tr)

    for ep in range(1, epochs + 1):
        idx = rng.permutation(n_tr)
        for start in range(0, n_tr, batch):
            bi = idx[start:start + batch]
            Xb, yb = X_tr[bi], y_tr[bi]

            # Forward
            h1_pre, h1, out = forward(W1, b1, W2, b2, Xb)
            n = len(yb)

            # Backward (cross-entropy + softmax joint gradient)
            d_out = softmax(out)
            d_out[np.arange(n), yb] -= 1
            d_out /= n

            dW2 = d_out.T @ h1         # (10, 16)
            db2 = d_out.sum(axis=0)
            d_h1 = d_out @ W2          # (n, 16)
            d_h1_pre = d_h1 * relu_grad(h1_pre)
            dW1 = d_h1_pre.T @ Xb      # (16, 64)
            db1 = d_h1_pre.sum(axis=0)

            W1 = opt.update('W1', W1, dW1)
            b1 = opt.update('b1', b1, db1)
            W2 = opt.update('W2', W2, dW2)
            b2 = opt.update('b2', b2, db2)

        if ep % 50 == 0 or ep == 1:
            _, _, out_tr = forward(W1, b1, W2, b2, X_tr)
            _, _, out_te = forward(W1, b1, W2, b2, X_te)
            print(f"  ep={ep:3d}  train_acc={accuracy(out_tr,y_tr):.4f}"
                  f"  test_acc={accuracy(out_te,y_te):.4f}"
                  f"  loss={cross_entropy_loss(out_te,y_te):.4f}")

    return W1, b1, W2, b2

# ── NFE quantization ──────────────────────────────────────────────────────────
def quantize_weights(W1, b1, W2, b2, scale_W1=1.0, scale_W2=1.0):
    """
    Quantize all weights and biases to NFE.  scale_Lk is a power-of-2 factor
    applied before encoding; scale 1.0 = no adjustment.

    Returns NFE-codeword arrays and the decoded (rounded) FP64 equivalents.
    Biases are treated as individual NFE values without per-layer scaling
    (biases are already in a reasonable range after training).
    """
    def enc_matrix(M, scale):
        rows, cols = M.shape
        nfe_M  = [[None]*cols for _ in range(rows)]
        fp_M   = np.zeros_like(M)
        for i in range(rows):
            for j in range(cols):
                w = nfe_enc(M[i][j] * scale)
                nfe_M[i][j] = w
                fp_M[i][j]  = nfe_dec(w) / scale
        return nfe_M, fp_M

    def enc_vector(v, scale=1.0):
        nfe_v = [None]*len(v); fp_v = np.zeros(len(v))
        for i, x in enumerate(v):
            w = nfe_enc(x * scale)
            nfe_v[i] = w; fp_v[i] = nfe_dec(w) / scale
        return nfe_v, fp_v

    # Scale biases by the same layer factor so the relationship
    # z = W_scaled · x + b_scaled = scale * (W_true · x + b_true) holds.
    # Expnorm removes the overall scale at inference time.
    nfe_W1, fp_W1 = enc_matrix(W1, scale_W1)
    nfe_b1, fp_b1 = enc_vector(b1, scale_W1)
    nfe_W2, fp_W2 = enc_matrix(W2, scale_W2)
    nfe_b2, fp_b2 = enc_vector(b2, scale_W2)

    # Pad W2 to 16×16 (rows 10..15 = zeros), pad b2 to 16 entries
    pad_row = [NFE(0,0,0)] * 16
    nfe_W2_pad = nfe_W2 + [list(pad_row) for _ in range(6)]
    fp_W2_pad  = np.vstack([fp_W2, np.zeros((6, 16))])
    nfe_b2_pad = nfe_b2 + [NFE(0,0,0)] * 6
    fp_b2_pad  = np.append(fp_b2, np.zeros(6))

    return (nfe_W1, fp_W1, nfe_b1, fp_b1,
            nfe_W2_pad, fp_W2_pad, nfe_b2_pad, fp_b2_pad)

def report_band(name, nfe_M_flat, scale_exp=0):
    in_norm = sum(1 for w in nfe_M_flat if check_norm_band(w))
    below   = sum(1 for w in nfe_M_flat if w.e < E_NORM_LO and w.e > 0)
    floor   = sum(1 for w in nfe_M_flat if w.e == 0)
    above   = sum(1 for w in nfe_M_flat if w.e > E_NORM_HI)
    total   = len(nfe_M_flat)
    e_vals  = [w.e for w in nfe_M_flat if w.e > 0]
    e_min   = min(e_vals) if e_vals else 0
    e_max   = max(e_vals) if e_vals else 0
    print(f"  {name}: {in_norm}/{total} in NORM[{E_NORM_LO}..{E_NORM_HI}]"
          f"  below={below}  floor={floor}  above={above}"
          f"  E_min={e_min}  E_max={e_max}"
          f"  scale=2^{scale_exp}")

# ── Hex file writers ──────────────────────────────────────────────────────────
def write_hex(path, nfe_list):
    """Write one NFE codeword per line as 4 hex digits (13-bit in 16-bit field)."""
    with open(path, 'w') as f:
        for w in nfe_list:
            f.write(f"{w.codeword():04x}\n")

def write_labels_dat(path, labels):
    with open(path, 'w') as f:
        for lbl in labels:
            f.write(f"{int(lbl)}\n")

# ── Choose power-of-2 scale ───────────────────────────────────────────────────
def choose_scale(flat_weights):
    """Return (scale_factor, log2_scale) so all weights land in NORM band.
    Prefer k=0 (no scaling); search 0, 1, -1, 2, -2, ... so biases stay
    consistent and encoding error is minimised.
    """
    def all_in_band(k):
        scale = 2.0 ** k
        for w in flat_weights:
            ws = abs(w) * scale
            if ws == 0.0: continue
            eS = math.floor(math.log2(ws)) + EXP_BIAS
            if eS < E_NORM_LO or eS > E_NORM_HI:
                return False
        return True

    for delta in range(9):
        for k in ([0] if delta == 0 else [delta, -delta]):
            if all_in_band(k):
                return 2.0 ** k, k
    return 1.0, 0

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))

    print("=" * 64)
    print("sim/mlp_train.py")
    print("=" * 64)

    # Load data
    X_tr, X_te, y_tr, y_te = load_data()
    print(f"  train: {X_tr.shape[0]}  test: {X_te.shape[0]}  classes: 10")

    # Train
    print("Training 64→16→10 MLP (Adam lr=0.003, 300 epochs) ...")
    W1, b1, W2, b2 = train(X_tr, y_tr, X_te, y_te)
    _, _, out_te = forward(W1, b1, W2, b2, X_te)
    fp64_acc = accuracy(out_te, y_te)
    print(f"\nFP64 test accuracy: {fp64_acc*100:.2f}%  ({int(fp64_acc*len(y_te))}/{len(y_te)})")

    # Choose power-of-2 scales so all weights land in NORM band
    scale_W1, k_W1 = choose_scale(W1.flatten())
    scale_W2, k_W2 = choose_scale(W2.flatten())
    print(f"\nPer-layer scale factors (power-of-2):")
    print(f"  Layer 1: 2^{k_W1} = {scale_W1}")
    print(f"  Layer 2: 2^{k_W2} = {scale_W2}")
    print("  (Expnorm between layers removes scale effect at inference.)")

    # Quantize
    (nfe_W1, fp_W1, nfe_b1, fp_b1,
     nfe_W2, fp_W2, nfe_b2, fp_b2) = quantize_weights(
        W1, b1, W2, b2, scale_W1, scale_W2)

    # Report band membership
    print("\nNFE exponent distribution:")
    flat_W1 = [nfe_W1[i][j] for i in range(16) for j in range(64)]
    flat_b1 = nfe_b1
    flat_W2 = [nfe_W2[i][j] for i in range(16) for j in range(16)]
    flat_b2 = nfe_b2
    report_band("W1 (16×64)", flat_W1, k_W1)
    report_band("b1 (16)   ", flat_b1, k_W1)
    report_band("W2 (16×16)", flat_W2, k_W2)
    report_band("b2 (16)   ", flat_b2, k_W2)

    # Save weight hex files
    w1_path = os.path.join(out_dir, "MLP_W1.hex")
    b1_path = os.path.join(out_dir, "MLP_B1.hex")
    w2_path = os.path.join(out_dir, "MLP_W2.hex")
    b2_path = os.path.join(out_dir, "MLP_B2.hex")

    flat_W1_out = [nfe_W1[i][j]  for i in range(16) for j in range(64)]
    flat_W2_out = [nfe_W2[i][j]  for i in range(16) for j in range(16)]
    write_hex(w1_path, flat_W1_out)
    write_hex(b1_path, nfe_b1)
    write_hex(w2_path, flat_W2_out)
    write_hex(b2_path, nfe_b2)
    print(f"\nWeight files written:")
    print(f"  {w1_path}  ({len(flat_W1_out)} entries)")
    print(f"  {b1_path}  ({len(nfe_b1)} entries)")
    print(f"  {w2_path}  ({len(flat_W2_out)} entries)")
    print(f"  {b2_path}  ({len(nfe_b2)} entries)")

    # Save test images and labels
    imgs_path = os.path.join(out_dir, "MLP_TEST_IMAGES.hex")
    lbls_path = os.path.join(out_dir, "MLP_TEST_LABELS.dat")
    n_test = len(y_te)
    img_nfe_flat = []
    for img in range(n_test):
        for px in range(64):
            img_nfe_flat.append(nfe_enc(float(X_te[img, px])))
    write_hex(imgs_path, img_nfe_flat)
    write_labels_dat(lbls_path, y_te)
    print(f"  {imgs_path}  ({n_test}×64 = {len(img_nfe_flat)} entries)")
    print(f"  {lbls_path}  ({n_test} labels)")

    # Save FP64 data for mlp_infer_nfe.py
    npz_path = os.path.join(out_dir, "MLP_FP64.npz")
    np.savez(npz_path,
             W1=W1, b1=b1, W2=W2, b2=b2,
             fp_W1=fp_W1, fp_b1=fp_b1,
             fp_W2=fp_W2[:10, :], fp_b2=fp_b2[:10],
             X_te=X_te, y_te=y_te,
             scale_W1=np.array([scale_W1]), scale_W2=np.array([scale_W2]),
             k_W1=np.array([k_W1]), k_W2=np.array([k_W2]),
             fp_W2_pad=fp_W2, fp_b2_pad=fp_b2)
    print(f"  {npz_path}  (FP64 weights + test data)")
    print(f"\nFP64 test accuracy: {fp64_acc*100:.2f}%")
    print("Done.")

if __name__ == '__main__':
    main()
