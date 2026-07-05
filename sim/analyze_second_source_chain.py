#!/usr/bin/env python3
"""
analyze_second_source_chain.py — Pass/fail analysis of SSC_CHAIN_TRACE.csv
against Python model predictions in sim/second_source_chain.py.

Run from sim/ after: make ssc_chain

Predictions under test
─────────────────────────────────────────────────────────────────────────────
P1 [PATH_FAST, neutral, row_sum≈1.0]:
   Full-mantissa MAC path (no 6-bit intermediate quantization) holds ≤1%
   mean relative error vs FP64 golden through 256 feedback cycles.
   Predicted final error: 0.3838% (matching single-pass figure).

P2 [PATH_NFE / RTL, neutral, row_sum≈1.0]:
   Path that quantizes each intermediate product to 6-bit NFE fraction before
   accumulating diverges past 1% mean rel err within ~5 feedback cycles,
   ending near 20% error.
   Tolerance: RTL neutral onset ≤ 10 cycles.

P3 [expansive, row_sum≈1.1]:
   Both paths converge to ~95% error dominated by saturation events.
   Tolerance: final mean rel err within 2× of 95% (i.e., [47.5%, 190%]).

RTL Architecture Note
─────────────────────────────────────────────────────────────────────────────
horus_nfe.v op_sel=2'b10 (MUL) always produces a 6-bit-quantized result
(lines 530-532): f_result = scale_reg[12:7] or scale_reg[11:6].
This maps ONLY to PATH_NFE (Prediction 2/3), NOT to PATH_FAST (Prediction 1).

PATH_FAST — which keeps the full 14-bit mantissa product without re-encoding —
has no corresponding op_sel value in horus_nfe.v (scale_reg is not exported).
Therefore P1 is untestable from this RTL and is reported NOT CONFIRMED with an
explicit architectural gap note.

The "do not soften a mismatch into a pass" requirement is enforced: any result
that fails its tolerance band is reported NOT CONFIRMED with the raw numbers.
"""

import csv
import sys
import os

CSV_FILE  = "SSC_CHAIN_TRACE.csv"
DEPTH     = 256
DIV_THR   = 1.0    # divergence threshold, percent mean relative error

# Prediction parameters
P1_PRED_FINAL   = 0.3838   # % — predicted final error for PATH_FAST neutral
P2_ONSET_TOL    = 10       # cycles — tolerance band for P2 onset
P3_TARGET       = 95.0     # % — predicted final error for expansive regime
P3_TOL_FACTOR   = 2.0      # P3 pass band: [P3_TARGET/factor, P3_TARGET*factor]


def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    if not rows:
        raise ValueError(f"{path} is empty or has no data rows")
    return rows


def summarize_regime(rows, regime_name):
    """Return (onset_cycle, final_mean_err, cum_sat, cum_floor) for one regime.
    onset_cycle is None if mean_rel_err never exceeded DIV_THR within DEPTH.
    """
    regime_rows = [r for r in rows if r["regime"] == regime_name]
    if not regime_rows:
        return None, None, None, None

    onset = None
    for row in regime_rows:
        err = float(row["mean_rel_err"])
        if onset is None and err > DIV_THR:
            onset = int(row["cycle"])
            break  # first crossing

    last = regime_rows[-1]
    final_err = float(last["mean_rel_err"])
    cum_sat   = int(last["cum_sat"])
    cum_floor = int(last["cum_floor"])
    final_cycle = int(last["cycle"])

    return onset, final_err, cum_sat, cum_floor, final_cycle


def verdict_str(passed):
    return "CONFIRMED" if passed else "NOT CONFIRMED"


