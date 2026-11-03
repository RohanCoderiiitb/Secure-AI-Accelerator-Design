# =====================================================================
# Side-channel leakage assessment -- PROTECTED designs
# =====================================================================
# Run every target from this directory (security_analyses/protected).
#
# Layout this Makefile expects:
#   ../../protected_designs/source/masked_wt_multiplier.sv      weight masked (also holds share_multiplier)
#   ../../protected_designs/source/masked_act_multiplier.sv     activation masked
#   ../../protected_designs/source/masked_act_wt_multiplier.sv  activation + weight masked
#   ../../protected_designs/source/{processing_element,systolic_array}_masked_act.sv, act_masker.sv
#                                                         activation-masked PE / array
#   ../../protected_designs/source/systolic_array_wmask_shared.sv
#                                                         weight-masked array, one share per PE +
#                                                         shared random-weight column
#   ../unprotected/sca_capture.vh                         shared capture header
#   ../unprotected/scripts/{vcd_power,run_tvla,tvla}.py   shared analysis
#   ./scripts/run_tvla_second_order.py                    second-order TVLA
#   ./tb/tb_tvla_masked_wt_mult.sv                           testbench (weight masked)
#   ./tb/tvla_tb_masked_act_multiplier.sv                    testbench (activation masked)
#   ./tb/tb_tvla_masked_act_wt_mult.sv                        testbench (act + weight masked)
#   ./tb/tb_tvla_masked_act_pe.sv                            testbench (activation-masked PE)
#   ./tb/tb_tvla_masked_act_array.sv                         testbench (activation-masked array)
#   ./tb/tb_tvla_actlink_masked_array.sv                     testbench (plain-multiplier array, masked activation links)
#   ./tb/tb_tvla_wmask_shared_array.sv                       testbench (weight-masked shared-column array)
#   ../../protected_designs/sim/tb_func_wmask_shared.sv     functional check vs baseline array (make func)
#   ./build ./traces ./out                                generated
#
# Outputs
#   out/tvla_outputs/<mult>_multiplier/tvla_<target>/              first-order plots (+ summary.csv)
#   out/second_order_tvla_outputs/<mult>_multiplier/tvla_<target>/ second-order plots (+ tvla2_summary.csv)
#   out/adla_outputs/<mult>_multiplier/tvla_<target>/              ADLA plots (+ adla_summary.csv)
#   <mult> = wt_masked | act_masked | act_wt_masked
#   For the PE / array the directory is act_masked_pe/ or act_masked_array<R>x<C>/
#   (no "_multiplier" suffix), with the same tvla_act/ sub-folder.
#
# ---------------------------------------------------------------------
# Pick the design with DUT=
#   DUT=masked_mult      weight-masked multiplier      (TARGET is wt)
#   DUT=masked_act_mult  activation-masked only        (TARGET is act)
#   DUT=masked_mult_aw   activation + weight masked    (TARGET=act default, or wt)
#   DUT=masked_act_pe    activation-masked PE          (TARGET is act; exhaustive)
#   DUT=masked_act_array activation-masked ROWSxCOLS array (TARGET=act default, or row0)
#                        ROWS=5 COLS=5; N is the number of traces and is YOURS to pick
#   DUT=actlink_masked_array  array of baseline (unmasked) PEs, masking only on the
#                        activation links inside the array (TARGET=act default, or row0)
#   DUT=wmask_shared_array  weight-masked array: one SW-bit share per PE, a shared
#                        random-weight shadow column, recombination at the column
#                        outputs (TARGET=wt default, or row0). N default 2000.
#                        make func DUT=wmask_shared_array  -> cycle-exact check vs baseline
#   e.g.  make all DUT=masked_mult_aw TARGET=act
#
# Recommended order:
#   make check
#   make tvla2_selftest          second-order script on synthetic data
#   make null                    first-order null test   (must PASS)
#   make tvla                    first-order fixed vs random
#   make tvla2_null              second-order null test  (must PASS)
#   make tvla2                   second-order fixed vs random
#   make maskoff                 sanity: masking OFF, first order MUST detect
#   make adla_null / make adla   ADLA (reuses the TVLA datasets, needs null / tvla first)
#
#   make main                    tvla + tvla2 + adla only (no null tests, no maskoff)
#   make all                     everything above in that order
#
# ---------------------------------------------------------------------
# COMPLETE ACCELERATOR (weights as the secret) -- two commands
#   make latency    masked requantizer: latency / throughput vs the original
#                   requantize (and the 29-cycle reference), value-by-value
#                   equivalence; then end-to-end functional check of the
#                   protected accelerator against the unprotected one
#   make tvla_all   1st-order TVLA, 2nd-order TVLA and ADLA of BOTH accelerators
#                   (both live in protected_designs/complete_accelerator),
#                   only the t-statistic plot is kept:
#                     ../unprotected/out/tvla_outputs/complete_accelerator/tvla_wt/...t-statistic.png
#                     ./out/tvla_outputs/complete_accelerator/tvla_wt/...t-statistic.png
#   make tvla_cases protected accelerator, three cases, each simulated once
#                   (CASES_N=10000 traces) and analysed with 1st-order TVLA,
#                   2nd-order TVLA and ADLA:
#                     both    top_protected.sv          array + requantizer masked
#                     rq      top_protected_rq_only.sv  requantizer masked only
#                     arr     top_protected_arr_only.sv array masked only
#                   plots: ./out/{tvla_outputs,second_order_tvla_outputs,adla_outputs}/
#                          complete_accelerator_{both_masked,rq_masked,arr_masked}/tvla_wt/
#   make requant_tvla  stand-alone masked requantizer: 1st-order TVLA,
#                   2nd-order TVLA and ADLA on acc_in (one dataset):
#                     ./out/tvla_outputs/requantize_masked/tvla_act/...t-statistic.png
#                   knobs: RQ_N=2000 traces, RQ_MASK_OFF=1 (sanity control)
#   make requant_2nd_adla  2nd-order TVLA + ADLA only, reusing the existing
#                   traces/requantize_masked_act.npz (no new simulation)
#   Knobs: ACC_N=2000 traces per design, ACC_DOM_REG=1 (0 = low-latency
#          requantizer), ACC_KEEP_VCD=0, FUNC_NTEST=100, LAT_NBURST=300
# ---------------------------------------------------------------------
# Knobs
#   N=           traces. Default is per DUT: 131072 for the multipliers and
#                masked_act_pe, 2000 for masked_act_array (sampled, not
#                exhaustive). Always overridable, e.g. make all DUT=masked_act_array N=10000
#                131072 (multiplier/PE). 131072 = exhaustive: random group covers all
#                256 x 256 (weight, activation) pairs once; fixed group
#                covers every activation 256 times. Smaller N = random
#                subset (e.g. N=20000 for a quick run).
#   SEED=1
#   FIXED_W=-77  fixed-group weight     (signed decimal, TARGET=wt)
#   FIXED_A=93   fixed-group activation (signed decimal, TARGET=act)
#   REPEATS=20   subsets per point in a TTD sweep
#   ROWS=5 COLS=5  array geometry (DUT=masked_act_array)
#   KEEP_VCD=1   set 0 to delete each .vcd once its .npz exists (the exhaustive PE
#                VCD is ~6 GB per dataset)
#   PERM=500     label permutations for the ADLA threshold
#   TTD=1        set TTD=0 to skip the TTD sweep (it is the slow part
#                of the analysis at N=131072)
#
# Disk: the exhaustive VCD is several hundred MB.
# =====================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PY       ?= python3

