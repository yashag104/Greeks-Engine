"""Verilog generator: scheduled Heston datapath -> synthesizable RTL.

    python rtlgen.py --wl 56 --fl 28 --mults 8 --crot 3 --cvec 2 --iter-cordic \
                     --out ../verilog/gen/heston_aad_z7.v

Structure of the generated module (Verilog-2005):
  * t        cycle counter from start; phases setup [0,S), term [S,TF),
             finish [TF, TF+F)
  * ph       term phase = (t - S) mod II; term k starts at S + k*II
  * v<id>    one register per glue node, written when its operation runs
             (setup/finish: t == start; term: ph == start mod II)
  * v<id>_s<j>  storage chain for term values consumed >= II cycles later
  * mu<u>_*  shared multiplier u: operand select by (phase, t) table ->
             A/B reg -> product reg -> negate reg -> rounding shift reg
             (latency 4, one new operation per cycle)
  * cr<u>, cv<u>  CORDIC rotation / vectoring units (iterative or pipelined)
  * acc_*    accumulators, enabled only for valid terms 0..N-1
All constants and ROM contents are emitted as integers computed by the same
Python code the emulator uses, so emulator and RTL agree bit for bit.
"""
import argparse
import math
import os

import heston as H
from ir import ATAN_DEC, CORDIC_INVK_DEC, PI_DEC, RESOURCE_OPS, round_half_up
from sched import Config, schedule


def lit(v, w):
    v = int(v)
    return "(-%d'sd%d)" % (w, -v) if v < 0 else "%d'sd%d" % (w, v)


