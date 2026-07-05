# =============================================================================
# Horus NFE — Simulation Makefile
# =============================================================================
#
# Run from this directory:  cd sim && make test
#
# Requirements: Icarus Verilog >= 11  (iverilog / vvp)
#               GCC or Clang          (C-model)
#               Python 3.8+           (analysis scripts; matplotlib for fidelity)
#
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
CC       ?= gcc
PYTHON   ?= python3

RTL      := ../rtl
TB       := ../tb
IVFLAGS  := -Wall -g2012
CFLAGS   := -O2

# -----------------------------------------------------------------------------
# RTL source groups
# -----------------------------------------------------------------------------
SRC_CORE     := $(RTL)/horus_nfe.v $(RTL)/horus_pgate_ctrl.v $(RTL)/horus_system.v
SRC_MESH     := $(RTL)/horus_router.v $(RTL)/horus_mesh_top.v
SRC_WRAPPER  := $(RTL)/horus_nfe_wrapper.v
SRC_SYSTOLIC := $(RTL)/horus_systolic_array.v $(RTL)/horus_controller.v \
                $(RTL)/horus_input_buffer.v $(RTL)/horus_top.v

# =============================================================================
.PHONY: all hbs11 hbs12 hbs13 hbs14 hbs_c2 hbs_c5 hbs_c6 hbs_c7 hbs_c8 hbs_c9 hbs_c13
all: sim_mesh
	@echo ""
	@echo "Running Horus Mesh Testbench (7/7 tests expected)..."
	@echo "-----------------------------------------------------"
	$(VVP) sim_mesh
	@echo ""
	@echo "Done. Check output above for PASS/FAIL counts."

# =============================================================================
# SIMULATION TARGETS
# =============================================================================

sim_mesh: $(TB)/tb_horus_mesh_top.v $(SRC_CORE) $(SRC_MESH)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_nfe: $(TB)/tb_horus_nfe.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_pgate: $(TB)/tb_horus_pgate_ctrl.v $(RTL)/horus_pgate_ctrl.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_router: $(TB)/tb_horus_router.v $(RTL)/horus_router.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_wrapper: $(TB)/tb_horus_nfe_wrapper.v $(SRC_WRAPPER) $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_system: $(TB)/tb_horus_system.v $(RTL)/horus_nfe.v $(SRC_SYSTOLIC) $(RTL)/horus_input_buffer.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_boundary: $(TB)/tb_boundary_stress.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_fidelity: $(TB)/tb_fidelity_benchmark.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_hbs: $(TB)/tb_hbs_core_stability.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: hbs_stability
hbs_stability: sim_hbs
	@echo ""
	@echo "Running HBS Core Stability Suite (failure mapping)..."
	$(VVP) sim_hbs
	@echo ""
	@echo "Logs: HBS_CORE_MASTER_INDEX.log + HBS_CORE_TEST_01..06_*.log"

sim_hfd: $(TB)/tb_horus_failure_domain.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_cancel: $(TB)/tb_horus_cancel_analysis.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_comp: $(TB)/tb_horus_composition_analysis.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# HBS-11 policy validation: horus_system + horus_controller only
sim_hbs11: $(TB)/tb_hbs11_policy_validation.v $(SRC_CORE) $(RTL)/horus_controller.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: hbs11
hbs11: sim_hbs11
	@echo ""
	@echo "Running HBS-11 Execution Policy Validation Suite..."
	$(VVP) sim_hbs11
	@echo ""
	$(PYTHON) analyze_hbs11.py
	@echo ""
	@echo "Output: HBS11_POLICY_VALIDATION.csv + HBS11_POLICY_SUMMARY.log"

# HBS-12 arithmetic boundary mapping: horus_system only (mode_tag=000)
sim_hbs12: $(TB)/tb_hbs12_arithmetic_boundary.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: hbs12
hbs12: sim_hbs12
	@echo ""
	@echo "Running HBS-12 Arithmetic Boundary Mapping Suite..."
	$(VVP) sim_hbs12
	@echo ""
	$(PYTHON) analyze_hbs12.py
	@echo ""
	@echo "Output: HBS12_ARITHMETIC_BOUNDARY.csv + HBS12_SUMMARY.log"

# HBS-13 boundary gap characterization: horus_system only (mode_tag=000)
sim_hbs13: $(TB)/tb_hbs13_boundary_gap.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: hbs13
hbs13: sim_hbs13
	@echo ""
	@echo "Running HBS-13 Boundary Gap Characterization Suite..."
	$(VVP) sim_hbs13
	@echo ""
	$(PYTHON) analyze_hbs13.py
	@echo ""
	@echo "Output: HBS13_BOUNDARY_GAP.csv + HBS13_SUMMARY.log"

.PHONY: failure_domain cancel_analysis composition_analysis
failure_domain: sim_hfd
	@echo ""
	@echo "Running HORUS Failure-Domain Analysis..."
	$(VVP) sim_hfd
	@echo ""
	@echo "Output: HORUS_WEAKNESS_MAP.log + HFD_TEST_01..06_*.log"

cancel_analysis: sim_cancel
	@echo ""
	@echo "Running TEST 9 cancellation structure study..."
	$(VVP) sim_cancel
	@echo ""
	$(PYTHON) analyze_cancellation.py
	@echo ""
	@echo "Output: cancel_analysis.csv + TEST_09_SUMMARY.log"

composition_analysis: sim_comp
	@echo ""
	@echo "Running TEST 10 composition stress study..."
	$(VVP) sim_comp
	@echo ""
	$(PYTHON) analyze_composition.py
	@echo ""
	@echo "Output: composition_analysis.csv + TEST_10_SUMMARY.log"

