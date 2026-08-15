"""
AADVariable — The main type used for automatic adjoint differentiation.

An AADVariable wraps a floating-point value and records every arithmetic
operation on the global tape so that the reverse sweep can compute all
partial derivatives with respect to every input variable.

Usage
-----
    from aad_engine import AADVariable, tape, reset_tape

    reset_tape()
    x = AADVariable(2.0, name="x")
    y = AADVariable(3.0, name="y")
    f = x * y + aad_sin(x)
    f.backward()
    print(x.adjoint)  # ∂f/∂x
    print(y.adjoint)  # ∂f/∂y
"""

from .tape import tape


class AADVariable:
    """
    A scalar variable tracked by the AAD tape.

    Every arithmetic operation involving AADVariable objects is recorded
    on the global tape, enabling a single backward sweep to recover all
    partial derivatives.
    """

    __slots__ = ("value", "tape_index", "name")

    def __init__(self, value, tape_index=None, name=None):
        """
        Parameters
        ----------
        value : float
            The numeric value of this variable.
        tape_index : int or None
            If None (the default), a new leaf entry is created on the tape.
            Internal use: pass an existing index when creating intermediate
            results that are already recorded.
        name : str or None
            Optional human-readable name for debugging.
        """
        self.value = float(value)
        self.name = name
        if tape_index is not None:
            self.tape_index = tape_index
        else:
            # Record as a leaf (input) variable — no parents
            self.tape_index = tape.record(self.value, [])

    # ------------------------------------------------------------------
    # Adjoint access
    # ------------------------------------------------------------------

    @property
    def adjoint(self):
        """Return the adjoint ∂output/∂(this variable) after backward()."""
        return tape.adjoints[self.tape_index]

    # ------------------------------------------------------------------
    # Backward
    # ------------------------------------------------------------------

    def backward(self):
        """
        Convenience method: run the backward sweep seeded at this variable.
        Equivalent to tape.backward(self.tape_index).
        """
        tape.backward(self.tape_index)

    # ------------------------------------------------------------------
    # Arithmetic operators
    # ------------------------------------------------------------------

    def __add__(self, other):
        if isinstance(other, AADVariable):
            result_value = self.value + other.value
            idx = tape.record(result_value, [
                (self.tape_index, 1.0),
                (other.tape_index, 1.0),
            ])
            return AADVariable(result_value, tape_index=idx)
        else:
            other = float(other)
            result_value = self.value + other
            idx = tape.record(result_value, [
                (self.tape_index, 1.0),
            ])
            return AADVariable(result_value, tape_index=idx)

    def __radd__(self, other):
        return self.__add__(other)

    def __sub__(self, other):
        if isinstance(other, AADVariable):
            result_value = self.value - other.value
            idx = tape.record(result_value, [
                (self.tape_index, 1.0),
                (other.tape_index, -1.0),
            ])
            return AADVariable(result_value, tape_index=idx)
        else:
            other = float(other)
            result_value = self.value - other
            idx = tape.record(result_value, [
                (self.tape_index, 1.0),
            ])
            return AADVariable(result_value, tape_index=idx)

    def __rsub__(self, other):
        other = float(other)
        result_value = other - self.value
        idx = tape.record(result_value, [
            (self.tape_index, -1.0),
        ])
        return AADVariable(result_value, tape_index=idx)

    def __mul__(self, other):
        if isinstance(other, AADVariable):
            result_value = self.value * other.value
            idx = tape.record(result_value, [
                (self.tape_index, other.value),   # ∂(a*b)/∂a = b
                (other.tape_index, self.value),   # ∂(a*b)/∂b = a
            ])
            return AADVariable(result_value, tape_index=idx)
        else:
            other = float(other)
            result_value = self.value * other
            idx = tape.record(result_value, [
                (self.tape_index, other),          # ∂(a*c)/∂a = c
            ])
            return AADVariable(result_value, tape_index=idx)

    def __rmul__(self, other):
        return self.__mul__(other)

    def __truediv__(self, other):
        if isinstance(other, AADVariable):
            result_value = self.value / other.value
            idx = tape.record(result_value, [
                (self.tape_index, 1.0 / other.value),         # ∂(a/b)/∂a = 1/b
                (other.tape_index, -self.value / (other.value ** 2)),  # ∂(a/b)/∂b = -a/b²
            ])
            return AADVariable(result_value, tape_index=idx)
        else:
            other = float(other)
            result_value = self.value / other
            idx = tape.record(result_value, [
                (self.tape_index, 1.0 / other),
            ])
            return AADVariable(result_value, tape_index=idx)

    def __rtruediv__(self, other):
        other = float(other)
        result_value = other / self.value
        idx = tape.record(result_value, [
            (self.tape_index, -other / (self.value ** 2)),  # ∂(c/a)/∂a = -c/a²
        ])
        return AADVariable(result_value, tape_index=idx)

    def __neg__(self):
        result_value = -self.value
        idx = tape.record(result_value, [
            (self.tape_index, -1.0),
        ])
        return AADVariable(result_value, tape_index=idx)

    def __pos__(self):
        return self

    def __pow__(self, other):
        """Handles a**b where a is AADVariable, b is scalar or AADVariable."""
        if isinstance(other, AADVariable):
            # a^b: ∂/∂a = b*a^(b-1), ∂/∂b = a^b * ln(a)
            import math
            result_value = self.value ** other.value
            idx = tape.record(result_value, [
                (self.tape_index, other.value * (self.value ** (other.value - 1.0))),
                (other.tape_index, result_value * math.log(self.value) if self.value > 0 else 0.0),
            ])
            return AADVariable(result_value, tape_index=idx)
        else:
            other = float(other)
            result_value = self.value ** other
            idx = tape.record(result_value, [
                (self.tape_index, other * (self.value ** (other - 1.0))),
            ])
            return AADVariable(result_value, tape_index=idx)

    def __rpow__(self, other):
        """Handles c**a where c is scalar, a is AADVariable."""
        import math
        other = float(other)
        result_value = other ** self.value
        partial = result_value * math.log(other) if other > 0 else 0.0
        idx = tape.record(result_value, [
            (self.tape_index, partial),  # ∂(c^a)/∂a = c^a * ln(c)
        ])
        return AADVariable(result_value, tape_index=idx)

    # ------------------------------------------------------------------
    # Comparison (based on value only, no tape recording)
    # ------------------------------------------------------------------

    def __lt__(self, other):
        if isinstance(other, AADVariable):
            return self.value < other.value
        return self.value < float(other)

    def __le__(self, other):
        if isinstance(other, AADVariable):
            return self.value <= other.value
        return self.value <= float(other)

    def __gt__(self, other):
        if isinstance(other, AADVariable):
            return self.value > other.value
        return self.value > float(other)

    def __ge__(self, other):
        if isinstance(other, AADVariable):
            return self.value >= other.value
        return self.value >= float(other)

    def __eq__(self, other):
        if isinstance(other, AADVariable):
            return self.value == other.value
        return self.value == float(other)

    # ------------------------------------------------------------------
    # Conversion
    # ------------------------------------------------------------------

    def __float__(self):
        return self.value

    def __repr__(self):
        name_str = f" ({self.name})" if self.name else ""
        return f"AADVariable(value={self.value:.6g}, idx={self.tape_index}{name_str})"
