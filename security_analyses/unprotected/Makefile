# =====================================================================
# Side-channel leakage assessment -- unprotected baseline
# =====================================================================
# Run every target from this directory (security_analyses/unprotected).
#
# Layout this Makefile expects:
#   ../../source/*.sv        RTL
#   ./sca_capture.vh         shared capture header (this directory)
#   ./qif_schedule.vh        QIF enumeration header (this directory)
#   ./tb/*.sv                testbenches
#   ./scripts/*.py           analysis
#   ./build ./traces ./out   generated
#
# ---------------------------------------------------------------------
# FIRST ORDER TVLA          make null DUT=pe   then   make tvla DUT=pe
# ADLA                      make adla DUT=pe          (reuses the dataset)
# SECOND ORDER TVLA         make tvla2 DUT=pe         (reuses the dataset)
# QIF                       make qif QDUT=pe          (needs its own capture)
#
# Everything at once, one DUT:   make allorders DUT=pe
# Everything, every DUT:         make all
# ---------------------------------------------------------------------
#
# Knobs
#   N=2000        traces (split 50/50)
#   SEED=1
#   TARGET=act    act | wt | both | row0  -- which operand carries the contrast
#   ROWS= COLS=   systolic array geometry (DUT=array)
#   ACT_MODE=1    0=PASS 1=RELU 2=RELU_CLIP 3=LEAKY_RELU (DUT=act)
#   WIN_LEN=8     pooling window (DUT=maxpool)
#   PERM=500      label permutations for the ADLA threshold
#   REPEATS=20    subsets per point in a TTD sweep
#
# QIF knobs
#   SECRET=wt     wt | act | mode | m0 | len   -- which secret category
#   QIF_CTX=256   enumerated contexts (array, mac ACC_STEPS=2)
#   ACC_STEPS=1   MAC: 1 = exhaustive single step, 2 = accumulate on context
#   ACC_STEP=1    requantize/psum sweep stride; 1 = true exhaustive
#   RESUME= QLIMIT=   checkpoint a long enumeration into chunks
# =====================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PY       ?= python3
RTL      := ../../source
RTL_EXT  := sv
TB       := tb
TB_EXT   := sv
BUILD    := build
TR       := traces
OUT      := out
SCRIPTS  := scripts

# Headers live in THIS directory, not in tb/, so '.' must be on the
# include path as well.
IVFLAGS  ?= -g2012 -I . -I $(TB)

# Per-test output folders, matching the existing out/ layout.
OUT_T1   := $(OUT)/tvla_first_order_outputs
OUT_T2   := $(OUT)/tvla_second_order_outputs
OUT_AD   := $(OUT)/adla_outputs
OUT_QIF  := $(OUT)/qif_outputs

# --- knobs -----------------------------------------------------------
N        ?= 2000
SEED     ?= 1
TARGET   ?= act
ROWS     ?= 5
COLS     ?= 5
REPEATS  ?= 20
PERM     ?= 500
ACT_MODE ?= 1
WIN_LEN  ?= 8

SECRET    ?= wt
QIF_CTX   ?= 256
ACC_STEPS ?= 1
ACC_STEP  ?= 1
ACC_LO    ?= -131072
ACC_HI    ?= 131071
QWIN      ?= 2
EXH       ?= 1
#   1 ->    256 contexts ->     65,536 traces, ~5 min,   1.4 GB
#   2 -> 65,536 contexts -> 16,777,216 traces, ~23 hr, 354 GB (use FST)
CTX_BYTES ?= 1
N_M0      ?= 1
M0_CTX    ?= 256
RESUME    ?= 0
QLIMIT    ?= 0
SRC_MULT    := $(RTL)/multiplier.$(RTL_EXT)
SRC_PE      := $(SRC_MULT) $(RTL)/processing_element.$(RTL_EXT)
SRC_ARRAY   := $(SRC_PE) $(RTL)/systolic_array.$(RTL_EXT)
SRC_PSUM    := $(RTL)/partial_sum_accumulators.$(RTL_EXT)
SRC_REQUANT := $(RTL)/requantization_block.$(RTL_EXT)
SRC_ACT     := $(RTL)/activation_unit.$(RTL_EXT)
SRC_MAXPOOL := $(RTL)/maxpool_unit.$(RTL_EXT)
SRC_OUT     := $(SRC_REQUANT) $(SRC_ACT)
SRC_GBUF    := $(RTL)/sram_2p.$(RTL_EXT) $(RTL)/global_buffer.$(RTL_EXT)
SRC_SPAD    := $(RTL)/sram_2p.$(RTL_EXT) $(RTL)/scratchpad.$(RTL_EXT)
SRC_ADDRGEN := $(SRC_SPAD) $(RTL)/address_generator.$(RTL_EXT)
SRC_LOADCTRL:= $(RTL)/sram_2p.$(RTL_EXT) $(RTL)/global_buffer.$(RTL_EXT) \
			   $(RTL)/scratchpad.$(RTL_EXT) $(RTL)/address_generator.$(RTL_EXT) \
               $(RTL)/load_controller.$(RTL_EXT)

