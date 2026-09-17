#!/usr/bin/env bash
# Full implementation matrix: 3 designs x 2 boards. Edit PARTS for your boards.
# Results land in hardware/vivado/runs/<part>/<top>/ ; then run
#   python parse_reports.py      -> validation/results/vivado.csv
set -euo pipefail
cd "$(dirname "$0")"
PARTS=${PARTS:-"xc7z020clg400-1 xczu7ev-ffvc1156-2-e"}
TOPS=${TOPS:-"heston_aad_z7h heston_aad_z7 heston_aad_zu heston_bump_z7 heston_bump_zu heston_top_level heston_bump_top heston_cos_forward"}
CLK_NS=${CLK_NS:-10.0}
for part in $PARTS; do
  for top in $TOPS; do
    out="runs/$part/$top"
    mkdir -p "$out"
    vivado -mode batch -nojournal -log "$out/vivado.log" \
           -source synth_impl.tcl -tclargs "$top" "$part" "$CLK_NS" "$out"
  done
done