# =============================================================================
.PHONY: test
test: sim_nfe sim_pgate sim_router sim_wrapper sim_mesh
	@echo ""
	@echo "======================================================"
	@echo "  Horus NFE — Full Simulation Suite"
	@echo "======================================================"
	@echo ""
	@echo "[1/5] NFE arithmetic core (4/4 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_nfe
	@echo ""
	@echo "[2/5] Power-gate controller (3/3 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_pgate
	@echo ""
	@echo "[3/5] XY Router (8/8 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_router
	@echo ""
	@echo "[4/5] Tile-depth wrapper (4/4 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_wrapper
	@echo ""
	@echo "[5/5] 2-D Mesh top (7/7 tests)"
	@echo "------------------------------------------------------"
	$(VVP) sim_mesh
	@echo ""
	@echo "======================================================"
	@echo "  26 tests expected total. Review output above."
	@echo "======================================================"

# =============================================================================
.PHONY: sim_c
sim_c: horus_sim
	@echo ""
	@echo "Running C-model (10M iterations per operation)..."
	./horus_sim

horus_sim: horus_sim.c
	$(CC) $(CFLAGS) -o $@ $< -lm

# -----------------------------------------------------------------------------
# NFE deployment review (July 2026) — C-model matvec + ABMP tests
# See sim/README.md and docs/NFE_DEPLOYMENT_REVIEW.md
# -----------------------------------------------------------------------------
NFE_REVIEW_SRCS := nfe_matvec.c nfe_matvec2.c abmp_epoch_test.c \
                   abmp_blast_radius.c abmp_k128_test.c abmp_norm_fires.c

.PHONY: nfe_matvec nfe_matvec2 abmp_epoch_test abmp_blast_radius \
        abmp_k128_test abmp_norm_fires deployment_review

nfe_matvec: nfe_matvec.c
	$(CC) $(CFLAGS) -o $@ $< -lm

nfe_matvec2: nfe_matvec2.c
	$(CC) $(CFLAGS) -o $@ $< -lm

abmp_epoch_test: abmp_epoch_test.c
	$(CC) $(CFLAGS) -o $@ $< -lm

abmp_blast_radius: abmp_blast_radius.c
	$(CC) $(CFLAGS) -o $@ $< -lm

abmp_k128_test: abmp_k128_test.c
	$(CC) $(CFLAGS) -o $@ $< -lm

abmp_norm_fires: abmp_norm_fires.c
	$(CC) $(CFLAGS) -o $@ $< -lm

deployment_review: nfe_matvec nfe_matvec2 abmp_epoch_test abmp_blast_radius \
                   abmp_k128_test abmp_norm_fires
	@echo ""
	@echo "======================================================"
	@echo "  NFE Deployment Review — C-model test suite"
	@echo "======================================================"
	@echo ""
	@echo "[1/6] 8×8 matvec baseline"
	@echo "------------------------------------------------------"
	./nfe_matvec
	@echo ""
	@echo "[2/6] Dual-path routed matvec"
	@echo "------------------------------------------------------"
	./nfe_matvec2
	@echo ""
	@echo "[3/6] ABMP epoch snapshot test"
	@echo "------------------------------------------------------"
	./abmp_epoch_test
	@echo ""
	@echo "[4/6] ABMP blast radius (K=8)"
	@echo "------------------------------------------------------"
	./abmp_blast_radius
	@echo ""
	@echo "[5/6] K=128 HBS-1 reduction"
	@echo "------------------------------------------------------"
	./abmp_k128_test
	@echo ""
	@echo "[6/6] Forced normalization at boundary"
	@echo "------------------------------------------------------"
	./abmp_norm_fires
	@echo ""
	@echo "Full findings: docs/NFE_DEPLOYMENT_REVIEW.md"

.PHONY: fidelity
fidelity: sim_fidelity
	@echo ""
	@echo "Running 1024-cycle fidelity benchmark..."
	$(VVP) sim_fidelity
	@echo ""
	$(PYTHON) analyze_fidelity.py

# ── Second-source chain RTL confirmation (July 2026) ─────────────────────────
# Runs y ← A·y feedback chains through horus_nfe.v (3 regimes × 256 cycles).
# Confirms/falsifies predictions from sim/second_source_chain.py.
# RTL path: PATH_NFE only (6-bit-quantized MUL, horus_nfe.v lines 494-536).
# Output: SSC_CHAIN_TRACE.csv + analyze_second_source_chain.py verdicts.
sim_ssc_chain: $(TB)/tb_second_source_chain.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: ssc_chain
ssc_chain: sim_ssc_chain
	@echo ""
	@echo "Running second-source chain RTL confirmation..."
	@echo "  3 regimes (contractive/neutral/expansive) × 256 depth cycles"
	$(VVP) sim_ssc_chain
	@echo ""
	$(PYTHON) analyze_second_source_chain.py
	@echo ""
	@echo "Output: SSC_CHAIN_TRACE.csv"

# ── PATH_FAST Synthesis Comparison ───────────────────────────────────────────
# Functional check: neutral-regime 256-cycle chain through horus_nfe_pf.v.
# Requires: horus_nfe_pf.v in rtl/  (created by the PF synthesis campaign).
# Synthesis: Sky130 HD TT 025C 1v80; yosys 0.9+.
# Timing: not measured (OpenSTA not installed).

YOSYS ?= yosys

sim_pf_check: $(TB)/tb_horus_nfe_pf.v $(RTL)/horus_nfe_pf.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: pf_check
pf_check: sim_pf_check
	@echo ""
	@echo "Running PATH_FAST functional check (neutral regime, 256 cycles)..."
	$(VVP) sim_pf_check
	@echo ""

