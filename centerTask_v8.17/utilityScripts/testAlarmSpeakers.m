function results = testAlarmSpeakers(mode, deviceID)
% TESTALARMSPEAKERS  Check that the rig speakers actually carry the
% end-of-session alarm, and find which output device they are wired to.
% Paola Castillo 2026-08-06
%
% The alarm (AlertTaskDone.m) is played with MATLAB's sound(), which has no
% device argument: it ALWAYS goes to the system default output. So on a rig
% whose speakers hang off a second output -- HDMI monitor, USB DAC, the amp
% in the rack -- the session ends, the tone "plays" with no error, and
% nobody in the room hears a thing. This script separates the four things
% that can be wrong, in the order worth checking:
%
%   1. the alarm is not called by the engines, or alertOnFinish is false
%   2. the default output device rejects 8192 Hz, so sound() silently
%      falls back to beep (which may itself be muted)
%   3. it plays fine, but to the WRONG device -- 'sweep' finds the right one
%   4. it reaches the right device, but a cable/channel/volume is dead
%
% USAGE
%   testAlarmSpeakers                % full guided check -- start here
%   testAlarmSpeakers('devices')     % just list output devices, no sound
%   testAlarmSpeakers('alarm')       % the 3 real alarms, default device
%   testAlarmSpeakers('sweep')       % same alarm through EVERY device in turn
%   testAlarmSpeakers('device', 3)   % through output device ID 3 only
%   testAlarmSpeakers('channels')    % left / right / both, finds a dead speaker
%   testAlarmSpeakers('loop')        % repeats, so you can walk to the rack
%
% 'devices' is the only mode that neither plays nor prompts, so it is the
% one that is safe to run while a session is up.
%
% OUTPUT (also printed)
%   results.devices        struct array: ID, Name, supports8192
%   results.defaultDeviceID  what sound() will use (-1 = OS default)
%   results.wiredInEngines   both engines still call AlertTaskDone
%   results.alertOnFinish    the ConfigOrgParams default
%   results.heardOnDevices   IDs you confirmed by ear (sweep/device modes)
%
% See also: AlertTaskDone, AlertWaveform, ConfigOrgParams

if nargin < 1 || isempty(mode), mode = 'full'; end
if nargin < 2, deviceID = []; end

% centerTask holds AlertTaskDone/AlertWaveform/ConfigOrgParams; locate it
% robustly and put it on the path, so a five-minute hardware check needs no
% cd. The old fixed guess (a 'centerTask' sibling of this script) broke on a
% rig that keeps the code in a dated wrapper (e.g. centerTask_07082026/
% centerTask), leaving taskDir wrong and AlertTaskDone undefined -- see
% findTaskDir for the order it tries now.
here    = fileparts(mfilename('fullpath'));
taskDir = findTaskDir(here);
if ~isempty(taskDir) && exist('AlertWaveform', 'file') ~= 2
    addpath(taskDir);
end
if isempty(taskDir)
    fprintf(['   NOTE: could not locate the centerTask folder automatically.\n' ...
             '   If the steps below say AlertTaskDone/ConfigOrgParams are undefined,\n' ...
             '   run:  addpath(''<path to your centerTask>'')  and re-run.\n']);
end

results = struct('devices', [], 'defaultDeviceID', [], 'wiredInEngines', [], ...
                 'alertOnFinish', [], 'heardOnDevices', []);
results.heardOnDevices = [];

fprintf('\n=== ALARM / SPEAKER CHECK ===\n');

