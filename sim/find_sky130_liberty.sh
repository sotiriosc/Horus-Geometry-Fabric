#!/usr/bin/env bash
# Resolve Sky130 HD TT 025C 1v80 liberty for Yosys synthesis scripts.
# Prints the path on stdout; exits 0 if found, 1 if not.

set -euo pipefail

LIB_NAME="sky130_fd_sc_hd__tt_025C_1v80.lib"

try_file() {
    if [ -n "${1:-}" ] && [ -f "$1" ]; then
        echo "$1"
        exit 0
    fi
}

try_file "${SKY130_HD_LIB:-}"

if [ -n "${PDK_ROOT:-}" ]; then
    try_file "$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib/$LIB_NAME"
fi

if [ -d "${HOME}/.volare/volare/sky130/versions" ]; then
    for base in "$HOME"/.volare/volare/sky130/versions/*; do
        try_file "$base/sky130A/libs.ref/sky130_fd_sc_hd/lib/$LIB_NAME"
    done
fi

for candidate in \
    /usr/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/$LIB_NAME \
    /opt/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/$LIB_NAME; do
    try_file "$candidate"
done

exit 1
