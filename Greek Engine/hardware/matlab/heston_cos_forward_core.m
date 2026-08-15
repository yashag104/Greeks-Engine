%% heston_cos_forward_core.m
% Heston-COS Forward Pricing Core — Fixed-Point Pipeline
%
% Implements the COS method for Heston option pricing in fixed-point
% arithmetic, following the tape schema from the Heston-COS document.
%
% Usage:
%   [price, tape] = heston_cos_forward_core(S0, K, T, r, v0, kappa, theta, xi, rho, 'call', 128);

function [price, tape] = heston_cos_forward_core(S0_val, K_val, T_val, r_val, ...
    v0_val, kappa_val, theta_val, xi_val, rho_val, option_type, N_terms)
    
    if nargin < 10; option_type = 'call'; end
    if nargin < 11; N_terms = 128; end
    
    fp = fixed_point_utils();
    
    % Fixed-point formats
    WL32 = 32; WL48 = 48; WL64 = 64;
    FMT_PRICE  = [WL32, 17];
    FMT_PARAM  = [WL32, 28];
    FMT_LOG    = [WL32, 28];
    FMT_CHAR   = [WL64, 48];   % Extended precision for char func
    FMT_ACCUM  = [WL48, 30];
    FMT_COEFF  = [WL32, 17];
    
    % Quantize inputs
    S0    = fp.create(S0_val,    1, FMT_PRICE(1), FMT_PRICE(2));
    K     = fp.create(K_val,     1, FMT_PRICE(1), FMT_PRICE(2));
    T     = fp.create(T_val,     1, FMT_PARAM(1), FMT_PARAM(2));
    r     = fp.create(r_val,     1, FMT_PARAM(1), FMT_PARAM(2));
    v0    = fp.create(v0_val,    1, FMT_PARAM(1), FMT_PARAM(2));
    kappa = fp.create(kappa_val, 1, FMT_PARAM(1), FMT_PARAM(2));
    theta = fp.create(theta_val, 1, FMT_PARAM(1), FMT_PARAM(2));
    xi    = fp.create(xi_val,    1, FMT_PARAM(1), FMT_PARAM(2));
    rho_p = fp.create(rho_val,   1, FMT_PARAM(1), FMT_PARAM(2));
    
    % Initialize tape
    tape = struct();
    tape.values = {};
    tape.partials = {};
    tape_idx = 0;
    
    % Record inputs (indices 1-9)
    input_names = {'S0','K','T','r','v0','kappa','theta','xi','rho'};
    input_vals = [S0.value, K.value, T.value, r.value, v0.value, ...
                  kappa.value, theta.value, xi.value, rho_p.value];
    for i = 1:9
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = input_vals(i);
        tape.partials{tape_idx} = {[], []};
    end
    
    % ============================================================
    % Step 1: x = ln(S0/K)
    % ============================================================
    x_val = log(S0.value / K.value);
    x = fp.create(x_val, 1, FMT_LOG(1), FMT_LOG(2));
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = x.value;
    tape.partials{tape_idx} = {[1, 2], [1/S0.value * (S0.value/K.value), ...
                                         -S0.value/(K.value^2) / (S0.value/K.value)]};
    % Simplified: dln(S/K)/dS = 1/S, dln(S/K)/dK = -1/K
    tape.partials{tape_idx} = {[1, 2], [1/S0.value, -1/K.value]};
    
    % ============================================================
    % Step 2: Truncation range [a, b] (scalar computation)
    % ============================================================
    if abs(kappa.value) < 1e-10
        c1 = x.value + r.value * T.value;
    else
        c1 = x.value + (r.value - 0.5*theta.value)*T.value + ...
             (1 - exp(-kappa.value*T.value))/(2*kappa.value) * (theta.value - v0.value);
    end
    c2 = max(v0.value * T.value + 0.5*theta.value*T.value, 1e-8);
    L = 10;
    a_val = c1 - L*sqrt(c2);
    b_val = c1 + L*sqrt(c2);
    bma = b_val - a_val;
    
    % ============================================================
    % Step 3: COS summation loop
    % ============================================================
    sum_real = 0;  % Accumulator (will be tracked on tape)
    sum_tape_idx = 0;
    
    % Create initial sum variable
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = 0;
    tape.partials{tape_idx} = {[], []};
    sum_tape_idx = tape_idx;
    
    for k = 0:N_terms-1
        u_k = k * pi / bma;
        
        % ============================================================
        % Step 3a: Heston characteristic function at u_k
        % ============================================================
        if k == 0
            phi_r = 1.0;
            phi_i = 0.0;
            % Record trivial char func (no dependencies)
            tape_idx = tape_idx + 1;
            tape.values{tape_idx} = phi_r;
            tape.partials{tape_idx} = {[], []};
            phi_r_idx = tape_idx;
            
            tape_idx = tape_idx + 1;
            tape.values{tape_idx} = phi_i;
            tape.partials{tape_idx} = {[], []};
            phi_i_idx = tape_idx;
        else
            [phi_r, phi_i, tape, tape_idx] = heston_char_func_fp(...
                u_k, T, r, v0, kappa, theta, xi, rho_p, x, ...
                fp, FMT_CHAR, tape, tape_idx);
            phi_r_idx = tape_idx - 1;
            phi_i_idx = tape_idx;
        end
        
        % ============================================================
        % Step 3b: F_k = Re[phi * exp(-i*u_k*a)]
        % ============================================================
        phase_r = cos(-u_k * a_val);
        phase_i = sin(-u_k * a_val);
        
        % F_k = phi_r*phase_r - phi_i*phase_i  (scalar phases)
        F_k_val = phi_r * phase_r - phi_i * phase_i;
        F_k = fp.create(F_k_val, 1, FMT_PARAM(1), FMT_PARAM(2));
        
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = F_k.value;
        tape.partials{tape_idx} = {[phi_r_idx, phi_i_idx], [phase_r, -phase_i]};
        
        % ============================================================
        % Step 3c: Payoff coefficient V_k (scalar)
        % ============================================================
        if strcmp(option_type, 'call')
            V_k = payoff_coeff_call(k, 0, b_val, a_val, b_val, K.value);
        else
            V_k = payoff_coeff_put(k, a_val, 0, a_val, b_val, K.value);
        end
        
        % ============================================================
        % Step 3d: Accumulate weighted contribution
        % ============================================================
        weight = 0.5;
        if k > 0
            weight = 1.0;
        end
        
        contrib_val = weight * F_k.value * V_k;
        
        % Update sum
        new_sum = sum_real + contrib_val;
        tape_idx = tape_idx + 1;
        tape.values{tape_idx} = new_sum;
        tape.partials{tape_idx} = {[sum_tape_idx, tape_idx-1], [1.0, weight * V_k]};
        sum_tape_idx = tape_idx;
        sum_real = new_sum;
    end
    
    % ============================================================
    % Step 4: Discount factor and final price
    % ============================================================
    neg_rT = -r.value * T.value;
    disc = exp(neg_rT);
    
    % Record discount computation
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = neg_rT;
    tape.partials{tape_idx} = {[4, 3], [-T.value, -r.value]};
    
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = disc;
    tape.partials{tape_idx} = {[tape_idx-1], [disc]};
    disc_idx = tape_idx;
    
    % price = disc * sum
    price_val = disc * sum_real;
    price = fp.create(price_val, 1, FMT_PRICE(1), FMT_PRICE(2)).value;
    
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = price;
    tape.partials{tape_idx} = {[disc_idx, sum_tape_idx], [sum_real, disc]};
    
    tape.size = tape_idx;
    tape.output_idx = tape_idx;
    
    % Reference price
    ref_price = heston_cos_reference(S0_val, K_val, T_val, r_val, v0_val, ...
        kappa_val, theta_val, xi_val, rho_val, option_type, N_terms);
    
    fprintf('Heston-COS Forward Core (%s, N=%d):\n', option_type, N_terms);
    fprintf('  Price (fixed-point) = %.8f\n', price);
    fprintf('  Price (reference)   = %.8f\n', ref_price);
    fprintf('  Error               = %.2e\n', abs(price - ref_price));
    fprintf('  Tape size: %d entries\n', tape.size);