# ---------------------------------------------------------------------
# Paths. Everything that lives OUTSIDE this folder is absolute, derived
# from where this Makefile sits, so the repo can be cloned anywhere.
#   HERE = security_analyses/protected     ROOT = repo root
# Outputs (build/ traces/ out/) stay relative to HERE; the guard below
# makes sure make always runs from HERE (or via make -C <this folder>).
# ---------------------------------------------------------------------
HERE     := $(patsubst %/,%,$(abspath $(dir $(lastword $(MAKEFILE_LIST)))))
ROOT     := $(abspath $(HERE)/../..)
ifneq ($(patsubst %/,%,$(abspath $(CURDIR))),$(HERE))
  $(error run make from $(HERE)  (or: make -C $(HERE) <target>))
endif

SRC      := $(ROOT)/source
RTL_P    := $(ROOT)/protected_designs/source
SIM_P    := $(ROOT)/protected_designs/sim
UNP      := $(ROOT)/security_analyses/unprotected
USCRIPTS := $(UNP)/scripts
SCRIPTS  := scripts
TB       := tb
BUILD    := build
TR       := traces
OUT      := out
OUT_T1   := $(OUT)/tvla_outputs
OUT_T2   := $(OUT)/second_order_tvla_outputs
OUT_AD   := $(OUT)/adla_outputs

IVFLAGS  ?= -g2012 -I $(UNP) -I $(TB)

# --- knobs -----------------------------------------------------------
SEED    ?= 1
FIXED_W ?= -77
FIXED_A ?= 93
REPEATS ?= 20
TTD     ?= 1
PERM    ?= 500
KEEP_VCD ?= 1
ROWS    ?= 5
COLS    ?= 5

# --- DUT -------------------------------------------------------------
DUT  ?= masked_mult
ifeq ($(DUT),masked_mult)
  SRCS   := $(RTL_P)/masked_wt_multiplier.sv
  TBF    := $(TB)/tb_tvla_masked_wt_mult.sv
  TARGET := wt
  N_DEF  := 131072
else ifeq ($(DUT),masked_mult_aw)
  SRCS   := $(RTL_P)/masked_wt_multiplier.sv $(RTL_P)/masked_act_wt_multiplier.sv
  TBF    := $(TB)/tb_tvla_masked_act_wt_mult.sv
  TARGET ?= act
  N_DEF  := 131072
else ifeq ($(DUT),masked_act_mult)
  SRCS   := $(RTL_P)/masked_wt_multiplier.sv $(RTL_P)/masked_act_multiplier.sv
  TBF    := $(TB)/tvla_tb_masked_act_multiplier.sv
  TARGET := act
  N_DEF  := 131072
else ifeq ($(DUT),masked_act_pe)
  SRCS   := $(RTL_P)/masked_wt_multiplier.sv $(RTL_P)/processing_element_masked_act.sv
  TBF    := $(TB)/tb_tvla_masked_act_pe.sv
  TARGET := act
  N_DEF  := 131072
else ifeq ($(DUT),masked_act_array)
  SRCS   := $(RTL_P)/masked_wt_multiplier.sv $(RTL_P)/processing_element_masked_act.sv \
            $(RTL_P)/systolic_array_masked_act.sv $(RTL_P)/act_masker.sv
  TBF    := $(TB)/tb_tvla_masked_act_array.sv
  TARGET ?= act
  N_DEF  := 2000
  PARAMS := -Ptb_tvla_masked_act_array.ROWS=$(ROWS) -Ptb_tvla_masked_act_array.COLS=$(COLS)
