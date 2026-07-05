#!/usr/bin/env python3
"""
sim/hopfield_demo.py — Hopfield associative-memory recall demo.

Network: 64 neurons, states ±1.
Weights: Hebbian rule  W = Σ_k p_k p_k^T / N,  zero diagonal.
Patterns: three 8×8 binary letter glyphs (H, T, X), stored as NFE-encoded
          weight codewords.
Update rule: s ← sign(W·s), synchronous, run to convergence or 32 iterations.
Matvec: 64×64 computed as 8×8 grid of 8×8 block sub-matvecs (same tiling as
        tb_hopfield_recall.v) via baseline PATH_NFE model.

Weight NFE encoding:
  Weight magnitudes: {1/64, 3/64}.
  nfe_enc(1/64)  = NFE(s, E=26, f=0)  — stored_E 26 ∈ NORM band [16..47]
  nfe_enc(3/64)  = NFE(s, E=27, f=32) — stored_E 27 ∈ NORM band [16..47]
  E_NORM_LO=16, E_NORM_HI=47 from sim/nfe_matvec2.c lines 65-66.
  Both values sit BELOW the ANCHOR zone (E ∈ [28..35], nfe_matvec2.c lines 67-68);
  the full NFE MUL guard applies (PATH_NFE, not PATH_FAST).
  All weight × state products are exactly representable in NFE (products are
  ±1/64 or ±3/64, which encode without mantissa rounding); the block-matvec
  row sums carry no quantisation error in FP64 accumulation.

NFE functions reused from sim/norm_interval_sweep.py:
  lfsr_step — lines 56-58
  lfsr_frac — lines 60-61
  nfe_dec   — lines 68-70
  nfe_enc   — lines 72-87
  nfe_mul   — lines 91-98
"""

import math
import csv
import sys
import os

# ── Constants ─────────────────────────────────────────────────────────────────
N_NEURONS   = 64        # total neurons
NB          = 8         # block size for tiled matvec
K_PATTERNS  = 3         # stored patterns
EXP_BIAS    = 32
EXP_MAX     = 63
MAX_ITERS   = 32        # convergence cutoff
N_TRIALS    = 20        # corruption seeds per (pattern, level)
FLIP_LEVELS = [8, 13]   # bits corrupted per level
N_SPURIOUS  = 8         # random initial states to probe for spurious attractors

# Seeds — must match tb_hopfield_recall.v localparams exactly
CORRUPT_SEED_BASE  = 0xBEEFCAFE
SPURIOUS_SEED_BASE = 0x5A5AA5A5

# ── LFSR (mirrors norm_interval_sweep.py lines 56-61) ─────────────────────────
def lfsr_step(s):
    bit = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1
    return ((s << 1) & 0xFFFFFFFF) | bit

def lfsr_frac(s):
    return ((s >> 8) & 0xFFFFFF) / 16777216.0

# ── NFE helpers (reused from norm_interval_sweep.py lines 64-98) ──────────────
class NFE:
    __slots__ = ("s", "e", "f")
    def __init__(self, s, e, f): self.s, self.e, self.f = s, e, f
    def __eq__(self, o): return self.s == o.s and self.e == o.e and self.f == o.f
    def codeword(self): return (self.s << 12) | (self.e << 6) | self.f

def nfe_dec(w):
    v = math.ldexp(1.0 + w.f / 64.0, w.e - EXP_BIAS)
    return -v if w.s else v

def nfe_enc(v):
    """mirrors norm_interval_sweep.py nfe_enc, lines 72-87."""
    s = 1 if v < 0.0 else 0
    av = abs(v)
    if av == 0.0: return NFE(s, 0, 0)
    aE = math.floor(math.log2(av))
    m  = av / math.ldexp(1.0, aE)
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
    """mirrors norm_interval_sweep.py nfe_mul, lines 91-98."""
    P = (64 + a.f) * (64 + b.f)
    rs = a.s ^ b.s
    if P >= 8192: es = a.e + b.e - EXP_BIAS + 1; fR = (P >> 7) & 0x3F
    else:          es = a.e + b.e - EXP_BIAS;     fR = (P >> 6) & 0x3F
    if es < 0:       return NFE(rs, 0, 0)
    if es > EXP_MAX: return NFE(rs, EXP_MAX, 63)
    return NFE(rs, es, fR)

# ── Patterns: 8×8 binary letter glyphs (1 = '#', -1 = '.') ───────────────────
# Stored row-major (PATTERNS[k][row*8+col]).
# Packed bit representation: 1 bit per pixel, MSB = row 0 col 0.
#   PATT_H = 0x8181_81FF_8181_8181
#   PATT_T = 0xFF10_1010_1010_1010
#   PATT_X = 0x8142_2418_1824_4281
# These localparams must match tb_hopfield_recall.v exactly.

