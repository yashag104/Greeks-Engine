"""Host-side reference for host_setup designs (e.g. heston_aad_z7h on a Zynq).

The FPGA runs the 128-term forward + reverse AAD loop; the host (the Zynq's
ARM cores) computes the per-evaluation constants before starting it and the
discounting / final chain rule after it. These functions are the bit-exact
specification of both host steps, in the same fixed-point arithmetic as the
datapath (heston.py), so host + FPGA reproduces the fully on-chip design's
outputs exactly (checked by `python host.py`).

    ports = setup_ports(dp, gen, params, is_call)     # -> {hs_<id>: int}
    outs  = finish(dp, params, is_call, sums)          # sums: {name: int} from sum_* ports
"""
import heston as H


def setup_ports(dp, gen, params, is_call):
    q = H.quantize_inputs(params, is_call, dp.g.fl)
    vals = dp.g.eval_fixed(q, part="setup")
    return {port: int(vals[nid]) for nid, port in gen.host_inputs.items()}


def finish(dp, params, is_call, sums):
    q = H.quantize_inputs(params, is_call, dp.g.fl)
    vals = dp.g.eval_fixed(q, part="setup")
    fin = list(vals)
    dp.g.eval_fixed(dict(q, **{"acc_" + a: sums[a] for a in dp.acc_names}), values=fin, part="finish")
    return {o: fin[dp.finish[o]] for o in dp.outputs}


if __name__ == "__main__":
    from rtlgen import Gen
    from sched import Config
    cfg = Config(wl=56, fl=28, mults=8, crot=3, cvec=2, cordic_pipelined=False, host_setup=True)
    dp = H.Datapath(56, 28)
    gen = Gen(dp, cfg, "heston_aad_z7h")
    gen.emit()
    ok = True
    for p, call in ([100, 100, 1, .05, .04, 1.5, .04, .3, -.9], True), ([100, 110, .25, 0, .0175, 1.5768, .0398, .5751, -.5711], False):
        q = H.quantize_inputs(p, call, 28)
        full, tr = H.emulate(dp, q)                 # fully on-chip design
        ports = setup_ports(dp, gen, p, call)       # host step 1
        split = finish(dp, p, call, tr["acc"])      # FPGA loop sums -> host step 2
        ok &= (full == split) and all(ports[pt] == tr["setup"][nid] for nid, pt in gen.host_inputs.items())
        print("case", p, "host+FPGA == on-chip:", full == split, " price %.8f" % (split["price"] / 2 ** 28))
    print("PASS" if ok else "FAIL")