else ifeq ($(DUT),actlink_masked_array)
  SRCS   := $(SRC)/multiplier.sv $(SRC)/processing_element.sv \
            $(RTL_P)/systolic_array_actlink_masked.sv $(RTL_P)/act_masker.sv
  TBF    := $(TB)/tb_tvla_actlink_masked_array.sv
  TARGET ?= act
  N_DEF  := 2000
  PARAMS := -Ptb_tvla_actlink_masked_array.ROWS=$(ROWS) -Ptb_tvla_actlink_masked_array.COLS=$(COLS)
else ifeq ($(DUT),wmask_shared_array)
  SRCS   := $(SRC)/multiplier.sv $(RTL_P)/systolic_array_wmask_shared.sv
  TBF    := $(TB)/tb_tvla_wmask_shared_array.sv
  TARGET ?= wt
  N_DEF  := 2000
  PARAMS := -Ptb_tvla_wmask_shared_array.ROWS=$(ROWS) -Ptb_tvla_wmask_shared_array.COLS=$(COLS)
else
  $(error unknown DUT=$(DUT): use masked_mult, masked_act_mult, masked_mult_aw, masked_act_pe, masked_act_array, actlink_masked_array or wmask_shared_array)
endif
N ?= $(N_DEF)

# human-readable multiplier name + per-run output directories / plot prefixes
#   out/<order>_outputs/<mult>_multiplier/tvla_<target>/<mult>__target-<target>[__masking-off]__<1st|2nd>-order__<plot>.png
ifeq ($(DUT),masked_act_pe)
  MULT_NAME := act_masked_pe
  DESIGN_DIR := act_masked_pe
else ifeq ($(DUT),masked_act_array)
  MULT_NAME := act_masked_array$(ROWS)x$(COLS)
  DESIGN_DIR := act_masked_array$(ROWS)x$(COLS)
else ifeq ($(DUT),actlink_masked_array)
  MULT_NAME := act_linkmasked_plainmul_array$(ROWS)x$(COLS)
  DESIGN_DIR := act_linkmasked_plainmul_array$(ROWS)x$(COLS)
else ifeq ($(DUT),wmask_shared_array)
  MULT_NAME := wt_masked_shared_array$(ROWS)x$(COLS)
  DESIGN_DIR := wt_masked_shared_array$(ROWS)x$(COLS)
else
  MULT_NAME := $(strip $(if $(filter masked_mult,$(DUT)),wt_masked,$(if $(filter masked_act_mult,$(DUT)),act_masked,act_wt_masked)))
  DESIGN_DIR := $(MULT_NAME)_multiplier
endif
RUN_SUB   := $(DESIGN_DIR)/tvla_$(TARGET)
RUN_BASE  := $(MULT_NAME)__target-$(TARGET)
P1        := $(OUT_T1)/$(RUN_SUB)/$(RUN_BASE)__1st-order
P1_OFF    := $(OUT_T1)/$(RUN_SUB)/$(RUN_BASE)__masking-off__1st-order
P2        := $(OUT_T2)/$(RUN_SUB)/$(RUN_BASE)__2nd-order
PA        := $(OUT_AD)/$(RUN_SUB)/$(RUN_BASE)

# '#' starts a make comment even inside a macro body, so it must be escaped
HASH := \#

# scripts emit <prefix>_{t,mean,var,ttd}.png; give them descriptive names
# usage: $(call NAME,<prefix>,<order>)
NAME = for pair in t:t-statistic mean:mean-power-trace var:variance-trace ttd:time-to-detection; do \
  for sep in _ __; do f=$(1)$$sep$${pair%%:*}.png; [ -f $$f ] && mv $$f $(1)__$${pair$(HASH)*:}.png; done; done; true

# run_adla.py emits <prefix>_adla.png, _adla_vs_tvla.png, _adla_ttd.png
NAME_AD = for pair in adla:statistic adla_vs_tvla:vs-tvla-comparison adla_ttd:time-to-detection; do \
  f=$(1)_$${pair%%:*}.png; [ -f $$f ] && mv $$f $(1)__adla__$${pair$(HASH)*:}.png; done; true

FIXARGS := +FIXED_W=$(FIXED_W) +FIXED_A=$(FIXED_A)
SUF   := $(DUT)$(if $(filter masked_act_array actlink_masked_array wmask_shared_array,$(DUT)),$(ROWS)x$(COLS))
VVPF  := $(BUILD)/tb_$(SUF).vvp
ABS   := $(CURDIR)
TTDF  := $(if $(filter 1,$(TTD)),--ttd --repeats $(REPEATS),)

.PHONY: dirs check build null tvla tvla2_selftest tvla2_null tvla2 \
        adla_null adla maskoff all main clean func \
        latency tvla_all acc_tvla requant_tvla requant_2nd_adla \
        tvla_cases acc_case

dirs:
	@mkdir -p $(BUILD) $(TR) $(OUT_T1)/$(RUN_SUB) $(OUT_T2)/$(RUN_SUB) $(OUT_AD)/$(RUN_SUB)

check:
	@echo "ROOT=$(ROOT)"
	@echo "DUT=$(DUT) TARGET=$(TARGET) N=$(N) traces ($$(( $(N) / 2 )) fixed + $$(( $(N) / 2 )) random)"
	@for f in $(SRCS) $(TBF); do \
	  test -f $$f && echo "  [ok] $$f" \
	  || { echo "  [FAIL] $$f missing"; exit 1; }; done
	@test -f $(UNP)/sca_capture.vh \
	  && echo "  [ok] $(UNP)/sca_capture.vh" \
	  || { echo "  [FAIL] $(UNP)/sca_capture.vh missing"; exit 1; }
	@for f in vcd_power.py run_tvla.py tvla.py; do \
	  test -f $(USCRIPTS)/$$f && echo "  [ok] $(USCRIPTS)/$$f" \
	  || { echo "  [FAIL] $(USCRIPTS)/$$f missing"; exit 1; }; done
	@test -f $(SCRIPTS)/run_tvla_second_order.py \
	  && echo "  [ok] $(SCRIPTS)/run_tvla_second_order.py" \
	  || { echo "  [FAIL] $(SCRIPTS)/run_tvla_second_order.py missing"; exit 1; }
	@$(PY) -c "import numpy" 2>/dev/null && echo "  [ok] numpy" || echo "  [WARN] numpy missing"
	@$(PY) -c "import matplotlib" 2>/dev/null && echo "  [ok] matplotlib" \
	  || echo "  [WARN] matplotlib missing -- plots will be skipped"

