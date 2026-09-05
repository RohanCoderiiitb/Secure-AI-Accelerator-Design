# =====================================================================
# Tier 0 RTL TVLA pipeline
# =====================================================================
# Usage
#   make null DUT=pe                  # ALWAYS run this first
#   make tvla DUT=pe
#   make sweep                        # array-size ladder
#   make all
#
# Knobs
#   N=2000        traces (split 50/50)
#   SEED=1
#   TARGET=act    act | wt | both | row0 -- which operand carries the contrast
#   ROWS=/COLS=   systolic array geometry (DUT=array only)
#   ACT_MODE=1    activation function: 0=PASS 1=RELU 2=RELU_CLIP 3=LEAKY_RELU
#                 (DUT=act only; suffix _relu/_pass etc. is appended to TAG)
#   WIN_LEN=8     pooling window size (DUT=maxpool only)
#   PERM=500      label permutations for the ADLA threshold
#
# ADLA and second-order TVLA reuse the TVLA dataset -- no re-simulation:
#   make tvla DUT=pe   then   make adla DUT=pe      (or just: make both DUT=pe)
#   make tvla2 DUT=pe            univariate 2nd order (parallel masking)
#   make tvla2_biv DUT=pe        all cycle pairs (serialised masking/shuffling)
#   make allorders DUT=pe        capture once, then 1st + ADLA + 2nd order
#   make tvla2_all               univariate 2nd order on every block
# =====================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PY       ?= python3
IVFLAGS  ?= -g2012 -I tb

N        ?= 2000
SEED     ?= 1
TARGET   ?= act
ROWS     ?= 5
COLS     ?= 5
REPEATS  ?= 20
PERM     ?= 500    # label permutations for the ADLA empirical threshold
ACT_MODE ?= 1      # 0=PASS 1=RELU 2=RELU_CLIP 3=LEAKY_RELU (DUT=act only)
WIN_LEN  ?= 8      # pooling window length (DUT=maxpool only)

RTL   := ../source
TB    := tb
BUILD := build
TR    := traces
OUT   := out

SRC_MULT      := $(RTL)/multiplier.sv
SRC_PE        := $(RTL)/multiplier.sv $(RTL)/processing_element.sv
SRC_ARRAY     := $(RTL)/multiplier.sv $(RTL)/processing_element.sv $(RTL)/systolic_array.sv
SRC_PSUM      := $(RTL)/partial_sum_accumulators.sv
SRC_OUT       := $(RTL)/requantization_block.sv $(RTL)/activation_unit.sv
SRC_REQUANT   := $(RTL)/requantization_block.sv
SRC_ACT       := $(RTL)/activation_unit.sv
SRC_MAXPOOL   := $(RTL)/maxpool_unit.sv

DUT ?= pe

PARAMS  :=
VVP_EXTRA :=

ifeq ($(DUT),mult)
  SRCS := $(SRC_MULT)
  TBF  := $(TB)/tb_tvla_mult.sv
endif
ifeq ($(DUT),mac)
  SRCS := $(SRC_PE)
  TBF  := $(TB)/tb_tvla_mac.sv
endif
ifeq ($(DUT),pe)
  SRCS := $(SRC_PE)
  TBF  := $(TB)/tb_tvla_pe.sv
endif
ifeq ($(DUT),array)
  SRCS   := $(SRC_ARRAY)
  TBF    := $(TB)/tb_tvla_array.sv
  PARAMS := -Ptb_tvla_array.ROWS=$(ROWS) -Ptb_tvla_array.COLS=$(COLS)
endif
ifeq ($(DUT),psum)
  SRCS := $(SRC_PSUM)
  TBF  := $(TB)/tb_tvla_psum.sv
endif
ifeq ($(DUT),outstage)
  SRCS := $(SRC_OUT)
  TBF  := $(TB)/tb_tvla_output_stage.sv
endif
ifeq ($(DUT),requantize)
  SRCS := $(SRC_REQUANT)
  TBF  := $(TB)/tb_tvla_requantize.sv
endif
ifeq ($(DUT),act)
  SRCS      := $(SRC_ACT)
  TBF       := $(TB)/tb_tvla_act.sv
  VVP_EXTRA := +ACT_MODE=$(ACT_MODE)
