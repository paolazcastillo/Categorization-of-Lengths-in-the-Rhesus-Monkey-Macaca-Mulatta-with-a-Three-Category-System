function [kbDevice, useKbQueue] = SetupKeyboardDevice(useMouse, keysToWatch)
% SETUPKEYBOARDDEVICE  Resolve which physical keyboard device index to use
% for KbQueueCheck/SafeKbCheck, and start a KbQueue on it if possible.
% Paola Castillo 2026-07-31
%
%   Do NOT hardcode a device index: on Linux/X11 (Computer 2 rig) index 1
%   is the "master keyboard" (X11's virtual core keyboard), which
%   KbQueueCreate explicitly refuses to use ("Invalid deviceIndex
%   specified. Master keyboards can not be handled by this function.").
%   This was the root cause of a KbQueueCreate failure that cascaded into
%   HideCursor and FillRect errors on invalid window handles.
%
%   GetKeyboardIndices alone is not enough either: on this rig it returns
%   5 keyboard-class devices (Virtual core XTEST keyboard, 2x Power
%   Button, Dell WMI hotkeys, and the real Dell Wired Multimedia
%   Keyboard) -- the first index is the XTEST virtual device, not the
%   physical keyboard. Power Button/hotkeys devices also don't report
%   standard keys (space/ESC/r), so picking one of those would fail
%   silently (no error, but the task would never see a keypress). Filter
%   out known non-keyboard classes by name and keep whatever remains.
%   Confirmed on this rig (2026-07-10): after this filter, index 8
%   ('Dell Dell Wired Multimedia Keyboard') is the sole survivor and
%   physically registers keypresses via KbQueueCheck.
%
%   Prefer KbQueue for keyboard polling: on OSes the installed PTB does
%   not support (e.g. macOS 26) plain KbCheck can be left
%   half-initialised and error, whereas the KbQueue path is independent
%   and usually still works. useKbQueue=false tells the caller to fall
%   back to SafeKbCheck().
%
%   INPUT  useMouse    : true skips keyboard hardware entirely (kbDevice = [])
%          keysToWatch : vector of key codes (from KbName) to arm on the queue
if useMouse
    kbDevice = [];
    useKbQueue = false;
    return;
end

[kbIdx, kbNames] = GetKeyboardIndices;
excludePatterns = {'virtual', 'xtest', 'power button', 'hotkeys'};
isJunk = false(size(kbIdx));
for i = 1:numel(kbNames)
    nameLower = lower(kbNames{i});
    for p = 1:numel(excludePatterns)
        if contains(nameLower, excludePatterns{p})
            isJunk(i) = true;
        end
    end
end
kbIdxCandidates   = kbIdx(~isJunk);
kbNamesCandidates = kbNames(~isJunk);

if isempty(kbIdxCandidates)
    warning('centerTask:noKeyboard', ...
        ['No physical keyboard survived the exclusion filter ' ...
        '(only virtual/hotkey/power-button devices were detected); ' ...
        'space/ESC/r controls disabled for this run.']);
    kbDevice = [];
else
    if numel(kbIdxCandidates) > 1
        warning('centerTask:ambiguousKeyboard', ...
            'More than one keyboard candidate after filtering (%s); using the first: %s (index %d).', ...
            strjoin(kbNamesCandidates, ', '), kbNamesCandidates{1}, kbIdxCandidates(1));
    end
    kbDevice = kbIdxCandidates(1);
end

useKbQueue = false;
try
    kqList = zeros(1, 256);
    kqList(keysToWatch) = 1;
    KbQueueCreate(kbDevice, kqList);
    KbQueueStart(kbDevice);
    useKbQueue = true;
catch
    useKbQueue = false;
end
end