# =====================================================================
# TVLA / ADLA / second-order DUT selection
# =====================================================================
DUT    ?= pe
PARAMS :=
VVP_EXTRA :=

ifeq ($(DUT),mult)
  SRCS := $(SRC_MULT)
  TBF  := $(TB)/tb_tvla_mult.$(TB_EXT)
endif
ifeq ($(DUT),mac)
  SRCS := $(SRC_PE)
  TBF  := $(TB)/tb_tvla_mac.$(TB_EXT)
endif
ifeq ($(DUT),pe)
  SRCS := $(SRC_PE)
  TBF  := $(TB)/tb_tvla_pe.$(TB_EXT)
endif
ifeq ($(DUT),array)
  SRCS   := $(SRC_ARRAY)
  TBF    := $(TB)/tb_tvla_array.$(TB_EXT)
  PARAMS := -Ptb_tvla_array.ROWS=$(ROWS) -Ptb_tvla_array.COLS=$(COLS)
endif
ifeq ($(DUT),psum)
  SRCS := $(SRC_PSUM)
  TBF  := $(TB)/tb_tvla_psum.$(TB_EXT)
endif
ifeq ($(DUT),outstage)
  SRCS := $(SRC_OUT)
  TBF  := $(TB)/tb_tvla_outstage.$(TB_EXT)
endif
ifeq ($(DUT),requantize)
  SRCS := $(SRC_REQUANT)
  TBF  := $(TB)/tb_tvla_requantize.$(TB_EXT)
endif
ifeq ($(DUT),act)
  SRCS      := $(SRC_ACT)
  TBF       := $(TB)/tb_tvla_act.$(TB_EXT)
  VVP_EXTRA := +ACT_MODE=$(ACT_MODE)
endif
ifeq ($(DUT),maxpool)
  SRCS      := $(SRC_MAXPOOL)
  TBF       := $(TB)/tb_tvla_maxpool.$(TB_EXT)
  VVP_EXTRA := +WIN_LEN=$(WIN_LEN)
endif
ifeq ($(DUT),gbuf)
  SRCS := $(SRC_GBUF)
  TBF  := $(TB)/tb_tvla_gbuf.$(TB_EXT)
endif
ifeq ($(DUT),spad)
  SRCS := $(SRC_SPAD)
  TBF  := $(TB)/tb_tvla_spad.$(TB_EXT)
endif
ifeq ($(DUT),addrgen)
  SRCS := $(SRC_ADDRGEN)
  TBF  := $(TB)/tb_tvla_addrgen.$(TB_EXT)
endif
ifeq ($(DUT),loadctrl)
  SRCS := $(SRC_LOADCTRL)
  TBF  := $(TB)/tb_tvla_loadctrl.$(TB_EXT)
endif

ifeq ($(DUT),array)
  SUF := $(DUT)$(ROWS)x$(COLS)
else ifeq ($(DUT),act)
  ACT_NAMES := pass relu relu_clip leaky
  SUF := $(DUT)_$(word $(shell echo $$(($(ACT_MODE)+1))),$(ACT_NAMES))
else
  SUF := $(DUT)
endif

VVPF := $(BUILD)/tb_$(SUF).vvp

.PHONY: dirs build null tvla adla adla_null tvla2 tvla2_null tvla2_biv \
        tvla2_selftest tvla2_all both allorders sweep act_all \
        qif qif_selftest qif_build qif_run qif_analyse qif_all \
        all clean check

dirs:
	@mkdir -p $(BUILD) $(TR) $(OUT_T1) $(OUT_T2) $(OUT_AD) $(OUT_QIF)

