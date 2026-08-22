function seq = BuildWeightedTargetSequence(numAttemptsNeeded, weights, blockSize, maxConsecSame)
% BUILDWEIGHTEDTARGETSEQUENCE  Balanced pseudorandom direction sequence with
% arbitrary per-direction proportions.
%   Paola Castillo 2026-07-31
%
%   seq = BuildWeightedTargetSequence(numAttemptsNeeded, weights, blockSize, maxConsecSame)
%
%   weights       : [1 x nDir] relative proportion per direction (need not
%                   sum to 1 -- normalized internally).
%   blockSize     : trials per balancing block. Pick a value such that
%                   weights*blockSize are (near) integers for an exact
%                   realized proportion, e.g. [0.35 0.15 0.35 0.15] with
%                   blockSize=20 -> 7/3/7/3 exactly.
%   maxConsecSame : longest allowed run of the same direction, held both
%                   within a block and across block boundaries.
%
%   Uses the LARGEST-REMAINDER method to turn weights into exact integer
%   per-block counts -- proportions realized this way don't drift and don't
%   produce long uncontrolled runs the way i.i.d. sampling (rand < p) can.
%   Returns a buffer 3x numAttemptsNeeded long, since a caller with a
%   retry/correction procedure (a failed attempt repeats the same trial)
%   consumes more attempts than trials.
%
%   Hardware-independent shared helper (same rationale as
%   BuildTrialSequence.m): ported out of a one-off reference training
%   script (CenterOutSimple.m) so any engine needing weighted target
%   positions can reuse it instead of re-deriving the block+largest-
%   remainder+run-check logic.
nDir = numel(weights);
if any(weights < 0) || sum(weights) <= 0
    error('BuildWeightedTargetSequence:badWeights', ...
        'weights must be non-negative with a positive sum.');
end
wNorm = weights(:)' / sum(weights);

rawCounts   = wNorm * blockSize;
blockCounts = floor(rawCounts);
deficit     = blockSize - sum(blockCounts);
if deficit > 0
    [~, ordRem] = sort(rawCounts - blockCounts, 'descend');
    for k = 1:deficit
        blockCounts(ordRem(k)) = blockCounts(ordRem(k)) + 1;
    end
end
if any(blockCounts == 0 & wNorm > 0)
    warning('BuildWeightedTargetSequence:zeroCount', ...
        ['A direction with weight > 0 got 0 slots in a block of %d (it will ' ...
        'never appear). Increase blockSize.'], blockSize);
end

basePool = [];
for i = 1:nDir
    basePool = [basePool; repmat(i, blockCounts(i), 1)]; %#ok<AGROW>
end

nBlocks = ceil((numAttemptsNeeded * 3) / blockSize);   % 3x buffer for retries
seq     = zeros(nBlocks * blockSize, 1);
idxSeq  = 0;
relaxWarned = false;

for b = 1:nBlocks
    % Carry the tail of the already-placed sequence so maxConsecSame also
    % holds across the block boundary.
    tailLen = min(idxSeq, max(maxConsecSame, 0));
    if tailLen > 0
        prevTail = seq(idxSeq - tailLen + 1 : idxSeq);
    else
        prevTail = [];
    end

    placed = false;
    for attempt = 1:200   % 1) try-by-rejection
        cand = basePool(randperm(numel(basePool)));
        if localRunOK([prevTail; cand], numel(prevTail), maxConsecSame)
            placed = true;
            break;
        end
    end

    if ~placed   % 2) repair by swapping
        cand = basePool(randperm(numel(basePool)));
        full = [prevTail; cand];
        nOff = numel(prevTail);
        i = nOff + 1;
        guard = 0;
        while i <= numel(full) && guard < 5000
            guard = guard + 1;
            if runViolationAt(full, i, maxConsecSame)
                swapped = false;
                for j = (i + 1):numel(full)
                    if full(j) ~= full(i)
                        tmp = full(i); full(i) = full(j); full(j) = tmp;
                        swapped = true;
                        break;
                    end
                end
                if ~swapped, break; end   % block infeasible: accept as-is
            else
                i = i + 1;
            end
        end
        cand = full(nOff + 1:end);
        if ~localRunOK([prevTail; cand], numel(prevTail), maxConsecSame) && ~relaxWarned
            warning('BuildWeightedTargetSequence:relaxedRun', ...
                ['Could not respect maxConsecSame = %d with these weights in ' ...
                'every block; the constraint was relaxed in some. Raise ' ...
                'maxConsecSame or lower the dominant weight.'], maxConsecSame);
            relaxWarned = true;
        end
    end

    seq(idxSeq + 1 : idxSeq + blockSize) = cand;
    idxSeq = idxSeq + blockSize;
end
end

function ok = localRunOK(seq, nOffset, maxRun)
ok = true;
if maxRun < 1, return; end
for i = (nOffset + 1):numel(seq)
    if runViolationAt(seq, i, maxRun)
        ok = false;
        return;
    end
end
end

function bad = runViolationAt(seq, i, maxRun)
bad = false;
if maxRun < 1 || i <= maxRun, return; end
bad = all(seq(i - maxRun:i) == seq(i));
end