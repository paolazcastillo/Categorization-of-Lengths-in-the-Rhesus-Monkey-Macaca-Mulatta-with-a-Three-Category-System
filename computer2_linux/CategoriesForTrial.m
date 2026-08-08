function [catRows, trueCat] = CategoriesForTrial(nc, lenIdx, trainingPhase, ...
        lengthCategory, lengthCat2, colorRows2, colorRows3)
% CATEGORIESFORTRIAL  Which categories one trial offers, and which is correct.
%
%   Answers "for a bar of length index lenIdx shown with nc targets, which
%   categories go on screen (catRows) and which of them is the correct one
%   (trueCat)?". The single place all four of CenterOutTask.m's call sites go
%   through (initial sequence build, correction retry, and the two requeues
% ) so a mode can't be wired into some of them and silently not the others.
%
%   Its output feeds straight into DrawTrialLayout.m / FixedTargetLayout.m
%   (which turn categories into per-slot directions and colours); this
%   function decides WHICH categories, they decide WHERE each one lands.
%
%   Both outputs are deterministic in (nc, lenIdx) with ONE exception: the
%   training phase-2 foil is redrawn at random on every call. That is
%   deliberate; it is what makes a correction retry offer a different wrong
%   colour than the attempt before it, the same reason DrawTrialLayout.m
%   reshuffles positions on a retry.
%
%   INPUT
%     nc             : targets this trial (1 = training phase 1, 2, or 3)
%     lenIdx         : bar length index into the ACTIVE stimulus set
%     trainingPhase  : 0 = normal categorization, 1 or 2 = colour matching
%                      (see CenterOutTask.m's "Training phases" block)
%     lengthCategory : [1 x numLengths] length -> 3-category bucket
%     lengthCat2     : [1 x numLengths] length -> 2-category bucket
%     colorRows2     : active category rows for a 2-cat trial, e.g. [1 3]
%     colorRows3     : active category rows for a 3-cat trial, i.e. [1 2 3]
%
%   OUTPUT
%     catRows : [1 x nc] category indices on screen; always contains trueCat
%     trueCat : the correct category (1=Short, 2=Mid, 3=Long)

if trainingPhase > 0
    % Colour MATCHING, not categorization: the correct target always wears
    % the bar's own 3-category colour, whatever nc is; lengthCat2's
    % coarser 2-bucket split has no role in these phases.
    trueCat = colorRows3(lengthCategory(lenIdx));
    if nc == 1
        catRows = trueCat;                       % phase 1: nothing to choose between
    else
        otherCats = colorRows3(colorRows3 ~= trueCat);
        catRows = [trueCat, otherCats(randi(numel(otherCats)))];   % phase 2: + one foil colour
    end
elseif nc == 2
    catRows = colorRows2;  trueCat = colorRows2(lengthCat2(lenIdx));
else
    catRows = colorRows3;  trueCat = colorRows3(lengthCategory(lenIdx));
end
end
