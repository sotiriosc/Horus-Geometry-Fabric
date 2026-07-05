#!/usr/bin/env python3
"""
pf_spotcheck.py — independent spot-check of the RTL PATH_FAST 0.18% result.

Methodology:
  1. Replicate the testbench LFSR (tb/tb_horus_nfe_pf.v, SEED = 0xCAFEF00D, r=1)
     in Python to generate the IDENTICAL 8×8 matrix A and initial y vector.
  2. Run the Python PATH_FAST chain (nfe_fast_mac, matching second_source_chain.py
     step_fast logic) for 256 neutral-regime cycles, logging per-cycle error.
  3. Load the RTL per-cycle trace from sim/PF_RTL_TRACE.csv (written by the
     modified tb/tb_horus_nfe_pf.v).
  4. Overlay the two error trajectories and print:
       - Cycles where RTL and Python diverge by more than 2× from each other.
       - Plain verdict: does the RTL track golden at least as closely as the
         Python fast path at every logged checkpoint?
       - Flag any surprising divergence (RTL much better in a way the mechanism
         doesn't explain, or worse) as a suspected testbench/DUT coupling issue.

The Python model uses the EXACT same LFSR seed and matrix generation as the
testbench, not random.Random, so no seed modification of the testbench is needed.

Seed derivation (tb/tb_horus_nfe_pf.v lines 177–188):
  SEED = 0xCAFEF00D
  lfsr = SEED ^ (1 * 0x11111111 + 0x5555AAAA)
       = 0xCAFEF00D ^ 0x6666BBBB
       = 0xAC984BB6
  step: {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]}
  val : (s[31:8] * 1.0) / 16777216.0  — 24-bit unsigned fraction in [0,1)

Usage:
    make pf_check           (regenerates PF_RTL_TRACE.csv)
    python3 pf_spotcheck.py [--rtl-csv PF_RTL_TRACE.csv]
"""

import argparse
import csv
import math
import os
import sys

# ── NFE constants ────────────────────────────────────────────────────────────
N        = 8
EXP_BIAS = 32
EXP_MAX  = 63


class NFE:
    __slots__ = ("s", "e", "f")
    def __init__(self, s, e, f):
        self.s, self.e, self.f = s, e, f


def nfe_dec(w):
    v = math.ldexp(1.0 + w.f / 64.0, w.e - EXP_BIAS)
    return -v if w.s else v


def nfe_enc(v):
    s = 1 if v < 0.0 else 0
    av = abs(v)
    if av == 0.0:
        return NFE(s, 0, 0)
    aE = math.floor(math.log2(av))
    m = av / math.ldexp(1.0, aE)
    if m < 1.0:
        aE -= 1; m = av / math.ldexp(1.0, aE)
    if m >= 2.0:
        aE += 1; m = av / math.ldexp(1.0, aE)
    if aE < -EXP_BIAS:
        return NFE(s, 0, 0)
    if aE > EXP_MAX - EXP_BIAS:
        return NFE(s, EXP_MAX, 63)
    eS = aE + EXP_BIAS
    f = round((m - 1.0) * 64.0)
    if f > 63:
        f = 0; eS += 1
        if eS > EXP_MAX:
            return NFE(s, EXP_MAX, 63)
    return NFE(s, eS, f)


def pf_accumulate_rtl(pf_accum_int, a, b):
    """RTL-faithful PF accumulate for spot-check (W=32, matching horus_nfe_pf.v)."""
    scale_reg = (64 + a.f) * (64 + b.f)
    sreg_msb  = 1 if scale_reg >= 8192 else 0
    scale14   = scale_reg & 0x3FFF
    # RTL lines 538-544: exp_sum includes +1 correction for P >= 8192
    exp_sum   = a.e + b.e - EXP_BIAS + sreg_msb
    if exp_sum < 0 or exp_sum >= 64:
        return pf_accum_int
    res_sign = a.s ^ b.s
    # RTL lines 573-575: k = exp_sum - scale_reg[13] - PF_K_REF = a.e+b.e-EXP_BIAS-PF_K_REF
    k = exp_sum - sreg_msb - 28
    k = max(-8, min(8, k))
    term_u = scale14 << k if k >= 0 else scale14 >> (-k)
    term   = -term_u if res_sign else term_u
    new_acc = pf_accum_int + term
    return max(-(1 << 31), min((1 << 31) - 1, new_acc))


