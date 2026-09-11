function S = LoadSessionTrialData2Cat(csvPath, useFirstAttemptOnly, verbose)
% LOADSESSIONTRIALDATA2CAT  Load + clean one trial_data_*.csv from a 2-category
% (Short/Long) session into the SAME output struct shape as
% LoadSessionTrialData.m (the 3-category version), so
% AnalyzePsychometricCurves2Cat.m can reuse EXACTLY the same STEP 1-4 fitting
% engine (sigmoid MLE, Wilson CI, SDT with Hautus correction, deviance
% goodness-of-fit, bootstrap) as the 3-category pipeline.
%
% THIS IS A SEPARATE FILE, NOT A CALL TO LoadSessionTrialData.m, because the
% 2-category CSV schema is genuinely incompatible with that loader in two
% concrete:
%
%   1) NO 'Attempt' COLUMN. LoadSessionTrialData.m requires it
%      (resolveColumn(..., required=true)) and errors out immediately if
%      absent. Both real 2-cat example files
%      (trial_data_23May2026_1444.csv, trial_data_04May2026_1439.csv) have
%      no Attempt column at all. Here it is OPTIONAL: if present, the
%      UseFirstAttemptOnly filter is applied exactly as in the 3-cat
%      loader; if absent, the filter is a documented no-op (nExcludedRetry
%      stays 0, S.hasAttemptColumn=false) rather than a hard error.
%
%   2) DIFFERENT ChosenTarget CODING. In the 2-cat
%      CSVs, ChosenTarget=0 means "chose Short" (a real response), 1 means "chose Long", -1 means no response, silently reclassified all 224
%      genuine "chose Short" trials (ChosenTarget=0) as omissions, AND its
%      ChosenTarget-code-learning step (which filters codesHere>0 before
%      taking the mode) found zero usable codes for ShortGroup, fell back
%      to the hardcoded colorRows2=[1 3] convention, and collided with
%      LongGroup's own empirically-learned code (also 1) -- both
%      categories ended up mapped to the same ChosenTarget code, silently
%      via containers.Map overwrite, with no error raised.
%
%      THE FIX HERE: omission is detected from ErrorType==1 (this version
%      own explicit "early exit / no response" sentinel, present and
%      unambiguous in both example files, cross-checked against
%      ChosenTarget==-1 in those same rows)  it is never silently allowed to overwrite,
%      unlike the containers.Map behavior that caused the corruption above.
%
%   3) NO HARDCODED FALLBACK CODE CONVENTION. LoadSessionTrialData.m falls
%      back to colorRows2=[1 3] (a documented CenterOutTask.m convention)
%      when a category has zero correct trials to learn its code from.
%      There is no equivalent documented convention for the script that
%      produced these 2-cat CSVs . So if a category here
%      has zero correct trials, this function ERRORS explicitely instead of
%      guessing a fallback that has not been verified for this schema.
%
%   4) BarSize UNIT. Tries 'BarSizeVA_deg'/'BarSizeVA' (degrees) first, same
%      as the 3-cat loader; if absent, falls back to 'BarSizePx' (pixels)
%      WITH A LOUD WARNING and S.barSizeUnit='px' -- never silently
%      converts . Mixing 'deg' and
%      'px' sessions in one multi-session pool must be caught by the
%      caller (AnalyzePsychometricCurvesMultiSession2Cat.m checks this the
%      same way the 3-cat script checks category-structure compatibility).
%
% Everything else (category ordering by ascending true bar length, rank
% assignment, unexpected-code detection, exclusion reporting) mirrors
% LoadSessionTrialData.m as closely as the design differences allow, so the
% two loaders stay conceptually parallel.
%
% TIMING COLUMNS. We had problems logging the reactions times in a past version of the task, so we verified and tracked the correct columns 
% to analyze the SAME RTs in both tasks designs.
%
%   INPUT
%     csvPath             : path to a 2-category trial_data_*.csv
%     useFirstAttemptOnly : true/false -- honored only if an Attempt column
%                           exists (see point 1 above); otherwise a no-op,
%                           reported explicitly via S.hasAttemptColumn
%     verbose              : true/false -- print load/exclusion summary
%
%   OUTPUT (struct S) -- same fields as LoadSessionTrialData.m, PLUS:
%     .xFit, .rankFit, .stimRankFit, .dirFit, .groupNames, .groupCode,
%     .nCat, .csvPath, .csvBase, .nRowsRaw, .nRows, .nOmission,
%     .nExcludedRetry, .nUnexpected
%     .barSizeUnit        : 'deg' or 'px' (see point 4)
%     .hasAttemptColumn   : true/false (see point 1)
%     .timeToTargetFit    : target-onset -> cursor-enters-target, in the
%                           CSV's own time units (seconds), aligned 1:1 with
%                           .xFit via the same useRow mask; NaN for rows
%                           where the timing schema could not be resolved
%     .isCorrectFit       : IsCorrect for the same useRow-selected trials
%                           (needed to split the chronometric curve into
%                           correct vs. error trials, same as 3-cat)
%     .timingSchema       : 'new' | 'old' | 'unresolved' (see comment above)
%


