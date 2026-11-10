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
# COMPLETE ACCELERATOR (weights as the secret) -- protected_designs/complete_accelerator
#   make acc_all    func_acc, then acc_random, then acc_fixed, in one command
#                   (stops at the first failure); knobs ACC_TRACES, ACC_NRQ as below
#   make func_acc   every functional bench (also: make latency)
#   make acc_random four builds (unprotected, arr, rq, both), ACTS=random,
#                   ACC_TRACES=10000 each: 1st-order TVLA, 2nd-order TVLA, ADLA
#   make acc_fixed  same, ACTS=fixed (attacker knows and fixes the inputs), DUMP_TAIL=1
#                   plots: ./out/{tvla_outputs,second_order_tvla_outputs,adla_outputs}/
#                          complete_accelerator_<build>_<acts>/
#   make acc_build ABUILD=<build> ACTS=<acts>   one build (details at the section below)
#   make requant_tvla  stand-alone masked requantizer: 1st-order TVLA,
#                   2nd-order TVLA and ADLA on acc_in (one dataset):
#                     ./out/tvla_outputs/requantize_masked/tvla_act/...t-statistic.png
#                   knobs: RQ_N=2000 traces, RQ_MASK_OFF=1 (sanity control)
#   make requant_2nd_adla  2nd-order TVLA + ADLA only, reusing the existing
#                   traces/requantize_masked_act.npz (no new simulation)
#   make shuffle_func  shuffled (unmasked) requantizer, functional check vs
#                   requantize + latency + shuffle statistics
#                   (protected_designs/source/requantize_shuffled.sv,
#                    protected_designs/sim/tb_func_requantize_shuffled.sv)
#   make shuffle_tvla  shuffled requantizer: 1st-order TVLA, 2nd-order TVLA
#                   and ADLA on acc_in (one dataset, SH_N=10000 traces):
#                     ./out/{tvla_outputs,second_order_tvla_outputs,adla_outputs}/
#                       requantize_shuffled/tvla_act/
#                   knobs: SH_N=10000, SH_OFF=1 (same hardware, shuffling off:
#                   the comparison run), SH_INORDER=0 (default: results
#                   leave unordered with a slot index; folder
#                   requantize_shuffled_ooo) or SH_INORDER=1 (results put
#                   back in arrival order; folder requantize_shuffled)
#   make shuffle_2nd_adla  2nd-order TVLA + ADLA only, reusing the existing
#                   shuffled-requantizer dataset (same SH_OFF / SH_INORDER)
#   make shuffle_cpa   does shuffling lower the CORRELATION per cycle?
#                   simulates SH_N traces with the value / issue-order log,
#                   then correlates the power at every cycle with each value
#                   in ARRIVAL order (attacker's view) and in the true ISSUE
#                   order, for four leakage models (bit count of acc+bias /
#                   of the product, and bit CHANGES from the previous value
#                   for both: hd_acc, hd_prod). Plots + per-cycle tables in
#                     ./out/cpa_outputs/<requantize_shuffled[_ooo]>/tvla_act/
#   make shuffle_cpa_only  same analysis, no new simulation (reuses the npz and
#                   _values.csv of the last run); SH_MODELS="hd_acc hd_prod"
#   Knobs: ACC_TRACES=10000 traces per build, ACC_NRQ=1, ACC_DOM_REG=1 (0 = low-latency
#          requantizer), ACC_KEEP_VCD=0 (requant/shuffle targets), FUNC_NTEST=100, LAT_NBURST=300
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
        latency func_acc acc_all acc_random acc_fixed acc_build acc_list requant_tvla requant_2nd_adla \
        shuffle_func shuffle_tvla shuffle_2nd_adla shuffle_cpa shuffle_cpa_only

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
	$(IVERILOG) -g2012 -Ptb_func_wmask_shared.N=$(ACC_N) -Ptb_func_wmask_shared.ACCW=$(ACC_ACCW) \
	       -Ptb_func_wmask_shared.ROWS=$(ACC_ROWS) -Ptb_func_wmask_shared.COLS=$(ACC_COLS) \
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
# Complete accelerator, weights as the secret: four builds, two attacker
# models. All RTL and the functional / TVLA testbenches live in
# protected_designs/complete_accelerator/ (5x5 array, WAVES = 4).
#
#   make func_acc      every functional bench (prints PASS/FAIL, latency,
#                      throughput): tb_accel_func (both / rq-only / arr-only,
#                      rq and both for NRQ = 1 2 5), tb_requant_latency,
#                      tb_func_wmask_shared (accelerator copies of the arrays)
#   make acc_random    ACTS=random (new random activations every trace, both
#                      groups), DUMP_TAIL=0, all four builds
#   make acc_fixed     ACTS=fixed (one activation tile drawn once, used in every
#                      trace of both groups: the attacker knows and fixes the
#                      inputs), DUMP_TAIL=1, all four builds
#   make acc_build ABUILD=unprotected|arr|rq|both ACTS=random|fixed   one build
#
# Capture window: from the start pulse (weight load included) until the design is
# back to idle, measured per build (94 / 100 / 137 / 143 cycles at NRQ = 1).
# Each build: one simulation of ACC_TRACES traces -> power proxy (npz) ->
# VCD deleted -> capture-window check (last 3 captured cycles idle, else the
# make stops) -> 1st-order TVLA, 2nd-order TVLA, ADLA on the same dataset.
# Only the t-statistic and adla__statistic plots are kept:
#   out/tvla_outputs/complete_accelerator_<build>_<acts>/              ..._1st-order__t-statistic.png
#   out/second_order_tvla_outputs/complete_accelerator_<build>_<acts>/ ..._2nd-order__t-statistic.png
#   out/adla_outputs/complete_accelerator_<build>_<acts>/              ..._adla__statistic.png
# Knobs: ACC_TRACES=10000  ACC_NRQ=1 (shared masked requantizer cores in the
#        rq / both builds)  ACC_DOM_REG=1  SEED=1  PERM=500
#        DUMP_TAIL (default 1 for ACTS=fixed, 0 for ACTS=random)
#        FUNC_NTEST=100 LAT_NBURST=300 NTILES=200
# =====================================================================
ACC_DIR      := $(ROOT)/protected_designs/complete_accelerator
ACC_TRACES   ?= 10000
ACC_NRQ      ?= 1
ACC_DOM_REG  ?= 1
FUNC_NTEST   ?= 100
LAT_NBURST   ?= 300
ABUILD       ?= both
ACTS         ?= random
DUMP_TAIL    ?= $(if $(filter fixed,$(ACTS)),1,0)

