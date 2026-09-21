function results = AnalyzePsychometricCurvesMultiSessionAlternating(csvPaths, varargin)
% ANALYZEPSYCHOMETRICCURVESMULTISESSIONALTERNATING  Pool several "alternate"
% sessions together -- each trial_data_*.csv mixes 2-category blocks
% (ShortGroup/LongGroup) and 3-category blocks (ShortGroup/MidGroup/
% LongGroup) in the same file, tagged per-row by a NumCategories column.
%
% WHAT THIS DOES: backfills a TakeoffTime_s column into EVERY input session
% that predates it (BackfillTakeoffTime.m -- a no-op for one that already
% has it), splits each (possibly backfilled) session into its 2-category
% rows and its 3-category rows (SplitAlternatingSessionCsv.m), then pools
% all the 2-category splits together through the existing, UNMODIFIED
% AnalyzePsychometricCurvesMultiSession.m, and separately pools all the
% 3-category splits together the same way -- with
% 'ChronometricTimeSource'='Takeoff' always forced on that call, so the
% pooled chronometric curve is target-onset -> movement takeoff, not
% target-onset -> target-reached (not one of this function's own options;
% see BackfillTakeoffTime.m for why every alternate session can support
% it). See SplitAlternatingSessionCsv.m and
% AnalyzePsychometricCurvesAlternating.m (the single-session sibling of
% this function) for why a split -- not a new fitting engine -- is the
% correct approach.
%
% UNEVEN SESSIONS: an "alternate" session is not required to contain both
% block types. If, across the sessions you selected, only 1 session
% contributed rows to a given bucket, that bucket falls back to
% AnalyzePsychometricCurves.m (single-session, NOT pooled) instead of
% erroring out; if 0 sessions did, that bucket's result is [] with a
% printed note. Both cases are reported explicitly, not silently.
%
% NO STATISTICS/OPTIMIZATION TOOLBOX IS USED (inherited from
% AnalyzePsychometricCurvesMultiSession.m: fminsearch + erf/erfinv only).
%
%   INPUT
%     csvPaths : cell array of paths to "alternate" trial_data_*.csv files
%                (one per session), OR a single path (auto-wrapped; you
%                need >=2 sessions for this function to make sense -- use
%                AnalyzePsychometricCurvesAlternating.m directly for 1)
%
%   NAME-VALUE OPTIONS (forwarded as-is to AnalyzePsychometricCurvesMultiSession.m
%   for BOTH the 2-cat and 3-cat pools -- see that function's header)
%     'UseFirstAttemptOnly', 'LinkFunction', 'UseLapseRates', 'LapseMax',
%     'NBootstrap', 'BootstrapAlpha', 'MakePlots', 'FigureVisible',
%     'FitOrdinalModel', 'Verbose', 'RunPerSessionComparison',
%     'PerSessionMakePlots', 'MakeComparisonPlots'
%     'OutDir'  (default: <folder of first csvPath>/psychometric_analysis_multisession_alternating)
%
%   OUTPUT (struct results)
%     .cat2, .cat3 : the results struct from AnalyzePsychometricCurvesMultiSession.m
%                    (if >=2 sessions had rows of that category count),
%                    OR from AnalyzePsychometricCurves.m (if exactly 1
%                    session did -- results.cat2.pooled = false in that
%                    case so callers can tell the difference), OR [] (0
%                    sessions did)
%     .splitInfoPerSession : cell array, SplitAlternatingSessionCsv.m output
%                             for each input session
%     .csvPaths
%
%   USAGE
%     results = AnalyzePsychometricCurvesMultiSessionAlternating(csvPaths, 'OutDir', outDir);

% Depends on AnalyzePsychometricCurvesMultiSession.m + AnalyzePsychometricCurves.m
% + LoadSessionTrialData.m from the sibling src/3cat folder -- add both this
% file's own folder and ../3cat to the path so this works even if the
% caller only added this one folder.
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
addpath(fullfile(thisDir, '..', '3cat'));

% ===========================================================================
% OPTIONS (same list as AnalyzePsychometricCurvesMultiSession.m)
% ===========================================================================
p = inputParser;
addRequired(p, 'csvPaths', @(x) iscell(x) || ischar(x) || isstring(x));
addParameter(p, 'UseFirstAttemptOnly', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'LinkFunction', 'logistic', @(s) any(strcmpi(s, {'logistic', 'probit'})));
addParameter(p, 'UseLapseRates', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'LapseMax', 0.10, @(x) isnumeric(x) && isscalar(x) && x > 0 && x < 0.5);
addParameter(p, 'NBootstrap', 1000, @(x) isnumeric(x) && isscalar(x) && x >= 0);
addParameter(p, 'BootstrapAlpha', 0.05, @(x) isnumeric(x) && isscalar(x) && x > 0 && x < 1);
addParameter(p, 'MakePlots', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'FigureVisible', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'FitOrdinalModel', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'OutDir', '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
addParameter(p, 'Verbose', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'RunPerSessionComparison', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'PerSessionMakePlots', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'MakeComparisonPlots', false, @(x) islogical(x) || isnumeric(x));
% Forwarded to BackfillTakeoffTime.m for every session -- set this if the
% csvPaths were pulled out of their original outputs/ session folders (so
% each trajectory_movement_*.csv is no longer sitting next to its
% trial_data_*.csv). See BackfillTakeoffTime.m's own header.
addParameter(p, 'TrajectoryDir', '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
parse(p, csvPaths, varargin{:});
opt = p.Results;
verbose = logical(opt.Verbose);

if ischar(csvPaths)
    csvPaths = {csvPaths};
elseif isstring(csvPaths)
    csvPaths = cellstr(csvPaths);
end
csvPaths = csvPaths(:)';
nSessions = numel(csvPaths);
if nSessions < 2
    error('AnalyzePsychometricCurvesMultiSessionAlternating:tooFewSessions', ...
        ['At least 2 sessions are needed for a combined analysis (%d received). ' ...
         'For a single session use AnalyzePsychometricCurvesAlternating.m directly.'], nSessions);
end
for i = 1:nSessions
    csvPaths{i} = char(csvPaths{i});
    if ~exist(csvPaths{i}, 'file')
        error('AnalyzePsychometricCurvesMultiSessionAlternating:fileNotFound', 'CSV not found: %s', csvPaths{i});
    end
end

[firstDir, ~, ~] = fileparts(csvPaths{1});
if isempty(opt.OutDir)
    outDir = fullfile(firstDir, 'psychometric_analysis_multisession_alternating');
else
    outDir = char(opt.OutDir);
end
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
splitDir = fullfile(outDir, 'split_csv');

vprintf(verbose, '\n======= AnalyzePsychometricCurvesMultiSessionAlternating: %d sessions =======\n', nSessions);

% Options forwarded to AnalyzePsychometricCurves(MultiSession).m for both
% pools (all of opt except csvPaths/OutDir, which are set per-pool below).
%
% ChronometricTimeSource is hardcoded to 'Takeoff' here (not exposed as one
% of THIS function's own options): the pooled chronometric curve for
% "alternate" sessions is target-onset -> movement takeoff, full stop, not
% a choice made per call. See the backfill loop below for why every
% alternate session can support it even though none of them were recorded
% with a TakeoffTime_s column.
fwdMulti = {'UseFirstAttemptOnly', opt.UseFirstAttemptOnly, 'LinkFunction', opt.LinkFunction, ...
    'UseLapseRates', opt.UseLapseRates, 'LapseMax', opt.LapseMax, 'NBootstrap', opt.NBootstrap, ...
    'BootstrapAlpha', opt.BootstrapAlpha, 'MakePlots', opt.MakePlots, 'FigureVisible', opt.FigureVisible, ...
    'FitOrdinalModel', opt.FitOrdinalModel, 'Verbose', opt.Verbose, ...
    'RunPerSessionComparison', opt.RunPerSessionComparison, 'PerSessionMakePlots', opt.PerSessionMakePlots, ...
    'MakeComparisonPlots', opt.MakeComparisonPlots, 'ChronometricTimeSource', 'Takeoff'};
fwdSingle = {'UseFirstAttemptOnly', opt.UseFirstAttemptOnly, 'LinkFunction', opt.LinkFunction, ...
    'UseLapseRates', opt.UseLapseRates, 'LapseMax', opt.LapseMax, 'NBootstrap', opt.NBootstrap, ...
    'BootstrapAlpha', opt.BootstrapAlpha, 'MakePlots', opt.MakePlots, 'FigureVisible', opt.FigureVisible, ...
    'FitOrdinalModel', opt.FitOrdinalModel, 'Verbose', opt.Verbose, 'ChronometricTimeSource', 'Takeoff'};

% ===========================================================================
% BACKFILL TakeoffTime_s per session (no-op for one that already has it),
% THEN SPLIT every (possibly backfilled) session into its 2-category and
% 3-category rows
% ===========================================================================
takeoffBackfillDir = fullfile(outDir, 'takeoff_backfill');
splitInfoPerSession = cell(1, nSessions);
list2cat = {};
list3cat = {};
for i = 1:nSessions
    vprintf(verbose, '\n--- Backfilling + splitting session %d/%d ---\n', i, nSessions);
    csvPathBackfilled = BackfillTakeoffTime(csvPaths{i}, 'OutDir', takeoffBackfillDir, ...
        'TrajectoryDir', opt.TrajectoryDir, 'Verbose', verbose);
    splitInfoPerSession{i} = SplitAlternatingSessionCsv(csvPathBackfilled, splitDir, verbose);
    if ~isempty(splitInfoPerSession{i}.path2cat)
        list2cat{end + 1} = splitInfoPerSession{i}.path2cat; %#ok<AGROW>
    end
    if ~isempty(splitInfoPerSession{i}.path3cat)
        list3cat{end + 1} = splitInfoPerSession{i}.path3cat; %#ok<AGROW>
    end
end

results = struct();
results.csvPaths = csvPaths;   % the ORIGINAL inputs, unchanged
results.splitInfoPerSession = splitInfoPerSession;
results.cat2 = poolBucket(list2cat, '2-category', fullfile(outDir, '2cat'), fwdMulti, fwdSingle, verbose);
results.cat3 = poolBucket(list3cat, '3-category', fullfile(outDir, '3cat'), fwdMulti, fwdSingle, verbose);

vprintf(verbose, ['\n=======================================================\n' ...
    'Done. Combined "alternate" analysis of %d sessions saved to: %s\n'], nSessions, outDir);
end

function out = poolBucket(list, label, bucketOutDir, fwdMulti, fwdSingle, verbose)
n = numel(list);
if n >= 2
    vprintf(verbose, '\n--- Pooling %d session(s) of %s blocks ---\n', n, label);
    out = AnalyzePsychometricCurvesMultiSession(list, 'OutDir', bucketOutDir, fwdMulti{:});
    out.pooled = true;
elseif n == 1
    vprintf(verbose, ['\n--- Only 1 session had %s blocks -- running it as a single session ' ...
        '(NOT pooled) ---\n'], label);
    out = AnalyzePsychometricCurves(list{1}, 'OutDir', bucketOutDir, fwdSingle{:});
    out.pooled = false;
else
    out = [];
    vprintf(verbose, '\nNo session had %s blocks -- this bucket is [].\n', label);
end
end

function vprintf(verbose, varargin)
if verbose, fprintf(varargin{:}); end
end
