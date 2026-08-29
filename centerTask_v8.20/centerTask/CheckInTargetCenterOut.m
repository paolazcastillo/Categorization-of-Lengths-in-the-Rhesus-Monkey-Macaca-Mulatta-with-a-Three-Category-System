function inside = CheckInTargetCenterOut(x, y, targetRect)
% CHECKINTARGETCENTEROUT  True if point (x,y) is inside a target.
%
%   Deterministic helper reconstructed from its call site in
%   CenterOutTask.m:
%       inTarget(k) = CheckInTargetCenterOut(x, y, tarPos{k})
%   where tarPos{k} is a rect [x1 y1 x2 y2] that the engine draws as a filled
%   oval (Screen('FillOval', ...)). The acceptance region therefore matches the
%   drawn disc: a circle inscribed in the (square) rect.
%
%   This is hardware-independent and exact; safe to use on the rig too.

if isempty(targetRect) || all(targetRect == 0)
    inside = false;   % target not placed yet
    return;
end

cx = (targetRect(1) + targetRect(3)) / 2;
cy = (targetRect(2) + targetRect(4)) / 2;
radius = (targetRect(3) - targetRect(1)) / 2;
inside = (x - cx)^2 + (y - cy)^2 <= radius^2;
end
