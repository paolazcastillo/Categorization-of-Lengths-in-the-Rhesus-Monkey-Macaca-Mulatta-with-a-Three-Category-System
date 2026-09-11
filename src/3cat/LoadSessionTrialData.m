function S = LoadSessionTrialData(csvPath, useFirstAttemptOnly, verbose)
% LOADSESSIONTRIALDATA  Load + clean one trial_data_*.csv from
% CenterOutTask.m into ready-to-fit trial-level vectors.
%
% Extracted out of AnalyzePsychometricCurves.m so the SAME loading/
% cleaning/exclusion logic (column resolution, ChosenTarget-code learning,
% omission/retry exclusions and all the explicit errors warnings)
% is used by both the single-session script and
% AnalyzePsychometricCurvesMultiSession.m. AnalyzePsychometricCurves.m's own behavior is
% UNCHANGED by this refactor; it now calls this function instead of
% inlining the same code, but produces byte-identical results.
%
%   INPUT
%     csvPath             : path to a trial_data_*.csv
%     useFirstAttemptOnly : true/false -- see AnalyzePsychometricCurves.m's
%                        
%     verbose              : true/false -- print load/exclusion summary
%
%   OUTPUT (struct S)
%     .xFit, .rankFit, .stimRankFit, .dirFit : trial-level vectors, ALREADY
%         filtered down to the rows used for fitting (equivalent to
%         AnalyzePsychometricCurves.m's xFit/rankFit/stimRankFit/dirFit)
%     .groupNames, .groupCode, .nCat : category structure (ascending by
%         true bar length), learned the same way as the single-session script
%     .csvPath, .csvBase : copied back for labeling
%     .nRowsRaw, .nRows, .nOmission, .nExcludedRetry, .nUnexpected : the
%         same exclusion counters AnalyzePsychometricCurves.m reports
%

if ~exist(csvPath, 'file')
    error('LoadSessionTrialData:fileNotFound', 'CSV not found: %s', csvPath);
end
[~, csvBase, ~] = fileparts(csvPath);

% ===========================================================================
% LOAD + RESOLVE COLUMNS
% ===========================================================================
T = loadCsvAsStruct(csvPath);
nRowsRaw = numel(T.raw{1});
vprintf(verbose, 'Loaded %d rows, %d columns.\n', nRowsRaw, numel(T.colnames));

colStimGroup = resolveColumn(T.colnames, {'StimulusGroup'}, true, 'true category (StimulusGroup)');
colBarSize   = resolveColumn(T.colnames, {'BarSizeVA_deg', 'BarSizeVA'}, true, 'bar length (BarSizeVA)');
colIsCorrect = resolveColumn(T.colnames, {'IsCorrect'}, true, 'IsCorrect');
colErrorType = resolveColumn(T.colnames, {'ErrorType'}, true, 'ErrorType');
colChosen    = resolveColumn(T.colnames, {'ChosenTarget'}, true, 'ChosenTarget');
colAttempt   = resolveColumn(T.colnames, {'Attempt'}, true, 'Attempt');
colDirChosen = resolveColumn(T.colnames, {'DirectionChosen'}, false, 'DirectionChosen');
colTotal = resolveColumn(T.colnames, {'TotalTime_s'}, false, 'TotalTime_s');
colExec  = resolveColumn(T.colnames, {'ExecutionTime_s'}, false, 'ExecutionTime_s');
colReact = resolveColumn(T.colnames, {'ReactionTime_s'}, false, 'ReactionTime_s');
colDecision = resolveColumn(T.colnames, {'DecisionTime_s'}, false, 'DecisionTime_s');

if any(strcmp({colStimGroup, colBarSize, colIsCorrect, colErrorType, colChosen, colAttempt}, ''))
    error('LoadSessionTrialData:missingColumns', ...
        'One or more required columns could not be resolved in %s. Available columns: %s', ...
        csvPath, strjoin(T.colnames, ', '));
end

stimGroup = T.raw{strcmp(T.colnames, colStimGroup)};
[barSize, nBadBarSize]   = toNumeric(T.raw{strcmp(T.colnames, colBarSize)});
[isCorrect, ~]           = toNumeric(T.raw{strcmp(T.colnames, colIsCorrect)});
[chosenTarget, ~]        = toNumeric(T.raw{strcmp(T.colnames, colChosen)});
[attempt, ~]              = toNumeric(T.raw{strcmp(T.colnames, colAttempt)});
if ~isempty(colDirChosen)
    dirChosen = T.raw{strcmp(T.colnames, colDirChosen)};
else
    dirChosen = repmat({''}, numel(barSize), 1);
end

% timeToTarget = target-onset -> cursor-enters-target. This is to check discrepancies in how the reactions times are being logged.
if ~isempty(colTotal)
    timingSchema = 'new';
    [timeToTarget, ~] = toNumeric(T.raw{strcmp(T.colnames, colTotal)});
    if ~isempty(colDecision) && ~isempty(colReact)
        [decCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colDecision)});
        [reactCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colReact)});
        reconstructed = decCheck + reactCheck;
        badCheck = ~isnan(timeToTarget) & ~isnan(reconstructed) & (abs(timeToTarget - reconstructed) > 0.01);
        if any(badCheck)
            warning('LoadSessionTrialData:timingCrossCheckFailed', ...
                ['%s: %d row(s) where TotalTime_s does not match DecisionTime_s+ReactionTime_s ' ...
                 '(difference > 0.01s) -- check the file, the "current" format assumption might ' ...
                 'not apply.'], csvBase, nnz(badCheck));
        end
    end
