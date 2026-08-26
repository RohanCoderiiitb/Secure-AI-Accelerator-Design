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
# ADLA reuses the TVLA dataset:
#   make tvla DUT=pe   then   make adla DUT=pe      (or just: make both DUT=pe)
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

SRC_MULT      := $(RTL)/multiplier.v
SRC_PE        := $(RTL)/multiplier.v $(RTL)/processing_element.v
SRC_ARRAY     := $(RTL)/multiplier.v $(RTL)/processing_element.v $(RTL)/systolic_array.v
SRC_PSUM      := $(RTL)/partial_sum_accumulators.v
SRC_OUT       := $(RTL)/requantization_block.v $(RTL)/activation_unit.v
SRC_REQUANT   := $(RTL)/requantization_block.v
SRC_ACT       := $(RTL)/activation_unit.v
SRC_MAXPOOL   := $(RTL)/maxpool_unit.v

DUT ?= pe

PARAMS  :=
VVP_EXTRA :=

ifeq ($(DUT),mult)
  SRCS := $(SRC_MULT)
  TBF  := $(TB)/tb_tvla_mult.v
endif
ifeq ($(DUT),mac)
  SRCS := $(SRC_PE)
  TBF  := $(TB)/tb_tvla_mac.v
endif
ifeq ($(DUT),pe)
  SRCS := $(SRC_PE)
  TBF  := $(TB)/tb_tvla_pe.v
endif
ifeq ($(DUT),array)
  SRCS   := $(SRC_ARRAY)
  TBF    := $(TB)/tb_tvla_array.v
  PARAMS := -Ptb_tvla_array.ROWS=$(ROWS) -Ptb_tvla_array.COLS=$(COLS)
endif
ifeq ($(DUT),psum)
  SRCS := $(SRC_PSUM)
  TBF  := $(TB)/tb_tvla_psum.v
endif
ifeq ($(DUT),outstage)
  SRCS := $(SRC_OUT)
  TBF  := $(TB)/tb_tvla_output_stage.v
endif
ifeq ($(DUT),requantize)
  SRCS := $(SRC_REQUANT)
  TBF  := $(TB)/tb_tvla_requantize.v
endif
ifeq ($(DUT),act)
  SRCS      := $(SRC_ACT)
  TBF       := $(TB)/tb_tvla_act.v
  VVP_EXTRA := +ACT_MODE=$(ACT_MODE)
endif
ifeq ($(DUT),maxpool)
  SRCS      := $(SRC_MAXPOOL)
  TBF       := $(TB)/tb_tvla_maxpool.v
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

.PHONY: all dirs build null tvla adla adla_null both sweep act_all clean

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
