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
%   warnSec   : throttled warning. The link is drifting but the session's
%               timing is still within the noise of the epoch durations.
%   abortSec  : trip. Past this point the session is producing data whose
%               intervals are wrong by more than any epoch's jitter, and
%               continuing only costs the subject work that will be
%               discarded. update() returns true; the caller stops the run.
%
% The trip is latching: once tripped it stays tripped, so a caller that
% polls after the fact still sees it.
%
% USAGE (see CenterOutTask.m / CenterInTask.m)
%   mon = ClockSkewMonitor(0.05, 0.20, 5);
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
        trippedAtSkew       % the |skew| that tripped it
    end

    methods
        function obj = ClockSkewMonitor(warnSec, abortSec, warnPeriodSec)
            if nargin < 1 || isempty(warnSec), warnSec = 0.05; end
            if nargin < 2 || isempty(abortSec), abortSec = 0.20; end
            if nargin < 3 || isempty(warnPeriodSec), warnPeriodSec = 5; end
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
            if a >= obj.abortSec
                obj.tripped       = true;
                obj.trippedAtSkew = a;
                isTripped         = true;
                fprintf(['CLOCK FAULT: the input time base and GetSecs are %.3f s apart ' ...
                         '(abort threshold %.3f s). Every interval measured from a sample ' ...
                         'timestamp is wrong by that amount and every window anchored on ' ...
                         'one is that much shorter than configured. Session stopped.\n'], ...
                        a, obj.abortSec);
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
                'nUpdates',      obj.nUpdates, ...
                'nOverWarn',     obj.nOverWarn, ...
                'tripped',       obj.tripped, ...
                'trippedAtSkew', obj.trippedAtSkew);
        end
    end
end
