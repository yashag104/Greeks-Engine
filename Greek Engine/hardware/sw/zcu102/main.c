/* End-to-end Heston price + 9 Greeks on the ZCU102: Cortex-A53 + the 64-bit engine,
 * with timing over the processor bus and power from the board's monitors.
 *
 * Vitis standalone (bare-metal) application for the processor design built by
 * hardware/vivado/zcu102/bd_ps.tcl (PS M_AXI_HPM0_FPD -> AXI4-Lite ->
 * heston_aad_zu_lite, PL clock 100 MHz). Three parts:
 *
 *   1. correctness  all 101 board cases (1 vector, 50-case sweep, 50 real NIFTY
 *                   days; generated/zu_cases.h) checked bit-exact, 10 outputs each
 *   2. timing       each stage with the A53's generic timer, best and mean of
 *                   REPEAT evaluations: write 19 words, engine (start .. done),
 *                   read 20 words, and the whole evaluation; then back-to-back
 *                   throughput
 *   3. power        the INA226 monitors on the PL_PMBUS (I2C0, mux 0x75 channel 1)
 *                   read in alternating IDLE / RUN windows; RUN = evaluations back
 *                   to back. Engine power = RUN - IDLE; energy per evaluation =
 *                   that power / evaluations per second
 *
 * Output goes to the UART and, so that no serial console is needed, into a log
 * buffer in DDR at LOG_ADDR, which run_app.tcl saves to a file after the run.
 *
 * The same file builds on a PC against software stand-ins (pc_test.h), which
 * checks this program's logic before the board.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "zu_cases.h"

#ifdef ZU_PC_TEST
#include "pc_test.h"
#else
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"
#include "xiicps.h"
#if defined(__has_include) && __has_include("xiltimer.h")
#include "xiltimer.h"        /* Vitis 2023.2+: XTime_GetTime and XTime here */
#include "xtimer_config.h"   /* COUNTS_PER_SECOND */
#else
#include "xtime_l.h"
#endif
#define REG_WR(off, v) Xil_Out32(ZU_BASE + (off), (uint32_t)(v))
#define REG_RD(off)    Xil_In32(ZU_BASE + (off))
#define NOW()          ({ XTime t_; XTime_GetTime(&t_); (uint64_t)t_; })
#define TICKS_PER_S    ((uint64_t)COUNTS_PER_SECOND)
#endif

/* bd_ps.tcl writes the engine's address to base_addr_ps.txt; build_vitis.py passes it
 * as -DZU_BASE. 0xA0000000 is the start of M_AXI_HPM0_FPD. */
#ifndef ZU_BASE
#define ZU_BASE 0xA0000000u
#endif
#define ZU_CTRL    0x100u
#define ZU_STAT    0x104u
#define STAT_DONE  1u
#define STAT_RERR  2u
#define STAT_BUSY  4u
#define REPEAT     1000
#ifndef POWER_WINDOW_MS
#define POWER_WINDOW_MS 10000     /* per IDLE / RUN window */
#endif
#define POWER_REPS 3

/* ---- log: UART and a DDR buffer that xsdb reads after the run ------------------ */
#ifndef LOG_ADDR
#define LOG_ADDR 0x40000000u      /* 1 GB into DDR, far above this small program */
#endif
#define LOG_MAX    (192 * 1024)
#define LOG_RUN    0x52554e21u    /* "RUN!": running; "DONE" when finished */
#define LOG_DONE   0x444f4e45u
typedef struct { volatile uint32_t magic, len; char text[LOG_MAX]; } logbuf_t;
#define LOGB ((logbuf_t *)(uintptr_t)LOG_ADDR)

static void out(const char *fmt, ...) {
  char line[256];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  if (n >= (int)sizeof line) n = sizeof line - 1;
  fputs(line, stdout);
  if (LOGB->len + (uint32_t)n < LOG_MAX) { memcpy(LOGB->text + LOGB->len, line, n); LOGB->len += n; }
}