build: dirs
	$(IVERILOG) $(IVFLAGS) $(PARAMS) -o $(VVPF) $(SRCS) $(TBF)

# ---------------------------------------------------------------------
# First-order TVLA. Null test first, always.
# ---------------------------------------------------------------------
null: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=null +TVLA_TARGET=$(TARGET) \
	       $(FIXARGS) +TAG=$(SUF)_$(TARGET)_null +OUTDIR=$(TR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET)_null.vcd \
	       --meta $(TR)/$(SUF)_$(TARGET)_null.meta.csv --out $(TR)/$(SUF)_$(TARGET)_null.npz
	$(if $(filter 1,$(KEEP_VCD)),,rm -f $(TR)/$(SUF)_$(TARGET)_null.vcd)
	cd $(USCRIPTS) && $(PY) run_tvla.py --npz $(ABS)/$(TR)/$(SUF)_$(TARGET)_null.npz --null

tvla: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=tvla +TVLA_TARGET=$(TARGET) \
	       $(FIXARGS) +TAG=$(SUF)_$(TARGET) +OUTDIR=$(TR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET).vcd \
	       --meta $(TR)/$(SUF)_$(TARGET).meta.csv --out $(TR)/$(SUF)_$(TARGET).npz
	$(if $(filter 1,$(KEEP_VCD)),,rm -f $(TR)/$(SUF)_$(TARGET).vcd)
	cd $(USCRIPTS) && $(PY) run_tvla.py --npz $(ABS)/$(TR)/$(SUF)_$(TARGET).npz \
	       $(TTDF) --profile \
	       --plot $(ABS)/$(P1)_ \
	       --csv  $(ABS)/$(OUT_T1)/summary.csv
	@$(call NAME,$(ABS)/$(P1))

# ---------------------------------------------------------------------
# Second-order TVLA. Reuses the first-order datasets (run null / tvla
# first). Univariate: both share datapaths switch in the same cycle.
# ---------------------------------------------------------------------
tvla2_selftest:
	$(PY) $(SCRIPTS)/run_tvla_second_order.py --self-test

tvla2_null: dirs
	$(PY) $(SCRIPTS)/run_tvla_second_order.py \
	       --npz $(TR)/$(SUF)_$(TARGET)_null.npz --null

tvla2: dirs
	$(PY) $(SCRIPTS)/run_tvla_second_order.py \
	       --npz $(TR)/$(SUF)_$(TARGET).npz --compare --profile $(TTDF) \
	       --plot $(P2) \
	       --csv  $(OUT_T2)/tvla2_summary.csv
	@$(call NAME,$(P2))

# ---------------------------------------------------------------------
# ADLA (Anderson-Darling). Reuses the first-order datasets (run null /
# tvla first); no re-simulation.
# ---------------------------------------------------------------------
adla_null: dirs
	cd $(USCRIPTS) && $(PY) run_adla.py --npz $(ABS)/$(TR)/$(SUF)_$(TARGET)_null.npz \
	       --null --perm $(PERM)

adla: dirs
	cd $(USCRIPTS) && $(PY) run_adla.py --npz $(ABS)/$(TR)/$(SUF)_$(TARGET).npz \
	       --compare --profile --perm $(PERM) $(TTDF) \
	       --plot $(ABS)/$(PA) \
	       --csv  $(ABS)/$(OUT_AD)/adla_summary.csv
	@$(call NAME_AD,$(ABS)/$(PA))

# ---------------------------------------------------------------------
# Sanity control: masking OFF (m = 0, r = 0). First-order TVLA MUST
# detect here; if it does not, the setup cannot see the secret's leakage and
# the masked result above means nothing.
# ---------------------------------------------------------------------
maskoff: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=tvla +TVLA_TARGET=$(TARGET) \
	       $(FIXARGS) +MASK_OFF=1 +TAG=$(SUF)_$(TARGET)_maskoff +OUTDIR=$(TR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET)_maskoff.vcd \
	       --meta $(TR)/$(SUF)_$(TARGET)_maskoff.meta.csv \
	       --out $(TR)/$(SUF)_$(TARGET)_maskoff.npz
	$(if $(filter 1,$(KEEP_VCD)),,rm -f $(TR)/$(SUF)_$(TARGET)_maskoff.vcd)
	cd $(USCRIPTS) && $(PY) run_tvla.py \
	       --npz $(ABS)/$(TR)/$(SUF)_$(TARGET)_maskoff.npz --profile \
	       --plot $(ABS)/$(P1_OFF)_ \
	       --csv  $(ABS)/$(OUT_T1)/summary.csv
	@$(call NAME,$(ABS)/$(P1_OFF))

# ---------------------------------------------------------------------
# Functional check (DUT=wmask_shared_array only): baseline array and masked
# array side by side, psum/valid/act compared every cycle, mask_en=1 and 0.
# ---------------------------------------------------------------------
FUNC_TB  := $(SIM_P)/tb_func_wmask_shared.sv
FUNC_SRCS := $(SRC)/multiplier.sv $(SRC)/processing_element.sv $(SRC)/systolic_array.sv \
             $(RTL_P)/systolic_array_wmask_shared.sv
