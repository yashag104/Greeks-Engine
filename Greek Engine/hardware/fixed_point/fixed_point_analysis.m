%% fixed_point_analysis.m
% Analyze numeric ranges of all intermediate variables in the BS and
% Heston-COS pricing pipelines to determine optimal fixed-point formats.
%
% This script sweeps over representative parameter ranges and records
% the min/max of every intermediate value. Results inform the bit-width
% budget in bit_width_budget.md.

clear; clc;
fprintf('=== Fixed-Point Range Analysis ===\n\n');

%% Parameter sweep ranges
S_range     = [50, 100, 200, 500, 1000];
K_range     = [50, 100, 200, 500, 1000];
T_range     = [0.01, 0.1, 0.5, 1.0, 2.0, 5.0];
r_range     = [0.0, 0.01, 0.03, 0.05, 0.10];
sigma_range = [0.05, 0.10, 0.20, 0.40, 0.80, 1.50];

% Heston-specific
v0_range    = [0.01, 0.04, 0.09, 0.16, 0.25];
kappa_range = [0.5, 1.0, 2.0, 5.0, 10.0];
theta_range = [0.01, 0.04, 0.09, 0.16];
xi_range    = [0.1, 0.3, 0.5, 0.8, 1.0];
rho_range   = [-0.9, -0.7, -0.5, -0.3, 0.0];

%% ============================================================
%% Part 1: Black-Scholes Range Analysis
%% ============================================================
fprintf('--- Black-Scholes Intermediate Variable Ranges ---\n');

bs_ranges = struct();
fields = {'sqrt_T','sigma_sqrt_T','S_over_K','ln_S_K','d1','d2',...
          'N_d1','N_d2','n_d1','exp_neg_rT','price'};
for i = 1:length(fields)
    bs_ranges.(fields{i}) = [inf, -inf];  % [min, max]
end

for S = S_range
    for K = K_range
        for T = T_range
            for r = r_range
                for sigma = sigma_range
                    sqrt_T = sqrt(T);
                    sigma_sqrt_T = sigma * sqrt_T;
                    S_over_K = S / K;
                    ln_S_K = log(S_over_K);
                    d1 = (ln_S_K + (r + 0.5*sigma^2)*T) / sigma_sqrt_T;
                    d2 = d1 - sigma_sqrt_T;
                    N_d1 = 0.5 * (1 + erf(d1 / sqrt(2)));
                    N_d2 = 0.5 * (1 + erf(d2 / sqrt(2)));
                    n_d1 = exp(-0.5 * d1^2) / sqrt(2 * pi);
                    exp_neg_rT = exp(-r*T);
                    price = S*N_d1 - K*exp_neg_rT*N_d2;

                    vals = struct('sqrt_T',sqrt_T,'sigma_sqrt_T',sigma_sqrt_T,...
                        'S_over_K',S_over_K,'ln_S_K',ln_S_K,'d1',d1,'d2',d2,...
                        'N_d1',N_d1,'N_d2',N_d2,'n_d1',n_d1,...
                        'exp_neg_rT',exp_neg_rT,'price',price);

                    for i = 1:length(fields)
                        f = fields{i};
                        v = vals.(f);
                        bs_ranges.(f)(1) = min(bs_ranges.(f)(1), v);
                        bs_ranges.(f)(2) = max(bs_ranges.(f)(2), v);
                    end
                end
            end
        end
    end
end

fprintf('%-20s %15s %15s %10s\n', 'Variable', 'Min', 'Max', 'Int Bits');
fprintf('%s\n', repmat('-', 1, 60));
for i = 1:length(fields)
    f = fields{i};
    mn = bs_ranges.(f)(1);
    mx = bs_ranges.(f)(2);
    abs_max = max(abs(mn), abs(mx));
    if abs_max > 0
        int_bits = ceil(log2(abs_max)) + 1;  % +1 for sign
    else
        int_bits = 1;
    end
    fprintf('%-20s %15.6f %15.6f %10d\n', f, mn, mx, int_bits);
end

%% ============================================================
%% Part 2: Heston Characteristic Function Range Analysis
%% ============================================================
fprintf('\n--- Heston Characteristic Function Ranges ---\n');

heston_fields = {'rho_xi','term1_real','term1_imag','d_real','d_imag',...
                  'g_real','g_imag','C_real','C_imag','D_real','D_imag',...
                  'phi_real','phi_imag','F_k'};
heston_ranges = struct();
for i = 1:length(heston_fields)
    heston_ranges.(heston_fields{i}) = [inf, -inf];
end

N_terms = 128;

% Sample representative parameters
test_params = {
    struct('S0',100,'K',100,'T',1.0,'r',0.05,'v0',0.04,'kappa',2.0,...
           'theta',0.04,'xi',0.3,'rho',-0.7);
    struct('S0',100,'K',120,'T',0.5,'r',0.03,'v0',0.09,'kappa',1.5,...
           'theta',0.09,'xi',0.5,'rho',-0.8);
    struct('S0',100,'K',80,'T',2.0,'r',0.04,'v0',0.01,'kappa',3.0,...
           'theta',0.04,'xi',0.4,'rho',-0.6);
    struct('S0',50,'K',60,'T',0.5,'r',0.01,'v0',0.16,'kappa',0.5,...
           'theta',0.16,'xi',1.0,'rho',-0.9);
};