endif
ifeq ($(DUT),maxpool)
  SRCS      := $(SRC_MAXPOOL)
  TBF       := $(TB)/tb_tvla_maxpool.sv
  VVP_EXTRA := +WIN_LEN=$(WIN_LEN)
endif

ifeq ($(DUT),array)
  SUF := $(DUT)$(ROWS)x$(COLS)
else ifeq ($(DUT),act)
  # Append mode name so per-mode traces don't overwrite each other
  ACT_NAMES := pass relu relu_clip leaky
  SUF := $(DUT)_$(word $(shell echo $$(($(ACT_MODE)+1))),$(ACT_NAMES))
else
  SUF := $(DUT)
endif

VVPF := $(BUILD)/tb_$(SUF).vvp

.PHONY: all dirs build null tvla adla adla_null tvla2 tvla2_null tvla2_biv \
        tvla2_selftest tvla2_all both allorders sweep act_all clean

dirs:
	@mkdir -p $(BUILD) $(TR) $(OUT)

build: dirs
	$(IVERILOG) $(IVFLAGS) $(PARAMS) -o $(VVPF) $(SRCS) $(TBF)

# ---------------------------------------------------------------------
# Null test. Non-negotiable prerequisite for interpreting any result.
# ---------------------------------------------------------------------
null: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=null \
	       +TVLA_TARGET=$(TARGET) $(VVP_EXTRA) +TAG=$(SUF)_null
	$(PY) scripts/vcd_power.py --vcd $(TR)/$(SUF)_null.vcd \
	       --meta $(TR)/$(SUF)_null.meta.csv --out $(TR)/$(SUF)_null.npz
	cd scripts && $(PY) run_tvla.py --npz ../$(TR)/$(SUF)_null.npz --null

# ---------------------------------------------------------------------
# Fixed vs random
# ---------------------------------------------------------------------
tvla: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=$(TARGET) $(VVP_EXTRA) +TAG=$(SUF)_$(TARGET)
	$(PY) scripts/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET).vcd \
	       --meta $(TR)/$(SUF)_$(TARGET).meta.csv --out $(TR)/$(SUF)_$(TARGET).npz
	cd scripts && $(PY) run_tvla.py --npz ../$(TR)/$(SUF)_$(TARGET).npz \
	       --ttd --repeats $(REPEATS) --profile \
	       --plot ../$(OUT)/$(SUF)_$(TARGET) --csv ../$(OUT)/summary.csv

# ---------------------------------------------------------------------
# ADLA. Reuses the TVLA dataset -- no re-simulation. Run `make tvla` (or
# `make null`) first so the .npz exists, then point ADLA at the same file.
# ---------------------------------------------------------------------
adla_null:
	cd scripts && $(PY) run_adla.py --npz ../$(TR)/$(SUF)_null.npz --null \
	       --perm $(PERM)

adla:
	cd scripts && $(PY) run_adla.py --npz ../$(TR)/$(SUF)_$(TARGET).npz \
	       --compare --profile --perm $(PERM) \
	       --plot ../$(OUT)/$(SUF)_$(TARGET) --csv ../$(OUT)/adla_summary.csv

# Full statistical pass on one DUT: capture once, then both tests on it.
both: tvla
	$(MAKE) --no-print-directory adla DUT=$(DUT) TARGET=$(TARGET) \
	        ROWS=$(ROWS) COLS=$(COLS) ACT_MODE=$(ACT_MODE) PERM=$(PERM)

# ---------------------------------------------------------------------
# Second-order TVLA. Also reuses the TVLA dataset. Univariate is the
# default: with a parallel masked datapath both shares land in the same
# time sample, so (P_i - mu_i)^2 is the right transform and no cross-cycle
# product is needed. Use tvla2_biv only for serialised masking or
# shuffling, where the shares genuinely separate in time.
# ---------------------------------------------------------------------
tvla2_selftest:
	cd scripts && $(PY) run_tvla_second_order.py --self-test

tvla2_null:
	cd scripts && $(PY) run_tvla_second_order.py \
	       --npz ../$(TR)/$(SUF)_null.npz --null

