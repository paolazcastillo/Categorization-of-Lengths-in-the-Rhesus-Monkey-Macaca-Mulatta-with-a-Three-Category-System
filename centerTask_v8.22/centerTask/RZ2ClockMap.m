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
%   slope   : ordinary least squares over a sliding window of the last
%             windowLen observations. OLS is unbiased for the slope even
%             though the observations are contaminated by latency, because
%             the contamination is a level, not a trend, as long as the
%             backlog is stationary.
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
%   offset  : anchored on the MINIMUM residual of the window, not on the
%             OLS intercept. The OLS intercept absorbs the MEAN transport
%             latency; the minimum residual tracks the fastest observed
%             path, which is the standard minimum-delay filter used in clock
%             synchronisation. This removes the mean-latency bias and leaves
%             only the (unobservable, constant) floor latency of the link.
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
        function obj = RZ2ClockMap(seedRateHz, windowLen, maxRateDev, minObs)
            if nargin < 1 || isempty(seedRateHz) || ~isfinite(seedRateHz) || seedRateHz <= 0
                error('RZ2ClockMap:badSeed', ...
                    'A positive, finite seed sample rate is required (got %g).', seedRateHz);
            end
            if nargin < 2 || isempty(windowLen), windowLen = 600; end
            if nargin < 3 || isempty(maxRateDev), maxRateDev = 0.10; end
            if nargin < 4 || isempty(minObs), minObs = 30; end

            obj.seedSecPerSample   = 1 / seedRateHz;
            obj.secPerSample       = 1 / seedRateHz;
            obj.offset             = NaN;
            obj.windowLen          = max(round(windowLen), 2);
            obj.maxRateDev         = abs(maxRateDev);
            obj.minObs             = max(round(minObs), 2);
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
                'nSlopeClamped',         obj.nSlopeClamped, ...
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
            a = sum(xc .* (y - ym)) / sxx;
            aLo = obj.seedSecPerSample * (1 - obj.maxRateDev);
            aHi = obj.seedSecPerSample * (1 + obj.maxRateDev);
            if a < aLo || a > aHi
                a = min(max(a, aLo), aHi);
                obj.nSlopeClamped = obj.nSlopeClamped + 1;
            end
            b = ym - a * xm;
            r = y - (b + a * x);
            rMin = min(r);
            obj.secPerSample = a;
            obj.offset       = b + rMin;
            obj.residualRms  = sqrt(mean((r - rMin) .^ 2));
            obj.nFits        = obj.nFits + 1;
        end
    end
end