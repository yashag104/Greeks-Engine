//============================================================================
// fx_lib.vh -- shared fixed-point constants, `include'd INSIDE a module body
//============================================================================
// Every constant is stored once as a signed Q4.60 literal (generated in
// 120-digit decimal arithmetic by hardware/tools/gen_constants.py) and
// rounded to the including module's own FL by q60(). This replaces the old
// `$rtoi(c * 2.0**16) <<< (FL-16)` idiom, which silently truncated every
// constant to 16 fractional bits even in the Q32.32 datapath -- e.g. the
// CORDIC gain 1/K was off by 2.3e-5 relative, which alone made phi(0) =
// 0.999977 instead of 1.
//
// Requires the including module to define parameters WL and FL, with
// FL <= 59, WL <= 128 and all constants |c| < 8.
//============================================================================

localparam signed [63:0] C_LN2          = 64'sh0B17217F7D1CF79B;
localparam signed [63:0] C_INV_LN2      = 64'sh171547652B82FE17;
localparam signed [63:0] C_PI           = 64'sh3243F6A8885A308D;
localparam signed [63:0] C_TWO_PI       = 64'sh6487ED5110B4611A;
localparam signed [63:0] C_HALF_PI      = 64'sh1921FB54442D1847;
localparam signed [63:0] C_INV_2PI      = 64'sh028BE60DB9391055;
localparam signed [63:0] C_CORDIC_INV_K = 64'sh09B74EDA8435E5A6;
localparam signed [63:0] C_ONE          = 64'sh1000000000000000;

// Round a Q4.60 constant to Q(WL-FL, FL + extra) (round-half-up).
function signed [WL-1:0] q60x;
    input signed [63:0] c;
    input integer       extra;   // additional fractional (guard) bits
    reg   signed [127:0] t;   // wide enough for any WL <= 128
    begin
        t = ($signed({{64{c[63]}}, c}) >>> (60 - FL - extra - 1)) + 128'sd1;
        t = t >>> 1;
        q60x = t[WL-1:0];
    end
endfunction

function signed [WL-1:0] q60;
    input signed [63:0] c;
    begin
        q60 = q60x(c, 0);
    end
endfunction

// 1/n!, Q4.60
function signed [63:0] inv_fact;
    input [3:0] n;
    begin
        case (n)
            4'd0: inv_fact = 64'sh1000000000000000;
            4'd1: inv_fact = 64'sh1000000000000000;
            4'd2: inv_fact = 64'sh0800000000000000;
            4'd3: inv_fact = 64'sh02AAAAAAAAAAAAAB;
            4'd4: inv_fact = 64'sh00AAAAAAAAAAAAAB;
            4'd5: inv_fact = 64'sh0022222222222222;
            4'd6: inv_fact = 64'sh0005B05B05B05B06;
            4'd7: inv_fact = 64'sh0000D00D00D00D01;
            4'd8: inv_fact = 64'sh00001A01A01A01A0;
            4'd9: inv_fact = 64'sh000002E3BC74AAD9;
            4'd10: inv_fact = 64'sh00000049F93EDDE2;
            4'd11: inv_fact = 64'sh00000006B99159FD;
            4'd12: inv_fact = 64'sh000000008F76C780;
            4'd13: inv_fact = 64'sh000000000B09230A;
            4'd14: inv_fact = 64'sh0000000000C9CBA5;
            4'd15: inv_fact = 64'sh00000000000D73FA;
            default: inv_fact = 64'sh0;
        endcase
    end
endfunction

