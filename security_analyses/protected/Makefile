# =====================================================================
# TVLA pipeline for the protected multiplier, PE, and systolic array.
# Run from this directory or use: make -C security_analyses/protected ...
#
# The capture conversion, first-order TVLA, and ADLA stages reuse the
# unprotected scripts. Second-order TVLA uses the protected wrapper, which
# imports the same first-order statistics implementation.
#
# `make all_protected` runs multiplier -> PE -> array. For each DUT it runs:
#   TVLA self-test, fixed-vs-fixed null checks, first-order TVLA,
#   ADLA, second-order TVLA, and a mask-off positive control where supported.
#
# Outputs, including VCD/NPZ captures, are stored in tvla_outputs/<DUT>_<TARGET>/.
# Knobs: N (traces, default 2000), SEED, TARGET (default wt),
#        REPEATS (default 20), PERM (default 500), TTD (default 1).
# Valid TARGET values: multiplier=act|wt|both, PE=act|wt,
#                      array=act|wt|row0. For all_protected use act or wt;
#                      TARGET=both is only valid for the multiplier alone.
# =====================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PY       ?= python3

ROOT     := ../..
RTL_P    := $(ROOT)/protected_designs/source
UNP      := ../unprotected
USCRIPTS := $(UNP)/scripts
SCRIPTS  := scripts
TB       := tb
BUILD    := build
OUT      := tvla_outputs

IVFLAGS  ?= -g2012 -I $(UNP) -I $(TB)

N       ?= 2000
SEED    ?= 1
TARGET  ?= wt
REPEATS ?= 20
PERM    ?= 500
TTD     ?= 1
FIXED_W ?= -77
FIXED_A ?= 93
PSUM_RANDOM ?= 0

DUT ?= multiplier

ifeq ($(DUT),multiplier)
  SUF  := multiplier_masked
  SRCS := $(RTL_P)/multiplier_wt_masked.sv
  TBF  := $(TB)/tb_tvla_multiplier_masked.sv
  MASKOFF_SUPPORTED := 0
else ifeq ($(DUT),pe)
  SUF  := pe_masked
  SRCS := $(RTL_P)/multiplier_wt_masked.sv \
          $(RTL_P)/mask_rng.sv \
          $(RTL_P)/weight_splitter.sv \
          $(RTL_P)/processing_element_masked.sv
  TBF  := $(TB)/tb_tvla_pe_masked.sv
  MASKOFF_SUPPORTED := 1
else ifeq ($(DUT),array)
  SUF  := array_masked
  SRCS := $(RTL_P)/multiplier_wt_masked.sv \
          $(RTL_P)/mask_rng.sv \
          $(RTL_P)/weight_splitter.sv \
          $(RTL_P)/weight_masker.sv \
          $(RTL_P)/processing_element_masked.sv \
          $(RTL_P)/systolic_array_masked.sv
  TBF  := $(TB)/tb_tvla_array_masked.sv
  MASKOFF_SUPPORTED := 1
else
  $(error unknown DUT=$(DUT); choose multiplier, pe, or array)
endif

RUN_DIR := $(OUT)/$(DUT)_$(TARGET)
TR      := $(RUN_DIR)/traces
OUT_T1  := $(RUN_DIR)/first_order
OUT_AD  := $(RUN_DIR)/adla
OUT_T2  := $(RUN_DIR)/second_order
VVPF    := $(BUILD)/tb_$(SUF).vvp
FIXARGS := +FIXED_W=$(FIXED_W) +FIXED_A=$(FIXED_A)
TTDF    := $(if $(filter 1,$(TTD)),--ttd --repeats $(REPEATS),)
PLOT    := $(abspath $(RUN_DIR))/$(SUF)_$(TARGET)
NPZ_TVLA := $(TR)/$(SUF)_$(TARGET).npz
NPZ_NULL := $(TR)/$(SUF)_$(TARGET)_null.npz
NPZ_OFF  := $(TR)/$(SUF)_$(TARGET)_maskoff.npz

.PHONY: dirs check build tvla2_selftest null tvla adla_null adla \
        tvla2_null tvla maskoff all all_protected clean

dirs:
	mkdir -p $(BUILD) $(TR) $(OUT_T1) $(OUT_AD) $(OUT_T2)

check:
	@for f in $(SRCS) $(TBF) $(UNP)/sca_capture.vh \
	          $(USCRIPTS)/vcd_power.py $(USCRIPTS)/run_tvla.py \
	          $(USCRIPTS)/tvla.py $(USCRIPTS)/run_adla.py \
	          $(USCRIPTS)/adla.py $(SCRIPTS)/run_tvla_second_order.py; do \
	  test -f $$f && echo "  [ok] $$f" || { echo "  [FAIL] $$f missing"; exit 1; }; \
	done
	@$(PY) -c "import numpy, scipy" || { echo "[FAIL] numpy and scipy are required"; exit 1; }
	@$(PY) -c "import matplotlib" || echo "[WARN] matplotlib missing; plots will be skipped"

