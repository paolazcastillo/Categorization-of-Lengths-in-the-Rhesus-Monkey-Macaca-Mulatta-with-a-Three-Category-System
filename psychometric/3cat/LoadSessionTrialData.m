function S = LoadSessionTrialData(csvPath, useFirstAttemptOnly, verbose, chronometricSource)
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
%     chronometricSource   : 'TargetReached' (default) | 'Takeoff' |
%                        'TakeoffToTarget', OR a cell array of more than one
%                        of those -- which time(s) populate the chronometric
%                        curve(s):
%                          'TargetReached'   target-onset -> cursor-enters-
%                                            target (TotalTime_s, or the
%                                            era-resolved v2_2 reconstruction
%                                            below). The original behavior.
%                          'Takeoff'         target-onset -> movement takeoff
%                                            (TakeoffTime_s, written live by
%                                            TrialTakeoff.m since its
%                                            addition to CenterOutTask.m; see
%                                            BackfillTakeoffTime.m in
%                                            psychometric/alternate for
%                                            sessions recorded before that
%                                            column existed).
%                          'TakeoffToTarget' movement takeoff -> cursor-
%                                            enters-target, i.e. the
%                                            EXECUTION half of the reach
%                                            AFTER takeoff -- computed as
%                                            'TargetReached' minus 'Takeoff'
%                                            for the SAME row (no separate
%                                            column; both components already
%                                            share the same target-onset
%                                            origin, so the subtraction
%                                            cancels it exactly).
%                        A session missing a needed column (or where
%                        'TargetReached'/'Takeoff' themselves are
%                        unresolved) is treated as unresolved for that
%                        source -- see the chronometric section below -- so
%                        callers pooling several sessions do not need to
%                        special-case it.
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
%     .timeToTargetFit, .timingSchema : the FIRST requested chronometricSource
%         (kept for the single-source callers that pre-date multi-source
%         support, e.g. AnalyzePsychometricCurves.m)
%     .chrono.(SourceName).timeToTargetFit, .chrono.(SourceName).timingSchema
%         : one entry per REQUESTED source (SourceName is 'TargetReached',
%         'Takeoff' or 'TakeoffToTarget' verbatim, valid MATLAB fieldnames
%         as-is) -- what AnalyzePsychometricCurvesMultiSession.m reads when
%         several chronometric curves are requested at once
%

if nargin < 4 || isempty(chronometricSource)
    chronometricSource = 'TargetReached';
end
chronoSources = cellstr(chronometricSource);
validSources = {'TargetReached', 'Takeoff', 'TakeoffToTarget'};
[isValidSource, validIdx] = ismember(lower(chronoSources), lower(validSources));
if ~all(isValidSource)
    error('LoadSessionTrialData:badChronometricSource', ...
        'chronometricSource must be one of {%s}; got ''%s''.', ...
        strjoin(validSources, ', '), strjoin(chronoSources(~isValidSource), ''', '''));
end
chronoSources = validSources(validIdx);   % normalize casing -- used as struct fieldnames below
chronoSources = unique(chronoSources, 'stable');   % de-dupe, keep first-requested order
% Only resolve the components a requested source actually needs -- e.g. a
% caller asking only for 'TargetReached' should never see a warning about a
% missing TakeoffTime_s column it never asked for.
needTargetReached = any(ismember(chronoSources, {'TargetReached', 'TakeoffToTarget'}));
needTakeoff = any(ismember(chronoSources, {'Takeoff', 'TakeoffToTarget'}));

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