if ~exist(csvPath, 'file')
    error('LoadSessionTrialData2Cat:fileNotFound', 'CSV not found: %s', csvPath);
end
[~, csvBase, ~] = fileparts(csvPath);

% ===========================================================================
% LOAD + RESOLVE COLUMNS
% ===========================================================================
T = loadCsvAsStruct(csvPath);
nRowsRaw = numel(T.raw{1});
vprintf(verbose, 'Loaded %d rows, %d columns.\n', nRowsRaw, numel(T.colnames));

colStimGroup = resolveColumn(T.colnames, {'StimulusGroup'}, true, 'true category (StimulusGroup)');
colIsCorrect = resolveColumn(T.colnames, {'IsCorrect'}, true, 'IsCorrect');
colErrorType = resolveColumn(T.colnames, {'ErrorType'}, true, 'ErrorType');
colChosen    = resolveColumn(T.colnames, {'ChosenTarget'}, true, 'ChosenTarget');
colAttempt   = resolveColumn(T.colnames, {'Attempt'}, false, 'Attempt');
colDirChosen = resolveColumn(T.colnames, {'DirectionChosen', 'Direction'}, false, 'DirectionChosen/Direction');

% Timing columns, all OPTIONAL (never forced the psychometric fit) --
% resolved discrepancies-aware, PORTED VERBATIM from the real, current
% LoadSessionTrialData.m.
% Same "POOLING WARNING" rules: the column literally named
% "ReactionTime" means a DIFFERENT interval depending on engine generation,
% even though it sits in the same CSV position:
%   CURRENT/"new" files : TotalTime(_s), DecisionTime(_s), ReactionTime(_s).
%     DecisionTime = target-onset -> leave-center
%     ReactionTime = leave-center -> reach-target (movement/execution only)
%     TotalTime    = DecisionTime + ReactionTime = target-onset -> reach-target
%   "old"/v2_2-era files (BOTH 2-cat example CSVs): DecisionTime,
%   ExecutionTime, ReactionTime columns (no TotalTime at all).
%     DecisionTime  = target-onset -> leave-center (same meaning, unchanged)
%     ExecutionTime = leave-center -> reach-target (== "new" ReactionTime)
%     ReactionTime  = target-onset -> reach-target, i.e. the TOTAL
%                      (== "new" TotalTime) -- NOT movement-only here.
% Verified directly against trial_data_23May2026_1444.csv (2026-08-25):
% ReactionTime == DecisionTime + ExecutionTime row-by-row (e.g. row 1:
% 0.3324+0.8835=1.2159 vs ReactionTime=1.2158, matching within rounding).
% Both "_s"-suffixed (3-cat convention) and unsuffixed (2-cat convention,
% confirmed) column names are tried, so a future 2-cat session using either
% naming still resolves correctly instead of silently landing in
% 'unresolved'.
colTotal    = resolveColumn(T.colnames, {'TotalTime_s', 'TotalTime'}, false, 'TotalTime');
colExec     = resolveColumn(T.colnames, {'ExecutionTime_s', 'ExecutionTime'}, false, 'ExecutionTime');
colReact    = resolveColumn(T.colnames, {'ReactionTime_s', 'ReactionTime'}, false, 'ReactionTime');
colDecision = resolveColumn(T.colnames, {'DecisionTime_s', 'DecisionTime'}, false, 'DecisionTime');

colBarSizeDeg = resolveColumn(T.colnames, {'BarSizeVA_deg', 'BarSizeVA'}, false, 'bar length in degrees');
colBarSizePx  = resolveColumn(T.colnames, {'BarSizePx'}, false, 'bar length in pixels');
if ~isempty(colBarSizeDeg)
    colBarSize = colBarSizeDeg;
    barSizeUnit = 'deg';
