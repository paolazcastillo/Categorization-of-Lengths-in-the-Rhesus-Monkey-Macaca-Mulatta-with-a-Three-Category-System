classdef RZ2ClockMap < handle
% RZ2CLOCKMAP  Maps an RZ2 sample index onto THIS machine's GetSecs clock
% with a continuously re-estimated affine model.
%
%     tHat(n) = offset + secPerSample * n
%
% WHY THIS EXISTS. The previous time base anchored once, at the first
% indexed sample of the session, and then advanced by a FIXED constant
% (rz2SampleRateHz). Any error in that constant integrates: a relative rate
% error of eps produces a divergence of eps seconds per second between the
% RZ2 stamps and GetSecs, without bound. On session sessPX-309 (03-Sep-2026)
% the divergence measured 13.7 ms/s (r = 0.9998 against session time,
% n = 33 trials) and reached 3.17 s after four minutes, which is the whole
% of the negative-DecisionTime_s and premature-abort failure: markers taken
% from this clock were being compared against, and subtracted from, markers
% taken from GetSecs.
%
% The constant is now only a SEED. The slope is re-estimated from the data,
% so a wrong seed, a changed 'downsample' on the Synapse side, and ordinary
% crystal drift between the two machines are all absorbed by the same
% mechanism instead of each needing its own correction.
%
% ESTIMATOR. Every drain contributes one observation pair
% (index of the NEWEST sample in the drain, GetSecs at that drain). The
% newest sample is used because it is the least delayed one available: its
% transport latency is the closest to the link's floor.
%
%   slope   : the SEED until the window spans at least minSpanSec of
%             samples, then ordinary least squares over the window, clamped
%             to +-maxRateDev of the seed. OLS is unbiased for the slope
%             even though the observations are contaminated by latency,
%             because the contamination is a level, not a trend, as long
%             as the backlog is stationary -- but unbiased is not precise.
%
%             SEED FIRST (2026-09-05). With the ~150 ms rms arrival jitter
%             this link actually has, the standard error of an OLS slope
%             over a 2 s span is ~5%: for the first seconds of sessPX-509
%             the map ran on a slope that was noise, its timeline wandered
%             at tens of ms per second, and the slew limit cannot correct a
%             SLOPE error (it caps the step at one index, the error
%             re-accumulates over the next batch). The seed is now known to
%             ~+-0.04% from the rig itself, so it is a better slope than
%             anything a short window can produce; the residual 400 ppm and
%             crystal drift are 0.4 ms/s, which the offset anchor tracks
%             trivially. The window earns the right to change the slope
%             only once its span makes the estimate better than the seed.
%
%             A GROWING backlog is the exception, and it is the dangerous
%             one. With t_arr(n) = t_cap(n) + L(n) and L increasing, the
%             fitted slope is 1/f + dL/dn: the map attributes to a slower
%             ADC what is really samples arriving later and later, so its
%             output tracks ARRIVALS instead of captures. trigTime then
%             stays close to sampleTime, the skew monitor sees nothing, and
%             a real backlog becomes invisible -- the precise failure the
%             monitor exists to catch.
%
%             Hence the queueClear gate on addObservation: a drain that did
%             not empty the queue contributes nothing. Those are the
%             observations whose latency is above the floor by an amount
%             that is itself trending, and they are exactly the ones that
%             carry the bias. If the queue never clears, the map simply
%             stops updating, the estimate holds where it was, and the skew
%             grows until the monitor stops the session. Refusing to
%             estimate is the correct response to data that cannot support
%             the estimate.
%   offset  : anchored on a LOW QUANTILE of the window residuals, not on the
%             OLS intercept. The OLS intercept absorbs the MEAN transport
%             latency; a low quantile tracks the fast path, which is the
%             standard minimum-delay idea used in clock synchronisation.
%             This removes the mean-latency bias and leaves only the
%             (unobservable, constant) floor latency of the link.
%
%             A QUANTILE, NOT THE MINIMUM (2026-09-05). The first version
%             used min(). On the rig the link turned out to carry 0-225 ms
%             of arrival jitter (Computer 1's relay loop saturates at ~43 Hz
%             with 225 ms stalls), and min() is maximally sensitive to a
%             single early arrival: one such pair pulled the offset back by
%             up to 166 ms, held it there for the life of the window, and
%             the monotone guard below then froze the output for ~150
%             samples. The 10th percentile ignores the odd early packet and
%             still sits close to the floor.
%
%             OVER ITS OWN, SHORT WINDOW (offsetWindow, default 100), not
%             over the slope window. The slope needs SPAN, so its window is
%             long; the offset needs to SLIDE, so its window is short, and
%             the two must not share one length. On sessPX-509 the 600-
%             observation window never filled (this link yields ~16
%             accepted observations/s, half the frames arrive empty), so
%             the anchor was a running minimum over a growing sample -- a
%             ratchet that pulled the offset back 226 ms in 17 s, inflated
%             the reported skew at 12.6 ms/s, and produced 177 monotone
%             clamps. A window that actually slides cannot ratchet.
%
%   slew    : the line is not allowed to JUMP. Each refit may move the
%             time assigned to the newest index by at most maxSlewSec;
%             beyond that the intercept is pulled back so the move equals
%             the limit, and the rest is applied over later fits. This is
%             how every disciplined clock behaves (a PLL slews, it does not
%             step) and it is what makes the output monotone by
%             construction rather than by clamping. The first fit after
%             warm-up is exempt: it replaces a single-pair anchor and is
%             allowed to snap.
%
% WHAT IS NOT FIXED HERE. The floor latency itself is invisible from this
% side: a link that is uniformly 8 ms slow looks exactly like a link that is
% not. It is a CONSTANT offset, so it cancels in every within-trial
% difference and shifts stimulus-to-response intervals by that fixed amount.
% Measuring it needs a hardware loopback, not more statistics.
%
% USAGE (see ReadRZ2Joystick.m)
%   clk = RZ2ClockMap(939.0024, 600, 0.10);
%   clk.addObservation(idxNewest, GetSecs());
%   t   = clk.indexToTime(idxVector);      % seconds, GetSecs frame
%   s   = clk.summary();                   % health/report struct
%
% See also: ReadRZ2Joystick, SetupRZ2Joystick, ClockSkewMonitor

    properties (SetAccess = private)
        seedSecPerSample        % 1/seed rate, the starting slope and the clamp centre
        secPerSample            % current slope estimate (s per sample)
        offset                  % current intercept, GetSecs frame
        windowLen               % observations kept for the sliding fit
        maxRateDev              % fractional band the slope is clamped to around the seed
        minObs                  % observations required before the first fit
        minSpanSec              % index span the window must cover before the slope may leave the seed
        nSlopeFits              % fits that updated the slope (span condition met)
        offsetQuantile          % residual quantile the offset is anchored on (0 = strict minimum)
        offsetWindow            % most recent observations the offset quantile is taken over
        maxSlewSec              % largest move of t(newest idx) one refit may apply
        nSlewLimited            % refits whose move was cut to maxSlewSec
        nObs                    % observations accepted
        nObsRejected            % observations refused because the queue was not clear
        nFits                   % refits performed
        nSlopeClamped           % fits whose slope hit the clamp
        nMonotoneClamped        % emitted samples pulled forward to stay monotone
        worstMonotoneClamp      % worst such pull, seconds
        residualRms             % rms of the window residuals about the minimum-delay line
    end

    properties (Access = private)
        idxBuf                  % ring buffer of observation indices
        tBuf                    % ring buffer of observation GetSecs readings
        head                    % write position in the ring
        count                   % valid entries in the ring
        anchored                % false until the first observation lands
        lastEmitted             % newest time handed out, for the monotone guard
    end

    methods
        function obj = RZ2ClockMap(seedRateHz, windowLen, maxRateDev, minObs, offsetQuantile, maxSlewSec, offsetWindow, minSpanSec)
            if nargin < 1 || isempty(seedRateHz) || ~isfinite(seedRateHz) || seedRateHz <= 0
                error('RZ2ClockMap:badSeed', ...
                    'A positive, finite seed sample rate is required (got %g).', seedRateHz);
            end
            if nargin < 2 || isempty(windowLen), windowLen = 600; end
            if nargin < 3 || isempty(maxRateDev), maxRateDev = 0.01; end
            if nargin < 4 || isempty(minObs), minObs = 30; end
            if nargin < 5 || isempty(offsetQuantile), offsetQuantile = 0.10; end
            if nargin < 6 || isempty(maxSlewSec), maxSlewSec = 0.002; end
            if nargin < 7 || isempty(offsetWindow), offsetWindow = 100; end
            if nargin < 8 || isempty(minSpanSec), minSpanSec = 30; end

            obj.seedSecPerSample   = 1 / seedRateHz;
            obj.secPerSample       = 1 / seedRateHz;
            obj.offset             = NaN;
            obj.windowLen          = max(round(windowLen), 2);
            obj.maxRateDev         = abs(maxRateDev);
            obj.minObs             = max(round(minObs), 2);
            obj.offsetQuantile     = min(max(offsetQuantile, 0), 0.5);
            obj.maxSlewSec         = abs(maxSlewSec);
            obj.offsetWindow       = max(round(offsetWindow), 2);
            obj.minSpanSec         = abs(minSpanSec);
            obj.nSlopeFits         = 0;
            obj.nSlewLimited       = 0;
            obj.idxBuf             = zeros(obj.windowLen, 1);
            obj.tBuf               = zeros(obj.windowLen, 1);
            obj.head               = 0;
            obj.count              = 0;
            obj.anchored           = false;
            obj.lastEmitted        = -Inf;
            obj.nObs               = 0;
            obj.nObsRejected       = 0;
            obj.nFits              = 0;
            obj.nSlopeClamped      = 0;
            obj.nMonotoneClamped   = 0;
            obj.worstMonotoneClamp = 0;
            obj.residualRms        = NaN;
        end

        function addObservation(obj, idxNewest, tLocal, queueClear)
            % queueClear: true when the drain that produced this pair left
            % the receive queue empty, i.e. this sample waited only the
            % link's floor latency. Defaults true so a caller that cannot
            % tell keeps the old behaviour; see the ESTIMATOR note above
            % for why a pair taken while the queue is still draining is
            % worse than no pair at all.
            if nargin < 4 || isempty(queueClear)
                queueClear = true;
            end
            if ~isscalar(idxNewest) || ~isscalar(tLocal) || ...
                    ~isfinite(idxNewest) || ~isfinite(tLocal)
                return;
            end
            if ~queueClear
                obj.nObsRejected = obj.nObsRejected + 1;
                return;
            end
            obj.head = mod(obj.head, obj.windowLen) + 1;
            obj.idxBuf(obj.head) = idxNewest;
            obj.tBuf(obj.head)   = tLocal;
            obj.count = min(obj.count + 1, obj.windowLen);
            obj.nObs  = obj.nObs + 1;
            if ~obj.anchored
                obj.offset   = tLocal - obj.secPerSample * idxNewest;
                obj.anchored = true;
            end
            if obj.count >= obj.minObs
                obj.refit();
            end
        end

        function t = indexToTime(obj, idx)
            if ~obj.anchored
                t = nan(size(idx));
                return;
            end
            t = obj.offset + obj.secPerSample * idx;
            if isfinite(obj.lastEmitted)
                below = t < obj.lastEmitted;
                if any(below(:))
                    pull = obj.lastEmitted - min(t(below));
                    if pull > obj.worstMonotoneClamp
                        obj.worstMonotoneClamp = pull;
                    end
                    obj.nMonotoneClamped = obj.nMonotoneClamped + sum(below(:));
                    t(below) = obj.lastEmitted;
                end
            end
            if ~isempty(t)
                newest = max(t(:));
                if newest > obj.lastEmitted
                    obj.lastEmitted = newest;
                end
            end
        end

        function s = summary(obj)
            s = struct( ...
                'seedRateHz',            1 / obj.seedSecPerSample, ...
                'estimatedRateHz',       1 / obj.secPerSample, ...
                'estimatedVsSeedPpm',    (obj.seedSecPerSample / obj.secPerSample - 1) * 1e6, ...
                'nObservations',         obj.nObs, ...
                'nObservationsRejected', obj.nObsRejected, ...
                'nFits',                 obj.nFits, ...
                'nSlopeFits',            obj.nSlopeFits, ...
                'nSlopeClamped',         obj.nSlopeClamped, ...
                'nSlewLimited',          obj.nSlewLimited, ...
                'nMonotoneClamped',      obj.nMonotoneClamped, ...
                'worstMonotoneClampSec', obj.worstMonotoneClamp, ...
                'residualRmsSec',        obj.residualRms);
        end
    end

    methods (Access = private)
        function refit(obj)
            n = obj.count;
            x = obj.idxBuf(1:n);
            y = obj.tBuf(1:n);
            xm = mean(x);
            ym = mean(y);
            xc = x - xm;
            sxx = sum(xc .* xc);
            if ~isfinite(sxx) || sxx <= 0
                return;
            end
            spanSamples = max(x) - min(x);
            if spanSamples >= obj.minSpanSec / obj.seedSecPerSample
                a = sum(xc .* (y - ym)) / sxx;
                aLo = obj.seedSecPerSample * (1 - obj.maxRateDev);
                aHi = obj.seedSecPerSample * (1 + obj.maxRateDev);
                if a < aLo || a > aHi
                    a = min(max(a, aLo), aHi);
                    obj.nSlopeClamped = obj.nSlopeClamped + 1;
                end
                obj.nSlopeFits = obj.nSlopeFits + 1;
            else
                a = obj.secPerSample;
            end
            b = ym - a * xm;
            r = y - (b + a * x);

            % Offset quantile over the most RECENT offsetWindow residuals
            % only. The ring is 1:n valid with head at obj.head; walk back
            % from head to collect the last m entries in arrival order.
            m = min(n, obj.offsetWindow);
            recent = mod(obj.head - (m - 1:-1:0) - 1, n) + 1;
            rr = r(recent);
            rs = sort(rr);
            k  = min(m, max(1, round(obj.offsetQuantile * m)));
            rQ = rs(k);
            bNew = b + rQ;

            % Slew limit, evaluated where it matters: at the newest index
            % in the window, which is where the next sample will be stamped.
            xNew = x(obj.head);
            if obj.nFits > 0
                tOld  = obj.offset + obj.secPerSample * xNew;
                tNew  = bNew + a * xNew;
                move  = tNew - tOld;
                if abs(move) > obj.maxSlewSec
                    bNew = bNew - (move - sign(move) * obj.maxSlewSec);
                    obj.nSlewLimited = obj.nSlewLimited + 1;
                end
            end

            obj.secPerSample = a;
            obj.offset       = bNew;
            obj.residualRms  = sqrt(mean((rr - rQ) .^ 2));
            obj.nFits        = obj.nFits + 1;
        end
    end
end