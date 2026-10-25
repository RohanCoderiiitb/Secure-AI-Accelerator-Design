# =====================================================================
# Side-channel leakage assessment -- PROTECTED designs
# =====================================================================
# Run every target from this directory (security_analyses/protected).
#
# Layout this Makefile expects:
#   ../../protected_designs/source/masked_wt_multiplier.sv      weight masked (also holds share_multiplier)
#   ../../protected_designs/source/masked_act_multiplier.sv     activation masked
#   ../../protected_designs/source/masked_act_wt_multiplier.sv  activation + weight masked
#   ../unprotected/sca_capture.vh                         shared capture header
#   ../unprotected/scripts/{vcd_power,run_tvla,tvla}.py   shared analysis
#   ./scripts/run_tvla_second_order.py                    second-order TVLA
#   ./tb/tb_tvla_masked_wt_mult.sv                           testbench (weight masked)
#   ./tb/tvla_tb_masked_act_multiplier.sv                    testbench (activation masked)
#   ./tb/tb_tvla_masked_act_wt_mult.sv                        testbench (act + weight masked)
#   ./build ./traces ./out                                generated
#
# Outputs
#   out/tvla_outputs/<mult>_multiplier/tvla_<target>/              first-order plots (+ summary.csv)
#   out/second_order_tvla_outputs/<mult>_multiplier/tvla_<target>/ second-order plots (+ tvla2_summary.csv)
#   <mult> = wt_masked | act_masked | act_wt_masked
#
# ---------------------------------------------------------------------
# Pick the design with DUT=
#   DUT=masked_mult      weight-masked multiplier      (TARGET is wt)
#   DUT=masked_act_mult  activation-masked only        (TARGET is act)
#   DUT=masked_mult_aw   activation + weight masked    (TARGET=act default, or wt)
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
#
#   make all                     everything above in that order
# ---------------------------------------------------------------------
# Knobs
#   N=131072     traces. 131072 = exhaustive: random group covers all
#                256 x 256 (weight, activation) pairs once; fixed group
#                covers every activation 256 times. Smaller N = random
#                subset (e.g. N=20000 for a quick run).
#   SEED=1
#   FIXED_W=-77  fixed-group weight     (signed decimal, TARGET=wt)
#   FIXED_A=93   fixed-group activation (signed decimal, TARGET=act)
#   REPEATS=20   subsets per point in a TTD sweep
#   TTD=1        set TTD=0 to skip the TTD sweep (it is the slow part
#                of the analysis at N=131072)
#
# Disk: the exhaustive VCD is several hundred MB.
# =====================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PY       ?= python3

RTL_P    := ../../protected_designs/source
UNP      := ../unprotected
USCRIPTS := $(UNP)/scripts
SCRIPTS  := scripts
TB       := tb
BUILD    := build
TR       := traces
OUT      := out
OUT_T1   := $(OUT)/tvla_outputs
OUT_T2   := $(OUT)/second_order_tvla_outputs

IVFLAGS  ?= -g2012 -I $(UNP) -I $(TB)

# --- knobs -----------------------------------------------------------
N       ?= 131072
SEED    ?= 1
FIXED_W ?= -77
FIXED_A ?= 93
REPEATS ?= 20
TTD     ?= 1

# --- DUT -------------------------------------------------------------
DUT  ?= masked_mult
ifeq ($(DUT),masked_mult)
  SRCS   := $(RTL_P)/masked_wt_multiplier.sv
  TBF    := $(TB)/tb_tvla_masked_wt_mult.sv
  TARGET := wt
else ifeq ($(DUT),masked_mult_aw)
  SRCS   := $(RTL_P)/masked_wt_multiplier.sv $(RTL_P)/masked_act_wt_multiplier.sv
  TBF    := $(TB)/tb_tvla_masked_act_wt_mult.sv
  TARGET ?= act
else ifeq ($(DUT),masked_act_mult)
  SRCS   := $(RTL_P)/masked_wt_multiplier.sv $(RTL_P)/masked_act_multiplier.sv
  TBF    := $(TB)/tvla_tb_masked_act_multiplier.sv
  TARGET := act
else
  $(error unknown DUT=$(DUT): use masked_mult, masked_act_mult or masked_mult_aw)
endif