FUNC_VVP := $(BUILD)/func_wmask_shared$(ROWS)x$(COLS).vvp
NTILES   ?= 200
func: dirs
	@for f in $(FUNC_SRCS) $(FUNC_TB); do test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	$(IVERILOG) -g2012 -Ptb_func_wmask_shared.ROWS=$(ROWS) -Ptb_func_wmask_shared.COLS=$(COLS) \
	       -o $(FUNC_VVP) $(FUNC_SRCS) $(FUNC_TB)
	$(VVP) $(FUNC_VVP) +NTILES=$(NTILES) +SEED=$(SEED)

all:
	$(MAKE) --no-print-directory tvla2_selftest
	$(MAKE) --no-print-directory null    N=$(N) SEED=$(SEED) FIXED_W=$(FIXED_W) FIXED_A=$(FIXED_A) DUT=$(DUT) TARGET=$(TARGET) ROWS=$(ROWS) COLS=$(COLS)
	$(MAKE) --no-print-directory tvla    N=$(N) SEED=$(SEED) FIXED_W=$(FIXED_W) FIXED_A=$(FIXED_A) DUT=$(DUT) TARGET=$(TARGET) TTD=$(TTD) ROWS=$(ROWS) COLS=$(COLS)
	$(MAKE) --no-print-directory tvla2_null DUT=$(DUT) TARGET=$(TARGET) ROWS=$(ROWS) COLS=$(COLS)
	$(MAKE) --no-print-directory tvla2   TTD=$(TTD) REPEATS=$(REPEATS) DUT=$(DUT) TARGET=$(TARGET) ROWS=$(ROWS) COLS=$(COLS)
	$(MAKE) --no-print-directory adla_null DUT=$(DUT) TARGET=$(TARGET) ROWS=$(ROWS) COLS=$(COLS)
	$(MAKE) --no-print-directory adla    PERM=$(PERM) TTD=$(TTD) DUT=$(DUT) TARGET=$(TARGET) ROWS=$(ROWS) COLS=$(COLS)
	$(MAKE) --no-print-directory maskoff N=$(N) SEED=$(SEED) FIXED_W=$(FIXED_W) FIXED_A=$(FIXED_A) DUT=$(DUT) TARGET=$(TARGET) ROWS=$(ROWS) COLS=$(COLS)

# No null tests, no mask-off control: just first-order TVLA, second-order TVLA and ADLA.
main:
	$(MAKE) --no-print-directory tvla    N=$(N) SEED=$(SEED) FIXED_W=$(FIXED_W) FIXED_A=$(FIXED_A) DUT=$(DUT) TARGET=$(TARGET) TTD=$(TTD) ROWS=$(ROWS) COLS=$(COLS)
	$(MAKE) --no-print-directory tvla2   TTD=$(TTD) REPEATS=$(REPEATS) DUT=$(DUT) TARGET=$(TARGET) ROWS=$(ROWS) COLS=$(COLS)
	$(MAKE) --no-print-directory adla    PERM=$(PERM) TTD=$(TTD) DUT=$(DUT) TARGET=$(TARGET) ROWS=$(ROWS) COLS=$(COLS)

clean:
	rm -rf $(BUILD) $(TR) $(OUT_T1) $(OUT_T2) $(OUT_AD)

# =====================================================================
# Complete accelerator: protected vs unprotected, weights as the secret.
# All RTL and the functional/TVLA testbenches live in
# protected_designs/complete_accelerator/; tb_requant_latency.sv may sit in
# protected_designs/sim/. Run from security_analyses/protected.
# =====================================================================
ACC_DIR      := $(ROOT)/protected_designs/complete_accelerator
ACC_N        ?= 2000
ACC_DOM_REG  ?= 1
ACC_KEEP_VCD ?= 0
FUNC_NTEST   ?= 100
LAT_NBURST   ?= 300

ACC_COMMON := $(ACC_DIR)/multiplier.sv $(ACC_DIR)/activation_unit.sv $(ACC_DIR)/maxpool_unit.sv \
              $(ACC_DIR)/address_generator.sv $(ACC_DIR)/load_controller.sv $(ACC_DIR)/sram_2p.sv \
              $(ACC_DIR)/scratchpad.sv $(ACC_DIR)/global_buffer.sv
ACC_UNP    := $(ACC_DIR)/processing_element.sv $(ACC_DIR)/systolic_array.sv \
              $(ACC_DIR)/partial_sum_accumulators.sv $(ACC_DIR)/requantization_block.sv $(ACC_DIR)/top.sv
ACC_PROT   := $(ACC_DIR)/systolic_array_wmask_shared.sv $(ACC_DIR)/masking_gadgets.sv \
              $(ACC_DIR)/requantize_masked.sv $(ACC_DIR)/psum_accum_masked.sv \
              $(ACC_DIR)/systolic_array_wmask_shares.sv $(ACC_DIR)/top_protected.sv
ACC_SRCS_unprotected := $(ACC_COMMON) $(ACC_UNP)
ACC_SRCS_protected   := $(ACC_COMMON) $(ACC_PROT)
ACC_DEF_unprotected  :=
ACC_DEF_protected    := -DPROT -Ptb_tvla_accelerator.DOM_REG=$(ACC_DOM_REG)
# latency testbench: complete_accelerator/ if present, else protected_designs/sim/
ACC_TB_LAT  := $(firstword $(wildcard $(ACC_DIR)/tb_requant_latency.sv) \
                           $(ROOT)/protected_designs/sim/tb_requant_latency.sv)