ACC_COMMON := $(ACC_DIR)/multiplier.sv $(ACC_DIR)/activation_unit.sv $(ACC_DIR)/maxpool_unit.sv \
              $(ACC_DIR)/address_generator.sv $(ACC_DIR)/load_controller.sv $(ACC_DIR)/sram_2p.sv \
              $(ACC_DIR)/scratchpad.sv $(ACC_DIR)/global_buffer.sv $(ACC_DIR)/bias_scale.sv
ACC_UNP    := $(ACC_DIR)/processing_element.sv $(ACC_DIR)/systolic_array.sv \
              $(ACC_DIR)/partial_sum_accumulators.sv $(ACC_DIR)/requantization_block.sv $(ACC_DIR)/top.sv
ACC_PROT   := $(ACC_DIR)/systolic_array_wmask_shared.sv $(ACC_DIR)/systolic_array_wmask_shares.sv \
              $(ACC_DIR)/psum_accum_masked.sv $(ACC_DIR)/masking_gadgets.sv $(ACC_DIR)/requantize_masked.sv \
              $(ACC_DIR)/rq_share_server.sv $(ACC_DIR)/top_protected.sv \
              $(ACC_DIR)/top_protected_rq_only.sv $(ACC_DIR)/top_protected_arr_only.sv