switch lower(mode)
    case 'devices'
        [results.devices, results.defaultDeviceID] = reportDevices();
    case 'alarm'
        [results.devices, results.defaultDeviceID] = reportDevices();
        playAllAlarmsOnDefault();
    case 'device'
        if isempty(deviceID)
            error('testAlarmSpeakers:noDevice', ...
                  'Mode ''device'' needs an ID: testAlarmSpeakers(''device'', 3)');
        end
        [results.devices, results.defaultDeviceID] = reportDevices();
        if playOnDevice(deviceID, 'done')
            if askHeard(sprintf('device %d', deviceID)) == 1
                results.heardOnDevices = deviceID;
            end
        end
    case 'sweep'
        [results.devices, results.defaultDeviceID] = reportDevices();
        results.heardOnDevices = sweepDevices(results.devices);
        reportSweepVerdict(results);
    case 'channels'
        [results.devices, results.defaultDeviceID] = reportDevices();
        channelTest(deviceID);
    case 'loop'
        loopAlarm();
    otherwise   % 'full'
        [results.wiredInEngines, results.alertOnFinish] = reportWiring(taskDir);
        [results.devices, results.defaultDeviceID] = reportDevices();
        reportSystemVolume();
        heardIt = playAllAlarmsOnDefault();
        channelTest([]);
        reportFullVerdict(results, heardIt);
end

fprintf('\n');
end

% ===========================================================================
function td = findTaskDir(here)
% Where centerTask actually is, most reliable first:
%   1. already on the MATLAB path (the operator runs the console from it) --
%      which('AlertWaveform.m') then names its folder directly;
%   2. a recursive search under this script's project root for AlertWaveform.m
%      sitting inside a folder named 'centerTask' -- this is what survives a
%      dated wrapper like centerTask_<date>/centerTask;
%   3. the old fixed guess (a 'centerTask' sibling of this script).
% Returns '' if none of them find it (the caller then prints a NOTE).
td = '';
w = which('AlertWaveform.m');
if isempty(w), w = which('CenterOutTask.m'); end
if ~isempty(w), td = fileparts(w); return; end

root = fileparts(here);
if ~isempty(root) && exist(root, 'dir') == 7
    try
        hits = dir(fullfile(root, '**', 'AlertWaveform.m'));   % R2016b: ** recursion + .folder
        for i = 1:numel(hits)
            [~, leaf] = fileparts(hits(i).folder);
            if strcmpi(leaf, 'centerTask')
                td = hits(i).folder;
                return;
            end
        end
    catch
    end
end

guess = fullfile(fileparts(here), 'centerTask');
if exist(guess, 'dir') == 7
    td = guess;
end
end

% ===========================================================================
function [wired, alertOnFinish] = reportWiring(taskDir)
% Before touching a cable: is the alarm even reachable from a real session?
% Both facts are read from the files themselves, not assumed, because "the
% speakers are dead" and "nothing ever calls the alarm" sound identical
% from the other side of the room.
fprintf('\n-- 1. Wiring in the code --\n');

wired = true;
engines = {'CenterOutTask.m', 'CenterInTask.m'};
for k = 1:numel(engines)
    if ~isempty(taskDir)
        f = fullfile(taskDir, engines{k});
    else
        f = '';
    end
    if isempty(f) || exist(f, 'file') ~= 2
        f = which(engines{k});   % maybe centerTask is on the path even if taskDir was not resolved
    end
    if isempty(f) || exist(f, 'file') ~= 2
        fprintf('   %-18s NOT FOUND (add your centerTask folder to the MATLAB path)\n', engines{k});
        wired = false;
        continue;
    end
    nCalls = numel(strfind(fileread(f), 'AlertTaskDone('));
    if nCalls > 0
        fprintf('   %-18s calls AlertTaskDone (%d call sites)\n', engines{k}, nCalls);
    else
        fprintf('   %-18s DOES NOT call AlertTaskDone -- no alarm from this engine\n', engines{k});
        wired = false;
    end
end

alertOnFinish = true;
try
    d = ConfigOrgParams.getTaskDefaults();
    if isfield(d, 'alertOnFinish')
        alertOnFinish = logical(d.alertOnFinish);
    end
    if alertOnFinish
        fprintf('   orgParams.alertOnFinish = true  (alarm enabled by default)\n');
    else
        fprintf('   orgParams.alertOnFinish = FALSE -- the alarm is switched off\n');
        fprintf('     -> ConfigOrgParams.m, "=== SESSION ===" block\n');
    end
