function [peakVel, meanVel, peakAccel, nSamples] = TrialKinematics(trajBuf, trajN, trialNum, moveEpochs, interpGridDt, cutoffHz, outlierMethod, hampelHalfWindow, hampelNSigma, minMoveSamples, minMoveDurSec)
% TRIALKINEMATICS  Peak/mean cursor speed (px/s) and peak acceleration
% (px/s^2) during one trial's movement-analysis window, from the per-frame
% trajectory buffer (columns: TrialNum, Time, X, Y, Epoch, Block,
% TrialNumInBlock, Attempt).
% NaN when there are fewer than 2 matching samples to differentiate (e.g.
% an early-exit trial that never left the centre), and NaN again when the
% segment is too short to RESOLVE a peak (see the QC guard below).
%
% moveEpochs: scalar OR vector of numeric epoch codes (TaskEpoch.m values)
% to include; a row is used whenever its Epoch column matches ANY of them
% (ismember). CenterOutTask.m currently passes DECISION_TIME+MOVEMENT together
% (its kinematicsEpochs, defined once next to EP so this function and
% SaveMovementTrajectory.m's export always agree on the same window); an
% older/simpler caller can still pass a single code (e.g. EP.MOVEMENT.Value
% alone) to reproduce the original MOVEMENT-only behaviour. See
% CenterOutTask.m's kinematicsEpochs header comment for what changes when
% DECISION_TIME is included: it is mostly near-static centre-hold/decision time,
% not reach time, so folding it in changes meanVel in particular from a
% pure "reach speed" figure into one that also depends on how long the
% subject took to leave the centre.
%
% interpGridDt (seconds, optional, default 0.008): the fixed resampling
% grid used below. MUST match whichever input source actually produced
% trajBuf's samples this session (orgParams.inputSource); 'joystick'
% natively runs at ~125 Hz (~8ms, utilityScripts/measureJoystickNativeRate.m),
% while 'rz2adc' delivers consecutive samples of the RZ2's ~1017 Hz ADC
% (~0.98ms; see computer1_synapse/InitJoystickRelay.m), ~8x finer. CenterOutTask.m derives
% and passes the right value per session's inputSource (see its
% kinematicsGridDt); the 0.008 default here only covers ad-hoc/manual calls
% that omit it, relying on it for a real rz2adc session would resample
% every trial onto a grid ~7x coarser than that source's real resolution.
%
% cutoffHz (optional, default 20): -3 dB cutoff of the Butterworth low-pass
% applied to the resampled position trace before differentiating (see the
% filtering block below). 0 or Inf disables that stage.
%
% outlierMethod (optional, default 'kalman'): how single-sample position
% glitches are handled in STAGE 1, before anything is resampled. Both modes
% leave every later stage identical (pchip onto interpGridDt, low-pass at
% cutoffHz, then differentiate):
%   'kalman' : RTS smoothing only, innovation gate DISABLED (gateSigma=Inf).
%   'hampel' : a Hampel median screen of the raw positions first, then the
%              same gate-disabled RTS smoothing.
% See the STAGE 1 block below for why the gate is off in both.
%
% hampelHalfWindow / hampelNSigma (optional, defaults 3 and 3): window
% half-width and rejection threshold of that median screen, 'hampel' mode
% only; see HampelFilter.m.
%
% minMoveSamples (optional, default 5) and minMoveDurSec (optional, default
% [] = disabled) are the QC guard: a segment with fewer than
% minMoveSamples raw samples, or (when set) spanning less than minMoveDurSec,
% reports peakVel/meanVel/peakAccel as NaN instead of a number. This is the
% fast-but-under-resolved case, not an outlier and not a filter artifact: at
% the joystick path's ~120 Hz effective logging rate (2 samples per 60 Hz
% frame) a ~55 ms velocity peak rests on ~7 samples, so a segment shorter
% than that does not contain enough real measurements to MEASURE a peak
% magnitude; whatever number comes out is set by where the few samples
% happened to land, and no amount of smoothing recovers what was never
% sampled. Same honesty as the peakVel < 1e-6 guard further down (report
% not-observed rather than a misleading value), for the opposite regime.
%
% nSamples (raw count of rows found for this trial matching moveEpochs) is a
% QC signal for the caller: it's how many real measurements back the
% interpolation below, regardless of how it changes peakVel/peakAccel;
% lets the exported CSV be audited per-trial instead of just eyeballing
% magnitudes. It counts rows FOUND, which is also what feeds the smoothing
% below: no stage drops samples (the Hampel screen replaces a flagged
% reading with its window median rather than deleting the instant, and the
% smoother returns an estimate at every input time), so nSamples stays a
% plain measure of raw coverage. It is ALWAYS returned as that raw count,
% including on the QC-guard path above, where it is the very thing that
% explains why the kinematics came back NaN.
%
% Differentiating the raw samples directly isn't comparable across trials:
% a trial with more raw matching samples (e.g. a slower reach, a longer
% DECISION_TIME dwell if that epoch is included, or one that landed on more
% oversampled frames) has more chances to catch both a higher true peak AND
% a noise spike than a trial with few samples, so peakVel/peakAccel would be
% biased by sample count, not just by how the subject actually moved. Fix:
% resample the position trace onto a FIXED interpGridDt grid
% (shape-preserving cubic Hermite; smooth, no overshoot, unlike a plain
% cubic spline) before differentiating, so every trial's velocity/
% acceleration is computed at the SAME effective resolution no matter how
% many raw points fed the interpolation. Plain linear interpolation would
% not fix this: it reproduces the same raw segment slope at every inserted
% point, changing nothing about the peak.
% interpGridDt should match the source's MEASURED native sampling
% resolution, not go finer (see header note above for 'joystick' vs.
% 'rz2adc'), asking pchip to resolve detail where no real measurement
% exists amplifies ordinary reading jitter into velocity/acceleration
% noise (squared for acceleration, a 2nd derivative) even after the
% smoothing stages below have removed glitches and high-frequency noise.
%
% NOTE that this resampling changes only the kinematics REPORTED in
% trial_data_*.csv. It never touches what was recorded: the trajectory
% exports are written straight from trajBuf, every raw sample, with the
% Time_ms this function reads below.
if nargin < 5 || isempty(interpGridDt)
    interpGridDt = 0.008;   % seconds -- fallback only; see header note above
