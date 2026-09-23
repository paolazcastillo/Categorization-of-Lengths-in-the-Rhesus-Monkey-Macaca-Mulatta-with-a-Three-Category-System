% RUNPSYCHOMETRICANALYSISMULTISESSIONALTERNATING
%   Sibling of RunPsychometricAnalysisMultiSession.m and
%   RunPsychometricAnalysisMultiSession2Cat.m, adapted for "alternate"
%   sessions (a single trial_data_*.csv mixing 2-category and 3-category
%   blocks, tagged per-row by a NumCategories column). Opens a NATIVE
%   file-selection dialog (uigetfile) to CHOOSE SEVERAL alternate session
%   CSVs and analyzes them TOGETHER with
%   AnalyzePsychometricCurvesMultiSessionAlternating.m: every session is
%   first split into its 2-category rows and its 3-category rows
%   (SplitAlternatingSessionCsv.m), then all the 2-category splits are
%   pooled together and, separately, all the 3-category splits are pooled
%   together -- each pool going through the same
%   AnalyzePsychometricCurvesMultiSession.m engine used for ordinary
%   single-category-count sessions.
%
%   Requires on the path: AnalyzePsychometricCurvesMultiSessionAlternating.m,
%   AnalyzePsychometricCurvesAlternating.m, SplitAlternatingSessionCsv.m,
%   and (from src/3cat) AnalyzePsychometricCurvesMultiSession.m,
%   AnalyzePsychometricCurves.m, LoadSessionTrialData.m (see QUICK-EDIT).
%
%   BEHAVIOR:
%     - A file-selection dialog opens (native uigetfile), starting in
%       'startDir', filtered to 'trial_data_*.csv'.
%     - You MUST select AT LEAST 2 files (Ctrl+click / Shift+click); if
%       you select only 1, the script stops and suggests calling
%       AnalyzePsychometricCurvesAlternating.m directly instead (there is
%       no point "combining" a single session).
%     - If you cancel the dialog without choosing anything, the script
%       stops without doing anything (not an error).
%     - Each selected session does not need to contain both block types --
%       AnalyzePsychometricCurvesMultiSessionAlternating.m reports how many
%       sessions ended up contributing to each pool, and falls back to a
%       single-session (non-pooled) analysis if only 1 session has rows of
%       a given category count.

% ===========================================================================
% QUICK-EDIT -- ADJUST THESE PATHS for your computer before running
% ===========================================================================
startDir  = 'C:\path\to\your\Proyecto\Resultados_Alternating';
outDir    = 'C:\Users\LabB15\Documents\Erick\Erick\Proyecto\Resultados_AltCATEG\Análisis\Resultados';
% Only needed if your trial_data_*.csv files were pulled out of their
% original outputs/ session folders (so trajectory_movement_*.csv is no
% longer sitting next to each one) -- point this at the task's outputs
% root (e.g. '...\outputs\alternate') so BackfillTakeoffTime.m can still
% find them; the chronometric curve is target-onset -> movement takeoff
% and needs that file. Leave as '' if trial_data_*.csv already lives next
% to its trajectory_movement_*.csv (the normal, un-consolidated layout).
trajectoryDir = 'C:\Users\LabB15\Documents\Erick\CategTask_GitHub\Categorization-of-Lengths-in-the-Rhesus-Monkey-Macaca-Mulatta-with-a-Three-Category-System\outputs\alternate';

% ===========================================================================
% Always add this script's own folder (src/alternate) AND its sibling
% src/3cat folder to the path, so MATLAB can find
% AnalyzePsychometricCurvesMultiSessionAlternating.m,
% AnalyzePsychometricCurvesAlternating.m, SplitAlternatingSessionCsv.m
% (here) and AnalyzePsychometricCurvesMultiSession.m,
% AnalyzePsychometricCurves.m, LoadSessionTrialData.m (in ../3cat) even when
% the working directory is elsewhere.
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
addpath(fullfile(thisDir, '..', '3cat'));

[fileNames, filePath] = uigetfile( ...
    fullfile(startDir, 'trial_data_*.csv'), ...
    'Select 2 or more "alternate" trial_data_*.csv files to analyze TOGETHER', ...
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
        'To analyze a single "alternate" session on its own, use AnalyzePsychometricCurvesAlternating.m ' ...
        'directly (e.g.: results = AnalyzePsychometricCurvesAlternating(csvPath)).\n' ...
        'Nothing was done.\n']);
    return;
end

fprintf('%d file(s) selected to combine:\n', nFiles);
csvPaths = cell(1, nFiles);
for i = 1:nFiles
    csvPaths{i} = fullfile(filePath, fileNames{i});
    fprintf('  %d) %s\n', i, fileNames{i});
end

results = AnalyzePsychometricCurvesMultiSessionAlternating(csvPaths, 'OutDir', outDir, ...
    'TrajectoryDir', trajectoryDir);

fprintf('\n=======================================================\n');
fprintf('Done. Combined "alternate" analysis of %d sessions saved to: %s\n', nFiles, outDir);
fprintf('2-category pool in: %s\n', fullfile(outDir, '2cat'));
fprintf('3-category pool in: %s\n', fullfile(outDir, '3cat'));