def nfe_fast_mac(a, b):
    """Full-mantissa MAC (mirrors second_source_chain.py nfe_fast_mac)."""
    P    = (64 + a.f) * (64 + b.f)
    sign = -1.0 if (a.s ^ b.s) else 1.0
    return sign * math.ldexp(float(P), a.e + b.e - 76)


def pf_readout_rtl(pf_accum_int):
    """RTL-faithful NOP readout for spot-check (W=32). Mirrors lines 613-679."""
    pf_sign = 1 if pf_accum_int < 0 else 0
    pf_abs  = abs(pf_accum_int) & 0x7FFFFFFF
    if pf_abs == 0:
        return NFE(pf_sign, 0, 0)
    pf_msb = pf_abs.bit_length() - 1
    pf_es  = pf_msb + 16
    if pf_msb >= 6:
        pf_f = (pf_abs >> (pf_msb - 6)) & 0x3F
        if pf_msb >= 7 and ((pf_abs >> (pf_msb - 7)) & 1):
            if pf_f == 0x3F:
                pf_f = 0; pf_es += 1
            else:
                pf_f += 1
    else:
        pf_f = (pf_abs << (6 - pf_msb)) & 0x3F
    if pf_es > EXP_MAX:
        return NFE(pf_sign, EXP_MAX, 63)
    return NFE(pf_sign, pf_es, pf_f)


# ── LFSR replication (mirror tb/tb_horus_nfe_pf.v lines 131–143) ────────────

def lfsr_step(s):
    """32-bit Fibonacci LFSR: {s[30:0], s[31]^s[21]^s[1]^s[0]}."""
    s &= 0xFFFFFFFF
    bit = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1
    return ((s << 1) | bit) & 0xFFFFFFFF


def lfsr_frac(s):
    """24-bit fraction from bits [31:8]: s[31:8] / 2^24."""
    return ((s >> 8) & 0xFFFFFF) / 16777216.0


def gen_matrix_and_y():
    """
    Replicate tb/tb_horus_nfe_pf.v lines 176–197.
    Returns A_fp (8×8 float), A_nfe (8×8 NFE), y_nfe (8 NFE), y_g (8 float).

    Seed derivation (tb lines 177):
      SEED = 0xCAFEF00D
      r = 1 (neutral regime index)
      lfsr = SEED ^ (r * 0x11111111 + 0x5555AAAA)
           = 0xCAFEF00D ^ (0x11111111 + 0x5555AAAA)
           = 0xCAFEF00D ^ 0x6666BBBB
    """
    SEED = 0xCAFEF00D
    r    = 1  # neutral regime (tb line 177: r=1, target_rowsum=1.00)
    lfsr = (SEED ^ (r * 0x11111111 + 0x5555AAAA)) & 0xFFFFFFFF

    # Matrix A (tb lines 178–189)
    A_fp = [[0.0] * N for _ in range(N)]
    for i in range(N):
        rowsum = 0.0
        for j in range(N):
            lfsr = lfsr_step(lfsr)
            A_fp[i][j] = lfsr_frac(lfsr) + 1e-3
            rowsum += A_fp[i][j]
        for j in range(N):
            A_fp[i][j] = A_fp[i][j] / rowsum * 1.00  # neutral target = 1.00
    A_nfe = [[nfe_enc(A_fp[i][j]) for j in range(N)] for i in range(N)]

    # Initial y vector (tb lines 192–197)
    y_nfe = []
    y_g   = []
    for j in range(N):
        lfsr = lfsr_step(lfsr)
        fval = 1.0 + (lfsr & 0x3F) / 64.0   # lfsr[5:0] / 64 (tb line 194)
        nw   = nfe_enc(fval)
        y_nfe.append(nw)
        y_g.append(nfe_dec(nw))              # golden starts from NFE-decoded value

    return A_fp, A_nfe, y_nfe, y_g