end
if nargin < 6 || isempty(cutoffHz)
    cutoffHz = 20;          % Hz, -3 dB point of the low-pass below
end
if nargin < 7 || isempty(outlierMethod)
    outlierMethod = 'kalman';   % 'kalman' | 'hampel' -- see STAGE 1 below
end
if nargin < 8 || isempty(hampelHalfWindow)
    hampelHalfWindow = 3;   % samples per side, 'hampel' mode only
end
if nargin < 9 || isempty(hampelNSigma)
    hampelNSigma = 3;       % scaled-MADs, 'hampel' mode only
end
if nargin < 10 || isempty(minMoveSamples)
    minMoveSamples = 5;     % raw samples needed to resolve a peak
end
if nargin < 11
    minMoveDurSec = [];     % [] disables the duration half of the QC guard
end
peakVel = nan;  meanVel = nan;  peakAccel = nan;
rows = trajBuf(1:trajN, 1) == trialNum & ismember(trajBuf(1:trajN, 5), moveEpochs);
nSamples = nnz(rows);
if nSamples < 2, return; end

% QC GUARD (sample count); evaluated on the RAW samples, before anything
% is smoothed or resampled, so a segment this thin never reaches the
% differentiation stage to have a number invented for it. Fewer than
% minMoveSamples real measurements cannot resolve the shape of a velocity
% peak (see the header note on the ~120 Hz effective logging rate): the
% reach genuinely happened, it just happened between samples, so report that
% honestly as NaN (not observed) rather than as a magnitude the data does
% not support. nSamples itself is deliberately NOT touched; it is returned
% as the true raw count on this path exactly as on any other, so a
% low-coverage trial stays visible and auditable in the exported CSV instead
% of disappearing into an unexplained NaN.
if nSamples < minMoveSamples, return; end

