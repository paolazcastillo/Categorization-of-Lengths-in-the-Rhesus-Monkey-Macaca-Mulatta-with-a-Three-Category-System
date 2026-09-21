function [outCsvPath, info] = BackfillTakeoffTime(csvPath, varargin)
% BACKFILLTAKEOFFTIME  Add a TakeoffTime_s column to a trial_data_*.csv that
% predates it, computed OFFLINE from that session's own
% trajectory_movement_*.csv via TrialTakeoff.m -- the exact same function
% CenterOutTask.m now calls live, so a backfilled value is numerically
% identical to what the task would have written had this session been run
% on a build that already had it (see TrialTakeoff.m's header: a base-MATLAB
% 1:1 port of the EDA notebooks' TrajectoryProcessor).
%
% WHY THIS EXISTS
% AnalyzePsychometricCurvesMultiSession.m's chronometric curve can be
% pointed at TakeoffTime_s (target-onset -> movement takeoff) instead of its
% default target-onset -> cursor-enters-target time (see
% 'ChronometricTimeSource' there and in LoadSessionTrialData.m). Sessions
% recorded before TrialTakeoff.m was added to CenterOutTask.m -- every
% "alternate" session as of 2026-09-20 -- have no TakeoffTime_s column at
% all, so under 'ChronometricTimeSource'='Takeoff' LoadSessionTrialData.m
% would otherwise just exclude them (a missing column is treated the same
% as an unresolved timing schema). This function is the one place that gap
% gets filled. AnalyzePsychometricCurvesAlternating.m and
% AnalyzePsychometricCurvesMultiSessionAlternating.m call it automatically
% on every session before splitting/pooling -- most callers never need to
% invoke it directly.
%
%   INPUT
%     csvPath : path to a trial_data_*.csv (must be named
%               "trial_data_<runTag>.csv", CenterOutTask.m's own naming)
%
%   NAME-VALUE OPTIONS
%     'OutDir'  : folder to write the augmented copy into (default:
%                 <folder of csvPath>/takeoff_backfill). Only used when a
%                 backfill actually happens; the original file is NEVER
%                 modified in place.
%     'TrajectoryDir' : where to look for "trajectory_movement_<runTag>.csv"
%                 if it is NOT sitting next to csvPath (default: '', i.e.
%                 only the same folder as csvPath is checked). Set this to
%                 the task's outputs root (e.g. 'outputs/alternate') when
%                 your trial_data_*.csv files have been consolidated into
%                 their own working folder, separate from each session's
%                 original outputs/ folder -- a common workflow, and the
%                 reason this option exists. Two layouts are tried under
%                 TrajectoryDir, in order:
%                   1) <TrajectoryDir>/<runTag>/trajectory_movement_<runTag>.csv
%                      (CenterOutTask.m's own one-folder-per-session layout)
%                   2) <TrajectoryDir>/trajectory_movement_<runTag>.csv
%                      (a flat folder with everything already gathered)
%     'Verbose' : true/false (default true)
%
%   OUTPUT
%     outCsvPath : csvPath UNCHANGED if it already has a TakeoffTime_s
%                  column (a new-format session -- this function is then a
%                  cheap no-op), or if the matching trajectory_movement file
%                  (or a required column) cannot be found (warns and
%                  returns the original path so the caller's pipeline
%                  degrades to its normal "unresolved timing" handling
%                  instead of erroring); otherwise the path to the augmented
%                  copy written under 'OutDir'.
%     info       : struct with .backfilled (logical), .nTrials, .nResolved
%                  (TakeoffTime_s non-NaN count after backfilling), .reason
%                  (human-readable, for logging either way)
%
%   See also: TrialTakeoff, TaskEpoch, LoadSessionTrialData

p = inputParser;
addRequired(p, 'csvPath', @(s) ischar(s) || (isstring(s) && isscalar(s)));
addParameter(p, 'OutDir', '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
addParameter(p, 'TrajectoryDir', '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
addParameter(p, 'Verbose', true, @(x) islogical(x) || isnumeric(x));
parse(p, csvPath, varargin{:});
opt = p.Results;
csvPath = char(opt.csvPath);
verbose = logical(opt.Verbose);

if ~exist(csvPath, 'file')
    error('BackfillTakeoffTime:fileNotFound', 'CSV not found: %s', csvPath);
end
[csvDir, csvBase, csvExt] = fileparts(csvPath);

info = struct('backfilled', false, 'nTrials', 0, 'nResolved', 0, 'reason', '');

trialT = readtable(csvPath, 'TextType', 'string');
if any(strcmp(trialT.Properties.VariableNames, 'TakeoffTime_s'))
    outCsvPath = csvPath;
    info.reason = 'TakeoffTime_s already present -- no backfill needed.';
    vprintf(verbose, '%s: %s\n', csvBase, info.reason);
    return;
end

% trial_data_<runTag>.csv -> trajectory_movement_<runTag>.csv. Tried, in
% order: (1) same folder as csvPath (see CenterOutTask.m's own naming and
% the "joins on Block+TrialNumInBlock+Attempt" comment above its
% trialLogFile fopen); (2) <TrajectoryDir>/<runTag>/... (one-folder-per-
% session, CenterOutTask.m's own outputs/ layout); (3) <TrajectoryDir>/...
% (flat). (2)/(3) only apply if 'TrajectoryDir' was given.
if ~strncmp(csvBase, 'trial_data_', numel('trial_data_'))
    outCsvPath = csvPath;
    info.reason = ['Filename does not match "trial_data_<runTag>.csv" -- cannot locate the ' ...
        'matching trajectory_movement file. TakeoffTime_s NOT backfilled.'];
    warning('BackfillTakeoffTime:unexpectedFilename', '%s: %s', csvBase, info.reason);
    return;
end
runTag = csvBase(numel('trial_data_') + 1:end);
trajFilename = ['trajectory_movement_' runTag '.csv'];
trajCandidates = {fullfile(csvDir, trajFilename)};
trajectoryDir = char(opt.TrajectoryDir);
if ~isempty(trajectoryDir)
    trajCandidates{end + 1} = fullfile(trajectoryDir, runTag, trajFilename);
    trajCandidates{end + 1} = fullfile(trajectoryDir, trajFilename);
end
trajPath = '';
for c = 1:numel(trajCandidates)
    if exist(trajCandidates{c}, 'file')
        trajPath = trajCandidates{c};
        break;
    end
end
if isempty(trajPath)
    hint = '';
    if isempty(trajectoryDir)
        hint = [' -- pass ''TrajectoryDir'' pointing at the outputs/ folder if this session''s ' ...
            'files were split apart from trial_data_' runTag '.csv'];
    end
    outCsvPath = csvPath;
    info.reason = sprintf('No %s found (tried: %s)%s. TakeoffTime_s NOT backfilled.', trajFilename, ...
        strjoin(trajCandidates, '; '), hint);
    warning('BackfillTakeoffTime:noTrajectoryFile', '%s: %s', csvBase, info.reason);
    return;
end
if ~any(strcmp(trialT.Properties.VariableNames, 'DecisionTime_s'))
    outCsvPath = csvPath;
    info.reason = 'No DecisionTime_s column -- TrialTakeoff.m needs it. TakeoffTime_s NOT backfilled.';
    warning('BackfillTakeoffTime:noDecisionTime', '%s: %s', csvBase, info.reason);
    return;
end
reqTrajCols = {'Time_ms', 'X_px', 'Y_px', 'Epoch', 'Block', 'TrialNumInBlock', 'Attempt', 'RZ2Idx'};
trajTHead = readtable(trajPath, 'TextType', 'string');
missingCols = reqTrajCols(~ismember(reqTrajCols, trajTHead.Properties.VariableNames));
if ~isempty(missingCols)
    outCsvPath = csvPath;
    info.reason = sprintf('trajectory_movement_%s.csv is missing column(s): %s. TakeoffTime_s NOT backfilled.', ...
        runTag, strjoin(missingCols, ', '));
    warning('BackfillTakeoffTime:missingTrajectoryColumns', '%s: %s', csvBase, info.reason);
    return;
end
trajT = trajTHead;

% TrialTakeoff.m / TaskEpoch.m live in the task engine, not on the
% psychometric analysis path by default.
thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, '..', '..', 'centerTask_v10.00', 'centerTask'));

nTrials = height(trialT);
info.nTrials = nTrials;
takeoffTime_s = nan(nTrials, 1);

% Group the trajectory rows by (Block, TrialNumInBlock, Attempt) ONCE, up
% front, rather than re-filtering the whole trajectory table per trial_data
% row (O(n+m) instead of O(n*m) for what is otherwise a join).
trajKey = trajKeyOf(trajT.Block, trajT.TrialNumInBlock, trajT.Attempt);
[uKeys, ~, trajGroup] = unique(trajKey);
rowsByGroup = accumarray(trajGroup, (1:numel(trajGroup))', [numel(uKeys), 1], @(v) {v});

% rz2adc sessions drop cached/wall-clock-stamped (RZ2Idx-NaN) rows first,
% the same as CenterOutTask.m's useRZ2 flag does live (see TrialTakeoff.m's
% dropUnindexed); a USB-joystick/mouse session's RZ2Idx is NaN throughout,
% so this correctly comes out false for it without needing the session's
% params.mat.
dropUnindexed = any(~isnan(trajT.RZ2Idx));

trialKey = trajKeyOf(trialT.Block, trialT.TrialNumInBlock, trialT.Attempt);
movementEpochValue = TaskEpoch.MOVEMENT.Value;
for i = 1:nTrials
    gIdx = find(uKeys == trialKey(i), 1);
    if isempty(gIdx)
        rows = zeros(0, 5);
    else
        rows = trajT{rowsByGroup{gIdx}, {'Time_ms', 'X_px', 'Y_px', 'Epoch', 'RZ2Idx'}};
    end
    decisionTime = trialT.DecisionTime_s(i);
    if isnan(decisionTime)
        continue;   % TrialTakeoff needs it; leave NaN, same as the live engine would
    end
    takeoffTime_s(i) = TrialTakeoff(rows, decisionTime, movementEpochValue, dropUnindexed);
end

info.nResolved = nnz(~isnan(takeoffTime_s));
trialT.TakeoffTime_s = takeoffTime_s;

if isempty(opt.OutDir)
    outDir = fullfile(csvDir, 'takeoff_backfill');
else
    outDir = char(opt.OutDir);
end
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
outCsvPath = fullfile(outDir, [csvBase csvExt]);
writetable(trialT, outCsvPath);
info.backfilled = true;
info.reason = 'TakeoffTime_s computed offline from trajectory_movement via TrialTakeoff.m.';
vprintf(verbose, ['%s: backfilled TakeoffTime_s for %d trial(s) (%d resolved, %d NaN) -> %s\n'], ...
    csvBase, nTrials, info.nResolved, nTrials - info.nResolved, outCsvPath);
end

function k = trajKeyOf(block, trialNum, attempt)
% Composite integer key for (Block, TrialNumInBlock, Attempt) -- all three
% are small positive integers in this engine (see CenterOutTask.m), so this
% packing is exact and collision-free.
k = uint64(round(block)) * uint64(1e8) + uint64(round(trialNum)) * uint64(1e4) + uint64(round(attempt));
end

function vprintf(verbose, varargin)
if verbose, fprintf(varargin{:}); end
end
