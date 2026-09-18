function [takeoffTime_s, info] = TrialTakeoff(rows, decisionTime, movementEpoch, dropUnindexed)
% TRIALTAKEOFF  Movement takeoff (5 % of peak speed) for ONE attempt, computed
% online the same way the EDA notebooks compute `move_takeoff_ms` offline.
%
%   [takeoffTime_s, info] = TrialTakeoff(rows, decisionTime, movementEpoch, dropUnindexed)
%
%   INPUT
%     rows          N x 5 double: [Time_ms, X_px, Y_px, Epoch, RZ2Idx] --
%                   ONLY this attempt's rows, already restricted to the
%                   epochs the movement export keeps (movementExportEpochs
%                   in CenterOutTask.m: DECISION_TIME + MOVEMENT +
%                   TARGET_HOLD). That is exactly the set of rows the
%                   notebook's TrajectoryDataset(..., move_epochs=MOVE_EPOCHS)
%                   hands to TrajectoryProcessor.process for the trial.
%     decisionTime  DecisionTime_s of this attempt (target-onset ->
%                   leave-center), as written to trial_data_*.csv.
%     movementEpoch TaskEpoch code of the MOVEMENT epoch (EP.MOVEMENT.Value).
%     dropUnindexed true on the rz2adc input path: rows whose RZ2Idx is NaN
%                   (cached / wall-clock-stamped samples) are discarded
%                   first, mirroring the notebook's "rz2adc" pipeline
%                   profile (drop_unindexed_rows = True).
%
%   OUTPUT
%     takeoffTime_s target-onset -> movement takeoff, in seconds. This is
%                   the notebook's TakeoffTime_s:
%                       TakeoffTime_s = DecisionTime_s - takeoff_lead_ms/1000
%                       takeoff_lead_ms = move_onset_ms - move_takeoff_ms
%                   where move_onset_ms is the first MOVEMENT-epoch sample
%                   and move_takeoff_ms the retrospective 5 %-of-peak
%                   takeoff, both measured from the trial's first kept
%                   sample. NaN whenever the notebook would also give NaN
%                   (fewer than 5 samples, no MOVEMENT rows, no motion,
%                   non-increasing grid) or if anything below throws.
%     info          struct with the intermediate values (move_takeoff_ms,
%                   move_onset_ms, takeoff_lead_ms, peak_vel_time_ms,
%                   n_speed_peaks, n_samples, n_replaced, n_duplicate_ts,
%                   under_resolved, butter_applied) for logging/debugging.
%
%   PIPELINE (a 1:1 port of TrajectoryProcessor in the EDA notebooks --
%   keep the two in step; the notebook is the reference):
%     1. sort by Time_ms (stable), drop duplicate timestamps (keep first)
%     2. under-resolved if n < 5 samples -> NaN
%     3. Hampel screen on raw X/Y: half-window 3, 3 sigma, MAD x 1.4826,
%        windows truncated at the edges, flagged samples replaced by the
%        window median
%     4. Kalman (constant-jerk-noise, pos/vel/acc state) forward filter +
%        RTS smoother, meas sigma 2 px, jerk sigma 1e5 px/s^3, no gating
%     5. PCHIP resample onto an 8 ms grid from t0 (last node forced to tN)
%     6. 2nd-order Butterworth 6 Hz, zero-phase (forward-backward) with
%        6-sample odd reflection padding and steady-state initial state
%        (filtfilt-style); skipped when n_grid <= 6
%     7. speed = hypot(diff x, diff y)/dt at the midpoints of the grid
%     8. peak search restricted to speed samples at or before the last
%        MOVEMENT-epoch time; local maxima with prominence >= 15 % of the
%        window maximum (scipy.signal.find_peaks semantics, plateau
%        midpoints); FIRST such peak, else the global maximum
%     9. takeoff = walking BACKWARD from that peak, the first earlier
%        sample still at or above 5 % of the peak speed
%
%   Base MATLAB only (no Signal Processing / Statistics toolboxes): pchip,
%   filter and median are all core functions.
%
%   See also: SaveMovementTrajectory, CenterOutTask

