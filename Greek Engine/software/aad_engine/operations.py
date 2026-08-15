"""
AAD Operations — Transcendental and special functions for AADVariable.

Each function evaluates the forward value and records the operation
(with its local partial derivative) on the global tape.

Functions
---------
aad_sin, aad_cos, aad_exp, aad_log, aad_sqrt, aad_pow, aad_abs,
aad_norm_cdf, aad_norm_pdf, aad_max
"""

import math
from .tape import tape
from .aad_variable import AADVariable

# ======================================================================
# Standard math functions
# ======================================================================


def aad_sin(x):
    """sin(x) with AAD tracking.  ∂sin/∂x = cos(x)."""
    if not isinstance(x, AADVariable):
        return math.sin(x)
    result_value = math.sin(x.value)
    idx = tape.record(result_value, [
        (x.tape_index, math.cos(x.value)),
    ])
    return AADVariable(result_value, tape_index=idx)


def aad_cos(x):
    """cos(x) with AAD tracking.  ∂cos/∂x = −sin(x)."""
    if not isinstance(x, AADVariable):
        return math.cos(x)
    result_value = math.cos(x.value)
    idx = tape.record(result_value, [
        (x.tape_index, -math.sin(x.value)),
    ])
    return AADVariable(result_value, tape_index=idx)


def aad_exp(x):
    """exp(x) with AAD tracking.  ∂exp/∂x = exp(x)."""
    if not isinstance(x, AADVariable):
        return math.exp(x)
    result_value = math.exp(x.value)
    idx = tape.record(result_value, [
        (x.tape_index, result_value),  # ∂exp(x)/∂x = exp(x)
    ])
    return AADVariable(result_value, tape_index=idx)


def aad_log(x):
    """ln(x) with AAD tracking.  ∂ln/∂x = 1/x."""
    if not isinstance(x, AADVariable):
        return math.log(x)
    result_value = math.log(x.value)
    idx = tape.record(result_value, [
        (x.tape_index, 1.0 / x.value),
    ])
    return AADVariable(result_value, tape_index=idx)


def aad_sqrt(x):
    """sqrt(x) with AAD tracking.  ∂sqrt/∂x = 1/(2√x)."""
    if not isinstance(x, AADVariable):
        return math.sqrt(x)
    result_value = math.sqrt(x.value)
    idx = tape.record(result_value, [
        (x.tape_index, 0.5 / result_value),
    ])
    return AADVariable(result_value, tape_index=idx)


def aad_pow(base, exponent):
    """
    base^exponent with AAD tracking.

    Delegates to AADVariable.__pow__ / __rpow__ for mixed types.
    """
    if isinstance(base, AADVariable):
        return base ** exponent
    elif isinstance(exponent, AADVariable):
        return float(base) ** exponent
    else:
        return float(base) ** float(exponent)


def aad_abs(x):
    """
    |x| with AAD tracking.  ∂|x|/∂x = sign(x).

    Note: not differentiable at x = 0; we define ∂|0|/∂x = 0.
    """
    if not isinstance(x, AADVariable):
        return abs(x)
    result_value = abs(x.value)
    sign = 1.0 if x.value > 0 else (-1.0 if x.value < 0 else 0.0)
    idx = tape.record(result_value, [
        (x.tape_index, sign),
    ])
    return AADVariable(result_value, tape_index=idx)


# ======================================================================
# Statistical functions (Normal distribution)
# ======================================================================

_SQRT_2PI = math.sqrt(2.0 * math.pi)
_SQRT_2 = math.sqrt(2.0)


def _norm_pdf_value(x):
    """Standard normal PDF evaluated at x (plain float)."""
    return math.exp(-0.5 * x * x) / _SQRT_2PI


def _norm_cdf_value(x):
    """Standard normal CDF evaluated at x (plain float)."""
    return 0.5 * (1.0 + math.erf(x / _SQRT_2))


def aad_norm_pdf(x):
    """
    Standard normal PDF  n(x) = (1/√2π) exp(−x²/2)  with AAD tracking.

    ∂n/∂x = −x · n(x)
    """
    if not isinstance(x, AADVariable):
        return _norm_pdf_value(x)
    pdf_val = _norm_pdf_value(x.value)
    idx = tape.record(pdf_val, [
        (x.tape_index, -x.value * pdf_val),  # ∂n(x)/∂x = -x·n(x)
    ])
    return AADVariable(pdf_val, tape_index=idx)


