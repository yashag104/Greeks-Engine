/* End-to-end Heston price + 9 Greeks on the ZedBoard: ARM host steps + FPGA loop.
 *
 * Vitis standalone (bare-metal) application for the processor design built by
 * hardware/vivado/zedboard/bd_lite.tcl (PS -> AXI4-Lite -> heston_aad_z7h_lite).
 * For every case in heston_host_cases.h (50 board-sweep cases, 50 real NIFTY
 * days) it runs the whole evaluation on the board:
 *
 *   setup    hc_setup on the ARM: the 16 per-evaluation constants
 *   write    9 parameters, is_call and the 16 constants over AXI4-Lite (51 words)
 *   engine   start, then poll STAT until done (the FPGA's 128-term loop)
 *   read     the 9 sums back (18 words)
 *   finish   hc_finish on the ARM: discounting and the final chain rule
 *
 * and checks all 10 outputs bit-exact against the emulator. Each stage is timed
 * with the Cortex-A9 global timer, so the end-to-end latency includes the bus
 * transfers that the 65.3 us loop-only figure leaves out. Output over UART.
 *
 * The same file builds on a PC against a software stand-in for the engine's
 * registers (pc_test.c), which checks this program's logic before the board.
 *
 * Generated inputs (hardware/gen/cgen.py, copied into generated/):
 *   heston_host.c/.h   bit-exact host steps   heston_host_regs.h  register map
 *   heston_host_cases.h  inputs and expected outputs
 */
#include <stdint.h>
#include <stdio.h>
#include "heston_host.h"
#include "heston_host_regs.h"
#include "heston_host_cases.h"

#ifdef HC_PC_TEST
#include "pc_test.h"
#else
#include "xil_io.h"
#include "sleep.h"
#if defined(__has_include) && __has_include("xiltimer.h")
#include "xiltimer.h"        /* Vitis 2023.2+: XTime_GetTime and XTime here */
#include "xtimer_config.h"   /* COUNTS_PER_SECOND (the global timer: CPU clock / 2) */
#else
#include "xtime_l.h"         /* older standalone BSPs */
#endif
#define REG_WR(off, v) Xil_Out32(HC_BASE + (off), (uint32_t)(v))
#define REG_RD(off)    Xil_In32(HC_BASE + (off))
#define NOW()          ({ XTime t_; XTime_GetTime(&t_); (uint64_t)t_; })
#define TICKS_PER_S    ((uint64_t)COUNTS_PER_SECOND)
#endif

/* bd_lite.tcl writes the engine's address to base_addr_ps.txt (0x40000000, the
 * start of M_AXI_GP0, in the 2025.2 build); build_vitis.py passes it as -DHC_BASE. */
#ifndef HC_BASE
#define HC_BASE 0x40000000u
#endif
#define STAT_DONE  1u
#define STAT_RERR  2u
#define REPEAT     200      /* timing repetitions of each stage, case 1 */

static void wr64(unsigned off, int64_t v) {      /* low word first, as the RTL expects */
  REG_WR(off, (uint32_t)((uint64_t)v & 0xffffffffu));
  REG_WR(off + 4, (uint32_t)((uint64_t)v >> 32));
}

static int64_t rd_sum(unsigned off) {             /* 56-bit word, high word zero-padded */
  uint64_t lo = REG_RD(off), hi = REG_RD(off + 4);
  uint64_t raw = ((hi & ((1u << (HC_WL - 32)) - 1)) << 32) | lo;
  if (raw & ((uint64_t)1 << (HC_WL - 1))) raw -= (uint64_t)1 << HC_WL;   /* sign-extend */
  return (int64_t)raw;
}

typedef struct { uint64_t setup, write, engine, read, finish; } stage_t;

/* one whole evaluation; returns 0, or -1 on range_err / a stuck engine */
static int evaluate(const hc_case *c, int64_t out[HC_NOUT], stage_t *t) {
  hc_ctx ctx;
  int64_t ports[HC_NPORTS], sums[HC_NSUMS];
  uint64_t t0 = NOW();
  hc_setup(c->p, c->is_call, &ctx, ports);
  uint64_t t1 = NOW();
  for (int i = 0; i < 9; i++) wr64(hc_param_regs[i], c->p[i]);
  REG_WR(HC_REG_IS_CALL, c->is_call ? 1u : 0u);
  for (int i = 0; i < HC_NPORTS; i++) wr64(hc_port_regs[i], ports[i]);
  uint64_t t2 = NOW();
  REG_WR(HC_REG_CTRL, 1u);
  uint32_t st;
  long spins = 0;
  while (!((st = REG_RD(HC_REG_STAT)) & STAT_DONE))
    if (++spins > 100000000L) return -1;
  uint64_t t3 = NOW();
  if (st & STAT_RERR) return -1;
  for (int i = 0; i < HC_NSUMS; i++) sums[i] = rd_sum(hc_sum_regs[i]);
  uint64_t t4 = NOW();
  hc_finish(&ctx, sums, out);
  uint64_t t5 = NOW();
  t->setup = t1 - t0; t->write = t2 - t1; t->engine = t3 - t2; t->read = t4 - t3; t->finish = t5 - t4;
  return 0;
}

