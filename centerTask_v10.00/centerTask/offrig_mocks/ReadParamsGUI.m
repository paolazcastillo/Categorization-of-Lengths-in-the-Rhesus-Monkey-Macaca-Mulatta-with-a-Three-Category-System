function params = ReadParamsGUI(handles)
% READPARAMSGUI  (off-rig mock) Build the run-parameter struct.
%
%   On the rig this reads the training-console widgets. Off-rig the exact
%   widget set is not known in advance, so this returns sensible defaults
%   and overrides them with any matching edit boxes that DO exist in
%   `handles`. Only the fields the task engine actually consumes are
%   guaranteed.
%
%   NOTE: this is a MOCK for off-rig logic testing, not the lab function.

% --- Defaults (override below if the matching widget exists) -------------
params.stop               = 0;
params.Reward             = 0.20;   % reward valve open time (s)
params.centerRad          = 150;    % centre-window diameter (px)
params.centerToTargetDist = 200;    % centre-to-target distance (px)

% --- Pull values from edit boxes when present ---------------------------
params.Reward             = readNum(handles, 'editReward',    params.Reward);
params.trainTrials        = readNum(handles, 'editTrainRepe', 400);
params.testTrials         = readNum(handles, 'editTestRepe',  0);
end

function val = readNum(handles, tag, default)
% Return str2double of a uicontrol's String if the tagged field exists.
val = default;
if isstruct(handles) && isfield(handles, tag)
    raw = str2double(get(handles.(tag), 'String'));
    if ~isnan(raw), val = raw; end
end
end