def aad_norm_cdf(x):
    """
    Standard normal CDF  N(x) = ∫_{-∞}^{x} n(t) dt  with AAD tracking.

    ∂N/∂x = n(x)  (the PDF)

    This is registered as a primitive operation with a known derivative,
    rather than being decomposed into elementary ops.  This is the standard
    AAD approach for library functions whose derivative is known analytically.
    """
    if not isinstance(x, AADVariable):
        return _norm_cdf_value(x)
    cdf_val = _norm_cdf_value(x.value)
    pdf_val = _norm_pdf_value(x.value)  # N'(x) = n(x)
    idx = tape.record(cdf_val, [
        (x.tape_index, pdf_val),
    ])
    return AADVariable(cdf_val, tape_index=idx)


def aad_max(a, b):
    """
    max(a, b) with AAD tracking.

    ∂max/∂a = 1 if a > b else 0
    ∂max/∂b = 1 if b > a else 0
    At a == b, we assign gradient 0.5 to each (sub-gradient convention).

    Note: This introduces a discontinuity in the derivative — acceptable
    for payoff functions but should be avoided in smooth pricing formulas.
    """
    a_is_aad = isinstance(a, AADVariable)
    b_is_aad = isinstance(b, AADVariable)
    a_val = a.value if a_is_aad else float(a)
    b_val = b.value if b_is_aad else float(b)

    result_value = max(a_val, b_val)

    parents = []
    if a_val > b_val:
        if a_is_aad:
            parents.append((a.tape_index, 1.0))
        if b_is_aad:
            parents.append((b.tape_index, 0.0))
    elif b_val > a_val:
        if a_is_aad:
            parents.append((a.tape_index, 0.0))
        if b_is_aad:
            parents.append((b.tape_index, 1.0))
    else:
        # a == b: sub-gradient
        if a_is_aad:
            parents.append((a.tape_index, 0.5))
        if b_is_aad:
            parents.append((b.tape_index, 0.5))

    idx = tape.record(result_value, parents)
    return AADVariable(result_value, tape_index=idx)


# ======================================================================
# Complex-number support for Heston characteristic function
# ======================================================================
# The Heston characteristic function involves complex arithmetic.
# We provide AAD-tracked complex operations that treat real and imaginary
# parts as separate AAD variables.


class AADComplex:
    """
    A complex number where both real and imaginary parts are AADVariables.

    This allows the COS method (which evaluates a complex-valued
    characteristic function) to be fully tracked on the AAD tape.
    """

    __slots__ = ("real", "imag")

    def __init__(self, real, imag=None):
        """
        Parameters
        ----------
        real : AADVariable or float
        imag : AADVariable or float or None
            If None, imaginary part is 0.
        """
        if not isinstance(real, AADVariable):
            real = AADVariable(float(real))
        if imag is None:
            imag = AADVariable(0.0)
        elif not isinstance(imag, AADVariable):
            imag = AADVariable(float(imag))
        self.real = real
        self.imag = imag

    def __add__(self, other):
        if isinstance(other, AADComplex):
            return AADComplex(self.real + other.real, self.imag + other.imag)
        elif isinstance(other, AADVariable):
            return AADComplex(self.real + other, self.imag)
        else:
            return AADComplex(self.real + float(other), self.imag)

    def __radd__(self, other):
        return self.__add__(other)

    def __sub__(self, other):
        if isinstance(other, AADComplex):
            return AADComplex(self.real - other.real, self.imag - other.imag)
        elif isinstance(other, AADVariable):
            return AADComplex(self.real - other, self.imag)
        else:
            return AADComplex(self.real - float(other), self.imag)

    def __rsub__(self, other):
        if isinstance(other, AADComplex):
            return AADComplex(other.real - self.real, other.imag - self.imag)
        elif isinstance(other, AADVariable):
            return AADComplex(other - self.real, -self.imag)
        else:
            return AADComplex(float(other) - self.real, -self.imag)

    def __mul__(self, other):
        """(a+bi)(c+di) = (ac-bd) + (ad+bc)i"""
        if isinstance(other, AADComplex):
            real_part = self.real * other.real - self.imag * other.imag
            imag_part = self.real * other.imag + self.imag * other.real
            return AADComplex(real_part, imag_part)
        elif isinstance(other, AADVariable):
            return AADComplex(self.real * other, self.imag * other)
        else:
            c = float(other)
            return AADComplex(self.real * c, self.imag * c)

    def __rmul__(self, other):
        return self.__mul__(other)

    def __truediv__(self, other):
        """(a+bi)/(c+di) = ((ac+bd) + (bc-ad)i) / (c²+d²)"""
        if isinstance(other, AADComplex):
            denom = other.real * other.real + other.imag * other.imag
            real_part = (self.real * other.real + self.imag * other.imag) / denom
            imag_part = (self.imag * other.real - self.real * other.imag) / denom
            return AADComplex(real_part, imag_part)
        elif isinstance(other, AADVariable):
            return AADComplex(self.real / other, self.imag / other)
        else:
            c = float(other)
            return AADComplex(self.real / c, self.imag / c)

    def __neg__(self):
        return AADComplex(-self.real, -self.imag)

    def __repr__(self):
        return f"AADComplex(real={self.real}, imag={self.imag})"


