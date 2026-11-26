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

def show_logs():
    """print the end of every log Vitis left in the workspace (its errors are only there)"""
    import glob
    logs = sorted(glob.glob(os.path.join(WS, "**", "*.log"), recursive=True) +
                  glob.glob(os.path.join(WS, "**", "*.txt"), recursive=True), key=os.path.getmtime)
    for f in logs[-6:]:
        print("===== %s" % f)
        print("".join(open(f, errors="replace").readlines()[-25:]))


client = vitis.create_client()
try:
    client.set_workspace(WS)
    # The boot components (FSBL, PMU firmware) are not needed: run_app.tcl initialises
    # the PS with psu_init over JTAG. Skip them where this Vitis version allows it.
    import inspect
    opts = dict(name="heston_zcu102_plat", hw_design=os.path.join(STAGE, "heston_zcu102_ps.xsa"),
                os="standalone", cpu="psu_cortexa53_0", domain_name="standalone_a53")
    params = inspect.signature(client.create_platform_component).parameters
    if "no_boot_bsp" in params:
        opts["no_boot_bsp"] = True
    print("create_platform_component options:", ", ".join(sorted(k for k in opts if k != "hw_design")))
    try:
        platform = client.create_platform_component(**opts)
        platform.build()
    except Exception as e:
        print("ERROR: platform creation failed: %s" % e)
        print("create_platform_component accepts: %s" % ", ".join(params))
        show_logs()
        raise
    xpfm = client.find_platform_in_repos("heston_zcu102_plat")

    app = client.create_app_component(name="heston_app", platform=xpfm, domain="standalone_a53")
    app.import_files(from_loc=STAGE, files=["main.c", "zu_cases.h"], dest_dir_in_cmp="src")
    app.set_app_config(key="USER_COMPILE_DEFINITIONS", values="ZU_BASE=%su" % base)
    # Link everything into the on-chip memory, not the DDR (the lab board's DDR did
    # not train with the preset's settings), keeping OCM's first 16 KB for the log
    # buffer at 0xFFFC0000 (LOG_ADDR in main.c, run_app.tcl).
    import re
    ld = os.path.join(WS, "heston_app", "src", "lscript.ld")
    text = open(ld).read()
    text, n_sec = re.subn(r">\s*psu_ddr_0_memory_0", "> psu_ocm_ram_0_memory_0", text)
    text, n_mem = re.subn(r"(psu_ocm_ram_0_memory_0\s*:\s*ORIGIN\s*=\s*)0x[fF]{3}[cC]0000(\s*,\s*LENGTH\s*=\s*)0x40000",
                          r"\g<1>0xfffc4000\g<2>0x3c000", text)
    if n_sec == 0 or n_mem != 1:
        raise SystemExit("ERROR: could not move the program to OCM in %s (%d sections, %d regions)" % (ld, n_sec, n_mem))
    open(ld, "w").write(text)
    print("linker script: %d sections moved to OCM (0xfffc4000, 240 KB); log at 0xfffc0000" % n_sec)
    app.set_app_config(key="USER_COMPILE_OPTIMIZATION_LEVEL", values="-O2")
    try:
        app.build()
    except Exception as e:
        print("ERROR: application build failed: %s" % e)
        show_logs()
        raise
    elf = os.path.join(WS, "heston_app", "build", "heston_app.elf")
    print("RESULT: %s %s" % ("built" if os.path.isfile(elf) else "MISSING", elf))
finally:
    vitis.dispose()                 # never leave a Vitis server running
