function rects = CueRectsFor(slots, xCenter, yCenter, cueDistance, cueSize, cueYOffset)
% CUERECTSFOR  Build a 4xN rect matrix for cue dots at the given horizontal slot offsets
% (in units of cueDistance), centred on cueYOffset above the screen centre.
rects = zeros(4, numel(slots));
for k = 1:numel(slots)
    cx = xCenter + slots(k) * cueDistance;
    rects(:, k) = [cx - cueSize/2; yCenter + cueYOffset - cueSize/2; ...
                cx + cueSize/2; yCenter + cueYOffset + cueSize/2];
end
end