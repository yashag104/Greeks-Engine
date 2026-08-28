%% tb_heston_pipeline.m
% Testbench for the Heston-COS forward + reverse pipeline.
%
% Validates the fixed-point pipeline against bump-and-reprice reference
% across multiple parameter combinations.
%
% Usage:
%   tb_heston_pipeline

clear; clc;
fprintf('============================================================\n');
fprintf('TESTBENCH: HESTON-COS PIPELINE\n');
fprintf('============================================================\n\n');

% Test scenarios
scenarios = {
    % S0, K, T, r, v0, kappa, theta, xi, rho, type, N, label
    {100, 100, 1.0, 0.05, 0.04, 2.0, 0.04, 0.3, -0.7, 'call', 128, 'ATM, baseline'};
    {100, 120, 0.5, 0.03, 0.09, 1.5, 0.09, 0.5, -0.8, 'call', 128, 'OTM, high vol'};
    {100, 80,  2.0, 0.04, 0.01, 3.0, 0.04, 0.4, -0.6, 'call', 128, 'ITM, long mat'};
    {100, 100, 0.25,0.02, 0.04, 2.0, 0.04, 0.2, -0.5, 'call', 128, 'Short expiry'};
    {50,  60,  1.0, 0.01, 0.16, 0.5, 0.16, 1.0, -0.9, 'call', 128, 'High vol-of-vol'};
    {100, 100, 1.0, 0.05, 0.04, 2.0, 0.04, 0.3, -0.7, 'put',  128, 'ATM put'};
};

n_pass = 0;
n_fail = 0;
price_tol = 0.05;       % Absolute price tolerance (looser for Heston)
greek_rel_tol = 0.05;   % 5% relative tolerance for Greeks

fprintf('%-25s %12s %12s %12s %12s %8s\n', ...
    'Scenario', 'Price Err', 'Delta RelErr', 'Vega RelErr', 'Rho RelErr', 'Status');
fprintf('%s\n', repmat('-', 1, 81));

for i = 1:length(scenarios)
    sc = scenarios{i};
    S0 = sc{1}; K = sc{2}; T = sc{3}; r = sc{4};
    v0 = sc{5}; kappa = sc{6}; theta = sc{7};
    xi = sc{8}; rho = sc{9};
    opt_type = sc{10}; N = sc{11}; label = sc{12};
    
    % Run pipeline (suppress output)
    evalc('result = heston_top_level(S0, K, T, r, v0, kappa, theta, xi, rho, opt_type, N);');
    
    % Price error
    price_err = abs(result.price - result.ref.price);
    
    % Relative errors for key Greeks
    if abs(result.ref.delta) > 1e-10
        delta_rerr = abs(result.greeks.delta - result.ref.delta) / abs(result.ref.delta);
    else
        delta_rerr = abs(result.greeks.delta - result.ref.delta);
    end
    
    if abs(result.ref.vega_v0) > 1e-10
        vega_rerr = abs(result.greeks.vega_v0 - result.ref.vega_v0) / abs(result.ref.vega_v0);
    else
        vega_rerr = abs(result.greeks.vega_v0 - result.ref.vega_v0);
    end
    
    if abs(result.ref.rho_r) > 1e-10
        rho_rerr = abs(result.greeks.rho_r - result.ref.rho_r) / abs(result.ref.rho_r);
    else
        rho_rerr = abs(result.greeks.rho_r - result.ref.rho_r);
    end
    
    pass = (price_err < price_tol) && (delta_rerr < greek_rel_tol) && ...
           (vega_rerr < greek_rel_tol) && (rho_rerr < greek_rel_tol);
    
    if pass
        status = 'PASS';
        n_pass = n_pass + 1;
    else
        status = '** FAIL **';
        n_fail = n_fail + 1;
    end
    
    fprintf('%-25s %12.4e %12.4e %12.4e %12.4e %8s\n', ...
        label, price_err, delta_rerr, vega_rerr, rho_rerr, status);
end

fprintf('\n%s\n', repmat('=', 1, 81));
fprintf('Results: %d PASSED, %d FAILED, %d total\n', n_pass, n_fail, n_pass+n_fail);
fprintf('%s\n', repmat('=', 1, 81));

if n_fail == 0
    fprintf('\nAll tests PASSED!\n');
else
    fprintf('\nWARNING: %d test(s) FAILED.\n', n_fail);
end
