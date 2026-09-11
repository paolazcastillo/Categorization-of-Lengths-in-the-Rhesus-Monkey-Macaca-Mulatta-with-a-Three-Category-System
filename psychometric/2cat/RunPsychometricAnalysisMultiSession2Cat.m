% RUNPSYCHOMETRICANALYSISMULTISESSION2CAT
%   Erick Castro
%   Sibling of RunPsychometricAnalysisMultiSession.m (the 3-category
%   driver), adapted for 2-category sessions. Opens a NATIVE file-selection
%   dialog (uigetfile) to CHOOSE SEVERAL trial_data_*.csv sessions and
%   analyzes them TOGETHER with AnalyzePsychometricCurvesMultiSession2Cat.m:
%   one COMBINED set of curves (with session-level, not trial-level,
%   bootstrap) plus a session-by-session comparison table/plots.
%
%   THIS FILE IS THE ONLY REAL DIFFERENCE vs. the 3-cat driver: it calls
%   AnalyzePsychometricCurvesMultiSession2Cat instead of
%   AnalyzePsychometricCurvesMultiSession, and the QUICK-EDIT paths below
%   point to a 2-category folder by default (ADJUST THEM to wherever you
%   actually keep your 2-cat CSVs and the .m scripts).
%
%   Requires on the path: AnalyzePsychometricCurvesMultiSession2Cat.m,
%   AnalyzePsychometricCurves2Cat.m and LoadSessionTrialData2Cat.m (see
%   QUICK-EDIT).
%
%   BEHAVIOR:
%     - A file-selection dialog opens (native uigetfile), starting in
%       'startDir', filtered to 'trial_data_*.csv'.
%     - You MUST select AT LEAST 2 files (Ctrl+click / Shift+click); if
%       you select only 1, the script stops and suggests using
%       RunPsychometricAnalysis2Cat.m instead (if you have it) or calling
%       AnalyzePsychometricCurves2Cat.m directly (there is no point
%       "combining" a single session).
%     - If you cancel the dialog without choosing anything, the script
%       stops without doing anything (not an error).
%     - If the chosen sessions do NOT share the same category structure
%       (2 categories, same names/order), or are NOT in the SAME bar-size
%       unit (all in degrees or all in pixels),
%       AnalyzePsychometricCurvesMultiSession2Cat.m stops with an explicit
%       error indicating which session differs -- do not try to force
%       that, re-select only sessions that are compatible with each other.

% ===========================================================================
% QUICK-EDIT -- ADJUST THESE 3 PATHS for your computer before running
% ===========================================================================
scriptDir = 'C:\path\to\your\Proyecto';
startDir  = 'C:\path\to\your\Proyecto\Resultados_2CATEG';
outDir    = 'C:\path\to\your\Proyecto\Resultados_2CATEG\PsychometricAnalysis\MultiSession';

% ===========================================================================
addpath(scriptDir);

[fileNames, filePath] = uigetfile( ...
    fullfile(startDir, 'trial_data_*.csv'), ...
    'Select 2 or more trial_data_*.csv files (2 categories) to analyze TOGETHER', ...
    'MultiSelect', 'on');

if isequal(fileNames, 0)
    fprintf('Cancelled -- no file was selected. Nothing was done.\n');
    return;
end

% uigetfile returns a char (not a cell) when a SINGLE file is selected.
if ischar(fileNames)
    fileNames = {fileNames};
end
nFiles = numel(fileNames);

if nFiles < 2
    fprintf(['You selected only 1 file -- this script is for COMBINING several sessions.\n' ...
        'To analyze a single session on its own, use AnalyzePsychometricCurves2Cat.m directly ' ...
        '(e.g.: results = AnalyzePsychometricCurves2Cat(csvPath)).\n' ...
        'Nothing was done.\n']);
    return;
end

fprintf('%d file(s) selected to combine:\n', nFiles);
csvPaths = cell(1, nFiles);
for i = 1:nFiles
    csvPaths{i} = fullfile(filePath, fileNames{i});
    fprintf('  %d) %s\n', i, fileNames{i});
end

results = AnalyzePsychometricCurvesMultiSession2Cat(csvPaths, 'OutDir', outDir);

fprintf('\n=======================================================\n');
fprintf('Done. Combined analysis of %d sessions (2 categories) saved to: %s\n', nFiles, outDir);
fprintf('Individual per-session results (for the comparison table) in: %s\n', ...
    fullfile(outDir, 'per_session'));