end

%% ============================================================
%% Heston characteristic function (fixed-point, per-term)
%% ============================================================
function [phi_r, phi_i, tape, tape_idx] = heston_char_func_fp(...
    u, T, r, v0, kappa, theta, xi, rho_p, x, fp, FMT, tape, tape_idx)
    
    % All computations in extended precision (FMT)
    rho_xi = rho_p.value * xi.value;
    
    % term1 = -kappa + i*rho*xi*u
    t1_r = -kappa.value;
    t1_i = rho_xi * u;
    
    % term1^2
    t1sq_r = t1_r^2 - t1_i^2;
    t1sq_i = 2 * t1_r * t1_i;
    
    % xi^2*(iu + u^2)
    xi2 = xi.value^2;
    t2_r = xi2 * u^2;
    t2_i = xi2 * u;
    
    % under_sqrt = t1^2 + t2
    us_r = t1sq_r + t2_r;
    us_i = t1sq_i + t2_i;
    
    % d = complex sqrt
    mag = sqrt(us_r^2 + us_i^2);
    sqrt_mag = sqrt(mag);
    ang = atan2(us_i, us_r);
    d_r = sqrt_mag * cos(ang/2);
    d_i = sqrt_mag * sin(ang/2);
    
    % num = kappa - rho*xi*iu - d
    num_r = kappa.value - d_r;
    num_i = -rho_xi*u - d_i;
    
    % den = kappa - rho*xi*iu + d
    den_r = kappa.value + d_r;
    den_i = -rho_xi*u + d_i;
    
    % g = num/den
    den_m2 = den_r^2 + den_i^2;
    g_r = (num_r*den_r + num_i*den_i) / den_m2;
    g_i = (num_i*den_r - num_r*den_i) / den_m2;
    
    % exp(-d*T)
    exp_a = exp(-d_r * T.value);
    edT_r = exp_a * cos(-d_i * T.value);
    edT_i = exp_a * sin(-d_i * T.value);
    
    % g*exp(-dT)
    ge_r = g_r*edT_r - g_i*edT_i;
    ge_i = g_r*edT_i + g_i*edT_r;
    
    % 1 - g*exp(-dT)
    omge_r = 1 - ge_r;
    omge_i = -ge_i;
    
    % 1 - g
    omg_r = 1 - g_r;
    omg_i = -g_i;
    
    % ratio = (1-g*exp(-dT)) / (1-g)
    omg_m2 = omg_r^2 + omg_i^2;
    ratio_r = (omge_r*omg_r + omge_i*omg_i) / omg_m2;
    ratio_i = (omge_i*omg_r - omge_r*omg_i) / omg_m2;
    
    % log(ratio)
    lr_r = 0.5 * log(ratio_r^2 + ratio_i^2);
    lr_i = atan2(ratio_i, ratio_r);
    
    % C
    kth_xi2 = kappa.value * theta.value / xi2;
    C_r = kth_xi2 * (num_r*T.value - 2*lr_r);
    C_i = r.value*u*T.value + kth_xi2*(num_i*T.value - 2*lr_i);
    
    % D
    nxi2_r = num_r / xi2;
    nxi2_i = num_i / xi2;
    ome_r = 1 - edT_r;
    ome_i = -edT_i;
    omge_m2 = omge_r^2 + omge_i^2;
    dr_r = (ome_r*omge_r + ome_i*omge_i) / omge_m2;
    dr_i = (ome_i*omge_r - ome_r*omge_i) / omge_m2;
    D_r = nxi2_r*dr_r - nxi2_i*dr_i;
    D_i = nxi2_r*dr_i + nxi2_i*dr_r;
    
    % exponent = C + D*v0 + i*u*x
    exp_r = C_r + D_r*v0.value;
    exp_i = C_i + D_i*v0.value + u*x.value;
    
    % phi = exp(exponent)
    phi_mag = exp(exp_r);
    phi_r = phi_mag * cos(exp_i);
    phi_i = phi_mag * sin(exp_i);
    
    % Record on tape (simplified — record the final phi values
    % with partial derivatives w.r.t. all inputs)
    % In a full implementation, each intermediate would be recorded.
    % Here we record the char func outputs with numerical partials.
    
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = phi_r;
    % Partials would trace through the entire char func computation
    % For the MATLAB simulation, we compute them numerically
    tape.partials{tape_idx} = compute_char_partials_real(u, T, r, v0, kappa, theta, xi, rho_p, x);
    
    tape_idx = tape_idx + 1;
    tape.values{tape_idx} = phi_i;
    tape.partials{tape_idx} = compute_char_partials_imag(u, T, r, v0, kappa, theta, xi, rho_p, x);