build: dirs
	$(IVERILOG) $(IVFLAGS) -o $(VVPF) $(SRCS) $(TBF)

tvla2_selftest:
	$(PY) $(SCRIPTS)/run_tvla_second_order.py --self-test

# Each analysis consumes the captures produced below. The fixed-vs-fixed
# null datasets are analysed by all three statistics before fixed-vs-random.
null: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=null \
	       +TVLA_TARGET=$(TARGET) $(FIXARGS) +TAG=$(SUF)_$(TARGET)_null \
	       +OUTDIR=$(TR) +MASK_EN=1 +PSUM_RANDOM=$(PSUM_RANDOM)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET)_null.vcd \
	       --meta $(TR)/$(SUF)_$(TARGET)_null.meta.csv --out $(NPZ_NULL)
	$(PY) $(USCRIPTS)/run_tvla.py --npz $(NPZ_NULL) --null \
	       --csv $(OUT_T1)/summary.csv
	$(PY) $(USCRIPTS)/run_adla.py --npz $(NPZ_NULL) --null --perm $(PERM) \
	       --csv $(OUT_AD)/summary.csv
	$(PY) $(SCRIPTS)/run_tvla_second_order.py --npz $(NPZ_NULL) --null \
	       --csv $(OUT_T2)/summary.csv

tvla: build
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=$(TARGET) $(FIXARGS) +TAG=$(SUF)_$(TARGET) \
	       +OUTDIR=$(TR) +MASK_EN=1 +PSUM_RANDOM=$(PSUM_RANDOM)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET).vcd \
	       --meta $(TR)/$(SUF)_$(TARGET).meta.csv --out $(NPZ_TVLA)
	$(PY) $(USCRIPTS)/run_tvla.py --npz $(NPZ_TVLA) $(TTDF) --profile \
	       --plot "$(PLOT)_first_order" --csv $(OUT_T1)/summary.csv
	$(PY) $(USCRIPTS)/run_adla.py --npz $(NPZ_TVLA) --compare --profile \
	       --perm $(PERM) $(TTDF) \
	       --plot "$(PLOT)_adla" --csv $(OUT_AD)/summary.csv
	$(PY) $(SCRIPTS)/run_tvla_second_order.py --npz $(NPZ_TVLA) \
	       --compare --profile $(TTDF) \
	       --plot "$(PLOT)_second_order" --csv $(OUT_T2)/summary.csv

adla_null:
	$(PY) $(USCRIPTS)/run_adla.py --npz $(NPZ_NULL) --null --perm $(PERM) \
	       --csv $(OUT_AD)/summary.csv

tvla2_null:
	$(PY) $(SCRIPTS)/run_tvla_second_order.py --npz $(NPZ_NULL) --null \
	       --csv $(OUT_T2)/summary.csv

maskoff: build
ifeq ($(MASKOFF_SUPPORTED),1)
	$(VVP) $(VVPF) +NTRACES=$(N) +SEED=$(SEED) +MODE=tvla \
	       +TVLA_TARGET=$(TARGET) $(FIXARGS) +TAG=$(SUF)_$(TARGET)_maskoff \
	       +OUTDIR=$(TR) +MASK_EN=0 +PSUM_RANDOM=$(PSUM_RANDOM)
	$(PY) $(USCRIPTS)/vcd_power.py --vcd $(TR)/$(SUF)_$(TARGET)_maskoff.vcd \
	       --meta $(TR)/$(SUF)_$(TARGET)_maskoff.meta.csv --out $(NPZ_OFF)
	$(PY) $(USCRIPTS)/run_tvla.py --npz $(NPZ_OFF) --profile \
	       --plot "$(PLOT)_maskoff" --csv $(OUT_T1)/summary.csv
else
	@echo "[skip] The isolated multiplier bench has no mask-enable control."
endif

all: check tvla2_selftest null tvla maskoff

all_protected:
	$(MAKE) --no-print-directory all DUT=multiplier TARGET=$(TARGET) N=$(N) SEED=$(SEED) REPEATS=$(REPEATS) PERM=$(PERM) TTD=$(TTD)
	$(MAKE) --no-print-directory all DUT=pe TARGET=$(TARGET) N=$(N) SEED=$(SEED) REPEATS=$(REPEATS) PERM=$(PERM) TTD=$(TTD) PSUM_RANDOM=$(PSUM_RANDOM)
	$(MAKE) --no-print-directory all DUT=array TARGET=$(TARGET) N=$(N) SEED=$(SEED) REPEATS=$(REPEATS) PERM=$(PERM) TTD=$(TTD)

clean:
	rm -rf $(BUILD) $(OUT)