% Resolve the (up to) two underlying time components ANY requested source
% needs; 'TakeoffToTarget' is not a column of its own, it is the difference
% of these two (see the docstring above), computed further down once both
% are masked the same way. 'unresolved' means the SAME thing to every
% downstream caller regardless of which source was asked for: this session
% is excluded from the AFFECTED chronometric curve(s), psychometric fit
% unaffected.
targetReachedTime = nan(numel(barSize), 1);
targetReachedSchema = 'unresolved';
if needTargetReached
    % target-onset -> cursor-enters-target. This is to check discrepancies in how the reactions times are being logged.
    if ~isempty(colTotal)
        targetReachedSchema = 'new';
        [targetReachedTime, ~] = toNumeric(T.raw{strcmp(T.colnames, colTotal)});
        if ~isempty(colDecision) && ~isempty(colReact)
            [decCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colDecision)});
            [reactCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colReact)});
            reconstructed = decCheck + reactCheck;
            badCheck = ~isnan(targetReachedTime) & ~isnan(reconstructed) & (abs(targetReachedTime - reconstructed) > 0.01);
            if any(badCheck)
                warning('LoadSessionTrialData:timingCrossCheckFailed', ...
                    ['%s: %d row(s) where TotalTime_s does not match DecisionTime_s+ReactionTime_s ' ...
                     '(difference > 0.01s) -- check the file, the "current" format assumption might ' ...
                     'not apply.'], csvBase, nnz(badCheck));
            end
        end
    elseif ~isempty(colExec) && ~isempty(colReact)
        targetReachedSchema = 'old';
        [targetReachedTime, ~] = toNumeric(T.raw{strcmp(T.colnames, colReact)});
        if ~isempty(colDecision)
            [decCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colDecision)});
            [execCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colExec)});
            reconstructed = decCheck + execCheck;
            badCheck = ~isnan(targetReachedTime) & ~isnan(reconstructed) & (abs(targetReachedTime - reconstructed) > 0.01);
            if any(badCheck)
                warning('LoadSessionTrialData:timingCrossCheckFailed', ...
                    ['%s: %d row(s) where ReactionTime_s (v2_2-era, = total) does not match ' ...
                     'DecisionTime_s+ExecutionTime_s (difference > 0.01s) -- check the file, the ' ...
                     '"v2_2" format assumption might not apply.'], csvBase, nnz(badCheck));
            end
        end
    else
        warning('LoadSessionTrialData:timingSchemaUnresolved', ...
            ['%s: could not unambiguously determine the total-time column (target-onset -> the ' ...
             'cursor enters the target). Expected "TotalTime_s" (current format) or ' ...
             '"ExecutionTime_s"+"ReactionTime_s" together (v2_2-era format, where "ReactionTime_s" is ' ...
             'ALREADY the total -- see the "POOLING WARNING" comment in CenterOutTask.m). Available ' ...
             'columns: %s. The psychometric analysis is NOT affected; this session will be excluded ' ...
             'from any chronometric curve that depends on this time.'], csvBase, strjoin(T.colnames, ', '));
    end
end

takeoffTime = nan(numel(barSize), 1);
takeoffSchema = 'unresolved';
if needTakeoff
    % target-onset -> movement takeoff (TrialTakeoff.m's 5%-of-peak-speed
    % detection, written live since its addition to CenterOutTask.m, or
    % backfilled offline for older sessions -- see BackfillTakeoffTime.m in
    % psychometric/alternate). No era reconstruction: TakeoffTime_s never
    % existed under another column name, so either it is here or it is not.
    colTakeoff = resolveColumn(T.colnames, {'TakeoffTime_s'}, false, 'TakeoffTime_s');
    if ~isempty(colTakeoff)
        takeoffSchema = 'takeoff';
        [takeoffTime, ~] = toNumeric(T.raw{strcmp(T.colnames, colTakeoff)});
    else
        warning('LoadSessionTrialData:takeoffColumnMissing', ...
            ['%s: chronometricSource includes ''Takeoff''/''TakeoffToTarget'' but this file has no ' ...
             'TakeoffTime_s column -- run BackfillTakeoffTime.m on it first (psychometric/alternate), ' ...
             'or record it with a CenterOutTask.m build that includes TrialTakeoff.m. Available ' ...
             'columns: %s. The psychometric analysis is NOT affected; this session will be excluded ' ...
             'from any chronometric curve that depends on this time.'], csvBase, strjoin(T.colnames, ', '));
    end
end

if nBadBarSize > 0
    warning('LoadSessionTrialData:badRows', ...
        '%s: %d row(s) had a non-numeric BarSize value and will be dropped.', csvBase, nBadBarSize);