.PHONY: synth_baseline
synth_baseline:
	@echo ""
	@echo "Synthesizing horus_nfe (baseline) against Sky130 HD..."
	$(YOSYS) -Q synth_nfe_baseline.ys 2>&1 | tee SYNTH_NFE_BASELINE.log
	@echo ""
	@echo "Output: SYNTH_NFE_BASELINE.log"
	@echo ""

.PHONY: synth_pf
synth_pf:
	@echo ""
	@echo "Synthesizing horus_nfe_pf (PATH_FAST) against Sky130 HD..."
	$(YOSYS) -Q synth_nfe_pf.ys 2>&1 | tee SYNTH_NFE_PF.log
	@echo ""
	@echo "Output: SYNTH_NFE_PF.log"
	@echo ""

.PHONY: pf_comparison
pf_comparison: pf_check synth_baseline synth_pf
	@echo ""
	@echo "PATH_FAST synthesis comparison complete."
	@echo "See: docs/PF_SYNTHESIS_COMPARISON.md"
	@echo ""

# =============================================================================
# Task 1 — System-level area denominator (horus_top: 16×horus_nfe + controller)
# =============================================================================

.PHONY: synth_top_baseline
synth_top_baseline:
	@echo ""
	@echo "Synthesizing horus_top (baseline) against Sky130 HD..."
	$(YOSYS) -Q synth_top_baseline.ys 2>&1 | tee SYNTH_TOP_BASELINE.log
	@echo ""
	@echo "Output: SYNTH_TOP_BASELINE.log"
	@echo ""

.PHONY: synth_top_pf
synth_top_pf:
	@echo ""
	@echo "Synthesizing horus_top (PATH_FAST) against Sky130 HD..."
	$(YOSYS) -Q synth_top_pf.ys 2>&1 | tee SYNTH_TOP_PF.log
	@echo ""
	@echo "Output: SYNTH_TOP_PF.log"
	@echo ""

.PHONY: sys_area
sys_area: synth_top_baseline synth_top_pf
	@echo ""
	@echo "System-level area comparison complete."
	@echo "See: SYNTH_TOP_BASELINE.log  SYNTH_TOP_PF.log"
	@echo ""

# =============================================================================
# Task 2 — Accumulator width sweep (Python model)
# =============================================================================

.PHONY: width_sweep
width_sweep:
	@echo ""
	@echo "Running PATH_FAST accumulator width sweep..."
	$(PYTHON) pf_width_sweep.py
	@echo ""

# =============================================================================
# Task 3 — Spot-check: RTL vs Python error trajectory
# pf_check must run first to generate PF_RTL_TRACE.csv
# =============================================================================

sim_pf_trace: $(TB)/tb_horus_nfe_pf.v $(RTL)/horus_nfe_pf.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: pf_spotcheck
pf_spotcheck: sim_pf_trace
	@echo ""
	@echo "Running PATH_FAST testbench (generates PF_RTL_TRACE.csv)..."
	$(VVP) sim_pf_trace
	@echo ""
	@echo "Running Python spot-check overlay..."
	$(PYTHON) pf_spotcheck.py
	@echo ""

# =============================================================================
# de-risk bundle: Tasks 1-3 in order
# =============================================================================

.PHONY: pf_derisk
pf_derisk: sys_area width_sweep pf_spotcheck
	@echo ""
	@echo "PATH_FAST de-risk tasks 1-3 complete."
	@echo "See: docs/PF_DECISION_INPUTS.md (to be written after reviewing outputs)"
	@echo ""

# =============================================================================
# PF18 — W=18 accumulator variant functional check and synthesis
# =============================================================================

sim_pf18_check: $(TB)/tb_horus_nfe_pf18.v $(RTL)/horus_nfe_pf18.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

.PHONY: pf18_check
pf18_check: sim_pf18_check
	@echo ""
	@echo "Running PF18 functional check (neutral + expansive regime, 256 cycles)..."
	$(VVP) sim_pf18_check
	@echo ""

.PHONY: synth_pf18
synth_pf18:
	@echo ""
	@echo "Synthesizing horus_nfe_pf18 (W=18) against Sky130 HD..."
	$(YOSYS) -Q synth_nfe_pf18.ys 2>&1 | tee SYNTH_NFE_PF18.log
	@echo ""
	@echo "Output: SYNTH_NFE_PF18.log"
	@echo ""

.PHONY: synth_top_pf18
synth_top_pf18:
	@echo ""
	@echo "Synthesizing horus_top (PF18) against Sky130 HD..."
	$(YOSYS) -Q synth_top_pf18.ys 2>&1 | tee SYNTH_TOP_PF18.log
	@echo ""
	@echo "Output: SYNTH_TOP_PF18.log"
	@echo ""

.PHONY: pf18_synth
pf18_synth: synth_pf18 synth_top_pf18
	@echo ""
	@echo "PF18 synthesis complete. See: SYNTH_NFE_PF18.log  SYNTH_TOP_PF18.log"
	@echo ""

.PHONY: pf18
pf18: pf18_check pf18_synth
	@echo ""
	@echo "PF18 tasks complete. See: docs/PF_DECISION_INPUTS.md"
	@echo ""

.PHONY: analysis
analysis:
	@echo "Running NFE precision analysis..."
	$(PYTHON) horus_nfe_analysis.py

# =============================================================================
.PHONY: wave_mesh wave_router wave_nfe
wave_mesh: sim_mesh
	$(VVP) sim_mesh
	gtkwave tb_horus_mesh_top.vcd &

wave_router: sim_router
	$(VVP) sim_router
	gtkwave tb_horus_router.vcd &

wave_nfe: sim_nfe
	$(VVP) sim_nfe
	gtkwave dump.vcd &

