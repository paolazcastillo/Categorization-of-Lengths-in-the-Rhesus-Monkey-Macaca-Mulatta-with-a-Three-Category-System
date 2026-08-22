function x = NormInvNoTB(p)
% NORMINVNOTB  Inverse standard-normal CDF without the Statistics Toolbox (erfinv is a
% base MATLAB function). Input is clamped away from 0 and 1 so a rate that
% survived the log-linear correction as exactly degenerate still returns a
% finite value instead of +/-Inf.
% Paola Castillo 2026-07-31
p = min(max(p, eps), 1 - eps);
x = sqrt(2) * erfinv(2 * p - 1);
end