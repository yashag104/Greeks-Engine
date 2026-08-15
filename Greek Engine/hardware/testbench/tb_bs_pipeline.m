%% tb_bs_pipeline.m
% Testbench for the Black-Scholes forward + reverse pipeline.
%
% Validates the fixed-point pipeline against closed-form floating-point
% reference across multiple parameter combinations.
%
% Usage:
%   tb_bs_pipeline

clear; clc;
fprintf('============================================================\n');
fprintf('TESTBENCH: BLACK-SCHOLES PIPELINE\n');
fprintf('============================================================\n\n');

% Test scenarios
scenarios = {
    % S, K, T, r, sigma, type, label
    {100, 105, 0.5, 0.05, 0.2, 'call', 'Standard ATM call'};
    {100, 80,  1.0, 0.05, 0.2, 'call', 'Deep ITM call'};
    {100, 120, 1.0, 0.05, 0.2, 'call', 'Deep OTM call'};
    {50,  50,  0.25,0.01, 0.3, 'call', 'Low-price ATM call'};
    {100, 95,  1.0, 0.03, 0.25,'put',  'Slightly ITM put'};
    {100, 100, 2.0, 0.05, 0.4, 'put',  'High-vol ATM put'};
    {500, 500, 0.1, 0.02, 0.15,'call', 'Short-expiry ATM call'};
    {1000,950, 1.0, 0.04, 0.2, 'call', 'Large-price ITM call'};
};

n_pass = 0;
n_fail = 0;
price_tol = 0.01;       % Absolute price tolerance
greek_tol = 0.001;      % Absolute Greek tolerance

fprintf('%-35s %10s %10s %10s %10s %10s %8s\n', ...
    'Scenario', 'Price Err', 'Delta Err', 'Vega Err', 'Theta Err', 'Rho Err', 'Status');
fprintf('%s\n', repmat('-', 1, 93));

for i = 1:length(scenarios)
    sc = scenarios{i};
    S = sc{1}; K = sc{2}; T = sc{3};
    r = sc{4}; sigma = sc{5};
    opt_type = sc{6}; label = sc{7};
    
    % Suppress output during test
    % Run pipeline
    evalc('result = bs_top_level(S, K, T, r, sigma, opt_type);');
    
    % Check errors
    errs = [
        abs(result.price_fp - result.ref.price), ...
        abs(result.greeks_fp.delta - result.ref.delta), ...
        abs(result.greeks_fp.vega - result.ref.vega), ...
        abs(result.greeks_fp.theta - result.ref.theta), ...
        abs(result.greeks_fp.rho - result.ref.rho), ...
    ];
    
    pass = all(errs(1) < price_tol) && all(errs(2:end) < greek_tol);
    
    if pass
        status = 'PASS';
        n_pass = n_pass + 1;
    else
        status = '** FAIL **';
        n_fail = n_fail + 1;
    end
    
    fprintf('%-35s %10.2e %10.2e %10.2e %10.2e %10.2e %8s\n', ...
        label, errs(1), errs(2), errs(3), errs(4), errs(5), status);
end

fprintf('\n%s\n', repmat('=', 1, 93));
fprintf('Results: %d PASSED, %d FAILED, %d total\n', n_pass, n_fail, n_pass+n_fail);
fprintf('%s\n', repmat('=', 1, 93));

if n_fail == 0
    fprintf('\nAll tests PASSED!\n');
else
    fprintf('\nWARNING: %d test(s) FAILED.\n', n_fail);
    fprintf('Check fixed-point precision budget for failing scenarios.\n');
end
