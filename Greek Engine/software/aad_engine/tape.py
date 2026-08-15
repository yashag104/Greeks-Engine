"""
Tape — Global recording structure for AAD operations.

The tape records every elementary operation performed during the forward pass.
Each entry stores the indices of the input variables and the local partial
derivatives evaluated at the current values.  The backward sweep processes
entries in reverse order to accumulate adjoints.

Architecture
------------
- values[i]   : the floating-point value of variable i
- adjoints[i] : the accumulated adjoint ∂f/∂v_i (initialized to 0)
- entries[i]  : list of (parent_index, local_partial) tuples that contributed
                to producing variable i

Usage
-----
    from aad_engine.tape import tape, reset_tape

    reset_tape()                         # clear before a new computation
    idx = tape.record(value, parents)    # record a new variable
    tape.backward(output_idx)            # reverse sweep from output
    grad = tape.adjoints[input_idx]      # read the gradient
"""


class Tape:
    """
    A Wengert list (tape) for reverse-mode automatic differentiation.

    The tape is a flat list of recorded operations.  Each slot corresponds
    to one intermediate variable produced during the forward evaluation.
    """

    def __init__(self):
        self.values = []       # values[i] = float value of variable i
        self.adjoints = []     # adjoints[i] = accumulated ∂output/∂v_i
        self.entries = []      # entries[i] = [(parent_idx, local_partial), ...]
        self._locked = False   # True after backward() to prevent further recording

    # ------------------------------------------------------------------
    # Recording
    # ------------------------------------------------------------------

    def record(self, value, parents_and_partials):
        """
        Record a new variable on the tape.

        Parameters
        ----------
        value : float
            The value produced by the forward operation.
        parents_and_partials : list of (int, float)
            Each element is (parent_tape_index, ∂this_value/∂parent_value).
            For leaf (input) variables, pass an empty list [].

        Returns
        -------
        int
            The tape index assigned to this variable.
        """
        if self._locked:
            raise RuntimeError(
                "Tape is locked after backward(). Call reset_tape() before a new computation."
            )
        idx = len(self.values)
        self.values.append(float(value))
        self.adjoints.append(0.0)
        self.entries.append(list(parents_and_partials))
        return idx

    # ------------------------------------------------------------------
    # Backward sweep
    # ------------------------------------------------------------------

    def backward(self, output_index):
        """
        Perform the reverse-mode adjoint sweep.

        Seeds the output adjoint to 1.0 and propagates backward through
        every tape entry, accumulating ∂output/∂v_i for all i.

        Parameters
        ----------
        output_index : int
            Tape index of the output variable (the function value whose
            derivatives we want).
        """
        # Seed
        self.adjoints[output_index] = 1.0

        # Reverse sweep
        for i in range(output_index, -1, -1):
            adj_i = self.adjoints[i]
            if adj_i == 0.0:
                continue
            for parent_idx, local_partial in self.entries[i]:
                self.adjoints[parent_idx] += adj_i * local_partial

        self._locked = True

    # ------------------------------------------------------------------
    # Utilities
    # ------------------------------------------------------------------

    def reset(self):
        """Clear all recorded data and unlock the tape."""
        self.values.clear()
        self.adjoints.clear()
        self.entries.clear()
        self._locked = False

    def __len__(self):
        return len(self.values)

    def __repr__(self):
        return f"Tape(size={len(self)}, locked={self._locked})"

    def dump(self, max_entries=50):
        """Return a human-readable dump of the tape for debugging."""
        lines = [f"Tape dump ({len(self)} entries, locked={self._locked}):"]
        for i in range(min(len(self), max_entries)):
            parents_str = ", ".join(
                f"v{pi}×{pp:.6g}" for pi, pp in self.entries[i]
            )
            lines.append(
                f"  v{i} = {self.values[i]:.6g}  adj={self.adjoints[i]:.6g}"
                f"  parents=[{parents_str}]"
            )
        if len(self) > max_entries:
            lines.append(f"  ... ({len(self) - max_entries} more entries)")
        return "\n".join(lines)


# ======================================================================
# Global tape instance
# ======================================================================

tape = Tape()


def reset_tape():
    """Reset the global tape.  Call this before every new computation."""
    tape.reset()