PATTERN_H_2D = [
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
    [ 1, 1, 1, 1, 1, 1, 1, 1],  # ########  ← crossbar row 3
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
]

PATTERN_T_2D = [
    [ 1, 1, 1, 1, 1, 1, 1, 1],  # ########  ← top bar row 0
    [-1,-1,-1, 1,-1,-1,-1,-1],  # ...#....
    [-1,-1,-1, 1,-1,-1,-1,-1],  # ...#....
    [-1,-1,-1, 1,-1,-1,-1,-1],  # ...#....
    [-1,-1,-1, 1,-1,-1,-1,-1],  # ...#....
    [-1,-1,-1, 1,-1,-1,-1,-1],  # ...#....
    [-1,-1,-1, 1,-1,-1,-1,-1],  # ...#....
    [-1,-1,-1, 1,-1,-1,-1,-1],  # ...#....
]

PATTERN_X_2D = [
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
    [-1, 1,-1,-1,-1,-1, 1,-1],  # .#....#.
    [-1,-1, 1,-1,-1, 1,-1,-1],  # ..#..#..
    [-1,-1,-1, 1, 1,-1,-1,-1],  # ...##...
    [-1,-1,-1, 1, 1,-1,-1,-1],  # ...##...
    [-1,-1, 1,-1,-1, 1,-1,-1],  # ..#..#..
    [-1, 1,-1,-1,-1,-1, 1,-1],  # .#....#.
    [ 1,-1,-1,-1,-1,-1,-1, 1],  # #......#
]

PATTERN_NAMES = ['H', 'T', 'X']
PATTERNS_2D   = [PATTERN_H_2D, PATTERN_T_2D, PATTERN_X_2D]

def _flatten(p2d):
    return [v for row in p2d for v in row]

PATTERNS = [_flatten(p) for p in PATTERNS_2D]  # each: 64-element ±1 list


def render_state(s, width=8):
    """Return list of 8 ASCII rows for state s (64-element ±1 list)."""
    rows = []
    for r in range(width):
        rows.append(''.join('#' if s[r*width+c] > 0 else '.' for c in range(width)))
    return rows


# ── Weight matrix ──────────────────────────────────────────────────────────────
def build_weights():
    """Hebbian W = Σ_k p_k p_k^T / N, zero diagonal (i=j term excluded).
    Returns (W_real, W_nfe) each indexed as [i*N_NEURONS + j]."""
    N = N_NEURONS
    W_real = [0.0] * (N * N)
    for p in PATTERNS:
        for i in range(N):
            for j in range(N):
                if i != j:
                    W_real[i*N+j] += p[i] * p[j] / N
    W_nfe = [nfe_enc(v) for v in W_real]
    return W_real, W_nfe


def check_weight_encoding(W_real, W_nfe):
    mags = sorted(set(round(abs(v), 10) for v in W_real if abs(v) > 1e-15))
    exps = sorted(set(w.e for w in W_nfe if w.e > 0))
    print(f"  Nonzero weight magnitudes: {mags}")
    print(f"  NFE stored exponents:      {exps}")
    in_norm = all(16 <= w.e <= 47 for w in W_nfe if w.e > 0)
    print(f"  All in NORM band [16..47]: {in_norm}  "
          f"(E_NORM_LO/HI from nfe_matvec2.c lines 65-66)")


# ── Block matvec (PATH_NFE baseline, 8×8 tiling) ──────────────────────────────
def hopfield_matvec(W_nfe, s_nfe):
    """64×64 NFE matvec as 8×8 grid of 8×8 block sub-matvecs (PATH_NFE).
    Loop order: row-block → col-block → row-within-block → col-within-block.
    This ordering matches tb_hopfield_recall.v DUT sequencing exactly.
    Returns z: list of 64 float row sums (not re-encoded to NFE).
    """
    N = N_NEURONS
    z = [0.0] * N
    for rb in range(NB):       # row block (output side)
        for cb in range(NB):   # col block (input side)
            for ri in range(NB):
                psum = 0.0
                for ci in range(NB):
                    i = rb * NB + ri
                    j = cb * NB + ci
                    psum += nfe_dec(nfe_mul(W_nfe[i*N + j], s_nfe[j]))
                z[rb * NB + ri] += psum
    return z


def step_hopfield(W_nfe, s_nfe):
    """Single synchronous Hopfield update  s ← sign(W·s).
    sign(0) = +1  (consistent with RTL testbench: z_accum >= 0 → +1).
    Returns (new_s_int, new_s_nfe)."""
    z = hopfield_matvec(W_nfe, s_nfe)
    s_new = [1 if v >= 0.0 else -1 for v in z]
    return s_new, [nfe_enc(float(v)) for v in s_new]


