function nextEpoch = PauseLoop(taskWindow, black_c, orgParams, kbDevice, useKbQueue, KEY_SPACE)
% PAUSELOOP  Blocks until the operator presses space again: blanks the
% screen and flips the status text to "Task is paused" / back to "Task is
% running". Returns nextEpoch = 0, the sentinel both engines use so the
% state-machine switch below falls through to no case on the frame right
% after a pause (nextEpoch gets reassigned on the very next iteration by
% whichever epoch was active when space was first pressed).
% Paola Castillo 2026-07-31
%
% IMPORTANT: callers MUST DISCARD the return value. nextEpoch = 0 is
% intentionally not a valid epoch in either engine; it is only a sentinel
% to signal "just resumed". CenterOutTask.m and CenterInTask.m both call
% this as:
%   PauseLoop(taskWindow, black_c, orgParams, kbDevice, useKbQueue, KEY_SPACE);
% (no left-hand side). Assigning the sentinel to nextEpoch would leave the
% state machine in an unmatched case that nothing else writes, hanging the
% task silently after the resume.
pause(0.2);
set(orgParams.handles.text77, 'String', 'Task is paused');
set(orgParams.handles.text77, 'ForegroundColor', 'red');
drawnow();
BlankScreen(taskWindow, black_c);
waiting = true;
while waiting
    [kd, kc] = SafeKbCheck(kbDevice, useKbQueue);
    if kd && kc(KEY_SPACE)
        set(orgParams.handles.text77, 'String', 'Task is running');
        set(orgParams.handles.text77, 'ForegroundColor', 'blue');
        drawnow();
        waiting = false;
        pause(0.2);
    end
end
nextEpoch = 0;
end