.PHONY: clean
clean:
	rm -f sim_nfe sim_pgate sim_router sim_wrapper sim_mesh sim_system \
	      sim_fidelity sim_boundary sim_hbs sim_hfd sim_cancel sim_comp horus_sim \
	      nfe_matvec nfe_matvec2 abmp_epoch_test abmp_blast_radius \
	      abmp_k128_test abmp_norm_fires
	rm -f *.vcd fidelity_benchmark.csv fidelity_plot.png fidelity_error_plot.png \
	      sim_ssc_chain SSC_CHAIN_TRACE.csv
	rm -f sim_pf_check SYNTH_NFE_BASELINE.log SYNTH_NFE_PF.log
	rm -f sim_pf_trace PF_RTL_TRACE.csv
	rm -f SYNTH_TOP_BASELINE.log SYNTH_TOP_PF.log
	rm -f HBS_CORE_*.log HFD_TEST_*.log HORUS_WEAKNESS_MAP.log
	rm -f HBS11_POLICY_VALIDATION.csv HBS11_POLICY_SUMMARY.log sim_hbs11
	rm -f HBS12_ARITHMETIC_BOUNDARY.csv HBS12_SUMMARY.log sim_hbs12
	rm -f HBS13_BOUNDARY_GAP.csv HBS13_SUMMARY.log sim_hbs13
	rm -f HBS14_SYSTEM_INTEGRATION.csv HBS14_SUMMARY.log sim_hbs14
	rm -f HBS_C2_LIVE_SIM.csv HBS_C2_LIVE_SUMMARY.log sim_hbs_c2 \
	      hbs_c2_state_space_ascii.txt hbs_c2_e_density.png \
	      hbs_c2_uf_ovf_timeline.png hbs_c2_accum_drift.png hbs_c2_mode_region_hm.png
	rm -f HBS_C5_KERNEL_STRESS.csv HBS_C5_KERNEL_SUMMARY.log sim_hbs_c5 \
	      hbs_c5_mode_surface_classA.png hbs_c5_mode_surface_classB.png \
	      hbs_c5_mode_surface_classC.png hbs_c5_mode_surface_classD.png \
	      hbs_c5_mode_surface_all.png hbs_c5_action_manifold.png
	rm -f HBS_C6_REAL_WORLD.csv HBS_C6_SUMMARY.log sim_hbs_c6 \
	      hbs_c6_workload_heatmap.png hbs_c6_collapse_exposure.png \
	      hbs_c6_cancellation_drift.png hbs_c6_deepchain_degradation.png
	rm -f HBS_C7_FAILURE_DOMAIN.csv HBS_C7_SUMMARY.log sim_hbs_c7 \
	      hbs_c7_failure_heatmap.png hbs_c7_r2_exponent_drift.png \
	      hbs_c7_r1_residual_growth.png hbs_c7_recovery_comparison.png
	rm -f HBS_C8_ATTRACTOR_MODEL.csv HBS_C8_SUMMARY.log HBS_C8_PHASE_SPACE.png
	rm -f HBS_C9_SINGULARITY.csv HBS_C9_SUMMARY.log sim_hbs_c9 \
	      hbs_c9_attractor_timeline.png hbs_c9_s1d_e_sawtooth.png \
	      hbs_c9_tti_distribution.png hbs_c9_phase_trajectory.png
	@echo "Cleaned generated binaries and artifacts."

.PHONY: help
help:
	@echo ""
	@echo "Horus NFE — Simulation targets (run from sim/)"
	@echo "----------------------------------------------"
	@echo "  make              Mesh testbench (7/7, default)"
	@echo "  make test         Full suite (26/26)"
	@echo "  make fidelity     1024-cycle fidelity benchmark + plots"
	@echo "  make sim_c        C-model 10M-iteration proof"
	@echo "  make deployment_review  NFE matvec + ABMP review suite (6 tests)"
	@echo "  make analysis     Python precision analysis"
	@echo "  make sim_boundary Boundary-stress testbench"
	@echo "  make failure_domain HORUS failure-domain analysis (6 tests)"
	@echo "  make hbs_stability  HBS core failure-mapping suite (6 tests)"
	@echo "  make cancel_analysis  TEST 9 cancellation residual study"
	@echo "  make composition_analysis TEST 10 composition stress study"
	@echo "  make hbs11            HBS-11 execution policy validation suite"
	@echo "  make hbs12            HBS-12 arithmetic boundary mapping suite"
	@echo "  make hbs13            HBS-13 boundary gap characterization suite"
	@echo "  make hbs14            HBS-14 end-to-end system consistency suite"
	@echo "  make hbs_c2           HBS-C2 live system observation harness"
	@echo "  make hbs_c5           HBS-C5 C4 kernel decision surface stress-test"
	@echo "  make hbs_c6           HBS-C6 adversarial real-world workload stress-test"
	@echo "  make hbs_c7           HBS-C7 failure-domain isolation suite"
	@echo "  make hbs_c8           HBS-C8 attractor decomposition and phase-space reduction"
	@echo "  make hbs_c9           HBS-C9 singularity validation (C8 falsification attempt)"
	@echo "  make hbs_c10          HBS-C10 predictive validation (attractor model accuracy)"
	@echo "  make hbs_c12          HBS-C12 adversarial reality collapse suite"
	@echo "  make hbs_c13          HBS-C13 attractor controllability & phase steering suite"
	@echo "  make hbs_c14          HBS-C14 attractor-to-computation synthesis suite"

# HBS-14 end-to-end system consistency: horus_system + horus_systolic_array
sim_hbs14: $(TB)/tb_hbs14_system_integration.v $(SRC_CORE) $(RTL)/horus_systolic_array.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs14: sim_hbs14
	@echo ""
	@echo "Running HBS-14 End-to-End System Consistency Suite..."
	$(VVP) sim_hbs14
	@echo ""
	$(PYTHON) analyze_hbs14.py
	@echo ""
	@echo "Output: HBS14_SYSTEM_INTEGRATION.csv + HBS14_SUMMARY.log"
	@echo ""