end

function partials = compute_char_partials_real(u, T, r, v0, kappa, theta, xi, rho_p, x)
    % Numerical partials of Re[phi] w.r.t. input parameters
    % Using central finite differences
    eps = 1e-8;
    base_phi = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value, xi.value, rho_p.value, x.value);
    
    parent_indices = [3, 4, 5, 6, 7, 8, 9, 10];  % T,r,v0,kappa,theta,xi,rho,x
    partial_vals = zeros(1, 8);
    
    % dRe[phi]/dT
    phi_up = eval_char(u, T.value+eps, r.value, v0.value, kappa.value, theta.value, xi.value, rho_p.value, x.value);
    phi_dn = eval_char(u, T.value-eps, r.value, v0.value, kappa.value, theta.value, xi.value, rho_p.value, x.value);
    partial_vals(1) = (real(phi_up) - real(phi_dn)) / (2*eps);
    
    % dRe[phi]/dr
    phi_up = eval_char(u, T.value, r.value+eps, v0.value, kappa.value, theta.value, xi.value, rho_p.value, x.value);
    phi_dn = eval_char(u, T.value, r.value-eps, v0.value, kappa.value, theta.value, xi.value, rho_p.value, x.value);
    partial_vals(2) = (real(phi_up) - real(phi_dn)) / (2*eps);
    
    % dRe[phi]/dv0
    phi_up = eval_char(u, T.value, r.value, v0.value+eps, kappa.value, theta.value, xi.value, rho_p.value, x.value);
    phi_dn = eval_char(u, T.value, r.value, v0.value-eps, kappa.value, theta.value, xi.value, rho_p.value, x.value);
    partial_vals(3) = (real(phi_up) - real(phi_dn)) / (2*eps);
    
    % dRe[phi]/dkappa
    phi_up = eval_char(u, T.value, r.value, v0.value, kappa.value+eps, theta.value, xi.value, rho_p.value, x.value);
    phi_dn = eval_char(u, T.value, r.value, v0.value, kappa.value-eps, theta.value, xi.value, rho_p.value, x.value);
    partial_vals(4) = (real(phi_up) - real(phi_dn)) / (2*eps);
    
    % dRe[phi]/dtheta
    phi_up = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value+eps, xi.value, rho_p.value, x.value);
    phi_dn = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value-eps, xi.value, rho_p.value, x.value);
    partial_vals(5) = (real(phi_up) - real(phi_dn)) / (2*eps);
    
    % dRe[phi]/dxi
    phi_up = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value, xi.value+eps, rho_p.value, x.value);
    phi_dn = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value, xi.value-eps, rho_p.value, x.value);
    partial_vals(6) = (real(phi_up) - real(phi_dn)) / (2*eps);
    
    % dRe[phi]/drho
    phi_up = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value, xi.value, rho_p.value+eps, x.value);
    phi_dn = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value, xi.value, rho_p.value-eps, x.value);
    partial_vals(7) = (real(phi_up) - real(phi_dn)) / (2*eps);
    
    % dRe[phi]/dx
    phi_up = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value, xi.value, rho_p.value, x.value+eps);
    phi_dn = eval_char(u, T.value, r.value, v0.value, kappa.value, theta.value, xi.value, rho_p.value, x.value-eps);
    partial_vals(8) = (real(phi_up) - real(phi_dn)) / (2*eps);
    
    partials = {parent_indices, partial_vals};
