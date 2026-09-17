#!/usr/bin/env bash
# Re-run every verification in the repository and print a PASS/FAIL summary.
#
#   ./verify_all.sh            (~3 minutes on 8 cores; needs iverilog + .venv)
#
# 1. arithmetic-library unit tests (fp_exp/log/div, CORDIC, complex ops) vs double
# 2. FSM engine: Heston AAD, price-only, AXI testbenches; Black-Scholes testbench
# 3. generated datapaths: AAD + price-only for both configs (every setup/finish
#    register and terms 0-2 bit-exact vs the emulator, all outputs, out-of-domain
#    range_err), AXI and bump-and-reprice wrappers
# 4. committed hardware/verilog/gen/*.v identical to fresh generator output
# 5. emulator accuracy + error bound on the reference case
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
PY="$ROOT/.venv/bin/python"
V="$ROOT/hardware/verilog"
LOG="$ROOT/hardware/gen/build/verify_logs"
mkdir -p "$LOG"
declare -a NAMES RESULTS

record() {  # name, logfile, pass-pattern
  if grep -q "$3" "$2" && ! grep -q "FAIL" "$2"; then r=PASS; else r=FAIL; fi
  NAMES+=("$1"); RESULTS+=("$r")
  printf '%-58s %s\n' "$1" "$r"
}

echo "== 1. arithmetic library unit tests"
(cd "$ROOT/hardware/sim/unit" && python3 check_real_primitives.py > "$LOG/unit_real.log" 2>&1)
"$PY" - "$LOG/unit_real.log" <<'EOF' > "$LOG/unit_real.chk"
import re, sys
vals = []
for line in open(sys.argv[1]):
    m = re.search(r"\{([^}]*)\}", line)          # first dict: worst errors (second: sample counts)
    if m:
        vals += [float(x) for x in re.findall(r": ([\d.]+)", m.group(1))]
ok = bool(vals) and all(v <= 2.5 for v in vals)
print("PASS" if ok else "FAIL")
EOF
record "fp_exp/fp_log/CORDIC/fp_div within 2.5 ULP" "$LOG/unit_real.chk" PASS
(cd "$ROOT/hardware/sim/unit" && python3 check_complex_primitives.py > "$LOG/unit_cplx.log" 2>&1)
"$PY" - "$LOG/unit_cplx.log" <<'EOF' > "$LOG/unit_cplx.chk"
import re, sys
ok = all(float(x) <= 4.0 for x in re.findall(r"worst err ([\d.]+) ULP", open(sys.argv[1]).read()))
print("PASS" if ok else "FAIL")
EOF
record "complex div/sqrt/log/exp within 4 ULP" "$LOG/unit_cplx.chk" PASS

echo "== 2. FSM engine testbenches (parallel)"
SRC="heston_top_level.v heston_cos_forward.v heston_char_func.v heston_payoff_coeff.v complex_add_sub.v complex_div.v complex_exp.v complex_log.v complex_mult.v complex_sqrt.v cordic.v fp_div.v fp_exp.v fp_log.v fp_sqrt.v"
(cd "$V" && for t in heston_greeks_tb heston_forward_tb heston_axi_top_tb; do
   (iverilog -g2005 -I . -o "$LOG/$t.vvp" tb/$t.v $SRC heston_axi_top.v && vvp -n "$LOG/$t.vvp" > "$LOG/$t.log" 2>&1) &
 done
 (iverilog -g2005 -I . -o "$LOG/bs.vvp" tb/bs_pipeline_tb.v bs_top_level.v bs_forward_core.v bs_reverse_pass.v bs_second_order.v fp_*.v cordic.v && vvp -n "$LOG/bs.vvp" > "$LOG/bs.log" 2>&1) &
 wait)
record "FSM Heston AAD: price + 9 sensitivities vs reference" "$LOG/heston_greeks_tb.log" "PASS: all outputs"
record "FSM Heston price-only pass vs reference" "$LOG/heston_forward_tb.log" "^PASS"
record "FSM Heston AXI4-Stream wrapper" "$LOG/heston_axi_top_tb.log" "PASS: AXI4-Stream"
"$PY" - "$LOG/bs.log" <<'EOF' > "$LOG/bs.chk"
import re, sys
bad = 0
for got, exp in re.findall(r"=\s*(-?[\d.]+)\s*\(expect\s*(-?[\d.]+)\)", open(sys.argv[1]).read()):
    g, e = float(got), float(exp)
    if abs(g - e) > 3e-3 * max(1.0, abs(e)):     # Q16.16 core: price error ~ S * ULP
        bad += 1
print("PASS" if bad == 0 else "FAIL %d" % bad)
EOF
record "Black-Scholes AAD (Q16.16) within 0.3% of closed form" "$LOG/bs.chk" PASS