catch err
    fprintf('   Could not read ConfigOrgParams defaults (%s)\n', err.message);
end
% The console never shows this field, so it can only be false if someone
% edited ConfigOrgParams.m or passed alertOnFinish in an offline script.
fprintf('   (CenterConsole does not expose this switch -- it comes from the defaults)\n');
end

% ===========================================================================
function [devices, defaultID] = reportDevices()
% Every output MATLAB can see, plus whether it accepts the alarm's 8192 Hz.
% A device that says "no" there is a silent alarm even when everything else
% is right: sound() throws, AlertTaskDone swallows it and beeps instead.
fprintf('\n-- 2. Audio output devices --\n');

devices = struct('ID', {}, 'Name', {}, 'supports8192', {});
info = audiodevinfo;
if isempty(info.output)
    fprintf('   NO OUTPUT DEVICES VISIBLE TO MATLAB. Nothing can play here.\n');
    defaultID = -1;
    return;
end

defaultID = -1;
try
    p = audioplayer(zeros(64, 1), 8192);   % default device, then ask which it is
    defaultID = p.DeviceID;
    clear p;
catch
    fprintf('   (could not open the default device at 8192 Hz)\n');
end

fprintf('   %-4s %-8s %-11s %s\n', 'ID', 'default', '8192 Hz', 'Name');
for k = 1:numel(info.output)
    id = info.output(k).ID;
    ok = false;
    try
        ok = audiodevinfo(0, id, 8192, 16, 1) == 1;
    catch
    end
    devices(end+1) = struct('ID', id, 'Name', info.output(k).Name, ...
                            'supports8192', ok);   %#ok<AGROW>
    okTxt = 'REJECTED';
    if ok
        okTxt = 'ok';
    end
    defTxt = '';
    if id == defaultID
        defTxt = '<--';
    end
    fprintf('   %-4d %-8s %-11s %s\n', id, defTxt, okTxt, info.output(k).Name);
end

if defaultID < 0
    fprintf('   sound() uses the OS default output (ID -1: whatever the\n');
    fprintf('   operating system''s sound settings currently point at).\n');
end
end

% ===========================================================================
function reportSystemVolume()
% A muted OS mixer looks exactly like a dead speaker from MATLAB's side.
fprintf('\n-- 3. System volume --\n');
if ismac
    % osascript only prints its LAST statement, so volume and mute have to
    % come back from one expression or the second reading masks the first.
    [st, out] = system(['osascript -e "set s to (get volume settings)" ' ...
                        '-e "(output volume of s as text) & \",\" & (output muted of s as text)"']);
    parts = regexp(strtrim(out), ',', 'split');
    if st == 0 && numel(parts) == 2
        fprintf('   Output volume: %s / 100\n', strtrim(parts{1}));
        fprintf('   Muted: %s\n', strtrim(parts{2}));
        if strcmpi(strtrim(parts{2}), 'true')
            fprintf('   -> MUTED. Nothing below this line can be heard until you unmute.\n');
        end
    else
        fprintf('   Could not read the system volume.\n');
    end
else
    % No scriptable equivalent worth trusting on the Windows rig, and a
    % wrong reading here is worse than none.
    fprintf('   Check the OS mixer by hand: system volume up, not muted, and\n');
    fprintf('   MATLAB not muted in the per-application volume mixer.\n');
end
end

% ===========================================================================
function heardAny = playAllAlarmsOnDefault()
% The real thing: AlertTaskDone itself, not a re-implementation, so what
% you judge by ear is exactly what a finished session will make.
fprintf('\n-- 4. The three real alarms (default device, via AlertTaskDone) --\n');
outcomes = {'done', 'stopped', 'error'};
labels = {'DONE: rising 3-tone (quota reached)', ...
          'STOPPED: falling 2-tone (operator/Abort)', ...
          'ERROR: low repeated tone (crash)'};
