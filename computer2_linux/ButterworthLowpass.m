function [y, applied] = ButterworthLowpass(x, fs, cutoffHz)
% BUTTERWORTHLOWPASS  Zero-phase 2nd-order Butterworth low-pass, applied
% forward and backward (so 4th-order magnitude, exactly zero phase lag).
%
%   INPUT
%     x        : [N x 1] or [N x D] signal, UNIFORMLY sampled (columns
%                filtered independently)
%     fs       : sampling rate of x, Hz
%     cutoffHz : -3 dB cutoff of the single-pass filter, Hz
%
%   OUTPUT
%     y        : same size as x
%     applied  : false when the filter was skipped and y == x (too few
%                samples, or a cutoff at/above Nyquist); so a caller can
%                report honestly instead of assuming filtering happened
%
%   TOOLBOX-FREE on purpose: butter() and filtfilt() are Signal Processing
%   Toolbox, which the rig's MATLAB (R2016b) is not guaranteed to have;
%   same reason NormInvNoTB.m exists here. filter() is core MATLAB.
%
%   DESIGN. Bilinear transform of the normalised 2nd-order Butterworth
%   H(s) = 1/(s^2 + sqrt(2)s + 1), with the cutoff pre-warped by
%   K = tan(pi*fc/fs) so the -3 dB point lands on cutoffHz in the DIGITAL
%   filter, not fc/2-ish above it as a naive s->z substitution gives.
%
%   ZERO PHASE. Filtering forward only would delay the signal by a few ms at
%   this cutoff, fine for a plot, wrong here, where the point is WHEN the
%   velocity/acceleration peak occurs. Running the same filter over the
%   time-reversed output cancels the phase exactly (and squares the
%   magnitude response, hence "4th-order magnitude" above: the effective
%   -3 dB point sits slightly below cutoffHz).
%
%   EDGES. Both passes are seeded with the filter's steady state for a
%   constant input (zi below) and run on a signal extended by odd reflection
%   about each endpoint, the same construction filtfilt uses. Without it,
%   each pass starts from rest and produces a step-response transient at the
%   trace's start and end, precisely where a reach's launch and landing
%   (its largest accelerations) live.
NFACT = 6;   % 3*(filter order) reflected samples per edge, as in filtfilt

y = x;
applied = false;
if isempty(x) || fs <= 0 || cutoffHz <= 0
    return;
end
if cutoffHz >= fs / 2
    return;   % at/above Nyquist there is nothing to remove
end

wasRow = isrow(y);
if wasRow, y = y(:); end
N = size(y, 1);
if N <= NFACT
    % Too short for a valid reflection: leave the trace untouched, and
    % restore the caller's orientation, since a pass-through that silently
    % returned a column for a row input would break arithmetic downstream
    % (a row/column mismatch does not error under implicit expansion, it
    % quietly produces an N x N matrix).
    y = x;
    return;
end

K  = tan(pi * cutoffHz / fs);
nrm = 1 / (1 + sqrt(2) * K + K ^ 2);
b = [K^2, 2 * K^2, K^2] * nrm;
a = [1, 2 * (K^2 - 1) * nrm, (1 - sqrt(2) * K + K^2) * nrm];

% Steady-state initial conditions for a constant input of 1 (transposed
% direct-form II states); scaled by the first sample at each pass below.
zi = (eye(2) - [-a(2) 1; -a(3) 0]) \ [b(2) - a(2) * b(1); b(3) - a(3) * b(1)];

for d = 1:size(y, 2)
    col  = y(:, d);
    pre  = 2 * col(1)   - col(NFACT+1:-1:2);
    post = 2 * col(end) - col(end-1:-1:end-NFACT);
    ext  = [pre; col; post];

    ext = filter(b, a, ext, zi * ext(1));            % forward
    ext = flipud(ext);
    ext = filter(b, a, ext, zi * ext(1));            % backward
    ext = flipud(ext);

    y(:, d) = ext(NFACT+1:end-NFACT);
end

if wasRow, y = y.'; end
applied = true;
end