ACC_TB_FUNC := $(ACC_DIR)/tb_accel_func.sv
ACC_TB_TVLA := $(ACC_DIR)/tb_tvla_accelerator.sv

# ---- command 1: requantizer latency + full-accelerator functional check ----
latency:
	@mkdir -p $(BUILD)
	@for f in $(ACC_COMMON) $(ACC_UNP) $(ACC_PROT) $(ACC_DIR)/msk_counts.vh $(ACC_TB_LAT) $(ACC_TB_FUNC); do \
	  test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	$(IVERILOG) -g2012 -I $(ACC_DIR) -o $(BUILD)/tb_requant_latency.vvp \
	       $(ACC_DIR)/requantization_block.sv $(ACC_DIR)/masking_gadgets.sv \
	       $(ACC_DIR)/requantize_masked.sv $(ACC_TB_LAT)
	$(VVP) $(BUILD)/tb_requant_latency.vvp +NBURST=$(LAT_NBURST) +SEED=$(SEED)
	$(IVERILOG) -g2012 -I $(ACC_DIR) -Ptb_accel_func.DOM_REG=$(ACC_DOM_REG) \
	       -o $(BUILD)/tb_accel_func.vvp $(ACC_COMMON) $(ACC_UNP) $(ACC_PROT) $(ACC_TB_FUNC)
	$(VVP) $(BUILD)/tb_accel_func.vvp +NTEST=$(FUNC_NTEST) +SEED=$(SEED)

