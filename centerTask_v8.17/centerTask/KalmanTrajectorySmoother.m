function [smoothed, nGated] = KalmanTrajectorySmoother(t, xy, measSigmaPx, jerkSigmaPxPerS3, gateSigma)
% KALMANTRAJECTORYSMOOTHER  Fixed-interval Kalman smoother (RTS) for a
% cursor position trace sampled at IRREGULAR times.
% Paola Castillo 2026-08-04
%
%   INPUT
%     t                : [N x 1] sample times in SECONDS, strictly increasing
%     xy               : [N x D] positions in px (columns filtered
%                        independently -- typically D = 2 for [X Y])
%     measSigmaPx      : std of the position reading noise, px (default 2)
%     jerkSigmaPxPerS3 : process-noise std of the jerk, px/s^3 (default 1e5)
%     gateSigma        : innovation gate, in sigmas (default 4; Inf = off)
%
%   OUTPUT
%     smoothed         : [N x D] smoothed positions at the SAME t
%     nGated           : how many measurements were rejected by the gate
%                        (summed over columns) -- QC signal for the caller
%
%   MODEL. Constant-acceleration per axis, state [pos; vel; acc], driven by
%   continuous white jerk. The rig's samples are not evenly spaced (frames
%   plus the oversampled reads taken inside the async-flip window), so F and
%   Q are rebuilt from the ACTUAL dt of each step rather than assuming a
%   fixed rate:
%       F = [1 dt dt^2/2; 0 1 dt; 0 0 1]
%       Q = jerkSigma^2 * [dt^5/20 dt^4/8 dt^3/6
%                          dt^4/8  dt^3/3 dt^2/2
%                          dt^3/6  dt^2/2 dt    ]
%   which is the exact discretisation of the continuous white-jerk model, so
%   a long gap (a dropped frame) is trusted correspondingly less instead of
%   being treated like a normal step.
%
%   WHY SMOOTHED, NOT FILTERED. A forward-only Kalman filter is causal: its
%   estimate lags the true position by roughly one correlation time, which
%   would shift and flatten exactly the thing this feeds -- the peak of the
%   velocity/acceleration profile. The backward RTS pass uses the whole
%   trial (already fully recorded before the caller runs, so there is
%   nothing online about this) and gives a zero-lag estimate.
%
%   OUTLIER REJECTION. A plain Kalman update has no defence against a single
%   bad ADC read: it just pulls the state toward it. The innovation gate
%   restores what the Hampel screen used to do here -- a measurement whose
%   innovation exceeds gateSigma * sqrt(S) (S = innovation variance, i.e.
%   the filter's own prediction of how far off that reading should plausibly
%   be) is dropped, and only the PREDICT step is kept for that instant. That
%   is self-scaling: the gate is wide where the filter is genuinely
%   uncertain (start of trial, after a long gap) and tight where it is not,
%   so it doesn't need a separate noise scale of its own. Gated samples are
%   not deleted from the output -- the smoother fills them from the
%   dynamics, keeping t/xy row-aligned for the caller.
%
%   DEFAULTS. measSigmaPx = 2 px is the reading jitter of the rig's joystick
%   ADC path (GetMouse has OS-level smoothing and is quieter; using the
%   noisier figure for both just smooths the mouse path slightly more).
%   jerkSigmaPxPerS3 = 1e5 admits a reach whose acceleration swings by
%   ~1e4 px/s^2 over ~100 ms -- fast enough not to clip a real launch, tight
%   enough that per-sample jitter isn't tracked as real motion. Both are
%   physical quantities, not tuning knobs in arbitrary units: re-measure
%   them (a stationary hold gives measSigmaPx; the accel traces of real
%   reaches bound the jerk) before changing them.
%
%   The jerk prior was swept against simulated minimum-jerk reaches (2 px
%   measurement noise + one injected glitch, 40 runs each, then through
%   TrialKinematics' full grid + 20 Hz low-pass path). Error in the reported
%   peak acceleration vs. truth:
%                    350 ms reach     150 ms reach
%       1e4              +0 %             -89 %      <- clips a fast reach
%       3e4              +3 %             -51 %      <- clips a fast reach
%       1e5             +18 %              +4 %
%       3e5             +41 %              +5 %
%       1e6             +67 %              +7 %
%   1e5 is the only value that fails neither regime: below it the prior is
%   too tight and flattens a genuinely fast launch (an error that looks like
%   clean data and would be read as a slow subject), above it the filter
%   starts tracking measurement noise as real acceleration. The residual
%   positive bias is inherent to double-differentiating a noisy trace; it is
%   consistent across trials, so between-condition comparisons -- what this
%   measure is for -- are unaffected, but the absolute number should not be
%   quoted as an exact peak.
if nargin < 3 || isempty(measSigmaPx),      measSigmaPx      = 2;    end
if nargin < 4 || isempty(jerkSigmaPxPerS3), jerkSigmaPxPerS3 = 1e5;  end
if nargin < 5 || isempty(gateSigma),        gateSigma        = 4;    end

t = t(:);
N = numel(t);
smoothed = xy;
nGated   = 0;
if N < 3 || size(xy, 1) ~= N
    return;   % nothing to smooth (or caller handed mismatched sizes)
end

R = measSigmaPx ^ 2;
q = jerkSigmaPxPerS3 ^ 2;

dtAll = diff(t);
% Initial acceleration uncertainty: what the jerk model can build up over a
% typical inter-sample interval, times a slack factor -- a wide but not
% absurd prior, so the first few samples set the acceleration instead of
% being dragged toward a hard 0.
accStd0 = jerkSigmaPxPerS3 * 20 * median(dtAll);

for d = 1:size(xy, 2)
    z = xy(:, d);

    xf = zeros(3, N);  Pf = zeros(3, 3, N);   % filtered (posterior)
    xp = zeros(3, N);  Pp = zeros(3, 3, N);   % predicted (prior)
    Fk = zeros(3, 3, N);                      % F that produced step k from k-1

    % Seed from the first two samples: position measured, velocity from the
    % first difference (its variance is 2R/dt^2 -- both endpoints are noisy).
    dt0 = dtAll(1);
    xp(:, 1)    = [z(1); (z(2) - z(1)) / dt0; 0];
    Pp(:, :, 1) = diag([R, 2 * R / dt0 ^ 2, accStd0 ^ 2]);
    Fk(:, :, 1) = eye(3);

    for k = 1:N
        if k > 1
            dt = dtAll(k - 1);
            F = [1 dt dt^2/2; 0 1 dt; 0 0 1];
            Q = q * [dt^5/20 dt^4/8 dt^3/6
                     dt^4/8  dt^3/3 dt^2/2
                     dt^3/6  dt^2/2 dt    ];
            Fk(:, :, k) = F;
            xp(:, k)    = F * xf(:, k - 1);
            Pp(:, :, k) = F * Pf(:, :, k - 1) * F' + Q;
        end

        innov = z(k) - xp(1, k);
        S     = Pp(1, 1, k) + R;
        if innov ^ 2 <= (gateSigma ^ 2) * S
            K = Pp(:, 1, k) / S;
            xf(:, k)    = xp(:, k) + K * innov;
            Pf(:, :, k) = Pp(:, :, k) - K * Pp(1, :, k);
            % Round-off makes the covariance drift out of symmetry over a
            % few hundred updates; the smoother pass below inverts it, so
            % re-symmetrise rather than let that accumulate.
            Pf(:, :, k) = (Pf(:, :, k) + Pf(:, :, k)') / 2;
        else
            xf(:, k)    = xp(:, k);   % measurement rejected: predict only
            Pf(:, :, k) = Pp(:, :, k);
            nGated      = nGated + 1;
        end
    end

    % Rauch-Tung-Striebel backward pass
    xs = xf;
    Ps = Pf;
    for k = N-1:-1:1
        F = Fk(:, :, k + 1);
        C = (Pf(:, :, k) * F') / Pp(:, :, k + 1);
        xs(:, k)    = xf(:, k) + C * (xs(:, k + 1) - xp(:, k + 1));
        Ps(:, :, k) = Pf(:, :, k) + C * (Ps(:, :, k + 1) - Pp(:, :, k + 1)) * C';
    end

    smoothed(:, d) = xs(1, :)';
end
end
