#!/usr/bin/env python3
"""
sim/tile_v2_golden.py — Golden vector generation for horus_tile_v2.

Tile v2 is the respecified tile from docs/TILE_RESULTS.md: multipliers +
shims + registered mode only. No buffer, no normalizer instance. The
expected output per operand pair is therefore the per-pair shimmed NFE-13
product — NOT the normalized block output of v1.

Sources of truth (unchanged):
  - Operands:  sim/TILE_E4M3_OPS.hex, sim/TILE_E3M6_OPS.hex (same 1000-pair
               sets that gate v1; K2 golden sets routed through v2 ports)
  - Multiply:  dual_core_model.dual_core_mul (bit-exact per mode)
  - Shims:     tile_model.shim_e4m3_to_nfe13 / shim_e3m6_to_nfe13
               (verified standalone in tile_model.py)

Outputs:
  sim/TILE_V2_E4M3_OUT.hex — 1000 × 13-bit NFE-13 expected shim outputs
  sim/TILE_V2_E3M6_OUT.hex — 1000 × 13-bit NFE-13 expected shim outputs
"""

import os
import sys

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)

from dual_core_model import dual_core_mul
from tile_model import shim_e4m3_to_nfe13, shim_e3m6_to_nfe13


def _read_ops(fname: str, width_hex: int):
    with open(os.path.join(DIR, fname)) as f:
        return [int(line.strip(), 16) for line in f if line.strip()]


def main():
    # E4M3: 16-bit words {a[7:0], b[7:0]}
    ops_e4 = _read_ops("TILE_E4M3_OPS.hex", 4)
    out_e4 = []
    for w in ops_e4:
        a = (w >> 8) & 0xFF
        b = w & 0xFF
        prod = dual_core_mul(a, b, mode=1)
        out_e4.append(shim_e4m3_to_nfe13(prod))

    # E3M6: 20-bit words {a[9:0], b[9:0]}
    ops_e3 = _read_ops("TILE_E3M6_OPS.hex", 5)
    out_e3 = []
    for w in ops_e3:
        a = (w >> 10) & 0x3FF
        b = w & 0x3FF
        prod = dual_core_mul(a, b, mode=0)
        out_e3.append(shim_e3m6_to_nfe13(prod))

    with open(os.path.join(DIR, "TILE_V2_E4M3_OUT.hex"), "w") as f:
        f.write("\n".join(f"{cw:04X}" for cw in out_e4) + "\n")
    with open(os.path.join(DIR, "TILE_V2_E3M6_OUT.hex"), "w") as f:
        f.write("\n".join(f"{cw:04X}" for cw in out_e3) + "\n")

    print(f"  TILE_V2_E4M3_OUT.hex: {len(out_e4)} expected shim outputs")
    print(f"  TILE_V2_E3M6_OUT.hex: {len(out_e3)} expected shim outputs")


if __name__ == "__main__":
    main()