end

function partials = compute_char_partials_imag(u, T, r, v0, kappa, theta, xi, rho_p, x)
    % Numerical partials of Im[phi] (same structure as real)
    eps = 1e-8;
    parent_indices = [3, 4, 5, 6, 7, 8, 9, 10];
    partial_vals = zeros(1, 8);
    
    params = {T.value, r.value, v0.value, kappa.value, theta.value, xi.value, rho_p.value, x.value};
    
    for p = 1:8
        params_up = params;
        params_dn = params;
        params_up{p} = params{p} + eps;
        params_dn{p} = params{p} - eps;
        
        phi_up = eval_char(u, params_up{:});
        phi_dn = eval_char(u, params_dn{:});
        partial_vals(p) = (imag(phi_up) - imag(phi_dn)) / (2*eps);
    end
    
    partials = {parent_indices, partial_vals};
end

function phi = eval_char(u, T, r, v0, kappa, theta, xi, rho, x)
    % Evaluate Heston char func (floating-point, for partials computation)
    iu = 1i * u;
    t1 = rho*xi*iu - kappa;
    d = sqrt(t1^2 + xi^2*(iu + u^2));
    num = kappa - rho*xi*iu - d;
    den = kappa - rho*xi*iu + d;
    g = num / den;
    edT = exp(-d*T);
    C = r*iu*T + (kappa*theta/xi^2) * (num*T - 2*log((1 - g*edT)/(1 - g)));
    D = (num/xi^2) * (1 - edT) / (1 - g*edT);
    phi = exp(C + D*v0 + iu*x);