def main():
    if not os.path.exists(CSV_FILE):
        print(f"ERROR: {CSV_FILE} not found.")
        print("Run 'make ssc_chain' from sim/ to generate it.")
        sys.exit(1)

    try:
        rows = load_csv(CSV_FILE)
    except (ValueError, KeyError) as exc:
        print(f"ERROR reading {CSV_FILE}: {exc}")
        sys.exit(1)

    print(f"\nSecond-source chain RTL analysis")
    print(f"CSV: {CSV_FILE}")
    print("=" * 72)

    results = {}
    for regime in ["contractive", "neutral", "expansive"]:
        r = summarize_regime(rows, regime)
        if r[0] is None and r[1] is None:
            print(f"WARNING: no data found for regime '{regime}' in {CSV_FILE}")
        results[regime] = r  # (onset, final_err, cum_sat, cum_floor, final_cycle)

    # ── Per-regime data dump ──────────────────────────────────────────────────
    for regime in ["contractive", "neutral", "expansive"]:
        onset, final_err, cum_sat, cum_floor, final_cycle = results[regime]
        if final_err is None:
            continue
        print(f"\nRegime: {regime}  (final_cycle={final_cycle})")
        if onset is None:
            print(f"  Divergence onset (> {DIV_THR}%): NONE within {DEPTH} cycles")
        else:
            print(f"  Divergence onset (> {DIV_THR}%): cycle {onset}")
        print(f"  Final mean rel err      : {final_err:.4f}%")
        print(f"  Cumulative sat  (E63f63): {cum_sat}")
        print(f"  Cumulative floor(E0 f0) : {cum_floor}")

    print("\n" + "=" * 72)
    print("PREDICTION VERDICTS")
    print("=" * 72)

    # ── P1: PATH_FAST, neutral ─────────────────────────────────────────────────
    print(f"\nP1  [neutral, PATH_FAST, final_err ≤ 1.0%, onset = NONE in {DEPTH} cycles]")
    print(f"    Predicted: final_err = {P1_PRED_FINAL}%, onset = NONE (never diverges)")
    print(f"    ARCHITECTURAL GAP: horus_nfe.v op_sel=2'b10 (MUL) outputs a 6-bit-")
    print(f"    quantized fraction (lines 530-532: scale_reg[12:7] / scale_reg[11:6]).")
    print(f"    PATH_FAST requires exposing the full 14-bit scale_reg product — there")
    print(f"    is no op_sel value for this in the current RTL interface.")
    print(f"    This testbench exercises only PATH_NFE.  P1 cannot be confirmed or")
    print(f"    falsified without RTL modification to expose the full-mantissa path.")
    print(f"    VERDICT: NOT CONFIRMED  (ARCHITECTURAL GAP — untestable from this RTL)")

    # ── P2: PATH_NFE / RTL, neutral ───────────────────────────────────────────
    neut = results.get("neutral", (None, None, None, None, None))
    neut_onset, neut_final, neut_sat, neut_floor, neut_fc = neut

    print(f"\nP2  [neutral, PATH_NFE/RTL, onset ≤ {P2_ONSET_TOL} cycles, final ≈ 20%]")
    print(f"    Predicted: onset ≤ 5 cycles (tolerance: ≤ {P2_ONSET_TOL}),  "
          f"final ≈ 20%")

    if neut_final is None:
        print(f"    RTL result: NO DATA for neutral regime")
        print(f"    VERDICT: NOT CONFIRMED  (missing data)")
    else:
        onset_str = f"cycle {neut_onset}" if neut_onset else f"NONE within {DEPTH}"
        print(f"    RTL result: onset = {onset_str},  final_err = {neut_final:.4f}%")

        if neut_onset is not None and neut_onset <= P2_ONSET_TOL:
            print(f"    VERDICT: CONFIRMED  "
                  f"(onset {neut_onset} ≤ tolerance {P2_ONSET_TOL})")
        elif neut_onset is None:
            # RTL never diverged — that would match P1 (PATH_FAST), not P2
            print(f"    VERDICT: NOT CONFIRMED  — RTL neutral path NEVER diverged "
                  f"past {DIV_THR}% in {DEPTH} cycles")
            print(f"    Final error {neut_final:.4f}% vs predicted ~20%.  "
                  f"This contradicts P2 (PATH_NFE should diverge quickly).")
            print(f"    Possible cause: RTL quantization is less aggressive than "
                  f"the Python PATH_NFE model — investigate horus_nfe.v MUL output.")
        else:
            # Onset exists but is beyond tolerance
            print(f"    VERDICT: NOT CONFIRMED  — onset {neut_onset} exceeds "
                  f"tolerance {P2_ONSET_TOL}")
            print(f"    Actual onset ({neut_onset}) is {neut_onset - 5} cycles "
                  f"later than prediction (~5).  Raw mismatch reported.")

    # ── P3: expansive regime ───────────────────────────────────────────────────
    exp = results.get("expansive", (None, None, None, None, None))
    exp_onset, exp_final, exp_sat, exp_floor, exp_fc = exp

    p3_lo = P3_TARGET / P3_TOL_FACTOR   # 47.5%
    p3_hi = P3_TARGET * P3_TOL_FACTOR   # 190%

    print(f"\nP3  [expansive, final_err ≈ {P3_TARGET:.0f}%, within "
          f"{P3_TOL_FACTOR}× tolerance → [{p3_lo:.1f}%, {p3_hi:.1f}%]]")
    print(f"    Predicted: both paths converge to ~{P3_TARGET:.0f}% error "
          f"(saturation-dominated)")

    if exp_final is None:
        print(f"    RTL result: NO DATA for expansive regime")
        print(f"    VERDICT: NOT CONFIRMED  (missing data)")
    else:
        print(f"    RTL result: final_err = {exp_final:.4f}%,  "
              f"cum_sat = {exp_sat}")
        if p3_lo <= exp_final <= p3_hi:
            print(f"    VERDICT: CONFIRMED  "
                  f"({p3_lo:.1f}% ≤ {exp_final:.4f}% ≤ {p3_hi:.1f}%)")
        else:
            diff = abs(exp_final - P3_TARGET)
            direction = "below" if exp_final < p3_lo else "above"
            print(f"    VERDICT: NOT CONFIRMED  — {exp_final:.4f}% is outside "
                  f"[{p3_lo:.1f}%, {p3_hi:.1f}%]")
            print(f"    Divergence from prediction: {diff:.2f}% "
                  f"({direction} tolerance band).  Raw mismatch reported.")
            if exp_sat == 0:
                print(f"    Note: zero saturation events — expansive regime may not "
                      f"have reached the OVF cliff within {DEPTH} cycles.")

    # ── Summary ────────────────────────────────────────────────────────────────
    print("\n" + "=" * 72)
    print("SUMMARY")
    print("  P1 (PATH_FAST, neutral)  : NOT CONFIRMED  (architectural gap)")

    # P2 verdict compact
    if neut_onset is not None and neut_onset <= P2_ONSET_TOL:
        p2_v = f"CONFIRMED  (onset={neut_onset})"
    elif neut_onset is None:
        p2_v = f"NOT CONFIRMED  (never diverged; final={neut_final:.2f}%)"
    else:
        p2_v = f"NOT CONFIRMED  (onset={neut_onset} > tol={P2_ONSET_TOL})"
    print(f"  P2 (PATH_NFE, neutral)   : {p2_v}")

    # P3 verdict compact
    if exp_final is not None and p3_lo <= exp_final <= p3_hi:
        p3_v = f"CONFIRMED  (final={exp_final:.2f}%)"
    elif exp_final is None:
        p3_v = "NOT CONFIRMED  (missing data)"
    else:
        p3_v = f"NOT CONFIRMED  (final={exp_final:.2f}%, outside [{p3_lo:.1f},{p3_hi:.1f}]%)"
    print(f"  P3 (expansive ~95%)      : {p3_v}")

    print("\nNote: P1 is NOT CONFIRMED because the RTL has no PATH_FAST datapath,")
    print("      not because the RTL falsifies the prediction.  P2 and P3 are the")
    print("      only predictions falsifiable by this RTL testbench.")
    print("=" * 72)


if __name__ == "__main__":
    main()
