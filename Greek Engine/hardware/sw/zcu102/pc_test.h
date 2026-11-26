/* Software stand-ins for the ZCU102 engine and power monitors, so main.c runs on a PC:
 *
 *   gcc -O2 -DZU_PC_TEST -DPOWER_WINDOW_MS=200 -Igenerated main.c -o zu_pc_test && ./zu_pc_test
 *
 * The register model answers a start with the expected outputs of whichever case
 * the 19 input words match (so it checks this program's register traffic, not the
 * engine), and its first STAT read after a start returns the previous status, as
 * a read that overtakes the start write on the bus would. The INA226 model
 * answers at 0x40-0x45 (0x46, 0x47 absent), with a shunt reading that rises while
 * evaluations run, and its I2C fails now and then, to exercise the retries.
 */
#include <time.h>

static uint32_t pc_regs[1024];
static int pc_stale, pc_busy_reads;
static unsigned long pc_evals;

static void pc_wr(uint32_t off, uint32_t v) {
  pc_regs[off / 4] = v;
  if (off == 0x100 && (v & 1)) {
    pc_stale = 1;            /* next STAT read: the old value */
    pc_busy_reads = 3;
    int hit = -1;
    for (int c = 0; c < ZU_NCASES && hit < 0; c++)
      if (!memcmp(zu_cases[c].w, pc_regs, sizeof zu_cases[c].w)) hit = c;
    for (int i = 0; i < ZU_NOUT; i++) {
      uint64_t o = hit < 0 ? 0 : (uint64_t)zu_cases[hit].want[i];
      pc_regs[zu_out_off[i] / 4] = (uint32_t)o;
      pc_regs[zu_out_off[i] / 4 + 1] = (uint32_t)(o >> 32);
    }
    pc_evals++;
  }
}
static uint32_t pc_rd(uint32_t off) {
  if (off == 0x104) {
    if (pc_stale) { pc_stale = 0; return pc_regs[0x104 / 4]; }
    if (pc_busy_reads) { pc_busy_reads--; return pc_regs[0x104 / 4] = 4; }
    return pc_regs[0x104 / 4] = 1;
  }
  return pc_regs[off / 4];
}
#define REG_WR(off, v) pc_wr((off), (uint32_t)(v))
#define REG_RD(off)    pc_rd(off)
static uint64_t pc_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
#define NOW()       pc_now()
#define TICKS_PER_S 1000000000ull

static unsigned char pc_logmem[256 * 1024] __attribute__((aligned(8)));
#define LOG_ADDR ((uintptr_t)pc_logmem)

static uint8_t pc_ptr, pc_mux;
static unsigned long pc_i2c_ops, pc_seen_evals;
static int i2c_init(void) { return 0; }
static int i2c_wr(uint8_t a, uint8_t *b, int n) {
  if (++pc_i2c_ops % 97 == 0) return -1;              /* an occasional bus error */
  if (a == 0x75) { pc_mux = b[0]; return 0; }
  if (pc_mux != 0x05 || a < 0x40 || a > 0x45 || n != 1) return -1;
  pc_ptr = b[0];
  return 0;
}
static int i2c_rd(uint8_t a, uint8_t *b, int n) {
  if (pc_mux != 0x05 || a < 0x40 || a > 0x45 || n != 2) return -1;
  uint16_t v = 0;
  if (pc_ptr == 0xFE) v = 0x5449;
  else if (pc_ptr == 0x02) v = a == 0x40 ? 680 : 1440;                 /* 0.85 V, 1.8 V */
  else if (pc_ptr == 0x01) {                                           /* 1 mV idle, +2 mV busy */
    v = (uint16_t)(400 + (pc_evals != pc_seen_evals ? 800 : 0));
    pc_seen_evals = pc_evals;
  }
  b[0] = (uint8_t)(v >> 8); b[1] = (uint8_t)v;
  return 0;
}
