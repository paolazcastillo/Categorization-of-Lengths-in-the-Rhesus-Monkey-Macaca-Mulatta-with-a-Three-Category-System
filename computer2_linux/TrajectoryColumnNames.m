function varNames = TrajectoryColumnNames(nCols, withMoveTime)
% TRAJECTORYCOLUMNNAMES  CSV column names for a stripped trajectory matrix.
%
%   Single source of truth for the header that SaveTrajectory.m and
%   SaveMovementTrajectory.m write. Call with the column count of the
%   already-stripped matrix (TrialNum removed, so 7 or 5 columns):
%
%     varNames = TrajectoryColumnNames(size(trajectory, 2));
%
%   withMoveTime (optional, default false) appends the extra trailing
%   'MoveTime_ms' column that ONLY the movement-only export carries: the
%   per-record time measured from that trial's own movement onset (see
%   SaveMovementTrajectory.m). Pass the base column count, NOT the widened
%   one, i.e. TrajectoryColumnNames(size(m, 2) - 1, true), so both
%   layouts keep a single definition here:
%
%     7 + MoveTime_ms  Date, Time_ms, X_px, Y_px, Epoch, Block,
%                      TrialNumInBlock, Attempt, MoveTime_ms
%
%   Supported layouts (column count AFTER removing the TrialNum column):
%     7  CenterOutTask.m  (N x 8 raw buffer -> N x 7 stripped):
%          Date, Time_ms, X_px, Y_px, Epoch, Block, TrialNumInBlock, Attempt
%     5  CenterInTask.m   (N x 6 raw buffer -> N x 5 stripped):
%          Date, Time_ms, X_px, Y_px, Epoch, Attempt
%
%   Time is MILLISECONDS SINCE THE FIRST TRIAL OF THE SESSION STARTED (see
%   sessionT0 in CenterOutTask.m/CenterInTask.m's trial loop), not an
%   absolute clock reading; row 1 of a fresh session is always ~0. Every
%   row is stamped the same way, at the instant its own cursor sample was
%   read, no matter which write path in the trial loop produced it, and
%   BOTH exports carry the column unmodified; the movement-only file
%   appends MoveTime_ms rather than re-zeroing Time_ms. A given row's
%   Time_ms is therefore identical in trajectory_*.csv and
%   trajectory_movement_*.csv, which is what lets the two be joined.
%
%   Adding a new engine with a different buffer layout: add a case here.
%   Neither SaveTrajectory.m nor SaveMovementTrajectory.m needs to change.
if nargin < 2 || isempty(withMoveTime)
    withMoveTime = false;
end
switch nCols
    case 7
        varNames = {'Date', 'Time_ms', 'X_px', 'Y_px', 'Epoch', 'Block', 'TrialNumInBlock', 'Attempt'};
    case 5
        varNames = {'Date', 'Time_ms', 'X_px', 'Y_px', 'Epoch', 'Attempt'};
    otherwise
        error('TrajectoryColumnNames:unknownLayout', ...
            ['Unrecognized trajectory column count (%d after stripping TrialNum). ' ...
            'Expected 5 (CenterInTask, 6-col raw buffer) or ' ...
            '7 (CenterOutTask, 8-col raw buffer). ' ...
            'Add a case to TrajectoryColumnNames.m for new engines.'], nCols);
end
if withMoveTime
    varNames{end + 1} = 'MoveTime_ms';
end
end