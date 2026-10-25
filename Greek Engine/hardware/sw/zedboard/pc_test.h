/* PC stand-in for the engine's AXI4-Lite registers, so main.c's logic (register
 * layout, 64-bit word order, 56-bit sign extension, host steps) can be checked
 * without a board:
 *   gcc -O2 -DHC_PC_TEST -Igenerated main.c generated/heston_host.c -o pc_test && ./pc_test
 * On start it finds the case whose parameters were written and answers with that
 * case's loop sums, laid out as the RTL lays them out (56-bit, high word
 * zero-padded); it also checks that the 16 host constants arrived intact. */
#include <string.h>
#include <time.h>
static uint32_t pc_mem[1024];
static void pc_write(unsigned off, uint32_t v);
#define REG_WR(off, v) pc_write((off), (uint32_t)(v))
#define REG_RD(off)    pc_mem[(off) / 4]
static uint64_t pc_now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec; }
#define NOW()          pc_now()
#define TICKS_PER_S    1000000000ull
static int64_t pc_rd64(unsigned off) { return (int64_t)(((uint64_t)pc_mem[off / 4 + 1] << 32) | pc_mem[off / 4]); }
static void pc_write(unsigned off, uint32_t v) {
  pc_mem[off / 4] = v;
  if (off != HC_REG_CTRL || !(v & 1)) return;
  pc_mem[HC_REG_STAT / 4] = 0;
  for (int c = 0; c < HC_NCASES; c++) {
    int hit = 1;
    for (int i = 0; i < 9; i++) if (pc_rd64(hc_param_regs[i]) != hc_cases[c].p[i]) hit = 0;
    if (!hit || (int)pc_mem[HC_REG_IS_CALL / 4] != hc_cases[c].is_call) continue;
    hc_ctx ctx; int64_t ports[HC_NPORTS];                 /* the constants must have arrived */
    hc_setup(hc_cases[c].p, hc_cases[c].is_call, &ctx, ports);
    for (int i = 0; i < HC_NPORTS; i++) if (pc_rd64(hc_port_regs[i]) != ports[i]) { printf("stub: constant %d corrupted\n", i); return; }
    for (int i = 0; i < HC_NSUMS; i++) {
      uint64_t raw = (uint64_t)hc_cases[c].sums[i] & (((uint64_t)1 << HC_WL) - 1);
      pc_mem[hc_sum_regs[i] / 4] = (uint32_t)raw;
      pc_mem[hc_sum_regs[i] / 4 + 1] = (uint32_t)(raw >> 32);
    }
    pc_mem[HC_REG_STAT / 4] = 1;                          /* done */
    return;
  }
  printf("stub: no case matches the written inputs\n");
}