static unsigned ns(uint64_t ticks) { return (unsigned)(ticks * 1000000000ull / TICKS_PER_S); }

int main(void) {
  static const char *names[HC_NOUT] = {"price", "delta", "strike_sens", "theta_greek", "rho_greek",
                                       "vega", "kappa_sens", "theta_sens", "xi_sens", "rho_corr"};
  int bad_cases = 0, bad_outputs = 0;
#ifndef HC_PC_TEST
  /* The xiltimer library starts the Cortex-A9 global timer only on the first
   * sleep call, so without this every timestamp would read the same value. */
  usleep(1);
#endif
  {
    uint64_t a = NOW();
    for (volatile int i = 0; i < 100000; i++) { }
    if (NOW() == a) { printf("ERROR: the timer is not running; timings would be meaningless\r\n"); return 2; }
  }
  printf("\r\nHeston AAD engine, end to end on the ZedBoard (ARM host steps + FPGA loop)\r\n");
  printf("engine at 0x%08x, %d cases, global timer %u Hz\r\n", (unsigned)HC_BASE, HC_NCASES,
         (unsigned)TICKS_PER_S);
  for (int c = 0; c < HC_NCASES; c++) {
    int64_t out[HC_NOUT];
    stage_t t;
    if (evaluate(&hc_cases[c], out, &t)) {
      printf("CASE %d: FAIL (range_err or engine timeout)\r\n", c + 1);
      bad_cases++;
      continue;
    }
    int e = 0;
    for (int i = 0; i < HC_NOUT; i++)
      if (out[i] != hc_cases[c].want[i]) {
        e++;
        printf("  FAIL %-12s got %lld want %lld\r\n", names[i], (long long)out[i], (long long)hc_cases[c].want[i]);
      }
    if (e) { bad_cases++; bad_outputs += e; printf("CASE %d: FAIL (%d)\r\n", c + 1, e); }
  }
  if (bad_cases == 0)
    printf("PASS: %d cases x %d outputs bit-exact vs the emulator (1-50 board sweep, 51-100 real NIFTY)\r\n",
           HC_NCASES, HC_NOUT);
  else
    printf("FAIL: %d of %d cases, %d outputs differ\r\n", bad_cases, HC_NCASES, bad_outputs);

  /* timing: each stage, best and mean over REPEAT runs of case 1 (warm caches) */
  stage_t best = {~0ull, ~0ull, ~0ull, ~0ull, ~0ull}, sum = {0, 0, 0, 0, 0};
  for (int r = 0; r < REPEAT; r++) {
    int64_t out[HC_NOUT];
    stage_t t;
    if (evaluate(&hc_cases[0], out, &t)) { printf("TIMING: FAIL\r\n"); return 1; }
#define ACC(f) do { sum.f += t.f; if (t.f < best.f) best.f = t.f; } while (0)
    ACC(setup); ACC(write); ACC(engine); ACC(read); ACC(finish);
  }
  printf("TIMING (ns, best / mean of %d)\r\n", REPEAT);
  printf("  setup   (ARM)              %8u %8u\r\n", ns(best.setup), ns(sum.setup / REPEAT));
  printf("  write   (51 words, AXI)    %8u %8u\r\n", ns(best.write), ns(sum.write / REPEAT));
  printf("  engine  (start .. done)    %8u %8u\r\n", ns(best.engine), ns(sum.engine / REPEAT));
  printf("  read    (18 words, AXI)    %8u %8u\r\n", ns(best.read), ns(sum.read / REPEAT));
  printf("  finish  (ARM)              %8u %8u\r\n", ns(best.finish), ns(sum.finish / REPEAT));
  uint64_t tb = best.setup + best.write + best.engine + best.read + best.finish;
  uint64_t tm = (sum.setup + sum.write + sum.engine + sum.read + sum.finish) / REPEAT;
  printf("  END TO END                 %8u %8u\r\n", ns(tb), ns(tm));
  return bad_cases != 0;
}
