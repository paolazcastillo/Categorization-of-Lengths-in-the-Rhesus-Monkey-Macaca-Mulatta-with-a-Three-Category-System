function inside = CheckInCircle(x, y, cx, cy, rectLeft, rectRight)
% CHECKINCIRCLE  True if point (x,y) is inside the centre hold window.
%   Paola Castillo 2026-07-31
%
%   Call site in CenterOutTask.m and CenterInTask.m:
%     CheckInCircle(x, y, xCenter, yCenter, centerCircle(1), centerCircle(3))
%
%   centerCircle = CenterRectOnPointd([0 0 r r], cx, cy) returns the PTB
%   rect [cx-r/2, cy-r/2, cx+r/2, cy+r/2]. Column indices:
%     1 = rectLeft  = cx - r/2   (x of left  edge)
%     2 =             cy - r/2   (y of top    edge, not used here)
%     3 = rectRight = cx + r/2   (x of right edge)
%     4 =             cy + r/2   (y of bottom edge, not used here)
%
%   The acceptance region is a CIRCLE (the centre window is drawn with
%   Screen('FrameOval')), centred on (cx, cy) with radius (rectRight -
%   rectLeft) / 2. This is exact and hardware-independent.

radius = (rectRight - rectLeft) / 2;
inside = (x - cx)^2 + (y - cy)^2 <= radius^2;
end