elseif ~isempty(colExec) && ~isempty(colReact)
    timingSchema = 'old';
    [timeToTarget, ~] = toNumeric(T.raw{strcmp(T.colnames, colReact)});
    if ~isempty(colDecision)
        [decCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colDecision)});
        [execCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colExec)});
        reconstructed = decCheck + execCheck;
        badCheck = ~isnan(timeToTarget) & ~isnan(reconstructed) & (abs(timeToTarget - reconstructed) > 0.01);
        if any(badCheck)
            warning('LoadSessionTrialData:timingCrossCheckFailed', ...
                ['%s: %d row(s) where ReactionTime_s (v2_2-era, = total) does not match ' ...
                 'DecisionTime_s+ExecutionTime_s (difference > 0.01s) -- check the file, the ' ...
                 '"v2_2" format assumption might not apply.'], csvBase, nnz(badCheck));
        end
    end
else
    timingSchema = 'unresolved';
    timeToTarget = nan(numel(barSize), 1);
    warning('LoadSessionTrialData:timingSchemaUnresolved', ...
        ['%s: could not unambiguously determine the total-time column (target-onset -> the ' ...
         'cursor enters the target). Expected "TotalTime_s" (current format) or ' ...
         '"ExecutionTime_s"+"ReactionTime_s" together (v2_2-era format, where "ReactionTime_s" is ' ...
         'ALREADY the total -- see the "POOLING WARNING" comment in CenterOutTask.m). Available ' ...
         'columns: %s. The psychometric analysis is NOT affected; this session will be excluded ' ...
         'from any chronometric curve that depends on this time.'], csvBase, strjoin(T.colnames, ', '));
end

if nBadBarSize > 0
    warning('LoadSessionTrialData:badRows', ...
        '%s: %d row(s) had a non-numeric BarSize value and will be dropped.', csvBase, nBadBarSize);
end
validRow = ~isnan(barSize) & ~isnan(isCorrect) & ~isnan(chosenTarget) & ~isnan(attempt);
stimGroup = stimGroup(validRow);  barSize = barSize(validRow);  isCorrect = isCorrect(validRow);
chosenTarget = chosenTarget(validRow); attempt = attempt(validRow);
dirChosen = dirChosen(validRow);
timeToTarget = timeToTarget(validRow);
nRows = numel(barSize);
vprintf(verbose, '%d row(s) usable after dropping malformed rows. Timing schema detected: %s\n', nRows, timingSchema);

% ===========================================================================
% CATEGORY STRUCTURE
% ===========================================================================
uGroups = unique(stimGroup);
meanVA = nan(size(uGroups));
for i = 1:numel(uGroups)
    meanVA(i) = mean(barSize(strcmp(stimGroup, uGroups{i})));
end
[~, ord] = sort(meanVA, 'ascend');
groupNames = uGroups(ord);   % ascending by true length: e.g. {Short, Mid, Long}
nCat = numel(groupNames);
if nCat < 2
    error('LoadSessionTrialData:tooFewCategories', ...
        '%s: only %d distinct StimulusGroup value(s) found -- need at least 2 to define a boundary.', ...
        csvBase, nCat);