# Plot prefix carries a _2nd suffix so the three second-order PNGs sit
# beside the first-order ones instead of overwriting them: the filenames
# themselves (_t / _mean / _ttd) are deliberately identical.
tvla2:
	cd scripts && $(PY) run_tvla_second_order.py \
	       --npz ../$(TR)/$(SUF)_$(TARGET).npz --compare --profile \
	       --ttd --repeats $(REPEATS) \
	       --plot ../$(OUT)/$(SUF)_$(TARGET)_2nd \
	       --csv ../$(OUT)/tvla2_summary.csv

tvla2_biv:
	cd scripts && $(PY) run_tvla_second_order.py \
	       --npz ../$(TR)/$(SUF)_$(TARGET).npz --bivariate \
	       --csv ../$(OUT)/tvla2_summary.csv

# ---------------------------------------------------------------------
# Second-order univariate across every block, reusing the datasets that
# `make all` already captured. No re-simulation, no re-elaboration --
# this only reads traces/*.npz, so it is safe to run repeatedly.
#
# Bivariate is deliberately NOT run here: with an unprotected parallel
# datapath both shares land in the same aggregate P[t], so all the
# structure sits on the diagonal and the pair sweep costs T(T+1)/2 tests
# to rediscover the univariate answer. Run tvla2_biv per-DUT once
# countermeasures are in and the shares separate in time.
# ---------------------------------------------------------------------
tvla2_all:
	@for d in mult mac pe psum outstage requantize maxpool; do \
	  $(MAKE) --no-print-directory tvla2 DUT=$$d TARGET=$(TARGET) \
	          REPEATS=$(REPEATS); \
	done
	$(MAKE) --no-print-directory tvla2 DUT=array ROWS=$(ROWS) COLS=$(COLS) \
	        TARGET=$(TARGET) REPEATS=$(REPEATS)
	@for m in 0 1 2 3; do \
	  $(MAKE) --no-print-directory tvla2 DUT=act ACT_MODE=$$m \
	          TARGET=$(TARGET) REPEATS=$(REPEATS); \
	done

# Capture once, then every statistical test on that one dataset.
allorders: tvla
	$(MAKE) --no-print-directory adla  DUT=$(DUT) TARGET=$(TARGET) \
	        ROWS=$(ROWS) COLS=$(COLS) ACT_MODE=$(ACT_MODE) PERM=$(PERM)
	$(MAKE) --no-print-directory tvla2 DUT=$(DUT) TARGET=$(TARGET) \
	        ROWS=$(ROWS) COLS=$(COLS) ACT_MODE=$(ACT_MODE)

# ---------------------------------------------------------------------
# Array-size ladder. TTD is expected to grow with the PE count because
# algorithmic noise from parallel PEs grows with it. That curve is the
# publishable contribution, so run every rung with the same SEED and the
# same per-group trace count.
# ---------------------------------------------------------------------
sweep:
	@for g in 1 2 4 8; do \
	  $(MAKE) --no-print-directory tvla DUT=array ROWS=$$g COLS=$$g \
	          N=$(N) SEED=$(SEED) TARGET=$(TARGET); \
	done

all:
	@for d in mult mac pe psum outstage requantize maxpool; do \
	  $(MAKE) --no-print-directory null DUT=$$d N=$(N) SEED=$(SEED); \
	  $(MAKE) --no-print-directory tvla DUT=$$d N=$(N) SEED=$(SEED) TARGET=$(TARGET); \
	done
	$(MAKE) --no-print-directory null DUT=array ROWS=$(ROWS) COLS=$(COLS) N=$(N)
	$(MAKE) --no-print-directory tvla DUT=array ROWS=$(ROWS) COLS=$(COLS) N=$(N) TARGET=$(TARGET)
	# Activation unit: run all four modes
	$(MAKE) --no-print-directory act_all N=$(N) SEED=$(SEED)

# ---------------------------------------------------------------------
# Activation unit: all four modes in one shot
# ---------------------------------------------------------------------
act_all:
	@for m in 0 1 2 3; do \
	  $(MAKE) --no-print-directory null DUT=act ACT_MODE=$$m N=$(N) SEED=$(SEED); \
	  $(MAKE) --no-print-directory tvla DUT=act ACT_MODE=$$m N=$(N) SEED=$(SEED); \
	done

clean:
	rm -rf $(BUILD) $(TR) $(OUT)