# Verify the layout before a long run, so a typo fails in a second
# rather than after an hour of simulation.
check:
	@echo "RTL      : $(RTL)"
	@test -f $(RTL)/multiplier.$(RTL_EXT) \
	  && echo "  [ok] RTL found" \
	  || { echo "  [FAIL] no $(RTL)/multiplier.$(RTL_EXT)"; exit 1; }
	@test -f sca_capture.vh \
	  && echo "  [ok] sca_capture.vh in $(CURDIR)" \
	  || { echo "  [FAIL] sca_capture.vh missing"; exit 1; }
	@test -f qif_schedule.vh \
	  && echo "  [ok] qif_schedule.vh in $(CURDIR)" \
	  || { echo "  [FAIL] qif_schedule.vh missing"; exit 1; }
	@test -f $(SCRIPTS)/vcd_power.py \
	  && echo "  [ok] scripts/ found" \
	  || { echo "  [FAIL] scripts/vcd_power.py missing"; exit 1; }
	@$(PY) -c "import numpy" 2>/dev/null \
	  && echo "  [ok] numpy" || echo "  [WARN] numpy missing"
	@$(PY) -c "import matplotlib" 2>/dev/null \
	  && echo "  [ok] matplotlib" \
	  || echo "  [WARN] matplotlib missing -- plots will be skipped"
	@$(PY) -c "import scipy" 2>/dev/null \
	  && echo "  [ok] scipy" || echo "  [WARN] scipy missing"

build: dirs
	$(IVERILOG) $(IVFLAGS) $(PARAMS) -o $(VVPF) $(SRCS) $(TBF)

