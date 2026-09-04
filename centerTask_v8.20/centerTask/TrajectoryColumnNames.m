function varNames = TrajectoryColumnNames(nCols, withMoveTime)
% TRAJECTORYCOLUMNNAMES  CSV column names for a stripped trajectory matrix.
%
%   Single source of truth for the header that SaveTrajectory.m and
%   SaveMovementTrajectory.m write. Call with the column count of the
%   already-stripped matrix (TrialNum removed, so 8 or 6 columns):
%
%     varNames = TrajectoryColumnNames(size(trajectory, 2));
%
%   withMoveTime (optional, default false) appends the extra trailing
%   'MoveTime_ms' column that ONLY the movement-only export carries: the
%   per-record time measured from that trial's own movement onset (see
%   SaveMovementTrajectory.m). Pass the base column count, NOT the widened
%   one -- i.e. TrajectoryColumnNames(size(m, 2) - 1, true) -- so both
%   layouts keep a single definition here:
%
%     8 + MoveTime_ms  Date, Time_ms, X_px, Y_px, Epoch, Block,
%                      TrialNumInBlock, Attempt, RZ2Idx, MoveTime_ms
%
%   Supported layouts (column count AFTER removing the TrialNum column):
%     8  CenterOutTask.m  (N x 9 raw buffer -> N x 8 stripped):
%          Date, Time_ms, X_px, Y_px, Epoch, Block, TrialNumInBlock,
%          Attempt, RZ2Idx
%     6  CenterInTask.m   (N x 7 raw buffer -> N x 6 stripped):
%          Date, Time_ms, X_px, Y_px, Epoch, Attempt, RZ2Idx
%
%   RZ2Idx (2026-09-04) is the relay's absolute sample index on the rz2adc
%   path and NaN everywhere else, which makes it the row's PROVENANCE, not
%   an ornament: NaN says this row's Time_ms was estimated rather than
%   derived from an index. Before it existed, a wall-clock-stamped row and
%   an index-derived one were indistinguishable in the export, which is how
%   two different time bases coexisted in one Time_ms column for a whole
%   session without anything downstream being able to notice. It also lets
%   an offline analysis re-derive timing under a different sample rate.
%   The 7- and 5-column layouts are sessions written before that date.
%
%   Time is MILLISECONDS SINCE THE FIRST TRIAL OF THE SESSION STARTED (see
%   sessionT0 in CenterOutTask.m/CenterInTask.m's trial loop), not an
%   absolute clock reading -- row 1 of a fresh session is always ~0. Every
%   row is stamped the same way, at the instant its own cursor sample was
%   read, no matter which write path in the trial loop produced it, and
%   BOTH exports carry the column unmodified -- the movement-only file
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
    case 8
        varNames = {'Date', 'Time_ms', 'X_px', 'Y_px', 'Epoch', 'Block', 'TrialNumInBlock', 'Attempt', 'RZ2Idx'};
    case 6
        varNames = {'Date', 'Time_ms', 'X_px', 'Y_px', 'Epoch', 'Attempt', 'RZ2Idx'};
    case 7
        % Pre-2026-09-04 CenterOutTask layout, no RZ2Idx column.
        varNames = {'Date', 'Time_ms', 'X_px', 'Y_px', 'Epoch', 'Block', 'TrialNumInBlock', 'Attempt'};
    case 5
        % Pre-2026-09-04 CenterInTask layout, no RZ2Idx column.
        varNames = {'Date', 'Time_ms', 'X_px', 'Y_px', 'Epoch', 'Attempt'};
    otherwise
        error('TrajectoryColumnNames:unknownLayout', ...
            ['Unrecognized trajectory column count (%d after stripping TrialNum). ' ...
            'Expected 6 (CenterInTask, 7-col raw buffer) or ' ...
            '8 (CenterOutTask, 9-col raw buffer), or their pre-2026-09-04 ' ...
            'equivalents 5 and 7. ' ...
            'Add a case to TrajectoryColumnNames.m for new engines.'], nCols);
end
if withMoveTime
    varNames{end + 1} = 'MoveTime_ms';
end
end