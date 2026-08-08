function [y, nReplaced] = HampelFilter(x, halfWindow, nSigma)
% HAMPELFILTER  Sliding-window median (Hampel) outlier screen for a raw
% position trace, applied independently to each column.
%
%   INPUT
%     x          : [N x D] samples (columns screened independently,
%                  typically D = 2 for [X Y])
%     halfWindow : window around sample i is [i-halfWindow, i+halfWindow],
%                  truncated at the ends (default 3 -> 7 samples wide where
%                  the window is complete)
%     nSigma     : a sample deviating from its window median by more than
%                  nSigma scaled-MADs is replaced (default 3)
%
%   OUTPUT
%     y          : [N x D], flagged samples replaced by their window median;
%                  every input instant comes back out, so the caller's t/xy
%                  stay row-aligned
%     nReplaced  : how many samples were replaced (summed over columns),
%                  QC signal for the caller
%
%   TOOLBOX-FREE on purpose: hampel() is Signal Processing Toolbox, which the
%   rig's MATLAB (R2016b) is not guaranteed to have; same reason
%   ButterworthLowpass.m and NormInvNoTB.m exist here. The explicit window
%   loop below is also what makes the MAD a true window statistic: the
%   movmedian-of-deviations shortcut (HampelOutlierDetector.m) measures each
%   deviation against that sample's OWN median rather than against the one
%   median the test is applied about, which is close but not the same test.
%   At per-trial N (tens to a few thousand samples) the loop costs nothing.
%
%   WHY MEDIAN/MAD AND NOT MEAN/STD. A single bad ADC read pulls a mean and
%   inflates a standard deviation, so a mean+std test partly raises the very
%   threshold meant to catch it, the bigger the glitch, the better it hides.
%   Neither the median nor the MAD of a window moves appreciably for one
%   outlying sample in it, so the threshold stays set by the clean neighbours.
%
%   WHY THIS IS SAFE WHERE A DYNAMICS GATE IS NOT. The replacement value is
%   the window's own median (an actual neighbouring measurement, bounded by
%   the local data) so this screen can only ever pull a sample back toward
%   its neighbours. It cannot manufacture a position the trace never visited.
%   That is the difference from rejecting samples inside the Kalman filter
%   (KalmanTrajectorySmoother.m's innovation gate): there, a rejected sample
%   leaves the filter running predict-only, extrapolating the stale
%   constant-acceleration state, and a run of rejections through a real
%   reach's peak curvature overshoots into a velocity/acceleration peak that
%   never happened. This is a position-domain screen with no dynamics model,
%   so it has nothing to extrapolate with.
%
%   MADSCALE = 1.4826 makes the MAD a consistent estimator of the standard
%   deviation under normality, so nSigma reads on the familiar "n sigma"
%   scale. Without it a nominal 3 behaves like ~2 sigma.
%
%   EDGES. The window is simply truncated at the ends, so the first and last
%   halfWindow samples are judged against a one-sided, shorter window. That
%   is the least reliable regime AND it is where a reach's launch sits, and
%   the effect is measurable: on a 525-trial session (median MOVEMENT segment
%   38 samples) 73 % of all replacements fell in those edge regions, which
%   hold only ~16 % of the samples. A one-sided median lags a genuinely steep
%   launch, so some of those are real motion being pulled back, not glitches.
%   It shows up in the reported kinematics as a ~4 % lower median peak
%   velocity than plain 'kalman' mode on the same session (46.1 vs 48.0 cm/s)
% , which is why TrialKinematics.m defaults to 'kalman' and treats this
%   screen as the opt-in for a session with visible single-sample glitches,
%   rather than as the standard path.
MADSCALE = 1.4826;   % MAD -> std-equivalent under normality

if nargin < 2 || isempty(halfWindow)
    halfWindow = 3;    % 7-sample window where it is complete
end
if nargin < 3 || isempty(nSigma)
    nSigma = 3;        % 3-sigma rule of thumb
end

y = x;
nReplaced = 0;
if isempty(x)
    return;
end

wasRow = isrow(y);
if wasRow, y = y(:); end
N = size(y, 1);
halfWindow = max(1, round(halfWindow));
if N < 3
    % Too short for a window to have any neighbours to judge a sample
    % against; leave the trace untouched (and restore the caller's
    % orientation, as ButterworthLowpass.m does, so a pass-through cannot
    % silently turn a row into a column and break arithmetic downstream).
    y = x;
    return;
end

for d = 1:size(y, 2)
    col = y(:, d);
    out = col;
    for i = 1:N
        lo = max(1, i - halfWindow);
        hi = min(N, i + halfWindow);
        % The window is taken from the ORIGINAL column, not from the
        % partially-replaced output: filtering in place would let an early
        % replacement feed the median that judges the next sample, so the
        % screen would slowly drag a genuinely fast stretch toward its own
        % running median instead of testing each sample against what was
        % actually measured around it.
        win = col(lo:hi);
        med = median(win);
        mad = MADSCALE * median(abs(win - med));
        % The mad > 0 guard is not cosmetic: on a perfectly flat stretch (a
        % stationary cursor reading the same value repeatedly) the MAD is
        % exactly 0, the threshold collapses to 0, and ANY nonzero deviation
        % however small would be replaced. Such a window has no local scale
        % to judge its samples against, so they are left alone.
        if mad > 0 && abs(col(i) - med) > nSigma * mad
            out(i)    = med;
            nReplaced = nReplaced + 1;
        end
    end
    y(:, d) = out;
end

if wasRow, y = y.'; end
end