end

[~, stimRank] = ismember(stimGroup, groupNames);

groupCode = nan(1, nCat);
usedFallback = false(1, nCat);
for i = 1:nCat
    thisGroupCorrect = strcmp(stimGroup, groupNames{i}) & isCorrect == 1;
    codesHere = chosenTarget(thisGroupCorrect);
    codesHere = codesHere(codesHere > 0);
    if isempty(codesHere)
        usedFallback(i) = true;
    else
        groupCode(i) = mode(codesHere);
    end
end
if any(usedFallback)
    warning('LoadSessionTrialData:noCorrectTrialsForGroup', ...
        ['%s: group(s) [%s] had zero correct trials, so this script could not empirically ' ...
         'verify their ChosenTarget colour code. Falling back to the convention hardcoded ' ...
         'in CenterOutTask.m/ConfigOrgParams.m (colorRows3=[1 2 3], colorRows2=[1 3]). ' ...
         'VERIFY this manually if performance in that category was near zero.'], ...
        csvBase, strjoin(groupNames(usedFallback), ', '));
    if nCat == 3
        fallbackCodes = [1 2 3];
    elseif nCat == 2
        fallbackCodes = [1 3];
    else
        error('LoadSessionTrialData:noFallbackConvention', ...
            ['%s: %d categories found and at least one has zero correct trials, with no ' ...
             'documented ChosenTarget-code convention for that category count. Cannot proceed ' ...
             'without manual input -- inspect ChosenTarget values by hand.'], csvBase, nCat);
    end
    groupCode(usedFallback) = fallbackCodes(usedFallback);
end
vprintf(verbose, 'Category order (ascending length): %s\n', strjoin(groupNames, ' < '));
vprintf(verbose, 'ChosenTarget code learned per category: %s\n', mat2str(groupCode));

rankOfCode = containers.Map(num2cell(groupCode), num2cell(1:nCat));
chosenRank = nan(nRows, 1);
hasResponse = chosenTarget > 0;
unexpectedCode = false(nRows, 1);
for i = 1:nRows
    if hasResponse(i)
        if isKey(rankOfCode, chosenTarget(i))
            chosenRank(i) = rankOfCode(chosenTarget(i));
        else
            unexpectedCode(i) = true;
        end
    end