echo "== 3. generated shared-multiplier datapaths"
cd "$ROOT/hardware/gen"
Z7="--wl 56 --fl 28 --mults 8 --crot 3 --cvec 2"
ZU="--wl 64 --fl 32 --mults 32 --crot 1 --cvec 1 --pipe-cordic"
( "$PY" gen_tb.py $Z7 --name heston_aad_z7   > "$LOG/gen_z7.log" 2>&1 ) &
( "$PY" gen_tb.py $ZU --name heston_aad_zu   > "$LOG/gen_zu.log" 2>&1 ) &
( "$PY" gen_tb.py $Z7 --price-only --name z7_pricer > "$LOG/gen_z7_price.log" 2>&1 ) &
( "$PY" gen_tb.py $ZU --price-only --name zu_pricer > "$LOG/gen_zu_price.log" 2>&1 ) &
( "$PY" gen_tb.py $Z7 --host-setup --name heston_aad_z7h > "$LOG/gen_z7h.log" 2>&1 ) &
wait
record "generated AAD, Zynq-7020 config: bit-exact, 4731 cycles" "$LOG/gen_z7.log" "PASS: RTL matches"
record "generated AAD, 64-bit config: bit-exact, 1599 cycles" "$LOG/gen_zu.log" "PASS: RTL matches"
record "generated price-only pricer, Zynq-7020 config" "$LOG/gen_z7_price.log" "PASS: RTL matches"
record "generated price-only pricer, 64-bit config" "$LOG/gen_zu_price.log" "PASS: RTL matches"
record "generated AAD loop, host setup (Zynq-7020): bit-exact" "$LOG/gen_z7h.log" "PASS: RTL matches"
record "range_err raised for out-of-domain input (Zynq-7020)" "$LOG/gen_z7.log" "correctly flagged"
record "range_err raised for out-of-domain input (64-bit)" "$LOG/gen_zu.log" "correctly flagged"
( "$PY" wrappers.py axi  $Z7 --name heston_aad_z7 > "$LOG/axi_z7.log" 2>&1 ) &
( "$PY" wrappers.py axi  $ZU --name heston_aad_zu > "$LOG/axi_zu.log" 2>&1 ) &
( "$PY" wrappers.py bump $Z7 --name z7 > "$LOG/bump_z7.log" 2>&1 ) &
( "$PY" wrappers.py bump $ZU --name zu > "$LOG/bump_zu.log" 2>&1 ) &
( "$PY" wrappers.py axi  $Z7 --host-setup --name heston_aad_z7h > "$LOG/axi_z7h.log" 2>&1 ) &
( "$PY" host.py > "$LOG/host.log" 2>&1 ) &
wait
record "generated AXI4-Stream wrapper, Zynq-7020 config" "$LOG/axi_z7.log" "PASS: AXI4-Stream"
record "generated AXI4-Stream wrapper, 64-bit config" "$LOG/axi_zu.log" "PASS: AXI4-Stream"
record "generated AXI4-Stream wrapper, host-setup Zynq-7020" "$LOG/axi_z7h.log" "PASS: AXI4-Stream"
record "host setup + FPGA loop + host finish == on-chip design" "$LOG/host.log" "^PASS"
record "bump-and-reprice on generated pricer, Zynq-7020" "$LOG/bump_z7.log" "PASS: bump-and-reprice"
record "bump-and-reprice on generated pricer, 64-bit" "$LOG/bump_zu.log" "PASS: bump-and-reprice"

echo "== 4. committed generated RTL == generator output"
ok=1
for f in heston_aad_z7 heston_aad_zu heston_aad_z7h z7_pricer zu_pricer heston_aad_z7_axi heston_aad_zu_axi heston_aad_z7h_axi heston_bump_z7 heston_bump_zu; do
  cmp -s "build/$f.v" "$V/gen/$f.v" || { echo "  differs: $f.v"; ok=0; }
done
[ $ok = 1 ] && echo PASS > "$LOG/gen_cmp.chk" || echo FAIL > "$LOG/gen_cmp.chk"
record "hardware/verilog/gen/*.v up to date" "$LOG/gen_cmp.chk" PASS

echo "== 5. emulator accuracy and error bound"
"$PY" check_accuracy.py 32 > "$LOG/acc32.log" 2>&1
"$PY" - "$LOG/acc32.log" <<'EOF' > "$LOG/acc32.chk"
import re, sys
rows = re.findall(r"^\w+\s+[+-][\d.]+\s+(-?[\d.e+-]+)\s+(-?[\d.e+-]+)\s+([\d.e+-]+)\s+([\d.]+)$", open(sys.argv[1]).read(), re.M)
ok = rows and all(float(r[3]) <= 1.0 for r in rows) and all(abs(float(r[0])) < 1e-5 for r in rows)
print("PASS" if ok else "FAIL")
EOF
record "64-bit emulator: all errors < 1e-5, all below bound" "$LOG/acc32.chk" PASS

echo
fails=0
for r in "${RESULTS[@]}"; do [ "$r" = FAIL ] && fails=$((fails + 1)); done
echo "${#RESULTS[@]} checks, $fails failed (logs: $LOG)"
[ $fails = 0 ]
