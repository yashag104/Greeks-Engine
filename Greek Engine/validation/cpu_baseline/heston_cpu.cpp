// CPU baseline for the Greeks Engine: the same Heston-COS algorithm as the
// hardware (N = 128 terms, little-trap characteristic function, puts with calls
// by put-call parity, truncation range [a, b] frozen when differentiating), in
// double precision, with the price and 9 sensitivities computed four ways:
//
//   price     one pricing, no Greeks
//   bump      central finite differences, 19 pricings
//   aad       reverse mode with CoDiPack (RealReverse, a taped AD tool)
//   fwdvec    forward mode with CoDiPack, all 9 directions in one pass
//
//   ./heston_cpu check            base case: price and Greeks for each method
//   ./heston_cpu time  <n>        n timed evaluations per method, one thread
//   ./heston_cpu run   <method> <n>   n evaluations of one method (for the
//                                     multi-process throughput measurement)
//
// Build: see run_baseline.py (g++ -O3 -march=native, CoDiPack v2.3.2).
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>

#include <codi.hpp>

static const double PI = 3.14159265358979323846;
static const int N_TERMS = 128;

// ---- a minimal complex type over any real type R (double or a CoDiPack type).
// std::complex<T> is only specified for float/double/long double.
template <class R> struct Cx { R re, im; };
template <class R> static inline Cx<R> operator+(const Cx<R>& a, const Cx<R>& b) { return {a.re + b.re, a.im + b.im}; }
template <class R> static inline Cx<R> operator-(const Cx<R>& a, const Cx<R>& b) { return {a.re - b.re, a.im - b.im}; }
template <class R> static inline Cx<R> operator*(const Cx<R>& a, const Cx<R>& b) {
  return {a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re};
}
template <class T> struct NoDeduce { using type = T; };   // lets CoDiPack expressions convert to R
template <class R> static inline Cx<R> scal(const typename NoDeduce<R>::type& s, const Cx<R>& a) {
  return {s * a.re, s * a.im};
}
template <class R> static inline Cx<R> operator/(const Cx<R>& a, const Cx<R>& b) {
  R n = b.re * b.re + b.im * b.im;
  return {(a.re * b.re + a.im * b.im) / n, (a.im * b.re - a.re * b.im) / n};
}
template <class R> static inline Cx<R> cexp_(const Cx<R>& z) { R m = exp(z.re); return {m * cos(z.im), m * sin(z.im)}; }
template <class R> static inline Cx<R> clog_(const Cx<R>& z) { return {0.5 * log(z.re * z.re + z.im * z.im), atan2(z.im, z.re)}; }
template <class R> static inline double pv(const R& x) { return codi::RealTraits::getPassiveValue(x); }
template <class R> static inline Cx<R> csqrt_(const Cx<R>& z) {       // principal branch, as numpy
  R r = sqrt(z.re * z.re + z.im * z.im);
  if (pv(z.re) >= 0) { R w = sqrt(0.5 * (r + z.re)); return {w, z.im / (2.0 * w)}; }
  R w = sqrt(0.5 * (r - z.re));                                        // = |Im sqrt|
  R s = pv(z.im) >= 0 ? R(1.0) : R(-1.0);
  return {z.im / (2.0 * s * w), s * w};
}

// ---- Heston characteristic function of ln(S_T/K), "little trap" form
// (identical to validation/reference/heston_reference.py::char_func)
template <class R>
static Cx<R> char_func(double u, const R& T, const R& r, const R& v0, const R& kappa, const R& theta,
                       const R& xi, const R& rho, const R& x) {
  Cx<R> iu{R(0.0), R(u)};
  Cx<R> bb{kappa, -rho * xi * u};
  R xi2 = xi * xi;
  Cx<R> d = csqrt_(bb * bb + scal(xi2, Cx<R>{R(u * u), R(u)}));
  Cx<R> g = (bb - d) / (bb + d);
  Cx<R> e = cexp_(scal(R(-1.0) * T, d));
  Cx<R> one{R(1.0), R(0.0)};
  Cx<R> ge = g * e;
  Cx<R> C = scal(r * T, iu) +
            scal(kappa * theta / xi2, scal(T, bb - d) - scal(R(2.0), clog_((one - ge) / (one - g))));
  Cx<R> D = scal(R(1.0) / xi2, (bb - d) * ((one - e) / (one - ge)));
  return cexp_(C + scal(v0, D) + scal(x, iu));
}

// cumulant truncation range, evaluated passively (frozen when differentiating)
static void trunc_range(const double* p, double& a, double& b) {
  double S0 = p[0], K = p[1], T = p[2], r = p[3], v0 = p[4], kappa = p[5], theta = p[6];
  double x = std::log(S0 / K);
  double c1 = x + (r - 0.5 * theta) * T + (1.0 - std::exp(-kappa * T)) / (2.0 * kappa) * (theta - v0);
  double c2 = std::max(v0 * T + 0.5 * theta * T, 1e-8);
  a = c1 - 10.0 * std::sqrt(c2);
  b = c1 + 10.0 * std::sqrt(c2);
}

