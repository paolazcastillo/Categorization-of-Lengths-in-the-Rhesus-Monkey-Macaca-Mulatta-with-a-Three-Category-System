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
% 'ChronometricTimeSource'={'Takeoff','TakeoffToTarget'} always forced on
% that call, so the pooled chronometric curves are target-onset -> movement
% takeoff AND (separately) movement takeoff -> target-reached, never the
% original target-onset -> target-reached (not one of this function's own
% options; see BackfillTakeoffTime.m for why every alternate session can
% support both). See SplitAlternatingSessionCsv.m and
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
% ChronometricTimeSource is hardcoded to {'Takeoff', 'TakeoffToTarget'} here
% (not exposed as one of THIS function's own options): the pooled
% chronometric curves for "alternate" sessions are target-onset -> movement
% takeoff AND movement takeoff -> target-reached, full stop, not a choice
% made per call. See the backfill loop below for why every alternate
% session can support both even though none of them were recorded with a
% TakeoffTime_s column.
fwdMulti = {'UseFirstAttemptOnly', opt.UseFirstAttemptOnly, 'LinkFunction', opt.LinkFunction, ...
    'UseLapseRates', opt.UseLapseRates, 'LapseMax', opt.LapseMax, 'NBootstrap', opt.NBootstrap, ...
    'BootstrapAlpha', opt.BootstrapAlpha, 'MakePlots', opt.MakePlots, 'FigureVisible', opt.FigureVisible, ...
    'FitOrdinalModel', opt.FitOrdinalModel, 'Verbose', opt.Verbose, ...
    'RunPerSessionComparison', opt.RunPerSessionComparison, 'PerSessionMakePlots', opt.PerSessionMakePlots, ...
    'MakeComparisonPlots', opt.MakeComparisonPlots, 'ChronometricTimeSource', {'Takeoff', 'TakeoffToTarget'}};
fwdSingle = {'UseFirstAttemptOnly', opt.UseFirstAttemptOnly, 'LinkFunction', opt.LinkFunction, ...
    'UseLapseRates', opt.UseLapseRates, 'LapseMax', opt.LapseMax, 'NBootstrap', opt.NBootstrap, ...
    'BootstrapAlpha', opt.BootstrapAlpha, 'MakePlots', opt.MakePlots, 'FigureVisible', opt.FigureVisible, ...
    'FitOrdinalModel', opt.FitOrdinalModel, 'Verbose', opt.Verbose, ...
    'ChronometricTimeSource', {'Takeoff', 'TakeoffToTarget'}};

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

% -----------------------------------------------------------------------
% TRIAL SUMMARY TABLE -- one row per original session, totals at the bottom
% -----------------------------------------------------------------------
writeAlternatingTrialSummaryTable(results, nSessions, outDir, logical(opt.FigureVisible), verbose);

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

% =========================================================================
% TRIAL SUMMARY TABLE -- local helpers
% =========================================================================

function writeAlternatingTrialSummaryTable(results, nSessions, outDir, figureVisible, verbose)
% WRITEALTERNATINGTRIALSUMMARYTABLE
%   Writes alternating_trial_summary.csv to outDir with one data row per
%   original (alternating) session plus a TOTAL row.
%
%   Columns for each of the 2-cat and 3-cat buckets:
%     TrialsFit        -- trials actually used in the psychometric fit
%                         (= nCorrect + nError, after all exclusions)
%     Correct          -- correct trials among TrialsFit
%     Incorrect        -- incorrect trials among TrialsFit
%     CorrectRaw       -- correct trials among all nRows usable rows
%                         (BEFORE omission / retry / unexpected-code exclusion)
%     IncorrectRaw     -- incorrect trials among all nRows usable rows
%     Excl_Omission    -- omitted / no-response trials excluded
%     Excl_Retry       -- retry (Attempt>1) trials excluded
%     Excl_UnexpCode   -- unexpected ChosenTarget-code trials excluded
%     Excl_Psychometric-- 'No' | 'Yes: <reason>' (session skipped entirely)
%     Excl_Chronometric-- 'No' | 'Yes: timing schema unresolved' | 'N/A'

splitInfoPerSession = results.splitInfoPerSession;

% Build index maps: for each original session i,
%   idx2cat(i) = position of session i in the 2-cat pool (0 if not in pool)
%   idx3cat(i) = position of session i in the 3-cat pool (0 if not in pool)
idx2cat = zeros(1, nSessions);
idx3cat = zeros(1, nSessions);
j2 = 0; j3 = 0;
for i = 1:nSessions
    if ~isempty(splitInfoPerSession{i}.path2cat)
        j2 = j2 + 1;
        idx2cat(i) = j2;
    end
    if ~isempty(splitInfoPerSession{i}.path3cat)
        j3 = j3 + 1;
        idx3cat(i) = j3;
    end
end

header = {'Session', ...
    'TotalRows_OrigCSV', 'Rows2cat', 'Rows3cat', 'Skipped_InvalidNumCat', ...
    'TrialsFit_2cat',  'Correct_2cat',  'Incorrect_2cat',  'CorrectRaw_2cat',  'IncorrectRaw_2cat', ...
    'Excl_Omission_2cat', 'Excl_Retry_2cat', 'Excl_UnexpCode_2cat', ...
    'Excl_Psychometric_2cat', 'Excl_Chronometric_2cat', ...
    'TrialsFit_3cat',  'Correct_3cat',  'Incorrect_3cat',  'CorrectRaw_3cat',  'IncorrectRaw_3cat', ...
    'Excl_Omission_3cat', 'Excl_Retry_3cat', 'Excl_UnexpCode_3cat', ...
    'Excl_Psychometric_3cat', 'Excl_Chronometric_3cat', ...
    'Notes'};
nCols = numel(header);

rows = cell(nSessions, nCols);

for i = 1:nSessions
    si = splitInfoPerSession{i};
    totalRows = si.n2catRows + si.n3catRows + si.nSkippedRows;

    % Per-bucket meta + exclusion flags
    [m2, ep2, ec2] = getBucketSessionMeta(results.cat2, idx2cat(i), si.csvBase, '2cat');
    [m3, ep3, ec3] = getBucketSessionMeta(results.cat3, idx3cat(i), si.csvBase, '3cat');

    % Notes: collect any non-empty notes from both buckets
    noteParts = {};
    if ~isempty(m2) && isfield(m2, 'note') && ~isempty(m2.note)
        noteParts{end+1} = ['2cat: ' m2.note]; %#ok<AGROW>
    end
    if ~isempty(m3) && isfield(m3, 'note') && ~isempty(m3.note)
        noteParts{end+1} = ['3cat: ' m3.note]; %#ok<AGROW>
    end

    rows{i,  1} = si.csvBase;
    rows{i,  2} = sprintf('%d', totalRows);
    rows{i,  3} = sprintf('%d', si.n2catRows);
    rows{i,  4} = sprintf('%d', si.n3catRows);
    rows{i,  5} = sprintf('%d', si.nSkippedRows);

    % 2-cat numeric columns
    if ~isempty(m2)
        rows{i,  6} = sprintf('%d', m2.nCorrect + m2.nError);
        rows{i,  7} = sprintf('%d', m2.nCorrect);
        rows{i,  8} = sprintf('%d', m2.nError);
        rows{i,  9} = sprintf('%d', m2.nCorrectRaw);
        rows{i, 10} = sprintf('%d', m2.nErrorRaw);
        rows{i, 11} = sprintf('%d', m2.nOmission);
        rows{i, 12} = sprintf('%d', m2.nExcludedRetry);
        rows{i, 13} = sprintf('%d', m2.nUnexpectedCode);
    else
        for c = 6:13; rows{i, c} = '0'; end
    end
    rows{i, 14} = ep2;
    rows{i, 15} = ec2;

    % 3-cat numeric columns
    if ~isempty(m3)
        rows{i, 16} = sprintf('%d', m3.nCorrect + m3.nError);
        rows{i, 17} = sprintf('%d', m3.nCorrect);
        rows{i, 18} = sprintf('%d', m3.nError);
        rows{i, 19} = sprintf('%d', m3.nCorrectRaw);
        rows{i, 20} = sprintf('%d', m3.nErrorRaw);
        rows{i, 21} = sprintf('%d', m3.nOmission);
        rows{i, 22} = sprintf('%d', m3.nExcludedRetry);
        rows{i, 23} = sprintf('%d', m3.nUnexpectedCode);
    else
        for c = 16:23; rows{i, c} = '0'; end
    end
    rows{i, 24} = ep3;
    rows{i, 25} = ec3;
    rows{i, 26} = strjoin(noteParts, ' | ');
end

% ----- TOTALS row -----
numCols_idx = [2:5, 6:13, 16:23];   % columns that hold plain integers
totals = repmat({''}, 1, nCols);
totals{1} = 'TOTAL';
for c = numCols_idx
    vals = cellfun(@(r) str2double(r), rows(:, c));
    totals{c} = sprintf('%d', sum(vals(~isnan(vals))));
end
% Text-flag columns: count how many sessions are NOT 'No'
nExclPsych2  = sum(~strcmp(rows(:, 14), 'No'));
nExclChrono2 = sum(~strcmp(rows(:, 15), 'No'));
nExclPsych3  = sum(~strcmp(rows(:, 24), 'No'));
nExclChrono3 = sum(~strcmp(rows(:, 25), 'No'));
totals{14} = sprintf('%d sessions excl.', nExclPsych2);
totals{15} = sprintf('%d sessions excl.', nExclChrono2);
totals{24} = sprintf('%d sessions excl.', nExclPsych3);
totals{25} = sprintf('%d sessions excl.', nExclChrono3);
totals{26} = '';

% ----- Write CSV -----
fname = fullfile(outDir, 'alternating_trial_summary.csv');
fid = fopen(fname, 'w');
if fid < 0
    warning('AnalyzePsychometricCurvesMultiSessionAlternating:summaryWriteFailed', ...
        'Could not open %s for writing -- trial summary table not saved.', fname);
    return;
end
fprintf(fid, '%s\n', strjoin(header, ','));
for i = 1:nSessions
    % Escape any comma inside a cell by wrapping in quotes
    safeRow = cellfun(@(s) quoteIfNeeded(s), rows(i, :), 'UniformOutput', false);
    fprintf(fid, '%s\n', strjoin(safeRow, ','));
end
safeTotals = cellfun(@(s) quoteIfNeeded(s), totals, 'UniformOutput', false);
fprintf(fid, '%s\n', strjoin(safeTotals, ','));
fclose(fid);

vprintf(verbose, 'Saved: %s\n', fname);

% Render the same data as PNG figure(s) alongside the CSV
try
    [fA, fB] = renderAlternatingTrialSummaryFigure(rows, totals, header, nSessions, outDir, figureVisible);
    vprintf(verbose, 'Saved: %s\n', fA);
    vprintf(verbose, 'Saved: %s\n', fB);
catch ME_fig
    warning('AnalyzePsychometricCurvesMultiSessionAlternating:summaryFigureFailed', ...
        'Could not render trial summary figure: %s', ME_fig.message);
end
end

% -------------------------------------------------------------------------

function [fnameA, fnameB] = renderAlternatingTrialSummaryFigure(rows, totals, header, nSessions, outDir, figureVisible)
% RENDERALTERNATINGTRIALSUMMARYFIGURE
%   Saves TWO PNG files to outDir:
%     alternating_trial_summary_2cat.png  -- overview + 2-cat columns
%     alternating_trial_summary_3cat.png  -- 3-cat columns + Notes
%   Both include the Session column as the first column.
%   Uses only base-MATLAB functions (rectangle + text in axes); no toolbox.

vis = 'off';
if logical(figureVisible), vis = 'on'; end

colsA = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
colsB = [1, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26];

fnameA = fullfile(outDir, 'alternating_trial_summary_2cat.png');
fnameB = fullfile(outDir, 'alternating_trial_summary_3cat.png');

renderTableToFigure(rows, totals, header, colsA, nSessions, fnameA, vis, ...
    'Trial Summary  —  2-category bucket');
renderTableToFigure(rows, totals, header, colsB, nSessions, fnameB, vis, ...
    'Trial Summary  —  3-category bucket');
end

% -------------------------------------------------------------------------

function renderTableToFigure(rows, totals, header, colIdx, nDataRows, fname, vis, titleStr)
% RENDERTABLETOFIGURE  Draw a colour-coded table as a MATLAB figure and
% save it as a PNG.  No toolbox required: uses rectangle() + text() in an
% axes to render each cell.

nCols = numel(colIdx);

% Proportional column widths based on max character count in each column
colCharW = zeros(1, nCols);
for ci = 1:nCols
    c = colIdx(ci);
    w = numel(header{c});
    for r = 1:nDataRows
        if ~isempty(rows{r, c}), w = max(w, numel(rows{r, c})); end
    end
    if ~isempty(totals{c}), w = max(w, numel(totals{c})); end
    colCharW(ci) = max(w + 1, 4);
end
colFrac = colCharW / sum(colCharW);
xLeft   = [0, cumsum(colFrac)];

% Figure pixel dimensions
pxPerChar = 7;
figW = max(1100, round(sum(colCharW) * pxPerChar));
rowPx    = 22;
headPx   = 36;
titlePx  = 32;
marginPx = 16;
nAllRows = 1 + nDataRows + 1;
figH     = titlePx + headPx + nDataRows * rowPx + rowPx + 2 * marginPx;

fig = figure('Visible', vis, 'Units', 'pixels', ...
    'Position', [50, 50, figW, figH], 'Color', [1 1 1]);

axLeft_px = marginPx;
axBot_px  = marginPx;
axW_px    = figW - 2 * marginPx;
axH_px    = headPx + nDataRows * rowPx + rowPx;
ax = axes('Parent', fig, 'Units', 'pixels', ...
    'Position', [axLeft_px, axBot_px, axW_px, axH_px], ...
    'XLim', [0 1], 'YLim', [0 nAllRows], ...
    'YDir', 'reverse', 'Visible', 'off');
hold(ax, 'on');

cHead   = [0.15 0.38 0.70];
cHeadTx = [1.00 1.00 1.00];
cOdd    = [1.00 1.00 1.00];
cEven   = [0.93 0.95 1.00];
cTot    = [0.99 0.91 0.58];
cTotTx  = [0.27 0.17 0.00];
cGrid   = [0.60 0.60 0.60];
fSz     = 7;

for pass = 1:3
    if pass == 1
        for ci = 1:nCols
            x0 = xLeft(ci); w = colFrac(ci);
            lbl = strrep(header{colIdx(ci)}, '_', ' ');
            rectangle('Parent', ax, 'Position', [x0, 0, w, 1], ...
                'FaceColor', cHead, 'EdgeColor', cGrid, 'LineWidth', 0.5);
            text(ax, x0 + w/2, 0.5, lbl, ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
                'FontSize', fSz, 'FontWeight', 'bold', 'Color', cHeadTx, ...
                'Interpreter', 'none', 'Clipping', 'on');
        end
    elseif pass == 2
        for r = 1:nDataRows
            if mod(r, 2) == 1, bgC = cOdd; else, bgC = cEven; end
            for ci = 1:nCols
                c  = colIdx(ci);
                x0 = xLeft(ci); w = colFrac(ci);
                txt = rows{r, c};
                if isempty(txt), txt = ''; end
                rectangle('Parent', ax, 'Position', [x0, r, w, 1], ...
                    'FaceColor', bgC, 'EdgeColor', cGrid, 'LineWidth', 0.3);
                if ci == 1
                    text(ax, x0 + 0.004, r + 0.5, txt, ...
                        'HorizontalAlignment', 'left', 'VerticalAlignment', 'middle', ...
                        'FontSize', fSz, 'FontWeight', 'normal', 'Color', [0 0 0], ...
                        'Interpreter', 'none', 'Clipping', 'on');
                else
                    text(ax, x0 + w/2, r + 0.5, txt, ...
                        'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
                        'FontSize', fSz, 'FontWeight', 'normal', 'Color', [0 0 0], ...
                        'Interpreter', 'none', 'Clipping', 'on');
                end
            end
        end
    else
        yTot = nDataRows + 1;
        for ci = 1:nCols
            c  = colIdx(ci);
            x0 = xLeft(ci); w = colFrac(ci);
            txt = totals{c};
            if isempty(txt), txt = ''; end
            rectangle('Parent', ax, 'Position', [x0, yTot, w, 1], ...
                'FaceColor', cTot, 'EdgeColor', cGrid, 'LineWidth', 0.5);
            text(ax, x0 + w/2, yTot + 0.5, txt, ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
                'FontSize', fSz, 'FontWeight', 'bold', 'Color', cTotTx, ...
                'Interpreter', 'none', 'Clipping', 'on');
        end
    end
end

annotation(fig, 'textbox', ...
    [axLeft_px/figW, (axBot_px + axH_px)/figH, axW_px/figW, titlePx/figH], ...
    'String', titleStr, 'FontSize', 9, 'FontWeight', 'bold', ...
    'EdgeColor', 'none', 'BackgroundColor', 'none', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
    'Interpreter', 'none', 'FitBoxToText', false);

print(fig, fname, '-dpng', '-r150');
if strcmp(vis, 'off')
    close(fig);
end
end

% -------------------------------------------------------------------------

function [meta, excl_psych, excl_chrono] = getBucketSessionMeta(poolResult, poolIdx, origCsvBase, suffix)
% GETBUCKETSESSIONMETA  Extract per-session analysis metadata for one
% bucket (2cat or 3cat) of one original session.
%
%   poolResult  : results.cat2 or results.cat3 (can be [], a single-session
%                 AnalyzePsychometricCurves result, or a multi-session
%                 AnalyzePsychometricCurvesMultiSession result)
%   poolIdx     : index of this session in the pool (0 if session had no
%                 rows of this bucket type)
%   origCsvBase : original session's csvBase (e.g. 'trial_data_sessROM_...')
%   suffix      : '2cat' or '3cat'
%
%   meta        : results.meta struct for this session's bucket analysis,
%                 or [] if not available
%   excl_psych  : 'No' | 'Yes: <reason>'
%   excl_chrono : 'No' | 'Yes: timing schema unresolved' | 'N/A'

meta        = [];
excl_psych  = 'No';
excl_chrono = 'No';
splitBase   = [origCsvBase '_' suffix];   % base name of the split CSV file

if isempty(poolResult)
    excl_psych  = 'Yes: no rows of this type in any session';
    excl_chrono = 'N/A';
    return;
end

if poolIdx == 0
    excl_psych  = 'Yes: no rows of this type in this session';
    excl_chrono = 'N/A';
    return;
end

isPooled = isfield(poolResult, 'pooled') && logical(poolResult.pooled);

if isPooled
    % ---------- Multi-session result (AnalyzePsychometricCurvesMultiSession) ----------
    % Per-session full results (each element is a single-session
    % AnalyzePsychometricCurves result, or [] if that session's analysis failed).
    if isfield(poolResult, 'perSessionFullResults') && ...
            poolIdx <= numel(poolResult.perSessionFullResults) && ...
            ~isempty(poolResult.perSessionFullResults{poolIdx})
        meta = poolResult.perSessionFullResults{poolIdx}.meta;
    end

    % Chronometric exclusion: check the explicit excluded-session list
    if isfield(poolResult, 'chronometric')
        ch = poolResult.chronometric;
        if isfield(ch, 'excludedSessions') && any(strcmp(ch.excludedSessions, splitBase))
            excl_chrono = 'Yes: timing schema unresolved';
        elseif isfield(ch, 'available') && ~ch.available
            excl_chrono = 'Yes: chronometric curve not available';
        end
    else
        excl_chrono = 'N/A';
    end

else
    % ---------- Single-session fallback (AnalyzePsychometricCurves) ----------
    % poolResult IS the single-session analysis result; .meta is at top level.
    if isfield(poolResult, 'meta')
        meta = poolResult.meta;
    end
    % AnalyzePsychometricCurves does not produce a chronometric curve -- flag it
    excl_chrono = 'N/A (single-session bucket -- no chronometric curve)';
end
end

% -------------------------------------------------------------------------

function s = quoteIfNeeded(s)
% Wrap a string in double-quotes if it contains a comma, so the CSV cell
% stays intact. Double any internal double-quote per RFC 4180.
if isempty(s), return; end
if any(s == ',') || any(s == '"')
    s = ['"' strrep(s, '"', '""') '"'];
end
end
