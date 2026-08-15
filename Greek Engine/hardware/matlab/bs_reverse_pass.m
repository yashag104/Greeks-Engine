%% bs_reverse_pass.m
% Black-Scholes AAD Reverse Pass — Fixed-Point Pipeline
%
% Takes the tape produced by bs_forward_core and performs the adjoint
% sweep in reverse order, accumulating partial derivatives to compute
% all Greeks in a single backward pass.
%
% This represents the backward pipeline that would run on hardware.
%
% Usage:
%   [price, tape] = bs_forward_core(100, 105, 0.5, 0.05, 0.2, 'call');
%   greeks = bs_reverse_pass(tape);

function greeks = bs_reverse_pass(tape)
    % Get fixed-point utilities
    fp = fixed_point_utils();
    
    % Adjoint format: extended precision for accumulation
    ADJ_WL = 48;
    ADJ_FL = 32;
    
    % Initialize all adjoints to zero
    n = tape.size;
    adjoints = zeros(1, n);
    
    % Seed: adjoint of the output = 1.0
    adjoints(tape.output_idx) = 1.0;
    
    fprintf('\nBS Reverse Pass (AAD Adjoint Sweep):\n');
    fprintf('  Tape size: %d entries\n', n);
    fprintf('  Sweeping backward from entry %d to 1...\n', n);
    
    % ============================================================
    % Reverse sweep: process tape entries in reverse order
    % ============================================================
    for i = n:-1:1
        adj_i = adjoints(i);
        
        if adj_i == 0
            continue;  % Skip zero adjoints (optimization)
        end
        
        parents = tape.partials{i}{1};   % Parent indices
        partials = tape.partials{i}{2};  % Local partial derivatives
        
        % Accumulate: adj[parent] += adj[i] * local_partial
        for j = 1:length(parents)
            parent_idx = parents(j);
            local_partial = partials(j);
            
            % Fixed-point multiply-accumulate
            contribution_fp = fp.create(adj_i * local_partial, 1, ADJ_WL, ADJ_FL);
            adjoints(parent_idx) = adjoints(parent_idx) + contribution_fp.value;
        end
    end
    
    % ============================================================
    % Extract Greeks from adjoints of input variables
    % ============================================================
    % Input indices: 1=S, 2=K, 3=T, 4=r, 5=sigma
    
    greeks.delta = adjoints(1);  % dV/dS
    greeks.strike_sens = adjoints(2);  % dV/dK
    greeks.theta = adjoints(3);  % dV/dT (time-to-maturity)
    greeks.rho = adjoints(4);    % dV/dr
    greeks.vega = adjoints(5);   % dV/dsigma
    
    % ============================================================
    % Display results
    % ============================================================
    fprintf('\n  Greeks (from AAD backward pass, fixed-point):\n');
    fprintf('  %-20s = %12.8f\n', 'Delta (dV/dS)', greeks.delta);
    fprintf('  %-20s = %12.8f\n', 'Vega (dV/dsigma)', greeks.vega);
    fprintf('  %-20s = %12.8f\n', 'Theta (dV/dT)', greeks.theta);
    fprintf('  %-20s = %12.8f\n', 'Rho (dV/dr)', greeks.rho);
    fprintf('  %-20s = %12.8f\n', 'Strike sens (dV/dK)', greeks.strike_sens);
    
    % Store full adjoint vector for debugging
    greeks.all_adjoints = adjoints;
end