GRID_DT_S                  = 0.008;
CUTOFF_HZ                  = 6.0;
MIN_MOVE_SAMPLES           = 5;
HAMPEL_HALF_WINDOW         = 3;
HAMPEL_N_SIGMA             = 3.0;
HAMPEL_MAD_SCALE           = 1.4826;
KALMAN_MEAS_SIGMA_PX       = 2.0;
KALMAN_JERK_SIGMA_PX_S3    = 1e5;
BUTTER_N_FACT              = 6;
MOVE_SPEED_FRAC            = 0.05;    % the "5 %" takeoff
MULTI_PEAK_PROMINENCE_FRAC = 0.15;

takeoffTime_s = NaN;
info = struct('move_takeoff_ms', NaN, 'move_onset_ms', NaN, 'takeoff_lead_ms', NaN, ...
              'peak_vel_time_ms', NaN, 'n_speed_peaks', 0, 'n_samples', 0, ...
              'n_replaced', 0, 'n_duplicate_ts', 0, 'under_resolved', true, ...
              'butter_applied', false);

try
    if nargin < 4 || isempty(dropUnindexed), dropUnindexed = false; end
    if isempty(rows) || size(rows, 2) < 4
        return;
    end
    if dropUnindexed && size(rows, 2) >= 5
        rows = rows(~isnan(rows(:, 5)), :);
    end
    if isempty(rows)
        return;
    end

    % Movement window from the epoch column of the KEPT rows, before the
    % duplicate-timestamp drop (the notebook reads it off the group too).
    tAll_ms = rows(:, 1);
    mvMask  = rows(:, 4) == movementEpoch;
    if ~any(mvMask)
        return;                                  % no reach -> no takeoff lead
    end
    moveOnsetAbs_ms = min(tAll_ms(mvMask));
    moveEndAbs_ms   = max(tAll_ms(mvMask));

    % 1. stable sort, unique timestamps (first occurrence wins)
    t = tAll_ms / 1000;
    [t, order] = sort(t);                        % MATLAB sort is stable
    xy = rows(order, 2:3);
    [t, keep] = unique(t, 'first');
    xy = xy(keep, :);
    n = numel(t);
    info.n_samples      = n;
    info.n_duplicate_ts = numel(tAll_ms) - n;
    info.under_resolved = n < MIN_MOVE_SAMPLES;
    if info.under_resolved
        return;
    end

    % 3. Hampel screen (vectorised; NaN padding reproduces the truncated
    % edge windows of the reference implementation)
    [screened, nReplaced] = hampelScreen(xy, HAMPEL_HALF_WINDOW, HAMPEL_N_SIGMA, HAMPEL_MAD_SCALE);
    info.n_replaced = nReplaced;

    % 4. Kalman forward + RTS smoother
    stage1 = kalmanSmooth(t, screened, KALMAN_MEAS_SIGMA_PX, KALMAN_JERK_SIGMA_PX_S3);

    % 5. PCHIP onto the fixed grid
    grid = buildGrid(t, GRID_DT_S);
    gridXY = [pchip(t, stage1(:, 1), grid(:)), pchip(t, stage1(:, 2), grid(:))];

    % 6. zero-phase Butterworth
    [gridXY, info.butter_applied] = butterZeroPhase(gridXY, 1 / GRID_DT_S, CUTOFF_HZ, BUTTER_N_FACT);

    % 7. speed at grid midpoints (ms since the trial's first kept sample)
    gridTime_ms = (grid(:) - t(1)) * 1000;
    tS  = gridTime_ms / 1000;
    gdt = diff(tS);
    if isempty(gdt) || any(gdt <= 0)
        return;
    end
    vel   = hypot(diff(gridXY(:, 1)), diff(gridXY(:, 2))) ./ gdt;   % px/s
    tv_ms = (tS(1:end-1) + gdt / 2) * 1000;

    % 8. peak search inside the movement window
    t0_ms         = t(1) * 1000;
    windowEnd_ms  = moveEndAbs_ms - t0_ms;
    moveOnset_ms  = moveOnsetAbs_ms - t0_ms;
    search = tv_ms <= windowEnd_ms;
    if ~any(search), search = true(size(tv_ms)); end
    searchIdx = find(search);
    seg = vel(searchIdx);
    if numel(seg) >= 3 && max(seg) > 0
        localPeaks = findPeaksProminence(seg, MULTI_PEAK_PROMINENCE_FRAC * max(seg));
    else
        localPeaks = [];
    end
    info.n_speed_peaks = max(numel(localPeaks), 1);
    if ~isempty(localPeaks)
        pk = searchIdx(localPeaks(1));           % TAKEOFF_PEAK_CHOICE = "first"
    else
        [~, k] = max(seg);
        pk = searchIdx(k);
    end
    if vel(pk) < 1e-6
        return;
    end

    % 9. walk back to 5 % of that peak
    thr = MOVE_SPEED_FRAC * vel(pk);
    lo = pk;
    while lo > 1 && vel(lo - 1) >= thr
        lo = lo - 1;
    end
    info.move_takeoff_ms  = tv_ms(lo);
    info.move_onset_ms    = moveOnset_ms;
    info.takeoff_lead_ms  = moveOnset_ms - tv_ms(lo);
    winIdx = find(search & ((1:numel(tv_ms))' >= lo));
    [~, kk] = max(vel(winIdx));
    info.peak_vel_time_ms = tv_ms(winIdx(kk));
    takeoffTime_s = decisionTime - info.takeoff_lead_ms / 1000;
catch ME
    fprintf('WARNING: TrialTakeoff failed (%s); TakeoffTime_s = NaN for this trial.\n', ME.message);
    takeoffTime_s = NaN;
end
end

% -------------------------------------------------------------------------
function [cleaned, nReplaced] = hampelScreen(x, h, nSigma, madScale)
[n, d] = size(x);
cleaned = x;
nReplaced = 0;
if n < 3, return; end
w = 2 * h + 1;
for col = 1:d
    s = x(:, col);
    padded = [NaN(h, 1); s; NaN(h, 1)];
    win = zeros(n, w);
    for j = 1:w
        win(:, j) = padded(j:j + n - 1);
    end
    med = median(win, 2, 'omitnan');
    mad = madScale * median(abs(win - med), 2, 'omitnan');
    thr = nSigma * mad;
    bad = mad > 0 & abs(s - med) > thr;
    cleaned(bad, col) = med(bad);
    nReplaced = nReplaced + nnz(bad);
end
end

function smoothed = kalmanSmooth(t, xy, measSigma, jerkSigma)
% Constant-acceleration state [pos; vel; acc] per axis, white-jerk process
% noise; forward filter then Rauch-Tung-Striebel smoother. No innovation
% gate (gate_sigma = inf in every notebook profile), so the covariance
% recursion is shared by both axes and computed once.
n = numel(t);
smoothed = xy;
if n < 3, return; end
r  = measSigma ^ 2;
q  = jerkSigma ^ 2;
dtAll = diff(t(:));
accStd0 = jerkSigma * 20 * median(dtAll);
d  = size(xy, 2);
xf = zeros(3, d, n);  xp = zeros(3, d, n);
pf = zeros(3, 3, n);  pp = zeros(3, 3, n);  fk = zeros(3, 3, n);
dt0 = dtAll(1);
xp(:, :, 1) = [xy(1, :); (xy(2, :) - xy(1, :)) / dt0; zeros(1, d)];
pp(:, :, 1) = diag([r, 2 * r / dt0 ^ 2, accStd0 ^ 2]);
fk(:, :, 1) = eye(3);
for k = 1:n
    if k > 1
        dt = dtAll(k - 1);
        F  = [1, dt, dt ^ 2 / 2; 0, 1, dt; 0, 0, 1];
        Q  = q * [dt ^ 5 / 20, dt ^ 4 / 8, dt ^ 3 / 6; ...
                  dt ^ 4 / 8,  dt ^ 3 / 3, dt ^ 2 / 2; ...
                  dt ^ 3 / 6,  dt ^ 2 / 2, dt];
        fk(:, :, k) = F;
        xp(:, :, k) = F * xf(:, :, k - 1);
        pp(:, :, k) = F * pf(:, :, k - 1) * F' + Q;
    end
    innov = xy(k, :) - xp(1, :, k);              % 1 x d
    s     = pp(1, 1, k) + r;
    gain  = pp(:, 1, k) / s;                     % 3 x 1
    xf(:, :, k) = xp(:, :, k) + gain * innov;
    P = pp(:, :, k) - gain * pp(1, :, k);
    pf(:, :, k) = (P + P') / 2;
end
xs = xf;
for k = n - 1:-1:1
    F = fk(:, :, k + 1);
    C = pf(:, :, k) * F' / pp(:, :, k + 1);
    xs(:, :, k) = xf(:, :, k) + C * (xs(:, :, k + 1) - xp(:, :, k + 1));
end
smoothed = squeeze(xs(1, :, :))';
if size(smoothed, 2) ~= d, smoothed = smoothed'; end
end

function grid = buildGrid(t, dt)
total = t(end) - t(1);
if total < dt
    grid = [t(1), t(end)];
    return;
end
grid = t(1):dt:(t(end) + 1e-12);
if t(end) - grid(end) > dt / 4
    grid(end + 1) = t(end);
else
    grid(end) = t(end);
end
end

function [y, applied] = butterZeroPhase(x, fs, cutoff, nf)
[n, d] = size(x);
y = x;
applied = false;
if n == 0 || fs <= 0 || cutoff <= 0 || cutoff >= fs / 2 || n <= nf
    return;
end
k    = tan(pi * cutoff / fs);
nrm  = 1 / (1 + sqrt(2) * k + k ^ 2);
b    = [k ^ 2, 2 * k ^ 2, k ^ 2] * nrm;
a    = [1, 2 * (k ^ 2 - 1) * nrm, (1 - sqrt(2) * k + k ^ 2) * nrm];
companion = [-a(2), 1; -a(3), 0];
rhs = [b(2) - a(2) * b(1); b(3) - a(3) * b(1)];
zi  = (eye(2) - companion) \ rhs;                % steady-state initial state
for col = 1:d
    s    = x(:, col);
    pre  = 2 * s(1)   - s(nf + 1:-1:2);
    post = 2 * s(end) - s(end - 1:-1:end - nf);
    ext  = [pre; s; post];
    ext  = filter(b, a, ext, zi * ext(1));
    ext  = ext(end:-1:1);
    ext  = filter(b, a, ext, zi * ext(1));
    ext  = ext(end:-1:1);
    y(:, col) = ext(nf + 1:end - nf);
end
applied = true;
end

function peaks = findPeaksProminence(x, minProm)
% scipy.signal.find_peaks(x, prominence=minProm) for a 1-D vector: local
% maxima (plateaus count once, at their midpoint), edges never count, and
% prominence measured against the higher of the two neighbouring bases.
x = x(:);
n = numel(x);
cand = [];
i = 2;
while i < n
    if x(i - 1) < x(i)
        iAhead = i + 1;
        while iAhead < n && x(iAhead) == x(i)
            iAhead = iAhead + 1;
        end
        if x(iAhead) < x(i)
            cand(end + 1) = floor((i + iAhead - 1) / 2); %#ok<AGROW>
        end
        i = iAhead;
    else
        i = i + 1;
    end
end
peaks = [];
for p = cand
    lm = x(p);  i = p;
    while i > 1 && x(i - 1) <= x(p)
        i = i - 1;  lm = min(lm, x(i));
    end
    rm = x(p);  i = p;
    while i < n && x(i + 1) <= x(p)
        i = i + 1;  rm = min(rm, x(i));
    end
    if x(p) - max(lm, rm) >= minProm
        peaks(end + 1) = p; %#ok<AGROW>
    end
end
end
