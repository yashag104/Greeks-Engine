%% bs_forward_core.m
% Black-Scholes Forward Pricing Core — Fixed-Point Pipeline
%
% Implements the BS call/put pricing formula in fixed-point arithmetic,
% replicating the exact operation sequence from the tape schema.
%
% This represents the forward pricing pipeline that would run on hardware.
% Each operation is explicitly quantized to the specified fixed-point format.
%
% Usage:
%   [price, tape] = bs_forward_core(S, K, T, r, sigma, 'call');

function [price, tape] = bs_forward_core(S_val, K_val, T_val, r_val, sigma_val, option_type)
    if nargin < 6
        option_type = 'call';
    end
    
    % Get fixed-point utilities
    fp = fixed_point_utils();
    
    % ============================================================
    % Fixed-point format definitions (from bit_width_budget.md)
    % ============================================================
    % Standard precision: 32-bit
    WL32 = 32;
    % Accumulator precision: 48-bit
    WL48 = 48;
    
    % Format: [word_length, frac_length]
    FMT_PRICE   = [WL32, 17];  % Q(15,17) for prices 0-10000
    FMT_RATE    = [WL32, 28];  % Q(4,28) for rates/small values
    FMT_PROB    = [WL32, 30];  % Q(2,30) for probabilities 0-1
    FMT_D       = [WL32, 27];  % Q(5,27) for d1, d2
    FMT_LOG     = [WL32, 28];  % Q(4,28) for logarithms
    FMT_SIGMA   = [WL32, 28];  % Q(4,28) for volatility terms
    FMT_DISC    = [WL32, 30];  % Q(2,30) for discount factors
    FMT_ACCUM   = [WL48, 32];  % Q(16,32) for accumulations
    
    % ============================================================
    % Input quantization (Pipeline Stage 0)
    % ============================================================
    S     = fp.create(S_val,     1, FMT_PRICE(1), FMT_PRICE(2));
    K     = fp.create(K_val,     1, FMT_PRICE(1), FMT_PRICE(2));
    T     = fp.create(T_val,     1, FMT_RATE(1),  FMT_RATE(2));
    r     = fp.create(r_val,     1, FMT_RATE(1),  FMT_RATE(2));
    sigma = fp.create(sigma_val, 1, FMT_SIGMA(1), FMT_SIGMA(2));
    
    % Initialize tape for recording (stores value and local partials)
    tape = struct();
    tape.values = {};
    tape.partials = {};  % Each entry: {[parent_indices], [partial_values]}
    tape_idx = 0;
    
    % Record inputs
    tape_idx = tape_idx + 1; tape.values{tape_idx} = S.value;     tape.partials{tape_idx} = {[], []}; % idx 1: S
    tape_idx = tape_idx + 1; tape.values{tape_idx} = K.value;     tape.partials{tape_idx} = {[], []}; % idx 2: K
    tape_idx = tape_idx + 1; tape.values{tape_idx} = T.value;     tape.partials{tape_idx} = {[], []}; % idx 3: T
    tape_idx = tape_idx + 1; tape.values{tape_idx} = r.value;     tape.partials{tape_idx} = {[], []}; % idx 4: r
    tape_idx = tape_idx + 1; tape.values{tape_idx} = sigma.value; tape.partials{tape_idx} = {[], []}; % idx 5: sigma
    
    % ============================================================
    % Pipeline Stage 1: sqrt(T)
    % ============================================================
    sqrt_T = fp.create(sqrt(T.value), 1, FMT_SIGMA(1), FMT_SIGMA(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = sqrt_T.value;
    tape.partials{tape_idx} = {[3], [1/(2*sqrt_T.value)]};  % d(sqrt(T))/dT = 1/(2*sqrt(T))
    
    % ============================================================
    % Pipeline Stage 2: sigma * sqrt(T)
    % ============================================================
    sigma_sqrt_T = fp.mul(sigma, sqrt_T, FMT_SIGMA(1), FMT_SIGMA(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = sigma_sqrt_T.value;
    tape.partials{tape_idx} = {[5, 6], [sqrt_T.value, sigma.value]};
    
    % ============================================================
    % Pipeline Stage 3: S / K
    % ============================================================
    S_over_K = fp.div(S, K, FMT_LOG(1), FMT_LOG(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = S_over_K.value;
    tape.partials{tape_idx} = {[1, 2], [1/K.value, -S.value/(K.value^2)]};
    
    % ============================================================
    % Pipeline Stage 4: ln(S/K)
    % ============================================================
    ln_S_K = fp.create(log(S_over_K.value), 1, FMT_LOG(1), FMT_LOG(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = ln_S_K.value;
    tape.partials{tape_idx} = {[8], [1/S_over_K.value]};
    
    % ============================================================
    % Pipeline Stage 5: sigma^2
    % ============================================================
    sigma_sq = fp.mul(sigma, sigma, FMT_SIGMA(1), FMT_SIGMA(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = sigma_sq.value;
    tape.partials{tape_idx} = {[5, 5], [sigma.value, sigma.value]};  % 2*sigma
    
    % ============================================================
    % Pipeline Stage 6: sigma^2 / 2
    % ============================================================
    half = fp.create(0.5, 1, FMT_RATE(1), FMT_RATE(2));
    sigma_sq_half = fp.mul(sigma_sq, half, FMT_RATE(1), FMT_RATE(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = sigma_sq_half.value;
    tape.partials{tape_idx} = {[10], [0.5]};
    
    % ============================================================
    % Pipeline Stage 7: r + sigma^2/2
    % ============================================================
    r_plus = fp.add(r, sigma_sq_half, FMT_RATE(1), FMT_RATE(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = r_plus.value;
    tape.partials{tape_idx} = {[4, 11], [1.0, 1.0]};
    
    % ============================================================
    % Pipeline Stage 8: (r + sigma^2/2) * T
    % ============================================================
    drift_T = fp.mul(r_plus, T, FMT_LOG(1), FMT_LOG(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = drift_T.value;
    tape.partials{tape_idx} = {[12, 3], [T.value, r_plus.value]};
    
    % ============================================================
    % Pipeline Stage 9: numerator = ln(S/K) + (r+sigma^2/2)*T
    % ============================================================
    num = fp.add(ln_S_K, drift_T, FMT_LOG(1), FMT_LOG(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = num.value;
    tape.partials{tape_idx} = {[9, 13], [1.0, 1.0]};
    
    % ============================================================
    % Pipeline Stage 10: d1 = num / (sigma*sqrt(T))
    % ============================================================
    d1 = fp.div(num, sigma_sqrt_T, FMT_D(1), FMT_D(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = d1.value;
    tape.partials{tape_idx} = {[14, 7], [1/sigma_sqrt_T.value, -num.value/(sigma_sqrt_T.value^2)]};
    
    % ============================================================
    % Pipeline Stage 11: d2 = d1 - sigma*sqrt(T)
    % ============================================================
    d2 = fp.sub(d1, sigma_sqrt_T, FMT_D(1), FMT_D(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = d2.value;
    tape.partials{tape_idx} = {[15, 7], [1.0, -1.0]};
    
    % ============================================================
    % Pipeline Stage 12: -r*T
    % ============================================================
    rT = fp.mul(r, T, FMT_RATE(1), FMT_RATE(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = rT.value;
    tape.partials{tape_idx} = {[4, 3], [T.value, r.value]};
    
    neg_rT = fp.create(-rT.value, 1, FMT_RATE(1), FMT_RATE(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = neg_rT.value;
    tape.partials{tape_idx} = {[17], [-1.0]};
    
    % ============================================================
    % Pipeline Stage 13: exp(-r*T)
    % ============================================================
    discount = fp.create(exp(neg_rT.value), 1, FMT_DISC(1), FMT_DISC(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = discount.value;
    tape.partials{tape_idx} = {[18], [discount.value]};  % d(exp(x))/dx = exp(x)
    
    % ============================================================
    % Pipeline Stage 14: N(d1) and N(d2)
    % ============================================================
    N_d1 = fp.create(my_normcdf(d1.value), 1, FMT_PROB(1), FMT_PROB(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = N_d1.value;
    tape.partials{tape_idx} = {[15], [my_normpdf(d1.value)]};
    
    N_d2 = fp.create(my_normcdf(d2.value), 1, FMT_PROB(1), FMT_PROB(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = N_d2.value;
    tape.partials{tape_idx} = {[16], [my_normpdf(d2.value)]};
    
    % ============================================================
    % Pipeline Stage 15: Price computation
    % ============================================================
    if strcmp(option_type, 'call')
        % V = S*N(d1) - K*exp(-rT)*N(d2)
        S_Nd1 = fp.mul(S, N_d1, FMT_ACCUM(1), FMT_ACCUM(2));
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = S_Nd1.value;
        tape.partials{tape_idx} = {[1, 20], [N_d1.value, S.value]};
        
        K_disc = fp.mul(K, discount, FMT_ACCUM(1), FMT_ACCUM(2));
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = K_disc.value;
        tape.partials{tape_idx} = {[2, 19], [discount.value, K.value]};
        
        K_disc_Nd2 = fp.mul(K_disc, N_d2, FMT_ACCUM(1), FMT_ACCUM(2));
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = K_disc_Nd2.value;
        tape.partials{tape_idx} = {[23, 21], [N_d2.value, K_disc.value]};
        
        price_fp = fp.sub(S_Nd1, K_disc_Nd2, FMT_PRICE(1), FMT_PRICE(2));
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = price_fp.value;
        tape.partials{tape_idx} = {[22, 24], [1.0, -1.0]};
    else
        % V = K*exp(-rT)*N(-d2) - S*N(-d1)
        N_neg_d1 = fp.create(my_normcdf(-d1.value), 1, FMT_PROB(1), FMT_PROB(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = N_neg_d1.value;
    tape.partials{tape_idx} = {[15], [-my_normpdf(d1.value)]};
        
        N_neg_d2 = fp.create(my_normcdf(-d2.value), 1, FMT_PROB(1), FMT_PROB(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = N_neg_d2.value;
    tape.partials{tape_idx} = {[16], [-my_normpdf(d2.value)]};
        
        K_disc = fp.mul(K, discount, FMT_ACCUM(1), FMT_ACCUM(2));
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = K_disc.value;
        tape.partials{tape_idx} = {[2, 19], [discount.value, K.value]};
        
        K_disc_Nnd2 = fp.mul(K_disc, N_neg_d2, FMT_ACCUM(1), FMT_ACCUM(2));
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = K_disc_Nnd2.value;
        tape.partials{tape_idx} = {[24, 23], [N_neg_d2.value, K_disc.value]};
        
        S_Nnd1 = fp.mul(S, N_neg_d1, FMT_ACCUM(1), FMT_ACCUM(2));
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = S_Nnd1.value;
        tape.partials{tape_idx} = {[1, 22], [N_neg_d1.value, S.value]};
        
        price_fp = fp.sub(K_disc_Nnd2, S_Nnd1, FMT_PRICE(1), FMT_PRICE(2));
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = price_fp.value;
        tape.partials{tape_idx} = {[25, 26], [1.0, -1.0]};
    end
    
    % Store tape size
    tape.size = tape_idx;
    tape.output_idx = tape_idx;
    
    % Output
    price = price_fp.value;
    
    % Display results
    fprintf('BS Forward Core (%s):\n', option_type);
    fprintf('  Inputs: S=%.4f, K=%.4f, T=%.4f, r=%.4f, sigma=%.4f\n', ...
        S.value, K.value, T.value, r.value, sigma.value);
    fprintf('  d1=%.6f, d2=%.6f\n', d1.value, d2.value);
    fprintf('  N(d1)=%.6f, N(d2)=%.6f\n', N_d1.value, N_d2.value);
    fprintf('  exp(-rT)=%.6f\n', discount.value);
    fprintf('  Price (fixed-point) = %.6f\n', price);
    fprintf('  Price (reference)   = %.6f\n', ...
        bs_reference_price(S_val, K_val, T_val, r_val, sigma_val, option_type));
    fprintf('  Tape size: %d entries\n', tape.size);
end

function ref_price = bs_reference_price(S, K, T, r, sigma, option_type)
    % Floating-point reference price
    d1 = (log(S/K) + (r + 0.5*sigma^2)*T) / (sigma*sqrt(T));
    d2 = d1 - sigma*sqrt(T);
    if strcmp(option_type, 'call')
        ref_price = S*my_normcdf(d1) - K*exp(-r*T)*my_normcdf(d2);
    else
        ref_price = K*exp(-r*T)*my_normcdf(-d2) - S*my_normcdf(-d1);
    end
end

function p = my_normcdf(x)
    p = 0.5 * (1 + erf(x / sqrt(2)));
end

function p = my_normpdf(x)
    p = exp(-0.5 * x^2) / sqrt(2 * pi);
end