ACC_TB_LAT  := $(ACC_DIR)/tb_requant_latency.sv
ACC_TB_FUNC := $(ACC_DIR)/tb_accel_func.sv
ACC_TB_TVLA := $(ACC_DIR)/tb_tvla_accelerator.sv

# per-build sources / defines / parameters
BSRC_unprotected := $(ACC_UNP)
BSRC_arr  := $(ACC_DIR)/systolic_array_wmask_shared.sv $(ACC_DIR)/partial_sum_accumulators.sv \
             $(ACC_DIR)/requantization_block.sv $(ACC_DIR)/top_protected_arr_only.sv
BSRC_rq   := $(ACC_DIR)/processing_element.sv $(ACC_DIR)/systolic_array.sv \
             $(ACC_DIR)/partial_sum_accumulators.sv $(ACC_DIR)/masking_gadgets.sv \
             $(ACC_DIR)/requantize_masked.sv $(ACC_DIR)/rq_share_server.sv $(ACC_DIR)/top_protected_rq_only.sv
BSRC_both := $(ACC_DIR)/systolic_array_wmask_shared.sv $(ACC_DIR)/systolic_array_wmask_shares.sv \
             $(ACC_DIR)/psum_accum_masked.sv $(ACC_DIR)/masking_gadgets.sv $(ACC_DIR)/requantize_masked.sv \
             $(ACC_DIR)/rq_share_server.sv $(ACC_DIR)/top_protected.sv
# One parameter set for every accelerator build and bench (fair comparison):
# the same values are passed explicitly to all four builds, so a changed RTL or
# testbench default cannot make the builds diverge. Fixed by the brief (5x5,
# WAVES=4); ACCW = 2N + clog2(ROWS) = 19 in all builds.
ACC_N    := 8
ACC_ROWS := 5
ACC_COLS := 5
ACC_WAVES:= 4
ACC_ACCW := 19
ACC_MW   := 16
ACC_SW   := 6
ACC_BW   := 32
ACC_POOL := 1
accp = -P$(1).N=$(ACC_N) -P$(1).ROWS=$(ACC_ROWS) -P$(1).COLS=$(ACC_COLS) -P$(1).WAVES=$(ACC_WAVES) \
       -P$(1).ACCW=$(ACC_ACCW) -P$(1).MW=$(ACC_MW) -P$(1).SW=$(ACC_SW) -P$(1).BW=$(ACC_BW) \
       -P$(1).POOL_LEN=$(ACC_POOL) -P$(1).DOM_REG=$(ACC_DOM_REG) -P$(1).NRQ=$(ACC_NRQ)
BDEF_unprotected := $(call accp,tb_tvla_accelerator)
BDEF_arr  := -DARR_ONLY $(call accp,tb_tvla_accelerator)
BDEF_rq   := -DRQ_ONLY  $(call accp,tb_tvla_accelerator)
BDEF_both := -DPROT     $(call accp,tb_tvla_accelerator)

