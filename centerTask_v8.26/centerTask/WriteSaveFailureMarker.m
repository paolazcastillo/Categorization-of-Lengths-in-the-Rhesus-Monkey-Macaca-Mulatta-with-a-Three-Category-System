function WriteSaveFailureMarker(intendedFile, ME)
% WRITESAVEFAILUREMARKER  Leave a persistent trace next to a failed save.
%
%   SaveTrajectory.m and SaveMovementTrajectory.m already catch every save
%   error so a failed export never aborts the session (crucial on the
%   crash-recovery path). But until now that catch only did fprintf() to the
%   console -- if the console/diary was already gone (StartSessionLog failed,
%   or the session crashed before this point), the failure left no trace at
%   all: a missing trajectory file reads exactly like "session had no
%   movement", not "save failed", to anything inspecting the output folder
%   later.
%
%   Writes intendedFile + '.FAILED', a plain-text note with the timestamp and
%   error message. Best-effort: if even THIS write fails (e.g. the directory
%   itself is gone), it is swallowed silently -- a failed diagnostic must
%   never become a new source of aborts on the crash-recovery path.
%
%   INPUT  intendedFile : full path of the file that failed to save
%          ME           : the caught MException (or any struct/object with
%                          a .message field)

try
    fid = fopen([intendedFile, '.FAILED'], 'w');
    if fid ~= -1
        fprintf(fid, 'Save failed at %s\nIntended file: %s\nError: %s\n', ...
            datestr(now, 'dd-mmm-yyyy HH:MM:SS'), intendedFile, ME.message);
        fclose(fid);
    end
catch
    % Diagnostic-of-last-resort: never let this throw.
end
end
