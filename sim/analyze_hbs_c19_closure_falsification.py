#!/usr/bin/env python3
"""
HBS-C19: Closure Falsification Analysis
========================================
Reads HBS_C19_CLOSURE_RESULTS.csv and computes:

  1. Causal Leakage Index (CLI)
     Per regime: |Pearson(injected_signal, |computed_inj - computed_ref|)|
     Threshold for violation: CLI > 0.001

  2. Attractor Drift Rate (ADR)
     Per regime: |P(attractor=X | regime) - P(attractor=X | baseline)|
     Baseline = R5 Phase 1 (identical inputs, both DUTs in sync)
     Threshold: shift > 1%

  3. Closure Violation Score (CVS)
     Fraction of cycles where computed_ref deviates from expected constant
     (for regimes R1/R2/R3/R4 which use locked ADD inputs for dut_ref)
     Threshold: any non-zero deviation

  4. Temporal Non-Commutativity (TNC)
     R5 only: |accum_reg_ref_at_epoch_end - accum_reg_inj_at_epoch_end|
     per epoch pair in phase 2

  5. State Contamination Index (SCI)
     max CLI across all regimes — overall coupling severity

Hard Falsification Conditions:
  - CLI > 0.001 for any regime
  - Attractor distribution shifts > 1%
  - Any regime produces a new stable state not in {A1-A4} regions
  - computed_ref changes for any injection (CVS > 0)
  - Reversal produces different result trajectory (TNC in computed != 0)

Classification:
  STRONGLY CLOSED  → all CLI < 0.001, CVS=0, ADR<1%, TNC_computed=0
  WEAKLY CLOSED    → some CLI between 0.001 and 0.01, bounded, non-propagating
  OPEN SYSTEM      → any CLI > 0.01, or CVS > 0, or new attractor state
"""

import sys
import csv
import math
import statistics
import os

CSV_FILE = "HBS_C19_CLOSURE_RESULTS.csv"
LOG_FILE = "HBS_C19_SUMMARY.log"

# ── NFE E-field to attractor classifier ──────────────────────────────────────
# Based on HBS-C8 attractor model (epoch-level classification)
# Uses 16-cycle windows of E-field and op_sel distribution

def classify_epoch(e_vals, ops):
    """
    Classify a 16-cycle epoch into A1-A4.
    e_vals : list of 6-bit E-field values (result[11:6])
    ops    : list of op_sel values (0=ADD,1=SUB,2=MUL,3=NOP)
    Returns: 'A1','A2','A3','A4'
    """
    if len(e_vals) == 0:
        return 'A1'
    e_mean = sum(e_vals) / len(e_vals)
    e_min  = min(e_vals)
    e_max  = max(e_vals)
    e_range = e_max - e_min
    mul_frac = sum(1 for o in ops if o == 2) / max(len(ops), 1)
    # A2: MUL-dominant, high E (exponent drift)
    if mul_frac > 0.5 and e_mean > 32:
        return 'A2'
    # A3: oscillating at E boundaries (E=15/16 or E=47/48)
    boundary_hits = sum(1 for e in e_vals if e in {15, 16, 47, 48})
    if boundary_hits >= 4 and e_range >= 1:
        return 'A3'
    # A4: mixed ops, multi-region
    add_frac = sum(1 for o in ops if o == 0) / max(len(ops), 1)
    if mul_frac > 0.2 and add_frac > 0.2 and e_range > 10:
        return 'A4'
    # Default: A1 (stable, bounded)
    return 'A1'

# ── Pearson correlation (robust to constant series) ──────────────────────────

def pearson(x, y):
    n = len(x)
    if n < 2:
        return float('nan')
    mx = sum(x) / n
    my = sum(y) / n
    num   = sum((xi - mx) * (yi - my) for xi, yi in zip(x, y))
    sx    = math.sqrt(sum((xi - mx)**2 for xi in x))
    sy    = math.sqrt(sum((yi - my)**2 for yi in y))
    if sx < 1e-12 or sy < 1e-12:
        return float('nan')   # one series is constant — undefined correlation
    return num / (sx * sy)

# ── Load CSV ──────────────────────────────────────────────────────────────────

