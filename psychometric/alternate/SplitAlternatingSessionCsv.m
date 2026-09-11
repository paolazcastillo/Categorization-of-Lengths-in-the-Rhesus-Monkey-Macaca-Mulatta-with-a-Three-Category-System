function out = SplitAlternatingSessionCsv(csvPath, outDir, verbose)
% SPLITALTERNATINGSESSIONCSV  Split one trial_data_*.csv from an "alternate"
% session (2-category blocks and 3-category blocks interleaved in the same
% file, tagged per-row by a NumCategories column) into two ordinary
% trial_data_*.csv files: one with only the NumCategories==2 rows, one with
% only the NumCategories==3 rows.
%
% WHY A SPLIT INSTEAD OF A NEW LOADER/FITTING ENGINE
% ------------------------------------------------------------------
% An "alternate" session's ChosenTarget coding (1=Short, 2=Mid, 3=Long,
% 0=omission, i.e. response iff ChosenTarget>0) is exactly the convention
% LoadSessionTrialData.m / AnalyzePsychometricCurves.m already implement
% (that engine is generic to any nCat>=2, including its documented nCat==2
% fallback code [1 3]) -- NOT the convention LoadSessionTrialData2Cat.m
% expects (ErrorType-based omission, 0/1 ChosenTarget coding from the old
% standalone 2-cat script). A single ordinal-boundary fit also cannot mix
% sessions/blocks with different category counts (the model itself is
% defined per category count). So the only sound way to reuse the existing,
% tested engine unmodified is to physically separate the two block types
% into their own CSVs and analyze each with AnalyzePsychometricCurves.m /
% AnalyzePsychometricCurvesMultiSession.m as if they were ordinary 2- or
% 3-category sessions -- see AnalyzePsychometricCurvesAlternating.m and
% AnalyzePsychometricCurvesMultiSessionAlternating.m, which call this
% function and then hand the split files to those unmodified scripts.
%
%   INPUT
%     csvPath : path to an "alternate" trial_data_*.csv (MUST have a
%               NumCategories column with values 2 and/or 3; this is what
%               makes a CSV "alternate" rather than a plain single-category
%               session)
%     outDir  : folder to write the split CSVs into (created if missing)
%     verbose : true/false -- print row counts per bucket
%
%   OUTPUT (struct out)
%     .path2cat, .path3cat : full path to the split CSV for that bucket, or
%                             '' if that bucket had zero rows (no file written)
%     .n2catRows, .n3catRows : row counts written to each bucket
%     .nSkippedRows           : rows dropped (malformed NumCategories value,
%                                or a value other than 2/3), reported via
%                                warning(), never silently dropped
%     .csvBase                : the original file's base name (for labeling)

if ~exist(csvPath, 'file')
    error('SplitAlternatingSessionCsv:fileNotFound', 'CSV not found: %s', csvPath);
end
[~, csvBase, ~] = fileparts(csvPath);
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

fid = fopen(csvPath, 'r');
if fid < 0
    error('SplitAlternatingSessionCsv:cannotOpen', 'Could not open %s', csvPath);
end
headerLine = fgetl(fid);
colnames = strtrim(strsplit(strtrim(headerLine), ','));
nCols = numel(colnames);

idxNumCat = find(strcmpi(colnames, 'NumCategories'), 1);
if isempty(idxNumCat)
    fclose(fid);
    error('SplitAlternatingSessionCsv:noNumCategoriesColumn', ...
        ['%s: no "NumCategories" column found -- this file does not look like an "alternate" ' ...
         'session export. Available columns: %s'], csvBase, strjoin(colnames, ', '));
end
idxStimGroup = find(strcmpi(colnames, 'StimulusGroup'), 1);

lines2cat = {};
lines3cat = {};
groups2cat = {};
groups3cat = {};
nSkipped = 0;
lineNum = 1;
while true
    tline = fgetl(fid);
    if ~ischar(tline), break; end
    if isempty(strtrim(tline)), continue; end
    fields = strsplit(tline, ',');
    lineNum = lineNum + 1;
    if numel(fields) ~= nCols
        warning('SplitAlternatingSessionCsv:malformedLine', ...
            '%s: line %d has %d fields, expected %d -- skipped.', csvBase, lineNum, numel(fields), nCols);
        nSkipped = nSkipped + 1;
        continue;
    end
    numCat = str2double(strtrim(fields{idxNumCat}));
    if numCat == 2
        lines2cat{end + 1, 1} = tline; %#ok<AGROW>
        if ~isempty(idxStimGroup), groups2cat{end + 1, 1} = strtrim(fields{idxStimGroup}); end %#ok<AGROW>
    elseif numCat == 3
        lines3cat{end + 1, 1} = tline; %#ok<AGROW>
        if ~isempty(idxStimGroup), groups3cat{end + 1, 1} = strtrim(fields{idxStimGroup}); end %#ok<AGROW>
    else
        warning('SplitAlternatingSessionCsv:unexpectedNumCategories', ...
            ['%s: line %d has NumCategories=%s (expected 2 or 3) -- row skipped, not assigned to ' ...
             'either bucket.'], csvBase, lineNum, strtrim(fields{idxNumCat}));
        nSkipped = nSkipped + 1;
    end
end
fclose(fid);

if ~isempty(idxStimGroup)
    checkGroupCount(groups2cat, 2, csvBase, '2-category');
    checkGroupCount(groups3cat, 3, csvBase, '3-category');
end

out = struct();
out.csvBase = csvBase;
out.n2catRows = numel(lines2cat);
out.n3catRows = numel(lines3cat);
out.nSkippedRows = nSkipped;
out.path2cat = writeBucket(lines2cat, headerLine, outDir, [csvBase '_2cat.csv']);
out.path3cat = writeBucket(lines3cat, headerLine, outDir, [csvBase '_3cat.csv']);

vprintf(verbose, ['\n--- SplitAlternatingSessionCsv (%s) ---\n' ...
    '  2-category rows: %d%s\n' ...
    '  3-category rows: %d%s\n' ...
    '  Skipped rows:    %d\n'], ...
    csvBase, out.n2catRows, bucketNote(out.path2cat), ...
    out.n3catRows, bucketNote(out.path3cat), out.nSkippedRows);
end

function checkGroupCount(groups, expected, csvBase, label)
if isempty(groups), return; end
nDistinct = numel(unique(groups));
if nDistinct ~= expected
    warning('SplitAlternatingSessionCsv:groupCountMismatch', ...
        ['%s: the %s bucket (NumCategories==%d) actually contains %d distinct StimulusGroup ' ...
         'value(s) (%s), not %d -- NumCategories may be mislabeled for some rows. The analysis ' ...
         'will still run using whatever categories are actually present; verify this manually.'], ...
        csvBase, label, expected, nDistinct, strjoin(unique(groups), ', '), expected);
end
end

function path = writeBucket(lines, headerLine, outDir, fname)
if isempty(lines)
    path = '';
    return;
end
path = fullfile(outDir, fname);
fid = fopen(path, 'w');
fprintf(fid, '%s\n', headerLine);
for i = 1:numel(lines)
    fprintf(fid, '%s\n', lines{i});
end
fclose(fid);
end

function s = bucketNote(path)
if isempty(path)
    s = '  (no rows -- no file written)';
else
    s = '';
end
end

function vprintf(verbose, varargin)
if verbose, fprintf(varargin{:}); end
end
