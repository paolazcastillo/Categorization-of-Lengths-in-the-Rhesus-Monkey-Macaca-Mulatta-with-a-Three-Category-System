function CenterInTask(orgParams)
% CENTERINTASK  Simple centre-hold training task.
%
%   No bar, no cue, no categories: the subject must move the cursor
%   (joystick or mouse, orgParams.inputSource) into the centre window and
%   hold it there for holdTime to receive a reward. Meant as a
%   pre-categorization training step, run through CenterConsole.m's Task
%   type = "Center-In (hold)".
%
%   OPTIONAL REACH-TO-TARGET MODE (orgParams.useTargetReach, console
%   checkbox "Reach to target"): adds a single peripheral target
%   (Right/Up/Left/Down) after the centre hold succeeds; the subject must
%   then reach it and hold inside it (targetDuration/minTarHoldTime, the
%   same shared timing fields CenterOutTask.m reads) before reward. Off by
%   default, which reproduces this engine's original hold-only behaviour
%   exactly. Target position is drawn from orgParams.targetWeights (console
%   "Target weights (R,U,L,D)") via BuildWeightedTargetSequence.m, a
%   balanced pseudorandom sequence, not i.i.d. sampling, so realized
%   proportions don't drift and runs of the same direction stay bounded.
%   Per-direction correct/attempt counts are reported at session end (see
%   printCenterInDirMatrix) and saved alongside the usual summary.
%
%   CENTRE JITTER: in PURE HOLD mode (useTargetReach off) the hold-target's
%   drawn position is always offset by +/- orgParams.centerJitterRange
%   (console "Center jitter (+/- px)", default 150 px) each NEW trial
%   (retries keep the same spot); the whole point of pure hold mode is
%   that the subject has to find a new spot every trial; only how far that
%   spot can land is adjustable. The cursor's own screen mapping stays
%   anchored to the TRUE centre regardless, so the subject has to actually
%   move the joystick/mouse to find wherever the target landed; the
%   "neutral" joystick position does not track the jitter.
%
%   With REACH mode on (useTargetReach), the hold-target is pinned to the
%   true screen centre instead: the peripheral target's position is
%   already the randomized element there (drawn relative to the
%   hold-target), so also jittering the hold-target would compound two
%   independent randomizations the subject would have to solve at once.
%
%   TARGET COLOUR (orgParams.centerInTargetColor, console "Target colour
%   (hex)" under Center-In): the peripheral reach-mode target's fill
%   colour; only ever drawn when useTargetReach is on. Default 00FF00
%   (green), via OrgGetColor.m/HexToRGB.m, same convention as
%   CenterOutTask.m's category colours.
%
%   HOLD-RING COLOUR EFFECT (orgParams.useHoldColorEffect, console "Gray
%   until holding"): OFF by default; the centre hold-ring is always
%   green, with no visual distinction between "waiting to enter" and
%   "holding". ON restores the original cue: gray while waiting to enter
%   the centre (or before the hold timer has actually started), green once
%   the hold officially begins (EP.HOLD). See waitColor below.
%
%   Shares its setup/teardown plumbing (handles contract, hardware
%   init, async-flip cursor oversampling, pause handling) with
%   CenterOutTask.m via the same helper files, so a run looks and
%   behaves consistently across both engines, just with the bar/cue/
%   target epochs removed and no per-length/category bookkeeping;
%   there is nothing here to categorize.
%
%   INPUT  orgParams : struct of GUI handles and run parameters (from
%          CenterConsole.m's runTask, or built by hand by a caller like
%          OffrigPlay.m, same 5-field handles contract as
%          CenterOutTask.m).
%   Local helpers: initTimes, printCenterInSummary. Setup/teardown
%   plumbing shared with CenterOutTask.m (OrgGet, BlankScreen,
%   ForceCloseScreen, ConfirmRecordingLink, HideCursorSafe,
%   SetupKeyboardDevice, SafeKbCheck, SetupJoystick, SetupSynapseUDP,
%   InitTaskHandles, ReadCursorPosition, PauseLoop, SaveTrajectory) is NOT
%   local; see their own files in centerTask/.
if nargin < 1 || isempty(orgParams), orgParams = struct(); end

% ===========================================================================
% QUICK-EDIT: session stop condition
% ===========================================================================
%   The session runs until `maxCorrectTrials` hold-in-centre trials have
%   been rewarded (orgParams.maxCorrectTrials, console field "Center-In:
%   target correct trials"). Unlike CenterOutTask.m there is no finite
%   pseudorandom stimulus sequence to exhaust; every trial is identical
%   (enter, hold), so a subject that never engages can run indefinitely;
%   the operator's Abort button is the backstop, same as it would be on the
%   rig for any training task.
%   Rewarded holds are the ONLY thing that fills the quota here:
%   orgParams.quotaByPresentations (CenterOutTask.m's presentation-quota
%   switch, and the console's "Quota counts presentations" readout) is
%   deliberately not read by this engine. There it makes the session a
%   fixed length while keeping the (length, position) design balanced,
%   every combination shown the same number of times, an error costing its
%   own slot. This engine has no such grid to balance, so the same switch
%   would only mean "stop after N attempts, however many earned reward",
%   and a subject who never holds could finish a training session with
%   zero. The criterion this task exists to reach is the count of rewarded
%   holds, so it is the count of rewarded holds that ends it.
maxCorrectTrials = OrgGet(orgParams, 'maxCorrectTrials', 50);

% --- Named epoch (state) constants ---------------------------------------
% Plain numbers, not the TaskEpoch enumeration CenterOutTask.m uses: this
% engine has its own, much shorter epoch set with no bar/cue/target states,
% so sharing that enumeration would mean importing eight codes that can
% never occur here. The trajectory buffer therefore stores these numerics
% directly (no .Value dereference).
EP.ENTER_CENTER = 1;   % wait for cursor to reach the centre
EP.HOLD_START   = 2;   % count the attempt, start the hold timer
EP.HOLD         = 3;   % hold inside centre for holdTime, then reward (or the target, below)
EP.REWARD       = 4;   % deliver reward
EP.SUCCESS_FB   = 5;   % success feedback
EP.ERROR_FB     = 6;   % error feedback: white/black screen flash (left centre/target before hold time elapsed, or reach timeout)
EP.ITI          = 7;   % inter-trial interval
EP.BOOKKEEP     = 8;   % update GUI, log the trial, arm the next one
EP.TARGET_GO    = 9;   % reach-mode only: peripheral target shown, wait to enter it
EP.TARGET_HOLD  = 10;  % reach-mode only: hold inside the target for targetHoldTime, then reward

% --- Network endpoints (reward / event markers over UDP to Synapse) ------
remoteHost = '172.24.60.152';
localHost  = '172.24.60.146';

exitFlag = 0;
Screen('Preference', 'SkipSyncTests', 1);

try
% =========================================================================
% SETUP
% =========================================================================
% Status/GUI handles: auto-create a minimal status figure if the caller
% didn't pass one, same handles contract CenterOutTask.m uses (see
% that file's own SETUP section for why: it's what OffrigPlay.m and
% CenterConsole.m's runTask both point at every frame); see InitTaskHandles.m.
if ~isfield(orgParams, 'handles') || isempty(orgParams.handles)
    orgParams.handles = InitTaskHandles('CenterInTask');
end

d = datestr(now, 'dd-mmm-yyyy_HH-MM');
if isfield(orgParams, 'runTag') && ~isempty(orgParams.runTag)
    d = orgParams.runTag;
end
sessionDate = datestr(now, 'dd-mm-yyyy');

% --- Output folder: all session results go to outputs/<yyyy-mm>/ --------
outMonth = datestr(now, 'yyyy-mm');
outDir   = fullfile('outputs', outMonth);
if ~exist(outDir, 'dir'), mkdir(outDir); end

% --- Console transcript -> session_report_centerIn_<runTag>.txt ----------
% Same contract as CenterOutTask.m: started as soon as the output folder
% exists so the .txt holds the whole run, and kept alive by logCleanup until
% this function returns (including through the catch block, so a crashed
% session still leaves its transcript and its error on disk). The
% 'centerIn_' prefix matches this engine's other output files, so a day
% mixing both engines does not produce two files with the same name. See
% StartSessionLog.m.
sessionLogFile = fullfile(outDir, ['session_report_centerIn_' d '.txt']);
% logCleanup must stay in scope: clearing it stops the log immediately.
logCleanup = StartSessionLog(sessionLogFile, 'CenterInTask', d);   %#ok<NASGU>

% Show performance from a previous run with the same timestamp, if any
try
    prev = load(fullfile(outDir, ['perf_centerIn_' d '.mat']), 'good_trials', 'total_trials');
    set(orgParams.handles.edit91, 'String', num2str(prev.good_trials));
    set(orgParams.handles.edit92, 'String', ...
        num2str(prev.good_trials / prev.total_trials * 100));
catch
end

% --- Timing parameters (seconds) -----------------------------------------
holdTime_base   = OrgGet(orgParams, 'holdTimeBase',  1.0);
holdTime_delta  = OrgGet(orgParams, 'holdTimeDelta', 0.5);
holdTime_min    = holdTime_base - holdTime_delta;
holdTime_max    = holdTime_base + holdTime_delta;

successFeed = 0.2;    % success feedback duration
errorFeed   = 0.2;    % error feedback duration (how long the error flash lasts)
% Half-period of the error screen flash: the display alternates white/black
% every errorFlashPeriod seconds while errorFeed runs, so the default pair
% gives one full white-black blink per failed trial. Same 0.1 s as
% CenterOutTask.m's wrong-target flash, so an error looks identical to the
% subject whichever engine it is training on.
errorFlashPeriod = 0.1;
ITI         = OrgGet(orgParams, 'ITI',       2);    % base inter-trial interval (successful trials)
ITI_delta   = OrgGet(orgParams, 'ITIDelta',  0.5);  % random +/- variation on the success ITI
ITI_error   = OrgGet(orgParams, 'ITIError',  3);    % inter-trial interval after errors (longer)
rewTime     = OrgGet(orgParams, 'Reward', 0.15);

% --- Reach-to-target mode (optional) --------------------------------------
% Off by default; reproduces the original hold-only engine exactly.
% targetDuration/targetHoldTime reuse the SAME shared console fields
% CenterOutTask.m reads (targetDuration, minTarHoldTime): one Timing column,
% both engines, no separate reach-only fields needed.
useTargetReach = logical(OrgGet(orgParams, 'useTargetReach', 0));
targetWeights  = OrgGet(orgParams, 'targetWeights', [0.25 0.25 0.25 0.25]);
targetDuration = OrgGet(orgParams, 'targetDuration', 5);      % reach timeout
targetHoldTime = OrgGet(orgParams, 'minTarHoldTime', 0);      % hold-in-target time (0 = touch is enough)

% --- Colours ---------------------------------------------------------------
white_c = [255 255 255];  black_c = [0 0 0];
green_c = [0 255 0];      red_c   = [255 0 0];
gray_c  = [140 140 140];

% Peripheral reach-mode target fill colour, console-configurable hex
% (OrgGetColor.m/HexToRGB.m, same convention as CenterOutTask.m's category
% colours). Defaults to the green_c constant. Only ever drawn when
% useTargetReach is on (see the render block below).
targetColor = OrgGetColor(orgParams, 'centerInTargetColor', green_c);

% Gray-while-waiting/green-while-holding hold-ring effect: OFF by default
% (waitColor = green_c, so the ring never visibly changes). ON restores
% the original gray-until-holding cue (waitColor = gray_c). See the
% "HOLD-RING COLOUR EFFECT" header section above for where waitColor is
% used (trial-init holdColor and the ENTER_CENTER priming draw below);
% EP.HOLD/EP.SUCCESS_FB always set holdColor = green_c regardless of this
% flag, since that assignment is a no-op when waitColor is already green.
useHoldColorEffect = logical(OrgGet(orgParams, 'useHoldColorEffect', false));
waitColor = green_c;
if useHoldColorEffect
    waitColor = gray_c;
end

orgParams.trainTrials = maxCorrectTrials;
set(orgParams.handles.editTrainRepe, 'String', num2str(maxCorrectTrials));
% The console's per-block/per-category breakdown box belongs to
% CenterOutTask; this task has neither blocks nor categories, so blank it
% rather than leave a previous Center-Out run's numbers standing next to a
% Center-In session. Optional field: handles built by hand (OffrigPlay, or
% anything predating it) simply don't have it.
if isfield(orgParams.handles, 'textBreakdown')
    set(orgParams.handles.textBreakdown, 'String', '');
end

% --- Counters ------------------------------------------------------------
good_trials       = 0;  total_trials = 0;
trialIndex        = 0;   % advances once a trial resolves (correct, or maxStimAttempts exhausted)
error_early_exit  = 0;   % left the centre before holdTime elapsed
error_reach_timeout = 0; % reach-mode only: didn't enter the target within targetDuration
error_target_exit   = 0; % reach-mode only: left the target before targetHoldTime elapsed
prevTrialCorrect  = 0;
holdAchievedLog   = nan(1, max(maxCorrectTrials * 3, 10));   % QC: actual hold duration per attempt

% --- Trial-by-trial CSV (append mode: safe even if the task crashes) -----
trialLogFile = fullfile(outDir, ['trial_data_centerIn_' d '.csv']);
fid_log = fopen(trialLogFile, 'w');
% HoldTimeRequired_s is what was ASKED of this trial; HoldAchieved_s is what
% the subject actually produced, measured sample-to-sample; see the
% pooling warning at the BOOKKEEP epoch, which explains why that column is
% not comparable with sessions recorded before it became a measurement.
fprintf(fid_log, 'Date,TrialNum,Attempt,HoldTimeRequired_s,TimeToEnterCentre_s,HoldAchieved_s,IsCorrect,ErrorType,PrevTrialCorrect,TargetDir,ReachTime_s,HoldX_px,HoldY_px\n');
fclose(fid_log);
fprintf('Trial log file created: %s\n', trialLogFile);

% --- Open the display ------------------------------------------------------
screens = Screen('Screens');
screenNumber = max(screens);
[taskWindow, windowRect] = PsychImaging('OpenWindow', screenNumber, white_c);
% Guaranteed screen/priority/cursor teardown on ANY exit path; see the
% matching comment in CenterOutTask.m's SETUP for why this is
% independent of the rig-side CloseTask() helper.
ptbForceCleanup = onCleanup(@() ForceCloseScreen(taskWindow));
[screenXpixels, screenYpixels] = Screen('WindowSize', taskWindow);
screenXpixels = screenXpixels / 2;
screenYpixels = screenYpixels / 2;
flipInterval = Screen('GetFlipInterval', taskWindow);
Priority(MaxPriority(taskWindow));
Screen('BlendFunction', taskWindow, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

pointerRad     = 15;
pointer_offset = -220;
FixPoint = [-15 15 0 0; 0 0 -15 15];
[xCenter, yCenter] = RectCenter(windowRect);
% Console-configurable, same OrgGet-with-fallback pattern as the timing
% fields above and as CenterOutTask.m's own geometry. This matters more
% here than anywhere else in the project: the diameter of the centre window
% IS the difficulty of this task, since holding inside it is the entire
% requirement. Default 200 matches CenterOutTask.m so a subject moving
% between the two engines meets the same target size.
centerRad    = OrgGet(orgParams, 'centerRad', 200);   % centre-window diameter (px)
circleSize   = [0 0 centerRad centerRad];
% centerJitterRange: +/- px random offset of the hold-target's DRAWN
% position, ALWAYS applied in pure hold mode (console-configurable; there
% is still no "fixed at centre" option; the whole point of pure hold
% mode is that the subject has to find a new spot every trial, only how
% FAR that spot can land is adjustable). Drawn fresh once per TRIAL (not
% per retry; see "repeat_trial == 0" below), same convention as the
% reach-mode target direction. Deliberately does NOT change xCenter/
% yCenter themselves: the cursor's own screen mapping (ReadCursorPosition
% below) stays anchored to the TRUE centre, so the subject must actually
% move the joystick/mouse to find wherever the target landed this trial,
% rather than the "neutral" joystick position always happening to
% coincide with the target.
centerJitterRange = OrgGet(orgParams, 'centerJitterRange', 150);   % +/- px, pure hold mode only
holdX = xCenter;  holdY = yCenter;   % overwritten every trial below; placeholder for pre-loop use
centerCircle = CenterRectOnPointd(circleSize, holdX, holdY);

% --- Reach-mode target geometry (only meaningful if useTargetReach) -------
% Same convention as CenterOutTask.m: targets are targetRad-sized circles
% (independent of centerRad; same shared console field CenterOutTask.m
% reads) placed on a ring of radius centerToTargetDist*1.27 around the four
% cardinal directions. dy = -sin(a) so 90deg renders ABOVE screen-centre
% (PTB's y-axis grows downward); matches the Right/Up/Left/Down
% convention SessionReport.m's matrices already use for CenterOutTask.
% Targets4Dir is recomputed every trial (below, in the trial-start block)
% around holdX/holdY instead of the true centre, so it moves together with
% the jittered hold-target.
targetRad          = OrgGet(orgParams, 'targetRad', 200);          % peripheral target diameter (px)
centerToTargetDist = OrgGet(orgParams, 'centerToTargetDist', 200);
targetRadius  = centerToTargetDist * 1.27;
targetDirsDeg = [0 90 180 270];   % Right, Up, Left, Down
nDir = numel(targetDirsDeg);
Targets4Dir = repmat(centerCircle, nDir, 1);   % placeholder; recomputed per trial when useTargetReach

if useTargetReach
    if numel(targetWeights) ~= nDir
        error('CenterInTask:badTargetWeights', ...
            'targetWeights must have %d elements (Right/Up/Left/Down); got %d.', ...
            nDir, numel(targetWeights));
    end
    % blockSize=20, maxConsecSame=3: same defaults the reference training
    % script used: [35 15 35 15]-style weights reduce to exact integer
    % counts at blockSize=20, and a run of 3 is long enough to rarely force
    % the constraint-relaxation fallback for reasonable weights.
    targetSeq = BuildWeightedTargetSequence(maxCorrectTrials, targetWeights, 20, 3);
end
seqIdx = 0;
currentTargetDir  = 1;
currentTargetRect = Targets4Dir(1, :);

% Per-direction tallies (meaningful only when useTargetReach; harmless,
% all-zero otherwise); see printCenterInDirMatrix.
totalPerDir          = zeros(1, nDir);   % attempts where this direction's target was shown
correctPerDir        = zeros(1, nDir);
errReachTimeoutPerDir = zeros(1, nDir);
errTargetExitPerDir   = zeros(1, nDir);
reachTimePerDir = cell(1, nDir);
for iDir = 1:nDir, reachTimePerDir{iDir} = []; end

% --- Hardware: keyboard, joystick, UDP -----------------------------------
% Input source: 'joystick' (rig, default), 'mouse' (off-rig play/testing),
% or 'rz2adc' (a SECOND, ADC-wired analog joystick relayed over UDP from
% Computer 1's JoystickRelayToTask.m; see SetupRZ2Joystick.m). useMouse
% still gates keyboard-device selection, the reward UDP link, and the
% recording-link gate below exactly as before; useRZ2 additionally picks
% WHICH real device supplies the cursor, AND (further down, where trajBuf
% is logged) switches to recording every UDP sample the relay delivered
% between frames instead of one sample per frame.
inputSource = 'joystick';
if isfield(orgParams, 'inputSource') && ~isempty(orgParams.inputSource)
    inputSource = lower(orgParams.inputSource);
end
useMouse = strcmp(inputSource, 'mouse');
useRZ2   = strcmp(inputSource, 'rz2adc');

KEY_SPACE  = KbName('space');
KEY_ESCAPE = KbName('ESCAPE');
KEY_R      = KbName('r');
RestrictKeysForKbCheck([KEY_SPACE KEY_ESCAPE KEY_R]);
% See SetupKeyboardDevice.m for the full rationale (X11 master-keyboard /
% XTEST / hotkey-device filtering, KbQueue-over-KbCheck preference),
% shared with CenterOutTask.m.
[kbDevice, useKbQueue] = SetupKeyboardDevice(useMouse, [KEY_SPACE KEY_ESCAPE KEY_R]);
joy = [];  rz2 = [];
if useRZ2
    rz2 = SetupRZ2Joystick(orgParams, remoteHost);
elseif ~useMouse
    joy = SetupJoystick();
end
HideCursorSafe(taskWindow);

manualReward     = rewTime / 2;
manualRewardTime = 0;

% --- Water accounting ----------------------------------------------------
% Same contract as CenterOutTask.m: accumulate what Rewards() reports it
% actually commanded (post-clamp, and 0 when the Synapse UDP link is
% missing) rather than recomputing good_trials * rewTime, and keep the
% automatic and manual paths apart. Printed by SessionReport.reward, which
% both engines share.
rewardPulsesTask   = 0;  rewardSecTask   = 0;   % automatic pulse on each rewarded hold
rewardPulsesManual = 0;  rewardSecManual = 0;   % operator's 'r' key presses
rewardMlPerSec = OrgGet(orgParams, 'rewardMlPerSec', 0);   % 0 = valve not calibrated; report seconds only

uSynapse = [];
if ~useMouse
    uSynapse = SetupSynapseUDP(remoteHost, localHost);
    % Tell Computer 1 whether to actually run the RZ2 analog-joystick relay
    % (see SetRZ2RelayEnable.m); so it's only active while THIS machine
    % has Input source = 'rz2adc' selected, not for Computer 1's whole
    % "Run" session regardless of input source.
    SetRZ2RelayEnable(useRZ2, uSynapse);
end

h = orgParams.handles.dlgTrainingMain;

% --- Pre-run safety gate: confirm the recording amplifiers / Synapse link;
% Same rationale as CenterOutTask.m: UDP is connectionless, so reward
% markers never fail even with the amplifiers off. Skipped off-rig.
if ~useMouse && ~ConfirmRecordingLink()
    fprintf('Run aborted by operator: recording link not confirmed.\n');
    set(orgParams.handles.text77, 'String', 'Aborted: check amplifiers');
    set(orgParams.handles.text77, 'ForegroundColor', 'red');
    exitFlag = 1;
end

% =========================================================================
% TRIAL LOOP (finite-state machine)
% =========================================================================
setOnce_Trial = 1;
repeat_trial  = 0;
pauseTask     = 0;
% Set true the moment the operator ends the session early (console Abort
% button or in-window ESC key); distinguishes an operator-stopped run
% from a normal quota-completed one in the end-of-session status text
% (search "Task stopped" below). Same as CenterOutTask.m.
abortedByOperator = false;

% Correction procedure: a failed attempt repeats (same task, there is no
% varying stimulus to reshuffle), up to maxStimAttempts total attempts; the
% last consecutive failure counts as this trial's final error and trialIndex
% advances. Console-editable via orgParams.maxStimAttempts.
%
% orgParams.useRetries false (the console unchecks it automatically for a
% human participant; see ConfigSession.m) clamps that to a single attempt
% per trial, whatever maxStimAttempts says. Same clamp, same reasoning, as
% CenterOutTask.m: with a ceiling of 1, `stimAttempt < maxStimAttempts` is
% never true, so repeat_trial and the "attempt n/m" status text switch
% themselves off with no second code path. (This engine has no requeue at
% all (it has no stimulus, hence no (length, position) combination to
% verify) so orgParams.useRequeue means nothing here.)
maxStimAttempts = OrgGet(orgParams, 'maxStimAttempts', 5);
if ~logical(OrgGet(orgParams, 'useRetries', true))
    maxStimAttempts = 1;
end
stimAttempt     = 1;

% Same async-flip cursor oversampling as CenterOutTask.m; see that
% file's SETUP section for the full rationale (decouples the trajectory
% sample rate from the screen's Hz, extra samples taken free inside the
% pending-flip wait).
moveOversample   = OrgGet(orgParams, 'moveOversample', 1);
moveOversampleDt = OrgGet(orgParams, 'moveOversampleDt', 0.008);

% Per-trial visual state
showCursor = 1;  holdColor = waitColor;
cursorRect = [0 0 0 0];
% awaitTargetOnset: set when the state machine turns the reach target on,
% cleared by the next flip, which is what stamps t.targetOnset with the real
% stimulus-onset timestamp (see the render block below).
awaitTargetOnset = 0;

% --- Joystick/cursor trajectory buffer (X,Y over time) --------------------
% One row per frame: [TrialNum, Time, X, Y, Epoch, Attempt]. No Block/
% TrialNumInBlock columns here; there is no length/position rotation to
% split on, every trial is the same task. SaveTrajectory.m detects this
% 6-column layout from the column count and writes the matching CSV header.
% Time is MILLISECONDS SINCE THE FIRST TRIAL STARTED (sessionT0, captured
% once below the first time the setOnce_Trial block runs), not an absolute
% clock reading; so trajectory_*.csv always starts at ~0 regardless of
% how long MATLAB/Psychtoolbox had been running before this session began.
% ONE CONVENTION FOR EVERY ROW, same as CenterOutTask.m: a row is stamped
% at the moment its own x/y was read (sampleTime), minus sessionT0 (not
% at the top of the frame) so Time_ms is comparable across rows, across
% both engines' files, and against the console's live session clock.
trajChunk = 200000;
trajBuf   = zeros(trajChunk, 6);
trajN     = 0;

% sessionT0: GetSecs() the instant the first trial starts (set once, inside
% the setOnce_Trial block below; setOnce_Trial starts true, so this fires
% on the loop's very first iteration, before any trajBuf row is written).
% lastSessionTimeUpdate throttles the console's live "Session time" box to
% roughly once a second instead of every frame.
sessionT0             = [];
lastSessionTimeUpdate = 0;

% sessionHoldT0: when the SESSION CLOCK starts; the first hold of the
% first trial (EP.HOLD_START below), the first moment the subject engaged.
% Deliberately NOT sessionT0, which anchors the exported trajectory
% timestamps and must stay at the start of trial 1, or every sample taken
% before the first hold would be dated to a negative time. Same split, same
% reasoning as CenterOutTask.m. Once started it runs unbroken: an early exit
% does not stop it, so that trial's time counts up to the next trial's hold.
sessionHoldT0 = [];

% Discard whatever the RZ2 relay queued while the rest of setup ran; above
% all the recording-link dialog, which holds here for as long as the
% operator takes. Those samples predate the session; keeping them would both
% stall the first frames working the backlog off AND anchor the trajectory
% clock on a stale sample. Same call, same reasoning, as CenterOutTask.m;
% see FlushRZ2Joystick.m.
if useRZ2
    nFlushed = FlushRZ2Joystick(rz2);
    if nFlushed > 0
        fprintf('RZ2 link: discarded %d queued datagram(s) from setup before starting.\n', nFlushed);
    end
end

while exitFlag == 0

    if setOnce_Trial
        % The live status line is written at the END of this block instead
        % of here (same as CenterOutTask.m): it reports the trial this
        % iteration is about to run, and trialIndex/stimAttempt are only
        % advanced further down.
        BlankScreen(taskWindow, black_c);

        t = initTimes();
        setOnce_Trial = 0;
        if isempty(sessionT0)
            % First time through setOnce_Trial == start of trial 1: zero
            % the trajectory clock here, not at script launch, so
            % trajectory_*.csv's Time column reflects task time, not
            % however long the console/GUI sat idle beforehand.
            sessionT0 = GetSecs();
        end
        setOnce_Hold  = 1;
        showCursor = 1;  holdColor = waitColor;
        awaitTargetOnset = 0;   % no target pending at the start of a trial
        good_trial = 0;  error_type = 0;
        current_ITI = ITI + (rand() * 2 - 1) * ITI_delta;
        holdTime = holdTime_min + rand() * (holdTime_max - holdTime_min);
        t.trialStart = GetSecs();
        if repeat_trial == 0
            trialIndex  = trialIndex + 1;
            stimAttempt = 1;
            % Re-jitter the hold-target's position only for a genuinely NEW
            % trial; a retry (repeat_trial == 1 below) keeps the SAME
            % spot, same rationale as the reach-target direction below
            % (there is only one hold-target here, so unlike the reach
            % target there is no elimination-by-retry concern; this just
            % matches the "same trial, try again" convention elsewhere).
            %
            % Centre jitter is ONLY applied in pure hold mode. With reach
            % mode on, the peripheral target's position is already the
            % randomized element (see targetSeq below) and is defined
            % relative to the hold-target; also jittering the hold-target
            % itself would make BOTH move every trial, compounding the
            % randomization in a way that was not asked for. So the
            % hold-target stays pinned to the true screen centre whenever
            % useTargetReach is on.
            if useTargetReach
                holdX = xCenter;
                holdY = yCenter;
            else
                holdX = xCenter + (rand() * 2 - 1) * centerJitterRange;
                holdY = yCenter + (rand() * 2 - 1) * centerJitterRange;
            end
            centerCircle = CenterRectOnPointd(circleSize, holdX, holdY);
            % Draw the next target direction only for a genuinely NEW trial
            % -- a retry (repeat_trial == 1 below) reuses the SAME
            % direction, matching CenterOutTask.m's convention that a
            % retry re-shows the same stimulus rather than a fresh draw.
            if useTargetReach
                for iDir = 1:nDir
                    a  = deg2rad(targetDirsDeg(iDir));
                    dx = cos(a) * targetRadius;  dy = -sin(a) * targetRadius;
                    Targets4Dir(iDir, :) = CenterRectOnPointd([0 0 targetRad targetRad], holdX, holdY) + [dx dy dx dy];
                end
                seqIdx = seqIdx + 1;
                if seqIdx > numel(targetSeq), seqIdx = 1; end
                currentTargetDir  = targetSeq(seqIdx);
                currentTargetRect = Targets4Dir(currentTargetDir, :);
            end
        else
            stimAttempt = stimAttempt + 1;
        end
        repeat_trial = 0;

        % --- Live status: where this trial sits in the whole session ------
        % Center-In has no blocks and no categories (every trial is the
        % same hold task), so unlike CenterOutTask there is nothing to
        % break down further, but the operator still needs the plain
        % "how far along are we" figure stated outright, rather than having
        % to compare two boxes on the console by eye.
        % Painted from the same helper the end-of-trial repaint uses, so the
        % two cannot describe the session differently.
        paintProgressStatus(orgParams.handles, trialIndex, stimAttempt, ...
            maxStimAttempts, good_trials, maxCorrectTrials);
        drawnow();

        nextEpoch = EP.ENTER_CENTER;
    end

    this_time = GetSecs();

    % --- Console: live elapsed-session-time readout, throttled to ~1/s ---
    % (every frame would mean hundreds of needless set()/redraws per second)
    % From the first hold, the same instant the end-of-session total counts
    % from, so the live box and the report cannot disagree.
    if ~isempty(sessionHoldT0) && this_time - lastSessionTimeUpdate >= 1
        set(orgParams.handles.textSessionTime, 'String', FormatElapsedTime(this_time - sessionHoldT0));
        lastSessionTimeUpdate = this_time;
    end

    % --- Read input device -> cursor position ---
    [x, y] = ReadCursorPosition(taskWindow, inputSource, joy, rz2, xCenter, yCenter, screenXpixels, screenYpixels, pointer_offset);
    % sampleTime: the instant THIS cursor sample was taken, and the only
    % clock the base trajectory rows below are stamped with, NOT this_time
    % (captured at the top of the iteration, before the once-a-second
    % console set() above and before the read itself). Same convention as
    % the oversampled rows further down and as CenterOutTask.m, so a row's
    % Time_ms means the same thing in every trajectory file this suite
    % writes. this_time stays as it is: the epoch state machine compares
    % against it, and moving it would shift real task timing, not just
    % relabel a logged sample.
    sampleTime = GetSecs();
    inCenterCircle = CheckInCircle(x, y, holdX, holdY, centerCircle(1), centerCircle(3));
    inTarget = useTargetReach && CheckInTargetCenterOut(x, y, currentTargetRect);
    cursorRect = [x - pointerRad, y - pointerRad, x + pointerRad, y + pointerRad];

    if useRZ2
        % 'rz2adc' is fed by JoystickRelayToTask.m's UDP stream (up to
        % ~7500 pkts/s from Computer 1; see SetupRZ2Joystick.m/
        % ReadRZ2Joystick.m). Every sample it delivered since the last
        % frame gets its OWN trajectory row here instead of just one row
        % per frame; the whole reason that relay exists is to preserve
        % the joystick's native sampling rate rather than cap it at the
        % screen's frame rate. The [x, y] ReadCursorPosition already read
        % above (for rendering/hit-testing) is the newest row of this
        % same batch, so it is not logged a second time.
        rz2Batch = TakeRZ2JoystickSamples(rz2.port);   % [time, vx, vy], oldest first
        nRz2 = max(size(rz2Batch, 1), 1);   % always >=1 row/frame, like every other input source
        if trajN + nRz2 > size(trajBuf, 1)
            trajBuf(end + max(trajChunk, nRz2), 6) = 0;
        end
        if isempty(rz2Batch)
            % No new UDP sample arrived this frame (rare, only if the
            % relay briefly stalls); log the cached last-known position
            % ReadCursorPosition just returned so trajN still advances
            % exactly once, same as every other input source.
            trajN = trajN + 1;
            trajBuf(trajN, :) = [trialIndex, (sampleTime - sessionT0) * 1000, x, y, nextEpoch, stimAttempt];
        else
            for bi = 1:size(rz2Batch, 1)
                trajN = trajN + 1;
                bx = xCenter + screenXpixels * rz2Batch(bi, 2) * rz2.scaleX;
                by = yCenter + rz2.offsetY + screenYpixels * rz2Batch(bi, 3) * rz2.scaleY;
                % max(...,0): rz2Batch(bi,1) is interpolated from
                % rz2.port.UserData.lastDrainTime (stamped when
                % SetupRZ2Joystick.m opened the socket, BEFORE sessionT0
                % exists), so the very first batch of the very first frame
                % can legitimately compute a time just before sessionT0;
                % clamp those rows to exactly 0 rather than letting the
                % trajectory's first few rz2adc samples read negative.
                rz2TimeMs = max((rz2Batch(bi, 1) - sessionT0) * 1000, 0);
                trajBuf(trajN, :) = [trialIndex, rz2TimeMs, bx, by, nextEpoch, stimAttempt];
            end
        end
    else
        trajN = trajN + 1;
        if trajN > size(trajBuf, 1)
            trajBuf(end + trajChunk, 6) = 0;
        end
        trajBuf(trajN, :) = [trialIndex, (sampleTime - sessionT0) * 1000, x, y, nextEpoch, stimAttempt];
    end

    % trigTime: the timestamp of the cursor sample the state machine below
    % actually acts on. inCenterCircle and inTarget are both computed from
    % THIS sample's x/y, so every epoch transition derived from them belongs
    % to this sample. Same convention, and same reasoning, as CenterOutTask.m
    % (which additionally keeps the row INDEX, because it re-tags rows for
    % its movement-only export; this engine has no MOVEMENT epoch and never
    % calls SaveMovementTrajectory.m, so the index has no use here).
    %
    % Captured here, before the render block, because that block invalidates
    % the obvious alternative: the oversample loop reassigns sampleTime, so
    % by the time the state machine runs it refers to the LAST extra read,
    % not to the sample that drove the decision.
    %
    % Read back out of the row rather than copied from sampleTime so that
    % all three write paths above agree: on the rz2adc path row trajN is the
    % newest sample of the drained batch and carries ReadRZ2Joystick.m's
    % interpolated estimate, which is NOT sampleTime.
    trigTime = sessionT0 + trajBuf(trajN, 2) / 1000;

    % --- Render ---
    if showCursor
        % Fixed colour while visible (TARGET_GO or TARGET_HOLD); the
        % gray-while-waiting/green-while-held convention is centre-circle
        % only (holdColor below); the peripheral target does not switch
        % colour on entry/hold.
        if useTargetReach && (nextEpoch == EP.TARGET_GO || nextEpoch == EP.TARGET_HOLD)
            Screen('FillOval', taskWindow, targetColor, currentTargetRect);
        end
        Screen('DrawLines', taskWindow, FixPoint, 4, white_c, [holdX holdY], 2);
        Screen('FrameOval', taskWindow, holdColor, centerCircle, [], 4, 4);
        Screen('FillOval', taskWindow, red_c, cursorRect);

        Screen('AsyncFlipBegin', taskWindow);
        % Skipped entirely for 'rz2adc': the trajBuf block above already
        % logged every UDP sample the relay delivered this frame, which is
        % strictly more resolution than polling ReadCursorPosition a few
        % more times here would add, doing both would just re-drain an
        % already-drained socket and log duplicate cached values.
        if moveOversample > 0 && ~useRZ2
            for oi = 1:moveOversample
                pause(moveOversampleDt);
                [xOver, yOver] = ReadCursorPosition(taskWindow, inputSource, joy, rz2, xCenter, yCenter, screenXpixels, screenYpixels, pointer_offset);
                sampleTime = GetSecs();   % same convention as the base row above: stamp at this sample's own read
                trajN = trajN + 1;
                if trajN > size(trajBuf, 1)
                    trajBuf(end + trajChunk, 6) = 0;
                end
                trajBuf(trajN, :) = [trialIndex, (sampleTime - sessionT0) * 1000, xOver, yOver, nextEpoch, stimAttempt];
            end
        end
        [~, stimOnsetTime] = Screen('AsyncFlipEnd', taskWindow);

        % Target onset = the instant the reach target actually became
        % VISIBLE, not the instant the state machine decided to show it. The
        % HOLD case below only raises awaitTargetOnset; the target is drawn
        % on the next frame (the render above draws it whenever nextEpoch is
        % TARGET_GO/TARGET_HOLD), and this is that frame's flip. Stamping at
        % decision time inflated ReachTime_s by up to a full frame (~16.7 ms
        % at 60 Hz), because the target was still one flip from the screen.
        %
        % StimulusOnsetTime (2nd output), not VBLTimestamp: PTB's estimate
        % of true perceptual onset. Same GetSecs clock as every trajectory
        % row, so this stays comparable with Time_ms. Mirrors
        % CenterOutTask.m's handling of its own target onset.
        %
        % Placed before the state machine on purpose: the frame that first
        % draws the target is also the frame EP.TARGET_GO first runs, so
        % t.targetOnset is already valid when TARGET_GO reads it.
        if awaitTargetOnset
            t.targetOnset    = stimOnsetTime;
            awaitTargetOnset = 0;
        end
    end

    % --- Console "Abort" button ---
    if isgraphics(h) && getappdata(h, 'stop')
        exitFlag = 1;
        abortedByOperator = true;
    end

    % --- Keyboard: pause / quit / manual reward ---
    [keyIsDown, keyCode] = SafeKbCheck(kbDevice, useKbQueue);
    if keyIsDown
        if keyCode(KEY_SPACE)
            pauseTask = 1;
        elseif keyCode(KEY_ESCAPE)
            exitFlag = 1;
            abortedByOperator = true;
        elseif keyCode(KEY_R) && manualRewardTime < this_time - 0.2
            rewardSecManual    = rewardSecManual + Rewards(manualReward, 1, uSynapse);
            rewardPulsesManual = rewardPulsesManual + 1;
            manualRewardTime = this_time;
        end
    end

    % --- State machine ---
    switch nextEpoch
        case EP.ENTER_CENTER
            if inCenterCircle
                if setOnce_Hold
                    Screen('DrawLines', taskWindow, FixPoint, 4, white_c, [holdX holdY], 2);
                    Screen('FrameOval', taskWindow, waitColor, centerCircle, [], 4, 4);
                    Screen('Flip', taskWindow);
                    setOnce_Hold = 0;
                end
                nextEpoch = EP.HOLD_START;
            end

        case EP.HOLD_START
            if inCenterCircle
                total_trials = total_trials + 1;
                % Session clock starts at the FIRST hold, never reset
                % afterwards (see sessionHoldT0 above).
                if isempty(sessionHoldT0)
                    sessionHoldT0 = trigTime;
                end
                % trigTime, not GetSecs(): entry was detected from THIS
                % frame's sample. This is the shared start of the logged
                % HoldAchieved_s (whose end is t.holdSatisfied on a completed
                % hold, or t.leaveCenter on an early exit) and the end of
                % TimeToEnter_s, so it has to be the instant the cursor was
                % MEASURED inside, not the instant the state machine got
                % round to noticing. Note this also anchors the holdTime
                % window itself a fraction of a millisecond later than
                % before (trigTime is read after this_time within the same
                % frame), far below the jitter already in holdTime.
                t.centerHold = trigTime;
                nextEpoch = EP.HOLD;
            end

        case EP.HOLD
            holdColor = green_c;
            if this_time > t.centerHold + holdTime && inCenterCircle
                % The instant the hold requirement was MET, measured from
                % the sample that met it; the other end of HoldAchieved_s
                % on trials that got this far. Always >= holdTime, by the
                % frame of overshoot between the requirement expiring and
                % the next sample confirming the cursor is still inside.
                % Stamped here rather than inferred in BOOKKEEP because
                % only this branch knows the hold actually completed:
                % good_trial does not, since in reach mode a trial can
                % satisfy the hold and still fail the reach afterwards.
                t.holdSatisfied = trigTime;
                if useTargetReach
                    awaitTargetOnset = 1;   % stamped by the next flip, not here
                    totalPerDir(currentTargetDir) = totalPerDir(currentTargetDir) + 1;
                    nextEpoch = EP.TARGET_GO;
                else
                    t.reward = GetSecs();
                    nextEpoch = EP.REWARD;
                end
            elseif ~inCenterCircle
                % trigTime for the same reason as t.centerHold above: this
                % is the other end of HoldAchieved_s.
                t.leaveCenter = trigTime;
                error_type = 1;
                nextEpoch = EP.ERROR_FB;
            end

        case EP.TARGET_GO
            % Safety net only: t.targetOnset is normally already stamped by
            % the flip in the render block above, on this very frame. It can
            % only still be pending if that flip did not run at all (i.e.
            % showCursor was off), in which case anchor on this frame's
            % sample rather than leave targetDuration measured from 0, which
            % would fire the reach timeout instantly.
            if awaitTargetOnset
                t.targetOnset    = trigTime;
                awaitTargetOnset = 0;
            end
            if inTarget
                % trigTime: inTarget was hit-tested against THIS frame's
                % sample. Together with the flip-stamped t.targetOnset
                % above, this makes ReachTime_s span "target visible ->
                % cursor measured inside the target", with no state-machine
                % latency at either end.
                t.targetHit = trigTime;
                nextEpoch = EP.TARGET_HOLD;
            elseif this_time > t.targetOnset + targetDuration
                error_type = 2;
                nextEpoch = EP.ERROR_FB;
            end

        case EP.TARGET_HOLD
            if this_time > t.targetHit + targetHoldTime && inTarget
                reachTimePerDir{currentTargetDir}(end + 1) = t.targetHit - t.targetOnset;
                correctPerDir(currentTargetDir) = correctPerDir(currentTargetDir) + 1;
                t.reward = GetSecs();
                nextEpoch = EP.REWARD;
            elseif ~inTarget
                error_type = 3;
                nextEpoch = EP.ERROR_FB;
            end

        case EP.REWARD
            t.reward = GetSecs();
            rewardSecTask    = rewardSecTask + Rewards(rewTime, 1, uSynapse);
            rewardPulsesTask = rewardPulsesTask + 1;
            good_trials = good_trials + 1;
            good_trial  = 1;
            nextEpoch = EP.SUCCESS_FB;

        case EP.SUCCESS_FB
            holdColor = green_c;
            if this_time > t.reward + successFeed
                showCursor = 0;
                BlankScreen(taskWindow, black_c);
                t.blank = GetSecs();
                nextEpoch = EP.ITI;
            end

        case EP.ERROR_FB
            % Black/white screen flash on EVERY error, same 0.1 s
            % alternation CenterOutTask.m uses (see its EP.ERROR_FB).
            % It flashes on all three error types here rather than on one
            % of them, because unlike Center-Out this task has no
            % "picked the wrong thing" error to reserve it for: leaving the
            % centre early, timing out on the reach and leaving the target
            % early are all the same thing to the subject (the trial was
            % failed) and in pure hold mode (no reach) the early exit is
            % the ONLY error there is, so a flash reserved for anything
            % else would never fire.
            good_trial = 0;  repeat_trial = stimAttempt < maxStimAttempts;
            if ~t.marker
                t.marker = GetSecs();
                switch error_type
                    case 1
                        error_early_exit = error_early_exit + 1;
                    case 2
                        error_reach_timeout = error_reach_timeout + 1;
                        errReachTimeoutPerDir(currentTargetDir) = errReachTimeoutPerDir(currentTargetDir) + 1;
                    case 3
                        error_target_exit = error_target_exit + 1;
                        errTargetExitPerDir(currentTargetDir) = errTargetExitPerDir(currentTargetDir) + 1;
                end
            end
            showCursor = 0;
            % Alternate white/black every errorFlashPeriod seconds for as
            % long as the error feedback lasts, so the flash looks the same
            % whatever frame rate this rig runs at.
            %
            % Clamped at 0 because t.marker is stamped with GetSecs() a few
            % microseconds AFTER this_time was captured at the top of this
            % frame: on the entry frame the raw difference is slightly
            % negative, which floor()/mod() would turn into a black first
            % frame. The clamp makes the flash start on white every time.
            flashElapsed = max(0, this_time - t.marker);
            if mod(floor(flashElapsed / errorFlashPeriod), 2) == 0
                Screen('FillRect', taskWindow, white_c);
            else
                Screen('FillRect', taskWindow, black_c);
            end
            Screen('Flip', taskWindow);
            if this_time > t.marker + errorFeed
                BlankScreen(taskWindow, black_c);   % always end on black, mid-flash or not
                t.blank = GetSecs();
                t.marker = 0;
                nextEpoch = EP.ITI;
            end

        case EP.ITI
            BlankScreen(taskWindow, black_c);
            thisITI = ITI_error;
            if good_trial == 1, thisITI = current_ITI; end
            if this_time > t.blank + thisITI
                BlankScreen(taskWindow, black_c);
                nextEpoch = EP.BOOKKEEP;
            end

        case EP.BOOKKEEP
            set(orgParams.handles.edit91, 'String', num2str(good_trials));
            set(orgParams.handles.edit92, 'String', num2str(good_trials / total_trials * 100));

            timeToEnter = t.centerHold - t.trialStart;
            % HoldAchieved_s is a MEASUREMENT on every branch: both ends are
            % sample timestamps (t.centerHold, t.holdSatisfied and
            % t.leaveCenter all come from trigTime), so it is always the
            % hold the subject actually produced, on the same clock as
            % trajectory_*.csv's Time_ms.
            %
            % Deliberately NOT the nominal holdTime on correct trials: that
            % would mix the requested hold into a column named "achieved"
            % and hide the real overshoot, and it would score 0 for a
            % reach-mode trial that held correctly and then missed the
            % target; t.leaveCenter is only set on an early exit from the
            % centre, so neither branch would match. t.holdSatisfied covers
            % both: it is set exactly when the hold completed, regardless of
            % what happened afterwards.
            %
            % POOLING WARNING. Older session files carry the nominal value
            % in this column on correct trials, so HoldAchieved_s is not
            % comparable across the whole archive: those files read exactly
            % HoldTimeRequired_s here, current ones read slightly more (the
            % frame of overshoot). Check the session date before pooling.
            % HoldTimeRequired_s is unaffected and always records what was
            % asked for.
            if t.holdSatisfied > 0
                holdAchieved = t.holdSatisfied - t.centerHold;
            elseif t.leaveCenter > 0
                holdAchieved = t.leaveCenter - t.centerHold;
            else
                holdAchieved = 0;
            end
            if total_trials > numel(holdAchievedLog)
                % Grow buffer; fill the new region with NaN explicitly:
                % arr(end+N) = nan only sets the LAST new element to NaN,
                % the gap in between defaults to 0, which would corrupt the
                % isnan() filter in printCenterInSummary below.
                oldLen = numel(holdAchievedLog);
                holdAchievedLog(oldLen + 1 : oldLen + max(maxCorrectTrials, 10)) = nan;
            end
            holdAchievedLog(total_trials) = holdAchieved;

            targetDirForLog = 0;
            reachTimeForLog = NaN;
            if useTargetReach
                targetDirForLog = currentTargetDir;
                if t.targetHit > 0
                    reachTimeForLog = t.targetHit - t.targetOnset;
                end
            end

            fid_log = fopen(trialLogFile, 'a');
            fprintf(fid_log, '%s,%d,%d,%.4f,%.4f,%.4f,%d,%d,%d,%d,%.4f,%.2f,%.2f\n', ...
                sessionDate, trialIndex, stimAttempt, holdTime, timeToEnter, holdAchieved, ...
                good_trial, error_type, prevTrialCorrect, targetDirForLog, reachTimeForLog, holdX, holdY);
            fclose(fid_log);
            prevTrialCorrect = good_trial;

            % Repaint with the outcome of the trial that just CLOSED, not
            % only at the start of the next one; the last trial of a
            % session never gets a next one, so painting at trial start
            % alone would leave the counter one trial short of 0 and the
            % console would appear to jump straight to "Task done" (same
            % reasoning as CenterOutTask.m).
            paintProgressStatus(orgParams.handles, trialIndex, stimAttempt, ...
                maxStimAttempts, good_trials, maxCorrectTrials);

            % A failed hold costs the subject nothing but time: only rewarded
            % holds count towards the quota, so the session keeps going until
            % the criterion is genuinely met (see the QUICK-EDIT block above).
            if good_trials >= maxCorrectTrials
                exitFlag = 1;
            end

            setOnce_Trial = 1;
            pause(flipInterval);
            nextEpoch = EP.ENTER_CENTER;
    end

    % --- Pause handling ---
    % PauseLoop blocks until the operator resumes. Its return value is a
    % sentinel, NOT an epoch of this engine, so it is deliberately
    % DISCARDED rather than assigned to nextEpoch, exactly as
    % CenterOutTask.m does. Assigning it would set nextEpoch to a value no
    % case below matches, and since nothing else in the loop writes
    % nextEpoch, the state machine would sit in that unmatched state
    % forever: the task would appear to resume, redraw every frame, and
    % never advance again. Discarding it resumes at whichever epoch was
    % already active before the pause, which is what the operator expects.
    if pauseTask == 1
        PauseLoop(taskWindow, black_c, orgParams, kbDevice, useKbQueue, KEY_SPACE);
        pauseTask = 0;
        % A pause blocks this loop for an unbounded time while the relay
        % keeps streaming; same backlog problem as session start, so drop
        % it the same way.
        if useRZ2
            FlushRZ2Joystick(rz2);
        end
    end
end % trial loop

% Stop the session clock here: everything below is teardown, not time the
% subject spent on the task. Empty when no trial ever reached the hold.
if isempty(sessionHoldT0)
    sessionSeconds = [];
else
    sessionSeconds = GetSecs() - sessionHoldT0;
    % Final value into the console's live box, which is throttled to ~1/s
    % and would otherwise disagree with the total the report prints.
    set(orgParams.handles.textSessionTime, 'String', FormatElapsedTime(sessionSeconds));
end

% Release the fullscreen Psychtoolbox window immediately once the quota is
% met (or the session ends early), same rationale as CenterOutTask.m.
% ForceCloseScreen is idempotent; harmless no-op if CloseTask() below or the
% onCleanup-registered call at the top already ran.
ForceCloseScreen(taskWindow);

% =========================================================================
% TEARDOWN: aggregate, save, report
% =========================================================================
if total_trials > 0, perf = good_trials / total_trials * 100; else, perf = 0; end

if total_trials == 0
    % Aborted before any trial ran. If the recording-link gate was declined,
    % keep that message on screen (more informative than a generic one);
    % abortedByOperator is still false in that case, since it's set only by
    % the in-loop Abort/ESC handlers above, not the pre-loop gate.
    fprintf('No trials run; no session files written.\n');
    % Water can still have been delivered with no completed trial; the
    % operator's 'r' key works from the very first frame (same reasoning as
    % CenterOutTask.m's copy of this guard).
    if rewardPulsesTask + rewardPulsesManual > 0
        SessionReport.reward(rewardPulsesTask, rewardSecTask, ...
            rewardPulsesManual, rewardSecManual, rewardMlPerSec);
    end
    if abortedByOperator
        set(orgParams.handles.text77, 'String', 'Task stopped');
        set(orgParams.handles.text77, 'ForegroundColor', 'red');
    end
else
try
    S.good_trials = good_trials;  S.total_trials = total_trials;
    % Session duration from the first hold (see sessionHoldT0). Empty when
    % no trial ever reached the hold, so "never started" stays
    % distinguishable from "instantaneous". Same field CenterOutTask.m saves.
    S.sessionSeconds = sessionSeconds;
    S.error_early_exit = error_early_exit;
    % Water delivered; valve-open seconds plus the calibration used, so a
    % session can be converted to mL later even if the rig was calibrated
    % (or recalibrated) after the fact. Same fields CenterOutTask.m saves.
    S.rewardPulsesTask   = rewardPulsesTask;    S.rewardSecTask   = rewardSecTask;
    S.rewardPulsesManual = rewardPulsesManual;  S.rewardSecManual = rewardSecManual;
    S.rewardMlPerSec     = rewardMlPerSec;
    S.useTargetReach = useTargetReach;
    if useTargetReach
        S.targetWeights          = targetWeights;
        S.targetDirsDeg          = targetDirsDeg;
        S.totalPerDir            = totalPerDir;
        S.correctPerDir          = correctPerDir;
        S.errReachTimeoutPerDir  = errReachTimeoutPerDir;
        S.errTargetExitPerDir    = errTargetExitPerDir;
        S.reachTimePerDir        = reachTimePerDir;
        S.error_reach_timeout    = error_reach_timeout;
        S.error_target_exit      = error_target_exit;
    end
    save(fullfile(outDir, ['perf_centerIn_' d '.mat']), '-struct', 'S');
    fprintf('\nSession data saved to:  %s\n', fullfile(outDir, ['perf_centerIn_' d '.mat']));

    % Exported via the shared SaveTrajectory helper (see SaveTrajectory.m),
    % also used by CenterOutTask.m, so the export/crash-recovery logic
    % exists once rather than once per engine. 'centerIn_<d>' as the run tag
    % is what produces the trajectory_centerIn_*.{mat,csv} filenames this
    % engine's sessions are archived under. No movement-only cut is written (that is
    % SaveMovementTrajectory.m's job, and this engine has no MOVEMENT epoch
    % to filter on).
    SaveTrajectory(trajBuf, trajN, outDir, ['centerIn_' d], sessionDate);
catch ME_save
    fprintf('WARNING: error during matrix computation or save: %s\n', ME_save.message);
end

try
    printCenterInSummary(total_trials, good_trials, perf, error_early_exit, ...
        holdAchievedLog(1:total_trials));
    if useTargetReach
        printCenterInDirMatrix(targetDirsDeg, totalPerDir, correctPerDir, ...
            errReachTimeoutPerDir, errTargetExitPerDir, reachTimePerDir);
    end
    % Water delivered. Shared with CenterOutTask.m via SessionReport rather
    % than reprinted here: this engine has the same two reward paths (the
    % automatic pulse per rewarded hold and the operator's 'r' key), so the
    % two summaries stay identical without a second copy of the formatting.
    SessionReport.reward(rewardPulsesTask, rewardSecTask, ...
        rewardPulsesManual, rewardSecManual, rewardMlPerSec);
    % How long that took, measured the same way in both engines.
    SessionReport.duration(sessionSeconds, total_trials);
catch ME_print
    fprintf('WARNING: error during console printout: %s\n', ME_print.message);
end

if abortedByOperator
    set(orgParams.handles.text77, 'String', 'Task stopped');
else
    set(orgParams.handles.text77, 'String', 'Task done');
end
set(orgParams.handles.text77, 'ForegroundColor', 'red');
end

% Printed last, while the diary is still on, so the file ends by naming
% itself (same reasoning as CenterOutTask.m).
fprintf('\nSession report saved to: %s\n', sessionLogFile);

try, CloseTask; catch, end
if useKbQueue, try, KbQueueStop(kbDevice); KbQueueRelease(kbDevice); catch, end, end
if ~isempty(uSynapse)
    SetRZ2RelayEnable(false, uSynapse);   % stop Computer 1's relay along with this session
    fclose(uSynapse);
end
CleanupRZ2Joystick(rz2);   % release port 8831, or the next rz2adc run fails to rebind it
% Audible end-of-session alert, LAST, same reasoning and same tones as
% CenterOutTask.m (see AlertTaskDone.m).
if abortedByOperator
    AlertTaskDone('stopped', OrgGet(orgParams, 'alertOnFinish', true));
else
    AlertTaskDone('done', OrgGet(orgParams, 'alertOnFinish', true));
end
close(orgParams.handles.dlgTrainingMain);

catch ME
    disp(ME.identifier);  disp(ME.message);
    if ~isempty(ME.stack), disp(ME.stack(1)); end
    if numel(ME.stack) > 1, disp(ME.stack(2)); end
    % Salvage the in-memory trajectory buffer on a hard crash, same
    % rationale as CenterOutTask.m's top-level catch block.
    if exist('trajBuf', 'var') && exist('trajN', 'var') && trajN > 0 ...
            && exist('outDir', 'var') && exist('d', 'var')
        try
            if exist('sessionDate', 'var'), dateForLog = sessionDate; else, dateForLog = datestr(now, 'dd-mm-yyyy'); end
            SaveTrajectory(trajBuf, trajN, outDir, ['centerIn_' d], dateForLog);
            fprintf('Trajectory salvaged after crash: %d samples\n', trajN);
        catch
            fprintf('WARNING: could not salvage trajectory after crash.\n');
        end
    end
    try, CloseTask; catch, end
    if exist('useKbQueue', 'var') && useKbQueue
        try, KbQueueStop(kbDevice); KbQueueRelease(kbDevice); catch, end
    end
    if exist('uSynapse', 'var') && ~isempty(uSynapse)
        try, SetRZ2RelayEnable(false, uSynapse); catch, end
        fclose(uSynapse);
    end
    if exist('rz2', 'var'), try, CleanupRZ2Joystick(rz2); catch, end, end
    AlertTaskDone('error', OrgGet(orgParams, 'alertOnFinish', true));   % distinct "it crashed" tone
    try, close(orgParams.handles.dlgTrainingMain); catch, end
end
end % CenterInTask


% =========================================================================
% LOCAL HELPER FUNCTIONS
% =========================================================================
function t = initTimes()
% Named time markers for one trial.
t = struct('trialStart', 0, 'centerHold', 0, 'holdSatisfied', 0, 'leaveCenter', 0, ...
        'reward', 0, 'blank', 0, 'marker', 0, 'targetOnset', 0, 'targetHit', 0);
end

function printCenterInSummary(total_trials, good_trials, perf, error_early_exit, holdAchieved)
% PRINTCENTERINSUMMARY  End-of-session report: no blocks/categories to
% break out (unlike CenterOutTask.m's 2-level report); every trial
% is the same task, so one flat summary is all there is.
fprintf('\n======= CENTER-IN SESSION SUMMARY ==========\n');
fprintf('Total Trials:        %d\n', total_trials);
fprintf('Good Trials:         %d\n', good_trials);
fprintf('Overall Performance: %.2f%%\n', perf);
fprintf('Early Exit Errors:   %d (%.2f%%)\n', error_early_exit, error_early_exit/total_trials*100);
good = holdAchieved(~isnan(holdAchieved));
if ~isempty(good)
    fprintf('\nHold duration achieved (s): mean %.3f, median %.3f, min %.3f, max %.3f\n', ...
        mean(good), median(good), min(good), max(good));
end
fprintf('=============================================\n\n');
end

function paintProgressStatus(handles, trialIndex, stimAttempt, maxStimAttempts, ...
        goodTrials, maxCorrectTrials)
% Console Status line. Called twice per trial (as the trial opens and as
% it closes) so the wording lives here instead of at either call site.
%
% Center-In has no blocks and no categories (every trial is the same hold
% task), so unlike CenterOutTask there is nothing to break down further,
% but the operator still needs the plain "how far along are we" figure the
% console could previously only be read for by comparing two boxes by eye.
%
% Counts rewarded holds only, which is exactly what the stop condition
% counts, so the "(N left)" matches when the session will really end. The
% trial number beside it is what shows the cost of getting there.
if stimAttempt > 1
    retryStr = sprintf(' (attempt %d/%d)', stimAttempt, maxStimAttempts);
else
    retryStr = '';
end
set(handles.text77, 'String', sprintf( ...
    'Task is running -- trial %d%s -- %d/%d correct (%d left)', ...
    trialIndex, retryStr, goodTrials, maxCorrectTrials, ...
    max(0, maxCorrectTrials - goodTrials)));
set(handles.text77, 'ForegroundColor', 'blue');
end

function printCenterInDirMatrix(dirsDeg, totalPerDir, correctPerDir, ...
                                errReachTimeoutPerDir, errTargetExitPerDir, reachTimePerDir)
% PRINTCENTERINDIRMATRIX  Reach-mode per-direction performance matrix.
%
%   Unlike the reference training script this was ported from, there is no
%   %_shown vs %_assigned distinction here: a direction is only ever counted
%   once its target has actually appeared (drawn from targetSeq right when
%   EP.HOLD hands off to EP.TARGET_GO), so there is no "assigned but never
%   shown" case to separate out; an early exit during the CENTRE hold
%   happens before any direction is drawn at all, and is already excluded
%   from these tallies entirely (it shows up only in error_early_exit,
%   printed separately by printCenterInSummary above).
nDir = numel(dirsDeg);
names = {'Right', 'Up', 'Left', 'Down'};
if nDir ~= numel(names)
    names = arrayfun(@(d) sprintf('%ddeg', d), dirsDeg, 'UniformOutput', false);
end

fprintf('\n======= CENTER-IN REACH: PER-DIRECTION MATRIX =======\n');
fprintf('%-6s  %6s  %7s  %8s  %8s  %8s  %10s\n', ...
    'Dir', 'N', 'Correct', '%Correct', 'Timeout', 'TgtExit', 'ReachT(ms)');
for i = 1:nDir
    if totalPerDir(i) > 0
        pct = 100 * correctPerDir(i) / totalPerDir(i);
    else
        pct = NaN;
    end
    if isempty(reachTimePerDir{i})
        meanReach = NaN;
    else
        meanReach = mean(reachTimePerDir{i}) * 1000;
    end
    fprintf('%-6s  %6d  %7d  %7.1f%%  %8d  %8d  %10.1f\n', ...
        names{i}, totalPerDir(i), correctPerDir(i), pct, ...
        errReachTimeoutPerDir(i), errTargetExitPerDir(i), meanReach);
end
fprintf('======================================================\n\n');
end