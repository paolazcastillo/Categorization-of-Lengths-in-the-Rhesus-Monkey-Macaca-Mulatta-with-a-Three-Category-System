classdef ClockSkewMonitor < handle
% CLOCKSKEWMONITOR  Runtime canary for the "two clocks" failure.
%
% Every frame of the trial loop holds two readings of the same instant: the
% GetSecs taken at the cursor read (sampleTime) and the timestamp carried by
% the row that read produced (trigTime). On the mouse and joystick paths
% they are the same number by construction. On the rz2adc path trigTime
% comes from RZ2ClockMap, so their difference is a direct, per-frame
% measurement of how far the two time bases have drifted apart.
%
% That difference is what nobody was measuring. Session sessPX-309
% (03-Sep-2026) ran with it growing at 13.7 ms/s from the first minute and
% ended at 3.17 s, and the only visible symptom was behaviour that looked
% like the subject giving up: every window anchored on a sample-derived
% marker but tested against GetSecs had its effective duration reduced by
% exactly that amount (hold 1.0 s, execution 2.5 s), so the last ten trials
% were arithmetically impossible to complete.
%
% Two thresholds, because the two failures need different responses:
%   warnSec   : throttled warning, on the INSTANTANEOUS skew. The link is
%               drifting but the session's timing is still within the noise
%               of the epoch durations.
%   abortSec  : trip, on the SUSTAINED skew: the median over the last
%               windowLen updates (~1.5 s at 60 fps). Past this point the
%               session is producing data whose intervals are wrong by more
%               than any epoch's jitter, and continuing only costs the
%               subject work that will be discarded. update() returns true;
%               the caller stops the run.
%
% SUSTAINED, NOT INSTANTANEOUS (2026-09-05). The first version tripped on a
% single frame. On the rig the link carries 0-225 ms of arrival jitter from
% Computer 1's relay loop stalling, so one frame's sample can legitimately
% be 200 ms old while the next is fresh; that is a transient, not a broken
% time base, and stopping on it killed a session at trial 5 for nothing. A
% MEDIAN over ~1.5 s is what a stall cannot fake and a real, persistent
% backlog cannot hide. The instantaneous value still drives the warning and
% the maxSkewSec statistic, so the jitter stays visible in the report.
%
% The trip is latching: once tripped it stays tripped, so a caller that
% polls after the fact still sees it.
%
% USAGE (see CenterOutTask.m / CenterInTask.m)
%   mon = ClockSkewMonitor(0.05, 0.20, 5, 90);
%   if mon.update(sampleTime - trigTime, this_time), exitFlag = 1; end
%   s = mon.summary();
%
% See also: RZ2ClockMap, ReadRZ2Joystick

    properties (SetAccess = private)
        warnSec             % throttled-warning threshold, seconds
        abortSec            % trip threshold, seconds
        warnPeriodSec       % minimum spacing between warnings
        maxSkewSec          % worst |skew| seen this session
        nUpdates            % samples fed in
        nOverWarn           % updates at or above warnSec
        tripped             % latched, true once abortSec was reached
        lastWarnTime        % clock reading of the last warning issued
        trippedAtSkew       % the sustained |skew| that tripped it
        windowLen           % updates in the sustained (median) window
        maxSustainedSec     % worst median seen this session
    end

    properties (Access = private)
        ring                % ring buffer of recent |skew| values
        head
        count
    end

    methods
        function obj = ClockSkewMonitor(warnSec, abortSec, warnPeriodSec, windowLen)
            if nargin < 1 || isempty(warnSec), warnSec = 0.05; end
            if nargin < 2 || isempty(abortSec), abortSec = 0.20; end
            if nargin < 3 || isempty(warnPeriodSec), warnPeriodSec = 5; end
            if nargin < 4 || isempty(windowLen), windowLen = 90; end
            if abortSec < warnSec
                error('ClockSkewMonitor:badThresholds', ...
                    'abortSec (%g) must not be below warnSec (%g).', abortSec, warnSec);
            end
            obj.warnSec       = abs(warnSec);
            obj.abortSec      = abs(abortSec);
            obj.warnPeriodSec = abs(warnPeriodSec);
            obj.maxSkewSec    = 0;
            obj.nUpdates      = 0;
            obj.nOverWarn     = 0;
            obj.tripped       = false;
            obj.lastWarnTime  = -Inf;
            obj.trippedAtSkew = NaN;
            obj.windowLen     = max(round(windowLen), 1);
            obj.maxSustainedSec = 0;
            obj.ring          = zeros(obj.windowLen, 1);
            obj.head          = 0;
            obj.count         = 0;
        end

        function isTripped = update(obj, skewSec, nowSec)
            isTripped = obj.tripped;
            if ~isscalar(skewSec) || ~isfinite(skewSec) || obj.tripped
                return;
            end
            obj.nUpdates = obj.nUpdates + 1;
            a = abs(skewSec);
            if a > obj.maxSkewSec
                obj.maxSkewSec = a;
            end

            obj.head = mod(obj.head, obj.windowLen) + 1;
            obj.ring(obj.head) = a;
            obj.count = min(obj.count + 1, obj.windowLen);
            sustained = median(obj.ring(1:obj.count));
            if sustained > obj.maxSustainedSec
                obj.maxSustainedSec = sustained;
            end

            if obj.count >= obj.windowLen && sustained >= obj.abortSec
                obj.tripped       = true;
                obj.trippedAtSkew = sustained;
                isTripped         = true;
                fprintf(['CLOCK FAULT: the input time base has been a median %.3f s away from ' ...
                         'GetSecs over the last %d frames (abort threshold %.3f s; worst single ' ...
                         'frame %.3f s). Every interval measured from a sample timestamp is ' ...
                         'wrong by that amount and every window anchored on one is that much ' ...
                         'shorter than configured. Session stopped.\n'], ...
                        sustained, obj.windowLen, obj.abortSec, obj.maxSkewSec);
                return;
            end
            if a >= obj.warnSec
                obj.nOverWarn = obj.nOverWarn + 1;
                if ~isfinite(nowSec) || nowSec - obj.lastWarnTime >= obj.warnPeriodSec
                    if isfinite(nowSec)
                        obj.lastWarnTime = nowSec;
                    end
                    warning('centerTask:clockSkew', ...
                        ['Input time base is %.0f ms away from GetSecs (warn threshold ' ...
                         '%.0f ms, abort at %.0f ms). Check the RZ2 link and the ' ...
                         'estimated sample rate reported at teardown.'], ...
                        a * 1000, obj.warnSec * 1000, obj.abortSec * 1000);
                end
            end
        end

        function s = summary(obj)
            s = struct( ...
                'warnSec',       obj.warnSec, ...
                'abortSec',      obj.abortSec, ...
                'maxSkewSec',    obj.maxSkewSec, ...
                'maxSustainedSec', obj.maxSustainedSec, ...
                'windowLen',     obj.windowLen, ...
                'nUpdates',      obj.nUpdates, ...
                'nOverWarn',     obj.nOverWarn, ...
                'tripped',       obj.tripped, ...
                'trippedAtSkew', obj.trippedAtSkew);
        end
    end
end