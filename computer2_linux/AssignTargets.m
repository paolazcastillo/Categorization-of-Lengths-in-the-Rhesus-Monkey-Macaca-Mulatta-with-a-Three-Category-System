function [tarPos, tarColor, correctTarget, trialColor, trialDir, centerCueColor, numCat] = ...
        AssignTargets(idx, trialNumCat, trialDirs, trialColorRows, ...
                    trialCorrectSlot, trialCatIndices, colorArray, Targets4Dir)
% ASSIGNTARGETS  Build the per-trial targets from the precomputed layout.
%
%   Works for 2- or 3-category trials: only the first numCat slots are
%   populated; the rest stay empty and are neither drawn nor hit-tested
%   (the caller, placeTargets in CenterOutTask.m, sets targetOn(1:numCat)
%   = 1 and leaves the rest at 0).
%
%   Empty slots are initialized with rect [0 0 0 0] and a sentinel colour
%   [-1 -1 -1] rather than [0 0 0] (black). Black is a legal PTB colour;
%   if a slot that should be inactive were accidentally drawn, it would
%   appear black-on-black and be invisible, hiding the bug entirely. The
%   sentinel [-1 -1 -1] is outside PTB's valid colour range, so Screen()
%   would error immediately, making the bug loud rather than silent.
%
%   INPUT
%     idx              : trial index into the sequence arrays
%     trialNumCat      : [seqSize x 1] number of categories/targets per trial
%     trialDirs        : [seqSize x 3] direction index (1-4) per slot
%     trialColorRows   : [seqSize x 3] colorArray row index per slot
%     trialCorrectSlot : [seqSize x 1] which slot holds the correct colour
%     trialCatIndices  : [seqSize x 1] true category (1=Short,2=Mid,3=Long)
%     colorArray       : [3 x 3] RGB matrix; row c = category c's colour.
%                        CenterOutTask.m passes whichever of its two
%                        colorArray2Cat/colorArray3Cat tables matches THIS
%                        trial's category count (see placeTargets), not
%                        always ColorCategoryMap().allCategoryRGBs() itself.
%     Targets4Dir      : [4 x 4] rect matrix; row d = direction d's rect.
%
%   OUTPUT
%     tarPos         : {1x3} cell of [1x4] rects; slots > numCat = [0 0 0 0]
%     tarColor       : {1x3} cell of [1x3] RGB; slots > numCat = [-1 -1 -1]
%     correctTarget  : slot index of the correct target (1..numCat)
%     trialColor     : true category (1=Short, 2=Mid, 3=Long)
%     trialDir       : direction of the correct target
%     centerCueColor : RGB of the correct category (for the centre ring)
%     numCat         : number of active targets (2 or 3)

SENTINEL_COLOR = [-1 -1 -1];   % invalid PTB colour; errors loudly if an empty slot is accidentally drawn

numCat = trialNumCat(idx);
tarPos   = {[0 0 0 0],      [0 0 0 0],      [0 0 0 0]};
tarColor = {SENTINEL_COLOR, SENTINEL_COLOR, SENTINEL_COLOR};
for k = 1:numCat
    tarPos{k}   = Targets4Dir(trialDirs(idx, k), :);
    tarColor{k} = colorArray(trialColorRows(idx, k), :);
end
correctTarget  = trialCorrectSlot(idx);
trialColor     = trialCatIndices(idx);             % 1=Short, 2=Mid, 3=Long
trialDir       = trialDirs(idx, correctTarget);    % == the balanced correct dir
centerCueColor = colorArray(trialColor, :);
end