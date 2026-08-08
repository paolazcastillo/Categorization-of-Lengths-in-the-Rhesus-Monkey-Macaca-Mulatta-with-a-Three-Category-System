function idx = ActiveIndexFromSnapshots(data1, data2)
% ACTIVEINDEXFROMSNAPSHOTS  Given two full-buffer snapshots of a circular
% SerStore buffer taken some time apart, return the index where the value
% changed the most, the freshly-written region, i.e. where the buffer is
% CURRENTLY being written. Diff-peak math shared by CalibrateActiveIndex.m
% (blocking, pause() between the two snapshots; startup calibration only)
% and StepJoystickRelay.m's periodic recalibration (non-blocking: the two
% snapshots are taken on separate calls instead of around a pause(), see
% that file's header for why).
diffVals   = abs(data2 - data1);
diffSmooth = conv(diffVals, ones(1, 100) / 100, 'same');
[~, idx]   = max(diffSmooth);
end
