function [trialBarIndices, trialPositions] = BuildTrialSequence(seqSize, numBars)
% BUILDTRIALSEQUENCE  Balanced pseudorandom (bar, direction) trial sequence.
%   Paola Castillo 2026-07-31
%
%   Build a balanced pseudorandom sequence of (bar, direction) pairs such that
%   no more than 2 identical bar indices occur in a row and no identical
%   (bar, direction) pair occurs twice consecutively -- both held WITHIN and
%   ACROSS the 12-trial blocks. Falls back to greedy constraint-aware placement
%   when no random permutation satisfies it.
%
%   Shared by CenterOutTask.m (the real-time engine) and
%   offrig_mocks/TestLogic.m (off-rig, no-Psychtoolbox tests) -- this logic
%   has no hardware dependency, so it lives here once instead of as a local
%   function copied in both places.
%
%   GREEDY FALLBACK NOTE. When 5000 random permutations all fail (rare with
%   numBars=12; more likely with numBars=3, the prototypes3 set), the greedy
%   path places elements one at a time, picking the first available candidate
%   that respects both constraints. If no candidate fits, it forces the first
%   remaining element WITHOUT constraint checking to avoid an infinite loop.
%   That can produce a run of 3 or a repeated (bar,direction) pair at the
%   forced slot. This will be logged as a warning so you can detect it; it
%   does not stop the session.
maxConsecBarIdx = 3;   % reject the 3rd identical bar in a row -> max run = 2
if numBars == 1
    % Only one bar length in the set (e.g. an operator-selected single
    % training length -- see ParseBarSubset.m): every possible sequence is
    % one long run of that bar, so the run constraint can never be
    % satisfied. Leaving it on would burn 5000 doomed permutations per
    % block and then warn on every greedy slot. 0 disables it; the
    % no-repeated-(bar,direction) rule below still applies and is the only
    % one that means anything with a single bar.
    maxConsecBarIdx = 0;
end
N_reps          = 1;
blockSize       = numBars * 4 * N_reps;
nBlocks         = ceil(seqSize / blockSize);
% Bars carried across a block boundary. Floored at 1 so the
% no-repeated-(bar,direction) check below still sees the previous block's
% last bar even when the run rule is disabled (maxConsecBarIdx = 0).
histLen         = max(maxConsecBarIdx - 1, 1);

trialBarIndices = zeros(seqSize, 1);
trialPositions  = zeros(seqSize, 1);

[barGrid, posGrid] = meshgrid(1:numBars, 1:4);
baseBars = repmat(barGrid(:), N_reps, 1);
basePos  = repmat(posGrid(:), N_reps, 1);

for b = 1:nBlocks
    blockStart = (b - 1) * blockSize + 1;
    blockEnd   = min(b * blockSize, seqSize);
    blockLen   = blockEnd - blockStart + 1;

    % Carry the tail of the already-placed sequence so the constraints also
    % hold across the block boundary (otherwise runs can leak to 4 there).
    if blockStart > 1
        histStart = max(1, blockStart - histLen);
        prevBars  = trialBarIndices(histStart:blockStart - 1)';
        prevPos   = trialPositions(blockStart - 1);
    else
        prevBars  = [];
        prevPos   = 0;
    end

    % Try random permutations first
    success = 0;  candBars = [];  candPos = [];
    for attempt = 1:5000
        order = randperm(blockSize);
        candBars = baseBars(order(1:blockLen));
        candPos  = basePos(order(1:blockLen));
        if isValidSequence(candBars, candPos, prevBars, prevPos, maxConsecBarIdx)
            success = 1;  break;
        end
    end

    % Greedy fallback
    if ~success
        available = [baseBars(1:blockLen), basePos(1:blockLen)];
        available = available(randperm(blockLen), :);
        candBars = zeros(blockLen, 1);  candPos = zeros(blockLen, 1);
        for i = 1:blockLen
            placed = 0;
            for ci = randperm(size(available, 1))
                bi = available(ci, 1);  p = available(ci, 2);
                if okToPlace(candBars, candPos, i, bi, p, prevBars, prevPos, maxConsecBarIdx)
                    candBars(i) = bi;  candPos(i) = p;
                    available(ci, :) = [];  placed = 1;  break;
                end
            end
            if ~placed
                % No candidate respects the constraints: force the first
                % remaining element. This can violate the run or pair
                % constraint at this slot; it is logged as a warning rather
                % than erroring out, because a single constraint violation
                % in the sequence is far less harmful than a crashed session.
                warning('BuildTrialSequence:greedyForcedPlacement', ...
                    ['Block %d, slot %d: greedy fallback could not find a ' ...
                    'valid candidate; forcing placement without constraint ' ...
                    'check. The sequence may have a run of 3 or a repeated ' ...
                    '(bar,direction) pair at this slot. Consider increasing ' ...
                    'the numBars stimulus set if this happens frequently.'], b, i);
                candBars(i) = available(1, 1);  candPos(i) = available(1, 2);
                available(1, :) = [];
            end
        end
    end

    trialBarIndices(blockStart:blockEnd) = candBars;
    trialPositions(blockStart:blockEnd)  = candPos;
end
end

function ok = isValidSequence(bars, pos, prevBars, prevPos, maxConsec)
ok = 1;
for i = 1:numel(bars)
    if ~okToPlace(bars, pos, i, bars(i), pos(i), prevBars, prevPos, maxConsec)
        ok = 0;  return;
    end
end
end

function ok = okToPlace(bars, pos, i, thisBar, thisPos, prevBars, prevPos, maxConsec)
% True if placing (thisBar, thisPos) at slot i respects both constraints,
% counting the carried tail `prevBars` (last maxConsec-1 bars of the previous
% block) so the rules also hold across block boundaries.
ok = 1;
% Reject the maxConsec-th identical bar in a row: if the maxConsec-1
% immediately-preceding bars all equal thisBar. Missing history counts as a
% mismatch, so early slots are never falsely rejected. maxConsec < 2 means
% the caller disabled this rule entirely (single-bar set -- see the top of
% BuildTrialSequence); without this guard the empty `for` below would leave
% same = 1 and reject every candidate.
if maxConsec >= 2
    need = maxConsec - 1;
    same = 1;
    for k = 1:need
        j = i - k;
        if j >= 1
            val = bars(j);
        else
            tIdx = numel(prevBars) + j;   % j <= 0: index back into the carried tail
            if tIdx >= 1, val = prevBars(tIdx); else, val = 0; end
        end
        if val ~= thisBar, same = 0; break; end
    end
    if same, ok = 0; return; end
end
% No identical (bar, direction) pair twice in a row
if i == 1
    if isempty(prevBars), lastBar = 0; else, lastBar = prevBars(end); end
    lastPos = prevPos;
else
    lastBar = bars(i - 1);  lastPos = pos(i - 1);
end
if thisBar == lastBar && thisPos == lastPos, ok = 0; end
end