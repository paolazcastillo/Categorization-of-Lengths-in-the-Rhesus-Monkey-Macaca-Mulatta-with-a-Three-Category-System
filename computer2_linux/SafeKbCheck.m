function [kd, kc] = SafeKbCheck(dev, useQueue)
% SAFEKBCHECK  Robust keyboard poll for Psychtoolbox.
%   Paola Castillo 2026-07-31
%
%   Prefers KbQueueCheck (independent of KbCheck's OS-detection) when a queue
%   was created. Otherwise falls back to KbCheck. On OSes that the installed
%   PTB does not support (e.g. macOS 26), KbCheck's internal OS-detection can
%   be left half-initialised and error, whereas the KbQueue path is
%   independent and usually still works. One reset attempt is made on its
%   persistent state; if it still fails, this degrades gracefully to "no key
%   pressed" so an off-rig test run can still complete (it stops at
%   maxCorrectTrials). On the rig behaviour is unchanged.
if nargin < 2, useQueue = false; end
persistent broken
if isempty(broken), broken = false; end
kc = zeros(1, 256);
if useQueue
    try
        [pressed, firstPress] = KbQueueCheck(dev);
        kd = double(pressed > 0);
        kc = firstPress > 0;    % logical 1x256, indexable by key code
        return;
    catch
        % queue unusable this call -> fall through to KbCheck path
    end
end
if broken
    kd = 0;
    return;
end
try
    [kd, ~, kc] = KbCheck(dev);
catch
    try
        clear KbCheck                 % reset half-initialised persistents
        [kd, ~, kc] = KbCheck(dev);
    catch
        broken = true;
        warning('SafeKbCheck:KbCheckUnavailable', ...
            ['KbCheck is failing on this OS; keyboard controls ' ...
            '(space/ESC/r) are disabled for this run. The task will ' ...
            'still run and stop at maxCorrectTrials.']);
        kd = 0;
        kc = zeros(1, 256);
    end
end
end