#!/usr/bin/env bash
# Full implementation matrix: designs x boards. Edit PARTS/TOPS for your boards.
# Results land in hardware/vivado/runs/<part>/<top>/ ; then run
#   python parse_reports.py      -> validation/results/vivado.csv
# A failed run (e.g. heston_aad_zu needs more DSPs than a Zynq-7020 has) is
# reported and the matrix continues; the exit status is nonzero if any failed.
set -uo pipefail
cd "$(dirname "$0")"
PARTS=${PARTS:-"xc7z020clg400-1 xczu7ev-ffvc1156-2-e"}
TOPS=${TOPS:-"heston_aad_z7h heston_aad_z7 heston_aad_zu heston_bump_z7 heston_bump_zu heston_top_level heston_bump_top heston_cos_forward"}
CLK_NS=${CLK_NS:-10.0}
failed=()
for part in $PARTS; do
  for top in $TOPS; do
    out="runs/$part/$top"
    mkdir -p "$out"
    if ! vivado -mode batch -nojournal -log "$out/vivado.log" \
                -source synth_impl.tcl -tclargs "$top" "$part" "$CLK_NS" "$out"; then
      echo "FAILED: $top on $part (see $out/vivado.log)"
      failed+=("$part/$top")
    fi
  done
done
if [ ${#failed[@]} -gt 0 ]; then
  echo "${#failed[@]} run(s) failed: ${failed[*]}"
  exit 1
fi