# ── HBS-C2: Live System Observation Harness ──────────────────────────────────
sim_hbs_c2: $(TB)/tb_hbs_c2_live_sim.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c2: sim_hbs_c2
	@echo ""
	@echo "Running HBS-C2 Live System Observation Harness..."
	$(VVP) sim_hbs_c2
	@echo ""
	$(PYTHON) analyze_hbs_c2_live.py
	@echo ""
	@echo "Outputs: HBS_C2_LIVE_SIM.csv  HBS_C2_LIVE_SUMMARY.log"
	@echo "         hbs_c2_e_density.png  hbs_c2_uf_ovf_timeline.png"
	@echo "         hbs_c2_accum_drift.png  hbs_c2_mode_region_hm.png"
	@echo ""

# ── HBS-C5: C4 Kernel Decision Surface Exhaustive Stress-Test ────────────────
# Pure combinational testbench — no RTL DUT, no horus_system import.
# Tests all 4 × 64 × 32 = 8,192 kernel input combinations.
sim_hbs_c5: $(TB)/tb_hbs_c5_kernel_stress.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c5: sim_hbs_c5
	@echo ""
	@echo "Running HBS-C5 C4 Kernel Decision Surface Stress-Test..."
	$(VVP) sim_hbs_c5
	@echo ""
	$(PYTHON) analyze_hbs_c5_kernel_stress.py
	@echo ""
	@echo "Outputs: HBS_C5_KERNEL_STRESS.csv  HBS_C5_KERNEL_SUMMARY.log"
	@echo "         hbs_c5_mode_surface_classA/B/C/D.png"
	@echo "         hbs_c5_mode_surface_all.png  hbs_c5_action_manifold.png"
	@echo ""

# ── HBS-C6: Adversarial Real-World Workload Stress-Test ──────────────────────
# Tests horus_system DUT with 5 adversarial workloads × 500 cycles = 2500 cycles.
sim_hbs_c6: $(TB)/tb_hbs_c6_real_world_stress.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c6: sim_hbs_c6
	@echo ""
	@echo "Running HBS-C6 Adversarial Real-World Workload Stress-Test..."
	$(VVP) sim_hbs_c6
	@echo ""
	$(PYTHON) analyze_hbs_c6_real_world.py
	@echo ""
	@echo "Outputs: HBS_C6_REAL_WORLD.csv  HBS_C6_SUMMARY.log"
	@echo "         docs/HBS_C6_RESULTS.md"
	@echo "         hbs_c6_workload_heatmap.png  hbs_c6_collapse_exposure.png"
	@echo "         hbs_c6_cancellation_drift.png  hbs_c6_deepchain_degradation.png"
	@echo ""

# ── HBS-C7: Failure-Domain Isolation Suite ───────────────────────────────────
# Tests horus_system DUT with 4 adversarial regimes × 275 cycles = 1100 cycles.
sim_hbs_c7: $(TB)/tb_hbs_c7_failure_domain.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c7: sim_hbs_c7
	@echo ""
	@echo "Running HBS-C7 Failure-Domain Isolation Suite..."
	$(VVP) sim_hbs_c7
	@echo ""
	$(PYTHON) analyze_hbs_c7_failure_domain.py
	@echo ""
	@echo "Outputs: HBS_C7_FAILURE_DOMAIN.csv  HBS_C7_SUMMARY.log"
	@echo "         docs/HBS_C7_RESULTS.md  docs/HORUS_FAILURE_DOMAIN_MAP.md"
	@echo "         hbs_c7_failure_heatmap.png  hbs_c7_r2_exponent_drift.png"
	@echo "         hbs_c7_r1_residual_growth.png  hbs_c7_recovery_comparison.png"
	@echo ""

# ── HBS-C8: Attractor Decomposition & Phase-Space Reduction ──────────────────
# Pure analysis — no simulation required. Reads from prior HBS data.
hbs_c8:
	@echo ""
	@echo "Running HBS-C8 Attractor Decomposition & Phase-Space Reduction..."
	$(PYTHON) analyze_hbs_c8_attractor_model.py
	@echo ""
	@echo "Outputs: HBS_C8_ATTRACTOR_MODEL.csv  HBS_C8_SUMMARY.log"
	@echo "         HBS_C8_PHASE_SPACE.png"
	@echo "         docs/HBS_C8_ATTRACTOR_MODEL.md  docs/HORUS_PHASE_SPACE_REDUCTION.md"
	@echo ""

# ── HBS-C9: Singularity Validation ───────────────────────────────────────────
# 20 seeds × 4 workloads × 550 cycles = 44,000 cycles on horus_system DUT.
sim_hbs_c9: $(TB)/tb_hbs_c9_singularity.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c9: sim_hbs_c9
	@echo ""
	@echo "Running HBS-C9 Singularity Validation..."
	$(VVP) sim_hbs_c9
	@echo ""
	$(PYTHON) analyze_hbs_c9_singularity.py
	@echo ""
	@echo "Outputs: HBS_C9_SINGULARITY.csv  HBS_C9_SUMMARY.log"
	@echo "         docs/HBS_C9_RESULTS.md  docs/HORUS_S1_VALIDATION.md"
	@echo "         hbs_c9_attractor_timeline.png  hbs_c9_s1d_e_sawtooth.png"
	@echo "         hbs_c9_tti_distribution.png  hbs_c9_phase_trajectory.png"
	@echo ""

