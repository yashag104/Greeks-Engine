"""Build the ZedBoard end-to-end program with the Vitis command line (no IDE).

    D:\\2025.2\\Vitis\\bin\\vitis.bat -s build_vitis.py        (from this folder)
    -> <repo>/vitis_ws_zedboard/heston_app/build/heston_app.elf

Needs hardware/vivado/zedboard/heston_zed.xsa, written by bd_lite.tcl. Creates
a standalone (bare-metal) platform for the Cortex-A9 from it, then an
application from main.c and generated/ (the host steps, register map and test
cases from hardware/gen/cgen.py). The engine's base address is taken from
base_addr_ps.txt, which bd_lite.tcl writes, so it cannot drift from the bitstream.
Run the result with run_app.tcl (xsdb) and read the UART at 115200 baud.

Vitis rejects paths containing spaces, and this repository lives under
"Greek Engine", so the workspace is made next to it at the repository root
(no space) and the XSA and sources are copied in before use.
"""
import os
import shutil

import vitis

HERE = os.path.dirname(os.path.abspath(__file__))
HW = os.path.normpath(os.path.join(HERE, "..", "..", "vivado", "zedboard"))
XSA = os.path.join(HW, "heston_zed.xsa")
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
WS = os.path.join(REPO, "vitis_ws_zedboard")
GEN = os.path.join(HERE, "generated")
if " " in WS:
    raise SystemExit("ERROR: workspace path %s contains a space, which Vitis rejects" % WS)

if not os.path.isfile(XSA):
    raise SystemExit("ERROR: %s not found; run bd_lite.tcl (run_board.bat ps) first" % XSA)
base = open(os.path.join(HW, "base_addr_ps.txt")).read().strip()
print("engine base address from base_addr_ps.txt:", base)

def _rmtree(path):
    """rmtree that clears Windows' read-only flag (Vitis marks generated headers read-only)"""
    import stat

    def onexc(func, p, _exc):
        os.chmod(p, stat.S_IWRITE)
        func(p)
    if os.path.isdir(path):
        shutil.rmtree(path, onexc=onexc)


_rmtree(WS)
STAGE = os.path.join(REPO, "vitis_inputs_zedboard")   # space-free copies of the XSA and sources
_rmtree(STAGE)                                         # (Vitis must create WS itself)
os.makedirs(STAGE)
shutil.copy(XSA, STAGE)
for f in ["main.c"]:
    shutil.copy(os.path.join(HERE, f), STAGE)
for f in ["heston_host.c", "heston_host.h", "heston_host_regs.h", "heston_host_cases.h"]:
    shutil.copy(os.path.join(GEN, f), STAGE)

client = vitis.create_client()
try:
    client.set_workspace(WS)

    platform = client.create_platform_component(name="heston_zed_plat", hw_design=os.path.join(STAGE, "heston_zed.xsa"),
                                                os="standalone",
                                                cpu="ps7_cortexa9_0", domain_name="standalone_a9")
    platform.build()
    xpfm = client.find_platform_in_repos("heston_zed_plat")

    app = client.create_app_component(name="heston_app", platform=xpfm, domain="standalone_a9")
    app.import_files(from_loc=STAGE, files=["main.c", "heston_host.c", "heston_host.h", "heston_host_regs.h",
                                            "heston_host_cases.h"], dest_dir_in_cmp="src")
    app.set_app_config(key="USER_COMPILE_DEFINITIONS", values="HC_BASE=%su" % base)
    app.set_app_config(key="USER_COMPILE_OPTIMIZATION_LEVEL", values="-O2")
    app.build()
    elf = os.path.join(WS, "heston_app", "build", "heston_app.elf")
    print("RESULT: %s %s" % ("built" if os.path.isfile(elf) else "MISSING", elf))
finally:
    vitis.dispose()                 # never leave a Vitis server running
