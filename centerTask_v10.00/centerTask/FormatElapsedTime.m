function str = FormatElapsedTime(elapsedSeconds)
% FORMATELAPSEDTIME  "HH:MM:SS" (zero-padded) for a non-negative elapsed
% duration in seconds. Shared by CenterOutTask.m/CenterInTask.m to render
% the console's live "Session time" box (orgParams.handles.textSessionTime
% -- see CenterConsole.m/InitTaskHandles.m/offrig_mocks/OffrigPlay.m for
% where that handle comes from).
if ~isfinite(elapsedSeconds)
    % max(NaN, 0) silently returns 0 (MATLAB's max ignores NaN operands),
    % which would print a normal-looking "00:00:00" instead of surfacing
    % that whatever computed this duration produced NaN/Inf upstream.
    str = '--:--:--';
    return;
end
elapsedSeconds = max(elapsedSeconds, 0);
totalSec = floor(elapsedSeconds);
hh = floor(totalSec / 3600);
mm = floor(mod(totalSec, 3600) / 60);
ss = mod(totalSec, 60);
str = sprintf('%02d:%02d:%02d', hh, mm, ss);
end