elseif ~isempty(colBarSizePx)
    colBarSize = colBarSizePx;
    barSizeUnit = 'px';
    warning('LoadSessionTrialData2Cat:pxUnit', ...
        ['%s: bar size is in PIXELS (BarSizePx), not degrees of visual angle. ' ...
         'No automatic conversion is applied -- there is no confirmed px->degrees factor ' ...
         'for this session in the project (see DESIGN_psychofisica_2vs3cat.md). Do NOT mix with ' ...
         'sessions in BarSizeVA without confirming that factor.'], csvBase);
else
    error('LoadSessionTrialData2Cat:noBarSizeCol', ...
        '%s: no BarSizeVA_deg/BarSizeVA or BarSizePx column was found. Available columns: %s', ...
        csvBase, strjoin(T.colnames, ', '));
end

if any(strcmp({colStimGroup, colIsCorrect, colErrorType, colChosen}, ''))
    error('LoadSessionTrialData2Cat:missingColumns', ...
        'One or more required columns could not be resolved in %s. Available columns: %s', ...
        csvPath, strjoin(T.colnames, ', '));
end

hasAttemptColumn = ~isempty(colAttempt);

stimGroup = T.raw{strcmp(T.colnames, colStimGroup)};
[barSize, nBadBarSize]   = toNumeric(T.raw{strcmp(T.colnames, colBarSize)});
[isCorrect, ~]           = toNumeric(T.raw{strcmp(T.colnames, colIsCorrect)});
[errorType, ~]           = toNumeric(T.raw{strcmp(T.colnames, colErrorType)});
[chosenTarget, ~]        = toNumeric(T.raw{strcmp(T.colnames, colChosen)});
if hasAttemptColumn
    [attempt, ~] = toNumeric(T.raw{strcmp(T.colnames, colAttempt)});
else
    attempt = ones(numel(barSize), 1); % no-op placeholder: nothing gets excluded by it
end
if ~isempty(colDirChosen)
    dirChosen = T.raw{strcmp(T.colnames, colDirChosen)};
else
    dirChosen = repmat({''}, numel(barSize), 1);
end

% timeToTarget = target-onset -> cursor-enters-target, era-resolved per the
% comment above. Cross-checked  against the other two
% timing columns when available, exactly like the real LoadSessionTrialData.m

