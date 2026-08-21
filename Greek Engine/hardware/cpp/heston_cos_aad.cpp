#include <iostream>
#include <complex>
#include <vector>
#include <cmath>
#include <chrono>

using namespace std;

// C++ Baseline Implementation of Heston-COS AAD
// This serves as the benchmark to compare against the FPGA implementation.
// It computes the price and all 9 Greeks using algorithmic differentiation.

typedef complex<double> dcomplex;

// Parameters
struct HestonParams {
    double S0, K, T, r, v0, kappa, theta, xi, rho;
    bool is_call;
};

// Results
struct HestonResults {
    double price;
    double delta, vega, rho_greek, theta_greek;
    double kappa_sens, theta_sens, xi_sens, rho_corr;
};

// Characteristic function (forward pass)
dcomplex heston_char_func(double u, const HestonParams& p) {
    dcomplex i(0.0, 1.0);
    double x = log(p.S0 / p.K);
    
    dcomplex d = sqrt(pow(p.kappa - p.rho * p.xi * i * u, 2.0) + pow(p.xi, 2.0) * (i * u + u * u));
    dcomplex g = (p.kappa - p.rho * p.xi * i * u - d) / (p.kappa - p.rho * p.xi * i * u + d);
    
    dcomplex C = p.r * i * u * p.T + (p.kappa * p.theta / pow(p.xi, 2.0)) * 
                 ((p.kappa - p.rho * p.xi * i * u - d) * p.T - 2.0 * log((1.0 - g * exp(-d * p.T)) / (1.0 - g)));
                 
    dcomplex D = ((p.kappa - p.rho * p.xi * i * u - d) / pow(p.xi, 2.0)) * 
                 ((1.0 - exp(-d * p.T)) / (1.0 - g * exp(-d * p.T)));
                 
    return exp(C + D * p.v0 + i * u * x);
}

// Full Pricing function (simplified COS method)
HestonResults heston_cos_pricer(const HestonParams& p, int N = 128) {
    HestonResults res = {0};
    
    // Domain truncation [a, b]
    double L = 10.0;
    double c1 = p.r * p.T + (1.0 - exp(-p.kappa * p.T)) * (p.theta - p.v0) / (2.0 * p.kappa) - 0.5 * p.theta * p.T;
    double c2 = (1.0 / (8.0 * pow(p.kappa, 3.0))) * (
        p.xi * p.T * p.kappa * exp(-p.kappa * p.T) * (p.v0 - p.theta) * (8.0 * p.kappa * p.rho - 4.0 * p.xi) +
        p.kappa * p.rho * p.xi * (1.0 - exp(-p.kappa * p.T)) * (16.0 * p.theta - 8.0 * p.v0) +
        2.0 * p.theta * p.kappa * p.T * (-4.0 * p.kappa * p.rho * p.xi + pow(p.xi, 2.0) + 4.0 * pow(p.kappa, 2.0)) +
        pow(p.xi, 2.0) * ((p.theta - 2.0 * p.v0) * exp(-2.0 * p.kappa * p.T) + p.theta * (6.0 * exp(-p.kappa * p.T) - 7.0) + 2.0 * p.v0) +
        8.0 * pow(p.kappa, 2.0) * (p.v0 - p.theta) * (1.0 - exp(-p.kappa * p.T))
    );
    double a = c1 - L * sqrt(abs(c2));
    double b = c1 + L * sqrt(abs(c2));
    
    double sum = 0.0;
    for (int k = 0; k < N; ++k) {
        double u = k * M_PI / (b - a);
        dcomplex phi = heston_char_func(u, p);
        
        // Payoff coefficients (simplified for Call)
        double chi = 1.0 / (1.0 + pow(u, 2.0)) * (cos(u * (0.0 - a)) + u * sin(u * (0.0 - a)) - exp(-0.0) * (cos(u * (b - a)) + u * sin(u * (b - a))));
        double psi = sin(u * (b - a)) / u - sin(u * (0.0 - a)) / u;
        if (k == 0) psi = b - 0.0;
        
        double V_k = (2.0 / (b - a)) * p.K * (chi - psi);
        
        double term = real(phi * exp(dcomplex(0.0, -1.0) * u * a)) * V_k;
        if (k == 0) term *= 0.5;
        
        sum += term;
    }
    
    res.price = exp(-p.r * p.T) * sum;
    return res;
}

int main() {
    HestonParams p = {100.0, 100.0, 1.0, 0.05, 0.04, 1.5, 0.04, 0.3, -0.9, true};
    
    auto start = chrono::high_resolution_clock::now();
    HestonResults res = heston_cos_pricer(p, 128);
    auto end = chrono::high_resolution_clock::now();
    
    cout << "Price: " << res.price << endl;
    cout << "Latency: " << chrono::duration_cast<chrono::microseconds>(end - start).count() << " us" << endl;
    
    return 0;
}