end
if any(unexpectedCode)
    warning('LoadSessionTrialData:unexpectedChosenTargetCode', ...
        ['%s: %d row(s) have a ChosenTarget code (%s) that does not match any learned category ' ...
         'code (%s). These rows are excluded -- inspect them manually, this usually means a ' ...
         'session mode change (e.g. alternate/interleaved) mixed codings this script does not ' ...
         'currently handle.'], csvBase, nnz(unexpectedCode), ...
        mat2str(unique(chosenTarget(unexpectedCode))'), mat2str(groupCode));
end

% ===========================================================================
% EXCLUSIONS (reported explicitly, not silently applied)
% ===========================================================================
nOmission = nnz(~hasResponse);
nUnexpected = nnz(unexpectedCode);
useRow = hasResponse & ~unexpectedCode;
if logical(useFirstAttemptOnly)
    nExcludedRetry = nnz(useRow & attempt ~= 1);
    useRow = useRow & (attempt == 1);
else
    nExcludedRetry = 0;
end

vprintf(verbose, ['\n--- Exclusions (%s) ---\n' ...
    '  Total usable rows after cleaning:        %d\n' ...
    '  No response (omission / early exit):     %d (%.1f%%)\n' ...
    '  Unexpected ChosenTarget code:             %d\n' ...
    '  Excluded as a retry (Attempt>1):          %d  (UseFirstAttemptOnly=%d)\n' ...
    '  Rows used for the fit:                     %d\n'], ...
    csvBase, nRows, nOmission, 100 * nOmission / max(nRows, 1), nUnexpected, nExcludedRetry, ...
    logical(useFirstAttemptOnly), nnz(useRow));

% Chronometric fields (target-onset -> cursor-enters-target, era-resolved
% above), aligned 1:1 with xFit/rankFit/stimRankFit/dirFit via the SAME
% useRow mask -- so a chronometric curve and the psychometric curve are
% always built from exactly the same trial set (same UseFirstAttemptOnly/
% omission/unexpected-code exclusions), never two silently different ones.
% NaN here for a useRow-selected trial despite a RESOLVED schema would be a
% contradiction (every trial with a response should have a timed value) --
% flagged loudly rather than silently propagated into a chronometric mean.
timeToTargetFit = timeToTarget(useRow);
if ~strcmp(timingSchema, 'unresolved')
    nBadTiming = nnz(isnan(timeToTargetFit));
    if nBadTiming > 0
        warning('LoadSessionTrialData:timingMissingOnUsableRows', ...
            ['%s: %d of %d row(s) used for the fit have NaN total time even though the column ' ...
             'schema WAS resolved (%s) -- unexpected (check ChosenTarget/omission); those rows ' ...
             'will be excluded from any chronometric curve.'], ...
            csvBase, nBadTiming, nnz(useRow), timingSchema);
    end
end

S = struct();
S.csvPath = csvPath;
S.csvBase = csvBase;
S.xFit = barSize(useRow);
S.rankFit = chosenRank(useRow);
S.stimRankFit = stimRank(useRow);
S.dirFit = dirChosen(useRow);
S.groupNames = groupNames;
S.groupCode = groupCode;
S.nCat = nCat;
S.nRowsRaw = nRowsRaw;
S.nRows = nRows;
S.nOmission = nOmission;
S.nExcludedRetry = nExcludedRetry;
S.nUnexpected = nUnexpected;
S.timeToTargetFit = timeToTargetFit;
S.isCorrectFit = isCorrect(useRow);
S.timingSchema = timingSchema;
end

% =========================================================================
% LOCAL HELPER FUNCTIONS (mirrors of the ones in AnalyzePsychometricCurves.m
% -- small, stable I/O utilities, duplicated by design rather than shared
% via a library file, matching this project's existing convention of
% self-contained .m files. If you ever change CSV parsing here, mirror the
% change in AnalyzePsychometricCurves.m's own copies too, or better, delete
% those and have it call this file instead of loadCsvAsStruct directly.)
% =========================================================================

function vprintf(verbose, varargin)
if verbose, fprintf(varargin{:}); end
end

function T = loadCsvAsStruct(csvPath)
fid = fopen(csvPath, 'r');
if fid < 0
    error('LoadSessionTrialData:cannotOpen', 'Could not open %s', csvPath);
end
headerLine = fgetl(fid);
colnames = strsplit(strtrim(headerLine), ',');
colnames = strtrim(colnames);
nCols = numel(colnames);
raw = cell(1, nCols);
for c = 1:nCols, raw{c} = {}; end

lineNum = 1;
while true
    tline = fgetl(fid);
    if ~ischar(tline), break; end
    if isempty(strtrim(tline)), continue; end
    fields = strsplit(tline, ',');
    if numel(fields) ~= nCols
        warning('LoadSessionTrialData:malformedLine', ...
            'Line %d has %d fields, expected %d -- skipped.', lineNum + 1, numel(fields), nCols);
        lineNum = lineNum + 1;
        continue;
    end
    for c = 1:nCols
        raw{c}{end + 1, 1} = strtrim(fields{c}); %#ok<AGROW>
    end
    lineNum = lineNum + 1;
end
fclose(fid);

T = struct();
T.colnames = colnames;
T.raw = raw;
end

function name = resolveColumn(colnames, candidates, required, label)
name = '';
for i = 1:numel(candidates)
    hit = find(strcmpi(colnames, candidates{i}), 1);
    if ~isempty(hit), name = colnames{hit}; return; end
end
for i = 1:numel(candidates)
    hit = find(strncmpi(colnames, candidates{i}, numel(candidates{i})), 1);
    if ~isempty(hit), name = colnames{hit}; return; end
end
if required
    error('LoadSessionTrialData:columnNotFound', ...
        'Could not find a column for "%s" (tried: %s). Available columns: %s', ...
        label, strjoin(candidates, ', '), strjoin(colnames, ', '));
end
end

function [vals, nBad] = toNumeric(cellCol)
vals = str2double(cellCol);
nBad = nnz(isnan(vals) & ~cellfun(@(s) isempty(strtrim(s)) || strcmpi(strtrim(s), 'nan'), cellCol));
end