/* ---- one evaluation ------------------------------------------------------------ */
typedef struct { uint64_t write, engine, read; } stage_t;

/* 0, or -1 on a stuck engine, -2 on range_err. A read may overtake the start write
 * on the bus (AXI orders reads and writes separately), and STAT still holds the
 * previous done: so wait to see busy first. The engine is busy for 1,593 cycles,
 * far longer than one read, so busy is always seen. */
static int evaluate(const zu_case *c, int64_t o[ZU_NOUT], stage_t *t) {
  uint64_t t0 = NOW();
  for (int i = 0; i < ZU_NWORDS; i++) REG_WR(zu_in_off[i], c->w[i]);
  uint64_t t1 = NOW();
  REG_WR(ZU_CTRL, 1u);
  uint32_t st;
  long spins = 0;
  while (!((st = REG_RD(ZU_STAT)) & STAT_BUSY))
    if (++spins > 10000000L) return -1;
  while (!((st = REG_RD(ZU_STAT)) & STAT_DONE))
    if (++spins > 10000000L) return -1;
  uint64_t t2 = NOW();
  if (st & STAT_RERR) return -2;
  for (int i = 0; i < ZU_NOUT; i++) {
    uint64_t lo = REG_RD(zu_out_off[i]), hi = REG_RD(zu_out_off[i] + 4);
    o[i] = (int64_t)((hi << 32) | lo);
  }
  uint64_t t3 = NOW();
  t->write = t1 - t0; t->engine = t2 - t1; t->read = t3 - t2;
  return 0;
}

static unsigned ns(uint64_t ticks) { return (unsigned)(ticks * 1000000000ull / TICKS_PER_S); }

/* ---- the PL power monitors -------------------------------------------------------
 * ZCU102 PL_PMBUS: INA226 at 0x40-0x47 behind the PCA9544 mux at 0x75 (channel 1)
 * on I2C0. Shunts from the Linux device tree (zynqmp-zcu102-revA.dts, micro-ohm):
 * 2,000 at 0x40, 5,000 elsewhere. Rail names after UG1182; the sum over all of
 * them does not depend on the names. Only the shunt and bus voltage registers are
 * read (no writes to the monitors), so their reset configuration stands: one
 * 1.1 ms shunt and one 1.1 ms bus conversion, alternating. */
typedef struct { uint8_t addr; uint16_t shunt_uohm; const char *name; } rail_t;
static const rail_t rails[] = {{0x40, 2000, "VCCINT"}, {0x41, 5000, "VCCBRAM"}, {0x42, 5000, "VCCAUX"},
                               {0x43, 5000, "VCC1V2"}, {0x44, 5000, "VCC3V3"}, {0x45, 5000, "VADJ_FMC"},
                               {0x46, 5000, "MGTAVCC"}, {0x47, 5000, "MGTAVTT"}};
#define NRAIL ((int)(sizeof rails / sizeof rails[0]))
#define MUX_ADDR 0x75
#define MUX_PL   1

#ifndef ZU_PC_TEST
#define ZU_I2C0_BASE 0xFF020000u
static XIicPs iic;
static int i2c_init(void) {
  XIicPs_Config *cfg = NULL;
#ifdef SDT
  cfg = XIicPs_LookupConfig(ZU_I2C0_BASE);
#else
  for (int id = 0; id < XPAR_XIICPS_NUM_INSTANCES && !cfg; id++) {
    XIicPs_Config *c = XIicPs_LookupConfig(id);
    if (c && c->BaseAddress == ZU_I2C0_BASE) cfg = c;
  }
#endif
  if (!cfg || XIicPs_CfgInitialize(&iic, cfg, cfg->BaseAddress) != XST_SUCCESS) return -1;
  XIicPs_SetSClk(&iic, 400000);
  return 0;
}
static int i2c_idle(void) {
  for (long i = 0; XIicPs_BusIsBusy(&iic); i++)
    if (i > 1000000L) return -1;
  return 0;
}
static int i2c_wr(uint8_t a, uint8_t *b, int n) {
  if (i2c_idle() || XIicPs_MasterSendPolled(&iic, b, n, a) != XST_SUCCESS) return -1;
  return 0;
}
static int i2c_rd(uint8_t a, uint8_t *b, int n) {
  if (i2c_idle() || XIicPs_MasterRecvPolled(&iic, b, n, a) != XST_SUCCESS) return -1;
  return 0;
}
#endif

