#!/usr/bin/env python3
"""
synth_add_circuits.py
Run Yosys synthesis on isolated ADD circuits and report GE counts.
Uses Yosys's built-in 'synth' flow (maps to internal generic gates),
then converts to NAND2-equivalent GE using standard cell area weights.

NAND2-equivalent weights for Yosys generic internal cells:
  $_NOT_    : 0.5 GE
  $_AND_    : 1.0 GE
  $_NAND_   : 1.0 GE
  $_OR_     : 1.0 GE
  $_NOR_    : 1.0 GE
  $_XOR_    : 1.5 GE  (2 NAND2 equiv in most libs; some say 3 GE)
  $_XNOR_   : 1.5 GE
  $_MUX_    : 2.0 GE
  $_ANDNOT_ : 1.0 GE
  $_ORNOT_  : 1.0 GE
"""
import subprocess, re, sys, os

SYNTH_DIR = os.path.dirname(os.path.abspath(__file__))

# GE weights for Yosys internal mapped cells
GE_WEIGHT = {
    '$_NOT_':    0.5,
    '$_AND_':    1.0,
    '$_NAND_':   1.0,
    '$_OR_':     1.0,
    '$_NOR_':    1.0,
    '$_XOR_':    1.5,
    '$_XNOR_':   1.5,
    '$_MUX_':    2.0,
    '$_ANDNOT_': 1.0,
    '$_ORNOT_':  1.0,
    '$_AOI3_':   1.5,
    '$_OAI3_':   1.5,
    '$_AOI4_':   2.0,
    '$_OAI4_':   2.0,
    '$_TBUF_':   1.0,
    '$_BUF_':    0.5,
}

def synth(vfile, top, extra_opts=''):
    """Run Yosys synthesis, return (cell_dict, total_cells, total_ge, raw_stat)."""
    script = f"""
read_verilog {vfile}
synth -top {top} -flatten {extra_opts}
abc -g cmos2
stat
"""
    result = subprocess.run(
        ['yosys', '-p', script],
        capture_output=True, text=True
    )
    out = result.stdout + result.stderr

    # Parse stat output
    cells = {}
    in_stat = False
    for line in out.splitlines():
        if 'Number of cells:' in line:
            in_stat = True
        if in_stat:
            m = re.match(r'\s+(\$\w+)\s+(\d+)', line)
            if m:
                cells[m.group(1)] = int(m.group(2))

    total_cells = sum(cells.values())
    total_ge = sum(GE_WEIGHT.get(c, 1.0) * n for c, n in cells.items())
    return cells, total_cells, total_ge, out

def report(name, vfile, top, note=''):
    print(f'\n{"="*68}')
    print(f'  {name}')
    if note:
        print(f'  [{note}]')
    print(f'{"="*68}')
    cells, total_cells, total_ge, raw = synth(vfile, top)
    if not cells:
        # fallback: parse from stat differently
        print('  [raw stat excerpt]')
        for line in raw.splitlines():
            if any(x in line for x in ['Number of', '$_', 'Chip area', 'synth']):
                print('  ' + line)
        return None, None

    print(f'  {"Cell type":<16} {"count":>6}  {"weight":>7}  {"GE":>7}')
    print(f'  {"-"*16} {"-"*6}  {"-"*7}  {"-"*7}')
    for c in sorted(cells):
        w = GE_WEIGHT.get(c, 1.0)
        print(f'  {c:<16} {cells[c]:>6}  {w:>7.1f}  {cells[c]*w:>7.1f}')
    print(f'  {"-"*16} {"-"*6}  {"-"*7}  {"-"*7}')
    print(f'  {"TOTAL":<16} {total_cells:>6}           {total_ge:>7.1f} GE')
    return total_cells, total_ge

print('='*68)
print('  Yosys Synthesis — NFE ADD_FRAC vs Block-Scaled ADD')
print('  Tool: Yosys, abc -g cmos2 (maps to AND2/NOT/MUX)')
print('  GE = NAND2-equivalent  (1 GE = 1 NAND2)')
print('='*68)