# ── LFSR-based corruption ──────────────────────────────────────────────────────
def corrupt_pattern(pattern, n_flip, seed):
    """Flip n_flip bits without replacement using LFSR seed.
    Selection algorithm: swap-with-last (mirrors tb_hopfield_recall.v
    task corrupt_state exactly — same available-list ordering).
    Returns (corrupted_state_int, list_of_flipped_indices)."""
    p = list(pattern)
    lfsr = seed & 0xFFFFFFFF
    avail = list(range(len(p)))
    avail_len = len(p)
    flipped = []
    for _ in range(n_flip):
        lfsr = lfsr_step(lfsr)
        pos = int(lfsr_frac(lfsr) * avail_len)
        if pos >= avail_len:
            pos = avail_len - 1
        idx = avail[pos]
        p[idx] = -p[idx]
        flipped.append(idx)
        # Swap selected position with last (mirrors Verilog avail swap)
        avail[pos] = avail[avail_len - 1]
        avail_len -= 1
    return p, flipped


def random_pm1_state(seed):
    """Generate random ±1 state via LFSR.  Matches tb_hopfield_recall.v task random_state."""
    lfsr = seed & 0xFFFFFFFF
    s = []
    for _ in range(N_NEURONS):
        lfsr = lfsr_step(lfsr)
        s.append(1 if lfsr_frac(lfsr) >= 0.5 else -1)
    return s


# ── Metrics ────────────────────────────────────────────────────────────────────
def hamming(a, b):
    return sum(1 for x, y in zip(a, b) if x != y)

def nearest_pat(s):
    """Returns (index, hamming_distance) to closest stored pattern."""
    dists = [hamming(s, p) for p in PATTERNS]
    k = min(range(K_PATTERNS), key=lambda i: dists[i])
    return k, dists[k]

def all_overlaps(s):
    return [sum(a*b for a, b in zip(s, p)) / N_NEURONS for p in PATTERNS]