static unsigned long i2c_errors;

static int ina_rd(uint8_t a, uint8_t reg, uint16_t *v) {
  uint8_t b[2];
  for (int tries = 0; tries < 3; tries++) {
    if (!i2c_wr(a, &reg, 1) && !i2c_rd(a, b, 2)) { *v = (uint16_t)((b[0] << 8) | b[1]); return 0; }
    i2c_errors++;
  }
  return -1;
}

static int mux_select(int ch) {     /* PCA9544: bit 2 enables, bits 1:0 pick the channel */
  uint8_t v = (uint8_t)(ch < 0 ? 0 : 0x04 | ch);
  return i2c_wr(MUX_ADDR, &v, 1);
}

typedef struct { double vbus[NRAIL], shunt_sum[NRAIL]; long n[NRAIL]; unsigned long evals; uint64_t ticks; } window_t;

/* One window: bursts of 5 ms (evaluations back to back, or nothing), then one
 * shunt reading, rails in turn. The reading is the conversion that ended within
 * the last 2.2 ms, so it saw only the burst. */
static void window(int run, unsigned ms, const int *present, window_t *w) {
  memset(w, 0, sizeof *w);
  for (int r = 0; r < NRAIL; r++) {
    uint16_t v;
    if (present[r] && !ina_rd(rails[r].addr, 0x02, &v)) w->vbus[r] = v * 1.25e-3;
  }
  uint64_t start = NOW(), burst = TICKS_PER_S / 200, end = start + (uint64_t)ms * TICKS_PER_S / 1000;
  int r = 0;
  while (NOW() < end) {
    uint64_t t0 = NOW();
    while (NOW() - t0 < burst) {
      if (run) {
        int64_t o[ZU_NOUT];
        stage_t t;
        if (evaluate(&zu_cases[w->evals % ZU_NCASES], o, &t) == 0) w->evals++;
      }
    }
    for (int k = 0; k < NRAIL && !present[r]; k++) r = (r + 1) % NRAIL;
    uint16_t v;
    if (present[r] && !ina_rd(rails[r].addr, 0x01, &v)) { w->shunt_sum[r] += (int16_t)v * 2.5e-6; w->n[r]++; }
    r = (r + 1) % NRAIL;
  }
  w->ticks = NOW() - start;
}

static double rail_w(const window_t *w, int r) {
  return w->n[r] ? w->vbus[r] * (w->shunt_sum[r] / w->n[r]) / (rails[r].shunt_uohm * 1e-6) : 0.0;
}

static long long mw(double watts) { return (long long)(watts * 1000.0 + (watts < 0 ? -0.5 : 0.5)); }