% trajBuf's Time column is milliseconds since sessionT0 (see
% CenterOutTask.m/CenterInTask.m's trial loop); convert to seconds here,
% once, so every formula below (interpGridDt, gridDt, vel, accel) can stay
% written in seconds exactly as validated, instead of each needing its own
% unit conversion.
[tt, order] = sort(trajBuf(rows, 2) / 1000);
xx = trajBuf(rows, 3);  xx = xx(order);
yy = trajBuf(rows, 4);  yy = yy(order);
[tt, iu] = unique(tt);   % interp1 needs strictly increasing sample points
xx = xx(iu);  yy = yy(iu);
if numel(tt) < 2, return; end

% QC GUARD (duration); the same not-observed logic as the sample-count
% guard above, expressed in time rather than in samples, for a caller that
% would rather set the floor in physical units. Off by default ([]), since
% the sample-count guard is the one that maps directly onto what can be
% resolved; a real reach's DURATION is a property of the subject, not of the
% logging rate, so a floor on it discards data on a different basis.
if ~isempty(minMoveDurSec) && (tt(end) - tt(1)) < minMoveDurSec
    return;
end

% STAGE 1, outlier screen + Kalman (RTS) smoothing of the raw trace,
% BEFORE interpolating. Two problems are handled here, both of which have to
% be dealt with while the samples are still at their real, unevenly spaced
% times:
%   (a) single-sample position glitches (a noisy joystick ADC read; real
%       rig hardware, unlike GetMouse, has no OS-level smoothing). pchip has
%       no protection against a bad knot, and a glitch a few px wide
%       survives interpolation, then gets squared by the acceleration (a 2nd
%       derivative), turning an ~8px blip into a tens-of-thousands-px/s^2
%       "peak" that never happened. outlierMethod = 'hampel' screens these
%       out in the position domain first (see HampelFilter.m).
%   (b) ordinary reading jitter, which a low-pass alone cannot fully take
%       out at these sample counts without also flattening a real launch.
% Why here and not after gridding: the Kalman model is built from each
% step's ACTUAL dt, so it weights a frame-to-frame gap and an 8ms
% oversampled pair correctly, and it uses the measurement-noise scale
% explicitly, both of which are lost once interp1 has manufactured
% evenly-spaced points that all look equally trustworthy.
% X and Y go in as one matrix but are filtered independently (position noise
% on the two ADC axes is uncorrelated; there is no cross-axis coupling to
% preserve), and every input instant comes back out; neither stage deletes
% a sample, so tt/xx/yy stay aligned and no time gap is opened for interp1
% to bridge.
%
% WHY THE INNOVATION GATE IS OFF (gateSigma = Inf) IN BOTH MODES. The gate
% was doing (a)'s job, but it judges a reading against the smoother's own
% constant-acceleration prediction, and a real reach violates that model at
% its peak curvature by more than the gate is wide, during smooth tracking
% the predicted variance S is small, so the gate is only ~16 px. On fast
% trials it therefore rejected 18-58 % of GENUINE samples, and each rejection
% leaves the filter running predict-only, extrapolating a stale state that
% overshoots; after the backward pass, the resample and the differentiation
% that overshoot came out as peak velocities up to ~1716 cm/s (~17 m/s) and
% accelerations near 49 g in trial_data_*.csv, while the median trial stayed
% correct. Disabling the gate collapses that maximum to ~274 cm/s with the
% median unchanged. A median screen is the right tool for (a) instead: it
% replaces a bad sample with a neighbouring measurement rather than with an
% extrapolation, so it cannot fabricate a peak (see HampelFilter.m).
xy = [xx(:), yy(:)];
switch lower(outlierMethod)
    case 'kalman'
        % RTS smoothing alone; glitch handling is left to the smoother's
        % measurement-noise model, which pulls an isolated bad reading most
        % of the way back without a hard reject.
    case 'hampel'
        xy = HampelFilter(xy, hampelHalfWindow, hampelNSigma);
    otherwise
        % Same fallback philosophy as OrgGet.m: an unusable setting must not
        % take a session's kinematics down, but the substitution has to be
        % visible rather than silently applied.
        warning('TrialKinematics:unknownOutlierMethod', ...
            ['Unknown outlierMethod ''%s'' (expected ''kalman'' or ''hampel''). ' ...
            'Using ''kalman'' instead.'], outlierMethod);
