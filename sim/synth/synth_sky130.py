#!/usr/bin/env python3
"""
synth_sky130.py — Synthesize isolated ADD circuits against Sky130 HD liberty.

Requires:
  - Yosys 0.9+  (system install: apt install yosys)
  - sky130 PDK  (via volare: python3 -m volare fetch --pdk sky130 c6d73a35...)
    Default path: ~/.volare/volare/sky130/versions/<hash>/sky130A/...

Usage:
  python3 synth_sky130.py [--lib <path-to-sky130-liberty>]

Synthesizes:
  nfe_add_frac.v  — Standard NFE ADD_FRAC (rollover + exp + sat)
  blk_add_9.v     — Block-scaled 9-bit accumulator ADD (chain)
  blk_add_17.v    — Block-scaled 17-bit accumulator ADD (matvec)

Reports:
  Real standard-cell area (µm²) and NAND2-equivalent GE for each circuit.
  Chain saving, matvec Δgw_arith, and breakeven-α values.
"""
import subprocess, re, sys, os
from pathlib import Path

SYNTH_DIR = Path(__file__).parent
NAND2_AREA = 3.7536  # µm² for sky130_fd_sc_hd__nand2_1 @ TT 025C 1.8V

DEFAULT_LIB = Path.home() / ".volare/volare/sky130/versions/" \
    "c6d73a35f524070e85faff4a6a9eef49553ebc2b/sky130A/libs.ref/" \
    "sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"

def find_lib():
    if "--lib" in sys.argv:
        return sys.argv[sys.argv.index("--lib") + 1]
    if DEFAULT_LIB.exists():
        return str(DEFAULT_LIB)
    # Try to find it anywhere under ~/.volare
    for p in Path.home().glob(".volare/**/*tt_025C_1v80.lib"):
        if "sky130_fd_sc_hd" in str(p) and "sky130A" in str(p):
            return str(p)
    return None

def parse_lib_areas(lib_path):
    cells = {}
    with open(lib_path) as f:
        lines = f.readlines()
    cur = None
    for line in lines:
        m = re.match(r'\s*cell\s*\("?(sky130_fd_sc_hd__\w+)"?\)', line)
        if m:
            cur = m.group(1)
        if cur:
            am = re.match(r'\s*area\s*:\s*([\d.]+)', line)
            if am:
                cells[cur] = float(am.group(1))
                cur = None
    return cells

def synth(vfile, top, lib):
    script = f"""
read_liberty -lib {lib}
read_verilog {vfile}
synth -top {top} -flatten
abc -liberty {lib}
stat -liberty {lib}
"""
    r = subprocess.run(['yosys', '-p', script], capture_output=True, text=True, timeout=120)
    return r.stdout + r.stderr

def parse_result(raw, cell_areas):
    lib_marker = 'Library "sky130_fd_sc_hd'
    idx = raw.find(lib_marker)
    post_lib = raw[idx:] if idx >= 0 else raw

    used_cells = {}
    for line in post_lib.splitlines():
        m = re.search(r'ABC RESULTS:\s+(sky130_fd_sc_hd__\w+) cells:\s+(\d+)', line)
        if m:
            used_cells[m.group(1)] = int(m.group(2))

    am = re.search(r'Chip area for (?:top\s+)?module[^:]*:\s*([\d.]+)', raw)
    chip_area = float(am.group(1)) if am else None
    computed  = sum(cell_areas.get(c, 0) * n for c, n in used_cells.items())
    return used_cells, chip_area or computed

def main():
    lib = find_lib()
    if not lib:
        print("ERROR: Sky130 liberty file not found.")
        print("Install volare: pip3 install --user volare")
        print("Fetch PDK:      python3 -m volare fetch --pdk sky130 c6d73a35...")
        sys.exit(1)

    print(f"  Liberty: {lib}")
    print(f"  NAND2_1 reference = {NAND2_AREA} µm²\n")

    cell_areas = parse_lib_areas(lib)

    CIRCUITS = [
        ('nfe_add_frac', SYNTH_DIR / 'nfe_add_frac.v', 'Standard NFE ADD_FRAC'),
        ('blk_add_9',    SYNTH_DIR / 'blk_add_9.v',    'Block 9-bit ADD (chain)'),
        ('blk_add_17',   SYNTH_DIR / 'blk_add_17.v',   'Block 17-bit ADD (matvec)'),
    ]

    results = {}
    for top, vf, lbl in CIRCUITS:
        raw = synth(str(vf), top, lib)
        cells_used, area = parse_result(raw, cell_areas)
        ge = area / NAND2_AREA
        results[top] = {'area': area, 'ge': ge, 'cells': cells_used, 'label': lbl}

        print(f'{"="*68}')
        print(f'  {lbl}')
        print(f'{"="*68}')
        total = sum(cells_used.values())
        print(f'  {"Cell":<40} {"ct":>4}  {"unit µm²":>9}  {"total µm²":>10}  {"GE":>6}')
        print(f'  {"-"*40} {"-"*4}  {"-"*9}  {"-"*10}  {"-"*6}')
        for cn in sorted(cells_used):
            cnt = cells_used[cn]
            unit = cell_areas.get(cn, 0)
            tot = unit * cnt
            print(f'  {cn:<40} {cnt:>4}  {unit:>9.4f}  {tot:>10.4f}  {tot/NAND2_AREA:>6.2f}')
        print(f'  {"-"*40} {"-"*4}  {"-"*9}  {"-"*10}  {"-"*6}')
        print(f'  {"TOTAL":<40} {total:>4}  {"":>9}  {area:>10.4f}  {ge:>6.2f}\n')

    # Summary
    add_ge  = results['nfe_add_frac']['ge']
    blk9_ge = results['blk_add_9']['ge']
    blk17_ge= results['blk_add_17']['ge']

    DEPTH, N_NORM, NORM9, NORM17 = 1024, 64, 81, 117
    MUL_STD, MUL_BLK = 265, 197
    N_MUL, N_ADD, N_NM = 64, 56, 8
    DM_B, DM_I = 9, 16

    def gu(g): return g / add_ge

    chain_saving = (1 - (DEPTH * gu(blk9_ge) + N_NORM * gu(NORM9)) / DEPTH) * 100
    gw_s_mv = N_MUL * gu(MUL_STD) + N_ADD
    gw_b_mv = N_MUL * gu(MUL_BLK) + N_ADD * gu(blk17_ge) + N_NM * gu(NORM17)
    d = gw_b_mv - gw_s_mv

    print(f'{"="*68}')
    print(f'  SUMMARY')
    print(f'{"="*68}')
    print(f'  std NFE ADD  : {results["nfe_add_frac"]["area"]:.4f} µm² = {add_ge:.2f} GE  '
          f'({sum(results["nfe_add_frac"]["cells"].values())} cells)')
    print(f'  blk9 ADD     : {results["blk_add_9"]["area"]:.4f} µm² = {blk9_ge:.2f} GE  '
          f'({sum(results["blk_add_9"]["cells"].values())} cells)')
    print(f'  blk17 ADD    : {results["blk_add_17"]["area"]:.4f} µm² = {blk17_ge:.2f} GE  '
          f'({sum(results["blk_add_17"]["cells"].values())} cells)')
    print(f'  Chain saving : {chain_saving:.2f}%')
    print(f'  Matvec Δgw   : {d:+.2f}')
    if d < 0:
        print(f'  Breakeven α  : {-d/DM_B:.2f} (bcast +{DM_B})  /  {-d/DM_I:.2f} (indep +{DM_I})')

if __name__ == '__main__':
    main()