# ---------------------------------------------------------------------
# First-order TVLA. Null test first, always.
# ---------------------------------------------------------------------
null: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=null \
	       +TVLA_TARGET=$(TARGET) $(VVP_EXTRA) +TAG=$(SUF)_null
	$(PY) $(SCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_null.vcd \
	       --meta $(TR)/$(SUF)_null.meta.csv --out $(TR)/$(SUF)_null.npz
	cd $(SCRIPTS) && $(PY) run_tvla.py --npz ../$(TR)/$(SUF)_null.npz --null

tvla: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=$(TARGET) $(VVP_EXTRA) +TAG=$(SUF)_$(TARGET)
	$(PY) $(SCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET).vcd \
	       --meta $(TR)/$(SUF)_$(TARGET).meta.csv \
	       --out $(TR)/$(SUF)_$(TARGET).npz
	cd $(SCRIPTS) && $(PY) run_tvla.py --npz ../$(TR)/$(SUF)_$(TARGET).npz \
	       --ttd --repeats $(REPEATS) --profile \
	       --plot ../$(OUT_T1)/$(SUF)_$(TARGET) \
	       --csv ../$(OUT_T1)/summary.csv

# ---------------------------------------------------------------------
# ADLA. Reuses the TVLA dataset -- no re-simulation.
# ---------------------------------------------------------------------
adla_null:
	cd $(SCRIPTS) && $(PY) run_adla.py --npz ../$(TR)/$(SUF)_null.npz \
	       --null --perm $(PERM)

adla:
	cd $(SCRIPTS) && $(PY) run_adla.py --npz ../$(TR)/$(SUF)_$(TARGET).npz \
	       --compare --profile --perm $(PERM) \
	       --plot ../$(OUT_AD)/$(SUF)_$(TARGET) \
	       --csv ../$(OUT_AD)/adla_summary.csv

# ---------------------------------------------------------------------
# Second-order TVLA. Also reuses the TVLA dataset. Univariate by default:
# with a parallel masked datapath both shares land in the same time
# sample, so (P_i - mu_i)^2 is the right transform. tvla2_biv is for
# serialised masking or shuffling, where the shares separate in time.
# ---------------------------------------------------------------------
tvla2_selftest:
	cd $(SCRIPTS) && $(PY) run_tvla_second_order.py --self-test

tvla2_null:
	cd $(SCRIPTS) && $(PY) run_tvla_second_order.py \
	       --npz ../$(TR)/$(SUF)_null.npz --null

tvla2:
	cd $(SCRIPTS) && $(PY) run_tvla_second_order.py \
	       --npz ../$(TR)/$(SUF)_$(TARGET).npz --compare --profile \
	       --ttd --repeats $(REPEATS) \
	       --plot ../$(OUT_T2)/$(SUF)_$(TARGET)_2nd \
	       --csv ../$(OUT_T2)/tvla2_summary.csv

tvla2_biv:
	cd $(SCRIPTS) && $(PY) run_tvla_second_order.py \
	       --npz ../$(TR)/$(SUF)_$(TARGET).npz --bivariate \
	       --csv ../$(OUT_T2)/tvla2_summary.csv

tvla2_all:
	@for d in mult mac pe psum outstage requantize maxpool gbuf spad addrgen loadctrl; do \
	  $(MAKE) --no-print-directory tvla2 DUT=$$d TARGET=$(TARGET) \
	          REPEATS=$(REPEATS); \
	done
	$(MAKE) --no-print-directory tvla2 DUT=array ROWS=$(ROWS) COLS=$(COLS) \
	        TARGET=$(TARGET) REPEATS=$(REPEATS)
	@for m in 0 1 2 3; do \
	  $(MAKE) --no-print-directory tvla2 DUT=act ACT_MODE=$$m \
	          TARGET=$(TARGET) REPEATS=$(REPEATS); \
	done

both: tvla
	$(MAKE) --no-print-directory adla DUT=$(DUT) TARGET=$(TARGET) \
	        ROWS=$(ROWS) COLS=$(COLS) ACT_MODE=$(ACT_MODE) PERM=$(PERM)

allorders: tvla
	$(MAKE) --no-print-directory adla  DUT=$(DUT) TARGET=$(TARGET) \
	        ROWS=$(ROWS) COLS=$(COLS) ACT_MODE=$(ACT_MODE) PERM=$(PERM)
	$(MAKE) --no-print-directory tvla2 DUT=$(DUT) TARGET=$(TARGET) \
	        ROWS=$(ROWS) COLS=$(COLS) ACT_MODE=$(ACT_MODE)

# ---------------------------------------------------------------------
# Array-size ladder. TARGET=row0 is the correct stimulus: randomising the
# whole tile makes signal scale with the array as fast as the noise, so
# TTD stays flat instead of showing the algorithmic-noise effect.
# ---------------------------------------------------------------------
sweep:
	@for g in 1 2 4 8; do \
	  $(MAKE) --no-print-directory tvla DUT=array ROWS=$$g COLS=$$g \
	          N=$(N) SEED=$(SEED) TARGET=$(TARGET); \
	done

act_all:
	@for m in 0 1 2 3; do \
	  $(MAKE) --no-print-directory null DUT=act ACT_MODE=$$m N=$(N) SEED=$(SEED); \
	  $(MAKE) --no-print-directory tvla DUT=act ACT_MODE=$$m N=$(N) SEED=$(SEED); \
	done

# =====================================================================
# QIF. Needs its OWN capture: the stimulus is an exhaustive enumeration,
# not a fixed/random split, so unlike ADLA and second-order TVLA it
# cannot reuse the TVLA datasets.
# =====================================================================
QSRC_mult     := $(SRC_MULT)
QSRC_mac      := $(SRC_PE)
QSRC_pe       := $(SRC_PE)
QSRC_array    := $(SRC_ARRAY)
QSRC_act      := $(SRC_ACT)
QSRC_requant  := $(SRC_REQUANT)
QSRC_psum     := $(SRC_PSUM)
QSRC_maxpool  := $(SRC_MAXPOOL)
QSRC_gbuf     := $(SRC_GBUF)
QSRC_spad     := $(SRC_SPAD)
QSRC_addrgen  := $(SRC_ADDRGEN)
QSRC_loadctrl := $(SRC_LOADCTRL)

QDUT ?= $(DUT)
# otherwise a second run with a different secret definition silently
# overwrites the first and the plots look like they never regenerated.
QVAR :=
ifeq ($(QDUT),maxpool)
  QVAR := _w$(QWIN)
endif
ifeq ($(QDUT),mac)
  QVAR := _s$(ACC_STEPS)
endif
ifeq ($(QDUT),array)
  QVAR := _e$(EXH)b$(CTX_BYTES)
endif
ifeq ($(QDUT),requant)
  QVAR := _c$(M0_CTX)
endif
QTAG := qif_$(QDUT)_$(SECRET)$(QVAR)

# Human-readable secret names for QIF plot titles.
ifeq ($(SECRET),wt)
  QSECRET_NAME := Weight
else ifeq ($(SECRET),act)
  QSECRET_NAME := Activation
else ifeq ($(SECRET),mode)
  QSECRET_NAME := Activation Mode
else ifeq ($(SECRET),acc)
  QSECRET_NAME := Accumulator
else ifeq ($(SECRET),m0)
  QSECRET_NAME := M0
else ifeq ($(SECRET),psum)
  QSECRET_NAME := Partial Sum
else ifeq ($(SECRET),win)
  QSECRET_NAME := Window
else ifeq ($(SECRET),len)
  QSECRET_NAME := Window Length
else
  QSECRET_NAME := $(SECRET)
endif

qif_selftest:
	cd $(SCRIPTS) && $(PY) qif_validate.py

qif_build: dirs
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/tb_qif_$(QDUT).vvp \
	    $(QSRC_$(QDUT)) $(TB)/tb_qif_$(QDUT).$(TB_EXT)

qif_run: qif_build
	$(VVP) $(BUILD)/tb_qif_$(QDUT).vvp +TAG=$(QTAG) +SECRET=$(SECRET) \
	    +QIF_CTX=$(QIF_CTX) +ACC_LO=$(ACC_LO) +ACC_HI=$(ACC_HI) \
	    +ACC_STEP=$(ACC_STEP) +ACC_STEPS=$(ACC_STEPS) +WIN_LEN=$(QWIN) \
	    +N_M0=$(N_M0) +M0_CTX=$(M0_CTX) +EXH=$(EXH) \
	    +CTX_BYTES=$(CTX_BYTES) \
	    +RESUME=$(RESUME) +LIMIT=$(QLIMIT)
	$(PY) $(SCRIPTS)/vcd_power.py --vcd $(TR)/$(QTAG).vcd \
	    --meta $(TR)/$(QTAG).meta.csv --out $(TR)/$(QTAG).npz

qif_analyse:
	cd $(SCRIPTS) && $(PY) run_qif.py --npz ../$(TR)/$(QTAG).npz \
	    --secret-name "$(QSECRET_NAME)" \
	    --plot ../$(OUT_QIF)/$(QTAG) --csv ../$(OUT_QIF)/qif_summary.csv

qif: qif_selftest qif_run qif_analyse

# Every block, every valid secret definition, all exhaustive.
#
# The old version passed SECRET=$(SECRET) to every DUT, which mislabelled
# runs on blocks that ignore it (psum) or use different names (act,
# requant, maxpool), and included SECRET=len on maxpool -- degenerate,
# because win_len is constant within a run so the channel gets a single
# secret value and the analysis has nothing to measure.
qif_all:
	$(MAKE) --no-print-directory qif_selftest
	$(MAKE) --no-print-directory qif QDUT=mult    SECRET=wt
	$(MAKE) --no-print-directory qif QDUT=mult    SECRET=act
	$(MAKE) --no-print-directory qif QDUT=mac     SECRET=wt  ACC_STEPS=1
	$(MAKE) --no-print-directory qif QDUT=mac     SECRET=act ACC_STEPS=1
	$(MAKE) --no-print-directory qif QDUT=pe      SECRET=wt
	$(MAKE) --no-print-directory qif QDUT=pe      SECRET=act
	$(MAKE) --no-print-directory qif QDUT=act     SECRET=act
	$(MAKE) --no-print-directory qif QDUT=act     SECRET=mode
	$(MAKE) --no-print-directory qif QDUT=requant SECRET=acc ACC_STEP=1
	$(MAKE) --no-print-directory qif QDUT=requant SECRET=m0  M0_CTX=256
	$(MAKE) --no-print-directory qif QDUT=psum    SECRET=psum ACC_STEP=1
	$(MAKE) --no-print-directory qif QDUT=maxpool SECRET=win QWIN=2
	$(MAKE) --no-print-directory qif QDUT=array   SECRET=wt  EXH=1
	$(MAKE) --no-print-directory qif QDUT=gbuf    SECRET=data
	$(MAKE) --no-print-directory qif QDUT=spad    SECRET=data
	$(MAKE) --no-print-directory qif QDUT=addrgen SECRET=act
	$(MAKE) --no-print-directory qif QDUT=loadctrl SECRET=act
	$(MAKE) --no-print-directory qif QDUT=loadctrl SECRET=wt

# =====================================================================
all:
	@for d in mult mac pe psum outstage requantize maxpool gbuf spad addrgen loadctrl; do \
	  $(MAKE) --no-print-directory null DUT=$$d N=$(N) SEED=$(SEED); \
	  $(MAKE) --no-print-directory tvla DUT=$$d N=$(N) SEED=$(SEED) TARGET=$(TARGET); \
	done
	$(MAKE) --no-print-directory null DUT=array ROWS=$(ROWS) COLS=$(COLS) N=$(N)
	$(MAKE) --no-print-directory tvla DUT=array ROWS=$(ROWS) COLS=$(COLS) N=$(N) TARGET=$(TARGET)
	$(MAKE) --no-print-directory act_all N=$(N) SEED=$(SEED)

clean:
	rm -rf $(BUILD) $(TR) $(OUT_T1) $(OUT_T2) $(OUT_AD) $(OUT_QIF)