// atan(2^-i), Q4.60
function signed [63:0] atan_q60;
    input [5:0] i;
    begin
        case (i)
            6'd0: atan_q60 = 64'sh0C90FDAA22168C23;
            6'd1: atan_q60 = 64'sh076B19C1586ED3DA;
            6'd2: atan_q60 = 64'sh03EB6EBF25901BAC;
            6'd3: atan_q60 = 64'sh01FD5BA9AAC2F6DC;
            6'd4: atan_q60 = 64'sh00FFAADDB967EF4E;
            6'd5: atan_q60 = 64'sh007FF556EEA5D893;
            6'd6: atan_q60 = 64'sh003FFEAAB776E535;
            6'd7: atan_q60 = 64'sh001FFFD555BBBA97;
            6'd8: atan_q60 = 64'sh000FFFFAAAADDDDC;
            6'd9: atan_q60 = 64'sh0007FFFF55556EEF;
            6'd10: atan_q60 = 64'sh0003FFFFEAAAAB77;
            6'd11: atan_q60 = 64'sh0001FFFFFD55555C;
            6'd12: atan_q60 = 64'sh0000FFFFFFAAAAAB;
            6'd13: atan_q60 = 64'sh00007FFFFFF55555;
            6'd14: atan_q60 = 64'sh00003FFFFFFEAAAB;
            6'd15: atan_q60 = 64'sh00001FFFFFFFD555;
            6'd16: atan_q60 = 64'sh00000FFFFFFFFAAB;
            6'd17: atan_q60 = 64'sh000007FFFFFFFF55;
            6'd18: atan_q60 = 64'sh000003FFFFFFFFEB;
            6'd19: atan_q60 = 64'sh000001FFFFFFFFFD;
            6'd20: atan_q60 = 64'sh0000010000000000;
            6'd21: atan_q60 = 64'sh0000008000000000;
            6'd22: atan_q60 = 64'sh0000004000000000;
            6'd23: atan_q60 = 64'sh0000002000000000;
            6'd24: atan_q60 = 64'sh0000001000000000;
            6'd25: atan_q60 = 64'sh0000000800000000;
            6'd26: atan_q60 = 64'sh0000000400000000;
            6'd27: atan_q60 = 64'sh0000000200000000;
            6'd28: atan_q60 = 64'sh0000000100000000;
            6'd29: atan_q60 = 64'sh0000000080000000;
            6'd30: atan_q60 = 64'sh0000000040000000;
            6'd31: atan_q60 = 64'sh0000000020000000;
            6'd32: atan_q60 = 64'sh0000000010000000;
            6'd33: atan_q60 = 64'sh0000000008000000;
            6'd34: atan_q60 = 64'sh0000000004000000;
            6'd35: atan_q60 = 64'sh0000000002000000;
            6'd36: atan_q60 = 64'sh0000000001000000;
            6'd37: atan_q60 = 64'sh0000000000800000;
            6'd38: atan_q60 = 64'sh0000000000400000;
            6'd39: atan_q60 = 64'sh0000000000200000;
            6'd40: atan_q60 = 64'sh0000000000100000;
            6'd41: atan_q60 = 64'sh0000000000080000;
            6'd42: atan_q60 = 64'sh0000000000040000;
            6'd43: atan_q60 = 64'sh0000000000020000;
            6'd44: atan_q60 = 64'sh0000000000010000;
            6'd45: atan_q60 = 64'sh0000000000008000;
            6'd46: atan_q60 = 64'sh0000000000004000;
            6'd47: atan_q60 = 64'sh0000000000002000;
            6'd48: atan_q60 = 64'sh0000000000001000;
            6'd49: atan_q60 = 64'sh0000000000000800;
            6'd50: atan_q60 = 64'sh0000000000000400;
            6'd51: atan_q60 = 64'sh0000000000000200;
            6'd52: atan_q60 = 64'sh0000000000000100;
            6'd53: atan_q60 = 64'sh0000000000000080;
            6'd54: atan_q60 = 64'sh0000000000000040;
            6'd55: atan_q60 = 64'sh0000000000000020;
            6'd56: atan_q60 = 64'sh0000000000000010;
            6'd57: atan_q60 = 64'sh0000000000000008;
            6'd58: atan_q60 = 64'sh0000000000000004;
            6'd59: atan_q60 = 64'sh0000000000000002;
            6'd60: atan_q60 = 64'sh0000000000000001;
            6'd61: atan_q60 = 64'sh0000000000000000;
            6'd62: atan_q60 = 64'sh0000000000000000;
            6'd63: atan_q60 = 64'sh0000000000000000;
            default: atan_q60 = 64'sh0;
        endcase
    end
endfunction

// ln(1+t) Taylor coefficients (-1)^(n+1)/n, Q4.60
function signed [63:0] log_coef;
    input [3:0] n;
    begin
        case (n)
            4'd1: log_coef = 64'sh1000000000000000;
            4'd2: log_coef = -64'sh0800000000000000;
            4'd3: log_coef = 64'sh0555555555555555;
            4'd4: log_coef = -64'sh0400000000000000;
            4'd5: log_coef = 64'sh0333333333333333;
            4'd6: log_coef = -64'sh02AAAAAAAAAAAAAB;
            4'd7: log_coef = 64'sh0249249249249249;
            4'd8: log_coef = -64'sh0200000000000000;
            4'd9: log_coef = 64'sh01C71C71C71C71C7;
            4'd10: log_coef = -64'sh019999999999999A;
            4'd11: log_coef = 64'sh01745D1745D1745D;
            4'd12: log_coef = -64'sh0155555555555555;
            4'd13: log_coef = 64'sh013B13B13B13B13B;
            4'd14: log_coef = -64'sh0124924924924925;
            4'd15: log_coef = 64'sh0111111111111111;
            default: log_coef = 64'sh0;
        endcase
    end
endfunction