# human-readable multiplier name + per-run output directories / plot prefixes
#   out/<order>_outputs/<mult>_multiplier/tvla_<target>/<mult>__target-<target>[__masking-off]__<1st|2nd>-order__<plot>.png
MULT_NAME := $(strip $(if $(filter masked_mult,$(DUT)),wt_masked,$(if $(filter masked_act_mult,$(DUT)),act_masked,act_wt_masked)))
RUN_SUB   := $(MULT_NAME)_multiplier/tvla_$(TARGET)
RUN_BASE  := $(MULT_NAME)__target-$(TARGET)
P1        := $(OUT_T1)/$(RUN_SUB)/$(RUN_BASE)__1st-order
P1_OFF    := $(OUT_T1)/$(RUN_SUB)/$(RUN_BASE)__masking-off__1st-order
P2        := $(OUT_T2)/$(RUN_SUB)/$(RUN_BASE)__2nd-order

# scripts emit <prefix>_{t,mean,var,ttd}.png; give them descriptive names
# usage: $(call NAME,<prefix>,<order>)
NAME = for pair in t:t-statistic mean:mean-power-trace var:variance-trace ttd:time-to-detection; do \
  for sep in _ __; do f=$(1)$$sep$${pair%%:*}.png; [ -f $$f ] && mv $$f $(1)__$${pair#*:}.png; done; done; true

FIXARGS := +FIXED_W=$(FIXED_W) +FIXED_A=$(FIXED_A)
SUF   := $(DUT)
VVPF  := $(BUILD)/tb_$(SUF).vvp
ABS   := $(CURDIR)
TTDF  := $(if $(filter 1,$(TTD)),--ttd --repeats $(REPEATS),)

.PHONY: dirs check build null tvla tvla2_selftest tvla2_null tvla2 \
        maskoff all clean

dirs:
	@mkdir -p $(BUILD) $(TR) $(OUT_T1)/$(RUN_SUB) $(OUT_T2)/$(RUN_SUB)

check:
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
	$(IVERILOG) $(IVFLAGS) -o $(VVPF) $(SRCS) $(TBF)

# ---------------------------------------------------------------------
# First-order TVLA. Null test first, always.
# ---------------------------------------------------------------------
null: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=null +TVLA_TARGET=$(TARGET) \
	       $(FIXARGS) +TAG=$(SUF)_$(TARGET)_null +OUTDIR=$(TR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET)_null.vcd \
	       --meta $(TR)/$(SUF)_$(TARGET)_null.meta.csv --out $(TR)/$(SUF)_$(TARGET)_null.npz
	cd $(USCRIPTS) && $(PY) run_tvla.py --npz $(ABS)/$(TR)/$(SUF)_$(TARGET)_null.npz --null

tvla: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=tvla +TVLA_TARGET=$(TARGET) \
	       $(FIXARGS) +TAG=$(SUF)_$(TARGET) +OUTDIR=$(TR)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET).vcd \
	       --meta $(TR)/$(SUF)_$(TARGET).meta.csv --out $(TR)/$(SUF)_$(TARGET).npz
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
	cd $(USCRIPTS) && $(PY) run_tvla.py \
	       --npz $(ABS)/$(TR)/$(SUF)_$(TARGET)_maskoff.npz --profile \
	       --plot $(ABS)/$(P1_OFF)_ \
	       --csv  $(ABS)/$(OUT_T1)/summary.csv
	@$(call NAME,$(ABS)/$(P1_OFF))

all:
	$(MAKE) --no-print-directory tvla2_selftest
	$(MAKE) --no-print-directory null    N=$(N) SEED=$(SEED) FIXED_W=$(FIXED_W) FIXED_A=$(FIXED_A) DUT=$(DUT) TARGET=$(TARGET)
	$(MAKE) --no-print-directory tvla    N=$(N) SEED=$(SEED) FIXED_W=$(FIXED_W) FIXED_A=$(FIXED_A) DUT=$(DUT) TARGET=$(TARGET) TTD=$(TTD)
	$(MAKE) --no-print-directory tvla2_null DUT=$(DUT) TARGET=$(TARGET)
	$(MAKE) --no-print-directory tvla2   TTD=$(TTD) REPEATS=$(REPEATS) DUT=$(DUT) TARGET=$(TARGET)
	$(MAKE) --no-print-directory maskoff N=$(N) SEED=$(SEED) FIXED_W=$(FIXED_W) FIXED_A=$(FIXED_A) DUT=$(DUT) TARGET=$(TARGET)

clean:
	rm -rf $(BUILD) $(TR) $(OUT_T1) $(OUT_T2)
