function [idx, errMsg] = ParseBarSubset(spec, numLengths)
% PARSEBARSUBSET  Operator's bar-length selection -> stimulus-set indices.
%
%   Turns the console's "Bar lengths (subset)" text field into the index
%   vector CenterOutTask.m uses to cut its active stimulus set down to the
%   lengths a session should actually run (see orgParams.barLengthSubset).
%   Empty / 'all' means the whole set, so a session that never touches the
%   field behaves exactly as it did before this field existed.
%
%   Accepted forms (whitespace anywhere is ignored):
%     ''  or  'all'   every length in the active set
%     '5'             one length
%     '1,5,9'         a list
%     '1-4,9-12'      ranges, or ranges mixed with single indices
%     [1 5 9]         a numeric vector (for callers building orgParams by hand)
%
%   Duplicates are dropped and the result is sorted ascending, so '9,1,1'
%   and '1,9' select the same thing.
%
%   INPUT
%     spec       : selection string (or numeric vector), see forms above
%     numLengths : how many lengths the active stimulus set has (12 for
%                  'full12', 3 for 'prototypes3') -- indices must fall in
%                  1..numLengths
%
%   OUTPUT
%     idx    : [1 x n] selected indices, ascending; [] when errMsg is set
%     errMsg : '' on success, otherwise a message naming what was wrong.
%              Returned rather than thrown so CenterConsole.m can paint the
%              field red and block Start instead of crashing mid-session;
%              CenterOutTask.m turns a non-empty errMsg into an error().

idx = [];
errMsg = '';

if nargin < 2 || isempty(numLengths) || numLengths < 1
    errMsg = 'numLengths must be a positive integer.';
    return;
end

if isnumeric(spec)
    idx = spec(:)';
elseif isempty(spec) || strcmpi(strtrim(spec), 'all')
    idx = 1:numLengths;
    return;
else
    parts = strsplit(strtrim(spec), ',');
    for i = 1:numel(parts)
        p = strtrim(parts{i});
        if isempty(p), continue; end
        range = regexp(p, '^(\d+)\s*-\s*(\d+)$', 'tokens', 'once');
        if ~isempty(range)
            lo = str2double(range{1});
            hi = str2double(range{2});
            if lo > hi
                errMsg = sprintf('Range "%s" runs backwards (start > end).', p);
                idx = [];
                return;
            end
            idx = [idx, lo:hi];   %#ok<AGROW>
        elseif ~isempty(regexp(p, '^\d+$', 'once'))
            idx = [idx, str2double(p)];   %#ok<AGROW>
        else
            errMsg = sprintf('"%s" is not a bar index or an a-b range.', p);
            idx = [];
            return;
        end
    end
end

idx = unique(idx);   % also sorts ascending
if isempty(idx)
    errMsg = 'No bar lengths selected.';
    return;
end
if any(idx < 1) || any(idx > numLengths) || any(idx ~= floor(idx))
    errMsg = sprintf('Bar indices must be whole numbers between 1 and %d.', numLengths);
    idx = [];
end
end
