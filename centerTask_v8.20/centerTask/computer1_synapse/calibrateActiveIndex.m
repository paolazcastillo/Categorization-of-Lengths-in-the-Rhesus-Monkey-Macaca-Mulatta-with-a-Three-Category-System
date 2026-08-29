function idx = calibrateActiveIndex(syn, gizmo, bufSize, waitSec)
% CALIBRATEACTIVEINDEX  Finds where a circular SerStore buffer (gizmo's
% 'data1' parameter) is CURRENTLY being written: two full-buffer
% snapshots, waitSec apart -- see ActiveIndexFromSnapshots.m for the
% diff-peak technique itself. Used for both the X and Y joystick channels
% (gizmo='APICh1X' or 'APICh2Y').
%
% BLOCKING (pause(waitSec) between the two snapshots) -- only called from
% InitJoystickRelay.m's startup calibration, before Communication_CategTask_
% ACTX.m's shared reward/marker loop is running, so the stall is harmless
% there. StepJoystickRelay.m's PERIODIC recalibration does NOT call this
% function: it re-implements the same two-snapshot technique as a
% non-blocking state machine (first snapshot on one call, second snapshot
% on a LATER call once waitSec has actually elapsed) so recalibrating never
% freezes that shared loop. It used to call this blocking version directly,
% which froze reward delivery for ~2*waitSec whenever a target hit landed
% during a recalibration window -- confirmed 2026-07-30, see
% StepJoystickRelay.m's header for the full story.
%
% Lower waitSec = shorter stall, but also fewer freshly-written samples
% land in the diff for the peak-detection below to work with -- see
% InitJoystickRelay.m's CALIBRATION_WAIT_SEC comment for the margin this
% needs against the 100-sample smoothing window ActiveIndexFromSnapshots.m
% uses.
data1 = double(syn.getParameterValues(gizmo, 'data1', bufSize, 0));
pause(waitSec);
data2 = double(syn.getParameterValues(gizmo, 'data1', bufSize, 0));
idx   = ActiveIndexFromSnapshots(data1, data2);
end
