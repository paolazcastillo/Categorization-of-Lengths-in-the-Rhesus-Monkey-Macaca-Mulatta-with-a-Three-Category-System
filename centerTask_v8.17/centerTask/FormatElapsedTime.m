function str = FormatElapsedTime(elapsedSeconds)
% FORMATELAPSEDTIME  "HH:MM:SS" (zero-padded) for a non-negative elapsed
% duration in seconds. Shared by CenterOutTask.m/CenterInTask.m to render
% the console's live "Session time" box (orgParams.handles.textSessionTime
% -- see CenterConsole.m/InitTaskHandles.m/offrig_mocks/OffrigPlay.m for
% where that handle comes from).
% Paola Castillo 2026-07-31
elapsedSeconds = max(elapsedSeconds, 0);
totalSec = floor(elapsedSeconds);
hh = floor(totalSec / 3600);
mm = floor(mod(totalSec, 3600) / 60);
ss = mod(totalSec, 60);
str = sprintf('%02d:%02d:%02d', hh, mm, ss);
end