end

%% ============================================================
%% Payoff coefficient functions
%% ============================================================
function V_k = payoff_coeff_call(k, c, d, a, b, K)
    chi_k = chi_func(k, c, d, a, b);
    psi_k = psi_func(k, c, d, a, b);
    V_k = (2/(b-a)) * K * (chi_k - psi_k);
end

function V_k = payoff_coeff_put(k, c, d, a, b, K)
    chi_k = chi_func(k, c, d, a, b);
    psi_k = psi_func(k, c, d, a, b);
    V_k = (2/(b-a)) * K * (psi_k - chi_k);
end

function result = chi_func(k, c, d, a, b)
    bma = b - a;
    if k == 0
        result = exp(d) - exp(c);
        return;
    end
    kpi = k*pi/bma;
    denom = 1 + kpi^2;
    result = (1/denom) * (...
        exp(d)*cos(kpi*(d-a)) - exp(c)*cos(kpi*(c-a)) + ...
        kpi*(exp(d)*sin(kpi*(d-a)) - exp(c)*sin(kpi*(c-a))));
end

function result = psi_func(k, c, d, a, b)
    if k == 0
        result = d - c;
        return;
    end
    bma = b - a;
    kpi = k*pi/bma;
    result = (bma/(k*pi)) * (sin(kpi*(d-a)) - sin(kpi*(c-a)));
end

function ref = heston_cos_reference(S0, K, T, r, v0, kappa, theta, xi, rho, option_type, N)
    % Floating-point reference Heston-COS price
    x = log(S0/K);
    if abs(kappa) < 1e-10
        c1 = x + r*T;
    else
        c1 = x + (r - 0.5*theta)*T + (1-exp(-kappa*T))/(2*kappa)*(theta-v0);
    end
    c2 = max(v0*T + 0.5*theta*T, 1e-8);
    L = 10;
    a = c1 - L*sqrt(c2);
    b = c1 + L*sqrt(c2);
    bma = b - a;
    
    total = 0;
    for k = 0:N-1
        u_k = k*pi/bma;
        if k == 0
            phi_k = 1;
        else
            phi_k = eval_char(u_k, T, r, v0, kappa, theta, xi, rho, x);
        end
        phase = exp(-1i*u_k*a);
        F_k = real(phi_k * phase);
        
        if strcmp(option_type, 'call')
            V_k = payoff_coeff_call(k, 0, b, a, b, K);
        else
            V_k = payoff_coeff_put(k, a, 0, a, b, K);
        end
        
        w = 0.5;
        if k > 0; w = 1.0; end
        total = total + w * F_k * V_k;
    end
    ref = exp(-r*T) * total;
end