heard = nan(1, 3);
for k = 1:numel(outcomes)
    fprintf('   playing -- %s\n', labels{k});
    AlertTaskDone(outcomes{k}, true);
    pause(1.6);      % AlertTaskDone's sound() is non-blocking; let it finish
    heard(k) = askHeard(outcomes{k});
end
if all(isnan(heard))
    heardAny = NaN;          % nobody could be asked -- see askHeard
else
    heardAny = double(any(heard == 1));
end
end

% ===========================================================================
function heardIDs = sweepDevices(devices)
% The point of the whole script: play the same alarm out of every device in
% turn, so the one the rig speakers hang off identifies itself by ear.
fprintf('\n-- Sweep: the DONE alarm through every output device --\n');
heardIDs = [];
for k = 1:numel(devices)
    fprintf('\n   [%d/%d] ID %d: %s\n', k, numel(devices), devices(k).ID, devices(k).Name);
    if playOnDevice(devices(k).ID, 'done')
        if askHeard(sprintf('ID %d', devices(k).ID)) == 1
            heardIDs(end+1) = devices(k).ID;   %#ok<AGROW>
        end
    end
end
end

% ===========================================================================
function ok = playOnDevice(id, outcome)
% audioplayer is the only way to aim at a specific device -- sound() cannot.
% Devices that refuse 8192 Hz get the same tones resampled to 44100 rather
% than being skipped: for a "can this box make noise at all" test, a
% resampled alarm answers the question.
ok = false;
info = audiodevinfo;
if ~any([info.output.ID] == id)
    fprintf('      NO SUCH OUTPUT DEVICE (ID %d). Run testAlarmSpeakers(''devices'').\n', id);
    return;
end

[wave, fs] = AlertWaveform(outcome);
try
    supported = audiodevinfo(0, id, fs, 16, 1) == 1;
catch
    supported = false;
end
if ~supported
    fsNew = 44100;
    t0 = (0:numel(wave)-1) / fs;
    t1 = 0 : 1/fsNew : t0(end);
    wave = interp1(t0, wave, t1, 'linear', 0);
    fs = fsNew;
    fprintf('      (8192 Hz refused by this device -- resampled to 44100 Hz)\n');
end
try
    p = audioplayer(wave(:), fs, 16, id);
    playblocking(p);
    ok = true;
catch err
    fprintf('      CANNOT PLAY on this device: %s\n', err.message);
end
end

% ===========================================================================
function channelTest(id)
% Left, right, then both -- one dead channel is the failure that survives
% every other check on this list, because the alarm still "works".
fprintf('\n-- 5. Left / right channels --\n');
[mono, fs] = AlertWaveform('done');
mono = mono(:);
sides = {'LEFT speaker only', 'RIGHT speaker only', 'BOTH'};
waves = {[mono, zeros(size(mono))], [zeros(size(mono)), mono], [mono, mono]};
for k = 1:3
    fprintf('   playing -- %s\n', sides{k});
    try
        if isempty(id)
            p = audioplayer(waves{k}, fs);          % default device
        else
            p = audioplayer(waves{k}, fs, 16, id);
        end
        playblocking(p);
    catch err
        fprintf('      could not play: %s\n', err.message);
        return;
    end
    if askHeard(sides{k}) == 0
        fprintf('      -> that channel is not reaching a speaker (cable, amp, or balance).\n');
    end
    pause(0.3);
end
end

% ===========================================================================
function loopAlarm()
% For checking the rack itself: the alarm repeats while you walk over to
% the speakers, trace the cable and turn the amp up.
fprintf('\n-- Loop: DONE alarm every 4 s. Ctrl-C to stop. --\n');
for k = 1:60
    fprintf('   repetition %d/60\n', k);
    AlertTaskDone('done', true);
    pause(4);
