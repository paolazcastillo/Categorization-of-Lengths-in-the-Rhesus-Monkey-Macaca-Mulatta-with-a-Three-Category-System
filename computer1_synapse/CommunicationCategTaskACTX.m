function CommunicationCategTaskACTX()
% COMMUNICATIONCATEGTASKACTX  Bridges the Synapse computer to the task's
%   computer over UDP.
%   Cleaned up from the lab's original Computer-1 Synapse bridge script (German Mendoza Martinez): removed
%   eye-tracking and NAS/mym calls, and removed bookkeeping variables that
%   were written but never read anywhere (see below).
%
%   Computer-1-only (Windows): uses actxcontrol (ActiveX/COM) and the TDT
%   SynapseAPI, neither of which exist on Linux/Computer 2. Launched by
%   CategTaskCommunication.m's "Run" button, which publishes the GUI
%   handles as the global handles_glob before calling this function.
%
%   Reward messages arrive from the task computer as an evaluable string
%   (e.g. "reward=1;rewDuration=250;") over the UDP link; rewDuration is
%   set that way, not by direct assignment in this file.
%
%   JOYSTICK RELAY (2026-07-29, made on-demand 2026-07-30): also drives the
%   analog-joystick-over-UDP relay (JoystickRelayToTask.m's
%   InitJoystickRelay.m/StepJoystickRelay.m/CleanupJoystickRelay.m, port
%   8831) from inside this SAME loop, reusing this function's own `syn`
%   handle; so pressing "Run" here can start both reward/marker handling
%   and the joystick relay in one MATLAB process, no second MATLAB window
%   needed. StepJoystickRelay.m is self-paced and never calls pause(), so
%   interleaving it here does not slow down this loop's own reward/marker
%   responsiveness.
%
%   The relay does NOT start automatically with "Run"; it starts OFF and
%   is turned on/off by an rz2RelayEnable=1/0 message from Computer 2 (see
%   SetRZ2RelayEnable.m), sent whenever Computer 2's own Input source
%   selection becomes/stops being 'rz2adc'. Previously this relay ran for
%   this whole script's lifetime regardless of what Computer 2 was doing
%   with it (even in plain 'joystick'/'mouse' sessions); wasted
%   SynapseAPI/network traffic for a signal nothing was reading. relayEnabled
%   here tracks whether the relay is CURRENTLY running (not just whether
%   Init succeeded); a start failure is caught and warned, not a hard
%   failure, so a joystick-relay problem never blocks reward delivery. Tied
%   to this loop's own TD.GetSysMode() condition, so leaving Preview/
%   Record stops the joystick relay right along with everything else,
%   no separate Ctrl+C needed for it.
%
%   TriggerDuration: 309 (1-1000)
%   TriggerThreshold: 0.48 (0-5)
%   RS4 address: \\RS4-41026\data\CategTask_V2-190729-121356
%   Current ip RS4: 10.1.0.42
clc
global handles_glob;

try
    fclose(instrfind); % close any open serial port objects
catch
    disp 'No serial ports open'
end

