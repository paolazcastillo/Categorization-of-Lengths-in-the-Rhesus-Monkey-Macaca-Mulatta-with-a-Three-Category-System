% RUNPSYCHOMETRICANALYSISMULTISESSION
%   Erick Castro 
%   Opens a dialog to CHOOSE SEVERAL trial_data_*.csv sessions and analyzes
%   them TOGETHER with AnalyzePsychometricCurvesMultiSession.m: one
%   COMBINED set of curves (with session-level, not trial-level, bootstrap)
%   plus a session-by-session comparison table/plots 
%   RunPsychometricAnalysis.m runs each selected session
%   SEPARATELY (one set of curves per session, nothing combined).
%
%   Requires on the path: AnalyzePsychometricCurvesMultiSession.m,
%   AnalyzePsychometricCurves.m and LoadSessionTrialData.m (see QUICK-EDIT).
%
%   BEHAVIOR:
%     - A file-selection dialog opens (native uigetfile), starting in
%       'startDir', filtered to 'trial_data_*.csv'.
%     - You MUST select AT LEAST 2 files. if
%       you select only 1, the script stops and suggests using
%       RunPsychometricAnalysis.m instead.
%     - If you cancel the dialog without choosing anything, the script
%       stops without doing anything (not an error).
%     - If the chosen sessions do NOT share the same category structure
%       (e.g. you mix a 2-category session with a 3-category one),
%       AnalyzePsychometricCurvesMultiSession.m stops with an explicit
%       error indicating which session differs -- do not try to force
%       that, re-select only sessions from the same task type.

% ===========================================================================
% QUICK-EDIT, CHANGE THIS TO MATCH THE FOLDER WHERE YOUR DATA IS BEFORE RUNNING
% ===========================================================================
scriptDir = 'C:\path\to\your\Proyecto';
startDir  = 'C:\path\to\your\Proyecto\Resultados_3CATEG';
outDir    = 'C:\path\to\your\Proyecto\Resultados_3CATEG\PsychometricAnalysis\MultiSession';

% ===========================================================================
% Always add the folder that contains THIS script to the path so MATLAB
% can find AnalyzePsychometricCurvesMultiSession.m, AnalyzePsychometricCurves.m
% and LoadSessionTrialData.m even when the working directory is elsewhere.
thisDir = fileparts(mfilename('fullpath'));
addpath(thisDir);
addpath(scriptDir);  

[fileNames, filePath] = uigetfile( ...
    fullfile(startDir, 'trial_data_*.csv'), ...
    'Select 2 or more trial_data_*.csv files to analyze TOGETHER', ...
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
        'To analyze a single session on its own, use RunPsychometricAnalysis.m instead.\n' ...
        'Nothing was done.\n']);
    return;
end

fprintf('%d file(s) selected to combine:\n', nFiles);
csvPaths = cell(1, nFiles);
for i = 1:nFiles
    csvPaths{i} = fullfile(filePath, fileNames{i});
    fprintf('  %d) %s\n', i, fileNames{i});
end

results = AnalyzePsychometricCurvesMultiSession(csvPaths, 'OutDir', outDir);

fprintf('\n=======================================================\n');
fprintf('Done. Combined analysis of %d sessions saved to: %s\n', nFiles, outDir);
fprintf('Individual per-session results (for the comparison table) in: %s\n', ...
    fullfile(outDir, 'per_session'));
