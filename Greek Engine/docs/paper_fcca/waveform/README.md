Behavioural-simulation waveform (paper Fig. "wave").

    iverilog -g2012 -o sim tb.v ../../../hardware/verilog/gen/heston_aad_zu.v && vvp -n sim   # errors=0
    ../../../.venv/bin/python plotwave.py . ../figures/fig_wave.png

tb.v drives the generated 64-bit ZCU102 engine with two cases back to back (inputs quantised by
heston.quantize_inputs) and checks all ten outputs of each case bit for bit against heston.emulate.
Its $dumpfile path points at the directory where it was generated; edit it before re-running.
