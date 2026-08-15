%% bs_top_level.m
% Black-Scholes Complete Pipeline — Forward + Reverse (AAD)
%
% Runs the full BS pricing and Greeks pipeline:
% 1. Forward pass: compute price in fixed-point
% 2. Backward pass: compute all Greeks via AAD
% 3. Compare against floating-point reference
%
% Usage:
%   bs_top_level(100, 105, 0.5, 0.05, 0.2, 'call');

function results = bs_top_level(S, K, T, r, sigma, option_type)
    if nargin < 1; S = 100; end
    if nargin < 2; K = 105; end
    if nargin < 3; T = 0.5; end
    if nargin < 4; r = 0.05; end
    if nargin < 5; sigma = 0.2; end
    if nargin < 6; option_type = 'call'; end
    
    fprintf('============================================================\n');
    fprintf('BLACK-SCHOLES PIPELINE: FORWARD + REVERSE (AAD)\n');
    fprintf('============================================================\n');
    fprintf('Parameters: S=%.2f, K=%.2f, T=%.4f, r=%.4f, sigma=%.4f\n', ...
        S, K, T, r, sigma);
    fprintf('Option type: %s\n\n', option_type);
    
    % ============================================================
    % Step 1: Forward Pass (Fixed-Point)
    % ============================================================
    fprintf('--- FORWARD PASS ---\n');
    [price_fp, tape] = bs_forward_core(S, K, T, r, sigma, option_type);
    
    % ============================================================
    % Step 2: Reverse Pass (AAD Greeks, Fixed-Point)
    % ============================================================
    fprintf('\n--- REVERSE PASS ---\n');
    greeks_fp = bs_reverse_pass(tape);
    
    % ============================================================
    % Step 3: Floating-Point Reference
    % ============================================================
    fprintf('\n--- REFERENCE (Floating-Point) ---\n');
    ref = bs_reference_greeks(S, K, T, r, sigma, option_type);
    
    % ============================================================
    % Step 4: Comparison
    % ============================================================
    fprintf('\n--- COMPARISON (Fixed-Point vs Floating-Point) ---\n');
    fprintf('%-20s %15s %15s %12s\n', 'Greek', 'Fixed-Point', 'Reference', 'Error');
    fprintf('%s\n', repmat('-', 1, 62));
    
    comparisons = {
        'Price',    price_fp,           ref.price;
        'Delta',    greeks_fp.delta,    ref.delta;
        'Vega',     greeks_fp.vega,     ref.vega;
        'Theta',    greeks_fp.theta,    ref.theta;
        'Rho',      greeks_fp.rho,      ref.rho;
    };
    
    max_err = 0;
    for i = 1:size(comparisons, 1)
        name = comparisons{i, 1};
        fp_val = comparisons{i, 2};
        ref_val = comparisons{i, 3};
        err = abs(fp_val - ref_val);
        max_err = max(max_err, err);
        
        if abs(ref_val) > 1e-10
            rel_err = err / abs(ref_val);
            fprintf('%-20s %15.8f %15.8f %12.2e (%.1e rel)\n', ...
                name, fp_val, ref_val, err, rel_err);
        else
            fprintf('%-20s %15.8f %15.8f %12.2e\n', ...
                name, fp_val, ref_val, err);
        end
    end
    
    fprintf('\nMax absolute error: %.2e\n', max_err);
    fprintf('Tape entries: %d\n', tape.size);
    
    % Return results
    results.price_fp = price_fp;
    results.greeks_fp = greeks_fp;
    results.ref = ref;
    results.tape = tape;
    results.max_error = max_err;
end

function ref = bs_reference_greeks(S, K, T, r, sigma, option_type)
    % Floating-point closed-form BS Greeks
    sqrt_T = sqrt(T);
    sigma_sqrt_T = sigma * sqrt_T;
    d1 = (log(S/K) + (r + 0.5*sigma^2)*T) / sigma_sqrt_T;
    d2 = d1 - sigma_sqrt_T;
    disc = exp(-r*T);
    n_d1 = my_normpdf(d1);
    
    if strcmp(option_type, 'call')
        ref.price = S*my_normcdf(d1) - K*disc*my_normcdf(d2);
        ref.delta = my_normcdf(d1);
        % Theta as dV/dT (matching AAD convention)
        ref.theta = (S*n_d1*sigma)/(2*sqrt_T) + r*K*disc*my_normcdf(d2);
        ref.rho = K*T*disc*my_normcdf(d2);
    else
        ref.price = K*disc*my_normcdf(-d2) - S*my_normcdf(-d1);
        ref.delta = my_normcdf(d1) - 1;
        ref.theta = (S*n_d1*sigma)/(2*sqrt_T) - r*K*disc*my_normcdf(-d2);
        ref.rho = -K*T*disc*my_normcdf(-d2);
    end
    ref.vega = S*n_d1*sqrt_T;
    ref.gamma = n_d1 / (S*sigma_sqrt_T);
    
    fprintf('  Reference Greeks (floating-point):\n');
    fprintf('  Price = %.8f\n', ref.price);
    fprintf('  Delta = %.8f\n', ref.delta);
    fprintf('  Gamma = %.8f\n', ref.gamma);
    fprintf('  Vega  = %.8f\n', ref.vega);
    fprintf('  Theta = %.8f\n', ref.theta);
    fprintf('  Rho   = %.8f\n', ref.rho);
end

function p = my_normcdf(x)
    p = 0.5 * (1 + erf(x / sqrt(2)));
end

function p = my_normpdf(x)
    p = exp(-0.5 * x^2) / sqrt(2 * pi);
end