# ---- every functional bench ----
FNRQS ?= 1 2 5
func_acc:
	@mkdir -p $(BUILD)
	@for f in $(ACC_COMMON) $(ACC_UNP) $(ACC_PROT) $(ACC_DIR)/msk_counts.vh $(ACC_TB_LAT) $(ACC_TB_FUNC) $(FUNC_TB); do \
	  test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	@for v in PROT RQ_ONLY ARR_ONLY; do \
	  nl="$(FNRQS)"; [ $$v = ARR_ONLY ] && nl=5; \
	  for n in $$nl; do \
	    echo "=== tb_accel_func $$v NRQ=$$n"; \
	    $(IVERILOG) -g2012 -I $(ACC_DIR) $$( [ $$v = PROT ] || echo -D$$v ) $(call accp,tb_accel_func) \
	      -Ptb_accel_func.NRQ=$$n -o $(BUILD)/tb_accel_func_$$v$$n.vvp \
	      $(ACC_COMMON) $(ACC_UNP) $(ACC_PROT) $(ACC_TB_FUNC) || exit 1; \
	    $(VVP) -n $(BUILD)/tb_accel_func_$$v$$n.vvp +NTEST=$(FUNC_NTEST) +SEED=$(SEED) | sed -n '/=====/,$$p'; \
	  done; done
	@echo "=== tb_requant_latency"
	$(IVERILOG) -g2012 -I $(ACC_DIR) -o $(BUILD)/tb_requant_latency.vvp \
	       $(ACC_DIR)/requantization_block.sv $(ACC_DIR)/masking_gadgets.sv \
	       $(ACC_DIR)/requantize_masked.sv $(ACC_TB_LAT)
	$(VVP) -n $(BUILD)/tb_requant_latency.vvp +NBURST=$(LAT_NBURST) +SEED=$(SEED)
	@echo "=== tb_func_wmask_shared (accelerator copies of the arrays)"
	$(IVERILOG) -g2012 -Ptb_func_wmask_shared.N=$(ACC_N) -Ptb_func_wmask_shared.ACCW=$(ACC_ACCW) \
	       -Ptb_func_wmask_shared.ROWS=$(ACC_ROWS) -Ptb_func_wmask_shared.COLS=$(ACC_COLS) \
	       -o $(BUILD)/func_wmask_shared_acc.vvp $(ACC_DIR)/multiplier.sv $(ACC_DIR)/processing_element.sv \
	       $(ACC_DIR)/systolic_array.sv $(ACC_DIR)/systolic_array_wmask_shared.sv $(FUNC_TB)
	$(VVP) -n $(BUILD)/func_wmask_shared_acc.vvp +NTILES=$(NTILES) +SEED=$(SEED)
latency: func_acc

# ---- everything in one command: functional benches, then both attacker models ----
acc_all:
	$(MAKE) --no-print-directory func_acc SEED=$(SEED)
	$(MAKE) --no-print-directory acc_random ACC_TRACES=$(ACC_TRACES) ACC_NRQ=$(ACC_NRQ) SEED=$(SEED) PERM=$(PERM)
	$(MAKE) --no-print-directory acc_fixed  ACC_TRACES=$(ACC_TRACES) ACC_NRQ=$(ACC_NRQ) SEED=$(SEED) PERM=$(PERM)

# ---- one command per attacker model: all four builds ----
acc_random:
	@for b in unprotected arr rq both; do \
	  $(MAKE) --no-print-directory acc_build ABUILD=$$b ACTS=random ACC_TRACES=$(ACC_TRACES) \
	          ACC_NRQ=$(ACC_NRQ) SEED=$(SEED) PERM=$(PERM) || exit 1; done
	@$(MAKE) --no-print-directory acc_list ACTS=random

acc_fixed:
	@for b in unprotected arr rq both; do \
	  $(MAKE) --no-print-directory acc_build ABUILD=$$b ACTS=fixed ACC_TRACES=$(ACC_TRACES) \
	          ACC_NRQ=$(ACC_NRQ) SEED=$(SEED) PERM=$(PERM) || exit 1; done
	@$(MAKE) --no-print-directory acc_list ACTS=fixed