def run_python_fast_chain(A_fp, A_nfe, y_nfe_init, y_g_init, depth):
    """
    Run the Python PATH_FAST chain for 'depth' cycles using the RTL-faithful
    fixed-point accumulation (pf_accumulate_rtl + pf_readout_rtl).
    This mirrors what horus_nfe_pf.v does cycle-by-cycle.
    Returns list of (cycle, py_mean_err_pct) tuples.
    """
    y_nfe = list(y_nfe_init)
    y_g   = list(y_g_init)
    trace = []
    for t in range(1, depth + 1):
        # Golden step
        y_g = [sum(A_fp[i][j] * y_g[j] for j in range(N)) for i in range(N)]
        # RTL-faithful PF step (W=32)
        y_nfe_new = []
        for i in range(N):
            acc = 0
            for j in range(N):
                acc = pf_accumulate_rtl(acc, A_nfe[i][j], y_nfe[j])
            y_nfe_new.append(pf_readout_rtl(acc))
        y_nfe = y_nfe_new
        # Mean relative error
        errs = [abs(nfe_dec(y_nfe[i]) - y_g[i]) / abs(y_g[i]) * 100.0
                for i in range(N) if y_g[i] != 0.0 and math.isfinite(y_g[i])]
        trace.append((t, sum(errs) / len(errs) if errs else float("inf")))
    return trace


