# PDK configuration: Cadence GPDK045 / gsclib045 standard-cell library,
# from 45_nm_PDK/cadence/cadence_45nm in this repository.
# Sourced by run_design.sh; every tool script reads these variables.
#
#   lib/fast_vdd1v0_basicCells.lib  (1.1 V,   0 C) : synthesis, P&R, STA - the
#                                                     corner the lab Genus/Innovus
#                                                     flow (mmmc.tcl) uses
#   lib/slow_vdd1v0_basicCells.lib  (0.9 V, 125 C) : second, worst-case STA only
#   lef/gsclib045_tech.lef, lef/gsclib045_macro.lef : technology + cell abstracts
#
# Cell areas are identical in both corners, so the corner choice does not
# change the area of a given netlist. Implementing in the slow corner would
# make timing repair upsize/buffer the designs to hit 100 MHz at 0.9 V/125 C,
# mixing worst-case timing closure into the area comparison, so the fast
# corner (as in the lab flow) drives implementation.
# qrc/gpdk045.tch is a Cadence QRC tech file, which OpenROAD cannot read, and
# no OpenRCX rules exist for this PDK; wire RC comes from the per-layer
# RPERSQ / CPERSQDIST values in the tech LEF instead (set_wire_rc +
# estimate_parasitics -global_routing on the routed design).

PDK_DIR=${PDK_DIR:-$REPO/45_nm_PDK/cadence/cadence_45nm}
export PDK_NAME="Cadence GPDK045 (gsclib045)"
export TECH_LEF=$PDK_DIR/lef/gsclib045_tech.lef
export CELL_LEF=$PDK_DIR/lef/gsclib045_macro.lef
export LIB_FAST=$PDK_DIR/lib/fast_vdd1v0_basicCells.lib
export LIB_SLOW=$PDK_DIR/lib/slow_vdd1v0_basicCells.lib
export LIB=$LIB_FAST        # synthesis + place & route

export SITE=CoreSite
# Scan / enable-scan flops, delay cells, tri-states, latches and special
# cells: not wanted in a plain synthesised datapath.
# BUFX2: its LEF entry declares SITE CoreSiteDouble although the cell is
# single-height (1.71 um); OpenROAD then builds overlapping double-height
# rows and legalisation fails. BUFX3 is used as the default buffer instead,
# so the PDK files are used unmodified.
export DONT_USE="BUFX2 SDFF* SEDFF* SMDFF* MDFF* DLY* TBUF* TLAT* ANTENNA* HOLD* ACHCON* BMXI*"
export FILLERS="FILL64 FILL32 FILL16 FILL8 FILL4 FILL2 FILL1"
export TIEHI_CELL="TIEHI Y"
export TIELO_CELL="TIELO Y"
export BUF_CELL="BUFX3 A Y"
export DRIVE_CELL=BUFX3
export DRIVE_PIN=Y
export CTS_ROOT_BUF=CLKBUFX4
export CTS_BUFS="CLKBUFX2 CLKBUFX4 CLKBUFX8"

# Routing: odd metals horizontal, even metals vertical (tech LEF).
export PIN_HOR_LAYER=Metal3
export PIN_VER_LAYER=Metal4
export SIGNAL_LAYERS=Metal2-Metal10
export CLOCK_LAYERS=Metal4-Metal10
export RAIL_LAYER=Metal1
export RAIL_WIDTH=0.12          # VDD/VSS follow-pin rail width in the cell LEF
export STRAP_LAYER=Metal4
export STRAP_WIDTH=0.4