static void power(void) {
  int present[NRAIL] = {0}, found = 0;
  out("POWER: PL rails (INA226 on PL_PMBUS), windows of %u ms, %d repeats\r\n", (unsigned)POWER_WINDOW_MS, POWER_REPS);
  if (i2c_init() || mux_select(MUX_PL)) { out("POWER: FAIL (I2C0 or the mux at 0x75 did not answer)\r\n"); return; }
  for (int r = 0; r < NRAIL; r++) {
    uint16_t id;
    present[r] = !ina_rd(rails[r].addr, 0xFE, &id) && id == 0x5449;   /* "TI" */
    found += present[r];
    out("  0x%02x %-9s shunt %u uohm  %s\r\n", rails[r].addr, rails[r].name, rails[r].shunt_uohm,
        present[r] ? "INA226 found" : "not found");
  }
  if (!found) { out("POWER: FAIL (no INA226 on the PL bus)\r\n"); mux_select(-1); return; }
  double sum_idle[NRAIL] = {0}, sum_run[NRAIL] = {0}, sum_vbus[NRAIL] = {0}, rate_sum = 0;
  for (int rep = 1; rep <= POWER_REPS; rep++) {
    window_t wi, wr;
    window(0, POWER_WINDOW_MS, present, &wi);
    window(1, POWER_WINDOW_MS, present, &wr);
    double pi = 0, pr = 0, rate = wr.evals * (double)TICKS_PER_S / wr.ticks;
    for (int r = 0; r < NRAIL; r++) {
      pi += rail_w(&wi, r); pr += rail_w(&wr, r);
      sum_idle[r] += rail_w(&wi, r); sum_run[r] += rail_w(&wr, r); sum_vbus[r] += wr.vbus[r];
    }
    rate_sum += rate;
    out("  window %d: IDLE %lld mW, RUN %lld mW (%lu evaluations, %lld per s), difference %lld mW\r\n", rep,
        mw(pi), mw(pr), wr.evals, (long long)(rate + 0.5), mw(pr - pi));
  }
  double rate = rate_sum / POWER_REPS, idle = 0, run = 0;
  out("  per rail, mean of %d windows:  rail      bus mV  IDLE mW  RUN mW  RUN-IDLE mW\r\n", POWER_REPS);
  for (int r = 0; r < NRAIL; r++) {
    if (!present[r]) continue;
    double a = sum_idle[r] / POWER_REPS, b = sum_run[r] / POWER_REPS;
    idle += a; run += b;
    out("                                   %-9s %6lld %7lld %7lld %8lld\r\n", rails[r].name,
        mw(sum_vbus[r] / POWER_REPS), mw(a), mw(b), mw(b - a));
  }
  out("POWER RESULT: PL rails IDLE %lld mW, RUN %lld mW, engine (RUN-IDLE) %lld mW at %lld evaluations/s\r\n",
      mw(idle), mw(run), mw(run - idle), (long long)(rate + 0.5));
  out("ENERGY RESULT: %lld nJ per evaluation (RUN-IDLE), %lld nJ including the PL's idle power (RUN)\r\n",
      (long long)((run - idle) / rate * 1e9 + 0.5), (long long)(run / rate * 1e9 + 0.5));
  out("  I2C retries: %lu\r\n", i2c_errors);
  mux_select(-1);
}

