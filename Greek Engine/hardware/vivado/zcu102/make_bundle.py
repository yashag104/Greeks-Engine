"""Pack what the ZCU102 build and board runs need into one zip for the lab machine.

    python make_bundle.py [out.zip]      (default: greeks_zcu102.zip next to this file)

The zip unpacks to greeks_zcu102/hardware/..., the same relative layout as this
repository, so the scripts' relative paths work unchanged. The test vectors in
hardware/gen/build are generated files (not committed), so they are taken from
this checkout; run board_vectors.py first if they are missing.
"""
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
HW = os.path.normpath(os.path.join(HERE, "..", ".."))
FILES = ["verilog/gen/heston_aad_zu.v", "verilog/gen/heston_aad_zu_lite.v",
         "gen/build/heston_aad_zu_lite_vector.tcl", "gen/build/heston_aad_zu_lite_sweep.tcl",
         "gen/build/heston_aad_zu_lite_nifty.tcl",
         "vivado/zcu104/bd_jtag.tcl", "vivado/zedboard/run_jtag.tcl", "vivado/zedboard/mock/mock_vivado.tcl"]
FILES += ["vivado/zcu102/" + f for f in ["bd_jtag.tcl", "run_jtag.tcl", "run_sweep.tcl", "run_nifty.tcl",
                                         "run_board.sh", "README.md", "mock/drive.tcl", "bd_ps.tcl"]]
FILES += ["sw/zcu102/" + f for f in ["main.c", "pc_test.h", "build_vitis.py", "run_app.tcl", "gen_cases.py",
                                     "generated/zu_cases.h", "README.md"]]

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "greeks_zcu102.zip")
missing = [f for f in FILES if not os.path.isfile(os.path.join(HW, f))]
if missing:
    raise SystemExit("ERROR: missing %s" % ", ".join(missing))
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in FILES:
        info = zipfile.ZipInfo("greeks_zcu102/hardware/" + f)
        info.external_attr = (0o755 if f.endswith(".sh") else 0o644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        # Linux shells and Tcl need LF line endings
        z.writestr(info, open(os.path.join(HW, f), "rb").read().replace(b"\r\n", b"\n"))
print("wrote %s (%d files)" % (out, len(FILES)))