class Gen:
    def __init__(self, dp, cfg, name):
        self.dp, self.cfg, self.name = dp, cfg, name
        self.g = dp.g
        self.sch = schedule(dp, cfg)
        self.W = cfg.wl
        self.D = 2 * cfg.wl
        s = self.sch
        self.S = s.length["setup"]
        self.II = s.ii
        self.L = s.length["term"]
        self.NT = cfg.n_terms
        self.TF = self.S + (self.NT - 1) * self.II + self.L
        self.F = s.length["finish"]
        self.lines = []
        self.roms = {}
        # consumers (for storage chains)
        self.last_use = {}
        for n in self.g.nodes:
            for a in n.args:
                self.last_use[a] = max(self.last_use.get(a, -1), s.start.get(n.id, 0))
        for o in dp.term.values():                      # accumulator reads
            self.last_use[o] = max(self.last_use.get(o, -1), s.ready[o])
        for o in dp.finish.values():                    # module outputs
            self.last_use[o] = max(self.last_use.get(o, -1), s.ready[o] + 1)
        self.chains = {}                                # id -> number of storage regs

    # ------------------------------------------------------------ helpers
    def width(self, n):
        return {"W": self.W, "D": self.D, "B": 1}.get(n.width, self.W)

    def decl(self, n):
        w = self.width(n)
        return ("reg %s" % ("signed [%d:0] " % (w - 1) if w > 1 else "")) + "v%d" % n.id

    def is_unit(self, n):
        return n.op == "mul" or n.op == "pick"

    def unit_out(self, n):
        g = self.g
        if n.op == "mul":
            cls, u = self.sch.unit[n.id]
            return "mu%d_out" % u if n.attrs.get("raw") else "$signed(mu%d_out[%d:0])" % (u, self.W - 1)
        src = g.nodes[n.args[0]]
        cls, u = self.sch.unit[src.id]
        pre = "cr" if src.op == "crot" else "cv"
        return "%s%d_o%d" % (pre, u, n.attrs["i"])

    def loc(self, a, part, c):
        """expression for value a as seen by a consumer in `part` at
        part-relative cycle c"""
        g = self.g
        n = g.nodes[a]
        if n.op == "const":
            return lit(round_half_up(n.attrs["value"], n.frac), self.width(n))
        if n.op == "shl":                                # constant shift: wiring
            return "(%s <<< %d)" % (self.loc(n.args[0], part, c), n.attrs["n"])
        if n.op == "in":
            name = n.attrs["name"]
            if name == "k":
                return self.chain_ref(n, c, glue=True, base="kcur")
            if name.startswith("acc_"):
                return name
            return "p_" + name
        if n.part != part:                               # setup value used later
            return "v%d" % n.id
        r = self.sch.ready[n.id]
        if part != "term":
            if self.is_unit(n):
                return self.unit_out(n) if c == r else "v%d" % n.id
            return "v%d" % n.id
        if self.is_unit(n):
            return self.chain_ref(n, c, glue=False, base=self.unit_out(n))
        return self.chain_ref(n, c, glue=True, base="v%d" % n.id)

    def chain_ref(self, n, c, glue, base):
        r = self.sch.ready.get(n.id, 0)
        II = self.II
        if glue:
            j = (c - r) // II
        else:
            j = 0 if c == r else (c - r - 1) // II + 1
        if j == 0:
            return base
        self.chains[n.id] = max(self.chains.get(n.id, 0), j)
        return "v%d_s%d" % (n.id, j)

    def rom_fn(self, table, frac, w):
        key = (table, frac)
        if key not in self.roms:
            vals = self.g.tables[table]
            name = "rom_%s_%d" % (table, frac)
            body = ["    function signed [%d:0] %s;" % (w - 1, name), "        input [15:0] i;",
                    "        begin", "            case (i)"]
            for i, v in enumerate(vals):
                body.append("                16'd%d: %s = %s;" % (i, name, lit(round_half_up(v, frac), w)))
            body += ["                default: %s = 0;" % name, "            endcase", "        end",
                     "    endfunction"]
            self.roms[key] = (name, body)
        return self.roms[key][0]

    # ------------------------------------------------------------ glue expr
    def expr(self, n, c):
        g, W, D = self.g, self.W, self.D
        a = [self.loc(x, n.part, c) for x in n.args]
        fa = [g.nodes[x].frac for x in n.args]
        op = n.op
        if op == "add":
            return "%s + %s" % (a[0], a[1])
        if op == "sub":
            return "%s - %s" % (a[0], a[1])
        if op == "neg":
            return "-%s" % a[0]
        if op == "refrac":
            return "shr_rnd(%s, 16'sd%d)" % (a[0], fa[0] - n.frac)
        if op == "scale":
            return "shr_rnd(%s, %s - %s)" % (a[0], lit(fa[0] - n.frac, 16), "$signed(%s)" % a[1])
        if op == "abs":
            return "((%s < 0) ? -%s : %s)" % (a[0], a[0], a[0])
        if op == "max":
            return "((%s >= %s) ? %s : %s)" % (a[0], a[1], a[0], a[1])
        if op == "mux":
            return "(%s ? %s : %s)" % (a[0], a[1], a[2])
        if op == "is_neg":
            return "(%s < 0)" % a[0]
        if op == "eq0":
            return "(%s == 0)" % a[0]
        if op == "bit0":
            return "%s[0]" % a[0]
        if op == "ishr":
            return "(%s >>> %d)" % (a[0], n.attrs["n"])
        if op == "iand":
            return "(%s & %s)" % (a[0], lit(n.attrs["mask"], W))
        if op == "shl":
            return "(%s <<< %d)" % (a[0], n.attrs["n"])
        if op == "norm_e":
            e = "(lead_pos(%s) - %s)" % (a[0], lit(fa[0], 16))
            return ("(%s & ~16'sd1)" % e) if n.attrs["even"] else e
        if op == "idx":
            nb = n.attrs["nbits"]
            sh = g.mf + 2 - nb if n.attrs["span4"] else g.mf - nb
            return "((%s >>> %d) & %s)" % (a[0], sh, lit((1 << nb) - 1, W))
        if op == "adj_shift":
            return "adj_shift_fn(%s, %s, 16'sd%d, 16'sd%d)" % (a[0], a[1], fa[0], n.attrs["cap"])
        if op == "rom":
            fn = self.rom_fn(n.attrs["table"], n.frac, W)
            return "%s(%s)" % (fn, a[0])
        raise ValueError(op)

    # ------------------------------------------------------------ emit
    def emit(self):
        g, cfg, sch = self.g, self.cfg, self.sch
        W, D, II, S, TF, F, NT = self.W, self.D, self.II, self.S, self.TF, self.F, self.NT
        out = []
        P = out.append
        body = []
        B = body.append

        # enables
        def en(n, t_rel):
            if n.part == "setup":
                return "(in_setup && t == 32'd%d)" % t_rel
            if n.part == "finish":
                return "(in_fin && t == 32'd%d)" % (TF + t_rel)
            return "(in_term && ph == %d)" % (t_rel % II)

        # glue registers
        decls = []
        for n in g.nodes:
            if n.op in ("const", "in", "pick", "mul", "crot", "cvec", "shl"):
                continue
            if n.part == "setup" and cfg.host_setup:
                continue
            decls.append(self.decl(n) + ";")
            st = sch.start[n.id]
            B("    always @(posedge clk) if %s v%d <= %s;" % (en(n, st), n.id, self.expr(n, st)))
        # captures of unit outputs used in setup/finish, and term storage chains
        for n in g.nodes:
            if n.op not in ("mul", "pick"):
                continue
            if n.id not in self.last_use:
                continue
            r = sch.ready[n.id]
            if n.part in ("setup", "finish"):
                decls.append(self.decl(n) + ";")
                B("    always @(posedge clk) if %s v%d <= %s;" % (en(n, r), n.id, self.unit_out(n)))
        # accumulators
        for name in H.ACC:
            o = self.dp.term[name]
            r = sch.ready[o]
            src = self.loc(o, "term", r)
            decls.append("reg signed [%d:0] acc_%s;" % (W - 1, name))
            B("    always @(posedge clk) begin")
            B("        if (start_evt) acc_%s <= 0;" % name)
            B("        else if (in_term && ph == %d && t >= 32'd%d && t <= 32'd%d) acc_%s <= acc_%s + %s;"
              % (r % II, S + r, S + r + (NT - 1) * II, name, name, src))
            B("    end")

        # shared multipliers
        mul_ops = {u: [] for u in range(cfg.mults)}
        rot_ops = {u: [] for u in range(cfg.crot)}
        vec_ops = {u: [] for u in range(cfg.cvec)}
        for n in g.nodes:
            if n.id in sch.unit:
                cls, u = sch.unit[n.id]
                {"MUL": mul_ops, "CROT": rot_ops, "CVEC": vec_ops}[cls][u].append(n)
        for u, ops in mul_ops.items():
            decls.append("reg signed [%d:0] mu%d_a, mu%d_b, mu%d_A, mu%d_B;" % (W - 1, u, u, u, u))
            decls.append("reg signed [%d:0] mu%d_P, mu%d_Q, mu%d_out;" % (D - 1, u, u, u))
            decls.append("reg signed [15:0] mu%d_sh, mu%d_S1, mu%d_S2, mu%d_S3;" % (u, u, u, u))
            decls.append("reg mu%d_neg, mu%d_N1, mu%d_N2;" % (u, u, u))
            B("    always @* begin")
            B("        mu%d_a = 0; mu%d_b = 0; mu%d_sh = 0; mu%d_neg = 0;" % (u, u, u, u))
            for part, cond, key in (("setup", "in_setup", "t"), ("term", "in_term", "ph"), ("finish", "in_fin", "t")):
                pops = [n for n in ops if n.part == part]
                if not pops:
                    continue
                B("        if (%s) case (%s)" % (cond, key))
                for n in pops:
                    st = sch.start[n.id]
                    lab = st % II if part == "term" else (st if part == "setup" else TF + st)
                    a = [self.loc(x, part, st) for x in n.args]
                    fa = [g.nodes[x].frac for x in n.args]
                    if n.attrs.get("raw"):
                        sh = "16'sd0"
                    else:
                        base = fa[0] + fa[1] - n.frac
                        sh = lit(base, 16) if len(a) == 2 else "(%s - $signed(%s))" % (lit(base, 16), a[2])
                    B("            %d: begin mu%d_a = %s; mu%d_b = %s; mu%d_sh = %s; mu%d_neg = 1'b%d; end"
                      % (lab, u, a[0], u, a[1], u, sh, u, 1 if n.attrs.get("negate") else 0))
                B("            default: ;")
                B("        endcase")
            B("    end")
            B("    always @(posedge clk) begin")
            B("        mu%d_A <= mu%d_a; mu%d_B <= mu%d_b; mu%d_S1 <= mu%d_sh; mu%d_N1 <= mu%d_neg;" % ((u,) * 8))
            B("        mu%d_P <= mu%d_A * mu%d_B; mu%d_S2 <= mu%d_S1; mu%d_N2 <= mu%d_N1;" % ((u,) * 7))
            B("        mu%d_Q <= mu%d_N2 ? -mu%d_P : mu%d_P; mu%d_S3 <= mu%d_S2;" % ((u,) * 6))
            B("        mu%d_out <= shr_rnd(mu%d_Q, mu%d_S3);" % (u, u, u))
            B("    end")

        # CORDIC units
        nit = g.cordic_iters
        for kind, opsd, pre in (("rot", rot_ops, "cr"), ("vec", vec_ops, "cv")):
            for u, ops in opsd.items():
                decls.append("reg %s%d_go; reg signed [%d:0] %s%d_x, %s%d_y;" % (pre, u, W - 1, pre, u, pre, u))
                decls.append("wire signed [%d:0] %s%d_o0, %s%d_o1;" % (W - 1, pre, u, pre, u))
                B("    always @* begin")
                B("        %s%d_go = 0; %s%d_x = 0; %s%d_y = 0;" % (pre, u, pre, u, pre, u))
                for part, cond, key in (("setup", "in_setup", "t"), ("term", "in_term", "ph"), ("finish", "in_fin", "t")):
                    pops = [n for n in ops if n.part == part]
                    if not pops:
                        continue
                    B("        if (%s) case (%s)" % (cond, key))
                    for n in pops:
                        st = sch.start[n.id]
                        lab = st % II if part == "term" else (st if part == "setup" else TF + st)
                        a = [self.loc(x, part, st) for x in n.args]
                        y = a[1] if len(a) > 1 else "0"
                        B("            %d: begin %s%d_go = 1; %s%d_x = %s; %s%d_y = %s; end" % (lab, pre, u, pre, u, a[0], pre, u, y))
                    B("            default: ;")
                    B("        endcase")
                B("    end")
                B("    %s_%s #(.WL(%d)) %s%d_inst (.clk(clk), .go(%s%d_go), .a(%s%d_x), .b(%s%d_y), .o0(%s%d_o0), .o1(%s%d_o1));"
                  % (self.name, kind, W, pre, u, pre, u, pre, u, pre, u, pre, u, pre, u))

        # storage chains (term values), after all loc() calls populated them
        chain_lines = []
        for nid, jmax in sorted(self.chains.items()):
            n = g.nodes[nid]
            glue = not self.is_unit(n)
            r = 0 if n.op == "in" else sch.ready[nid]
            base = "kcur" if n.op == "in" else ("v%d" % nid if glue else self.unit_out(n))
            ph = (r - 1) % II if glue else r % II
            w = self.width(n) if n.op != "in" else W
            for j in range(1, jmax + 1):
                decls.append("reg signed [%d:0] v%d_s%d;" % (w - 1, nid, j))
                src = base if j == 1 else "v%d_s%d" % (nid, j - 1)
                chain_lines.append("    always @(posedge clk) if (in_term && ph == %d) v%d_s%d <= %s;" % (ph, nid, j, src))

        # ---------------- module text
        P("`timescale 1ns / 1ps")
        P("// Generated by hardware/gen/rtlgen.py -- do not edit by hand.")
        P("// Config: WL=%d FL=%d mults=%d crot=%d cvec=%d cordic=%s II=%d S=%d L=%d F=%d cycles/eval=%d"
          % (W, cfg.fl, cfg.mults, cfg.crot, cfg.cvec, "pipelined" if cfg.cordic_pipelined else "iterative",
             II, S, self.L, F, TF + F + 2))
        P("module %s (" % self.name)
        P("    input  wire clk, input wire rst, input wire start,")
        for p_ in H.PARAMS:
            P("    input  wire signed [%d:0] %s," % (W - 1, p_))
        P("    input  wire is_call,")
        for o in H.OUTPUTS:
            P("    output wire signed [%d:0] %s," % (W - 1, o))
        P("    output reg  done")
        P(");")
        P("    localparam WL = %d;" % W)
        P("    reg running; reg [31:0] t; reg [15:0] ph; reg [15:0] kcur;")
        P("    wire start_evt = start && !running;")
        P("    wire in_setup = running && t < 32'd%d;" % S)
        P("    wire in_term  = running && t >= 32'd%d && t < 32'd%d;" % (S, TF))
        P("    wire in_fin   = running && t >= 32'd%d;" % TF)
        for p_ in H.PARAMS:
            P("    reg signed [%d:0] p_%s;" % (W - 1, p_))
        P("    reg signed [%d:0] p_is_call;" % (W - 1))
        P("    always @(posedge clk) begin")
        P("        if (rst) begin running <= 0; done <= 0; end")
        P("        else begin")
        P("            done <= 0;")
        P("            if (start_evt) begin")
        P("                running <= 1; t <= 0;")
        for p_ in H.PARAMS:
            P("                p_%s <= %s;" % (p_, p_))
        P("                p_is_call <= is_call;")
        P("            end else if (running) begin")
        P("                t <= t + 1;")
        P("                if (t == 32'd%d) begin running <= 0; done <= 1; end" % (TF + F))
        P("            end")
        P("        end")
        P("    end")
        P("    // term phase and index")
        P("    always @(posedge clk) begin")
        P("        if (start_evt) begin ph <= %s; kcur <= 0; end" % ("0" if S == 0 else "0"))
        P("        else if (running && t + 1 >= 32'd%d) begin" % S)
        P("            if (t + 1 == 32'd%d) ph <= 0;" % S)
        P("            else begin")
        P("                ph <= (ph == %d) ? 16'd0 : ph + 16'd1;" % (II - 1))
        P("                if (ph == %d) kcur <= kcur + 16'd1;" % (II - 1))
        P("            end")
        P("        end")
        P("    end")
        P("")
        P("    function signed [%d:0] shr_rnd;" % (D - 1))
        P("        input signed [%d:0] v;" % (D - 1))
        P("        input signed [15:0] s;")
        P("        begin")
        P("            if (s > 0) shr_rnd = (v + ($signed({{%d{1'b0}}, 1'b1}) <<< (s - 1))) >>> s;" % (D - 1))
        P("            else if (s < 0) shr_rnd = v <<< (-s);")
        P("            else shr_rnd = v;")
        P("        end")
        P("    endfunction")
        P("    function signed [15:0] lead_pos;")
        P("        input signed [%d:0] v;" % (D - 1))
        P("        integer i; reg [%d:0] x;" % (D - 1))
        P("        begin")
        P("            x = (v < 0) ? -v : v; lead_pos = 0;")
        P("            for (i = 0; i < %d; i = i + 1) if (x[i]) lead_pos = i;" % D)
        P("        end")
        P("    endfunction")
        P("    function signed [15:0] adj_shift_fn;")
        P("        input signed [%d:0] a; input signed [%d:0] b; input signed [15:0] fr; input signed [15:0] cap;" % (D - 1, D - 1))
        P("        integer i; reg [%d:0] x; reg signed [15:0] s; reg found;" % (D - 1))
        P("        begin")
        P("            x = ((a < 0) ? -a : a) | ((b < 0) ? -b : b);")
        P("            s = 0; found = 0;")
        P("            for (i = 0; i < %d; i = i + 1) if (x[i]) begin s = i; found = 1; end" % D)
        P("            if (!found) adj_shift_fn = cap;")
        P("            else begin s = fr - s; adj_shift_fn = (s < 0) ? 16'sd0 : ((s > cap) ? cap : s); end")
        P("        end")
        P("    endfunction")
        body_text = body + chain_lines
        rom_text = []
        for name, lines in self.roms.values():
            rom_text += lines
        out += rom_text
        out += ["    " + d for d in decls]
        out += body_text
        for o in H.OUTPUTS:
            n = g.nodes[self.dp.finish[o]]
            P("    assign %s = %s;" % (o, "v%d" % n.id if n.op != "in" else "0"))
        out.append("endmodule")
        out.append("")
        out += (self.cordic_modules_pipelined(nit) if cfg.cordic_pipelined else self.cordic_modules(nit))
        return "\n".join(out)

    def cordic_modules(self, nit):
        """Iterative CORDIC units (exact models: ir.cordic_rot_fixed / cordic_vec_fixed)."""
        g, W = self.g, self.W
        fl, gb = g.fl, g.gb
        f = fl + gb
        XW = W + 2 + gb
        atan = ["            %d: at = %s;" % (i, lit(round_half_up(ATAN_DEC[i], f), XW)) for i in range(nit)]
        pi, half, invk = (round_half_up(PI_DEC, f), round_half_up(PI_DEC / 2, f), round_half_up(CORDIC_INVK_DEC, f))
        m = []
        for kind in ("rot", "vec"):
            m += ["module %s_%s #(parameter WL = %d) (" % (self.name, kind, W),
                  "    input wire clk, input wire go,",
                  "    input wire signed [WL-1:0] a, input wire signed [WL-1:0] b,",
                  "    output reg signed [WL-1:0] o0, output reg signed [WL-1:0] o1);",
                  "    localparam XW = %d, GB = %d, NIT = %d;" % (XW, gb, nit),
                  "    reg signed [XW-1:0] x, y, z, zt, at, xr, yr, zr;",
                  "    reg flip; reg signed [1:0] addpi; reg [7:0] cnt; reg busy;",
                  "    always @* begin",
                  "        case (cnt)"] + atan + [
                  "            default: at = 0;",
                  "        endcase",
                  "    end",
                  "    always @(posedge clk) begin",
                  "        if (go) begin",
                  "            cnt <= 0; busy <= 1;"]
            if kind == "rot":
                m += ["            zt = $signed(a) <<< GB;",
                      "            flip <= 0;",
                      "            if (zt > %s) begin zt = zt - %s; flip <= 1; end" % (lit(half, XW), lit(pi, XW)),
                      "            else if (zt < -%s) begin zt = zt + %s; flip <= 1; end" % (lit(half, XW), lit(pi, XW)),
                      "            x <= %s; y <= 0;" % lit(invk, XW)]
            else:
                m += ["            addpi <= 0; zt = 0;",
                      "            if (a < 0) begin x <= -($signed(a) <<< GB); y <= -($signed(b) <<< GB); addpi <= (b < 0) ? -2'sd1 : 2'sd1; end",
                      "            else begin x <= $signed(a) <<< GB; y <= $signed(b) <<< GB; end"]
            m += ["            z <= zt;",
                  "        end else if (busy) begin",
                  "            if (cnt < NIT) begin"]
            if kind == "rot":
                m += ["                if (z < 0) begin x <= x + (y >>> cnt); y <= y - (x >>> cnt); z <= z + at; end",
                      "                else begin x <= x - (y >>> cnt); y <= y + (x >>> cnt); z <= z - at; end"]
            else:
                m += ["                if (y >= 0) begin x <= x + (y >>> cnt); y <= y - (x >>> cnt); z <= z + at; end",
                      "                else begin x <= x - (y >>> cnt); y <= y + (x >>> cnt); z <= z - at; end"]
            m += ["                cnt <= cnt + 1;",
                  "            end else begin",
                  "                busy <= 0;"]
            if kind == "rot":
                m += ["                xr = (x + (1 <<< (GB - 1))) >>> GB; yr = (y + (1 <<< (GB - 1))) >>> GB;",
                      "                o0 <= flip ? -xr : xr; o1 <= flip ? -yr : yr;"]
            else:
                m += ["                zr = z + ((addpi == 1) ? %s : ((addpi == -1) ? -%s : 0));" % (lit(pi, XW), lit(pi, XW)),
                      "                o0 <= (x + (1 <<< (GB - 1))) >>> GB; o1 <= (zr + (1 <<< (GB - 1))) >>> GB;"]
            m += ["            end", "        end", "    end", "endmodule", ""]
        return m

    def cordic_modules_pipelined(self, nit):
        """Pipelined CORDIC units: one stage register per iteration, same
        latency (NIT + 2) and same arithmetic as the iterative units, but a new
        operation may start every cycle."""
        g, W = self.g, self.W
        fl, gb = g.fl, g.gb
        f = fl + gb
        XW = W + 2 + gb
        pi, half, invk = (round_half_up(PI_DEC, f), round_half_up(PI_DEC / 2, f), round_half_up(CORDIC_INVK_DEC, f))
        m = []
        for kind in ("rot", "vec"):
            m += ["module %s_%s #(parameter WL = %d) (" % (self.name, kind, W),
                  "    input wire clk, input wire go,",
                  "    input wire signed [WL-1:0] a, input wire signed [WL-1:0] b,",
                  "    output reg signed [WL-1:0] o0, output reg signed [WL-1:0] o1);",
                  "    localparam XW = %d, GB = %d, NIT = %d;" % (XW, gb, nit),
                  "    function signed [XW-1:0] at; input integer i;",
                  "        begin case (i)"]
            m += ["            %d: at = %s;" % (i, lit(round_half_up(ATAN_DEC[i], f), XW)) for i in range(nit)]
            m += ["            default: at = 0;", "        endcase end", "    endfunction",
                  "    reg signed [XW-1:0] xs [0:NIT]; reg signed [XW-1:0] ys [0:NIT]; reg signed [XW-1:0] zs [0:NIT];",
                  "    reg signed [1:0] tag [0:NIT];",
                  "    reg signed [XW-1:0] zt, xr, yr, zr; reg signed [1:0] tg; integer i;",
                  "    always @(posedge clk) begin"]
            if kind == "rot":
                m += ["        zt = $signed(a) <<< GB; tg = 0;",
                      "        if (zt > %s) begin zt = zt - %s; tg = 1; end" % (lit(half, XW), lit(pi, XW)),
                      "        else if (zt < -%s) begin zt = zt + %s; tg = 1; end" % (lit(half, XW), lit(pi, XW)),
                      "        xs[0] <= %s; ys[0] <= 0; zs[0] <= zt; tag[0] <= tg;" % lit(invk, XW),
                      "        for (i = 0; i < NIT; i = i + 1) begin",
                      "            if (zs[i] < 0) begin xs[i+1] <= xs[i] + (ys[i] >>> i); ys[i+1] <= ys[i] - (xs[i] >>> i); zs[i+1] <= zs[i] + at(i); end",
                      "            else begin xs[i+1] <= xs[i] - (ys[i] >>> i); ys[i+1] <= ys[i] + (xs[i] >>> i); zs[i+1] <= zs[i] - at(i); end",
                      "            tag[i+1] <= tag[i];",
                      "        end",
                      "        xr = (xs[NIT] + (1 <<< (GB - 1))) >>> GB; yr = (ys[NIT] + (1 <<< (GB - 1))) >>> GB;",
                      "        o0 <= (tag[NIT] != 0) ? -xr : xr; o1 <= (tag[NIT] != 0) ? -yr : yr;"]
            else:
                m += ["        if (a < 0) begin xs[0] <= -($signed(a) <<< GB); ys[0] <= -($signed(b) <<< GB); tag[0] <= (b < 0) ? -2'sd1 : 2'sd1; end",
                      "        else begin xs[0] <= $signed(a) <<< GB; ys[0] <= $signed(b) <<< GB; tag[0] <= 0; end",
                      "        zs[0] <= 0;",
                      "        for (i = 0; i < NIT; i = i + 1) begin",
                      "            if (ys[i] >= 0) begin xs[i+1] <= xs[i] + (ys[i] >>> i); ys[i+1] <= ys[i] - (xs[i] >>> i); zs[i+1] <= zs[i] + at(i); end",
                      "            else begin xs[i+1] <= xs[i] - (ys[i] >>> i); ys[i+1] <= ys[i] + (xs[i] >>> i); zs[i+1] <= zs[i] - at(i); end",
                      "            tag[i+1] <= tag[i];",
                      "        end",
                      "        zr = zs[NIT] + ((tag[NIT] == 1) ? %s : ((tag[NIT] == -1) ? -%s : 0));" % (lit(pi, XW), lit(pi, XW)),
                      "        o0 <= (xs[NIT] + (1 <<< (GB - 1))) >>> GB; o1 <= (zr + (1 <<< (GB - 1))) >>> GB;"]
            m += ["    end", "endmodule", ""]
        return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wl", type=int, default=56)
    ap.add_argument("--fl", type=int, default=28)
    ap.add_argument("--mults", type=int, default=8)
    ap.add_argument("--crot", type=int, default=3)
    ap.add_argument("--cvec", type=int, default=2)
    ap.add_argument("--terms", type=int, default=128)
    ap.add_argument("--pipe-cordic", action="store_true")
    ap.add_argument("--name", default="heston_aad_z7")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    cfg = Config(wl=a.wl, fl=a.fl, mults=a.mults, crot=a.crot, cvec=a.cvec, cordic_pipelined=a.pipe_cordic,
                 n_terms=a.terms)
    dp = H.Datapath(a.wl, a.fl)
    gen = Gen(dp, cfg, a.name)
    text = gen.emit()
    path = a.out or os.path.join(os.path.dirname(__file__), "..", "verilog", "gen", a.name + ".v")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)
    print("wrote %s: II=%d S=%d L=%d F=%d cycles/eval=%d" % (path, gen.II, gen.S, gen.L, gen.F, gen.TF + gen.F + 2))
    return gen


if __name__ == "__main__":
    main()
