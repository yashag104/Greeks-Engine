%% heston_top_level.m
% Heston-COS Complete Pipeline — Forward + Reverse (AAD)
%
% Runs the complete Heston pricing and Greeks pipeline:
% 1. Forward pass: Heston-COS price in fixed-point
% 2. Backward pass: all 9 Greeks via AAD
% 3. Compare against bump-and-reprice reference
%
% Usage:
%   heston_top_level();
%   heston_top_level(100, 100, 1, 0.05, 0.04, 2, 0.04, 0.3, -0.7, 'call', 128);

function results = heston_top_level(S0, K, T, r, v0, kappa, theta, xi, rho, option_type, N_terms)
    if nargin < 1;  S0 = 100; end
    if nargin < 2;  K = 100; end
    if nargin < 3;  T = 1.0; end
    if nargin < 4;  r = 0.05; end
    if nargin < 5;  v0 = 0.04; end
    if nargin < 6;  kappa = 2.0; end
    if nargin < 7;  theta = 0.04; end
    if nargin < 8;  xi = 0.3; end
    if nargin < 9;  rho = -0.7; end
    if nargin < 10; option_type = 'call'; end
    if nargin < 11; N_terms = 128; end
    
    fprintf('============================================================\n');
    fprintf('HESTON-COS PIPELINE: FORWARD + REVERSE (AAD)\n');
    fprintf('============================================================\n');
    fprintf('Parameters:\n');
    fprintf('  S0=%.2f, K=%.2f, T=%.4f, r=%.4f\n', S0, K, T, r);
    fprintf('  v0=%.4f, kappa=%.4f, theta=%.4f, xi=%.4f, rho=%.4f\n', ...
        v0, kappa, theta, xi, rho);
    fprintf('  Option: %s, N_terms: %d\n\n', option_type, N_terms);
    
    % ============================================================
    % Step 1: Forward Pass
    % ============================================================
    fprintf('--- FORWARD PASS ---\n');
    [price_fp, tape] = heston_cos_forward_core(S0, K, T, r, v0, kappa, theta, xi, rho, option_type, N_terms);
    
    % ============================================================
    % Step 2: Reverse Pass
    % ============================================================
    fprintf('\n--- REVERSE PASS ---\n');
    greeks_fp = heston_reverse_pass(tape);
    
    % ============================================================
    % Step 3: Bump-and-Reprice Reference
    % ============================================================
    fprintf('\n--- BUMP-AND-REPRICE REFERENCE ---\n');
    ref = heston_bump_reference(S0, K, T, r, v0, kappa, theta, xi, rho, option_type, N_terms);
    
    % ============================================================
    % Step 4: Comparison
    % ============================================================
    fprintf('\n--- COMPARISON ---\n');
    fprintf('%-25s %15s %15s %12s\n', 'Greek', 'AAD (FP)', 'Bump&Reprice', 'Rel.Err');
    fprintf('%s\n', repmat('-', 1, 67));
    
    comparisons = {
        'Price',                price_fp,              ref.price;
        'Delta (dV/dS0)',       greeks_fp.delta,       ref.delta;
        'Vega (dV/dv0)',        greeks_fp.vega_v0,     ref.vega_v0;
        'Rho (dV/dr)',          greeks_fp.rho_r,       ref.rho_r;
        'Kappa sens',           greeks_fp.kappa_sens,  ref.kappa_sens;
        'Theta sens',           greeks_fp.theta_sens,  ref.theta_sens;
        'Xi sens',              greeks_fp.xi_sens,     ref.xi_sens;
        'Rho corr sens',        greeks_fp.rho_corr,    ref.rho_corr;
    };
    
    for i = 1:size(comparisons, 1)
        name = comparisons{i, 1};
        fp_val = comparisons{i, 2};
        ref_val = comparisons{i, 3};
        
        if abs(ref_val) > 1e-10
            rel_err = abs(fp_val - ref_val) / abs(ref_val);
            fprintf('%-25s %15.8f %15.8f %12.4e\n', name, fp_val, ref_val, rel_err);
        else
            abs_err = abs(fp_val - ref_val);
            fprintf('%-25s %15.8f %15.8f %12.4e (abs)\n', name, fp_val, ref_val, abs_err);
        end
    end
    
    fprintf('\nTape size: %d entries\n', tape.size);
    
    results.price = price_fp;
    results.greeks = greeks_fp;
    results.ref = ref;
    results.tape = tape;
end

