function AlertTaskDone(outcome, enabled)
% ALERTTASKDONE  Audible alert when a session ends.
%
%   A session ends on its own schedule (the stop quota is reached), and the
%   task screen looks much the same the moment before and the moment after.
%   Without a sound, an operator who stepped away only finds out on their
%   next glance at the console, with the subject sitting in front of a
%   finished task, and the rig held up. This plays a short tone sequence
%   the instant the run ends, one per outcome, so "done", "you stopped it"
%   and "it crashed" are distinguishable from across the room.
%
%   INPUT
%     outcome : 'done'    : the session completed its quota (rising 3-tone)
%               'stopped' : ended by the operator, Abort or the stop key
%                            (falling 2-tone)
%               'error'   : the engine hit its crash handler (low, repeated)
%     enabled : optional, default true. Pass orgParams.alertOnFinish through
%               so a rig with no speakers (or an operator who does not want
%               it) can turn every call off from one place.
%
%   Never throws and never blocks the caller: a machine with no working
%   audio device falls back to MATLAB's own beep, and if that is off too the
%   run still ends normally. Deliberately called AFTER the hardware teardown
%   in both engines, so an audio problem cannot leave a valve, a UDP socket
%   or the PTB screen open behind it.
%
%   sound() has no device argument: this always goes to the SYSTEM DEFAULT
%   output. On a rig whose speakers hang off a second output, the tone plays
%   without error and nobody hears it; run testAlarmSpeakers.m to find out
%   which output device the speakers are actually on.
%
% See also: AlertWaveform, testAlarmSpeakers, CenterOutTask, CenterInTask, ConfigOrgParams

if nargin < 2 || isempty(enabled), enabled = true; end
if ~enabled, return; end
if nargin < 1 || isempty(outcome), outcome = 'done'; end

[wave, fs] = AlertWaveform(outcome);   % the tones themselves live there

try
    sound(wave, fs);
catch
    % No audio device, or it is busy/misconfigured: fall back to the
    % built-in beep rather than let a cosmetic alert kill the end of a
    % session that has already saved its data.
    try, beep; catch, end
end
end
