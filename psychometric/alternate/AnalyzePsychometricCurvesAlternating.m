function results = AnalyzePsychometricCurvesAlternating(csvPath, varargin)
% ANALYZEPSYCHOMETRICCURVESALTERNATING  Analyze ONE "alternate" session --
% a trial_data_*.csv that mixes 2-category blocks (ShortGroup/LongGroup) and
% 3-category blocks (ShortGroup/MidGroup/LongGroup) in the same file,
% tagged per-row by a NumCategories column (2 or 3) and a SessionMode
% column ('alternate').
%
% WHAT THIS DOES: backfills a TakeoffTime_s column if the session predates
% it (BackfillTakeoffTime.m -- a no-op if it is already there), splits the
% (possibly backfilled) session into its 2-category rows and its
% 3-category rows (SplitAlternatingSessionCsv.m), then runs EACH half
% through the existing, UNMODIFIED AnalyzePsychometricCurves.m -- the same
% psychometric-curve/SDT/ordinal-model/bootstrap engine already used for
% ordinary single-category-count sessions (its chronometric-curve fitting
% is what AnalyzePsychometricCurvesMultiSession.m adds when pooling >=2
% sessions -- see AnalyzePsychometricCurvesMultiSessionAlternating.m for
% that path; a single session run through THIS function has no
% chronometric curve to speak of). See SplitAlternatingSessionCsv.m's
% header for why the split (rather than a new fitting engine) is the
% correct approach: this session's ChosenTarget coding matches
% AnalyzePsychometricCurves.m's own convention exactly, and an
% ordinal-boundary model is only defined for a fixed category count, so the
% 2-cat blocks and 3-cat blocks must be fit separately regardless.
%
% 'ChronometricTimeSource'={'Takeoff','TakeoffToTarget'} is always forwarded
% to AnalyzePsychometricCurves.m (not one of this function's own options):
% any chronometric curve built off this session's data -- here or later, by
% whatever pools it -- is target-onset -> movement takeoff AND (separately)
% movement takeoff -> target-reached, never the original target-onset ->
% target-reached. See BackfillTakeoffTime.m.
%
% NO STATISTICS/OPTIMIZATION TOOLBOX IS USED (inherited from
% AnalyzePsychometricCurves.m: fminsearch + erf/erfinv only).
%
%   INPUT
%     csvPath : path to an "alternate" trial_data_*.csv (must have a
%               NumCategories column; see SplitAlternatingSessionCsv.m)
%
%   NAME-VALUE OPTIONS (forwarded as-is to AnalyzePsychometricCurves.m for
%   BOTH the 2-cat and 3-cat halves -- see that function's header for what
%   each one does)
%     'UseFirstAttemptOnly' (default true)
%     'LinkFunction'        (default 'logistic') -- 'logistic' | 'probit'
%     'UseLapseRates'       (default false)
%     'LapseMax'            (default 0.10)
%     'NBootstrap'          (default 1000)
%     'BootstrapAlpha'      (default 0.05)
%     'MakePlots'           (default true)
%     'FigureVisible'       (default true)
%     'FitOrdinalModel'     (default true)
%     'OutDir'              (default: <csv folder>/psychometric_analysis_alternating)
%     'Verbose'             (default true)
%
%   OUTPUT (struct results)
%     .cat2, .cat3 : the full results struct returned by
%                    AnalyzePsychometricCurves.m for the 2-category and
%                    3-category halves respectively, or [] if that session
%                    contained no rows of that category count (printed as a
%                    note, not an error -- an "alternate" session is not
%                    required to contain both block types)
%     .splitInfo   : the struct returned by SplitAlternatingSessionCsv.m
%                    (row counts per bucket, split file paths, skipped rows)
%     .csvPath, .csvBase : the ORIGINAL input, unchanged
%     .takeoffBackfillCsvPath : the path actually split/analyzed -- equal to
%                    .csvPath if it already had TakeoffTime_s, otherwise the
%                    augmented copy BackfillTakeoffTime.m wrote
%
%   USAGE
%     results = AnalyzePsychometricCurvesAlternating('trial_data_sessROM_07-Sep-2026_14-03.csv');
%     results.cat2   % 2-category-block sub-analysis (psychometric/chronometric/SDT/...)
%     results.cat3   % 3-category-block sub-analysis

% Depends on AnalyzePsychometricCurves.m + LoadSessionTrialData.m from the
% sibling src/3cat folder (unlike this project's other scripts, whose
% dependencies always live in the same folder) -- add both this file's own
% folder and ../3cat to the path so this works even if the caller only
% added this one folder.
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
addpath(fullfile(thisDir, '..', '3cat'));

% ===========================================================================
% OPTIONS (same list as AnalyzePsychometricCurves.m)
% ===========================================================================
p = inputParser;
addRequired(p, 'csvPath', @(s) ischar(s) || (isstring(s) && isscalar(s)));
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
% Forwarded to BackfillTakeoffTime.m -- set this if csvPath was pulled out
% of its original outputs/ session folder (so trajectory_movement_*.csv is
% no longer sitting next to it). See BackfillTakeoffTime.m's own header.
addParameter(p, 'TrajectoryDir', '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
parse(p, csvPath, varargin{:});
opt = p.Results;
csvPath = char(opt.csvPath);
verbose = logical(opt.Verbose);

if ~exist(csvPath, 'file')
    error('AnalyzePsychometricCurvesAlternating:fileNotFound', 'CSV not found: %s', csvPath);
end
[csvDir, csvBase, ~] = fileparts(csvPath);
if isempty(opt.OutDir)
    outDir = fullfile(csvDir, 'psychometric_analysis_alternating');
else
    outDir = char(opt.OutDir);
end
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

vprintf(verbose, '\n======= AnalyzePsychometricCurvesAlternating: %s =======\n', csvBase);

% Options forwarded to AnalyzePsychometricCurves.m for both halves (all of
% opt except OutDir, which is set per-half below).
%
% ChronometricTimeSource is hardcoded to {'Takeoff', 'TakeoffToTarget'} here
% (not exposed as one of THIS function's own options): the chronometric
% curves for "alternate" sessions are target-onset -> movement takeoff AND
% movement takeoff -> target-reached, full stop, not a choice made per
% call. See BackfillTakeoffTime below for why every alternate session can
% support both even though none of them were recorded with a TakeoffTime_s
% column.
fwd = {'UseFirstAttemptOnly', opt.UseFirstAttemptOnly, 'LinkFunction', opt.LinkFunction, ...
    'UseLapseRates', opt.UseLapseRates, 'LapseMax', opt.LapseMax, 'NBootstrap', opt.NBootstrap, ...
    'BootstrapAlpha', opt.BootstrapAlpha, 'MakePlots', opt.MakePlots, 'FigureVisible', opt.FigureVisible, ...
    'FitOrdinalModel', opt.FitOrdinalModel, 'Verbose', opt.Verbose, ...
    'ChronometricTimeSource', {'Takeoff', 'TakeoffToTarget'}};

% ===========================================================================
% BACKFILL TakeoffTime_s (no-op if the file already has it), THEN
% SPLIT into 2-category and 3-category halves
% ===========================================================================
csvPathForSplit = BackfillTakeoffTime(csvPath, 'OutDir', fullfile(outDir, 'takeoff_backfill'), ...
    'TrajectoryDir', opt.TrajectoryDir, 'Verbose', verbose);
splitInfo = SplitAlternatingSessionCsv(csvPathForSplit, fullfile(outDir, 'split_csv'), verbose);

results = struct();
results.csvPath = csvPath;
results.csvBase = csvBase;
results.takeoffBackfillCsvPath = csvPathForSplit;   % == csvPath if it already had TakeoffTime_s
results.splitInfo = splitInfo;

if ~isempty(splitInfo.path2cat)
    vprintf(verbose, '\n--- 2-category blocks (%d rows) ---\n', splitInfo.n2catRows);
    results.cat2 = AnalyzePsychometricCurves(splitInfo.path2cat, 'OutDir', fullfile(outDir, '2cat'), fwd{:});
else
    results.cat2 = [];
    vprintf(verbose, '\nNo 2-category rows in this session -- results.cat2 = [].\n');
end

if ~isempty(splitInfo.path3cat)
    vprintf(verbose, '\n--- 3-category blocks (%d rows) ---\n', splitInfo.n3catRows);
    results.cat3 = AnalyzePsychometricCurves(splitInfo.path3cat, 'OutDir', fullfile(outDir, '3cat'), fwd{:});
else
    results.cat3 = [];
    vprintf(verbose, '\nNo 3-category rows in this session -- results.cat3 = [].\n');
end

vprintf(verbose, ['\n=======================================================\n' ...
    'Done. %s: %d 2-cat row(s), %d 3-cat row(s), %d skipped. Output saved to: %s\n'], ...
    csvBase, splitInfo.n2catRows, splitInfo.n3catRows, splitInfo.nSkippedRows, outDir);
end

function vprintf(verbose, varargin)
if verbose, fprintf(varargin{:}); end
end
