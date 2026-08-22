function [slotDir, slotCol, correctSlot] = DrawTrialLayout(nc, trueCat, catRows, correctDir)
% DRAWTRIALLAYOUT  Random colour/position assignment for one trial's targets,
% given a fixed true category (trueCat) and correct direction (correctDir).
% Shared by the upfront sequence build and by the correction-trial reshuffle
% so a repeated stimulus doesn't keep the same colour in the same spot --
% otherwise the subject can solve the retry by spatial elimination ("not
% that one") instead of actually reading the bar again.
% Paola Castillo 2026-07-31
%
%   See also FixedTargetLayout.m, its deterministic no-shuffle counterpart
%   (every category always at the same direction), used instead of this
%   function whenever orgParams.fixedTargetLayout is true.
%
%   INPUT
%     nc         : number of active categories/targets (2 or 3)
%     trueCat    : category index of the correct target (1=Short,2=Mid,3=Long)
%     catRows    : [1 x nc] active category indices (e.g. [1 3] for 2-cat)
%     correctDir : direction (1-4) assigned to the correct target
%
%   OUTPUT
%     slotDir     : [1 x nc] direction per slot (shuffled)
%     slotCol     : [1 x nc] category per slot  (shuffled)
%     correctSlot : index into slotDir/slotCol where trueCat ended up

% Guard: trueCat must be in catRows. If not, distractCols would have nc
% elements instead of nc-1, silently producing a nc+1-element slotCol that
% gets truncated by randperm(nc), potentially losing trueCat from the array
% and returning correctSlot = [] -- a delayed crash with a confusing traceback.
assert(ismember(trueCat, catRows), ...
    'DrawTrialLayout: trueCat (%d) not found in catRows [%s].', ...
    trueCat, num2str(catRows));

otherDirs    = setdiff(1:4, correctDir);
distractDir  = otherDirs(randperm(numel(otherDirs), nc - 1));
distractCols = catRows(catRows ~= trueCat);
slotDir = [correctDir, distractDir];
slotCol = [trueCat,    distractCols];
ord = randperm(nc);
slotDir = slotDir(ord);  slotCol = slotCol(ord);
correctSlot = find(slotCol == trueCat, 1);
end