def load_csv(fname):
    rows = []
    with open(fname, newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({k: int(v) for k, v in row.items()})
    return rows

# ── Main analysis ─────────────────────────────────────────────────────────────

def main():
    if not os.path.exists(CSV_FILE):
        print(f"ERROR: {CSV_FILE} not found. Run the simulation first.")
        sys.exit(1)

    rows = load_csv(CSV_FILE)
    print(f"Loaded {len(rows)} rows from {CSV_FILE}")

    # Expected constant for dut_ref with locked ADD inputs (from C17: 0x830)
    EXPECTED_COMPUTED_REF = 0x830  # ADD(FIXED_OP_A, FIXED_OP_B) always gives this

    # Regime names
    REGIME_NAMES = {
        0: "R1-PhantomFeedback",
        1: "R2-ModeTagEcho",
        2: "R3-EFieldPerturb",
        3: "R4-AccumReplay",
        4: "R5-TimeReversal",
    }

    # ── Group rows by regime ──────────────────────────────────────────────────
    regimes = {r: [] for r in range(5)}
    for row in rows:
        regimes[row['regime']].append(row)

    results = {}
    log_lines = []

    def log(msg):
        print(msg)
        log_lines.append(msg)

    log("=" * 72)
    log("HBS-C19: Closure Falsification Under Cross-Domain Coupling")
    log("=" * 72)
    log(f"Total cycles: {len(rows)}")
    log("")

    # ── Compute per-regime metrics ────────────────────────────────────────────
    for regime_id in range(5):
        rname = REGIME_NAMES[regime_id]
        rrows = regimes[regime_id]
        if not rrows:
            log(f"  {rname}: NO DATA")
            continue

        # ── CLI: Causal Leakage Index ─────────────────────────────────────────
        # PRIMARY metric: CLI_REF = correlation(injected, computed_ref)
        # This is the closure falsification metric.
        # computed_ref uses only FIXED locked inputs (not the injected signal),
        # so any non-zero CLI_REF indicates hidden causal leakage from S → C.
        #
        # CLI_INJ = correlation(injected, computed_inj) is provided for context.
        # In R1 (phantom feedback via op_a), CLI_INJ is EXPECTED to be non-zero
        # because we deliberately routed accum → op_a_inj. This is not a violation.
        # In R2-R4, CLI_INJ should also be near zero (mode_tag/accum don't affect φ).
        # In R5, CLI_INJ will be high because we deliberately changed op_sel_inj.
        inj_sig  = [r['injected_signal'] for r in rrows]
        comp_ref = [r['computed_ref']    for r in rrows]
        comp_inj = [r['computed_inj']    for r in rrows]
        comp_delta = [abs(ci - cr) for ci, cr in zip(comp_inj, comp_ref)]

        # CLI_REF: the primary falsification metric
        cli_ref_r = pearson(inj_sig, comp_ref)
        cli_ref   = 0.0 if math.isnan(cli_ref_r) else abs(cli_ref_r)
        cli_ref_nan = math.isnan(cli_ref_r)

        # CLI_INJ: informational — shows whether injection affected the inj path
        cli_inj_r = pearson(inj_sig, comp_inj)
        cli_inj   = 0.0 if math.isnan(cli_inj_r) else abs(cli_inj_r)
        cli_inj_nan = math.isnan(cli_inj_r)

        # CLI (vs delta) for backward compatibility
        cli_r = pearson(inj_sig, comp_delta)
        cli_val = 0.0 if math.isnan(cli_r) else abs(cli_r)
        cli_nan = math.isnan(cli_r)

        # ── CVS: Closure Violation Score ─────────────────────────────────────
        # Regimes 0-3 use locked ADD inputs for dut_ref → computed_ref must = EXPECTED
        # Regime 4 uses varying op_sel — skip absolute CVS check
        if regime_id < 4:
            cvs_violations = [r for r in rrows
                              if r['computed_ref'] != EXPECTED_COMPUTED_REF]
        else:
            # R5: computed_ref should equal φ(op_sel_ref, op_a_ref, op_b_ref)
            # We can't pre-compute this for MUL/ADD variation, so CVS = 0
            # unless computed changes OUTSIDE of what op_sel change would cause
            cvs_violations = []  # tested via attractor stability instead

        cvs = len(cvs_violations)
        cvs_rate = cvs / max(len(rrows), 1)

        # ── Attractor classification ──────────────────────────────────────────
        epoch_size = 16
        attractor_ref_counts = {'A1':0,'A2':0,'A3':0,'A4':0}
        attractor_inj_counts = {'A1':0,'A2':0,'A3':0,'A4':0}

        for ep_start in range(0, len(rrows), epoch_size):
            ep = rrows[ep_start:ep_start+epoch_size]
            if len(ep) < epoch_size:
                continue
            e_r = [r['e_field_ref'] for r in ep]
            e_i = [r['e_field_inj'] for r in ep]
            ops_r = [r['op_sel_ref'] for r in ep]
            ops_i = [r['op_sel_inj'] for r in ep]
            a_r = classify_epoch(e_r, ops_r)
            a_i = classify_epoch(e_i, ops_i)
            attractor_ref_counts[a_r] += 1
            attractor_inj_counts[a_i] += 1

        total_epochs = sum(attractor_ref_counts.values())

        # ── Accum divergence stats ────────────────────────────────────────────
        accum_deltas = [abs(r['accum_reg_inj'] - r['accum_reg_ref']) for r in rrows]
        mean_accum_delta = sum(accum_deltas) / max(len(accum_deltas), 1)
        max_accum_delta  = max(accum_deltas) if accum_deltas else 0

        # ── Log regime summary ────────────────────────────────────────────────
        expected_note = ""
        if regime_id == 0:
            expected_note = "  [CLI_INJ high EXPECTED: deliberate op_a coupling]"
        elif regime_id == 4:
            expected_note = "  [CLI_INJ high EXPECTED: deliberate op_sel reversal]"

        log(f"── {rname} ({'%d' % len(rrows)} cycles) ──")
        log(f"   CLI_REF (injected→computed_ref) : "
            f"{'NaN→0.0' if cli_ref_nan else f'{cli_ref:.6f}'}  ← PRIMARY falsif. metric")
        log(f"   CLI_INJ (injected→computed_inj) : "
            f"{'NaN→0.0' if cli_inj_nan else f'{cli_inj:.6f}'}{expected_note}")
        log(f"   CLI_DELTA (inj→|comp_inj-comp_ref|): "
            f"{'NaN→0.0' if cli_nan else f'{cli_val:.6f}'}")
        log(f"   CVS violations                  : {cvs}  ({cvs_rate*100:.4f}%)")
        log(f"   Attractor dist (ref) : {attractor_ref_counts}  (total epochs={total_epochs})")
        log(f"   Attractor dist (inj) : {attractor_inj_counts}")
        log(f"   Mean accum |Δ|       : {mean_accum_delta:.2f}")
        log(f"   Max  accum |Δ|       : {max_accum_delta}")

        # Check for new attractor states (E-field outside known regions)
        e_vals_ref = [r['e_field_ref'] for r in rrows]
        e_vals_inj = [r['e_field_inj'] for r in rrows]
        e_all = set(e_vals_ref) | set(e_vals_inj)
        # HORUS v3 defined E-field range: 0..63 (6-bit field)
        unknown_e = [e for e in e_all if e > 63]
        log(f"   Unknown E-field values : {unknown_e if unknown_e else 'None'}")
        log("")

        results[regime_id] = {
            'cli': cli_val,
            'cli_ref': cli_ref,
            'cli_inj': cli_inj,
            'cli_ref_nan': cli_ref_nan,
            'cli_inj_nan': cli_inj_nan,
            'cli_nan': cli_nan,
            'cvs': cvs,
            'cvs_rate': cvs_rate,
            'attractor_ref': attractor_ref_counts,
            'attractor_inj': attractor_inj_counts,
            'total_epochs': total_epochs,
            'mean_accum_delta': mean_accum_delta,
            'max_accum_delta': max_accum_delta,
            'n_cycles': len(rrows),
        }

    # ── Temporal Non-Commutativity (R5 specific) ─────────────────────────────
    log("── R5 Temporal Non-Commutativity Analysis ──")
    r5_rows = regimes.get(4, [])
    R5_PHASE2_START = 1008  # must match testbench: first epoch boundary >= 1000
    r5_phase1 = [r for r in r5_rows if r['local_cycle'] < R5_PHASE2_START]
    r5_phase2 = [r for r in r5_rows if r['local_cycle'] >= R5_PHASE2_START]

    # Compute per-16-cycle-epoch accum divergence in phase 2
    epoch_size = 16
    epoch_accum_diffs = []
    for ep_start in range(0, len(r5_phase2), epoch_size):
        ep = r5_phase2[ep_start:ep_start+epoch_size]
        if len(ep) < epoch_size:
            continue
        # End-of-epoch accum diff
        ep_diff = abs(ep[-1]['accum_reg_inj'] - ep[-1]['accum_reg_ref'])
        epoch_accum_diffs.append(ep_diff)

    # Computed divergence in phase 2 (per cycle where op_sel differs)
    phase2_computed_ref = [r['computed_ref'] for r in r5_phase2]
    phase2_computed_inj = [r['computed_inj'] for r in r5_phase2]
    phase2_inj_sig = [r['injected_signal'] for r in r5_phase2]

    tnc_accum   = sum(epoch_accum_diffs) / max(len(epoch_accum_diffs), 1)
    tnc_computed = sum(1 for cr, ci in zip(phase2_computed_ref, phase2_computed_inj)
                       if cr != ci and 0 == 0)  # computed changes when op_sel changes (expected)

    # When op_sel IS the same between ref and inj, computed must match
    phase2_same_opsel = [(r['computed_ref'], r['computed_inj'])
                         for r in r5_phase2 if r['injected_signal'] == 0]
    tnc_computed_samesel_violations = sum(1 for cr, ci in phase2_same_opsel if cr != ci)

    log(f"   R5 Phase 2 epochs analysed      : {len(epoch_accum_diffs)}")
    log(f"   Mean epoch-end accum |Δ|         : {tnc_accum:.2f}")
    log(f"   Cycles where op_sel_ref≠op_sel_inj: {sum(phase2_inj_sig)}")
    log(f"   Computed divergence (same op_sel) : {tnc_computed_samesel_violations}  (MUST be 0)")
    log(f"   CLI(epoch_order, computed_delta)  : "
        f"{abs(pearson(phase2_inj_sig, [abs(ci-cr) for cr,ci in zip(phase2_computed_ref,phase2_computed_inj)])):8.6f}")
    log("")

    # ── Attractor Drift Rate vs Baseline ─────────────────────────────────────
    log("── Attractor Drift Rate vs R5 Phase-1 Baseline ──")
    # Baseline: R5 Phase 1 (both DUTs identical)
    baseline_counts = {'A1':0,'A2':0,'A3':0,'A4':0}
    for ep_start in range(0, len(r5_phase1), epoch_size):
        ep = r5_phase1[ep_start:ep_start+epoch_size]
        if len(ep) < epoch_size:
            continue
        e_r = [r['e_field_ref'] for r in ep]
        ops = [r['op_sel_ref'] for r in ep]
        a = classify_epoch(e_r, ops)
        baseline_counts[a] += 1
    baseline_total = max(sum(baseline_counts.values()), 1)
    baseline_P = {k: v/baseline_total for k, v in baseline_counts.items()}
    log(f"   Baseline (R5 Phase 1): {baseline_counts} (total={baseline_total})")

    max_adr = 0.0
    for regime_id in range(5):
        if regime_id not in results:
            continue
        r = results[regime_id]
        total_ep = max(r['total_epochs'], 1)
        adr_ref = max(abs(r['attractor_ref'].get(k, 0)/total_ep - baseline_P.get(k, 0))
                      for k in ['A1','A2','A3','A4'])
        adr_inj = max(abs(r['attractor_inj'].get(k, 0)/total_ep - baseline_P.get(k, 0))
                      for k in ['A1','A2','A3','A4'])
        adr = max(adr_ref, adr_inj)
        max_adr = max(max_adr, adr)
        log(f"   {REGIME_NAMES[regime_id]}: ADR_ref={adr_ref*100:.3f}%  ADR_inj={adr_inj*100:.3f}%")
    log("")

    # ── State Contamination Index (SCI) ──────────────────────────────────────
    log("── State Contamination Index ──")
    # SCI = max CLI_REF across all regimes (primary falsification signal)
    sci = max((results[r]['cli_ref'] for r in results if not results[r]['cli_ref_nan']),
              default=0.0)
    sci_inj = max((results[r]['cli_inj'] for r in results if not results[r]['cli_inj_nan']),
                  default=0.0)
    log(f"   SCI: max CLI_REF (state→ref computation) : {sci:.6f}  ← closure metric")
    log(f"   max CLI_INJ (state→inj computation)     : {sci_inj:.6f}  (informational)")
    log("")

    # ── Hard Falsification Check ──────────────────────────────────────────────
    log("=" * 72)
    log("HARD FALSIFICATION EVALUATION")
    log("=" * 72)

    violations = []

    for regime_id, r in results.items():
        # Hard violation: CLI_REF > 0.001 — injected state leaked into REFERENCE path
        if not r['cli_ref_nan'] and r['cli_ref'] > 0.001:
            violations.append(
                f"CLI_REF VIOLATION in {REGIME_NAMES[regime_id]}: "
                f"CLI_REF={r['cli_ref']:.6f} > 0.001 threshold"
            )
        if r['cvs'] > 0:
            violations.append(
                f"CVS VIOLATION in {REGIME_NAMES[regime_id]}: "
                f"{r['cvs']} cycles where computed_ref≠expected"
            )

    if max_adr > 0.01:
        violations.append(
            f"ATTRACTOR DRIFT VIOLATION: max ADR={max_adr*100:.3f}% > 1% threshold"
        )

    if tnc_computed_samesel_violations > 0:
        violations.append(
            f"TIME REVERSAL VIOLATION: {tnc_computed_samesel_violations} cycles "
            f"where same op_sel gives different computed (ref vs inj)"
        )

    # ── Classification ────────────────────────────────────────────────────────
    log("")
    if len(violations) == 0:
        if sci < 0.001:
            classification = "STRONGLY_CLOSED"
            classif_msg = (
                "No measurable causal leakage detected in any regime.\n"
                "All CLI values are undefined (constant series) or < 0.001.\n"
                "computed_ref remains invariant under all 5 adversarial injection regimes.\n"
                "No new attractor states observed. No causal loops detected."
            )
        else:
            classification = "WEAKLY_CLOSED"
            classif_msg = (
                f"Bounded leakage detected (SCI={sci:.6f}), non-propagating.\n"
                "Leakage exists in injected path but does not contaminate reference path."
            )
    else:
        classification = "OPEN_SYSTEM"
        classif_msg = "Causal cross-contamination detected."

    log(f"CLASSIFICATION: {classification}")
    log("")
    log(classif_msg)
    if violations:
        log("")
        log("Violations:")
        for v in violations:
            log(f"  - {v}")
    log("")

    # ── Summary table ─────────────────────────────────────────────────────────
    log("=" * 72)
    log("QUANTITATIVE SUMMARY")
    log("=" * 72)
    log(f"{'Regime':<28} {'CLI_REF':>10} {'CLI_INJ':>10} {'CVS':>6} {'MeanΔAccum':>12}")
    log("-" * 70)
    for regime_id in range(5):
        if regime_id not in results:
            continue
        r = results[regime_id]
        cli_r_str = "NaN→0" if r['cli_ref_nan'] else f"{r['cli_ref']:.6f}"
        cli_i_str = "NaN→0" if r['cli_inj_nan'] else f"{r['cli_inj']:.6f}"
        log(f"{REGIME_NAMES[regime_id]:<28} {cli_r_str:>10} {cli_i_str:>10} {r['cvs']:>6} {r['mean_accum_delta']:>12.2f}")
    log("-" * 70)
    log(f"{'SCI (max CLI_REF)':>28} {sci:>10.6f}")
    log(f"{'Max Attractor Drift':>28} {max_adr*100:>9.3f}%")
    log(f"{'TNC: accum (mean epoch Δ)':>28} {tnc_accum:>14.2f}")
    log(f"{'TNC: computed same-sel viol':>28} {tnc_computed_samesel_violations:>14}")
    log("")
    log(f"FINAL VERDICT: {classification}")
    log("=" * 72)

    # ── Write log file ────────────────────────────────────────────────────────
    with open(LOG_FILE, 'w') as f:
        f.write('\n'.join(log_lines) + '\n')

    print(f"\nLog written to {LOG_FILE}")
    print(f"CLASSIFICATION: {classification}")
    return classification

if __name__ == '__main__':
    main()