for p = 1:length(test_params)
    pm = test_params{p};
    x = log(pm.S0 / pm.K);

    % Truncation range
    c1 = x + (pm.r - 0.5*pm.theta)*pm.T + ...
         (1 - exp(-pm.kappa*pm.T))/(2*pm.kappa) * (pm.theta - pm.v0);
    c2 = max(pm.v0*pm.T + 0.5*pm.theta*pm.T, 1e-8);
    L = 10;
    a = c1 - L*sqrt(c2);
    b = c1 + L*sqrt(c2);
    bma = b - a;

    for k = 1:N_terms
        u = k * pi / bma;

        % Characteristic function internals
        rho_xi = pm.rho * pm.xi;
        term1_r = -pm.kappa;
        term1_i = rho_xi * u;

        t1sq_r = term1_r^2 - term1_i^2;
        t1sq_i = 2 * term1_r * term1_i;

        xi2 = pm.xi^2;
        t2_r = xi2 * u^2;
        t2_i = xi2 * u;

        us_r = t1sq_r + t2_r;
        us_i = t1sq_i + t2_i;

        % complex sqrt
        mag = sqrt(us_r^2 + us_i^2);
        sqrt_mag = sqrt(mag);
        angle = atan2(us_i, us_r);
        d_r = sqrt_mag * cos(angle/2);
        d_i = sqrt_mag * sin(angle/2);

        % num = kappa - rho*xi*iu - d
        num_r = pm.kappa - d_r;
        num_i = -rho_xi*u - d_i;

        % den = kappa - rho*xi*iu + d
        den_r = pm.kappa + d_r;
        den_i = -rho_xi*u + d_i;

        % g = num/den (complex division)
        den_mag2 = den_r^2 + den_i^2;
        g_r = (num_r*den_r + num_i*den_i) / den_mag2;
        g_i = (num_i*den_r - num_r*den_i) / den_mag2;

        % exp(-d*T)
        exp_a = exp(-d_r * pm.T);
        exp_dT_r = exp_a * cos(-d_i * pm.T);
        exp_dT_i = exp_a * sin(-d_i * pm.T);

        % g * exp(-dT)
        ge_r = g_r*exp_dT_r - g_i*exp_dT_i;
        ge_i = g_r*exp_dT_i + g_i*exp_dT_r;

        % 1 - g*exp(-dT)
        omge_r = 1 - ge_r;
        omge_i = -ge_i;

        % 1 - g
        omg_r = 1 - g_r;
        omg_i = -g_i;

        % ratio = omge / omg
        omg_mag2 = omg_r^2 + omg_i^2;
        ratio_r = (omge_r*omg_r + omge_i*omg_i) / omg_mag2;
        ratio_i = (omge_i*omg_r - omge_r*omg_i) / omg_mag2;

        % log(ratio)
        lr_r = 0.5 * log(ratio_r^2 + ratio_i^2);
        lr_i = atan2(ratio_i, ratio_r);

        % C
        kth_xi2 = pm.kappa * pm.theta / xi2;
        numT_r = num_r * pm.T;
        numT_i = num_i * pm.T;
        br_r = numT_r - 2*lr_r;
        br_i = numT_i - 2*lr_i;
        C_r = kth_xi2 * br_r;
        C_i = pm.r*u*pm.T + kth_xi2*br_i;

        % D
        nxi2_r = num_r / xi2;
        nxi2_i = num_i / xi2;
        ome_r = 1 - exp_dT_r;
        ome_i = -exp_dT_i;
        % D_ratio = ome / omge
        omge_mag2 = omge_r^2 + omge_i^2;
        dr_r = (ome_r*omge_r + ome_i*omge_i) / omge_mag2;
        dr_i = (ome_i*omge_r - ome_r*omge_i) / omge_mag2;
        D_r = nxi2_r*dr_r - nxi2_i*dr_i;
        D_i = nxi2_r*dr_i + nxi2_i*dr_r;

        % exponent
        exp_r = C_r + D_r*pm.v0;
        exp_i = C_i + D_i*pm.v0 + u*x;

        % phi
        phi_mag = exp(exp_r);
        phi_r = phi_mag * cos(exp_i);
        phi_i = phi_mag * sin(exp_i);

        % F_k
        phase_r = cos(-u * a);
        phase_i = sin(-u * a);
        F_k = phi_r*phase_r - phi_i*phase_i;

        % Update ranges
        vals = struct('rho_xi',rho_xi,'term1_real',term1_r,'term1_imag',term1_i,...
            'd_real',d_r,'d_imag',d_i,'g_real',g_r,'g_imag',g_i,...
            'C_real',C_r,'C_imag',C_i,'D_real',D_r,'D_imag',D_i,...
            'phi_real',phi_r,'phi_imag',phi_i,'F_k',F_k);

        for i = 1:length(heston_fields)
            f = heston_fields{i};
            v = vals.(f);
            if isfinite(v)
                heston_ranges.(f)(1) = min(heston_ranges.(f)(1), v);
                heston_ranges.(f)(2) = max(heston_ranges.(f)(2), v);
            end
        end
    end
end

fprintf('\n%-20s %15s %15s %10s\n', 'Variable', 'Min', 'Max', 'Int Bits');
fprintf('%s\n', repmat('-', 1, 60));
for i = 1:length(heston_fields)
    f = heston_fields{i};
    mn = heston_ranges.(f)(1);
    mx = heston_ranges.(f)(2);
    abs_max = max(abs(mn), abs(mx));
    if abs_max > 0
        int_bits = ceil(log2(abs_max)) + 1;
    else
        int_bits = 1;
    end
    fprintf('%-20s %15.6f %15.6f %10d\n', f, mn, mx, int_bits);
end

fprintf('\n=== Analysis Complete ===\n');
fprintf('Use these ranges to verify the bit-width budget in bit_width_budget.md\n');
