"""
AAD Engine — Core package for Algorithmic Adjoint Differentiation.

This package provides a tape-based reverse-mode automatic differentiation
engine. Import the key classes and functions from here:

    from aad_engine import AADVariable, tape, aad_sin, aad_cos, aad_exp, aad_log, aad_sqrt, aad_norm_cdf
"""

from .tape import tape, reset_tape
from .aad_variable import AADVariable
from .operations import (
    aad_sin, aad_cos, aad_exp, aad_log, aad_sqrt, aad_pow,
    aad_abs, aad_norm_cdf, aad_norm_pdf, aad_max
)
