`timescale 1ns / 1ps
// ============================================================================
// Module   : horus_controller
// Project  : Horus Engine
// File     : horus_controller.v
//
// Purpose
//   One-hot Moore FSM that automates a single computation window across the
//   4×4 horus_systolic_array.  The controller sequences four phases:
//   accumulator clear, pipeline fill + accumulation, result flush, and host
//   handshake — matching the accumulator protocol defined in horus_nfe.v and
//   horus_systolic_array.v exactly.
//
// ─────────────────────────────────────────────────────────────────────────────
// State Machine Diagram
// ─────────────────────────────────────────────────────────────────────────────
//
//              ┌──────────────────────────────────────────────────┐
//              │  result_ack                                       │
//              ▼                                                    │
//   ┌─────────────────┐  start_compute  ┌──────────────────────┐  │
//   │   IDLE (0001)   │────────────────►│    SETUP (0010)      │  │
//   │  All outputs=0  │                 │  accum_clr=1  1 cyc  │  │
//   └─────────────────┘                 └──────────────────────┘  │
//                                                 │                │
//                                           (next cycle)          │
//                                                 ▼                │
//                                       ┌─────────────────────┐   │
//                                       │   STREAM (0100)     │   │
//                                       │  accum_en=1  7 cyc  │   │
//                                       │  cycle_cnt: 0 → 6   │   │
//                                       └─────────────────────┘   │
//                                                 │                │
//                                     cycle_cnt == FILL_CYCLES     │
//                                                 ▼                │
//                                       ┌─────────────────────┐   │
//                                       │    READY (1000)     │───┘
//                                       │  data_valid=1       │
//                                       │  (NOP flush cycle)  │
//                                       └─────────────────────┘
//
// ─────────────────────────────────────────────────────────────────────────────
// Output Truth Table  (Moore — decoded purely from the state register)
// ─────────────────────────────────────────────────────────────────────────────
//   State   │  accum_clr  │  accum_en  │  data_valid
//  ─────────┼─────────────┼────────────┼────────────
//   IDLE    │      0      │      0     │      0
//   SETUP   │      1      │      0     │      0      ← clears all 16 PE accum_regs
//   STREAM  │      0      │      1     │      0      ← PE products fold into accum_reg
//   READY   │      0      │      0     │      1      ← NOP flush + host read window
//
// ─────────────────────────────────────────────────────────────────────────────
// Cycle-Accurate Timing Model
// ─────────────────────────────────────────────────────────────────────────────
//  The timing below is relative to the cycle when start_compute is sampled.
//
//  +-------+--------+-----------+-----------+----------+------------+
//  | Cycle | State  | cycle_cnt | accum_clr | accum_en | data_valid |
//  +-------+--------+-----------+-----------+----------+------------+
//  |   0   | IDLE   |     —     |     0     |     0    |     0      |  ← start_compute seen
//  |   1   | SETUP  |     0     |     1     |     0    |     0      |  ← accum_reg ← 0
//  |   2   | STREAM |     0     |     0     |     1    |     0      |  ← fill begin; PE[0,0] ✓
//  |   3   | STREAM |     1     |     0     |     1    |     0      |  ← PE[0,1], PE[1,0] ✓
//  |   4   | STREAM |     2     |     0     |     1    |     0      |  ← PE[0,2]..PE[2,0] ✓
//  |   5   | STREAM |     3     |     0     |     1    |     0      |  ← PE[0,3]..PE[3,0] ✓ (full fill)
//  |   6   | STREAM |     4     |     0     |     1    |     0      |  ← steady-state accum
//  |   7   | STREAM |     5     |     0     |     1    |     0      |  ← steady-state accum
//  |   8   | STREAM |     6     |     0     |     1    |     0      |  ← last STREAM cycle
//  |   9   | READY  |     —     |     0     |     0    |     1      |  ← NOP: accum_out ← accum_reg
//  +-------+--------+-----------+-----------+----------+------------+
//
//  READY acts as both the mandatory NOP flush cycle required by horus_nfe
//  (accum_out <= accum_reg requires one accum_en=0 cycle to capture the final
//  accumulated value — see horus_nfe.v line 319) and the host read window
//  where row_out_0..3 are stable.  The host samples during READY and ACKs.
//
// ─────────────────────────────────────────────────────────────────────────────
// Implementation: 3-Process Moore FSM
// ─────────────────────────────────────────────────────────────────────────────
//  Process 1 — Sequential : clocks state register + cycle_cnt
//  Process 2 — Comb-NSL   : next-state logic (pure combinational)
//  Process 3 — Comb-OFL   : output decode (pure combinational from state)
//
//  Three-process style separates concerns cleanly and allows synthesis tools
//  to freely retime state registers without disturbing the output decode path.
// ============================================================================

// ── Depth-Monitor: Flow Control (decoupled from data flit) ───────────────────
//
// The controller maintains a `depth_counter` that counts individual
// STREAM-cycle MAC accumulations across the current computation window.
// When `depth_counter` equals `max_depth` (host-configurable, 0 = disabled)
// the controller pulses `depth_reset` for exactly one cycle to trigger an
// automatic accumulator clear on the connected systolic array.
//
// This keeps Snapshot/Reset firmly in the **control plane** — it is triggered
// by cycle counting in the FSM, never by a data-flit bit.  The data path remains
// algebraically pure between depth boundaries.
//
// Depth counter semantics:
//   • Increments every cycle that `state == STREAM` (i.e. every real MAC cycle).
//   • Resets to zero whenever `depth_reset` fires or `state` leaves STREAM.
//   • `max_depth == 0` disables the monitor (no automatic resets).
//   • Minimum useful value: 4 (shallow-chain boundary per Test 10A).
//   • Recommended mid-range: 8–30.  Values ≥ 30 permit deep-chain floor regime.
// ─────────────────────────────────────────────────────────────────────────────

module horus_controller (
    input  wire       clk,
    input  wire       rst_n,           // Active-low asynchronous reset

    // ── Host handshake ────────────────────────────────────────────────────────
    input  wire       start_compute,   // Pulse: "begin a new computation window"
    input  wire       result_ack,      // Pulse: "row_out data latched; return to IDLE"

    // ── Depth-Monitor configuration (Flow Control) ────────────────────────────
    // max_depth : 6-bit threshold for automatic accumulator reset.
    //             0 = disabled.  Non-zero: fires depth_reset when
    //             depth_counter == max_depth during STREAM.
    input  wire [5:0] max_depth,

    // ── Systolic array control ────────────────────────────────────────────────
    output reg        accum_clr,       // 1-cycle high in SETUP or depth_reset
    output reg        accum_en,        // 7-cycle high in STREAM

    // ── Depth-Monitor status ──────────────────────────────────────────────────
    output reg        depth_reset,     // 1-cycle pulse: depth_counter hit max_depth
                                       // Route to accum_clr on the array; the
                                       // Depth-Monitor auto-clears depth_counter.

    // ── Host status ───────────────────────────────────────────────────────────
    output reg        data_valid       // High during READY
);

    // =========================================================================
    // One-Hot State Parameters
    // ─────────────────────────────────────────────────────────────────────────
    // One-hot encoding is chosen for three reasons:
    //   (a) The state bit maps 1:1 to each output signal — SETUP[1] directly
    //       drives accum_clr, STREAM[2] drives accum_en, READY[3] drives
    //       data_valid — reducing decode to a single wire tap.
    //   (b) FPGA synthesisers recognise one-hot and avoid inserting priority
    //       encoders between the state register and the output mux.
    //   (c) Any single-bit fault leaves exactly zero or two bits set, making
    //       fault detection trivial via a parity or popcount check.
    // =========================================================================
    localparam [3:0] IDLE   = 4'b0001;  // Quiescent; await start_compute
    localparam [3:0] SETUP  = 4'b0010;  // Assert accum_clr for exactly 1 cycle
    localparam [3:0] STREAM = 4'b0100;  // Assert accum_en; count 7 fill cycles
    localparam [3:0] READY  = 4'b1000;  // NOP flush + assert data_valid

    // =========================================================================
    // Pipeline Fill Latency Constant
    // ─────────────────────────────────────────────────────────────────────────
    // The 4×4 array has a worst-case activation + weight propagation depth of
    // max(ROWS-1, COLS-1) = 3 pipeline hops (the two shift fabrics fill in
    // parallel).  All 16 PEs first see valid coincident data at STREAM cycle 4
    // (cycle_cnt = 3).  STREAM continues for 3 additional accumulation cycles
    // (cycle_cnt 4, 5, 6) to build up a multi-sample dot product.
    //
    // Adjust FILL_CYCLES upward to extend the accumulation window; the 3-bit
    // cycle_cnt supports a maximum of FILL_CYCLES = 7 (8 STREAM cycles).
    // =========================================================================
    localparam [2:0] FILL_CYCLES = 3'd6;  // STREAM exits when cycle_cnt reaches this

    // =========================================================================
    // Registers
    // =========================================================================
    reg [3:0] state;          // Current one-hot state register
    reg [3:0] next_state;     // Combinational next-state wire (driven by Process 2)
    reg [2:0] cycle_cnt;      // 3-bit pipeline fill counter; active only in STREAM
    reg [5:0] depth_counter;  // Depth-Monitor MAC accumulation counter

    // =========================================================================
    // Process 1 — State register and cycle counter  (sequential)
    // ─────────────────────────────────────────────────────────────────────────
    // On every rising clock edge:
    //   • The state register captures next_state (computed by Process 2).
    //   • cycle_cnt increments while the machine is in STREAM and holds zero
    //     in all other states, guaranteeing that each new STREAM phase always
    //     starts counting from zero regardless of how long READY or IDLE last.
    //
    // Reset is asynchronous-active-low, matching the horus_nfe and
    // horus_systolic_array reset polarity so all three modules de-assert rst_n
    // simultaneously.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            cycle_cnt     <= 3'd0;
            depth_counter <= 6'd0;
        end else begin
            state <= next_state;

            // cycle_cnt: free-run only inside STREAM; reset everywhere else.
            if (state == STREAM)
                cycle_cnt <= cycle_cnt + 3'd1;
            else
                cycle_cnt <= 3'd0;

            // ── Depth-Monitor counter ──────────────────────────────────────────
            // Counts MAC cycles inside STREAM.  Resets on:
            //   • depth_reset fire this cycle (monitor threshold met)
            //   • Leaving STREAM (window boundary)
            //   • Global reset
            if (state == STREAM) begin
                if ((max_depth != 6'd0) && (depth_counter == max_depth))
                    depth_counter <= 6'd0;    // Reset: depth boundary hit
                else
                    depth_counter <= depth_counter + 6'd1;
            end else begin
                depth_counter <= 6'd0;
            end
        end
    end

    // =========================================================================
    // Process 2 — Next-State Logic  (combinational)
    // ─────────────────────────────────────────────────────────────────────────
    // Pure combinational decode of {state, cycle_cnt, start_compute, result_ack}.
    // The default assignment "next_state = state" implements the implicit
    // self-loop on every state, so only transitions that differ from hold need
    // explicit encoding.  The default case snaps any illegal one-hot pattern
    // back to IDLE for fault recovery.
    // =========================================================================
    always @(*) begin
        next_state = state;  // Default: hold current state

        case (state)

            IDLE: begin
                // Wait for the host to initiate a computation window.
                // start_compute may be held high; the FSM accepts it on the
                // first cycle it is seen (level-sensitive, not edge-triggered).
                if (start_compute)
                    next_state = SETUP;
            end

            SETUP: begin
                // Unconditional 1-cycle clear.  Advance to STREAM on the very
                // next clock regardless of any input signal.  The horus_nfe
                // accum_clr path has priority over accum_en inside each PE, so
                // accumulators are guaranteed clean before STREAM begins.
                next_state = STREAM;
            end

            STREAM: begin
                // Remain in STREAM until the fill counter expires.
                // cycle_cnt is evaluated against the PRE-clock value here
                // (combinational path), so the transition to READY is scheduled
                // during the cycle when cycle_cnt == FILL_CYCLES (the 7th STREAM
                // clock, 0-indexed), taking effect on the following posedge.
                if (cycle_cnt == FILL_CYCLES)
                    next_state = READY;
            end

            READY: begin
                // Hold data_valid high until the host acknowledges.
                // The host has one or more cycles to sample row_out_0..3 before
                // issuing result_ack.  On the cycle result_ack is sampled, the
                // FSM returns to IDLE on the next posedge.
                if (result_ack)
                    next_state = IDLE;
            end

            default: begin
                // Fault recovery: any illegal encoding → snap back to IDLE.
                // This prevents the FSM from locking up if radiation or a
                // synthesis bug corrupts the one-hot register.
                next_state = IDLE;
            end

        endcase
    end

    // =========================================================================
    // Process 3 — Output Logic  (combinational Moore decode)
    // ─────────────────────────────────────────────────────────────────────────
    // Outputs are decoded from the current state register ONLY — no input
    // signals appear here.  This is the defining property of a Moore machine:
    // output transitions are always aligned with state register updates
    // (synchronous clock edge), never with asynchronous input changes.
    //
    // Safe defaults (all inactive) are asserted first; the case statement
    // overrides exactly the signals that are active in each state.
    //
    // One-Hot shortcut: because each state bit corresponds to exactly one
    // output, an alternative equivalent implementation is:
    //   assign accum_clr  = state[1];   // SETUP bit
    //   assign accum_en   = state[2];   // STREAM bit
    //   assign data_valid = state[3];   // READY bit
    // The case statement below is retained for readability and to allow future
    // states with compound output patterns.
    // =========================================================================
    always @(*) begin
        // Inactive defaults — prevent latches; synthesis generates a mux tree.
        accum_clr   = 1'b0;
        accum_en    = 1'b0;
        depth_reset = 1'b0;
        data_valid  = 1'b0;

        case (state)

            IDLE: begin
                accum_clr   = 1'b0;
                accum_en    = 1'b0;
                depth_reset = 1'b0;
                data_valid  = 1'b0;
            end

            SETUP: begin
                // Pulse accum_clr for exactly 1 clock cycle to zero all PE
                // accumulators before a fresh computation window.
                accum_clr   = 1'b1;
                accum_en    = 1'b0;
                depth_reset = 1'b0;
                data_valid  = 1'b0;
            end

            STREAM: begin
                // Assert accum_en every STREAM cycle.
                //
                // Depth-Monitor: if max_depth is non-zero and depth_counter has
                // reached the threshold, simultaneously assert depth_reset and
                // accum_clr for ONE cycle.  accum_en is held HIGH so the MAC
                // pipeline does not stall — the clear takes effect atomically
                // (accum_clr has priority over accum_en inside horus_nfe).
                // The depth_counter resets to zero on this same clock edge
                // (Process 1 above), restarting the depth window immediately.
                if ((max_depth != 6'd0) && (depth_counter == max_depth)) begin
                    depth_reset = 1'b1;
                    accum_clr   = 1'b1;   // Snapshot-and-clear; control-plane only
                end else begin
                    depth_reset = 1'b0;
                    accum_clr   = 1'b0;
                end
                accum_en   = 1'b1;
                data_valid = 1'b0;
            end

            READY: begin
                accum_clr   = 1'b0;
                accum_en    = 1'b0;
                depth_reset = 1'b0;
                data_valid  = 1'b1;
            end

            default: begin
                accum_clr   = 1'b0;
                accum_en    = 1'b0;
                depth_reset = 1'b0;
                data_valid  = 1'b0;
            end

        endcase
    end

endmodule
