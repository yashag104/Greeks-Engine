"""Generate Q4.60 fixed-point constant literals for the RTL arithmetic library.

Every constant the RTL needs (ln2, pi, 1/n!, CORDIC atan table, log LUT, ...)
is emitted as a signed 64-bit literal with 60 fractional bits, computed in
120-digit decimal arithmetic, so that each module can round it down to its
own FL (see the q60() function in each module) with an error of at most
half an ULP -- instead of the previous $rtoi(x * 2**16) <<< (FL-16) pattern,
which silently truncated every constant to 16 fractional bits.

Usage: python gen_constants.py   (prints Verilog snippets to stdout)
"""
from decimal import Decimal, getcontext

getcontext().prec = 120
ONE = Decimal(1)
SCALE = Decimal(2) ** 60


def pi():
    # Machin: pi = 16 atan(1/5) - 4 atan(1/239)
    return 16 * atan_small(ONE / 5) - 4 * atan_small(ONE / 239)


def atan_small(x):
    s, term, n, x2 = Decimal(0), x, 1, x * x
    while abs(term) > Decimal(10) ** -110:
        s += term / n if (n // 2) % 2 == 0 else -term / n
        term *= x2
        n += 2
    return s


def atan(x):
    # reduce |x| <= 1 via atan(x) = 2 atan(x / (1 + sqrt(1 + x^2)))
    if x > Decimal("0.2"):
        return 2 * atan(x / (1 + (1 + x * x).sqrt()))
    return atan_small(x)


def lit(v):
    q = int((v * SCALE).to_integral_value())
    assert -(1 << 63) <= q < (1 << 63), v
    return "64'sh%016X" % (q & ((1 << 64) - 1)) if q >= 0 else "-64'sh%016X" % (-q)


def fact(n):
    f = 1
    for i in range(2, n + 1):
        f *= i
    return f


PI = pi()
LN2 = Decimal(2).ln()
consts = {
    "LN2": LN2, "INV_LN2": 1 / LN2, "PI": PI, "TWO_PI": 2 * PI, "HALF_PI": PI / 2,
    "INV_2PI": 1 / (2 * PI),
}
# CORDIC gain 1/K = prod 1/sqrt(1 + 2^-2i), i = 0..63 (converged far below 2^-60)
k = ONE
for i in range(64):
    k *= 1 / (1 + Decimal(4) ** -i).sqrt()
consts["CORDIC_INV_K"] = k

if __name__ == "__main__":
    for name, v in consts.items():
        print("localparam signed [63:0] C_%s = %s; // %s" % (name, lit(v), str(v)[:22]))
    print("\n// 1/n!  n = 0..15")
    for n in range(16):
        print("            4'd%d: inv_fact = %s;" % (n, lit(ONE / fact(n))))
    print("\n// atan(2^-i)  i = 0..63")
    for i in range(64):
        print("            6'd%d: atan_q60 = %s;" % (i, lit(atan(Decimal(2) ** -i))))
    print("\n// log LUT: c_j = 1 + (2j+1)/32 ; 1/c_j and ln(c_j)")
    for j in range(16):
        c = 1 + Decimal(2 * j + 1) / 32
        print("            4'd%d: begin inv_c = %s; ln_c = %s; end" % (j, lit(1 / c), lit(c.ln())))
    print("\n// ln(1+t) Horner coefficients (-1)^(n+1)/n, n = 1..15")
    for n in range(1, 16):
        print("            4'd%d: log_coef = %s;" % (n, lit(Decimal((-1) ** (n + 1)) / n)))
