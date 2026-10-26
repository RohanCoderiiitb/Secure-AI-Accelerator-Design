#!/usr/bin/env python3
"""Derive a router-compatible copy of the GPDK045 tech LEF.

    make_router_tech_lef.py <gsclib045_tech.lef> <output.lef>

OpenROAD's detailed router (TritonRoute) aborts on VIARULE GENERATE blocks
whose layers are front-end MASTERSLICE / IMPLANT layers (DRT-0129 "Unknown
layer Oxide for viarule M1_DIFF"). gsclib045_tech.lef has six of these:
M1_PO, M1_DIFF, M1_PSUB, M1_PIMP, M1_NIMP, M1_NWELL - contacts from Metal1
down to poly / diffusion / wells, used inside cells, never by signal routing.

It also drops the 16 "MINIMUMCUT 1 WIDTH 0.07 ..." statements. A one-cut
minimum is met by every via by construction, but TritonRoute mis-applies it
to the 70 nm-wide gsclib045 Metal1 pins and then finds no legal access point
on ~1 in 9 cell pins (DRT-0073). The multi-cut rules (MINIMUMCUT 2 / 4) are
kept.

The script copies the tech LEF and drops only the six front-end rules (and
their USEVIARULE references in the VLMDefaultSetup non-default rule) and the
single-cut MINIMUMCUT lines. Every routing layer, metal via, via rule between
metals, site and RC value is kept byte-for-byte. The original PDK file is not
modified.
"""
import re
import sys

FRONT_END_RULES = ["M1_PO", "M1_DIFF", "M1_PSUB", "M1_PIMP", "M1_NIMP", "M1_NWELL"]


def main(src, dst):
    text = open(src).read()
    removed = []
    for rule in FRONT_END_RULES:
        pat = re.compile(rf"^VIARULE {rule} GENERATE\n.*?^END {rule}\n\n?", re.S | re.M)
        text, n = pat.subn("", text)
        if n:
            removed.append(rule)
        text = re.sub(rf"^\s*USEVIARULE {rule} ;\n", "", text, flags=re.M)
    text, n_cut = re.subn(r"^\s*MINIMUMCUT 1 .*;\n", "", text, flags=re.M)
    header = ("# Derived from %s by make_router_tech_lef.py:\n"
              "# removed front-end VIARULEs %s (router cannot load them) and\n"
              "# %d single-cut MINIMUMCUT statements (always met; mis-applied by DRT).\n"
              % (src, " ".join(removed), n_cut))
    open(dst, "w").write(header + text)
    print("removed:", " ".join(removed), "+", n_cut, "MINIMUMCUT 1 lines")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