# ---- command 2: TVLA of both accelerators, t-statistic plot only ----
tvla_all:
	$(MAKE) --no-print-directory acc_tvla ACC=unprotected
	$(MAKE) --no-print-directory acc_tvla ACC=protected
	@echo ""
	@echo "plots:"
	@for side in $(UNP) $(HERE); do \
	  ls -1 $$side/out/tvla_outputs/complete_accelerator/tvla_wt/*.png \
	        $$side/out/second_order_tvla_outputs/complete_accelerator/tvla_wt/*.png \
	        $$side/out/adla_outputs/complete_accelerator/tvla_wt/*.png; done

# one design (ACC=unprotected | protected); used by tvla_all.
# Outputs follow each side's own folder layout:
#   unprotected -> security_analyses/unprotected/{traces,out/tvla_outputs}
#   protected   -> security_analyses/protected/{traces,out/tvla_outputs}
ACC        ?= protected
ASIDE_unprotected := $(UNP)
ASIDE_protected   := $(HERE)
ASIDE  := $(ASIDE_$(ACC))
ATR    := $(ASIDE)/traces
ATAG   := complete_accelerator_wt
AOUT   := $(ASIDE)/out/tvla_outputs/complete_accelerator/tvla_wt
APFX   := $(AOUT)/complete_accelerator_$(ACC)__target-wt__1st-order
A2OUT  := $(ASIDE)/out/second_order_tvla_outputs/complete_accelerator/tvla_wt
A2PFX  := $(A2OUT)/complete_accelerator_$(ACC)__target-wt__2nd-order
AAOUT  := $(ASIDE)/out/adla_outputs/complete_accelerator/tvla_wt
AAPFX  := $(AAOUT)/complete_accelerator_$(ACC)__target-wt
acc_tvla:
	@mkdir -p $(BUILD) $(ATR) $(AOUT) $(A2OUT) $(AAOUT)
	@for f in $(ACC_SRCS_$(ACC)) $(ACC_TB_TVLA) $(ACC_DIR)/msk_counts.vh $(UNP)/sca_capture.vh; do \
	  test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	$(IVERILOG) -g2012 -I $(UNP) -I $(ACC_DIR) $(ACC_DEF_$(ACC)) -o $(BUILD)/tb_tvla_acc_$(ACC).vvp \
	       $(ACC_SRCS_$(ACC)) $(ACC_TB_TVLA)
	$(VVP) $(BUILD)/tb_tvla_acc_$(ACC).vvp +NTRACES=$(ACC_N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=wt +TAG=$(ATAG) +OUTDIR=$(ATR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(ATR)/$(ATAG).vcd \
	       --meta $(ATR)/$(ATAG).meta.csv --out $(ATR)/$(ATAG).npz
	$(if $(filter 1,$(ACC_KEEP_VCD)),,rm -f $(ATR)/$(ATAG).vcd)
	cd $(USCRIPTS) && $(PY) run_tvla.py --npz $(ATR)/$(ATAG).npz \
	       --plot $(APFX)_ --csv $(ATR)/$(ATAG)_summary.csv
	@$(call NAME,$(APFX))
	@find $(AOUT) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- second-order TVLA (same dataset) ----
	$(PY) $(HERE)/$(SCRIPTS)/run_tvla_second_order.py --npz $(ATR)/$(ATAG).npz --compare \
	       --plot $(A2PFX) --csv $(ATR)/$(ATAG)_tvla2.csv
	@$(call NAME,$(A2PFX))
	@find $(A2OUT) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- ADLA (same dataset) ----
	cd $(USCRIPTS) && $(PY) run_adla.py --npz $(ATR)/$(ATAG).npz --compare --perm $(PERM) \
	       --plot $(AAPFX) --csv $(ATR)/$(ATAG)_adla.csv
	@$(call NAME_AD,$(AAPFX))
	@find $(AAOUT) -type f -name '*.png' ! -name '*adla__statistic.png' -delete
	@rm -f $(ATR)/$(ATAG)_summary.csv $(ATR)/$(ATAG)_tvla2.csv $(ATR)/$(ATAG)_adla.csv

# =====================================================================
# Stand-alone masked requantizer TVLA (fixed vs random acc_in),
# t-statistic plot only -> security_analyses/protected/out/tvla_outputs/
# =====================================================================
RQ_N        ?= 2000
RQ_MASK_OFF ?= 0
RQ_TB    := $(TB)/tb_tvla_requantize_masked.sv
RQ_TAG   := requantize_masked_act$(if $(filter 1,$(RQ_MASK_OFF)),_maskoff,)
RQ_TR    := $(HERE)/traces
RQ_OUT   := $(HERE)/out/tvla_outputs/requantize_masked/tvla_act
RQ_BASE  := requantize_masked__target-act$(if $(filter 1,$(RQ_MASK_OFF)),__masking-off,)
RQ_PFX   := $(RQ_OUT)/$(RQ_BASE)__1st-order
RQ_OUT2  := $(HERE)/out/second_order_tvla_outputs/requantize_masked/tvla_act
RQ_PFX2  := $(RQ_OUT2)/$(RQ_BASE)__2nd-order
RQ_OUTA  := $(HERE)/out/adla_outputs/requantize_masked/tvla_act
RQ_PFXA  := $(RQ_OUTA)/$(RQ_BASE)
requant_tvla:
	@mkdir -p $(BUILD) $(RQ_TR) $(RQ_OUT) $(RQ_OUT2) $(RQ_OUTA)
	@for f in $(ACC_DIR)/masking_gadgets.sv $(ACC_DIR)/requantize_masked.sv $(ACC_DIR)/msk_counts.vh \
	          $(RQ_TB) $(UNP)/sca_capture.vh; do \
	  test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	$(IVERILOG) -g2012 -I $(UNP) -I $(ACC_DIR) -Ptb_tvla_requantize_masked.DOM_REG=$(ACC_DOM_REG) \
	       -o $(BUILD)/tb_tvla_requantize_masked.vvp \
	       $(ACC_DIR)/masking_gadgets.sv $(ACC_DIR)/requantize_masked.sv $(RQ_TB)
	$(VVP) $(BUILD)/tb_tvla_requantize_masked.vvp +NTRACES=$(RQ_N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=act +MASK_OFF=$(RQ_MASK_OFF) +TAG=$(RQ_TAG) +OUTDIR=$(RQ_TR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(RQ_TR)/$(RQ_TAG).vcd \
	       --meta $(RQ_TR)/$(RQ_TAG).meta.csv --out $(RQ_TR)/$(RQ_TAG).npz
	$(if $(filter 1,$(ACC_KEEP_VCD)),,rm -f $(RQ_TR)/$(RQ_TAG).vcd)
	cd $(USCRIPTS) && $(PY) run_tvla.py --npz $(RQ_TR)/$(RQ_TAG).npz \
	       --plot $(RQ_PFX)_ --csv $(RQ_TR)/$(RQ_TAG)_summary.csv
	@$(call NAME,$(RQ_PFX))
	@find $(RQ_OUT) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- second-order TVLA (same dataset) ----
	$(PY) $(HERE)/$(SCRIPTS)/run_tvla_second_order.py --npz $(RQ_TR)/$(RQ_TAG).npz --compare \
	       --plot $(RQ_PFX2) --csv $(RQ_TR)/$(RQ_TAG)_tvla2.csv
	@$(call NAME,$(RQ_PFX2))
	@find $(RQ_OUT2) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- ADLA (same dataset) ----
	cd $(USCRIPTS) && $(PY) run_adla.py --npz $(RQ_TR)/$(RQ_TAG).npz --compare --perm $(PERM) \
	       --plot $(RQ_PFXA) --csv $(RQ_TR)/$(RQ_TAG)_adla.csv
	@$(call NAME_AD,$(RQ_PFXA))
	@find $(RQ_OUTA) -type f -name '*.png' ! -name '*adla__statistic.png' -delete
	@rm -f $(RQ_TR)/$(RQ_TAG)_summary.csv $(RQ_TR)/$(RQ_TAG)_tvla2.csv $(RQ_TR)/$(RQ_TAG)_adla.csv
	@echo "plots:" && ls -1 $(RQ_PFX)__t-statistic.png $(RQ_PFX2)__t-statistic.png $(RQ_PFXA)__adla__statistic.png

# 2nd-order TVLA + ADLA on the EXISTING requantizer dataset (no re-simulation)
requant_2nd_adla:
	@test -f $(RQ_TR)/$(RQ_TAG).npz || { echo "  [FAIL] $(RQ_TR)/$(RQ_TAG).npz missing -- run 'make requant_tvla' first"; exit 1; }
	@mkdir -p $(RQ_OUT2) $(RQ_OUTA)
	$(PY) $(HERE)/$(SCRIPTS)/run_tvla_second_order.py --npz $(RQ_TR)/$(RQ_TAG).npz --compare \
	       --plot $(RQ_PFX2) --csv $(RQ_TR)/$(RQ_TAG)_tvla2.csv
	@$(call NAME,$(RQ_PFX2))
	@find $(RQ_OUT2) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	cd $(USCRIPTS) && $(PY) run_adla.py --npz $(RQ_TR)/$(RQ_TAG).npz --compare --perm $(PERM) \
	       --plot $(RQ_PFXA) --csv $(RQ_TR)/$(RQ_TAG)_adla.csv
	@$(call NAME_AD,$(RQ_PFXA))
	@find $(RQ_OUTA) -type f -name '*.png' ! -name '*adla__statistic.png' -delete
	@rm -f $(RQ_TR)/$(RQ_TAG)_tvla2.csv $(RQ_TR)/$(RQ_TAG)_adla.csv
	@echo "plots:" && ls -1 $(RQ_PFX2)__t-statistic.png $(RQ_PFXA)__adla__statistic.png

# =====================================================================
# Protected accelerator, three masking cases (one top file each).
# make tvla_cases   -> both, rq, arr; CASES_N traces each (default 10000)
# make acc_case CASE=both|rq|arr  -> one case
# =====================================================================
CASES_N ?= 10000
CASE    ?= both

CASE_SRCS_both := $(ACC_PROT)
CASE_SRCS_rq   := $(ACC_DIR)/processing_element.sv $(ACC_DIR)/systolic_array.sv \
                  $(ACC_DIR)/partial_sum_accumulators.sv $(ACC_DIR)/masking_gadgets.sv \
                  $(ACC_DIR)/requantize_masked.sv $(ACC_DIR)/top_protected_rq_only.sv
CASE_SRCS_arr  := $(ACC_DIR)/systolic_array_wmask_shared.sv $(ACC_DIR)/partial_sum_accumulators.sv \
                  $(ACC_DIR)/requantization_block.sv $(ACC_DIR)/top_protected_arr_only.sv
CASE_DEF_both  := -DPROT     -Ptb_tvla_accelerator.DOM_REG=$(ACC_DOM_REG)
CASE_DEF_rq    := -DRQ_ONLY  -Ptb_tvla_accelerator.DOM_REG=$(ACC_DOM_REG)
CASE_DEF_arr   := -DARR_ONLY
CASE_NAME_both := both_masked
CASE_NAME_rq   := rq_masked
CASE_NAME_arr  := arr_masked

CNAME := complete_accelerator_$(CASE_NAME_$(CASE))
CTR   := $(HERE)/traces
CTAG  := $(CNAME)_wt
COUT1 := $(HERE)/out/tvla_outputs/$(CNAME)/tvla_wt
COUT2 := $(HERE)/out/second_order_tvla_outputs/$(CNAME)/tvla_wt
COUTA := $(HERE)/out/adla_outputs/$(CNAME)/tvla_wt
CPFX1 := $(COUT1)/$(CNAME)__target-wt__1st-order
CPFX2 := $(COUT2)/$(CNAME)__target-wt__2nd-order
CPFXA := $(COUTA)/$(CNAME)__target-wt

tvla_cases:
	$(MAKE) --no-print-directory acc_case CASE=both ACC_N=$(CASES_N)
	$(MAKE) --no-print-directory acc_case CASE=rq   ACC_N=$(CASES_N)
	$(MAKE) --no-print-directory acc_case CASE=arr  ACC_N=$(CASES_N)
	@echo ""
	@echo "plots:"
	@for c in both_masked rq_masked arr_masked; do \
	  ls -1 $(HERE)/out/tvla_outputs/complete_accelerator_$$c/tvla_wt/*.png \
	        $(HERE)/out/second_order_tvla_outputs/complete_accelerator_$$c/tvla_wt/*.png \
	        $(HERE)/out/adla_outputs/complete_accelerator_$$c/tvla_wt/*.png; done

acc_case:
	@test -n "$(CASE_NAME_$(CASE))" || { echo "  [FAIL] CASE=$(CASE): use both, rq or arr"; exit 1; }
	@mkdir -p $(BUILD) $(CTR) $(COUT1) $(COUT2) $(COUTA)
	@for f in $(ACC_COMMON) $(CASE_SRCS_$(CASE)) $(ACC_TB_TVLA) $(ACC_DIR)/msk_counts.vh $(UNP)/sca_capture.vh; do \
	  test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	$(IVERILOG) -g2012 -I $(UNP) -I $(ACC_DIR) $(CASE_DEF_$(CASE)) -o $(BUILD)/tb_tvla_$(CNAME).vvp \
	       $(ACC_COMMON) $(CASE_SRCS_$(CASE)) $(ACC_TB_TVLA)
	$(VVP) $(BUILD)/tb_tvla_$(CNAME).vvp +NTRACES=$(ACC_N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=wt +TAG=$(CTAG) +OUTDIR=$(CTR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(CTR)/$(CTAG).vcd \
	       --meta $(CTR)/$(CTAG).meta.csv --out $(CTR)/$(CTAG).npz
	$(if $(filter 1,$(ACC_KEEP_VCD)),,rm -f $(CTR)/$(CTAG).vcd)
	@# ---- 1st-order TVLA ----
	cd $(USCRIPTS) && $(PY) run_tvla.py --npz $(CTR)/$(CTAG).npz \
	       --plot $(CPFX1)_ --csv $(CTR)/$(CTAG)_summary.csv
	@$(call NAME,$(CPFX1))
	@find $(COUT1) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- 2nd-order TVLA (same dataset) ----
	$(PY) $(HERE)/$(SCRIPTS)/run_tvla_second_order.py --npz $(CTR)/$(CTAG).npz --compare \
	       --plot $(CPFX2) --csv $(CTR)/$(CTAG)_tvla2.csv
	@$(call NAME,$(CPFX2))
	@find $(COUT2) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- ADLA (same dataset) ----
	cd $(USCRIPTS) && $(PY) run_adla.py --npz $(CTR)/$(CTAG).npz --compare --perm $(PERM) \
	       --plot $(CPFXA) --csv $(CTR)/$(CTAG)_adla.csv
	@$(call NAME_AD,$(CPFXA))
	@find $(COUTA) -type f -name '*.png' ! -name '*adla__statistic.png' -delete
	@rm -f $(CTR)/$(CTAG)_summary.csv $(CTR)/$(CTAG)_tvla2.csv $(CTR)/$(CTAG)_adla.csv