end
end

% ===========================================================================
function reportSweepVerdict(results)
fprintf('\n-- Verdict --\n');
if isempty(results.heardOnDevices)
    fprintf('   No device produced audible sound. The problem is downstream of\n');
    fprintf('   MATLAB: speakers unpowered, cable, amp, or a muted OS mixer.\n');
    return;
end
fprintf('   Audible on device ID(s): %s\n', mat2str(results.heardOnDevices));
if results.defaultDeviceID >= 0 && ~any(results.heardOnDevices == results.defaultDeviceID)
    fprintf('   The default device (ID %d) is NOT one of them -- this is the\n', results.defaultDeviceID);
    fprintf('   "alarm plays, nobody hears it" case.\n');
end
printFixOptions(results.heardOnDevices);
end

% ===========================================================================
function reportFullVerdict(results, heardIt)
fprintf('\n-- Verdict --\n');
if isnan(heardIt)
    fprintf('   The alarms were played on the default output, but this MATLAB\n');
    fprintf('   could not ask you whether they came out. If they did not, run\n');
    fprintf('   testAlarmSpeakers(''sweep'') from the MATLAB desktop.\n');
    return;
end
if heardIt == 1
    fprintf('   The alarm reaches the speakers on the default output.\n');
    fprintf('   Nothing to change: a finished session will be audible.\n');
    return;
end
fprintf('   The alarm did NOT come out of the speakers. Next steps:\n');
if ~isempty(results.wiredInEngines) && ~results.wiredInEngines
    fprintf('   * An engine does not call AlertTaskDone -- fix that first (step 1).\n');
end
if ~isempty(results.alertOnFinish) && ~results.alertOnFinish
    fprintf('   * alertOnFinish is false -- the alarm is switched off (step 1).\n');
end
if ~isempty(results.devices)
    defOK = true;
    for k = 1:numel(results.devices)
        if results.devices(k).ID == results.defaultDeviceID
            defOK = results.devices(k).supports8192;
        end
    end
    if ~defOK
        fprintf('   * The default device rejects 8192 Hz -- sound() throws and\n');
        fprintf('     AlertTaskDone falls back to beep(), which may be off too.\n');
    end
end
fprintf('   * Run  testAlarmSpeakers(''sweep'')  to find which output device\n');
fprintf('     the speakers are actually on.\n');
end

% ===========================================================================
function printFixOptions(heardIDs)
fprintf('\n   To make the alarm come out THERE:\n');
fprintf('   a) Route the alarm to it directly (recommended): set\n');
fprintf('        orgParams.alertAudioDevice = %d;\n', heardIDs(1));
fprintf('      in ConfigOrgParams.m. AlertTaskDone now takes an audiodevinfo\n');
fprintf('      device id and plays through it via audioplayer, so the alarm\n');
fprintf('      goes THERE without moving any other MATLAB sound. (This is the\n');
fprintf('      device id you just confirmed by ear.)\n');
fprintf('   b) Or set device ID %d as the system DEFAULT output in the OS\n', heardIDs(1));
fprintf('      sound settings. sound() follows the OS default, so no code\n');
fprintf('      change -- but it moves every other MATLAB sound too.\n');
end

% ===========================================================================
function yes = askHeard(label)
% 1 = heard it, 0 = did not, NaN = nobody could be asked. The third value
% matters: run headless (-batch, -nodisplay) the sound still comes out of
% the rig, but input() does not exist, and reporting that as "not heard"
% would send the operator chasing a fault that is not there.
if ~usejava('desktop')
    fprintf('      (non-interactive MATLAB: cannot ask about "%s" -- judge by ear)\n', label);
    yes = NaN;
    return;
end
r = input(sprintf('      heard "%s"? [y/n] ', label), 's');
yes = double(~isempty(r) && lower(r(1)) == 'y');
end