acc_list:
	@echo ""
	@echo "plots (ACTS=$(ACTS)):"
	@for b in unprotected arr rq both; do \
	  ls -1 $(HERE)/out/tvla_outputs/complete_accelerator_$${b}_$(ACTS)/*.png \
	        $(HERE)/out/second_order_tvla_outputs/complete_accelerator_$${b}_$(ACTS)/*.png \
	        $(HERE)/out/adla_outputs/complete_accelerator_$${b}_$(ACTS)/*.png 2>/dev/null; done

# ---- one build, one attacker model ----
BNAME := complete_accelerator_$(ABUILD)_$(ACTS)
BTR   := $(HERE)/traces
BTAG  := $(BNAME)
BOUT1 := $(HERE)/out/tvla_outputs/$(BNAME)
BOUT2 := $(HERE)/out/second_order_tvla_outputs/$(BNAME)
BOUTA := $(HERE)/out/adla_outputs/$(BNAME)
BPFX1 := $(BOUT1)/$(BNAME)__target-wt__1st-order
BPFX2 := $(BOUT2)/$(BNAME)__target-wt__2nd-order
BPFXA := $(BOUTA)/$(BNAME)__target-wt
acc_build:
	@test -n "$(filter unprotected arr rq both,$(ABUILD))" || { echo "  [FAIL] ABUILD=$(ABUILD): use unprotected, arr, rq or both"; exit 1; }
	@test -n "$(filter random fixed,$(ACTS))" || { echo "  [FAIL] ACTS=$(ACTS): use random or fixed"; exit 1; }
	@mkdir -p $(BUILD) $(BTR) $(BOUT1) $(BOUT2) $(BOUTA)
	@for f in $(ACC_COMMON) $(BSRC_$(ABUILD)) $(ACC_TB_TVLA) $(ACC_DIR)/msk_counts.vh $(UNP)/sca_capture.vh; do \
	  test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	@echo "=== $(BNAME): $(ACC_TRACES) traces, $(ACC_ROWS)x$(ACC_COLS) WAVES=$(ACC_WAVES) ACCW=$(ACC_ACCW) MW=$(ACC_MW) NRQ=$(ACC_NRQ) DOM_REG=$(ACC_DOM_REG), DUMP_TAIL=$(DUMP_TAIL)"
	$(IVERILOG) -g2012 -I $(UNP) -I $(ACC_DIR) $(BDEF_$(ABUILD)) -o $(BUILD)/tb_tvla_$(BNAME).vvp \
	       $(ACC_COMMON) $(BSRC_$(ABUILD)) $(ACC_TB_TVLA)
	$(VVP) -n $(BUILD)/tb_tvla_$(BNAME).vvp +NTRACES=$(ACC_TRACES) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=wt +ACTS=$(ACTS) +DUMP_TAIL=$(DUMP_TAIL) +TAG=$(BTAG) +OUTDIR=$(BTR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(BTR)/$(BTAG).vcd \
	       --meta $(BTR)/$(BTAG).meta.csv --out $(BTR)/$(BTAG).npz
	rm -f $(BTR)/$(BTAG).vcd
	@# ---- capture-window check: last 3 captured cycles must be idle ----
	$(PY) $(HERE)/$(SCRIPTS)/check_capture_idle.py --npz $(BTR)/$(BTAG).npz --idle 3
	@# ---- 1st-order TVLA ----
	cd $(USCRIPTS) && $(PY) run_tvla.py --npz $(BTR)/$(BTAG).npz \
	       --plot $(BPFX1)_ --csv $(BTR)/$(BTAG)_summary.csv
	@$(call NAME,$(BPFX1))
	@find $(BOUT1) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- 2nd-order TVLA (same dataset) ----
	$(PY) $(HERE)/$(SCRIPTS)/run_tvla_second_order.py --npz $(BTR)/$(BTAG).npz --compare \
	       --plot $(BPFX2) --csv $(BTR)/$(BTAG)_tvla2.csv
	@$(call NAME,$(BPFX2))
	@find $(BOUT2) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- ADLA (same dataset) ----
	cd $(USCRIPTS) && $(PY) run_adla.py --npz $(BTR)/$(BTAG).npz --compare --perm $(PERM) \
	       --plot $(BPFXA) --csv $(BTR)/$(BTAG)_adla.csv
	@$(call NAME_AD,$(BPFXA))
	@find $(BOUTA) -type f -name '*.png' ! -name '*adla__statistic.png' -delete
	@rm -f $(BTR)/$(BTAG)_summary.csv $(BTR)/$(BTAG)_tvla2.csv $(BTR)/$(BTAG)_adla.csv

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
# Shuffled (unmasked) requantizer -- protected_designs/source/
#   make shuffle_func        functional check + latency + shuffle statistics
#   make shuffle_tvla        1st-order TVLA, 2nd-order TVLA, ADLA (SH_N traces)
#   make shuffle_2nd_adla    2nd-order TVLA + ADLA on the existing dataset
# Knobs: SH_N=10000  SH_OFF=0|1  SH_INORDER=0|1 (default 0)  SH_NTEST=300
# =====================================================================
SH_N       ?= 10000
SH_OFF     ?= 0
SH_INORDER ?= 0
SH_NTEST   ?= 300
SH_RTL   := $(SRC)/requantization_block.sv $(RTL_P)/requantize_shuffled.sv
SH_TB    := $(TB)/tb_tvla_requantize_shuffled.sv
SH_FTB   := $(SIM_P)/tb_func_requantize_shuffled.sv
SH_NAME  := requantize_shuffled$(if $(filter 0,$(SH_INORDER)),_ooo,)
SH_TAG   := $(SH_NAME)_act$(if $(filter 1,$(SH_OFF)),_shufoff,)
SH_TR    := $(HERE)/traces
SH_BASE  := $(SH_NAME)__target-act$(if $(filter 1,$(SH_OFF)),__shuffling-off,)
SH_OUT1  := $(HERE)/out/tvla_outputs/$(SH_NAME)/tvla_act
SH_OUT2  := $(HERE)/out/second_order_tvla_outputs/$(SH_NAME)/tvla_act
SH_OUTA  := $(HERE)/out/adla_outputs/$(SH_NAME)/tvla_act
SH_PFX1  := $(SH_OUT1)/$(SH_BASE)__1st-order
SH_PFX2  := $(SH_OUT2)/$(SH_BASE)__2nd-order
SH_PFXA  := $(SH_OUTA)/$(SH_BASE)

shuffle_func:
	@mkdir -p $(BUILD)
	@for f in $(SH_RTL) $(SH_FTB); do test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	$(IVERILOG) -g2012 -o $(BUILD)/tb_func_requantize_shuffled.vvp $(SH_RTL) $(SH_FTB)
	$(VVP) $(BUILD)/tb_func_requantize_shuffled.vvp +NTEST=$(SH_NTEST) +SEED=$(SEED)

shuffle_tvla:
	@mkdir -p $(BUILD) $(SH_TR) $(SH_OUT1) $(SH_OUT2) $(SH_OUTA)
	@for f in $(SH_RTL) $(SH_TB) $(UNP)/sca_capture.vh; do \
	  test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	$(IVERILOG) -g2012 -I $(UNP) -Ptb_tvla_requantize_shuffled.INORDER=$(SH_INORDER) \
	       -o $(BUILD)/tb_tvla_$(SH_NAME).vvp $(SH_RTL) $(SH_TB)
	$(VVP) $(BUILD)/tb_tvla_$(SH_NAME).vvp +NTRACES=$(SH_N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=act +SHUF_OFF=$(SH_OFF) +VALLOG=1 +TAG=$(SH_TAG) +OUTDIR=$(SH_TR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(SH_TR)/$(SH_TAG).vcd \
	       --meta $(SH_TR)/$(SH_TAG).meta.csv --out $(SH_TR)/$(SH_TAG).npz
	$(if $(filter 1,$(ACC_KEEP_VCD)),,rm -f $(SH_TR)/$(SH_TAG).vcd)
	@# ---- 1st-order TVLA ----
	cd $(USCRIPTS) && $(PY) run_tvla.py --npz $(SH_TR)/$(SH_TAG).npz \
	       --plot $(SH_PFX1)_ --csv $(SH_TR)/$(SH_TAG)_summary.csv
	@$(call NAME,$(SH_PFX1))
	@find $(SH_OUT1) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@$(MAKE) --no-print-directory shuffle_2nd_adla SH_OFF=$(SH_OFF) SH_INORDER=$(SH_INORDER)
	@rm -f $(SH_TR)/$(SH_TAG)_summary.csv
	@echo "plots:" && ls -1 $(SH_PFX1)__t-statistic.png $(SH_PFX2)__t-statistic.png $(SH_PFXA)__adla__statistic.png

shuffle_2nd_adla:
	@test -f $(SH_TR)/$(SH_TAG).npz || { echo "  [FAIL] $(SH_TR)/$(SH_TAG).npz missing -- run 'make shuffle_tvla' first"; exit 1; }
	@mkdir -p $(SH_OUT2) $(SH_OUTA)
	@# ---- 2nd-order TVLA (same dataset) ----
	$(PY) $(HERE)/$(SCRIPTS)/run_tvla_second_order.py --npz $(SH_TR)/$(SH_TAG).npz --compare \
	       --plot $(SH_PFX2) --csv $(SH_TR)/$(SH_TAG)_tvla2.csv
	@$(call NAME,$(SH_PFX2))
	@find $(SH_OUT2) -type f -name '*.png' ! -name '*t-statistic.png' -delete
	@# ---- ADLA (same dataset) ----
	cd $(USCRIPTS) && $(PY) run_adla.py --npz $(SH_TR)/$(SH_TAG).npz --compare --perm $(PERM) \
	       --plot $(SH_PFXA) --csv $(SH_TR)/$(SH_TAG)_adla.csv
	@$(call NAME_AD,$(SH_PFXA))
	@find $(SH_OUTA) -type f -name '*.png' ! -name '*adla__statistic.png' -delete
	@rm -f $(SH_TR)/$(SH_TAG)_tvla2.csv $(SH_TR)/$(SH_TAG)_adla.csv

# ---- correlation (CPA) view of the shuffled requantizer ----
SH_OUTC  := $(HERE)/out/cpa_outputs/$(SH_NAME)/tvla_act
SH_PFXC  := $(SH_OUTC)/$(SH_BASE)

shuffle_cpa:
	@mkdir -p $(BUILD) $(SH_TR) $(SH_OUTC)
	@for f in $(SH_RTL) $(SH_TB) $(UNP)/sca_capture.vh $(HERE)/$(SCRIPTS)/run_cpa_shuffle.py; do \
	  test -f $$f || { echo "  [FAIL] $$f missing"; exit 1; }; done
	$(IVERILOG) -g2012 -I $(UNP) -Ptb_tvla_requantize_shuffled.INORDER=$(SH_INORDER) \
	       -o $(BUILD)/tb_tvla_$(SH_NAME).vvp $(SH_RTL) $(SH_TB)
	$(VVP) $(BUILD)/tb_tvla_$(SH_NAME).vvp +NTRACES=$(SH_N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=act +SHUF_OFF=$(SH_OFF) +VALLOG=1 +TAG=$(SH_TAG) +OUTDIR=$(SH_TR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(SH_TR)/$(SH_TAG).vcd \
	       --meta $(SH_TR)/$(SH_TAG).meta.csv --out $(SH_TR)/$(SH_TAG).npz
	$(if $(filter 1,$(ACC_KEEP_VCD)),,rm -f $(SH_TR)/$(SH_TAG).vcd)
	@$(MAKE) --no-print-directory shuffle_cpa_only SH_OFF=$(SH_OFF) SH_INORDER=$(SH_INORDER)

# correlation analysis only, on the dataset of the last shuffle_cpa / shuffle_tvla run
SH_MODELS ?= acc prod hd_acc hd_prod
shuffle_cpa_only:
	@test -f $(SH_TR)/$(SH_TAG).npz -a -f $(SH_TR)/$(SH_TAG)_values.csv || \
	  { echo "  [FAIL] $(SH_TR)/$(SH_TAG).npz or _values.csv missing -- run 'make shuffle_cpa' first"; exit 1; }
	@mkdir -p $(SH_OUTC)
	@for m in $(SH_MODELS); do \
	  $(PY) $(HERE)/$(SCRIPTS)/run_cpa_shuffle.py --npz $(SH_TR)/$(SH_TAG).npz \
	       --values $(SH_TR)/$(SH_TAG)_values.csv --model $$m \
	       --plot $(SH_PFXC)__model-$$m --csv $(SH_PFXC)__model-$$m__cpa.csv > /dev/null || exit 1; \
	  echo "  model $$m done"; done
	@echo "plots:" && ls -1 $(SH_OUTC)/*.png