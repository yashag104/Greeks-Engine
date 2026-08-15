%% heston_reverse_pass.m
% Heston-COS AAD Reverse Pass — Fixed-Point Pipeline
%
% Takes the tape produced by heston_cos_forward_core and performs the
% adjoint sweep in reverse order. Computes all 9 Heston Greeks
% (sensitivities to S0, K, T, r, v0, kappa, theta, xi, rho) in a
% single backward pass.
%
% Usage:
%   [price, tape] = heston_cos_forward_core(100, 100, 1, 0.05, 0.04, 2, 0.04, 0.3, -0.7);
%   greeks = heston_reverse_pass(tape);

function greeks = heston_reverse_pass(tape)
    fp = fixed_point_utils();
    
    % Adjoint format: extended precision
    ADJ_WL = 64;
    ADJ_FL = 48;
    
    % Initialize adjoints
    n = tape.size;
    adjoints = zeros(1, n);
    
    % Seed output
    adjoints(tape.output_idx) = 1.0;
    
    fprintf('\nHeston Reverse Pass (AAD Adjoint Sweep):\n');
    fprintf('  Tape size: %d entries\n', n);
    fprintf('  Sweeping backward...\n');
    
    % Reverse sweep
    for i = n:-1:1
        adj_i = adjoints(i);
        if adj_i == 0
            continue;
        end
        
        parents = tape.partials{i}{1};
        partials = tape.partials{i}{2};
        
        for j = 1:length(parents)
            parent_idx = parents(j);
            local_partial = partials(j);
            
            % Fixed-point multiply-accumulate
            contribution = fp.create(adj_i * local_partial, 1, ADJ_WL, ADJ_FL);
            adjoints(parent_idx) = adjoints(parent_idx) + contribution.value;
        end
    end
    
    % Extract Greeks (input indices: 1=S0, 2=K, 3=T, 4=r, 5=v0,
    %                                6=kappa, 7=theta, 8=xi, 9=rho)
    greeks.delta       = adjoints(1);   % dV/dS0
    greeks.strike_sens = adjoints(2);   % dV/dK
    greeks.T_sens      = adjoints(3);   % dV/dT
    greeks.rho_r       = adjoints(4);   % dV/dr
    greeks.vega_v0     = adjoints(5);   % dV/dv0
    greeks.kappa_sens  = adjoints(6);   % dV/dkappa
    greeks.theta_sens  = adjoints(7);   % dV/dtheta
    greeks.xi_sens     = adjoints(8);   % dV/dxi
    greeks.rho_corr    = adjoints(9);   % dV/drho
    
    fprintf('\n  Heston Greeks (AAD, fixed-point):\n');
    fprintf('  %-25s = %12.8f\n', 'Delta (dV/dS0)',       greeks.delta);
    fprintf('  %-25s = %12.8f\n', 'Vega (dV/dv0)',        greeks.vega_v0);
    fprintf('  %-25s = %12.8f\n', 'Rho (dV/dr)',          greeks.rho_r);
    fprintf('  %-25s = %12.8f\n', 'Kappa sens (dV/dkappa)', greeks.kappa_sens);
    fprintf('  %-25s = %12.8f\n', 'Theta sens (dV/dtheta)', greeks.theta_sens);
    fprintf('  %-25s = %12.8f\n', 'Xi sens (dV/dxi)',     greeks.xi_sens);
    fprintf('  %-25s = %12.8f\n', 'Rho corr (dV/drho)',   greeks.rho_corr);
    
    greeks.all_adjoints = adjoints;
end