# ── HBS-C10: Predictive Validation ───────────────────────────────────────────
# 20 unseen workloads × 350 cycles = 7,000 cycles on horus_system DUT.
# Predictions generated analytically BEFORE simulation CSV is read.
sim_hbs_c10: $(TB)/tb_hbs_c10_predictive_validation.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c10: sim_hbs_c10
	@echo ""
	@echo "Running HBS-C10 Predictive Validation..."
	$(VVP) sim_hbs_c10
	@echo ""
	$(PYTHON) analyze_hbs_c10_predictive_validation.py
	@echo ""
	@echo "Outputs: HBS_C10_PREDICTIONS.csv  HBS_C10_SINGULARITY.csv"
	@echo "         HBS_C10_SUMMARY.log"
	@echo "         docs/HBS_C10_RESULTS.md  docs/HORUS_PREDICTIVE_VALIDATION.md"
	@echo ""

# ── HBS-C12: Adversarial Reality Collapse Suite ───────────────────────────────
# 5 adversarial suites × mixed cycles = 14,600 cycles on horus_system DUT.
sim_hbs_c12: $(TB)/tb_hbs_c12_adversarial_reality.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c12: sim_hbs_c12
	@echo ""
	@echo "Running HBS-C12 Adversarial Reality Collapse Suite..."
	$(VVP) sim_hbs_c12
	@echo ""
	$(PYTHON) analyze_hbs_c12_adversarial_reality.py
	@echo ""
	@echo "Outputs: HBS_C12_ADVERSARIAL.csv  HBS_C12_SUMMARY.log"
	@echo "         docs/HBS_C12_RESULTS.md  docs/HORUS_ADVERSARIAL_BEHAVIOR.md"
	@echo ""

# ── HBS-C13: Attractor Controllability & Phase Steering Suite ─────────────────
# 4 suites (C13A–D) × 7,528 cycles on horus_system DUT.
sim_hbs_c13: $(TB)/tb_hbs_c13_attractor_control.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c13: sim_hbs_c13
	@echo ""
	@echo "Running HBS-C13 Attractor Controllability & Phase Steering Suite..."
	$(VVP) sim_hbs_c13
	@echo ""
	$(PYTHON) analyze_hbs_c13_attractor_control.py
	@echo ""
	@echo "Outputs: HBS_C13_CONTROL.csv  HBS_C13_SUMMARY.log"
	@echo "         docs/HBS_C13_RESULTS.md  docs/HORUS_ATTRACTOR_CONTROL_MODEL.md"
	@echo ""

# ── HBS-C14: Attractor-to-Computation Synthesis Suite ─────────────────────────
# 5 suites (C14A–E) × 7,904 cycles on horus_system DUT.
sim_hbs_c14: $(TB)/tb_hbs_c14_attractor_computation.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c14: sim_hbs_c14
	@echo ""
	@echo "Running HBS-C14 Attractor-to-Computation Synthesis Suite..."
	$(VVP) sim_hbs_c14
	@echo ""
	$(PYTHON) analyze_hbs_c14_attractor_computation.py
	@echo ""
	@echo "Outputs: HBS_C14_COMPUTATION.csv  HBS_C14_SUMMARY.log"
	@echo "         docs/HBS_C14_RESULTS.md  docs/HORUS_ATTRACTOR_COMPUTATION_MODEL.md"
	@echo ""

# ── HBS-C15: OOB Controllability Falsification Suite ──────────────────────────
# 5 adversarial regimes × 1,500 cycles = 7,500 cycles on horus_system DUT.
sim_hbs_c15: $(TB)/tb_hbs_c15_oob_falsification.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c15: sim_hbs_c15
	@echo ""
	@echo "Running HBS-C15 OOB Controllability Falsification Suite..."
	$(VVP) sim_hbs_c15
	@echo ""
	$(PYTHON) analyze_hbs_c15_oob.py
	@echo ""
	@echo "Outputs: HBS_C15_OOB.csv  HBS_C15_SUMMARY.log"
	@echo "         docs/HBS_C15_RESULTS.md  docs/HORUS_CONTROL_ROBUSTNESS.md"
	@echo ""

# ── HBS-C16: Control Causality Isolation Suite ────────────────────────────────
# 4 modes × 2,000 cycles = 8,000 cycles. Full pipeline trace per cycle.
sim_hbs_c16: $(TB)/tb_hbs_c16_causal_isolation.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c16: sim_hbs_c16
	@echo ""
	@echo "Running HBS-C16 Control Causality Isolation Suite..."
	$(VVP) sim_hbs_c16
	@echo ""
	$(PYTHON) analyze_hbs_c16_causality.py
	@echo ""
	@echo "Outputs: HBS_C16_CAUSAL_TRACE.csv  HBS_C16_SUMMARY.log"
	@echo "         docs/HBS_C16_CAUSALITY_REPORT.md  docs/HORUS_CONTROL_CAUSALITY_MAP.md"
	@echo ""

# ── HBS-C17: Accumulation Feedback Closure Falsification ──────────────────────
# 9 sub-tests × varying cycles = 8,500 cycles. Proves strict feedforwardness.
sim_hbs_c17: $(TB)/tb_hbs_c17_feedback_closure.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c17: sim_hbs_c17
	@echo ""
	@echo "Running HBS-C17 Accumulation Feedback Closure Falsification Suite..."
	$(VVP) sim_hbs_c17
	@echo ""
	$(PYTHON) analyze_hbs_c17_feedback_closure.py
	@echo ""
	@echo "Outputs: HBS_C17_FEEDBACK_CLOSURE.csv  HBS_C17_SUMMARY.log"
	@echo "         docs/HBS_C17_FEEDBACK_CLOSURE.md  docs/HORUS_CAUSAL_CLOSURE_MAP.md"
	@echo ""

