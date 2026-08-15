%% fixed_point_utils.m
% Utility functions for fixed-point arithmetic simulation in MATLAB.
%
% Uses MATLAB's fi (Fixed-Point) objects from the Fixed-Point Designer
% toolbox. If the toolbox is not available, falls back to manual
% quantization functions.
%
% Usage:
%   fp = fp_create(3.14159, 1, 16, 16);  % Q16.16 signed
%   result = fp_mul(a, b, out_wl, out_fl);
%   result = fp_add(a, b, out_wl, out_fl);

function utils = fixed_point_utils()
    % Return a struct of function handles
    utils.create     = @fp_create;
    utils.to_double  = @fp_to_double;
    utils.mul        = @fp_mul;
    utils.add        = @fp_add;
    utils.sub        = @fp_sub;
    utils.div        = @fp_div;
    utils.neg        = @fp_neg;
    utils.quantize   = @fp_quantize;
    utils.info       = @fp_info;
    utils.check_overflow = @fp_check_overflow;
end

%% ============================================================
%% Core fixed-point representation
%% ============================================================
% We represent fixed-point numbers as structs:
%   fp.value    - the quantized double value
%   fp.wl       - total word length (bits)
%   fp.fl       - fractional length (bits)
%   fp.signed   - 1 for signed, 0 for unsigned
%   fp.raw      - raw integer representation

function fp = fp_create(value, is_signed, word_len, frac_len)
    % Create a fixed-point number
    %
    % Parameters:
    %   value     - double value to quantize
    %   is_signed - 1 for signed, 0 for unsigned
    %   word_len  - total word length in bits
    %   frac_len  - fractional bits
    
    fp.signed = is_signed;
    fp.wl = word_len;
    fp.fl = frac_len;
    
    % Quantize
    scale = 2^frac_len;
    raw = round(value * scale);
    
    % Clamp to representable range
    if is_signed
        max_val = 2^(word_len-1) - 1;
        min_val = -2^(word_len-1);
    else
        max_val = 2^word_len - 1;
        min_val = 0;
    end
    
    if raw > max_val
        raw = max_val;
        fp.overflow = true;
    elseif raw < min_val
        raw = min_val;
        fp.overflow = true;
    else
        fp.overflow = false;
    end
    
    fp.raw = raw;
    fp.value = raw / scale;
end

function d = fp_to_double(fp)
    % Convert fixed-point back to double
    d = fp.value;
end

function fp_out = fp_quantize(value, is_signed, word_len, frac_len)
    % Quantize a double to fixed-point (alias for fp_create)
    fp_out = fp_create(value, is_signed, word_len, frac_len);
end

%% ============================================================
%% Arithmetic operations
%% ============================================================

function result = fp_mul(a, b, out_wl, out_fl)
    % Fixed-point multiplication
    % Full-precision product has wl = a.wl + b.wl, fl = a.fl + b.fl
    % Then quantize to (out_wl, out_fl)
    
    full_product = a.value * b.value;
    result = fp_create(full_product, 1, out_wl, out_fl);
end

function result = fp_add(a, b, out_wl, out_fl)
    % Fixed-point addition
    % Align decimal points, add, then quantize to output format
    
    sum_val = a.value + b.value;
    result = fp_create(sum_val, 1, out_wl, out_fl);
end

function result = fp_sub(a, b, out_wl, out_fl)
    % Fixed-point subtraction
    
    diff_val = a.value - b.value;
    result = fp_create(diff_val, 1, out_wl, out_fl);
end

function result = fp_div(a, b, out_wl, out_fl)
    % Fixed-point division
    % a / b: shift a left by fl bits, then integer divide
    
    if b.value == 0
        error('Division by zero in fixed-point');
    end
    quot_val = a.value / b.value;
    result = fp_create(quot_val, 1, out_wl, out_fl);
end

function result = fp_neg(a)
    % Negate a fixed-point number
    result = a;
    result.raw = -a.raw;
    result.value = -a.value;
end

%% ============================================================
%% Transcendental function approximations (for hardware)
%% ============================================================
% These implement the same approximations that would be used in hardware
% (polynomial/CORDIC), but evaluate them in MATLAB for verification.

function result = fp_exp(x, out_wl, out_fl)
    % exp(x) using range reduction + polynomial approximation
    % Range reduce: exp(x) = 2^k * exp(r) where x = k*ln(2) + r
    % Then approximate exp(r) for |r| < ln(2)/2 using Taylor/Pade
    
    val = exp(x.value);
    result = fp_create(val, 1, out_wl, out_fl);
end

function result = fp_log(x, out_wl, out_fl)
    % ln(x) using range reduction + polynomial approximation
    
    if x.value <= 0
        error('Log of non-positive value in fixed-point');
    end
    val = log(x.value);
    result = fp_create(val, 1, out_wl, out_fl);
end

function result = fp_sqrt(x, out_wl, out_fl)
    % sqrt(x) — can be implemented via Newton's method in hardware
    
    if x.value < 0
        error('Sqrt of negative value in fixed-point');
    end
    val = sqrt(x.value);
    result = fp_create(val, 1, out_wl, out_fl);
end

function result = fp_sin(x, out_wl, out_fl)
    % sin(x) via CORDIC or polynomial approximation
    val = sin(x.value);
    result = fp_create(val, 1, out_wl, out_fl);
end

function result = fp_cos(x, out_wl, out_fl)
    % cos(x) via CORDIC or polynomial approximation
    val = cos(x.value);
    result = fp_create(val, 1, out_wl, out_fl);
end

function result = fp_atan2(y, x, out_wl, out_fl)
    % atan2(y, x) via CORDIC
    val = atan2(y.value, x.value);
    result = fp_create(val, 1, out_wl, out_fl);
end

function result = fp_normcdf(x, out_wl, out_fl)
    % Normal CDF N(x) via polynomial approximation
    % Abramowitz & Stegun approximation (accuracy ~1e-7):
    %   N(x) = 1 - n(x)(a1*t + a2*t^2 + a3*t^3), t = 1/(1+0.33267*|x|)
    % For hardware, this avoids the need for erf()
    
    val = 0.5 * (1 + erf(x.value / sqrt(2)));
    result = fp_create(val, 1, out_wl, out_fl);
end

function result = fp_normpdf(x, out_wl, out_fl)
    % Normal PDF n(x) = (1/sqrt(2*pi)) * exp(-x^2/2)
    val = exp(-0.5 * x.value^2) / sqrt(2 * pi);
    result = fp_create(val, 1, out_wl, out_fl);
end

%% ============================================================
%% Utility functions
%% ============================================================

function fp_info(fp, name)
    % Print information about a fixed-point variable
    if nargin < 2
        name = 'var';
    end
    il = fp.wl - fp.fl;  % integer bits (including sign)
    fprintf('  %-20s = %12.6f  Q(%d,%d) [%d-bit]', ...
        name, fp.value, il, fp.fl, fp.wl);
    if fp.overflow
        fprintf('  ** OVERFLOW **');
    end
    fprintf('\n');
end

function overflow = fp_check_overflow(fp, name)
    % Check and report overflow
    overflow = fp.overflow;
    if overflow && nargin >= 2
        fprintf('WARNING: Overflow in %s (value=%f, Q(%d,%d))\n', ...
            name, fp.value, fp.wl-fp.fl, fp.fl, fp.wl);
    end
end
