%% run_all.m
% Master script — runs all pipeline tests and generates results.
%
% Usage:
%   run_all

clear; clc;
fprintf('============================================================\n');
fprintf('GREEKS ENGINE — COMPLETE TEST SUITE (MATLAB)\n');
fprintf('============================================================\n\n');

%% ============================================================
%% Test 1: BS Pipeline — Multiple Scenarios
%% ============================================================
fprintf('\n########################################\n');
fprintf('TEST 1: BLACK-SCHOLES PIPELINE\n');
fprintf('########################################\n\n');

bs_scenarios = {
    struct('S',100,'K',105,'T',0.5,'r',0.05,'sigma',0.2,'type','call','label','ATM Call');
    struct('S',100,'K',80,'T',1.0,'r',0.05,'sigma',0.2,'type','call','label','Deep ITM Call');
    struct('S',100,'K',120,'T',1.0,'r',0.05,'sigma',0.2,'type','call','label','Deep OTM Call');
    struct('S',100,'K',100,'T',1.0,'r',0.03,'sigma',0.25,'type','put','label','ATM Put');
};

bs_results = {};
for i = 1:length(bs_scenarios)
    sc = bs_scenarios{i};
    fprintf('\n--- Scenario: %s ---\n', sc.label);
    bs_results{i} = bs_top_level(sc.S, sc.K, sc.T, sc.r, sc.sigma, sc.type);
end

%% ============================================================
%% Test 2: Heston Pipeline — Multiple Scenarios
%% ============================================================
fprintf('\n\n########################################\n');
fprintf('TEST 2: HESTON-COS PIPELINE\n');
fprintf('########################################\n\n');

heston_scenarios = {
    struct('S0',100,'K',100,'T',1.0,'r',0.05,'v0',0.04,'kappa',2.0,...
           'theta',0.04,'xi',0.3,'rho',-0.7,'type','call','N',128,...
           'label','ATM, moderate vol');
    struct('S0',100,'K',120,'T',0.5,'r',0.03,'v0',0.09,'kappa',1.5,...
           'theta',0.09,'xi',0.5,'rho',-0.8,'type','call','N',128,...
           'label','OTM, high vol');
    struct('S0',100,'K',80,'T',2.0,'r',0.04,'v0',0.01,'kappa',3.0,...
           'theta',0.04,'xi',0.4,'rho',-0.6,'type','call','N',128,...
           'label','ITM, long maturity');
};

heston_results = {};
for i = 1:length(heston_scenarios)
    sc = heston_scenarios{i};
    fprintf('\n--- Scenario: %s ---\n', sc.label);
    heston_results{i} = heston_top_level(sc.S0, sc.K, sc.T, sc.r, sc.v0, ...
        sc.kappa, sc.theta, sc.xi, sc.rho, sc.type, sc.N);
end

%% ============================================================
%% Test 3: Fixed-Point Error Analysis
%% ============================================================
fprintf('\n\n########################################\n');
fprintf('TEST 3: FIXED-POINT ERROR ANALYSIS\n');
fprintf('########################################\n\n');

fprintf('BS Pipeline Precision Summary:\n');
fprintf('%-30s %12s\n', 'Scenario', 'Max Error');
fprintf('%s\n', repmat('-', 1, 42));
for i = 1:length(bs_results)
    fprintf('%-30s %12.2e\n', bs_scenarios{i}.label, bs_results{i}.max_error);
end

fprintf('\n\n============================================================\n');
fprintf('ALL TESTS COMPLETE\n');
fprintf('============================================================\n');
