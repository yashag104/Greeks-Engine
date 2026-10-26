"""Build the ZCU102 end-to-end program with the Vitis command line (no IDE).

    vitis -s build_vitis.py        (from this folder; or ../../vivado/zcu102/run_board.sh app)
    -> <repo>/vitis_ws_zcu102/heston_app/build/heston_app.elf

Needs hardware/vivado/zcu102/heston_zcu102_ps.xsa, written by bd_ps.tcl. Creates
a standalone (bare-metal) platform for Cortex-A53 #0 from it, then an
application from main.c and generated/zu_cases.h (the 101 board cases, from
gen_cases.py). The engine's base address is taken from base_addr_ps.txt, which
bd_ps.tcl writes, so it cannot drift from the bitstream. Run the result with
run_app.tcl (xsdb).

Vitis rejects paths containing spaces, so the workspace is made at the
repository root (the parent of "hardware") and must have none.
"""
import os
import shutil

import vitis

HERE = os.path.dirname(os.path.abspath(__file__))
HW = os.path.normpath(os.path.join(HERE, "..", "..", "vivado", "zcu102"))
XSA = os.path.join(HW, "heston_zcu102_ps.xsa")
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
WS = os.path.join(REPO, "vitis_ws_zcu102")
STAGE = os.path.join(REPO, "vitis_inputs_zcu102")
SOURCES = [os.path.join(HERE, "main.c"), os.path.join(HERE, "generated", "zu_cases.h")]
if " " in WS:
    raise SystemExit("ERROR: workspace path %s contains a space, which Vitis rejects" % WS)
if not os.path.isfile(XSA):
    raise SystemExit("ERROR: %s not found; run bd_ps.tcl (run_board.sh ps) first" % XSA)
base = open(os.path.join(HW, "base_addr_ps.txt")).read().strip()
print("engine base address from base_addr_ps.txt:", base)


def _rmtree(path):
    """rmtree that clears read-only flags (Vitis marks generated headers read-only)"""
    import stat

    def onexc(func, p, _exc):
        os.chmod(p, stat.S_IWRITE)
        func(p)
    if os.path.isdir(path):
        shutil.rmtree(path, onexc=onexc)


_rmtree(WS)                       # Vitis must create the workspace itself
_rmtree(STAGE)
os.makedirs(STAGE)
shutil.copy(XSA, STAGE)
for f in SOURCES:
    shutil.copy(f, STAGE)

client = vitis.create_client()
try:
    client.set_workspace(WS)
    platform = client.create_platform_component(name="heston_zcu102_plat",
                                                hw_design=os.path.join(STAGE, "heston_zcu102_ps.xsa"),
                                                os="standalone", cpu="psu_cortexa53_0",
                                                domain_name="standalone_a53")
    platform.build()
    xpfm = client.find_platform_in_repos("heston_zcu102_plat")

    app = client.create_app_component(name="heston_app", platform=xpfm, domain="standalone_a53")
    app.import_files(from_loc=STAGE, files=["main.c", "zu_cases.h"], dest_dir_in_cmp="src")
    app.set_app_config(key="USER_COMPILE_DEFINITIONS", values="ZU_BASE=%su" % base)
    app.set_app_config(key="USER_COMPILE_OPTIMIZATION_LEVEL", values="-O2")
    app.build()
    elf = os.path.join(WS, "heston_app", "build", "heston_app.elf")
    print("RESULT: %s %s" % ("built" if os.path.isfile(elf) else "MISSING", elf))
finally:
    vitis.dispose()                 # never leave a Vitis server running