if ~isempty(colTotal)
    timingSchema = 'new';
    [timeToTarget, ~] = toNumeric(T.raw{strcmp(T.colnames, colTotal)});
    if ~isempty(colDecision) && ~isempty(colReact)
        [decCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colDecision)});
        [reactCheck, ~] = toNumeric(T.raw{strcmp(T.colnames, colReact)});
        reconstructed = decCheck + reactCheck;
        badCheck = ~isnan(timeToTarget) & ~isnan(reconstructed) & (abs(timeToTarget - reconstructed) > 0.01);
        if any(badCheck)
            warning('LoadSessionTrialData2Cat:timingCrossCheckFailed', ...
                ['%s: %d row(s) where TotalTime(_s) does not match DecisionTime(_s)+ReactionTime(_s) ' ...
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
            warning('LoadSessionTrialData2Cat:timingCrossCheckFailed', ...
                ['%s: %d row(s) where ReactionTime(_s) (v2_2-era/old, = total) does not match ' ...
                 'DecisionTime(_s)+ExecutionTime(_s) (difference > 0.01s) -- check the file, the ' ...
                 '"v2_2/old" format assumption might not apply.'], csvBase, nnz(badCheck));
        end
    end
else
    timingSchema = 'unresolved';
    timeToTarget = nan(numel(barSize), 1);
    warning('LoadSessionTrialData2Cat:timingSchemaUnresolved', ...
        ['%s: could not unambiguously determine the total-time column (target-onset -> the ' ...
         'cursor enters the target). Expected "TotalTime(_s)" (current format) or ' ...
         '"ExecutionTime(_s)"+"ReactionTime(_s)" together (v2_2-era/old format, where ' ...
         '"ReactionTime(_s)" is ALREADY the total). Available columns: %s. The psychometric ' ...
         'analysis is NOT affected; this session will be excluded from any chronometric curve.'], ...
        csvBase, strjoin(T.colnames, ', '));
end

if nBadBarSize > 0
    warning('LoadSessionTrialData2Cat:badRows', ...
        '%s: %d row(s) had a non-numeric BarSize value and will be dropped.', csvBase, nBadBarSize);
end
% NOTE: chosenTarget and errorType are allowed to be NaN here (an omitted
% trial can have ChosenTarget=-1 with ErrorType=1, or NaN reaction/decision
% times, but ChosenTarget/ErrorType themselves are always numeric in the
% example files); validRow only drops rows where the columns we actually
% NEED (barSize, isCorrect, errorType, chosenTarget, and attempt if present)
% failed to parse at all. timeToTarget is filtered by the SAME validRow mask
% for alignment, but never GATES it. That´s why a timing problem must never lock out
% a psychometric trial.
validRow = ~isnan(barSize) & ~isnan(isCorrect) & ~isnan(errorType) & ~isnan(chosenTarget) & ~isnan(attempt);
stimGroup = stimGroup(validRow);  barSize = barSize(validRow);  isCorrect = isCorrect(validRow);
errorType = errorType(validRow);  chosenTarget = chosenTarget(validRow);  attempt = attempt(validRow);
dirChosen = dirChosen(validRow);  timeToTarget = timeToTarget(validRow);
nRows = numel(barSize);
vprintf(verbose, '%d row(s) usable after dropping malformed rows. Timing schema detected: %s\n', nRows, timingSchema);

% ===========================================================================
% CATEGORY STRUCTURE (same logic as LoadSessionTrialData.m: ascending by
% true mean bar length)
% ===========================================================================
uGroups = unique(stimGroup);
meanVA = nan(size(uGroups));
for i = 1:numel(uGroups)
    meanVA(i) = mean(barSize(strcmp(stimGroup, uGroups{i})));
end
[~, ord] = sort(meanVA, 'ascend');
groupNames = uGroups(ord);   % e.g. {ShortGroup, LongGroup}
nCat = numel(groupNames);
if nCat < 2
    error('LoadSessionTrialData2Cat:tooFewCategories', ...
        '%s: only %d distinct StimulusGroup value(s) found -- need at least 2 to define a boundary.', ...
        csvBase, nCat);
end
if nCat ~= 2
    warning('LoadSessionTrialData2Cat:notTwoCategories', ...
        ['%s: found %d categories, not 2 -- this loader is meant for 2-category sessions ' ...
         '(see DESIGN_psychofisica_2vs3cat.md). It still works generically ' ...
         '(same as LoadSessionTrialData.m), but verify that this session really is 2-cat.'], ...
        csvBase, nCat);
end

[~, stimRank] = ismember(stimGroup, groupNames);

% ===========================================================================
% OMISSION (no response): from ErrorType==1, NOT from the sign of
% ChosenTarget (point 2 of the header). ErrorType==1 is this rig's own
% explicit "early exit / no response" sentinel
% ===========================================================================
hasResponse = (errorType ~= 1);
% Consistency check (fail loud, not silent): if ErrorType==1 but
% ChosenTarget is not the expected sentinel, or if ErrorType~=1 but
% ChosenTarget IS the sentinel, something doesn't match what was verified in
% the example files -- warn instead of assuming.
sentinelMismatch = (errorType == 1 & chosenTarget ~= -1) | (errorType ~= 1 & chosenTarget == -1);
if any(sentinelMismatch)
    warning('LoadSessionTrialData2Cat:sentinelMismatch', ...
        ['%s: %d row(s) where ErrorType==1 and ChosenTarget==-1 do NOT match as expected ' ...
         '(verified in the 2 example CSVs that they always DO match). Inspect manually -- ' ...
         'this session might use a different coding convention.'], ...
        csvBase, nnz(sentinelMismatch));
end

% ===========================================================================
% LEARN THE ChosenTarget CODE PER CATEGORY (mode among CORRECT trials of
% that category, using ALL responses (including 0; not just positive
% codes). No hardcoded fallback: if a category has no correct trials, this
% FAILS explicitly instead of guessing (see point 3 of the header).
% ===========================================================================
groupCode = nan(1, nCat);
for i = 1:nCat
    thisGroupCorrect = strcmp(stimGroup, groupNames{i}) & isCorrect == 1 & hasResponse;
    codesHere = chosenTarget(thisGroupCorrect);
    if isempty(codesHere)
        error('LoadSessionTrialData2Cat:noCorrectTrialsForGroup', ...
            ['%s: category "%s" has no correct trial with a response -- its ChosenTarget code ' ...
             'cannot be learned empirically, and this loader does NOT use a hardcoded fallback ' ...
             '(there is no documented and verified convention for this CSV schema, unlike ' ...
             'colorRows2=[1 3] in CenterOutTask.m for 3-cat sessions). Inspect this session ' ...
             'manually.'], csvBase, groupNames{i});
    end
    groupCode(i) = mode(codesHere);
end
% Explicit collision check. This is EXACTLY what silently failed in
% LoadSessionTrialData.m against this same data (containers.Map silently
% overwriting the duplicate key with no warning). Here it is checked before
% building the map, and stops with a specific error if two categories
% learned the same code.
if numel(unique(groupCode)) < nCat
    error('LoadSessionTrialData2Cat:groupCodeCollision', ...
        ['%s: two or more categories learned the SAME ChosenTarget code (%s for categories ' ...
         '{%s}) -- this would silently corrupt the code->category mapping if ignored ' ...
         '(this is exactly the bug verified in LoadSessionTrialData.m against this same kind of ' ...
         'data, see this file''s header). Check the real ChosenTarget coding in this session by ' ...
         'hand.'], csvBase, mat2str(groupCode), strjoin(groupNames, ', '));
end
vprintf(verbose, 'Category order (ascending length): %s\n', strjoin(groupNames, ' < '));
vprintf(verbose, 'ChosenTarget code learned per category: %s\n', mat2str(groupCode));

rankOfCode = containers.Map(num2cell(groupCode), num2cell(1:nCat));
chosenRank = nan(nRows, 1);
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
    warning('LoadSessionTrialData2Cat:unexpectedChosenTargetCode', ...
        ['%s: %d row(s) have a ChosenTarget code (%s) that does not match any learned category ' ...
         'code (%s). These rows are excluded -- inspect them manually.'], csvBase, nnz(unexpectedCode), ...
        mat2str(unique(chosenTarget(unexpectedCode))'), mat2str(groupCode));
end

% ===========================================================================
% EXCLUSIONS (reported explicitly)
% ===========================================================================
nOmission = nnz(~hasResponse);
nUnexpected = nnz(unexpectedCode);
useRow = hasResponse & ~unexpectedCode;
if hasAttemptColumn && logical(useFirstAttemptOnly)
    nExcludedRetry = nnz(useRow & attempt ~= 1);
    useRow = useRow & (attempt == 1);
else
    nExcludedRetry = 0;
end

attemptNote = '';
if ~hasAttemptColumn
    attemptNote = ' (NO Attempt column in this schema -- the UseFirstAttemptOnly filter does not apply, nothing was excluded as a retry)';
end
vprintf(verbose, ['\n--- Exclusions (%s) ---\n' ...
    '  Total usable rows after cleaning:        %d\n' ...
    '  No response (ErrorType==1):              %d (%.1f%%)\n' ...
    '  Unexpected ChosenTarget code:             %d\n' ...
    '  Excluded as a retry (Attempt>1):          %d  (UseFirstAttemptOnly=%d)%s\n' ...
    '  Rows used for the fit:                     %d\n'], ...
    csvBase, nRows, nOmission, 100 * nOmission / max(nRows, 1), nUnexpected, nExcludedRetry, ...
    logical(useFirstAttemptOnly), attemptNote, nnz(useRow));

% Chronometric fields (target-onset -> cursor-enters-target, era-resolved
% above), aligned 1:1 with xFit/rankFit/stimRankFit/dirFit via the SAME
% useRow mask (ported verbatim from LoadSessionTrialData.m's own
% end-of-function block, same rule: a chronometric curve and the
% psychometric curve must always be built from exactly the same trial set.
timeToTargetFit = timeToTarget(useRow);
if ~strcmp(timingSchema, 'unresolved')
    nBadTiming = nnz(isnan(timeToTargetFit));
    if nBadTiming > 0
        warning('LoadSessionTrialData2Cat:timingMissingOnUsableRows', ...
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
S.barSizeUnit = barSizeUnit;
S.hasAttemptColumn = hasAttemptColumn;
end

% =========================================================================
% LOCAL HELPER FUNCTIONS (byte-identical to LoadSessionTrialData.m's own --
% duplicated by design, matching this project's existing convention of
% self-contained files rather than a shared library; see that file's
% header for the same rationale)
% =========================================================================

function vprintf(verbose, varargin)
if verbose, fprintf(varargin{:}); end
end

function T = loadCsvAsStruct(csvPath)
fid = fopen(csvPath, 'r');
if fid < 0
    error('LoadSessionTrialData2Cat:cannotOpen', 'Could not open %s', csvPath);
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
        warning('LoadSessionTrialData2Cat:malformedLine', ...
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
    error('LoadSessionTrialData2Cat:columnNotFound', ...
        'Could not find a column for "%s" (tried: %s). Available columns: %s', ...
        label, strjoin(candidates, ', '), strjoin(colnames, ', '));
end
end

function [vals, nBad] = toNumeric(cellCol)
vals = str2double(cellCol);
nBad = nnz(isnan(vals) & ~cellfun(@(s) isempty(strtrim(s)) || strcmpi(strtrim(s), 'nan'), cellCol));
end