end
% measSigmaPx and jerkSigmaPxPerS3 stay at their tuned defaults ([]); only
% the gate is overridden, for the reason set out above.
smoothedXY = KalmanTrajectorySmoother(tt, xy, [], [], Inf);
xx = smoothedXY(:, 1);
yy = smoothedXY(:, 2);

totalDur = tt(end) - tt(1);
if totalDur <= 0, return; end
if totalDur < interpGridDt
    tGrid = [tt(1), tt(end)];   % too short for even 2 grid steps -- use the raw span directly
else
    tGrid = tt(1):interpGridDt:tt(end);
    % Don't drop the tail, but don't append it either if that would create
    % a near-zero-duration final segment (same noise-amplification risk
    % diff() is guarded against everywhere else here), snap the last grid
    % point onto it instead.
    if tt(end) - tGrid(end) > interpGridDt / 4
        tGrid(end + 1) = tt(end);
    else
        tGrid(end) = tt(end);
    end
end

xxGrid = interp1(tt, xx, tGrid, 'pchip');
yyGrid = interp1(tt, yy, tGrid, 'pchip');

% STAGE 2; zero-phase Butterworth low-pass at cutoffHz (default 20 Hz), on
% the UNIFORM grid, which is the first point in this pipeline where a
% frequency-domain filter is even defined (a fixed sampling rate is what a
% cutoff is expressed relative to; the raw samples have none).
% 20 Hz is above the bandwidth of voluntary arm movement (a reach's
% position/velocity profile is essentially spent by ~10 Hz) so the pass
% band keeps the whole real reach, including its launch transient, while
% everything above it is residual jitter that only differentiation would
% amplify (x1 for velocity, and again for acceleration). It also sits well
% under Nyquist for both input sources (125 Hz joystick -> 62.5 Hz; 1017 Hz
% rz2adc -> 508 Hz), so no session runs this filter near its own limit.
% Zero-phase (forward-backward) matters more than the shape here: a causal
% low-pass would delay the trace by a few ms and move WHERE the peak
% velocity/acceleration is reported to occur.
% ButterworthLowpass passes the trace through untouched (rather than
% erroring) when it is too short to reflect-pad; such a trial is already
% flagged to the caller by its low nSamples, so there is nothing extra to
% report here.
gridFs = 1 / interpGridDt;
if cutoffHz > 0 && isfinite(cutoffHz)
    xxGrid = ButterworthLowpass(xxGrid, gridFs, cutoffHz);
    yyGrid = ButterworthLowpass(yyGrid, gridFs, cutoffHz);
end
% The last grid step can be shorter than interpGridDt (the tail snap above),
% so gridFs is nominal for that one sample; diff() below uses the real
% per-step dt regardless.
gridDt = diff(tGrid);
vel = hypot(diff(xxGrid), diff(yyGrid)) ./ gridDt;
peakVel = max(vel);
meanVel = mean(vel);

% With moveEpochs = MOVEMENT only, real net displacement was guaranteed (a
% MOVEMENT epoch runs from leaving the centre to reaching the target), so a
% near-zero interpolated trace meant the reach happened faster than any raw
% sample caught it. With DECISION_TIME included that guarantee no longer holds
% on its own -- DECISION_TIME can itself be near-static -- but the same
% not-observed logic still applies whenever the WHOLE matched segment shows
% essentially zero displacement: report NaN (not observed) rather than a
% misleading 0 (measured stationary).
if peakVel < 1e-6
    peakVel = nan;  meanVel = nan;  return;
end

if numel(vel) >= 2
    tv  = tGrid(1:end-1) + gridDt / 2;   % velocity-sample midpoint times
    dtv = diff(tv);
    accel = diff(vel) ./ dtv;
    peakAccel = max(abs(accel));
end
end
