function joy = SetupJoystick()
% SETUPJOYSTICK  Initialize the rig joystick (index 1), with a clear
% error if it's not connected/recognized instead of a cryptic vrjoystick
% error surfacing mid-task.
% Paola Castillo 2026-07-31
try
    joy = vrjoystick(1);
catch ME_joy
    error('centerTask:noJoystick', ...
        ['Could not initialize the joystick at index 1: %s\n' ...
        'Verify the joystick is connected and recognized before ' ...
        'starting the task (check with vrjoystick(1) directly in the console).'], ...
        ME_joy.message);
end
end