// log LUT, c_j = 1 + (2j+1)/32 (midpoint of [1 + j/16, 1 + (j+1)/16)):
// 1/c_j and ln(c_j), Q4.60
function signed [63:0] log_inv_c;
    input [3:0] j;
    reg signed [63:0] inv_c, ln_c;
    begin
        case (j)
            4'd0: begin inv_c = 64'sh0F83E0F83E0F83E1; ln_c = 64'sh007E0A6C39E0CC01; end
            4'd1: begin inv_c = 64'sh0EA0EA0EA0EA0EA1; ln_c = 64'sh016F0D28AE56B4BA; end
            4'd2: begin inv_c = 64'sh0DD67C8A60DD67C9; ln_c = 64'sh0252AA5F03FEA46A; end
            4'd3: begin inv_c = 64'sh0D20D20D20D20D21; ln_c = 64'sh032A4B539E8AD68F; end
            4'd4: begin inv_c = 64'sh0C7CE0C7CE0C7CE1; ln_c = 64'sh03F7230DABC7C552; end
            4'd5: begin inv_c = 64'sh0BE82FA0BE82FA0C; ln_c = 64'sh04BA38AEB8474C27; end
            4'd6: begin inv_c = 64'sh0B60B60B60B60B61; ln_c = 64'sh05746F6FD6027294; end
            4'd7: begin inv_c = 64'sh0AE4C415C9882B93; ln_c = 64'sh06268CE1B05096AD; end
            4'd8: begin inv_c = 64'sh0A72F05397829CBC; ln_c = 64'sh06D13DDEF323D8A3; end
            4'd9: begin inv_c = 64'sh0A0A0A0A0A0A0A0A; ln_c = 64'sh07751A8130712830; end
            4'd10: begin inv_c = 64'sh09A90E7D95BC609B; ln_c = 64'sh0812A952D2E87F63; end
            4'd11: begin inv_c = 64'sh094F2094F2094F21; ln_c = 64'sh08AA61E97A6AF4D5; end
            4'd12: begin inv_c = 64'sh08FB823EE08FB824; ln_c = 64'sh093CAF0944D88D76; end
            4'd13: begin inv_c = 64'sh08AD8F2FBA938682; ln_c = 64'sh09C9F069AB150CD5; end
            4'd14: begin inv_c = 64'sh0864B8A7DE6D1D61; ln_c = 64'sh0A527C2ED81F5D81; end
            4'd15: begin inv_c = 64'sh0820820820820821; ln_c = 64'sh0AD6A0261ACF967E; end
            default: begin inv_c = 64'sh0; ln_c = 64'sh0; end
        endcase
        log_inv_c = inv_c;
    end
endfunction

function signed [63:0] log_ln_c;
    input [3:0] j;
    reg signed [63:0] inv_c, ln_c;
    begin
        case (j)
            4'd0: begin inv_c = 64'sh0F83E0F83E0F83E1; ln_c = 64'sh007E0A6C39E0CC01; end
            4'd1: begin inv_c = 64'sh0EA0EA0EA0EA0EA1; ln_c = 64'sh016F0D28AE56B4BA; end
            4'd2: begin inv_c = 64'sh0DD67C8A60DD67C9; ln_c = 64'sh0252AA5F03FEA46A; end
            4'd3: begin inv_c = 64'sh0D20D20D20D20D21; ln_c = 64'sh032A4B539E8AD68F; end
            4'd4: begin inv_c = 64'sh0C7CE0C7CE0C7CE1; ln_c = 64'sh03F7230DABC7C552; end
            4'd5: begin inv_c = 64'sh0BE82FA0BE82FA0C; ln_c = 64'sh04BA38AEB8474C27; end
            4'd6: begin inv_c = 64'sh0B60B60B60B60B61; ln_c = 64'sh05746F6FD6027294; end
            4'd7: begin inv_c = 64'sh0AE4C415C9882B93; ln_c = 64'sh06268CE1B05096AD; end
            4'd8: begin inv_c = 64'sh0A72F05397829CBC; ln_c = 64'sh06D13DDEF323D8A3; end
            4'd9: begin inv_c = 64'sh0A0A0A0A0A0A0A0A; ln_c = 64'sh07751A8130712830; end
            4'd10: begin inv_c = 64'sh09A90E7D95BC609B; ln_c = 64'sh0812A952D2E87F63; end
            4'd11: begin inv_c = 64'sh094F2094F2094F21; ln_c = 64'sh08AA61E97A6AF4D5; end
            4'd12: begin inv_c = 64'sh08FB823EE08FB824; ln_c = 64'sh093CAF0944D88D76; end
            4'd13: begin inv_c = 64'sh08AD8F2FBA938682; ln_c = 64'sh09C9F069AB150CD5; end
            4'd14: begin inv_c = 64'sh0864B8A7DE6D1D61; ln_c = 64'sh0A527C2ED81F5D81; end
            4'd15: begin inv_c = 64'sh0820820820820821; ln_c = 64'sh0AD6A0261ACF967E; end
            default: begin inv_c = 64'sh0; ln_c = 64'sh0; end
        endcase
        log_ln_c = ln_c;
    end
endfunction

// Round-to-nearest arithmetic right shift by FL of a (up to) 2*WL-bit
// product. Plain `>>> FL` floors, i.e. is biased by -0.5 ULP per
// multiplication; in the Heston-COS datapath those biases are multiplied by
// payoff coefficients |V_k| up to ~300 and accumulate coherently over the
// 128 terms (measured: -6.8e-7 absolute price bias at Q32.32 before this).
function signed [2*WL-1:0] rshr;
    input signed [2*WL-1:0] v;
    begin
        rshr = (v + ($signed({{(2*WL-1){1'b0}}, 1'b1}) <<< (FL - 1))) >>> FL;
    end
endfunction
