function [wave, fs] = AlertWaveform(outcome)
% ALERTWAVEFORM  The end-of-session alert tone sequence, as raw samples.
%   Paola Castillo 2026-08-06
%
%   Split out of AlertTaskDone.m so the tones live in ONE place: the engines
%   play them through AlertTaskDone (system default output, via sound()),
%   while testAlarmSpeakers.m has to push the same samples through a chosen
%   output device to find which one the rig speakers hang off. A second copy
%   of the tone table would drift, and then the speaker test would be
%   verifying a sound the rig never actually makes.
%
%   INPUT
%     outcome : 'done'    -- session completed its quota (rising 3-tone)
%               'stopped' -- ended by the operator/Abort (falling 2-tone)
%               'error'   -- the engine hit its crash handler (low, repeated)
%
%   OUTPUT
%     wave : 1xN row of samples in [-1 1], amplitude 0.35
%     fs   : 8192 Hz -- MATLAB's own default sound() rate. Kept low on
%            purpose: it is the rate every device is most likely to accept.
%            Some WASAPI/USB outputs still refuse it, which is exactly what
%            testAlarmSpeakers.m checks per device.
%
% See also: AlertTaskDone, testAlarmSpeakers

if nargin < 1 || isempty(outcome), outcome = 'done'; end

fs = 8192;
switch lower(outcome)
    case 'stopped'
        freqs = [740 494];          % falling: ended early, on purpose
        toneSec = 0.16;
    case 'error'
        freqs = [233 233 233];      % low and repeated: something went wrong
        toneSec = 0.22;
    otherwise
        freqs = [587 784 1047];     % rising: the session finished its quota
        toneSec = 0.15;
end

gapSec = 0.06;
gap = zeros(1, round(gapSec * fs));
wave = [];
for i = 1:numel(freqs)
    t = (0 : round(toneSec * fs) - 1) / fs;
    tone = 0.35 * sin(2 * pi * freqs(i) * t);
    % Fade the first and last 10 ms of every tone: a sine cut off
    % mid-cycle clicks through the speakers, which on a quiet rig is more
    % startling than the alert itself.
    nFade = min(round(0.01 * fs), floor(numel(tone) / 2));
    ramp = linspace(0, 1, nFade);
    tone(1:nFade) = tone(1:nFade) .* ramp;
    tone(end-nFade+1:end) = tone(end-nFade+1:end) .* fliplr(ramp);
    wave = [wave, tone, gap];   %#ok<AGROW> -- at most 3 short tones
end
end
