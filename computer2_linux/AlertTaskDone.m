function AlertTaskDone(outcome, enabled, device)
% ALERTTASKDONE  Audible alert when a session ends.
%   Paola Castillo 2026-08-04
%
%   A session ends on its own schedule (the stop quota is reached), and the
%   task screen looks much the same the moment before and the moment after.
%   Without a sound, an operator who stepped away only finds out on their
%   next glance at the console -- with the subject sitting in front of a
%   finished task, and the rig held up. This plays a short tone sequence
%   the instant the run ends, one per outcome, so "done", "you stopped it"
%   and "it crashed" are distinguishable from across the room.
%
%   INPUT
%     outcome : 'done'    -- the session completed its quota (rising 3-tone)
%               'stopped' -- ended by the operator, Abort or the stop key
%                            (falling 2-tone)
%               'error'   -- the engine hit its crash handler (low, repeated)
%     enabled : optional, default true. Pass orgParams.alertOnFinish through
%               so a rig with no speakers (or an operator who does not want
%               it) can turn every call off from one place.
%     device  : optional, default [] (empty). Which output the alert uses:
%                 []    -- MATLAB's sound(), i.e. the SYSTEM DEFAULT output.
%                          Exactly the behaviour this function always had.
%                 id    -- an audiodevinfo OUTPUT device ID (the same IDs
%                          testAlarmSpeakers.m lists and plays through). The
%                          alert is sent to THAT device via audioplayer, which
%                          -- unlike sound() -- can target a specific output.
%                          Use it on a rig whose speakers hang off a second
%                          output (e.g. the OS default is an HDMI monitor with
%                          no speakers). Pass orgParams.alertAudioDevice
%                          through from the engines.
%
%   Never throws and never blocks the caller beyond the tone's own length: an
%   invalid device id, a device that will not open, or no audio at all falls
%   back to sound() on the OS default, then to MATLAB's own beep, and if that
%   is off too the run still ends normally. Deliberately called AFTER the
%   hardware teardown in both engines, so an audio problem cannot leave a
%   valve, a UDP socket or the PTB screen open behind it.
%
%   Run testAlarmSpeakers.m to find which output device ID the rig speakers
%   are on, then put that number in orgParams.alertAudioDevice.
%
% See also: AlertWaveform, testAlarmSpeakers, CenterOutTask, CenterInTask, ConfigOrgParams

if nargin < 2 || isempty(enabled), enabled = true; end
if ~enabled, return; end
if nargin < 1 || isempty(outcome), outcome = 'done'; end
if nargin < 3, device = []; end

[wave, fs] = AlertWaveform(outcome);   % the tones themselves live there

% Targeted playback through a specific output device, via audioplayer (the
% only MATLAB primitive that takes a device id -- sound() does not). The IDs
% are audiodevinfo's, i.e. exactly what testAlarmSpeakers.m reports, so a
% number confirmed by ear there can be dropped straight into
% orgParams.alertAudioDevice. Wrapped in its own try/catch so a bad id or a
% refusing device falls through to the sound()/beep path below rather than
% taking down the end of a session that has already saved its data. A rig that
% leaves the device empty never enters this branch and behaves as before.
if ~isempty(device)
    try
        p = audioplayer(wave(:), fs, 16, device);
        playblocking(p);
        return;
    catch
        % fall through to the default-output path below
    end
end

try
    sound(wave, fs);
catch
    % No audio device, or it is busy/misconfigured: fall back to the
    % built-in beep rather than let a cosmetic alert kill the end of a
    % session that has already saved its data.
    try, beep; catch, end
end
end
