function [slotDir, slotCol, correctSlot] = FixedTargetLayout(nc, trueCat, catRows, catDirMap)
% FIXEDTARGETLAYOUT  Deterministic colour/position assignment for one
% trial's targets: every category always renders at the SAME screen
% direction, trial after trial. The "no shuffle" counterpart to
% DrawTrialLayout.m, used by CenterOutTask.m when
% orgParams.fixedTargetLayout is true (CenterConsole "Fixed target
% layout" checkbox); so a category's target position never has to be
% re-read each trial (e.g. category 1 always Right, category 2 always Up,
% category 3 always Left; the 4th cardinal direction, Down, stays unused).
%
%   INPUT
%     nc        : number of active categories/targets (2 or 3)
%     trueCat   : category index of the correct target (1=Short,2=Mid,3=Long)
%     catRows   : [1 x nc] active category indices (e.g. [1 3] for 2-cat)
%     catDirMap : [1 x 3] direction (1-4) assigned to each category row;
%                 CenterOutTask.m sets this to [1 2 3] (Right/Up/Left).
%
%   OUTPUT
%     slotDir     : [1 x nc] direction per slot, in catRows order
%     slotCol     : [1 x nc] category per slot, in catRows order
%     correctSlot : index into slotDir/slotCol where trueCat sits
assert(ismember(trueCat, catRows), ...
    'FixedTargetLayout: trueCat (%d) not found in catRows [%s].', ...
    trueCat, num2str(catRows));

slotCol = catRows;
slotDir = catDirMap(catRows);
correctSlot = find(slotCol == trueCat, 1);
end
