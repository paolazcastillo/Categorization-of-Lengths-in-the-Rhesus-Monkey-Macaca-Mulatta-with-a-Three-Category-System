function ReportTimeMonotonicity(t, label)
% REPORTTIMEMONOTONICITY  Warn when an exported time column steps backwards.
%
%   Shared by SaveTrajectory.m and SaveMovementTrajectory.m. A trajectory's
%   Time_ms is assumed non-decreasing by every offline velocity, every
%   MoveTime_ms and every trial-window cut made downstream, and that
%   assumption was silently false for a whole session before anything
%   checked it: two time bases were sharing the one column (a free-running
%   index clock for the RZ2 samples, the wall clock for everything else), so
%   rows stamped from one sat between rows stamped from the other and the
%   column stepped backwards 506 times, by up to 3.17 s, in
%   sessPX-309 (03-Sep-2026).
%
%   Reports, does not repair. Reordering or clamping here would hide a live
%   instrumentation fault behind a tidy-looking file, which is exactly the
%   failure mode this check exists to end. The caller still writes the file.
%
%   Silent when the column is clean, so any output at all means something
%   needs looking at.
%
%   INPUT
%     t     : time column, milliseconds
%     label : name used in the message ('trajectory', 'movement trajectory')
%
%   See also: SaveTrajectory, SaveMovementTrajectory, RZ2ClockMap
    if numel(t) < 2
        return;
    end
    d = diff(t);
    back = d < 0;
    if ~any(back)
        return;
    end
    fprintf(['WARNING: %s Time_ms is NOT monotonic -- %d backward step(s) of ' ...
             '%d, worst %.3f s. Two time bases are sharing one column, or the ' ...
             'input clock map is being re-anchored backwards. Any velocity or ' ...
             'interval derived from this file is invalid where that happens; ' ...
             'check the RZ2 link summary and the RZ2Idx column (NaN marks rows ' ...
             'whose time is estimated, not index-derived).\n'], ...
            label, sum(back), numel(d), -min(d) / 1000);
end