end
validRow = ~isnan(barSize) & ~isnan(isCorrect) & ~isnan(chosenTarget) & ~isnan(attempt);
stimGroup = stimGroup(validRow);  barSize = barSize(validRow);  isCorrect = isCorrect(validRow);
chosenTarget = chosenTarget(validRow); attempt = attempt(validRow);
dirChosen = dirChosen(validRow);
targetReachedTime = targetReachedTime(validRow);
takeoffTime = takeoffTime(validRow);
nRows = numel(barSize);
schemaMsgs = cell(1, numel(chronoSources));
for si = 1:numel(chronoSources)
    switch chronoSources{si}
        case 'TargetReached'
            schemaMsgs{si} = sprintf('TargetReached=%s', targetReachedSchema);
        case 'Takeoff'
            schemaMsgs{si} = sprintf('Takeoff=%s', takeoffSchema);
        case 'TakeoffToTarget'
            if strcmp(targetReachedSchema, 'unresolved') || strcmp(takeoffSchema, 'unresolved')
                schemaMsgs{si} = 'TakeoffToTarget=unresolved';
            else
                schemaMsgs{si} = 'TakeoffToTarget=takeoff-to-target';
            end
    end
end
vprintf(verbose, '%d row(s) usable after dropping malformed rows. Timing schema(s): %s\n', nRows, strjoin(schemaMsgs, ', '));

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

% Chronometric fields, aligned 1:1 with xFit/rankFit/stimRankFit/dirFit via
% the SAME useRow mask -- so any chronometric curve and the psychometric
% curve are always built from exactly the same trial set (same
% UseFirstAttemptOnly/omission/unexpected-code exclusions), never two
% silently different ones. One entry per REQUESTED source; 'TakeoffToTarget'
% is targetReachedTimeFit - takeoffTimeFit trial-by-trial (both already
% share the same target-onset origin, so it cancels out exactly, leaving
% takeoff -> target-reached).
targetReachedTimeFit = targetReachedTime(useRow);
takeoffTimeFit = takeoffTime(useRow);
chrono = struct();
for si = 1:numel(chronoSources)
    srcName = chronoSources{si};
    switch srcName
        case 'TargetReached'
            thisTime = targetReachedTimeFit;
            thisSchema = targetReachedSchema;
        case 'Takeoff'
            thisTime = takeoffTimeFit;
            thisSchema = takeoffSchema;
        case 'TakeoffToTarget'
            if strcmp(targetReachedSchema, 'unresolved') || strcmp(takeoffSchema, 'unresolved')
                thisSchema = 'unresolved';
                thisTime = nan(size(targetReachedTimeFit));
            else
                thisSchema = 'takeoff-to-target';
                thisTime = targetReachedTimeFit - takeoffTimeFit;
            end
    end
    % NaN here for a useRow-selected trial despite a RESOLVED schema would
    % be a contradiction (every trial with a response should have a timed
    % value) -- flagged loudly rather than silently propagated into a
    % chronometric mean.
    if ~strcmp(thisSchema, 'unresolved')
        nBadTiming = nnz(isnan(thisTime));
        if nBadTiming > 0
            warning('LoadSessionTrialData:timingMissingOnUsableRows', ...
                ['%s: %d of %d row(s) used for the fit have NaN %s time even though the column ' ...
                 'schema WAS resolved (%s) -- unexpected (check ChosenTarget/omission); those rows ' ...
                 'will be excluded from any chronometric curve.'], ...
                csvBase, nBadTiming, nnz(useRow), srcName, thisSchema);
        end
    end
    chrono.(srcName) = struct('timeToTargetFit', thisTime, 'timingSchema', thisSchema);
end

% Raw correct/incorrect: counted on all nRows usable rows (i.e. BEFORE the
% useRow exclusion mask that drops omissions, retries, and unexpected codes).
% isCorrect was converted to numeric (0/1) by toNumeric above; the validRow
% mask already eliminated rows with NaN in any key column, so every element
% here is 0 or 1. nCorrectRaw + nErrorRaw = nRows (all usable rows).
nCorrectRaw = nnz(isCorrect == 1);
nErrorRaw   = nnz(isCorrect == 0);

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
S.nCorrectRaw = nCorrectRaw;   % correct trials BEFORE exclusions (of nRows)
S.nErrorRaw   = nErrorRaw;     % incorrect trials BEFORE exclusions (of nRows)
S.isCorrectFit = isCorrect(useRow);
S.chrono = chrono;
S.chronometricSource = chronoSources;
% Back-compat single-source fields, from the FIRST requested source, for
% callers that pre-date multi-source support (AnalyzePsychometricCurves.m
% forwards ChronometricTimeSource but never reads these two itself).
S.timeToTargetFit = chrono.(chronoSources{1}).timeToTargetFit;
S.timingSchema = chrono.(chronoSources{1}).timingSchema;
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