# ── HBS-C23: Observer-Decoupling Falsification Suite ─────────────────────────
# 6,000 cycles, all 4 observer transforms applied simultaneously every cycle.
# Tests whether attractors are coordinate-invariant dynamical properties or
# observer-frame artifacts of the E-field extraction convention result[11:6].
sim_hbs_c23: $(TB)/tb_hbs_c23_observer_decoupling.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c23: sim_hbs_c23
	@echo ""
	@echo "Running HBS-C23 Observer-Decoupling Falsification Suite..."
	$(VVP) sim_hbs_c23
	@echo ""
	$(PYTHON) HBS_C23_ANALYSIS.py
	@echo ""
	@echo "Outputs: HBS_C23_OBSERVER_TRACE.csv  HBS_C23_REGIME_RESULTS.csv"
	@echo "         HBS_C23_SUMMARY.log"
	@echo ""

# ── HBS-C22: Exogenous Control Injection Test (Strict Version) ────────────────
# 4 regimes × 1,500 cycles = 6,000 cycles.
# First test with a TRULY INDEPENDENT injection source (mode_lfsr, no DUT dependency).
# Introduces Mutual Information as the primary causality metric.
sim_hbs_c22: $(TB)/tb_hbs_c22_exogenous_injection.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c22: sim_hbs_c22
	@echo ""
	@echo "Running HBS-C22 Exogenous Injection Suite..."
	$(VVP) sim_hbs_c22
	@echo ""
	$(PYTHON) HBS_C22_ANALYSIS.py
	@echo ""
	@echo "Outputs: HBS_C22_INJECTION_TRACE.csv  HBS_C22_MI_MATRIX.csv"
	@echo "         HBS_C22_REGIME_RESULTS.csv    HBS_C22_SUMMARY.log"
	@echo ""

# ── HBS-C21: Controlled Feedback Coupling Experiment (Option A) ───────────────
# 3 regimes (k=12, 10, 8) × 2,000 cycles = 6,000 cycles.
# Measures AII, CPR, PIG, SLF to characterize coupling penetration depth.
# ALU core RTL is untouched; computed_mod is a testbench-layer side-channel.
sim_hbs_c21: $(TB)/tb_hbs_c21_feedback_probe.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c21: sim_hbs_c21
	@echo ""
	@echo "Running HBS-C21 Feedback Probe Suite..."
	$(VVP) sim_hbs_c21
	@echo ""
	$(PYTHON) HBS_C21_ANALYSIS.py
	@echo ""
	@echo "Outputs: HBS_C21_FEEDBACK_TRACE.csv  HBS_C21_REGIME_RESULTS.csv"
	@echo "         HBS_C21_SUMMARY.log"
	@echo ""

# ── HBS-C20: Closure Firewall Localization & Causal Boundary Extraction ───────
# 3 isolation stress modes × 2,000 cycles = 6,000 cycles.
# Extracts the exact causal boundary geometry of the HORUS v3 firewall.
sim_hbs_c20: $(TB)/tb_hbs_c20_boundary_trace.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c20: sim_hbs_c20
	@echo ""
	@echo "Running HBS-C20 Closure Firewall Localization Suite..."
	$(VVP) sim_hbs_c20
	@echo ""
	$(PYTHON) HBS_C20_ANALYSIS.py
	@echo ""
	@echo "Outputs: HBS_C20_BOUNDARY_TRACE.csv  HBS_C20_BTF_MATRIX.csv"
	@echo "         HBS_C20_SUMMARY.log"
	@echo "         docs/HBS_C20_RESULTS.md  docs/HORUS_CLOSURE_GEOMETRY.md"
	@echo ""

# ── HBS-C19: Closure Falsification Under Cross-Domain Coupling ────────────────
# 5 adversarial injection regimes × 2,000 cycles = 10,000 cycles.
# Attempts to falsify the HBS-C18 System Closure Theorem via forced coupling.
sim_hbs_c19: $(TB)/tb_hbs_c19_closure_falsification.v $(SRC_CORE)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hbs_c19: sim_hbs_c19
	@echo ""
	@echo "Running HBS-C19 Closure Falsification Suite..."
	$(VVP) sim_hbs_c19
	@echo ""
	$(PYTHON) analyze_hbs_c19_closure_falsification.py
	@echo ""
	@echo "Outputs: HBS_C19_CLOSURE_RESULTS.csv  HBS_C19_SUMMARY.log"
	@echo "         docs/HBS_C19_RESULTS.md  docs/HORUS_CLOSURE_STABILITY_REPORT.md"
	@echo ""

# ── PF18 Power Iteration: three-way convergence comparison ────────────────────
sim_pf18_pi: $(TB)/tb_pf18_power_iteration.v $(RTL)/horus_nfe_pf18.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

sim_baseline_pi: $(TB)/tb_baseline_power_iteration.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

pi_sims: sim_pf18_pi sim_baseline_pi
	@echo ""
	@echo "Running PF18 power iteration..."
	$(VVP) sim_pf18_pi
	@echo ""
	@echo "Running Baseline power iteration..."
	$(VVP) sim_baseline_pi
	@echo ""
	@echo "Outputs: PF18_POWER_ITER.csv  BASELINE_POWER_ITER.csv"
	@echo ""

power_iteration: pi_sims
	@echo ""
	@echo "Running three-way comparison analysis..."
	$(PYTHON) analyze_power_iteration.py
	@echo ""
	@echo "Output: PI_THREE_WAY.csv  docs/PF18_POWER_ITERATION.md"
	@echo ""

# ── Normalization-Interval Sweep + RTL Confirmation ──────────────────────────
norm_sweep:
	@echo ""
	@echo "Running normalization-interval sweep (Python, ~30 s)..."
	$(PYTHON) norm_interval_sweep.py
	@echo ""
	@echo "Output: NORM_INTERVAL_SWEEP.csv"
	@echo ""