# ── Full recall run ────────────────────────────────────────────────────────────
def run_hopfield_case(W_nfe, s0_int):
    """Run Hopfield dynamics from s0_int until fixed point or MAX_ITERS.
    Returns (final_state, n_iters, converged, trace).
    trace: list of (iter, state_int, hamming_to_nearest, overlaps)."""
    s_int = list(s0_int)
    s_nfe = [nfe_enc(float(v)) for v in s_int]

    def _record(it, si):
        kn, hd = nearest_pat(si)
        return (it, list(si), hd, all_overlaps(si))

    trace = [_record(0, s_int)]
    for it in range(1, MAX_ITERS + 1):
        s_new, s_new_nfe = step_hopfield(W_nfe, s_nfe)
        trace.append(_record(it, s_new))
        if s_new == s_int:
            return s_new, it, True, trace
        s_int = s_new
        s_nfe = s_new_nfe
    return s_int, MAX_ITERS, False, trace


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 72)
    print("sim/hopfield_demo.py — Hopfield Recall Demo (PATH_NFE baseline)")
    print("=" * 72)

    W_real, W_nfe = build_weights()

    print("\n── Weight Encoding ──────────────────────────────────────────────────")
    check_weight_encoding(W_real, W_nfe)

    print("\n── Pattern Orthogonality (dot product / N) ──────────────────────────")
    for i in range(K_PATTERNS):
        for j in range(i+1, K_PATTERNS):
            dot = sum(PATTERNS[i][k]*PATTERNS[j][k] for k in range(N_NEURONS))
            print(f"  p_{PATTERN_NAMES[i]} · p_{PATTERN_NAMES[j]} = {dot:4d}  "
                  f"({dot/N_NEURONS:+.4f})")

    # ── Corruption tests ──────────────────────────────────────────────────────
    print("\n── Corruption Recall Tests ──────────────────────────────────────────")
    summary_rows = []
    csv_rows = []

    for pk, pat_name in enumerate(PATTERN_NAMES):
        pat = PATTERNS[pk]
        for lv, n_flip in enumerate(FLIP_LEVELS):
            n_exact = 0
            for trial in range(N_TRIALS):
                seed = (CORRUPT_SEED_BASE ^ (pk * 0x11111111) ^
                        (lv * 0x22222222) ^ (trial * 0x01234567)) & 0xFFFFFFFF
                s_corr, _ = corrupt_pattern(pat, n_flip, seed)
                final, n_iters, converged, trace = run_hopfield_case(W_nfe, s_corr)
                hd_target = hamming(final, pat)
                if hd_target == 0:
                    n_exact += 1
                for (it, si, hd_near, ovlps) in trace:
                    csv_rows.append({
                        'source': 'python',
                        'pat_name': pat_name,
                        'trial': trial,
                        'n_flip': n_flip,
                        'iteration': it,
                        'hamming_to_nearest': hd_near,
                        'nearest_pat': PATTERN_NAMES[nearest_pat(si)[0]],
                        'overlap_H': f"{ovlps[0]:.6f}",
                        'overlap_T': f"{ovlps[1]:.6f}",
                        'overlap_X': f"{ovlps[2]:.6f}",
                    })
            avg_it = "—"
            summary_rows.append((pat_name, n_flip, n_exact, N_TRIALS))
            print(f"  Pattern {pat_name}, {n_flip:2d}/64 corruptions: "
                  f"{n_exact:2d}/{N_TRIALS} exact recall")

    print("\n── Recall Rate Summary ──────────────────────────────────────────────")
    print(f"  {'Pattern':<8} {'Corrupted':<14} {'Exact Recall'}")
    print("  " + "-"*38)
    for (pat, nf, ne, tot) in summary_rows:
        pct = 100.0 * ne / tot
        print(f"  {pat:<8} {nf:2d}/64  (model)  {ne}/{tot}  ({pct:.0f}%)")

    # ── Spurious attractor tests ──────────────────────────────────────────────
    print("\n── Spurious Attractor Tests (random ±1 initial states) ─────────────")
    n_spurious_found = 0
    for si in range(N_SPURIOUS):
        seed = (SPURIOUS_SEED_BASE ^ (si * 0x01234567)) & 0xFFFFFFFF
        s_rand = random_pm1_state(seed)
        final, n_iters, converged, trace = run_hopfield_case(W_nfe, s_rand)
        kn, hd = nearest_pat(final)
        spurious = (hd > 0)
        if spurious:
            n_spurious_found += 1
            verdict = f"SPURIOUS — {hd} px from {PATTERN_NAMES[kn]}"
        else:
            verdict = f"→ pattern {PATTERN_NAMES[kn]} (exact)"
        print(f"  seed 0x{seed:08X}: {n_iters:2d} iter, converged={converged}, "
              f"{verdict}")
        for (it, s_it, hd_near, ovlps) in trace:
            csv_rows.append({
                'source': 'python',
                'pat_name': f'spurious_{si}',
                'trial': si,
                'n_flip': -1,
                'iteration': it,
                'hamming_to_nearest': hd_near,
                'nearest_pat': PATTERN_NAMES[nearest_pat(s_it)[0]],
                'overlap_H': f"{ovlps[0]:.6f}",
                'overlap_T': f"{ovlps[1]:.6f}",
                'overlap_X': f"{ovlps[2]:.6f}",
            })
    print(f"  Spurious attractors found: {n_spurious_found}/{N_SPURIOUS}")

    # ── ASCII recall sequences (one per pattern, 8-flip, trial 0) ─────────────
    print("\n── ASCII Recall Sequences  (8/64 corruptions, trial 0) ─────────────")
    for pk, pat_name in enumerate(PATTERN_NAMES):
        pat = PATTERNS[pk]
        seed = (CORRUPT_SEED_BASE ^ (pk * 0x11111111) ^ (0 * 0x22222222) ^
                (0 * 0x01234567)) & 0xFFFFFFFF
        s_corr, flipped = corrupt_pattern(pat, 8, seed)
        final, n_iters, converged, trace = run_hopfield_case(W_nfe, s_corr)

        print(f"\n  Pattern {pat_name}  seed 0x{seed:08X}  "
              f"flipped {len(flipped)} pixels")
        print("  Stored:")
        for row in render_state(pat):
            print(f"    {row}")
        print(f"  Corrupted input (t=0):")
        for row in render_state(s_corr):
            print(f"    {row}")
        for (it, s_it, hd_near, ovlps) in trace[1:]:
            print(f"  t={it}  (hamming_to_nearest={hd_near}):")
            for row in render_state(s_it):
                print(f"    {row}")
            if hd_near == 0:
                break
        hd_final = hamming(final, pat)
        if hd_final == 0:
            verdict = "EXACT"
        elif not converged:
            verdict = f"FAILED (did not converge in {MAX_ITERS} iters)"
        else:
            verdict = f"PARTIAL ({hd_final} pixels wrong)"
        print(f"  RECALL: {verdict}  ({n_iters} iteration(s))")

    # ── Write CSV ─────────────────────────────────────────────────────────────
    out_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = os.path.join(out_dir, "HOPFIELD_DEMO_PY.csv")
    fields = ['source','pat_name','trial','n_flip','iteration',
              'hamming_to_nearest','nearest_pat',
              'overlap_H','overlap_T','overlap_X']
    with open(csv_path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(csv_rows)
    print(f"\nPython trace written to {csv_path}  ({len(csv_rows)} rows)")
    return summary_rows, n_spurious_found


if __name__ == '__main__':
    main()
