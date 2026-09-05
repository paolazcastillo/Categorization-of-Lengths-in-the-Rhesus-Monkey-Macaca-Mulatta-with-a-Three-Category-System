function ForceCloseScreen(taskWindow)
% FORCECLOSESCREEN  Guaranteed screen/priority/cursor teardown, registered
% via onCleanup right after the PTB window opens so it runs on ANY exit
% from the calling task (normal return, thrown error, Ctrl+C) -- it does
% not depend on the rig-side closeTask() helper being present on the
% MATLAB path. Also called directly right after the trial loop ends, so
% the display is released immediately rather than staying captured
% through the save/report teardown. Each step is independently guarded:
% if closeTask() (or an earlier call to this function) already did its
% job, these are harmless no-ops.
try, Priority(0); catch, end
try, ShowCursor(taskWindow); catch, end
try
    % Screen('Close', <stale handle>) prints a PTB diagnostic ("Invalid
    % Window ... Index") to the console even though the error itself is
    % caught below -- checking Screen('Windows') first avoids that noise
    % in the (now common) case where the screen was already released.
    if ismember(taskWindow, Screen('Windows'))
        Screen('Close', taskWindow);
    end
catch
end
try, Screen('CloseAll'); catch, end
end