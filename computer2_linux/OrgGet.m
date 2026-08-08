function val = OrgGet(orgParams, field, default)
% ORGGET  orgParams.(field) if present and usable, otherwise `default`.
% Centralises the GUI-override pattern used for timing/geometry constants
% throughout CenterOutTask.m and CenterInTask.m.
%
% A field counts as usable when it is present, non-empty, and (for numeric
% values) free of NaN. The NaN check exists because CenterConsole.m fills
% every numeric field with str2double(get(edit, 'String')), and str2double
% returns NaN rather than erroring whenever the text is not a plain number:
% an emptied box, a stray letter, or a comma decimal separator ('0,5'
% instead of '0.5') all produce NaN. NaN is not empty, so without this guard
% it would sail past the isempty test and reach the task as a real value.
%
% That failure is silent and total rather than noisy and local. NaN
% propagates through arithmetic without complaint and poisons every
% comparison it touches, because any relational test against NaN is false:
%   centerRad   = NaN -> centerCircle is all-NaN -> CheckInCircle is always
%                        false -> the cursor can never register as inside
%                        the centre -> the task sits in ENTER_CENTER
%                        forever, logging nothing and raising nothing.
%   holdTimeBase= NaN -> `this_time > t.centerHold + holdTime` is always
%                        false -> the same hang, one epoch later.
% Falling back to the documented default keeps the session runnable, and the
% warning makes the substitution visible instead of letting the operator
% believe the value they typed took effect. All OrgGet calls happen once
% during setup, never inside the frame loop, so warning here costs nothing.
%
% Non-numeric values (the logical useCue, the char stimulusSet/stopMode) are
% passed through unchanged: NaN is not a state they can be in, and testing
% them for it would be meaningless.
val = default;
if ~isfield(orgParams, field) || isempty(orgParams.(field))
    return;
end

candidate = orgParams.(field);
if isnumeric(candidate) && any(isnan(candidate(:)))
    warning('OrgGet:nanField', ...
        ['orgParams.%s is NaN (an empty or unparseable console field -- ' ...
        'check for a comma decimal separator). Using the default instead: %s'], ...
        field, mat2str(default));
    return;
end
val = candidate;
end