function restoreLog = StartSessionLog(logFile, engineName, runTag)
% STARTSESSIONLOG  Mirror everything a session prints to the console into a
% .txt file, for as long as the returned object is alive.
%   Paola Castillo 2026-07-31
%
%   Used by CenterOutTask.m and CenterInTask.m so that every session leaves a
%   readable transcript next to its data files -- the budget block, any
%   requeue/warning notices during the run, and the whole end-of-session
%   report (SessionReport.blocks/session/reward/confusion/signalDetection)
%   without the operator having to scroll back through the MATLAB console or
%   remember to copy it out.
%
%   WHY DIARY, NOT evalc. The obvious alternative -- wrap each report call in
%   evalc and write the captured string -- loses everything a section printed
%   if that section then errors, in the console AND in the file, because
%   evalc discards its buffer when it throws. Those are exactly the sessions
%   whose partial output matters most. diary writes through as it goes, so a
%   half-printed table survives in both places. It also means a printer added
%   later is captured automatically, with no call site to remember to wrap.
%
%   The returned onCleanup restores whatever diary state the caller's MATLAB
%   was in beforehand (including a diary the operator had running on their
%   own file), and does so on EVERY exit path -- normal return, error, or
%   Ctrl+C. Keep it in a variable that lives as long as logging should:
%
%     logCleanup = StartSessionLog(f, 'CenterOutTask', runTag);   %#ok<NASGU>
%
%   Assigning it to ~ or not assigning it at all would destroy it immediately
%   and stop the log on the next line.
%
%   INPUT  logFile    : full path to the .txt to write (appended to if it
%                       already exists, so a re-run under the same runTag
%                       adds to the transcript rather than silently
%                       replacing the first run's)
%          engineName : engine that is running, for the header
%          runTag     : this run's file tag, so the .txt can be matched to
%                       the perf_/trial_data_/trajectory_ files beside it
%
%   OUTPUT restoreLog : onCleanup handle; see above.

if nargin < 2, engineName = ''; end
if nargin < 3, runTag = ''; end

prevState = get(0, 'Diary');
prevFile  = get(0, 'DiaryFile');
restoreLog = onCleanup(@() restoreDiaryState(prevState, prevFile));

diary(logFile);   % sets the file and turns the diary on
diary('on');      % explicit, in case it was already on for another file

fprintf('===========================================================\n');
fprintf('SESSION LOG -- %s\n', engineName);
fprintf('Run tag : %s\n', runTag);
fprintf('Started : %s\n', datestr(now, 'dd-mmm-yyyy HH:MM:SS'));
fprintf('Full console transcript for this run, including the end-of-session report.\n');
fprintf('===========================================================\n');
end

function restoreDiaryState(prevState, prevFile)
% Put the caller's diary back exactly as it was. Note diary(file) turns the
% diary ON as a side effect, so the state has to be re-applied after the
% filename, not before.
diary('off');
if ~isempty(prevFile)
    try
        diary(prevFile);
        if ~strcmpi(prevState, 'on')
            diary('off');
        end
    catch
        % A previous diary file that can no longer be opened (deleted, or on
        % an unmounted drive) must not turn a finished session into an
        % error -- the session's own log is already written and closed.
        diary('off');
    end
end
end