try
    handles = handles_glob;
    format shortg; % compact command-window number format

    % --- Reset GUI state for THIS run --------------------------------------
    % text7/text9 are only ever written at loop-end or inside catch; nothing
    % previously cleared them when a new run starts. Result: after a prior
    % run left "Out of loop" (or "Loop aborted") on screen, starting a new
    % run would update text6 to "Loop is running" as soon as the loop began,
    % while text7 kept showing the leftover text from the PREVIOUS run;
    % "Loop is running" and "Out of loop" visible at the same time. Confirmed
    % 2026-07-10.
    trySetGui(handles, 'text6', 'String', 'Starting...');
    trySetGui(handles, 'text6', 'ForegroundColor', [0 0 0.6]);
    trySetGui(handles, 'text7', 'String', '');
    trySetGui(handles, 'text9', 'String', '');
    drawnow()

    % --- Paths and hosts --------------------------------------------------
    addpath('C:\TDT\Synapse\SynapseAPI\Matlab');
    behPath = 'C:\CTS\MATBehavData\';
    remoteHost = '172.24.60.146';   % task computer (Computer 2)
    localHost  = '172.24.60.152';   % this computer (Synapse)

    % --- Trial/reward state -------------------------------------------------
    reward      = 0;   % 1 while a reward message is pending, set via eval(tmpStr)
    rewDuration = 0;    % reward gizmo duration, set via eval(tmpStr)
    % 1 while Computer 2 wants the RZ2 relay running (Input source =
    % 'rz2adc' selected there), set via eval(tmpStr); see
    % SetRZ2RelayEnable.m and the main loop's start/stop block below.
    rz2RelayEnable = 0;
    % Rows of [time, eventType, value], eventType: 1 = new stimulus index
    % (bVisIndex changed), 2 = reward delivered (value = duration). Saved to
    % actualTimes_<date>.mat at the end of the recording loop.
    stimRewTimes = [];
    trialInfo.actualTrial = 0;   % current trial id, from the task computer

    % --- Flags --------------------------------------------------------------
    doOnce          = 1;   % run the "loop started" GUI update once
    newInfoTrial    = 0;   % a new-trial message arrived, not yet processed
    doOnceInSession = 1;   % fetch the current Synapse block once per session

    % --- Synapse tag used below (the only one actually read/written) -------
    devName = 'RZ2(1)';   % preamp id
    tarStim = 'Spg/';

    % --- UDP link to the task computer --------------------------------------
    uTask = udp(remoteHost, 'RemotePort', 8830, 'LocalHost', localHost, 'LocalPort', 8830);
    uTask.OutputBufferSize = 100;
    uTask.Timeout = 1;
    uTask.DatagramTerminateMode = 'on';
    fopen(uTask);
    flushinput(uTask);   % wash out any stale messages from the task computer

    % --- TDT Synapse API / ActiveX connection -------------------------------
    syn = SynapseAPI('localhost');
    h = figure('Visible', 'off', 'HandleVisibility', 'off');
    TD = actxcontrol('TDevAcc.X', 'Parent', h);
    TD.ConnectServer('Local');

    bVisIndexPrev = TD.GetTargetVal([devName '.s' tarStim '/']); % prime for the change-detection below

    % --- Joystick relay (see header note above): starts OFF. Turned on/off
    % by Computer 2's rz2RelayEnable messages in the main loop below, not
    % here; see that block for why (only run the relay while Computer 2
    % actually has Input source = 'rz2adc' selected).
    relayEnabled = false;
    relayState   = [];

    % --- Main recording loop: runs while Synapse is in PREVIEW/RECORD -------
    while TD.GetSysMode() == 2 || TD.GetSysMode() == 3
        if doOnce
            set(handles.text6, 'String', 'Loop is running');
            set(handles.text6, 'ForegroundColor', 'blue');
            drawnow()
            doOnce = 0;
        end

        % Self-paced (see StepJoystickRelay.m); most calls here are a
        % no-op; never calls pause(), so it cannot slow down the
        % reward/marker handling below.
        if relayEnabled
            relayState = StepJoystickRelay(relayState);
        end

        bVisIndex = TD.GetTargetVal([devName '.s' tarStim '/']); % stimulus target value
        if bVisIndex ~= bVisIndexPrev
            stimRewTimes(end + 1, :) = [GetSecs(), 1, bVisIndex]; %#ok<AGROW>
            bVisIndexPrev = bVisIndex;
        end

        % --- Read a message from the task computer, if any -----------------
        tmpStr = ReadUDP(uTask);
        if ~isempty(tmpStr)
            % flushUDP() is not a MATLAB/Instrument Control Toolbox function
            % and was never defined anywhere in this codebase, it crashed
            % on the very first UDP message received (reward or trial-info
            % alike), aborting straight to the catch block before eval(tmpStr)
            % could ever run. flushinput() is the real function; it's already
            % used for the same purpose above (line ~65). Confirmed 2026-07-10.
            flushinput(uTask)
            if isstruct(tmpStr)
                % New-trial struct: initialTimeTrialReal, dimension, curr_block, actualTrial
                trialInfo = tmpStr;
                newInfoTrial = 1;
            elseif ischar(tmpStr)
                eval(tmpStr); % sets reward/rewDuration/rz2RelayEnable (see header note)
            else
                disp 'Warning! unknown UDP packet received'
                pause
            end
        end

        % --- Start/stop the RZ2 joystick relay to match Computer 2's
        % current Input source selection (rz2RelayEnable, set above via
        % eval(tmpStr); see SetRZ2RelayEnable.m). relayEnabled tracks
        % whether the relay is CURRENTLY running; a start failure is caught
        % and warned, not a hard failure, so it never blocks reward
        % delivery below.
        %
        % MATLAB's Code Analyzer flags both branches below as unreachable
        % (%#ok<UNRCH> suppresses that); it cannot see that eval(tmpStr)
        % above is what actually changes rz2RelayEnable at runtime, so from
        % its static, eval()-blind view rz2RelayEnable looks like a
        % constant 0 forever. Same false positive that would apply to the
        % reward/rewDuration eval() pattern above if mlint's dead-code
        % check happened to trigger on it too. ---
        if rz2RelayEnable && ~relayEnabled
            try %#ok<UNRCH>
                relayState   = InitJoystickRelay(syn);
                relayEnabled = true;
            catch ME_relay
                warning('Joystick relay disabled (init failed): %s', ME_relay.message);
            end
        elseif ~rz2RelayEnable && relayEnabled
            try, CleanupJoystickRelay(relayState); catch, end %#ok<UNRCH>
            relayEnabled = false;
        end

        % --- New-trial bookkeeping ------------------------------------------
        if newInfoTrial
            % Save the trial id into the Synapse circuit/TANK
            TD.SetTargetVal([devName '.Trial_Trial'], trialInfo.actualTrial);
            drawnow()

            if doOnceInSession
                syn.getCurrentBlock(); % touch the current recording tank once
                doOnceInSession = 0;
            end
            newInfoTrial = 0;
        end

        % --- Deliver a pending reward through the Synapse reward gizmo -----
        if rewDuration > 0
            TD.SetTargetVal([devName '.RewardGizmo_Reward'], 0);
            TD.SetTargetVal([devName '.RewardGizmo_RewardDuration'], rewDuration);
            TD.SetTargetVal([devName '.RewardGizmo_Reward'], 1);
            pause(rewDuration / 1000);  % espera la duración REAL de la válvula
            TD.SetTargetVal([devName '.RewardGizmo_Reward'], 0);
            stimRewTimes(end + 1, :) = [GetSecs(), 2, rewDuration]; %#ok<AGROW>
            reward = 0;
            rewDuration = 0;
        end
    end

    % Loop exited because Synapse left Preview/Record; stop the joystick
    % relay right along with everything else (see header note above).
    if relayEnabled, try, CleanupJoystickRelay(relayState); catch, end, end

    if ~isempty(stimRewTimes)
        save([behPath 'actualTimes_' date], 'stimRewTimes')
    end
    sca;

catch me
    % --- Diagnostics FIRST, unconditionally --------------------------------
    % Print to the command window before touching the GUI at all. Previously
    % the set(handles.text6, ...) calls ran first and, if the GUI figure had
    % already been closed/deleted (handles.text6 invalid), that set() call
    % itself errored, which aborted the catch block before ever reaching
    % disp(me.message), silently swallowing the real error. Confirmed
    % 2026-07-10: "Error using matlab.ui.control.UIControl/set: Invalid or
    % deleted object" at this exact line masked whatever actually failed in
    % the try block above.
    disp('--- CommunicationCategTaskACTX: error caught ---')
    disp(me.message)
    if ~isempty(me.stack)
        disp(['line ' num2str(me.stack(1).line)])
        disp(['function ' me.stack(1).name])
    else
        disp('(no stack info available)')
    end

    try, sca; catch, end

    % --- GUI updates: best-effort, each independently guarded --------------
    % A closed/deleted figure must not prevent cleanup (uTask/h) or hide the
    % diagnostics above; every set() is wrapped separately so one invalid
    % handle doesn't stop the rest.
    if exist('handles', 'var')
        trySetGui(handles, 'text6', 'String', 'Code error!');
        trySetGui(handles, 'text6', 'ForegroundColor', 'red');
        trySetGui(handles, 'text7', 'String', 'Loop aborted');
        trySetGui(handles, 'text7', 'ForegroundColor', 'red');
        trySetGui(handles, 'text9', 'String', 'Script paused, press enter to exit');
        trySetGui(handles, 'text9', 'ForegroundColor', 'red');
        drawnow()
    else
        disp('(handles_glob was empty/invalid -- GUI not updated)')
    end

    if exist('uTask', 'var'), try, fclose(uTask); catch, end, end
    if exist('h', 'var'), try, close(h); catch, end, end
    if exist('relayEnabled', 'var') && relayEnabled, try, CleanupJoystickRelay(relayState); catch, end, end

    disp('Script paused, press enter to exit')
    pause
end

if exist('handles', 'var')
    trySetGui(handles, 'text6', 'String', 'Synapse is not running');
    trySetGui(handles, 'text7', 'String', 'Out of loop');
    trySetGui(handles, 'text9', 'String', ' ');
    trySetGui(handles, 'text6', 'ForegroundColor', 'red');
    trySetGui(handles, 'text7', 'ForegroundColor', 'red');
    drawnow()
end
end

% ===========================================================================
function trySetGui(handles, fieldName, propName, propValue)
% TRYSETGUI  set() on a GUI control, skipping quietly if it's missing/deleted.
%   Keeps a stale/closed GUI figure from masking real errors or blocking
%   cleanup elsewhere in this file.
if isfield(handles, fieldName) && isvalid(handles.(fieldName))
    set(handles.(fieldName), propName, propValue);
end
end