def aad_complex_exp(z):
    """
    exp(a + bi) = exp(a) * (cos(b) + i*sin(b))

    Both parts tracked on the AAD tape.
    """
    if not isinstance(z, AADComplex):
        import cmath
        result = cmath.exp(z)
        return AADComplex(AADVariable(result.real), AADVariable(result.imag))

    exp_a = aad_exp(z.real)
    cos_b = aad_cos(z.imag)
    sin_b = aad_sin(z.imag)
    return AADComplex(exp_a * cos_b, exp_a * sin_b)


def aad_complex_log(z):
    """
    log(a + bi) = 0.5*ln(a²+b²) + i*atan2(b, a)

    Both parts tracked on the AAD tape.
    """
    # magnitude squared
    mag_sq = z.real * z.real + z.imag * z.imag
    half_log_mag = aad_log(mag_sq) * 0.5

    # angle = atan2(b, a) — register as primitive
    angle_val = math.atan2(z.imag.value, z.real.value)
    denom = z.real.value ** 2 + z.imag.value ** 2
    if denom < 1e-300:
        denom = 1e-300
    # ∂atan2(b,a)/∂a = -b/(a²+b²), ∂atan2(b,a)/∂b = a/(a²+b²)
    d_angle_d_real = -z.imag.value / denom
    d_angle_d_imag = z.real.value / denom
    angle_idx = tape.record(angle_val, [
        (z.real.tape_index, d_angle_d_real),
        (z.imag.tape_index, d_angle_d_imag),
    ])
    angle = AADVariable(angle_val, tape_index=angle_idx)

    return AADComplex(half_log_mag, angle)


def aad_complex_sqrt(z):
    """
    sqrt(a + bi) via the principal square root.

    sqrt(z) = sqrt(|z|) * (cos(θ/2) + i*sin(θ/2))
    where |z| = sqrt(a²+b²), θ = atan2(b, a)
    """
    mag_sq = z.real * z.real + z.imag * z.imag
    mag = aad_sqrt(mag_sq)
    sqrt_mag = aad_sqrt(mag)

    # angle / 2
    angle_val = math.atan2(z.imag.value, z.real.value)
    denom = z.real.value ** 2 + z.imag.value ** 2
    if denom < 1e-300:
        denom = 1e-300
    d_angle_d_real = -z.imag.value / denom
    d_angle_d_imag = z.real.value / denom
    angle_idx = tape.record(angle_val, [
        (z.real.tape_index, d_angle_d_real),
        (z.imag.tape_index, d_angle_d_imag),
    ])
    angle = AADVariable(angle_val, tape_index=angle_idx)
    half_angle = angle * 0.5

    cos_ha = aad_cos(half_angle)
    sin_ha = aad_sin(half_angle)

    return AADComplex(sqrt_mag * cos_ha, sqrt_mag * sin_ha)