function ref = heston_bump_reference(S0, K, T, r, v0, kappa, theta, xi, rho, option_type, N)
    % Bump-and-reprice reference Greeks (floating-point)
    eps = 1e-5;
    
    price_fn = @(s,k,t,rr,v,ka,th,x,rh) heston_cos_ref_price(s,k,t,rr,v,ka,th,x,rh,option_type,N);
    
    ref.price = price_fn(S0, K, T, r, v0, kappa, theta, xi, rho);
    
    % Delta
    eS = eps * S0;
    ref.delta = (price_fn(S0+eS,K,T,r,v0,kappa,theta,xi,rho) - ...
                 price_fn(S0-eS,K,T,r,v0,kappa,theta,xi,rho)) / (2*eS);
    
    % Vega (v0)
    ev = eps * max(abs(v0), 0.01);
    ref.vega_v0 = (price_fn(S0,K,T,r,v0+ev,kappa,theta,xi,rho) - ...
                   price_fn(S0,K,T,r,v0-ev,kappa,theta,xi,rho)) / (2*ev);
    
    % Rho (r)
    ref.rho_r = (price_fn(S0,K,T,r+eps,v0,kappa,theta,xi,rho) - ...
                 price_fn(S0,K,T,r-eps,v0,kappa,theta,xi,rho)) / (2*eps);
    
    % Kappa
    ek = eps * max(abs(kappa), 0.1);
    ref.kappa_sens = (price_fn(S0,K,T,r,v0,kappa+ek,theta,xi,rho) - ...
                      price_fn(S0,K,T,r,v0,kappa-ek,theta,xi,rho)) / (2*ek);
    
    % Theta (long-run variance)
    et = eps * max(abs(theta), 0.01);
    ref.theta_sens = (price_fn(S0,K,T,r,v0,kappa,theta+et,xi,rho) - ...
                      price_fn(S0,K,T,r,v0,kappa,theta-et,xi,rho)) / (2*et);
    
    % Xi
    exi = eps * max(abs(xi), 0.01);
    ref.xi_sens = (price_fn(S0,K,T,r,v0,kappa,theta,xi+exi,rho) - ...
                   price_fn(S0,K,T,r,v0,kappa,theta,xi-exi,rho)) / (2*exi);
    
    % Rho_corr
    rho_up = min(rho + eps, 0.999);
    rho_dn = max(rho - eps, -0.999);
    ref.rho_corr = (price_fn(S0,K,T,r,v0,kappa,theta,xi,rho_up) - ...
                    price_fn(S0,K,T,r,v0,kappa,theta,xi,rho_dn)) / (rho_up - rho_dn);
    
    fprintf('  Bump-and-reprice reference computed (8 pricings)\n');
end

function p = heston_cos_ref_price(S0, K, T, r, v0, kappa, theta, xi, rho, option_type, N)
    x = log(S0/K);
    if abs(kappa) < 1e-10
        c1 = x + r*T;
    else
        c1 = x + (r-0.5*theta)*T + (1-exp(-kappa*T))/(2*kappa)*(theta-v0);
    end
    c2 = max(v0*T + 0.5*theta*T, 1e-8);
    L = 10;
    a = c1 - L*sqrt(c2);
    b = c1 + L*sqrt(c2);
    bma = b - a;
    
    total = 0;
    for k = 0:N-1
        u = k*pi/bma;
        if k == 0
            phi = 1;
        else
            iu = 1i*u;
            t1 = rho*xi*iu - kappa;
            d = sqrt(t1^2 + xi^2*(iu+u^2));
            num = kappa - rho*xi*iu - d;
            den = kappa - rho*xi*iu + d;
            g = num/den;
            edT = exp(-d*T);
            C = r*iu*T + (kappa*theta/xi^2)*(num*T - 2*log((1-g*edT)/(1-g)));
            D = (num/xi^2)*(1-edT)/(1-g*edT);
            phi = exp(C + D*v0 + iu*x);
        end
        F = real(phi * exp(-1i*u*a));
        
        if strcmp(option_type, 'call')
            V = payoff_call(k, 0, b, a, b, K);
        else
            V = payoff_put(k, a, 0, a, b, K);
        end
        
        w = 0.5; if k>0; w=1; end
        total = total + w*F*V;
    end
    p = exp(-r*T) * total;
end

function V = payoff_call(k, c, d, a, b, K)
    V = (2/(b-a))*K*(chi_f(k,c,d,a,b) - psi_f(k,c,d,a,b));
end

function V = payoff_put(k, c, d, a, b, K)
    V = (2/(b-a))*K*(psi_f(k,c,d,a,b) - chi_f(k,c,d,a,b));
end

function r = chi_f(k, c, d, a, b)
    bma = b-a;
    if k==0; r = exp(d)-exp(c); return; end
    kp = k*pi/bma;
    den = 1+kp^2;
    r = (1/den)*(exp(d)*cos(kp*(d-a))-exp(c)*cos(kp*(c-a))+...
        kp*(exp(d)*sin(kp*(d-a))-exp(c)*sin(kp*(c-a))));
end

function r = psi_f(k, c, d, a, b)
    if k==0; r = d-c; return; end
    bma = b-a;
    r = (bma/(k*pi))*(sin(k*pi*(d-a)/bma)-sin(k*pi*(c-a)/bma));
end
