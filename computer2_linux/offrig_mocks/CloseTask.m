function CloseTask()
% CLOSETASK   (off-rig STUB) Best-effort teardown of display/input devices.
%
%   The real lab function closes the Psychtoolbox window and releases devices.
%   This stub restores the cursor/priority and closes any Screen windows if
%   Psychtoolbox happens to be installed, and is a harmless no-op otherwise.
%
%   NOTE: this is a mock for off-rig logic testing, not the lab function.

% One guarded block: if Psychtoolbox is absent the first call errors and the
% rest are skipped, which is fine, as there is nothing to release.
try
    Priority(0);
    ShowCursor;
    Screen('CloseAll');
catch
    % Psychtoolbox not present or already closed; nothing to do.
end
fprintf('[MOCK CloseTask] devices released (best effort).\n');
end