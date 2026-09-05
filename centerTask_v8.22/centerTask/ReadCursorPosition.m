function [x, y] = ReadCursorPosition(taskWindow, inputSource, joy, rz2, xCenter, yCenter, screenXpixels, screenYpixels, pointer_offset, joyGain)
% READCURSORPOSITION  One cursor sample from whichever input device is
% active (inputSource: 'mouse' | 'joystick' | 'rz2adc'). Mouse mode reads
% screen coordinates directly; 'joystick' maps the raw [-1, 1] USB-joystick
% axes onto screen pixels around the window centre (the -1.3 scale factor
% and pointer_offset are the rig's existing calibration, unchanged from the
% original per-engine code). 'rz2adc' reads a SECOND, ADC-wired analog
% joystick relayed over UDP from Computer 1 (JoystickRelayToTask.m ->
% SetupRZ2Joystick.m/ReadRZ2Joystick.m), scaled by its OWN independently-
% tunable rz2.scaleX/scaleY/offsetY -- its native ADC voltage range has no
% reason to match the USB joystick's [-1, 1], so it is not forced through
% the same -1.3/pointer_offset pair. Every raw sample the relay delivered
% between frames is separately logged to the trajectory by
% CenterOutTask.m/CenterInTask.m (see TakeRZ2JoystickSamples.m) -- this
% function's [x, y] return is only the LATEST one, used for cursor
% rendering and hit-testing this frame.
% joyGain (optional, default -1.3) is the USB-'joystick' axis gain, now
% console-editable (orgParams.joyGain) instead of the old hardcoded -1.3.
% Only affects 'joystick'; 'rz2adc' has its own rz2.scaleX/scaleY and 'mouse'
% none. The sign sets axis direction and the magnitude the pixels-per-unit
% travel, so this is the knob for "the USB joystick feels too slow/fast/
% inverted".
if nargin < 10 || isempty(joyGain), joyGain = -1.3; end
switch inputSource
    case 'mouse'
        [x, y] = GetMouse(taskWindow);
    case 'rz2adc'
        [vx, vy] = ReadRZ2Joystick(rz2);
        x = xCenter + screenXpixels * vx * rz2.scaleX;
        y = yCenter + rz2.offsetY + screenYpixels * vy * rz2.scaleY;
    otherwise   % 'joystick'
        axesVals = read(joy);
        x = xCenter + screenXpixels * axesVals(1, 1) * joyGain;
        y = yCenter + pointer_offset + screenYpixels * axesVals(1, 2) * joyGain;
end
end