int main(void) {
  LOGB->len = 0;
  LOGB->magic = LOG_RUN;
  int bad_cases = 0, bad_outputs = 0;
#ifndef ZU_PC_TEST
  usleep(1);      /* the xiltimer library starts the timer on the first sleep call */
#endif
  {
    uint64_t a = NOW();
    for (volatile int i = 0; i < 100000; i++) { }
    if (NOW() == a) { out("ERROR: the timer is not running; timings would be meaningless\r\n"); goto done; }
  }
  out("\r\nHeston AAD engine, end to end on the ZCU102 (Cortex-A53 + 64-bit engine)\r\n");
  out("engine at 0x%08x, %d cases, timer %llu Hz\r\n", (unsigned)ZU_BASE, ZU_NCASES,
      (unsigned long long)TICKS_PER_S);

  /* 1. correctness */
  int per_kind_bad[3] = {0, 0, 0}, per_kind_n[3] = {0, 0, 0};
  for (int c = 0; c < ZU_NCASES; c++) {
    const zu_case *k = &zu_cases[c];
    int kind = k->kind[0] == 'v' ? 0 : k->kind[0] == 's' ? 1 : 2;
    int64_t o[ZU_NOUT];
    stage_t t;
    int e = 0, rc = evaluate(k, o, &t);
    per_kind_n[kind]++;
    if (rc) {
      out("CASE %d (%s): FAIL (%s)\r\n", c + 1, k->kind, rc == -2 ? "range_err" : "engine timeout");
      bad_cases++; per_kind_bad[kind]++;
      continue;
    }
    for (int i = 0; i < ZU_NOUT; i++)
      if (o[i] != k->want[i]) {
        e++;
        out("  FAIL %-12s got %lld want %lld\r\n", zu_out_name[i], (long long)o[i], (long long)k->want[i]);
      }
    if (e) { bad_cases++; bad_outputs += e; per_kind_bad[kind]++; out("CASE %d (%s): FAIL (%d)\r\n", c + 1, k->kind, e); }
  }
  static const char *kinds[3] = {"single vector", "board sweep", "real NIFTY days"};
  for (int k = 0; k < 3; k++)
    out("%s: %s, %d case(s) x %d outputs bit-exact vs the emulator\r\n", per_kind_bad[k] ? "FAIL" : "PASS", kinds[k],
        per_kind_n[k] - per_kind_bad[k], ZU_NOUT);
  if (bad_cases)
    out("FAIL: %d of %d cases, %d outputs differ\r\n", bad_cases, ZU_NCASES, bad_outputs);
  else
    out("PASS: all %d cases x %d outputs bit-exact (%d of %d)\r\n", ZU_NCASES, ZU_NOUT, ZU_NCASES * ZU_NOUT,
        ZU_NCASES * ZU_NOUT);

  /* 2. timing: every case in turn, REPEAT evaluations */
  stage_t best = {~0ull, ~0ull, ~0ull}, sum = {0, 0, 0};
  uint64_t best_tot = ~0ull, sum_tot = 0;
  for (int r = 0; r < REPEAT; r++) {
    int64_t o[ZU_NOUT];
    stage_t t;
    if (evaluate(&zu_cases[r % ZU_NCASES], o, &t)) { out("TIMING: FAIL\r\n"); goto done; }
#define ACC(f) do { sum.f += t.f; if (t.f < best.f) best.f = t.f; } while (0)
    ACC(write); ACC(engine); ACC(read);
    uint64_t tot = t.write + t.engine + t.read;
    sum_tot += tot;
    if (tot < best_tot) best_tot = tot;
  }
  out("TIMING (ns, best / mean of %d)\r\n", REPEAT);
  out("  write   (19 words, AXI)    %8u %8u\r\n", ns(best.write), ns(sum.write / REPEAT));
  out("  engine  (start .. done)    %8u %8u\r\n", ns(best.engine), ns(sum.engine / REPEAT));
  out("  read    (20 words, AXI)    %8u %8u\r\n", ns(best.read), ns(sum.read / REPEAT));
  out("  END TO END                 %8u %8u\r\n", ns(best_tot), ns(sum_tot / REPEAT));
  {
    unsigned long n = 0;
    uint64_t t0 = NOW();
    while (NOW() - t0 < TICKS_PER_S) {
      int64_t o[ZU_NOUT];
      stage_t t;
      if (evaluate(&zu_cases[n % ZU_NCASES], o, &t)) { out("THROUGHPUT: FAIL\r\n"); goto done; }
      n++;
    }
    uint64_t el = NOW() - t0;
    out("THROUGHPUT: %llu evaluations per second, back to back, one engine\r\n",
        (unsigned long long)(n * TICKS_PER_S / el));
  }

  /* 3. power */
  power();

done:
  out("DONE\r\n");
  LOGB->magic = LOG_DONE;
#ifndef ZU_PC_TEST
  Xil_DCacheFlushRange((INTPTR)LOG_ADDR, (INTPTR)sizeof(logbuf_t));
#endif
  return bad_cases != 0;
}