// COS price; put payoff, call by parity (the hardware's algorithm)
template <class R> static R cos_price(const R* p, bool call, double a, double b) {
  const R &S0 = p[0], &K = p[1], &T = p[2], &r = p[3], &v0 = p[4], &kappa = p[5], &theta = p[6], &xi = p[7], &rho = p[8];
  R x = log(S0 / K);
  R sum = 0.0;
  const double bma = b - a, ea = std::exp(a);
  for (int k = 0; k < N_TERMS; ++k) {
    double u = k * PI / bma, cu = std::cos(u * a), su = std::sin(u * a);
    Cx<R> phi = char_func(u, T, r, v0, kappa, theta, xi, rho, x);
    R F = phi.re * cu + phi.im * su;                          // Re[phi e^{-iua}]
    double chi = (cu - ea - u * su) / (1.0 + u * u);          // put on [a, 0]
    double psi = (k == 0) ? -a : -(bma / (k * PI)) * su;
    R Vk = (2.0 / bma) * K * (psi - chi);
    sum += (k == 0 ? 0.5 : 1.0) * F * Vk;
  }
  R disc = exp(-r * T);
  R price = disc * sum;
  if (call) price += S0 - K * disc;
  return price;
}

// ---- the four methods; each fills out[10] = price, dV/dp[0..8]
static void m_price(const double* p, bool call, double* out) {
  double a, b; trunc_range(p, a, b);
  out[0] = cos_price(p, call, a, b);
}

static void m_bump(const double* p, bool call, double* out) {
  double a, b; trunc_range(p, a, b);
  out[0] = cos_price(p, call, a, b);
  for (int i = 0; i < 9; ++i) {
    double q[9]; std::memcpy(q, p, sizeof q);
    double h = 1e-5 * std::max(std::fabs(p[i]), 1e-2);
    q[i] = p[i] + h; double up = cos_price(q, call, a, b);
    q[i] = p[i] - h; double dn = cos_price(q, call, a, b);
    out[1 + i] = (up - dn) / (2 * h);
  }
}

using RR = codi::RealReverse;
static void m_aad(const double* p, bool call, double* out) {
  double a, b; trunc_range(p, a, b);
  RR::Tape& tape = RR::getTape();
  tape.setActive();
  RR q[9];
  for (int i = 0; i < 9; ++i) { q[i] = p[i]; tape.registerInput(q[i]); }
  RR v = cos_price(q, call, a, b);
  tape.registerOutput(v);
  tape.setPassive();
  v.setGradient(1.0);
  tape.evaluate();
  out[0] = v.getValue();
  for (int i = 0; i < 9; ++i) out[1 + i] = q[i].getGradient();
  tape.reset();
}

using FV = codi::RealForwardVec<9>;
static void m_fwdvec(const double* p, bool call, double* out) {
  double a, b; trunc_range(p, a, b);
  FV q[9];
  for (int i = 0; i < 9; ++i) { q[i] = p[i]; q[i].gradient()[i] = 1.0; }
  FV v = cos_price(q, call, a, b);
  out[0] = v.getValue();
  for (int i = 0; i < 9; ++i) out[1 + i] = v.getGradient()[i];
}

typedef void (*Method)(const double*, bool, double*);
static Method pick(const char* m) {
  if (!std::strcmp(m, "price")) return m_price;
  if (!std::strcmp(m, "bump")) return m_bump;
  if (!std::strcmp(m, "aad")) return m_aad;
  if (!std::strcmp(m, "fwdvec")) return m_fwdvec;
  std::fprintf(stderr, "unknown method %s\n", m); std::exit(2);
}

// deterministic in-domain inputs, so every method times the same work
static void make_inputs(int n, std::vector<double>& P, std::vector<char>& call) {
  P.resize(9 * n); call.resize(n);
  unsigned s = 12345;
  auto U = [&](double lo, double hi) { s = s * 1664525u + 1013904223u; return lo + (hi - lo) * (s >> 8) / double(1u << 24); };
  for (int i = 0; i < n; ++i) {
    double* q = &P[9 * i];
    q[0] = 100; q[1] = U(60, 150); q[2] = U(0.1, 3); q[3] = U(0, 0.1); q[4] = U(0.005, 0.25);
    q[5] = U(0.2, 6); q[6] = U(0.005, 0.25); q[7] = U(0.1, 1); q[8] = U(-0.95, 0.6);
    call[i] = U(0, 1) < 0.5;
  }
}

int main(int argc, char** argv) {
  const char* mode = argc > 1 ? argv[1] : "check";
  const char* names[4] = {"price", "bump", "aad", "fwdvec"};
  if (!std::strcmp(mode, "check")) {
    double base[9] = {100, 100, 1, 0.05, 0.04, 1.5, 0.04, 0.3, -0.9};
    for (const char* m : names) {
      double out[10] = {0};
      pick(m)(base, true, out);
      std::printf("%s", m);
      for (int i = 0; i < 10; ++i) std::printf(" %.12e", out[i]);
      std::printf("\n");
    }
    return 0;
  }
  if (!std::strcmp(mode, "time")) {
    int n = argc > 2 ? std::atoi(argv[2]) : 2000;
    std::vector<double> P; std::vector<char> C; make_inputs(n, P, C);
    for (const char* m : names) {
      Method f = pick(m);
      double out[10], sink = 0, best = 1e30;
      for (int rep = 0; rep < 5; ++rep) {                 // best of 5 passes over n inputs
        auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < n; ++i) { f(&P[9 * i], C[i], out); sink += out[0] + out[1]; }
        double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count() / n;
        best = std::min(best, us);
      }
      std::printf("%s %.3f us_per_eval (sink %.3g)\n", m, best, sink);
    }
    return 0;
  }
  if (!std::strcmp(mode, "run")) {
    Method f = pick(argv[2]);
    int n = std::atoi(argv[3]);
    std::vector<double> P; std::vector<char> C; make_inputs(n, P, C);
    double out[10], sink = 0;
    for (int i = 0; i < n; ++i) { f(&P[9 * i], C[i], out); sink += out[0]; }
    std::printf("%.6g\n", sink);
    return 0;
  }
  return 2;
}