sim_norm_interval: $(TB)/tb_norm_interval.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

norm_rtl: sim_norm_interval
	@echo ""
	@echo "Running RTL confirmation (3 cells)..."
	$(VVP) sim_norm_interval
	@echo ""
	@echo "Output: NORM_INTERVAL_RTL.csv"
	@echo ""

norm_vs_pf18: norm_sweep norm_rtl
	@echo ""
	@echo "Normalization-vs-PF18 campaign complete."
	@echo "Artifacts: NORM_INTERVAL_SWEEP.csv  NORM_INTERVAL_RTL.csv"
	@echo "Doc: docs/NORM_VS_PF18.md"
	@echo ""

# ── Hopfield demo ─────────────────────────────────────────────────────────────
hopfield_demo:
	@echo ""
	@echo "Running Hopfield Python demo (PATH_NFE baseline model)..."
	$(PYTHON) hopfield_demo.py
	@echo ""
	@echo "Output: HOPFIELD_DEMO_PY.csv"
	@echo ""

sim_hopfield_recall: $(TB)/tb_hopfield_recall.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

hopfield_rtl: sim_hopfield_recall
	@echo ""
	@echo "Running Hopfield RTL demo (horus_nfe baseline, ~5 s)..."
	$(VVP) sim_hopfield_recall
	@echo ""
	@echo "Output: HOPFIELD_TRACE.csv"
	@echo ""

hopfield_check: hopfield_demo hopfield_rtl
	@echo ""
	@echo "Running Python vs RTL agreement analysis..."
	$(PYTHON) analyze_hopfield.py
	@echo ""

hopfield_all: hopfield_check
	@echo "Hopfield demo complete."
	@echo "Artifacts: HOPFIELD_DEMO_PY.csv  HOPFIELD_TRACE.csv"
	@echo "Doc: docs/HOPFIELD_DEMO.md"
	@echo ""

# ── expnorm sweep + horus_norm RTL tests + synthesis ─────────────────────────
expnorm_sweep:
	@echo "Running block-exponent normalizer sweep (Python)..."
	$(PYTHON) expnorm_sweep.py
	@echo ""
	@echo "Artifacts: EXPNORM_SWEEP.csv  EXPNORM_GOLDEN.csv  EXPNORM_GOLDEN.dat"
	@echo ""

sim_horus_norm: $(TB)/tb_horus_norm.v $(RTL)/horus_norm.v $(RTL)/horus_nfe.v
	$(IVERILOG) $(IVFLAGS) -o $@ $^

horus_norm_rtl: sim_horus_norm
	@echo ""
	@echo "Running horus_norm unit + integration tests..."
	$(VVP) sim_horus_norm
	@echo ""

synth_norm: synth_horus_norm.ys
	@echo "Synthesising horus_norm (Sky130 HD)..."
	$(YOSYS) -Q synth_horus_norm.ys 2>&1 | tee SYNTH_HORUS_NORM.log
	@echo "Log: SYNTH_HORUS_NORM.log"
	@echo ""

expnorm_all: expnorm_sweep horus_norm_rtl synth_norm
	@echo "expnorm campaign complete."
	@echo "Artifacts: EXPNORM_SWEEP.csv  EXPNORM_GOLDEN.csv  EXPNORM_GOLDEN.dat  SYNTH_HORUS_NORM.log"
	@echo "Doc: docs/EXPNORM_RESULTS.md"
	@echo ""

# ── MLP digit-classification inference demo ───────────────────────────────────
mlp_train:
	@echo "Training 64→16→10 MLP and quantising to NFE..."
	$(PYTHON) mlp_train.py
	@echo ""
	@echo "Artifacts: MLP_W1.hex MLP_B1.hex MLP_W2.hex MLP_B2.hex"
	@echo "           MLP_TEST_IMAGES.hex MLP_TEST_LABELS.dat MLP_FP64.npz"
	@echo ""

mlp_norm_v2_golden:
	@echo "Generating EXPNORM_V2_GOLDEN.dat for tb_horus_norm_v2..."
	$(PYTHON) expnorm_sweep.py --v2-golden
	@echo ""

mlp_norm_v2: mlp_norm_v2_golden
	@echo "Compiling and running tb_horus_norm_v2 (mode-0 regression + composition)..."
	iverilog -g2012 -Wall -o sim_horus_norm_v2 \
	    ../tb/tb_horus_norm_v2.v ../rtl/horus_norm_v2.v
	vvp sim_horus_norm_v2
	@echo ""

mlp_infer:
	@echo "Running NFE inference pipelines (a/b/c/d, gate check, showcase)..."
	$(PYTHON) mlp_infer_nfe.py
	@echo ""
	@echo "Artifacts: MLP_PY_TRACE.csv  MLP_SHOWCASE.dat"
	@echo ""

mlp_rtl: mlp_infer
	@echo "Compiling and running RTL inference testbench..."
	iverilog -g2012 -Wall -o sim_mlp_inference \
	    ../tb/tb_mlp_inference.v ../rtl/horus_nfe.v ../rtl/horus_norm_v2.v
	vvp sim_mlp_inference
	@echo ""
	@echo "Artifacts: MLP_RTL_TRACE.csv"
	@echo ""

mlp_analyze: mlp_infer mlp_rtl
	@echo "Cross-checking RTL vs Python (predictions + activations)..."
	$(PYTHON) analyze_mlp.py
	@echo ""

mlp_all: mlp_train mlp_norm_v2 mlp_infer mlp_rtl mlp_analyze
	@echo "MLP inference demo complete (shared-offset expnorm, gate PASSED)."
	@echo "Full arc documented in docs/MLP_INFERENCE_DEMO.md"
	@echo ""