results = {}

# 1. Standard NFE ADD_FRAC
c, g = report(
    'STANDARD NFE ADD_FRAC (horus_nfe.v L318-340)',
    f'{SYNTH_DIR}/nfe_add_frac.v', 'nfe_add_frac',
    'rollover + exp increment + sat mux'
)
results['nfe_add'] = g

# 2. Block-scaled 9-bit ADD
c, g = report(
    'BLOCK-SCALED 9-bit ADD (chain accumulator)',
    f'{SYNTH_DIR}/blk_add_9.v', 'blk_add_9',
    'pure CPA, no rollover/exp/sat'
)
results['blk9'] = g

# 3. Block-scaled 17-bit ADD
c, g = report(
    'BLOCK-SCALED 17-bit ADD (matvec row accumulator)',
    f'{SYNTH_DIR}/blk_add_17.v', 'blk_add_17',
    'pure CPA, no rollover/exp/sat'
)
results['blk17'] = g

# 4. Block-scaled 18-bit ADD (sanity check — exact capacity)
c, g = report(
    'BLOCK-SCALED 18-bit ADD (exact capacity check)',
    f'{SYNTH_DIR}/blk_add_17.v', 'blk_add_18',
    '18-bit CPA, holds 16*127*127=258064'
)
results['blk18'] = g

# 5. Summary vs hypotheses
print('\n' + '='*68)
print('  SUMMARY vs ANALYTICAL HYPOTHESES')
print('='*68)

REF = results.get('nfe_add', 70)
for k, v in results.items():
    if v is None: continue
    print(f'  {k:<8}: synth={v:5.1f} GE')

print()
if results.get('nfe_add') and results.get('blk9'):
    add_s = results['nfe_add']
    b9    = results['blk9']
    b17   = results.get('blk17', 68)
    print(f'  Std ADD synth:  {add_s:.1f} GE   (merged model=70, explicit=91)')
    print(f'  Blk9 synth:     {b9:.1f} GE    (prior model=36)')
    print(f'  Blk17 synth:    {b17:.1f} GE   (prior model=68)')
    print()
    print(f'  Rollover/exp/sat overhead in synth: {add_s-b9:.1f} GE')
    print(f'  vs merged estimate:  {70-36:.0f} GE   vs explicit: {91-36:.0f} GE')
    print()

    # Recompute chain saving
    DEPTH, N_NORM, NORM9 = 1024, 64, 81
    def gu(g): return g / add_s  # normalise to synth std ADD
    gw_s = DEPTH * gu(add_s)
    gw_b = DEPTH * gu(b9) + N_NORM * gu(NORM9)
    print(f'  Chain saving (synth):   {100*(gw_s-gw_b)/gw_s:.2f}%')
    print(f'  Chain saving (merged 70 GE ref): 41.34%')
    print(f'  Chain saving (explicit 91 GE):   54.88%')
    print()

    # Recompute matvec
    MUL_STD, MUL_BLK, NORM17, N_MUL, N_ADD, N_NM = 265, 197, 117, 64, 56, 8
    DM_B, DM_I = 9, 16
    gw_s_mv = N_MUL*gu(MUL_STD) + N_ADD*gu(add_s)
    gw_b_mv = N_MUL*gu(MUL_BLK) + N_ADD*gu(b17)   + N_NM*gu(NORM17)
    d = gw_b_mv - gw_s_mv
    print(f'  Matvec Δgw_arith (synth): {d:+.1f}')
    if d < 0:
        print(f'  Breakeven α bcast (+9 dmov):  {-d/DM_B:.2f}')
        print(f'  Breakeven α indep (+16 dmov): {-d/DM_I:.2f}')
    print()
    print(f'  Prior merged:   Δgw=−50.4  α=5.6 / 3.1')
    print(f'  Prior explicit: Δgw=−67.2  α=7.47 / 4.20')