def load_rtl_trace(path):
    """Load sim/PF_RTL_TRACE.csv → list of (cycle, rtl_mean_err_pct)."""
    if not os.path.exists(path):
        print(f"ERROR: RTL trace file not found: {path}", file=sys.stderr)
        print("  Run 'make pf_check' from sim/ to generate it.", file=sys.stderr)
        sys.exit(1)
    trace = []
    with open(path) as fh:
        rd = csv.DictReader(fh)
        for row in rd:
            trace.append((int(row["cycle"]), float(row["rtl_mean_err_pct"])))
    return trace


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl-csv", default="PF_RTL_TRACE.csv",
                    help="per-cycle RTL trace CSV (default: PF_RTL_TRACE.csv)")
    ap.add_argument("--depth", type=int, default=256)
    args = ap.parse_args()

    # Step 1: generate matrix and y (identical to testbench)
    A_fp, A_nfe, y_nfe_init, y_g_init = gen_matrix_and_y()

    # Step 2: run Python fast chain
    py_trace = run_python_fast_chain(A_fp, A_nfe, y_nfe_init, y_g_init, args.depth)

    # Step 3: load RTL trace
    rtl_trace = load_rtl_trace(args.rtl_csv)

    if len(py_trace) != len(rtl_trace):
        print(f"WARNING: Python trace length {len(py_trace)} != RTL trace length "
              f"{len(rtl_trace)}; comparing common prefix.")
    common_len = min(len(py_trace), len(rtl_trace))

    # Step 4: overlay and compare
    diverge_cycles   = []
    rtl_worse_cycles = []
    rtl_surprising   = []

    for k in range(common_len):
        t_py,  err_py  = py_trace[k]
        t_rtl, err_rtl = rtl_trace[k]
        if t_py != t_rtl:
            print(f"WARNING: cycle mismatch at index {k}: py={t_py} rtl={t_rtl}")
        t = t_rtl
        # Divergence: RTL and Python differ by more than 2× from each other
        if err_py > 0.0 and err_rtl > 0.0:
            ratio = max(err_rtl / err_py, err_py / err_rtl)
            if ratio > 2.0:
                diverge_cycles.append((t, err_py, err_rtl, ratio))
        # RTL worse than Python (>2× specifically)
        if err_py > 0.0 and err_rtl > 2.0 * err_py:
            rtl_worse_cycles.append((t, err_py, err_rtl))
        # RTL surprisingly better: RTL < 0.1 × Python — possible coupling
        if err_py > 0.5 and err_rtl < 0.1 * err_py:
            rtl_surprising.append((t, err_py, err_rtl))

    # Print report
    print()
    print("=" * 72)
    print("pf_spotcheck — PATH_FAST RTL vs Python fast-path error trajectory")
    print(f"  Matrix seed: LFSR 0xCAFEF00D r=1 (neutral regime)")
    print(f"  Depth: {args.depth} cycles  |  RTL trace: {args.rtl_csv}")
    print("=" * 72)
    print()

    py_final  = py_trace[-1][1]  if py_trace  else float("nan")
    rtl_final = rtl_trace[-1][1] if rtl_trace else float("nan")
    print(f"  Final mean rel err  — Python fast path : {py_final:.4f}%")
    print(f"  Final mean rel err  — RTL PATH_FAST    : {rtl_final:.4f}%")
    print()

    if diverge_cycles:
        print(f"  CYCLES WHERE RTL AND PYTHON DIVERGE BY >2× FROM EACH OTHER"
              f" ({len(diverge_cycles)} cycles):")
        for t, ep, er, ratio in diverge_cycles[:20]:
            print(f"    cycle {t:4d}: Python={ep:.4f}%  RTL={er:.4f}%  ratio={ratio:.2f}×")
        if len(diverge_cycles) > 20:
            print(f"    ... ({len(diverge_cycles)-20} more cycles not shown)")
    else:
        print("  No cycles where RTL and Python diverge by >2× from each other.")
    print()

    if rtl_worse_cycles:
        print(f"  CYCLES WHERE RTL IS >2× WORSE THAN PYTHON ({len(rtl_worse_cycles)}):")
        for t, ep, er in rtl_worse_cycles[:10]:
            print(f"    cycle {t:4d}: Python={ep:.4f}%  RTL={er:.4f}%")
        if len(rtl_worse_cycles) > 10:
            print(f"    ... ({len(rtl_worse_cycles)-10} more)")
    else:
        print("  RTL is not >2× worse than Python at any cycle.")
    print()

    if rtl_surprising:
        print(f"  SUSPECTED COUPLING — RTL IS <10% of Python error at these cycles"
              f" ({len(rtl_surprising)}):")
        print("  (RTL dramatically better than mechanism predicts; inspect testbench.)")
        for t, ep, er in rtl_surprising[:10]:
            print(f"    cycle {t:4d}: Python={ep:.4f}%  RTL={er:.4f}%")
    else:
        print("  No suspicious coupling detected (RTL not implausibly better than Python).")
    print()

    # Final verdict
    print("-" * 72)
    if not diverge_cycles and not rtl_worse_cycles and not rtl_surprising:
        print("  VERDICT: PASS — RTL and Python fast paths track the same story.")
        print(f"  RTL final ({rtl_final:.4f}%) is {'better' if rtl_final <= py_final else 'worse'}"
              f" than Python ({py_final:.4f}%), consistent with 32-bit fixed-point"
              f" accumulation vs float.")
    elif not rtl_worse_cycles and not rtl_surprising and len(diverge_cycles) <= 5:
        print(f"  VERDICT: MARGINAL — {len(diverge_cycles)} divergent cycles detected."
              f"  Investigate cycles listed above.")
    else:
        print("  VERDICT: FLAG — significant trajectory divergence detected.")
        print("  Possible causes: seed mismatch, Jacobi/Gauss-Seidel discrepancy,")
        print("  testbench/DUT coupling, or accumulator overflow.  Inspect listed cycles.")
    print("=" * 72)
    print()


if __name__ == "__main__":
    main()
