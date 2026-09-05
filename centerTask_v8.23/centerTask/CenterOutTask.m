function CenterOutTask(orgParams)
% CENTEROUTTASKV3  Center-out length-categorization paradigm.
%
%   This version trims per-frame overhead in
%   the real-time loop and tidies the code:
%     * Keyboard codes are resolved once (no per-frame KbName string lookups).
%     * The three cue dots are precomputed and drawn in a single vectorized
%       FillOval instead of three calls every frame.
%     * The length-bar rectangle is computed when the bar turns on, not on
%       every frame it is visible.
%     * Constant rectangles (scaled centre cue) are precomputed.
%
%   The subject holds a cursor (joystick or mouse, orgParams.inputSource) in
%   a central window until a horizontal "length bar" appears (Short/Mid/Long,
%   mapped to Orange/Green/Blue). After a cue, 2 or 3 coloured targets
%   (orgParams.sessionMode) appear in that many of four cardinal directions;
%   the subject must acquire the target whose colour matches the bar's
%   length group. Correct acquisitions are rewarded; errors are classified
%   as "early exit" or "wrong target".
%
%   TRAINING PHASES (orgParams.trainingPhase, console "Training phase").
%   Two colour-matching drills that precede the categorization task proper.
%   The bar is drawn in its own category colour, and phase 1 shows a single
%   target in that same colour (nothing to choose between), phase 2 adds one
%   foil target in a different category colour, picking the foil is an
%   ordinary wrong-target error and gets the usual error flash. Both reuse
%   this file's state machine, retry/requeue logic and logging untouched;
%   see the "Training phases" block in SETUP. Pair with
%   orgParams.barLengthSubset (console "Bar lengths (subset)", see
%   ParseBarSubset.m) to drill one bar length (hence one colour) before
%   opening the selection up.
%
%   ERROR TAXONOMY (ErrorType column in trial_data_*.csv):
%     0  correct
%     1  early exit / timeout -- never reached the correct target (left the
%        centre too early, never departed in time, never arrived in time, or
%        broke the hold with orgParams.strictHold on). Never flashes.
%     2  wrong target -- entered a target of the wrong category. This IS the
%        trial's response, so it is the only outcome the confusion matrix
%        counts off-diagonal.
%     3  hold-break -- reached the CORRECT target and left it before
%        completing minTarHoldTime. Only ever produced in pre-training with
%        orgParams.trainingErrorFlash on (console "Training error flash");
%        see strictTraining in SETUP. Split out from type 1 because it says
%        nothing about whether the subject read the colour rule -- it is a
%        motor/patience failure on a trial the subject had already got right.
%
%   INPUT  orgParams : struct of GUI handles and run parameters (from
%          CenterConsole.m's runTask, or built by hand by a
%          caller like OffrigPlay.m).
%   Local helpers (only the ones welded to this file's state machine, which
%   would gain nothing from their own file): initTimes, earlyExit,
%   placeTargets, layoutForTrial.
%
%   Everything else lives in its own file in centerTask/, so it can be
%   unit-tested without Psychtoolbox and reused by the other engines:
%     Setup/teardown plumbing shared with CenterInTask.m: OrgGet,
%       BlankScreen, ForceCloseScreen, ConfirmRecordingLink, HideCursorSafe,
%       SetupKeyboardDevice, SafeKbCheck, SetupJoystick, SetupSynapseUDP,
%       InitTaskHandles, ReadCursorPosition, PauseLoop,
%       SaveMovementTrajectory (this engine writes the movement-only
%       trajectory export; the full multi-epoch SaveTrajectory.m is
%       CenterInTask.m's, see the export block below the trial loop)
%     Trial construction: ParseBarSubset (operator's bar-length
%       selection -> stimulus-set indices), BuildTrialSequence (pseudorandom sequence),
%       DrawTrialLayout (colour/position draw) or, when
%       orgParams.fixedTargetLayout is true, FixedTargetLayout (fixed
%       per-category direction, no shuffle), dispatched by the local
%       layoutForTrial helper and fed by CategoriesForTrial (which
%       categories a trial offers, incl. the training phases),
%       AssignTargets (layout -> drawable targets),
%       CueRectsFor (cue-dot geometry)
%     Shared tables/enums: TaskEpoch (epoch enumeration), ColorCategoryMap
%       (colour<->category)
%     Analysis: NormInvNoTB (toolbox-free normal quantile). NOTE this engine
%       computes no per-trial kinematics and writes no
%       trial_kinematics_*.csv. The trajectory exports carry every epoch and
%       sample, so speeds and accelerations are derived offline in the
%       Python EDA notebook instead.
%     Reporting: SessionReport (classdef; .blocks, .session, .confusion,
%       .signalDetection)
if nargin < 1 || isempty(orgParams), orgParams = struct(); end

% ===========================================================================
% Session stop condition, orgParams is the single source of truth (see
% ConfigOrgParams.m for the full default struct a caller can start from);
% there is no separate hardcoded pair of lines to remember to keep in sync
% with an override anymore, just the OrgGet(orgParams, field, default)
% fallback the rest of this SETUP section already uses everywhere else.
% ===========================================================================
%   The quota is per (bar length, target position) combination (numLengths
%   x 4 positions independent counters (good_trials_lenpos)) not per
%   length alone, so no single length x position pairing is left
%   under-sampled. numLengths is 12 for the default full12 stimulus set (48
%   combinations), or 3 for either reduced set (prototypes3 or extremes3
% ) which give 12 combinations each. See orgParams.stimulusSet below.
%   orgParams.stopMode = 'correctTrials' (default); minPerLength (below,
%              in Trial count) comes directly from orgParams.maxCorrectTrials:
%              correct trials needed per (length, position) combo.
%   orgParams.stopMode = 'blocks'       -- minPerLength is derived from
%              orgParams.numBlocks instead: one block (every length x 4
%              positions) gives each combination exactly 1 scheduled
%              opportunity, so minPerLength = numBlocks.
%   orgParams.quotaByPresentations = true, the SAME number, but filled by
%              every resolved trial instead of only by correct ones. An
%              error then costs its combination's slot rather than leaving
%              it owed, so the session is exactly plannedTrials trials long
%              whatever the subject does, and performance is the percentage
%              correct over that fixed set. Default false (the monkey
%              design). The console does not expose this on its own: it
%              follows the Retries checkbox (= ~useRetries), since a quota
%              of correct trials and the correction procedure are the same
%              intent. See ConfigOrgParams.m and quota_lenpos below.
%   See the "minPerLength" block further down for where these resolve. Note:
%   a combination that succeeds on its very first, un-reshuffled attempt
%   credits minPerLength directly. Only an ambiguous outcome, succeeded
%   only after a reshuffled retry, or exhausted every attempt without
%   succeeding at all, spawns one extra, GUARANTEED un-reshuffled
%   verification repeat (see isRequeuedSlot and EP.REWARD/EP.ERROR_FB
%   below), and credits minPerLength from THAT repeat's outcome instead.
%   Total session length therefore grows only with the error/retry rate,
%   not automatically to double the scheduled-opportunity count. EXCEPTION:
%   if that guaranteed repeat itself exhausts its attempts through early
%   exits (never through a wrong-target pick), it is not accepted as final
% ; another clean repeat is chained on instead, indefinitely, since an
%   early exit never counted as a genuine attempt at the combination. Only
%   a wrong-target exhaustion closes the combination out.

% --- Named epoch (state) constants ---------------------------------------
% Backed by TaskEpoch (see TaskEpoch.m), an ordered enumeration, instead of
% the old bare floats (EP.CUE=4.5, EP.STIM_DELAY=13/14 out of numeric
% order); every EP.xxx below and every switch/case/== comparison further
% down keeps working exactly as before, just against a real enum value
% instead of a magic number nobody can guess the meaning of at a glance.
EP.ENTER_CENTER  = TaskEpoch.ENTER_CENTER;  % wait for cursor to reach the centre
EP.HOLD_START    = TaskEpoch.HOLD_START;    % count the attempt, start the hold timer
EP.HOLD          = TaskEpoch.HOLD;          % hold inside centre, then show the bar
EP.BAR           = TaskEpoch.BAR;           % bar visible, then (optional stim->rule delay) the cue
EP.STIM_DELAY    = TaskEpoch.STIM_DELAY;    % optional working-memory delay between bar and cue
EP.CUE           = TaskEpoch.CUE;           % selection cue visible, then place targets
EP.CUE_DELAY     = TaskEpoch.CUE_DELAY;     % optional delay between cue and targets
EP.DECISION_TIME      = TaskEpoch.DECISION_TIME;      % wait for cursor to leave the centre
EP.MOVEMENT      = TaskEpoch.MOVEMENT;      % wait for cursor to reach a target
EP.TARGET_HOLD   = TaskEpoch.TARGET_HOLD;   % brief hold inside the correct target
EP.REWARD        = TaskEpoch.REWARD;        % deliver reward
EP.SUCCESS_FB    = TaskEpoch.SUCCESS_FB;    % success feedback
EP.ERROR_FB      = TaskEpoch.ERROR_FB;      % error feedback (flash on wrong target)
EP.ITI           = TaskEpoch.ITI;           % inter-trial interval
EP.BOOKKEEP      = TaskEpoch.BOOKKEEP;      % update GUI, log the trial, arm the next one

% Epoch set the movement-only trajectory export covers (used ONLY by
% SaveMovementTrajectory.m below). DECISION_TIME + MOVEMENT + TARGET_HOLD,
% so trajectory_movement_<runTag>.csv spans the whole response: the
% decision/wait inside the centre window, the reach out to the target, and
% the settle/hold once it arrives. Was called kinematicsEpochs back when a
% MATLAB-side engine differentiated exactly these rows; that engine has been
% removed, so the name now says what the list actually still does.
%
% WORTH KNOWING for anyone deriving speeds from that export offline:
% DECISION_TIME is mostly the subject sitting almost-still inside the centre
% window deciding when to depart (up to maxDecisionTime), not moving. A mean
% speed taken over the whole file is therefore NOT a pure "reach speed" --
% it also depends on how long the subject took to leave the centre, which is
% decision time, not movement time. Filter to Epoch == MOVEMENT (7) if a
% pure reach figure is what you want; the Epoch column is written on every
% row precisely so that cut can be made after the fact.
%
% Placed here (right after EP, before the try block) rather than deeper in
% SETUP so it is defined whenever EP is, including on the crash-recovery
% salvage path further down.
movementExportEpochs = [EP.DECISION_TIME.Value, EP.MOVEMENT.Value, EP.TARGET_HOLD.Value];

% --- Network endpoints (reward / event markers over UDP to Synapse) ------
remoteHost = OrgGet(orgParams, 'remoteSynapseHost', '172.24.60.152');
localHost  = OrgGet(orgParams, 'localMachineHost',  '172.24.60.146');

exitFlag = 0;
Screen('Preference', 'SkipSyncTests', 1);

try
% =========================================================================
% SETUP
% =========================================================================
% Status/GUI handles: auto-create a minimal status figure if the caller
% didn't pass one (e.g. calling CenterOutTask or CenterOutTask([])
% directly, without going through CenterConsole.m). Same fields
% OffrigPlay.m otherwise has to mock by hand; see InitTaskHandles.m.
% textBreakdown (the live per-block/per-category box) is the one OPTIONAL
% field: every write to it is guarded with isfield, so a hand-built handles
% struct that predates it still runs, just without the breakdown.
if ~isfield(orgParams, 'handles') || isempty(orgParams.handles)
    orgParams.handles = InitTaskHandles('CenterOutTask');
end

d = datestr(now, 'dd-mmm-yyyy_HH-MM'); % Kept just for compability with older versions that used the date in filenames.
% A caller (e.g. the console GUI) can pin this to a fixed tag instead, so
% every output file from one run (trial data, trajectory, perf, and the
% console's own params snapshot) shares the same name for traceability
% from input parameters to output files.
if isfield(orgParams, 'runTag') && ~isempty(orgParams.runTag)
    d = orgParams.runTag;
end
sessionDate = datestr(now, 'dd-mm-yyyy');   % logged per-row in the trial CSV

% --- Output folder: outputs/<yyyy-mm>/<yyyy-mm-dd>/<runTag>/ --------------
% Auto-created; keeps results out of the code folder, grouped by month, then
% by session day, then by SESSION (each run gets its own folder named by the
% runTag, which includes the start hour -- e.g.
% outputs/2026-06/2026-06-14/sess01_14-Jun-2026_09-31/). Anchored to the
% current working directory. mkdir creates every intermediate folder. The
% day/hour are taken from the session start, so a run that crosses midnight
% stays in the folder it began in. The session folder is the shared runTag
% `d`, so the task, the console's params snapshot, and every output file of
% one run all land together (the console builds outDir the same way).
outMonth = datestr(now, 'yyyy-mm');
outDay   = datestr(now, 'yyyy-mm-dd');
outDir   = fullfile('outputs', outMonth, outDay, d);
if ~exist(outDir, 'dir'), mkdir(outDir); end

% --- Console transcript -> session_report_<runTag>.txt --------------------
% Started here, as early as the output folder exists, so the .txt captures
% the WHOLE run: the session budget block, the bar-subset/training-phase
% notices, every requeue message, and the full end-of-session report. Kept
% alive by logCleanup until this function returns, including via the
% catch block below, so a crashed session still leaves its transcript (and
% the error itself) on disk. See StartSessionLog.m.
sessionLogFile = fullfile(outDir, ['session_report_' d '.txt']);
% logCleanup must stay in scope: clearing it stops the log immediately.
logCleanup = StartSessionLog(sessionLogFile, 'CenterOutTask', d);   %#ok<NASGU>

% Show performance from a previous run with the same timestamp, if any
try
    prev = load(fullfile(outDir, ['perf_' d '.mat']), 'good_trials', 'total_trials');
    set(orgParams.handles.edit91, 'String', num2str(prev.good_trials));
    set(orgParams.handles.edit92, 'String', ...
        num2str(prev.good_trials / prev.total_trials * 100));
catch
end

% --- Timing parameters (seconds) -----------------------------------------
% All overridable from orgParams (set by the console GUI); the literals
% here are just the fallback defaults when a field isn't provided, so any
% caller that predates these fields (e.g. OffrigPlay) keeps behaving the
% same as before.
holdTime_base   = OrgGet(orgParams, 'holdTimeBase',  1.0);   % cursor must stay in the centre this long...
holdTime_delta  = OrgGet(orgParams, 'holdTimeDelta', 0.5);   % ...drawn uniformly in [base-delta, base+delta]
holdTime_min    = holdTime_base - holdTime_delta;
holdTime_max    = holdTime_base + holdTime_delta;

barDuration       = OrgGet(orgParams, 'barDuration', 1.0);   % minimum bar-visible time before the cue
barStaysVisible   = 0;   % 0 = bar hides after barDuration, 1 = stays during selection
barTotalDuration  = 1.0; % total bar-visible time (only if barStaysVisible = 1)

% Working-memory delays. Both default to 0 (= no delay, as on the rig
% today); raise them gradually toward 1.0 s during training. The cursor
% must keep holding the centre through each delay (leaving early = error).
delayStimToRule  = OrgGet(orgParams, 'delayStimToRule',  0);   % delay 1: stimulus (bar) offset -> rule (cue)
barToTargetDelay = OrgGet(orgParams, 'barToTargetDelay', 0);   % delay 2: rule (cue) offset -> target onset

% useCue=false skips DRAWING the cue dots (screen just stays blank/fixation
% through the same cueDuration window) without changing trial timing;
% the CUE epoch and its duration still run exactly as before, so a session
% can compare with/without the rule reminder without also changing how
% long the subject has to wait for targets. Console checkbox "Show cue".
useCue      = OrgGet(orgParams, 'useCue', true);
cueDuration = OrgGet(orgParams, 'cueDuration', 0.5);   % time the cue dots (rule) are shown (500 ms)
cueYOffset  = OrgGet(orgParams, 'cueYOffset',  -220);  % cue vertical offset from centre (px, negative = up)
cueSize     = OrgGet(orgParams, 'cueSize',     125);   % cue dot diameter (px)
cueDistance = OrgGet(orgParams, 'cueDistance', 220);   % horizontal spacing between cue dots (px)

targetDuration = OrgGet(orgParams, 'targetDuration', 5);    % legacy combined window (fallback for the two split limits below)
% Two SEPARATE reach deadlines (console-editable), replacing the single
% targetDuration window. Each falls back to targetDuration when not set, so an
% older caller that only sets targetDuration keeps a 5 s window for each phase.
%   maxDecisionTime  : from target onset to LEAVING the centre (bounds the
%                      DECISION_TIME epoch; never departing in time = timeout).
%   maxExecutionTime : from leaving the centre to REACHING the correct target
%                      (bounds the MOVEMENT epoch; not arriving in time = timeout).
maxDecisionTime  = OrgGet(orgParams, 'maxDecisionTime',  OrgGet(orgParams, 'targetDuration', 2));
maxExecutionTime = OrgGet(orgParams, 'maxExecutionTime', OrgGet(orgParams, 'targetDuration', 2.5));
tarHoldFeed    = OrgGet(orgParams, 'tarHoldFeed',    0.2);  % success feedback duration
tarErrorFeed   = OrgGet(orgParams, 'tarErrorFeed',   0.2);  % error feedback duration
ITI            = OrgGet(orgParams, 'ITI',       2);    % base inter-trial interval (successful trials)
ITI_delta      = OrgGet(orgParams, 'ITIDelta',  0.5);  % random +/- variation on the success ITI
ITI_error      = OrgGet(orgParams, 'ITIError',  3);    % inter-trial interval after errors (longer)
% Reward valve time: driven by the SAME orgParams.Reward field the console's
% reward control sets, so changing "Reward" in the GUI affects the real
% per-trial reward, not just the manual-reward key.
rewTime        = OrgGet(orgParams, 'Reward', 0.15);
minTarHoldTime = OrgGet(orgParams, 'minTarHoldTime', 0.05);    % required hold inside the target before it counts as good (s)
% Hold strictness (console "Strict hold"). false (default): lenient -- leaving
% the target resets the hold timer and the subject may return and still earn
% reward by holding minTarHoldTime. true: any exit from the target before
% completing the hold aborts the trial (error_type = 1, no reward). See
% EP.TARGET_HOLD.
strictHold = logical(OrgGet(orgParams, 'strictHold', false));

% --- Stimulus set: bar lengths (visual angle -> pixels) -------------------
% The table itself, the reduced 3-length sets and the bar subset all live in
% ConfigBarLengths.m now, EDIT THAT FILE to change the physical bar sizes.
% Console-selectable via orgParams.stimulusSet ('full12' | 'prototypes3' |
% 'extremes3', see CenterConsole.m) and orgParams.barLengthSubset. Category
% colours: 1=Short/Orange, 2=Mid/Green, 3=Long/Blue (the cue and targets are
% coloured by CATEGORY).
[bars, barSubsetErr] = ConfigBarLengths(orgParams);
if ~isempty(barSubsetErr)
    error('CenterOutTask:badBarSubset', 'orgParams.barLengthSubset: %s', barSubsetErr);
end
% Unpacked into the local names the rest of this file already uses.
numCategories      = bars.numCategories;
stimulusSet        = bars.stimulusSet;
lengthCategory_set = bars.categorySet;   % tested for "one length per category" below
target_angles      = bars.angles;
lengthCategory     = bars.category;
lengthCat2         = bars.category2;
lengthsPerCategory = bars.lengthsPerCategory;
allBarSizes        = bars.sizesPx;
numLengths         = bars.numLengths;    % 12, 3 in either reduced set, or fewer with a bar subset
if numel(bars.subset) < numel(bars.anglesSet)
    fprintf('Bar subset: running %d of %d lengths (indices %s; %s deg VA).\n', ...
        numel(bars.subset), numel(bars.anglesSet), mat2str(bars.subset), ...
        strjoin(arrayfun(@(a) sprintf('%.2f', a), target_angles, 'UniformOutput', false), ' '));
end

barColorIntensity = OrgGet(orgParams, 'barColorIntensity', 0);  % 0 = white (categorize by LENGTH), 1 = full colour reveals the category
barHeight_default  = OrgGet(orgParams, 'barHeight',  50);
barOffsetY_default = OrgGet(orgParams, 'barOffsetY', -150);

% --- Training phases (console "Training phase") ---------------------------
% Colour-MATCHING drills that come before the real categorization task: the
% bar is drawn in its own category colour and the subject only has to reach
% the target painted that same colour. Both phases run on this file's
% existing state machine, sequence builder, retry/requeue logic, CSV and
% trajectory logging; the only thing they change is how many targets a
% trial offers and how their colours are picked.
%   0  off (default)  normal length categorization: white bar, 2 or 3
%                     targets by sessionMode, subject infers the category
%                     from the bar's LENGTH.
%   1  match          one single target, in the bar's own colour. Nothing to
%                     choose between, so a wrong-target error is impossible;
%                     only early exits and target timeouts can fail a trial.
%   2  match+foil     the matching target plus ONE distractor in a different
%                     category colour, drawn fresh each trial (and on each
%                     retry). Picking the distractor is an ordinary
%                     wrong-target error and gets the usual error flash.
% Pair with the bar subset above to drill a single colour first (e.g. '1'
% for Short only), then widen the selection as the subject improves.
trainingPhase = OrgGet(orgParams, 'trainingPhase', 0);
% Error flash policy (console "Show error flash", pre-training). A failed
% hold/reach (error_type 1, an early exit / not completing) ALWAYS flashes;
% the wrong-target pick (error_type 2, the phase-2 foil) flashes only when
% this is on. Off by default: the foil pick then just resolves without a
% flash. See EP.ERROR_FB below.
showErrorFlash = logical(OrgGet(orgParams, 'showErrorFlash', false));

% Strict training feedback (console "Training error flash"). SOLO afecta a
% las fases de entrenamiento (trainingPhase > 0); la tarea de categorizacion
% (trainingPhase == 0) queda EXACTAMENTE igual, sin importar este flag.
% Cuando esta activo:
%   (a) tocar el target INCORRECTO/foil => error CON flash (error_type = 2),
%       lo que ademas DESACTIVA el modo indulgente foilNoAbort de abajo.
%   (b) SALIR del target correcto antes de completar minTarHoldTime (romper
%       el hold) => error CON flash (error_type = 3, hold-break), en lugar
%       de solo reiniciar el conteo y permitir el reingreso.
% Default = true: en entrenamiento se marca error con flash en ambos casos.
% Ponlo en false para recuperar la conducta indulgente (el foil no aborta y
% salir del target solo reinicia el hold).
%
% RELACION CON strictHold (definido arriba). Los dos gobiernan el MISMO
% evento -- romper el hold -- pero en ambitos distintos y con codigos
% distintos, y por eso conviven en vez de sustituirse:
%   strictHold     : toda la sesion, incluida la categorizacion; cierra el
%                    ensayo como error_type = 1 (early exit), sin flash.
%   strictTraining : solo pre-entrenamiento; cierra como error_type = 3
%                    (hold-break), CON flash, y se cuenta en su propio
%                    contador (error_holdbreak) en lugar de diluirse entre
%                    los early exits.
% En entrenamiento strictTraining TIENE PRIORIDAD sobre strictHold, para que
% el hold-break quede etiquetado como tal. Ver EP.TARGET_HOLD mas abajo.
trainingErrorFlash = logical(OrgGet(orgParams, 'trainingErrorFlash', true));
strictTraining     = trainingErrorFlash && (trainingPhase > 0);
if ~ismember(trainingPhase, [0 1 2])
    error('CenterOutTask:badTrainingPhase', ...
        'orgParams.trainingPhase must be 0 (off), 1 or 2; got %s.', num2str(trainingPhase));
end
if trainingPhase > 0
    % The whole point of these phases is that bar and correct target carry
    % the SAME colour, so the bar is always drawn at full category colour
    % regardless of the console's "Reveal category colour" checkbox.
    barColorIntensity = 1;
    % The cue dots are a reminder of the 2-/3-category rule, which no longer
    % describes what is on screen (1 target in phase 1, an arbitrary colour
    % pair in phase 2). Suppressed the same way orgParams.useCue = false
    % does it, i.e. the CUE epoch still runs for its full cueDuration;
    % trial timing is unchanged, only the dots are gone. Set cueDuration = 0
    % from the console to drop that pause as well.
    useCue = false;
    if trainingPhase == 1
        fprintf(['Training phase 1: one target per trial, in the bar''s own colour. ' ...
            'Bar drawn at full colour, cue dots off.\n']);
    else
        fprintf(['Training phase 2: matching target + one foil in another category ' ...
            'colour (error flash on a foil pick). Bar drawn at full colour, cue dots off.\n']);
    end
end

% --- Foil-forgiving training (foilNoAbort) -------------------------------
% Cuando esta activo, tocar un target DISTRACTOR (foil) durante el
% movimiento NO aborta el ensayo ni cuenta como error: el ensayo sigue
% corriendo (permanece en EP.MOVEMENT) hasta que el sujeto alcanza el
% target CORRECTO, o hasta que expira targetDuration (entonces se cierra
% como timeout / early-exit, error_type = 1).
%
% Se aplica SOLO en fases de entrenamiento (trainingPhase > 0). En la tarea
% de categorizacion propiamente dicha (trainingPhase == 0) elegir el target
% equivocado ES la respuesta del ensayo, de modo que ahi el foil SIEMPRE
% penaliza, sin importar este flag (si no, no habria tarea que resolver).
%
% Default = 1 (indulgente en entrenamiento). Pon foilNoAbort = 0 para
% restaurar la conducta previa (un foil en fase 2 = wrong-target error con
% su flash de error habitual). No requiere cambios en la consola: si el GUI
% no envia el campo, se usa este default via OrgGet.
foilNoAbort  = logical(OrgGet(orgParams, 'foilNoAbort', 1));
% strictTraining tiene prioridad: si se pidio marcar el foil como error CON
% flash (arriba), no se puede a la vez perdonar el foil. Por eso el modo
% indulgente solo queda activo cuando strictTraining esta apagado.
forgiveFoils = foilNoAbort && (trainingPhase > 0) && ~strictTraining;
if forgiveFoils
    fprintf(['Foil-forgiving ON: los distractores NO abortan el ensayo; el sujeto ' ...
        'puede seguir hasta el target correcto (limite de movimiento: maxExecutionTime = %.2fs).\n'], ...
        maxExecutionTime);
end
if strictTraining
    fprintf(['Strict training ON: el foil marca error CON flash (error_type 2) y salir ' ...
        'del target antes de completar el hold marca error CON flash (error_type 3, ' ...
        'hold-break). Se ignoran foilNoAbort y strictHold mientras esto este activo.\n']);
end

% --- Colours -------------------------------------------------------------
% ColorCategoryMap (see ColorCategoryMap.m) is the single source of truth
% for every colour<->category association used below, so the cue dots, the
% bar, the targets, and the confusion-matrix decoding above can never drift
% out of sync with each other the way a colour table copied in more than
% one place could.
colorMap = ColorCategoryMap();
red_c    = colorMap.RED;     black_c  = colorMap.BLACK;      green_c  = colorMap.GREEN;
white_c  = colorMap.WHITE;   blue_c   = colorMap.BLUE;
orange_c = colorMap.ORANGE;
gray_c   = [140 140 140];    % centre-hold "waiting" colour -- matches CenterInTask.m's own gray_c
% Two INDEPENDENT colour tables (console "Category colours (hex)"), not one
% shared table a 2-cat trial borrows rows from: colorArray3Cat for 3-cat
% trials (row 1=Short, 2=Mid, 3=Long) and colorArray2Cat for 2-cat trials
% (row 1=Short, 3=Long; row 2 is never indexed, since colorRows2 below
% never includes it; populated with the Short colour purely so its shape
% matches colorArray3Cat). Falling back to ColorCategoryMap's own
% ORANGE/GREEN/BLUE when a hex field is absent reproduces this file's
% original behaviour (a single shared table, 2-cat reusing rows 1 and 3)
% exactly. See OrgGetColor.m and HexToRGB.m for the hex parsing.
colorArray3Cat = [ ...
    OrgGetColor(orgParams, 'color3CatShort', colorMap.ORANGE); ...
    OrgGetColor(orgParams, 'color3CatMid',   colorMap.GREEN); ...
    OrgGetColor(orgParams, 'color3CatLong',  colorMap.BLUE)];
color2CatShortRGB = OrgGetColor(orgParams, 'color2CatShort', colorMap.ORANGE);
color2CatLongRGB  = OrgGetColor(orgParams, 'color2CatLong',  colorMap.BLUE);
colorArray2Cat = [color2CatShortRGB; color2CatShortRGB; color2CatLongRGB];
if trainingPhase > 0
    % Training trials colour their targets by the bar's own 3-category
    % colour, and a phase-2 distractor can be ANY of the three, including
    % Mid, whose row in colorArray2Cat is a dummy copy of Short (see above).
    % Every "is this a 2-category trial?" branch downstream (the bar colour
    % in EP.HOLD, placeTargets' colour-table pick) would otherwise index
    % that dummy row for a phase-2 trial and paint a green target orange.
    colorArray2Cat = colorArray3Cat;
end

% --- Trial count ---------------------------------------------------------
% minPerLength is the real target: the session keeps running until every one
% of the numLengths individual bar lengths (12 for full12, 3 for
% prototypes3; see orgParams.stimulusSet) has reached this many correct
% trials. This is stricter than gating on a category total alone; with
% only a category-level quota, a session could hit its number using mostly
% the "easy" length in a category while never even showing its hardest
% (boundary-adjacent) one, since the per-length mix isn't controlled. Gating
% per length instead guarantees every individual bar length gets real
% coverage, not just the category as a whole.
%
% `bufferBudgetTrials` is a derived, category-level equivalent
% (lengthsPerCategory lengths/category x 4 positions/length) kept only for
% existing plumbing that predates per-length gating: buffer sizing, the
% GUI's "trainTrials" display field, and the on-screen counter's
% denominator. It is not what decides when the session stops, that's
% good_trials_lenpos vs minPerLength (below).
constTrials      = 4;              % 4 positions: right, up, left, down
% lengthsPerCategory is set above with the stimulus-set choice (4 for
% full12, 1 for prototypes3).

% minPerLength: the real stop-condition quota, resolved directly from
% orgParams (single source of truth; see the header note above).
stopMode = lower(OrgGet(orgParams, 'stopMode', 'correctTrials'));
switch stopMode
    case 'blocks'
        numBlocks = OrgGet(orgParams, 'numBlocks', 1);
        % Quota is now per (length, position) combination, and each 48-trial
        % block gives exactly ONE opportunity per combination; so numBlocks
        % maps 1:1 to minPerLength (not x constTrials, like before this was
        % per-length-only and each block gave 4 opportunities per length).
        minPerLength = numBlocks;
    otherwise   % 'correctTrials'
        minPerLength = OrgGet(orgParams, 'maxCorrectTrials', 100);   % correct trials needed per (length, position) combination
end
% What fills that quota: correct trials (default) or every presentation.
% See ConfigOrgParams.m for the reasoning; the practical difference is that
% with presentations the session runs exactly plannedTrials trials no matter
% how the subject does, because an error consumes its combination's slot
% instead of leaving it owed.
quotaByPresentations = logical(OrgGet(orgParams, 'quotaByPresentations', false));
% What the status line calls the number it is counting down. "correct left"
% is wrong under presentations; there what is left is trials, and an error
% brings the number down just as a success does.
if quotaByPresentations
    quotaNoun = 'trials';
else
    quotaNoun = 'correct';
end
% Per category: lengthsPerCategory x constTrials (positions) x minPerLength
% correct trials each, since the quota is per (length, position) combination.
bufferBudgetTrials = minPerLength * lengthsPerCategory * constTrials;   % category-level equivalent, for buffer sizing only

% --- Trial repetition: correction procedure and requeue ------------------
% The two mechanisms that let a session run MORE trials than it planned
% (see the trial-loop header comment on maxStimAttempts, and EP.REWARD /
% EP.ERROR_FB). Read here, before the session-budget printout below, so
% that printout can say plainly whether either is switched off; an
% operator sanity-checking a launch should not have to infer it from the
% trial counter later.
%
% Both default true (the monkey configuration this task was built for) and
% are unchecked automatically for human participants; see ConfigSession.m
% for the reasoning, ConfigOrgParams.m for the field definitions.
useRetries = logical(OrgGet(orgParams, 'useRetries', true));
useRequeue = logical(OrgGet(orgParams, 'useRequeue', true));

% --- Session budget, in the terms the stop condition actually uses -------
% plannedTrials is the whole point of the session: one correct trial per
% (length, position) combination, minPerLength times over. It is also
% exactly how many trials an ERROR-FREE session runs, since each scheduled
% slot is one such combination, which is why the same number serves as
% both the trial budget and the correct-trials target.
%
% Deliberately NOT bufferBudgetTrials (which is only ONE category's share,
% and over-counts whenever a bar subset leaves the categories unbalanced),
% putting that per-category number in the GUI's "Trials budget" box would
% label it as a whole-session figure.
%
% requeuedTrials is what makes the budget grow during a run: every error
% that forces a clean, un-reshuffled repeat appends one extra slot (see
% EP.REWARD / EP.ERROR_FB), so plannedTrials + requeuedTrials is the live
% "trials this session will take" figure the status line and the budget box
% both report.
plannedTrials    = numLengths * constTrials * minPerLength;
plannedBlocks    = minPerLength;   % each block = one opportunity per combination
requeuedTrials   = 0;
% Correct trials still owed, counted the way the stop condition counts them
% (per combination, capped at minPerLength; an over-achieving combination
% cannot pay off another one's shortfall).
quotaRemaining = @(g) plannedTrials - sum(min(g(:), minPerLength));

orgParams.trainTrials = plannedTrials;
set(orgParams.handles.editTrainRepe, 'String', num2str(plannedTrials));

% --- Counters ------------------------------------------------------------
good_trials = 0;  total_trials = 0;
trial_sequence_index = 0;   % advances on every attempt; indexes the sequence
error_early_exit = 0;       % left centre too early
error_wrong_target = 0;     % selected the wrong target
% Hold-break: reached the CORRECT target, then left it before completing
% minTarHoldTime. Only ever produced under strictTraining (pre-training with
% "Training error flash" on); stays 0 in the categorization task, where the
% same event is either forgiven or closed as an early exit via strictHold.
error_holdbreak = 0;

% Diagnostico de foils indulgentes (NO penalizan; solo se cuentan por
% flanco de entrada, no por frame). Utiles para ver cuanto tantea el
% sujeto los distractores antes de acertar durante el entrenamiento.
foilTouches     = 0;        % total de entradas a un foil en toda la sesion
foilTouches_grp = zeros(1, 3);
wasInFoil       = 0;        % estado previo (deteccion de flanco en EP.MOVEMENT)

% Previous-row values for the CSV's PrevTrialCorrect/PrevTrialDirection
% columns (sequential-effects covariates). No previous trial yet for row 1.
blockSize          = numLengths * 4;   % every length x 4 rotating positions (48 for full12, 12 for prototypes3)
prevTrialCorrect   = 0;
prevTrialDirection = 'None';

% Per-group counters: index 1=short, 2=mid, 3=long. Used for reporting and
% the on-screen counter only; the stop condition is gated by
% good_trials_lenpos, not these.
good_trials_grp  = zeros(1, 3);
total_trials_grp = zeros(1, 3);
error_early_grp  = zeros(1, 3);
error_wrong_grp  = zeros(1, 3);
error_holdbreak_grp = zeros(1, 3);
% Correct trials per (length, position) combination, rows = bar length
% (1-12 for full12, 1-3 for prototypes3), cols 1-4 = position (direction) of
% the correct target for that attempt. One independent quota per (length,
% position) pair instead of one per length (see stopMode). Deliberately
% pools 2-cat and 3-cat attempts at the same length together; the stop
% quota needs no session-mode exclusion (see the note below). The 2-cat/
% 3-cat split for REPORTING (not gating) is tracked separately right below.
good_trials_lenpos = zeros(numLengths, 4);
% What the STOP CONDITION actually reads, kept separate from the correct-
% trials tally above so the two questions stay independent: "how well did
% the subject do on this combination" (good_trials_lenpos, reporting) and
% "is this combination done" (quota_lenpos, gating). With
% quotaByPresentations false the two are the same table; with it true this
% one counts every resolved trial instead. Maintained in one place, in
% EP.BOOKKEEP, right before the quota is tested.
quota_lenpos = zeros(numLengths, 4);
% Same tally, split by how many categories that attempt was drawn from;
% pure reporting, doesn't affect the stop quota above. In sessionMode =
% 'alternate'/'interleaved' the same bar length can be tested under EITHER
% category-count scheme (2-cat and 3-cat use DIFFERENT length->category
% splits; lengthCat2 vs lengthCategory below), so a combined table alone
% can't tell you whether a length's correct trials came from its 2-cat or
% 3-cat framing. good_trials_lenpos == good_trials_lenpos_2cat +
% good_trials_lenpos_3cat, always.
good_trials_lenpos_2cat = zeros(numLengths, 4);
good_trials_lenpos_3cat = zeros(numLengths, 4);

% Confusion matrix (ML-style): rows = true category, cols = chosen category
% (1=Short, 2=Mid, 3=Long); only counts attempts that actually reached a
% target selection (chosen_target_color >= 1 in BOOKKEEP below); an early
% exit never chose a category (chosen_target_color stays 0), so it isn't a
% misclassification and isn't tallied here (it's already reported
% separately as an early-exit error).
% A correct trial always lands on the diagonal; confusionMat(t,c) for t~=c
% is a wrong-target error where the subject picked category c's colour
% instead of the true category t. In sessionMode = '2cat', row/col 2 (Mid)
% just stays all-zero, 2-cat trials never draw or offer Mid as an option.
confusionMat = zeros(3, 3);

% Per (group x direction) matrices: rows 1-3 = groups, cols 1-4 = directions
decision_times        = cell(3, 4);
correct_trials_matrix = zeros(3, 4);
total_trials_matrix   = zeros(3, 4);

% The SAME three tallies at (bar length x direction) resolution: rows =
% every length in the active set, cols 1-4 = directions. That is the 48
% combinations a full12 session is actually built from (12 x 4), which the
% matrices above roll up into 3 category rows; a roll-up that hides
% exactly what a psychometric read of this task needs, since the whole
% point of the 4 lengths inside a category is that they are NOT equivalent
% (the ones nearest a category boundary are the hard ones). Every cell here
% is credited from inside the same guard as its per-category counterpart
% below in the trial loop, so summing these rows by category always
% reproduces the matrices above exactly; they are one measurement at two
% resolutions, never two independent counts that could drift apart.
%
% Keyed on current_trial_direction (the direction the correct target was
% actually SHOWN at this attempt), same as the per-category matrices, NOT
% on the planned position that good_trials_lenpos/the quota tables use;
% those two differ only for a correction retry, and performance belongs to
% what was on screen.
decision_times_lenpos        = cell(numLengths, 4);
correct_trials_lenpos        = zeros(numLengths, 4);
total_trials_lenpos          = zeros(numLengths, 4);

% Allocate outcome logs with a 3x buffer (attempts can exceed `bufferBudgetTrials`)
maxAttempts      = bufferBudgetTrials * 3;
trial_outcomes   = zeros(1, maxAttempts);   % 1 = correct, 0 = error
trial_error_type = zeros(1, maxAttempts);   % 0 = correct, 1 = early exit, 2 = wrong target, 3 = hold-break

% --- Per-block statistics (Level 1 of the 2-level end-of-session report;
% Level 2 is the session-wide totals already tracked above). A "block" here
% is the same blockSize (= numLengths*4) pseudorandom-sequence rotation the
% CSV log's Block column uses; see blockSize below. grp/nc are read
% straight from the sequence (trialCatIndices/trialNumCat) at tally time,
% not assumed from a fixed per-block layout, so sessionMode = 'alternate'
% (2-cat/3-cat segments that don't line up with blockSize boundaries) and
% 'interleaved' (2-cat/3-cat chosen per trial) still tally correctly,
% each block just reports whatever mix of category counts actually ran in
% it (nCat2/nCat3 below). Grown on demand in BOOKKEEP if a session runs
% long enough to exceed this initial estimate (mirrors the
% trial_outcomes/trial_error_type growth pattern above); numBlocksUsed
% tracks how many entries are real so the trailing, still-empty
% preallocation isn't printed.
blockStatsTemplate = struct('total', 0, 'good', 0, 'errorEarly', 0, 'errorWrong', 0, ...
    'errorHoldbreak', 0, 'totalGrp', zeros(1, 3), 'goodGrp', zeros(1, 3), 'nCat2', 0, 'nCat3', 0);
blockStats     = repmat(blockStatsTemplate, 1, max(1, ceil(maxAttempts / blockSize)));
numBlocksUsed  = 0;

% --- Trial-by-trial CSV (append mode: safe even if the task crashes) -----
% ONE row per attempt, behavioural and timing columns only. This engine no
% longer computes per-trial kinematics, so there are no PeakVelocity_cmPerS
% / MeanVelocity_cmPerS / PeakAcceleration_cmPerS2 / NumMovementSamples
% columns and no companion trial_kinematics_*.csv; the trajectory exports
% keep every epoch and sample, so those quantities are derived offline from
% them instead. A row here joins to its trajectory rows on
% Block + TrialNumInBlock + Attempt -- the same key SaveMovementTrajectory.m's
% own header comment uses.
colorNames_log     = ColorCategoryMap.categoryCSVNames();
directionNames_log = {'Right_0', 'Up_90', 'Left_180', 'Down_270'};
trialLogFile      = fullfile(outDir, ['trial_data_' d '.csv']);
fid_log = fopen(trialLogFile, 'w');
% PlannedDirection = the ORIGINALLY planned position for this sequence
% slot (trialPositions, fixed by BuildTrialSequence; same value good_trials_lenpos
% uses), independent of any in-place reshuffle a correction retry does.
% DirectionCorrect is THIS attempt's actual shown position instead (see the
% retry-reshuffle comment above trialDirs(trial_sequence_index,...) further
% down); the two only differ for a trial that needed a retry, and only
% this per-attempt CSV (not the printed console report) records both side
% by side, so a retry's actual vs. planned position is fully auditable here.
fprintf(fid_log, ['Date,Block,TrialNumInBlock,StimulusGroup,BarSizeVA_deg,DecisionTime_s,' ...
                'ExecutionTime_s,TotalTime_s,IsCorrect,ErrorType,DirectionChosen,DirectionCorrect,' ...
                'PlannedDirection,ChosenTarget,PrevTrialCorrect,PrevTrialDirection,Attempt,' ...
                'NumCategories,SessionMode\n']);
fclose(fid_log);
fprintf('Trial log file created:      %s\n', trialLogFile);

% --- Per-foil-entry log (pre-training foil-forgiving only) ----------------
% One row PER FOIL ENTRY (not per trial): every time the subject enters a
% distractor during a forgiving pre-training trial (see EP.MOVEMENT), a row
% is appended here. The trial itself does not abort and its single row still
% goes to trial_data above; this companion file records each individual
% wrong-target touch that trial_data cannot (it is one-row-per-trial). Joins
% back to trial_data on Block+TrialNumInBlock+Attempt. Buffered in memory and
% flushed once per trial in BOOKKEEP, so it never does disk I/O inside the
% real-time tracking loop. Only ever written when forgiveFoils is on.
foilEventsLogFile = fullfile(outDir, ['foil_events_' d '.csv']);
if forgiveFoils
    fid_foil = fopen(foilEventsLogFile, 'w');
    fprintf(fid_foil, ['Date,Block,TrialNumInBlock,Attempt,StimulusGroup,BarSizeVA_deg,' ...
                    'CorrectDirection,FoilDirection,FoilColor,TimeSinceTargetOnset_s\n']);
    fclose(fid_foil);
    fprintf('Foil-events log file created: %s\n', foilEventsLogFile);
end
% In-memory buffer of foil entries not yet flushed to disk. Columns:
% [block, trialInBlock, attempt, trueGroup, foilColorRow, correctDir, foilDir,
%  barIdx, timeSinceOnset_s]. Grown on demand; flushed in EP.BOOKKEEP.
foilEventBuf   = zeros(0, 9);
nFoilPending   = 0;   % rows in foilEventBuf waiting to be written this trial


% --- Session mode: how many categories per trial -------------------------
% '3cat'        : every trial is Short/Mid/Long (3 targets)        [default]
% '2cat'        : every trial is Short/Long (2 targets)
% 'alternate'   : alternate 2-cat and 3-cat one FULL blockSize-trial block at
%                 a time (block 1 = all 2-cat, block 2 = all 3-cat, block 3 =
%                 all 2-cat, ...); blockLenCats below
%                 is pinned to blockSize itself (48 for full12, 12 for
%                 prototypes3), so a block finishes at one category count
%                 before the next block switches to the other.
%                 (named 'alternate', not 'blocks', so it doesn't collide with
%                 the stopMode='blocks' 48-trial quota unit above)
% 'interleaved' : 2-cat or 3-cat chosen at random each trial
sessionMode = '3cat';
if isfield(orgParams, 'sessionMode') && ~isempty(orgParams.sessionMode)
    sessionMode = lower(orgParams.sessionMode);
end
% The reduced sets carry exactly ONE length per category, so a 2-category
% framing has nothing to regroup: it would have to put two of the three
% lengths in the same bucket, which does not test a Short/Long boundary,
% it just relabels one of the three prototypes. These sets are 3-category
% by construction, and every mode that schedules 2-cat trials ('2cat', and
% the mixed 'alternate'/'interleaved') is therefore meaningless here.
%
% Coerced rather than rejected: a session should not fail to start with the
% subject already in the chair over a setting with exactly one sensible
% value. The console makes the combination unreachable in the first place
% (Session mode locks to 3-cat when a reduced set is picked), so this fires
% only for an offline script, loudly, and in the session log.
% Structural test ("each length IS its own category"), not a count and not a
% set name: it stays right for any future reduced set, and it does not fire
% for a full12 session whose bar subset happens to leave three lengths;
% those three still come from a 12-length table with a real 2-cat split.
oneLengthPerCategory = isequal(lengthCategory_set(:)', 1:numCategories);
if oneLengthPerCategory && ~strcmpi(sessionMode, '3cat')
    fprintf(['NOTE: stimulus set ''%s'' has one length per category, so sessionMode ' ...
        '''%s'' has no 2-category split to make. Running as ''3cat''.\n'], ...
        stimulusSet, sessionMode);
    sessionMode = '3cat';
end
% prototypes2 is a 2-category set by construction (one Short bar and one Long
% bar, Mid dropped -- see ConfigBarLengths.m). It has no 3-category framing to
% offer, so it locks to '2cat' the same way the one-length-per-category sets
% above lock to '3cat'. Left as a separate guard rather than folded into the
% test above because its categorySet is [1 3], not 1:numCategories, so
% oneLengthPerCategory is deliberately false for it.
if strcmpi(stimulusSet, 'prototypes2') && ~strcmpi(sessionMode, '2cat')
    fprintf(['NOTE: stimulus set ''prototypes2'' is a 2-category (Short/Long) set, so ' ...
        'sessionMode ''%s'' has no 3-category split to make. Running as ''2cat''.\n'], ...
        sessionMode);
    sessionMode = '2cat';
end
blockLenCats = blockSize;   % one full block (see blockSize above) per category-count segment
% Note: the per-(length,position) stop quota (good_trials_lenpos /
% minPerLength) needs no session-mode exclusion; every length in the
% active stimulus set is shown regardless of mode, only their category
% grouping differs.

% lengthCat2 (length -> bucket for the 2-category task) is resolved with the
% stimulus set and the bar subset up in the SETUP section, alongside
% lengthCategory (its 3-category counterpart), so all three stay indexed by
% the same selected lengths. Category ids are colour rows: 1=Short/Orange,
% 2=Mid/Green, 3=Long/Blue (2-cat uses only 1 and 3).
colorRows3 = [1 2 3];                   % Short, Mid, Long
colorRows2 = [1 3];                     % Short, Long

% --- Fixed target layout (optional, CenterConsole "Fixed target layout"
% checkbox) -------------------------------------------------------------
% Default (false) keeps DrawTrialLayout.m's per-trial colour/position
% shuffle. When true, every category always renders at the SAME cardinal
% direction on every trial; category 1 (Short) always Right, category 2
% (Mid) always Up, category 3 (Long) always Left; Down (direction 4) is
% never used, via FixedTargetLayout.m instead. See layoutForTrial below.
fixedTargetLayout = OrgGet(orgParams, 'fixedTargetLayout', false);
catDirMap = [1 2 3];   % category row -> direction (1=Right, 2=Up, 3=Left)

% --- Pseudorandom trial sequence -----------------------------------------
% BuildTrialSequence only guarantees an even split across the `numLengths`
% bar lengths (and therefore across categories) over a *full* block of
% numLengths*4 trials; a partial trailing block is just a random subset and
% can under-represent one category enough that it never reaches
% `bufferBudgetTrials` correct, running the trial index past the end of the
% sequence. Round up to a whole number of blocks so every category always
% gets enough trials.
seqBlock = numLengths * 4;
seqSize  = ceil((bufferBudgetTrials * 3) / seqBlock) * seqBlock;
[trialBarIndices, trialPositions] = BuildTrialSequence(seqSize, numLengths);

% Per-trial target layout (uniform for 1-, 2- or 3-category trials):
%   trialNumCat       number of categories/targets this trial (1 in training
%                     phase 1, 2 in phase 2 or a 2-cat trial, else 3)
%   trialDirs         direction (1-4) shown at each slot (padded to 3)
%   trialColorRows    colorArray row (1-3) shown at each slot (padded to 3)
%   trialCorrectSlot  slot whose colour matches the bar's category
%   trialCatIndices   colour row (1=Short,2=Mid,3=Long) of the correct category
trialNumCat      = zeros(seqSize, 1);
trialDirs        = zeros(seqSize, 3);
trialColorRows   = zeros(seqSize, 3);
trialCorrectSlot = zeros(seqSize, 1);
trialCatIndices  = zeros(seqSize, 1);
% True for a slot appended (past the original seqSize) to give an original
% presentation's (bar, position) combination a single fresh, un-reshuffled
% verification shot at the end of the sequence; queued only when that
% original presentation's outcome is ambiguous: it needed a reshuffled
% retry to succeed, or it exhausted every attempt without succeeding at
% all (see EP.REWARD and its mirror in EP.ERROR_FB). Succeeding on the very
% first, un-reshuffled attempt needs no repeat, that already verifies the
% combination directly. False for every originally-planned slot. Guards
% against requeuing the SAME combination again once a requeued slot fails
% via a wrong-target error (a deliberate, genuine attempt), but NOT when
% it fails via early exit, which chains on another requeue instead of
% closing the combination out (see EP.ERROR_FB), since an early exit never
% counted as a genuine attempt at it. So this grows the session by exactly
% one extra attempt-run per originally-planned slot ONLY once that slot's
% outcome is genuinely resolved (success, or a deliberate wrong-target
% pick); a subject stuck purely on early exits can chain it further.
isRequeuedSlot   = false(seqSize, 1);
for t = 1:seqSize
    if trainingPhase > 0
        % Training phases pin the target count themselves (1 = match only,
        % 2 = match + one foil); sessionMode's 2-/3-category schedule plays
        % no part in them.
        nc = trainingPhase;
    else
        switch sessionMode
            case '2cat',        nc = 2;
            case 'alternate',   nc = 2 + mod(floor((t - 1) / blockLenCats), 2);
            case 'interleaved', nc = 2 + double(rand < 0.5);
            otherwise,          nc = 3;          % '3cat'
        end
    end
    [catRows, trueCat] = CategoriesForTrial(nc, trialBarIndices(t), trainingPhase, ...
        lengthCategory, lengthCat2, colorRows2, colorRows3);
    % Correct slot keeps the balanced direction; distractors take the rest
    % (or, with fixedTargetLayout, every category keeps its own fixed
    % direction; see layoutForTrial).
    [slotDir, slotCol, correctSlot] = layoutForTrial(fixedTargetLayout, catDirMap, ...
        nc, trueCat, catRows, trialPositions(t));

    trialNumCat(t)          = nc;
    trialDirs(t, 1:nc)      = slotDir;
    trialColorRows(t, 1:nc) = slotCol;
    trialCorrectSlot(t)     = correctSlot;
    trialCatIndices(t)      = trueCat;
end

% --- Session budget printout ---------------------------------------------
% Printed before the display opens, so the operator can sanity-check what
% they just launched (and abort) before the subject is in front of it.
% Every figure here is derived from the SAME quantities the stop condition
% uses (good_trials_lenpos vs minPerLength) rather than restated, so the
% printout cannot claim a budget the session will not actually run to.
catNames_budget = ColorCategoryMap.categoryNames();
lengthsPerCat   = accumarray(lengthCategory(:), 1, [numCategories 1]);
fprintf('\n======= SESSION BUDGET =======\n');
if quotaByPresentations
    fprintf('Stop condition : %d presentation(s) per (bar length x position) combination\n', minPerLength);
    fprintf('                 errors consume their slot -- this session is exactly %d trials\n', plannedTrials);
else
    fprintf('Stop condition : %d correct trial(s) per (bar length x position) combination\n', minPerLength);
end
fprintf('Bar lengths    : %d (%.2f-%.2f deg VA)   Positions: %d\n', ...
    numLengths, min(target_angles), max(target_angles), constTrials);
fprintf('Per block      : %d trials = every length x %d positions, i.e. 1 shot per combination\n', ...
    blockSize, constTrials);
fprintf('Blocks         : %d (error-free); retries and requeues add trials, not combinations\n', plannedBlocks);
% Say it outright when either repetition mechanism is off: with both off the
% session runs exactly plannedTrials trials, which is a different session
% from the one the line above describes, and the operator is choosing
% between them at launch time.
if ~useRetries || ~useRequeue
    if ~useRetries
        retriesLabel = 'OFF (one attempt per stimulus)';
    else
        retriesLabel = sprintf('on (up to %d attempts)', OrgGet(orgParams, 'maxStimAttempts', 5));
    end
    if ~useRequeue
        requeueLabel = 'OFF (every trial credited where it stands)';
    else
        requeueLabel = 'on';
    end
    fprintf('Retries        : %s\n', retriesLabel);
    fprintf('Requeue        : %s\n', requeueLabel);
    if ~useRetries && ~useRequeue
        fprintf('                 -> this session runs exactly %d trials, no repeats of any kind\n', plannedTrials);
    end
end
fprintf('Correct trials needed, per category:\n');
for c = 1:numCategories
    fprintf('  %-5s : %2d length(s) x %d positions x %d = %4d\n', ...
        catNames_budget{c}, lengthsPerCat(c), constTrials, minPerLength, ...
        lengthsPerCat(c) * constTrials * minPerLength);
end
fprintf('  %-5s : %36d\n', 'TOTAL', plannedTrials);
fprintf('Remaining now  : %d of %d (whole session)\n', quotaRemaining(quota_lenpos), plannedTrials);
% Category-count mix. Counted over the first plannedTrials slots (the ones
% an error-free session actually runs) not the whole over-allocated
% sequence buffer, so the two numbers add up to the budget above. Printed
% only when the session genuinely mixes both (sessionMode 'alternate', and
% 'interleaved' which has the same reporting need); a pure 2cat/3cat or
% training session would just restate its own total.
nMixSlots = min(plannedTrials, seqSize);
n2cat_sched = sum(trialNumCat(1:nMixSlots) == 2);
n3cat_sched = sum(trialNumCat(1:nMixSlots) == 3);
if n2cat_sched > 0 && n3cat_sched > 0
    fprintf('Category mix   : %d x 2-cat + %d x 3-cat scheduled (sessionMode = %s)\n', ...
        n2cat_sched, n3cat_sched, sessionMode);
end
fprintf('==============================\n\n');

% --- Open the display ----------------------------------------------------
screens = Screen('Screens');
screenNumber = max(screens);
[taskWindow, windowRect] = PsychImaging('OpenWindow', screenNumber, white_c);
% Guaranteed screen/priority/cursor teardown on ANY exit path (normal
% return, thrown error, even Ctrl+C), independent of the rig-side
% CloseTask() helper. Without this, an error mid-loop from a missing/broken
% rig helper (e.g. undefined Rewards()/CloseTask() not on the MATLAB path)
% falls through to the catch block below, whose "try, CloseTask; catch, end"
% silently swallows a second undefined-function error, leaving the
% fullscreen PTB window frozen on screen even though MATLAB has returned.
ptbForceCleanup = onCleanup(@() ForceCloseScreen(taskWindow));
[screenXpixels, screenYpixels] = Screen('WindowSize', taskWindow);
screenXpixels = screenXpixels / 2;
screenYpixels = screenYpixels / 2;
flipInterval = Screen('GetFlipInterval', taskWindow);
Priority(MaxPriority(taskWindow));
Screen('BlendFunction', taskWindow, 'GL_SRC_ALPHA', 'GL_ONE_MINUS_SRC_ALPHA');

pointerRad     = 15;
pointer_offset = -220;
joyGain = OrgGet(orgParams, 'joyGain', -1.3);   % USB 'joystick' axis gain (console-editable); rz2adc/mouse unaffected
FixPoint = [-15 15 0 0; 0 0 -15 15];
[xCenter, yCenter] = RectCenter(windowRect);
% Same OrgGet-with-fallback pattern used for timing and the other geometry
% above: the console can override either of these, and the literal here is
% only the fallback when orgParams doesn't set the field. Note the default
% is 200, where v2_2-era sessions ran 150 (centerOutTask_v2_2.m; a
% superseded code generation, not a file in this repo; the name is kept
% because sessions recorded under it are still on disk); a wider centre
% window is easier to hold, so a session run WITHOUT an explicit
% orgParams.centerRad is not directly comparable to a v2_2 session on
% hold-related measures (early-exit rate in particular). Set the field from
% the console to pin it.
centerRad          = OrgGet(orgParams, 'centerRad', 200);   % centre-window diameter (px)
% targetRad is independent of centerRad; the operator can size the centre
% hold window and the peripheral targets differently. Default 200 matches
% centerRad's own default, so a session that doesn't touch this field
% renders targets at exactly the centre-window size, which is what
% Targets4Dir below produces when it reuses centerCircle's dimensions.
targetRad          = OrgGet(orgParams, 'targetRad', 180);    % peripheral target diameter (px)
centerToTargetDist = OrgGet(orgParams, 'centerToTargetDist', 320);
centerToTarget = centerToTargetDist * 1.27;
targetRadius   = centerToTarget;
circleSize     = [0 0 centerRad centerRad];
centerCircle   = CenterRectOnPointd(circleSize, xCenter, yCenter);
targetBaseRect = CenterRectOnPointd([0 0 targetRad targetRad], xCenter, yCenter);

% Four cardinal target rectangles (0, 90, 180, 270 degrees)
directions = [0, 90, 180, 270];
Targets4Dir = zeros(4, 4);
for i = 1:4
    a = deg2rad(directions(i));
    dx = cos(a) * targetRadius;  dy = -sin(a) * targetRadius;
    Targets4Dir(i, :) = targetBaseRect + [dx dy dx dy];
end

% --- Precompute constant render geometry (saves work in the hot loop) ----
% Cue dots are fixed per category count; precompute the 3-dot (Short/Mid/Long)
% and 2-dot (Short/Long) colour/rect matrices and draw whichever the current
% trial needs with a single vectorized FillOval (PTB accepts 3xN / 4xN).
cueColors3 = colorArray3Cat(colorRows3, :)';   % 3 dots: 3-cat Short/Mid/Long
cueColors2 = colorArray2Cat(colorRows2, :)';   % 2 dots: 2-cat Short/Long
cueRects3  = CueRectsFor([-1 0 1],   xCenter, yCenter, cueDistance, cueSize, cueYOffset);
cueRects2  = CueRectsFor([-0.5 0.5], xCenter, yCenter, cueDistance, cueSize, cueYOffset);
% Scaled centre-cue oval (centerCueScale is constant, so this rect is fixed).
centerCueScale = 0;
scaledCenterRect = CenterRectOnPointd( ...
    [0 0 centerRad*centerCueScale centerRad*centerCueScale], ...
    xCenter, yCenter);

% --- Hardware: keyboard, joystick, UDP -----------------------------------
% Input source: 'joystick' (rig, default), 'mouse' (off-rig play/testing),
% or 'rz2adc' (a SECOND, ADC-wired analog joystick relayed over UDP from
% Computer 1's JoystickRelayToTask.m; see SetupRZ2Joystick.m). useMouse
% still gates keyboard-device selection, the reward UDP link, and the
% recording-link gate below exactly as before (those only care about mouse
% vs. real hardware); useRZ2 additionally picks WHICH real device supplies
% the cursor, AND (further down, where trajBuf is logged) switches to
% recording every UDP sample the relay delivered between frames instead of
% one sample per frame.
inputSource = 'joystick';
if isfield(orgParams, 'inputSource') && ~isempty(orgParams.inputSource)
    inputSource = lower(orgParams.inputSource);
end
useMouse = strcmp(inputSource, 'mouse');
useRZ2   = strcmp(inputSource, 'rz2adc');

% Resolve key codes once; KbName string lookups are too costly per frame.
KEY_SPACE  = KbName('space');
KEY_ESCAPE = KbName('ESCAPE');
KEY_R      = KbName('r');
RestrictKeysForKbCheck([KEY_SPACE KEY_ESCAPE KEY_R]);
% See SetupKeyboardDevice.m for the full rationale (X11 master-keyboard /
% XTEST / hotkey-device filtering, KbQueue-over-KbCheck preference).
[kbDevice, useKbQueue] = SetupKeyboardDevice(useMouse, [KEY_SPACE KEY_ESCAPE KEY_R]);
joy = [];  rz2 = [];
if useRZ2
    rz2 = SetupRZ2Joystick(orgParams, remoteHost);
elseif ~useMouse
    joy = SetupJoystick();
end
HideCursorSafe(taskWindow);

manualReward     = rewTime / 2;   % consistent with the real per-trial reward, not the raw GUI field
manualRewardTime = 0;

% --- Water accounting ----------------------------------------------------
% Accumulated from what Rewards() REPORTS it commanded, not recomputed as
% (good_trials x rewTime): Rewards.m clamps each pulse to the Synapse
% gizmo's 1-1000 ms range and sends nothing when the UDP link is missing, so
% only its return value knows what the valve actually did. Kept split by
% source because they answer different questions; the trial total is the
% subject's earnings, the manual total is what the operator topped up by
% hand. See SessionReport.reward and the perf_*.mat fields at teardown.
rewardPulsesTask   = 0;  rewardSecTask   = 0;   % automatic pulse on each correct trial
rewardPulsesManual = 0;  rewardSecManual = 0;   % operator's 'r' key presses
% mL per second of valve-open time; rig-specific (line pressure, tubing),
% so there is no meaningful default; 0 means "not calibrated" and the report
% prints valve time only instead of inventing a conversion.
rewardMlPerSec = OrgGet(orgParams, 'rewardMlPerSec', 0);

% UDP/Synapse link. Off-rig (mouse) mode skips it: the host network and the
% Instrument Control Toolbox may be absent, and no markers/reward are needed.
uSynapse = [];
if ~useMouse
    uSynapse = SetupSynapseUDP(remoteHost, localHost);
    % Tell Computer 1 whether to actually run the RZ2 analog-joystick relay
    % (see SetRZ2RelayEnable.m); so it's only active while THIS machine
    % has Input source = 'rz2adc' selected, not for Computer 1's whole
    % "Run" session regardless of input source.
    SetRZ2RelayEnable(useRZ2, uSynapse);
end

h = orgParams.handles.dlgTrainingMain;   % polled every frame for the console's Abort button

% --- Pre-run safety gate: confirm the recording amplifiers / Synapse link;
% UDP is connectionless: opening uSynapse and sending reward/event markers
% NEVER fails even if the amplifiers / Synapse are OFF. Without this gate the
% task would run, log trials as "rewarded", deliver no reward, and record no
% neural data, a silent failure. Require explicit confirmation before start.
% Skipped in off-rig mouse mode (no amplifiers / recording in that case).
if ~useMouse && ~ConfirmRecordingLink()
    fprintf('Run aborted by operator: recording link not confirmed.\n');
    set(orgParams.handles.text77, 'String', 'Aborted: check amplifiers');
    set(orgParams.handles.text77, 'ForegroundColor', 'red');
    exitFlag = 1;   % skip the trial loop; fall through to clean teardown
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
% (search "Task stopped" below).
abortedByOperator = false;
% Set true when ClockSkewMonitor stops the run: a session killed because its
% time base went bad is neither an operator abort nor a completed quota, and
% the end-of-session text has to say so, because the alternative is exactly
% what happened on 03-Sep-2026 -- a run that ended looking like ordinary
% poor performance while every sample-anchored window was silently being
% truncated. Only ever set on the rz2adc path; the mouse and joystick paths
% read their position and their clock from the same call, so their skew is
% zero by construction.
abortedByClock = false;
skewMonitor = ClockSkewMonitor( ...
    OrgGet(orgParams, 'rz2SkewWarnSec',  0.05), ...
    OrgGet(orgParams, 'rz2SkewAbortSec', 0.20), ...
    [], ...
    OrgGet(orgParams, 'rz2SkewWindowFrames', 90));
% Set true when the session ends because the trial sequence ran out before
% the quota was met (see "Ran out of stimuli" below). A THIRD outcome, not a
% variant of the two above: nobody stopped it and it did not finish its
% quota either. Folding it into "Task done" would make a session that ended
% several correct trials short look, on the console, exactly like one that
% completed.
endedEarly = false;

% A failed attempt repeats the same stimulus (correction procedure), but only
% up to maxStimAttempts total attempts; the last consecutive failure counts
% as the stimulus's final error and the sequence advances to the next one.
% Succeeding on the very first, un-reshuffled attempt (stimAttempt == 1)
% genuinely verifies that (bar, position) combination and credits
% good_trials_lenpos immediately, no repeat needed. But an ORIGINAL
% presentation that only succeeds after a reshuffled retry, OR that
% exhausts every attempt without succeeding at all, does NOT credit
% good_trials_lenpos: the retry reshuffle means a retry-success may be at a
% DIFFERENT screen position than the one actually scheduled, so neither
% outcome verifies this SPECIFIC combination. Both instead queue exactly
% ONE clean, un-reshuffled repeat of themselves at the end of the sequence
% (see EP.REWARD and its mirror in EP.ERROR_FB, and isRequeuedSlot above);
% that guaranteed repeat's own eventual outcome; accepted as final,
% whether it resolves on its own first try or one of its own retries; is
% what credits good_trials_lenpos instead.
% Console-editable via orgParams.maxStimAttempts (see CenterConsole.m).
%
% EVERYTHING ABOVE describes the correction procedure as it runs for a
% monkey. With orgParams.useRetries false (read further up; the console
% unchecks it automatically for a human participant) the ceiling is clamped
% to a single attempt instead. Clamping the count rather than branching is
% deliberate: every downstream use of it; repeat_trial, the retry
% reshuffle at the top of the trial loop, the "retry n/m" status text;
% then switches itself off, since `stimAttempt < 1` is never true. There is
% no second code path to keep in step.
maxStimAttempts = OrgGet(orgParams, 'maxStimAttempts', 5);
if ~useRetries
    maxStimAttempts = 1;
end
stimAttempt     = 1;

% Screen('AsyncFlipBegin')/('AsyncFlipEnd') in the render block below hand
% the vsync wait to a background thread inside PTB: the MATLAB loop keeps
% running and polling the input device WHILE the flip is pending, and only
% blocks (AsyncFlipEnd) once it actually needs the completed swap, right
% before the next frame draws into the same buffer. This decouples the
% trajectory sample rate from the screen's Hz (see flipInterval above);
% it becomes bounded by the joystick/mouse's own polling rate and
% moveOversampleDt instead.
%
% moveOversample extra cursor reads, moveOversampleDt apart, are taken
% during that pending-flip window, in every epoch: this adds no extra
% wall-clock time to ITI/cue/bar durations, since the polling happens
% inside time the async flip is already spending waiting for vsync, not on
% top of it. Set moveOversample=0 via orgParams to disable and go back to
% one sample/frame (still async, just without the extra in-between reads).
%
% moveOversampleDt=0.008 (8ms): measured directly on this rig's joystick
% (median inter-change interval -> ~125 Hz native USB HID update rate, the
% common full-speed default). Polling narrower than that just re-reads the same cached HID
% value on about half the calls (no new information, just duplicate points
% that stair-step a differentiator).
% moveOversample=1, not several: at ~8ms/sample, 3 extra reads would span
% 24ms, longer than a ~16.7ms 60Hz frame's async-flip window, so the burst
% would run past the next vsync and delay the flip it's supposed to be
% free inside of. One extra read (8ms burst) safely fits, giving 2 real
% samples per frame (base + oversample) at roughly the native spacing.
moveOversample   = OrgGet(orgParams, 'moveOversample', 1);      % extra samples per frame, taken while the flip is pending
moveOversampleDt = OrgGet(orgParams, 'moveOversampleDt', 0.008); % seconds between them -- matches the joystick's measured ~125 Hz native update rate

% NOTE: the resampling grid, low-pass cutoff, outlier method and QC floors
% that used to be read here fed the per-trial kinematics engine, which has
% been removed, so those parameters went with it rather than being left as
% dead reads -- the oversampling above is what still shapes the recorded
% data, and everything downstream of it now happens offline in the Python
% EDA notebook from the trajectory exports. See ConfigOrgParams.m, where the
% matching defaults were dropped.

% Per-trial visual state
% awaitTargetOnset: set when the state machine turns the targets on, cleared
% by the next flip, which is what stamps t.targetOnset with the real
% stimulus-onset timestamp (see the render block and placeTargets below).
awaitTargetOnset = 0;
targetOn  = [0 0 0];
tarPos    = {[0 0 0 0], [0 0 0 0], [0 0 0 0]};
tarColor  = {orange_c, green_c, blue_c};
inTarget  = [0 0 0];
BarOn = 0; showCue = 0; showCursor = 1; updatePointer = 1;
% Gray-while-waiting / green-while-holding convention, console-configurable
% (checkbox "Gray until holding", orgParams.useHoldColorEffect, default on --
% same field and default as CenterInTask.m). On: gray until the cursor is
% confirmed inside the centre and the hold timer starts (EP.HOLD), green from
% then on. Off: the ring is always green (centerWaitColor = green_c).
useHoldColorEffect = logical(OrgGet(orgParams, 'useHoldColorEffect', true));
centerWaitColor = green_c;
if useHoldColorEffect
    centerWaitColor = gray_c;
end
centerHoldColor = centerWaitColor;
currentColor     = orange_c;
currentBarWidth  = allBarSizes(1);
currentBarHeight = barHeight_default;
currentBarOffsetY = barOffsetY_default;
barRect = [0 0 0 0];           % recomputed when the bar turns on
correctTarget = 1;
centerCueColor = green_c; centerContourColor = green_c;
reward = rewTime;
cursorRect = [0 0 0 0];

% --- Joystick/cursor trajectory buffer (X,Y over time) -------------------
% One row per frame: [TrialNum, Time, X, Y, Epoch, Block, TrialNumInBlock,
% Attempt, RZ2Idx].
% Time is MILLISECONDS SINCE THE FIRST TRIAL STARTED (sessionT0, captured
% once below the first time the setOnce_Trial block runs), not an absolute
% clock reading; so trajectory_movement_*.csv always starts at ~0
% regardless of how long MATLAB/Psychtoolbox had been running beforehand.
% ONE CONVENTION FOR EVERY ROW, whichever of the three write paths below
% produced it: a row is stamped at the moment ITS OWN x/y was read, minus
% sessionT0. Base rows use sampleTime (taken right after
% ReadCursorPosition), oversampled rows re-take it right after their own
% read, and rz2adc batch rows carry ReadRZ2Joystick.m's per-sample
% estimate, which spans up to that same read. So Time_ms is directly
% comparable across rows, in trajectory_movement_*.csv (which carries this
% column untouched; see SaveMovementTrajectory.m) and against the
% console's live session clock, which counts from the same sessionT0.
% Block/TrialNumInBlock are the same trial_sequence_index-derived values
% trial_data_*.csv's BOOKKEEP write uses (blockSize = numLengths*4 = 48; see
% there); split on trial_sequence_index, not total_trials, so a
% correction retry (same sequence slot, extra attempt) doesn't roll Block
% past the configured numBlocks. TrialNum (column 1) is still total_trials,
% so a row here still matches its trial_data.csv row 1:1 via TrialNum ==
% (that row's cumulative attempt count). Attempt is the same stimAttempt
% trial_data_*.csv logs (1 = fresh stimulus, 2+ = correction retry), so
% frames from different attempts at the same Block/TrialNumInBlock can
% still be told apart. Kept in memory and saved at teardown; grows in
% chunks if a long session exceeds the preallocation.
%
% RZ2Idx (column 9) is the relay's absolute sample index for rows the RZ2
% link produced, and NaN for every other row: mouse/joystick rows, the
% oversampled rows, and the cached-position row a frame writes when no UDP
% sample arrived. It is provenance, not decoration. Before this column
% existed, Time_ms was the only evidence of which clock a row came from,
% and it was the same column for both, so a row stamped from the wall clock
% sitting between two index-derived rows was indistinguishable from a
% genuine one -- that is how 506 backward steps of up to 3.17 s ended up in
% sessPX-309's export looking like data. NaN here now says outright "this
% row's time is estimated"; a non-NaN index says "derived, and here is the
% number it was derived from", which also lets an offline analysis redo the
% timing under a different rate without re-running anything.
trajChunk = 200000;
trajBuf   = zeros(trajChunk, 9);
trajN     = 0;

% sessionT0: GetSecs() the instant the first trial starts (set once, inside
% the setOnce_Trial block below; setOnce_Trial starts true, so this fires
% on the loop's very first iteration, before any trajBuf row is written).
% lastSessionTimeUpdate throttles the console's live "Session time" box to
% roughly once a second instead of every frame; see the isgraphics-style
% per-frame checks elsewhere in this loop for the same throttling idea.
sessionT0             = [];
lastSessionTimeUpdate = 0;

% sessionHoldT0: when the SESSION CLOCK starts; the first hold of the
% first trial (EP.HOLD_START below), i.e. the first moment the subject
% actually engaged with the task. Deliberately NOT sessionT0, which anchors
% the exported trajectory timestamps and must stay at the start of trial 1:
% moving it here would date every sample taken before the first hold to a
% negative time. Two different questions, two clocks.
%
% Trial 1 can sit in ENTER_CENTER for a long time (the subject settling,
% an operator adjusting the chair) and none of that is session time; the
% clock starting at the hold is what makes "total session time" comparable
% between sessions. Once started it runs unbroken to the end: an early exit
% does NOT stop it, so that trial's time simply counts up to the next
% trial's hold. Wall clock, so an operator pause is included in the total.
sessionHoldT0 = [];

curNumCat  = 3;   % categories/targets for the current trial (set per trial)

% The quota is checked once, at the end of EP.BOOKKEEP below (after that
% trial's row is written), not in this while-condition; see the `if
% ~any(good_trials_lenpos(:) < minPerLength)` right before `setOnce_Trial =
% 1` in the BOOKKEEP case. SUCCESS_FB -> ITI -> BOOKKEEP is where
% trial_outcomes/trial_data_*.csv actually get written, several frames
% after the quota-completing trial hits EP.REWARD; checking the quota
% earlier (e.g. every frame in this condition) risks exiting the loop as
% soon as the quota is satisfied but before that trial's row is written;
% it would count toward good_trials/total_trials/good_trials_lenpos but
% never make it into trial_outcomes or trial_data_*.csv.

% Discard whatever the RZ2 relay queued while the rest of setup ran; above
% all ConfirmRecordingLink's modal dialog, which holds here for as long as
% the operator takes. Those samples predate the session; keeping them would
% both stall the first frames working the backlog off AND anchor the
% trajectory clock on a stale sample. See FlushRZ2Joystick.m.
if useRZ2
    nFlushed = FlushRZ2Joystick(rz2);
    if nFlushed > 0
        fprintf('RZ2 link: discarded %d queued datagram(s) from setup before starting.\n', nFlushed);
    end
end

% Transient foil flash (pre-training only): when a foil is entered and the
% "Show error flash" checkbox is on, the screen flashes white/black until
% this time WITHOUT aborting the trial (see the Render block and EP.MOVEMENT).
% 0 = no flash pending. foilFlashStart anchors the white/black alternation.
foilFlashUntil = 0;
foilFlashStart = 0;

while exitFlag == 0

    if setOnce_Trial
        % The live status line is written at the END of this block instead
        % of here: it reports the trial/block this iteration is about to
        % run, and neither trial_sequence_index nor stimAttempt has been
        % advanced yet at this point.
        BlankScreen(taskWindow, black_c);

        t = initTimes();           % named time markers, all zero
        setOnce_Trial = 0;
        if isempty(sessionT0)
            % First time through setOnce_Trial == start of trial 1: zero
            % the trajectory clock here, not at script launch, so the
            % exported Time column reflects task time, not however long
            % the console/GUI sat idle beforehand.
            sessionT0 = GetSecs();
        end
        updatePointer = 1;
        setOnce_Hold  = 1;
        showCursor = 1;  showCue = 0;
        targetOn = [0 0 0];  BarOn = 0;
        awaitTargetOnset = 0;   % no targets pending at the start of a trial
        centerHoldColor = centerWaitColor;
        good_trial = 0;  error_type = 0;
        wasInFoil = 0;   % reinicia la deteccion de flanco de foils del ensayo
        current_trial_color = 0;  current_trial_direction = 0;
        % 0 = no target of any kind was entered (early exit / timeout), the
        % same sentinel chosen_target_direction uses, so the two agree and
        % the CSV never carries a negative code. Every real selection is a
        % category id 1-3, which is what the >= 1 guards downstream test.
        chosen_target_color = 0;
        chosen_target_direction = 0;   % 0 = no target entered yet (e.g. early exit)
        % Timing definitions. THREE intervals, each named for exactly what it
        % measures, and written to the CSV in this order:
        %   decisionTime  = target-onset  -> leave-center   (DecisionTime_s)
        %   executionTime = leave-center  -> reach-target   (ExecutionTime_s)
        %   totalTime     = decisionTime + executionTime    (TotalTime_s)
        %
        % TotalTime_s is the WHOLE stimulus-to-completion interval: from the
        % moment the targets appear to the moment the correct one is reached.
        % It is deliberately NOT the name of either half.
        %
        % POOLING NOTE. DecisionTime_s and ExecutionTime_s sit in the same
        % positions and carry the same names as in the centerOutTask_v2_2
        % generation, so those two columns pool as-is. The total is the only
        % column whose header has moved: v2_2-era files and v8.19 wrote it as
        % ReactionTime_s, one generation in between already wrote TotalTime_s,
        % and from v8.20 on TotalTime_s is the single name used everywhere --
        % in the CSV, in the variables and in the printed report. All of those
        % headers hold the SAME quantity, so an older file only needs its
        % third timing column renamed before it can be pooled.
        decisionTime = NaN; executionTime = NaN; totalTime = NaN;
        current_ITI = ITI + (rand() * 2 - 1) * ITI_delta;
        holdTime = holdTime_min + rand() * (holdTime_max - holdTime_min);
        if repeat_trial == 0
            if trial_sequence_index + 1 <= seqSize
                trial_sequence_index = trial_sequence_index + 1;
            else
                % Truly out of material: every stimulus either succeeded or
                % used up its maxStimAttempts. Stop rather than index past
                % the end of the arrays; some categories may fall short of
                % `trials`; that's reported by the usual end-of-session summary.
                fprintf(['Ran out of stimuli before every category reached its ' ...
                    'quota -- ending session early.\n']);
                exitFlag = 1;
                endedEarly = true;   % reported as its own outcome, not as "Task done"
            end
            stimAttempt = 1;
        else
            stimAttempt = stimAttempt + 1;
            % Correction retry: same bar/category, but reshuffle which target
            % gets which colour (and a fresh random correct DIRECTION) so the
            % subject can't just avoid the spot that was wrong last time;
            % they have to read the bar again. This means current_trial_direction
            % (Performance Matrix, trial_data_*.csv's DirectionCorrect) can
            % differ from trialPositions (good_trials_lenpos, PlannedDirection)
            % for a trial that needed a retry; see PlannedDirection's header
            % comment above trialLogFile's fopen for how that's reconciled: a
            % success here doesn't verify THIS slot's original, un-reshuffled
            % (bar, position) combination specifically, so whenever this slot
            % finally resolves (succeeds, here or on a later retry, or
            % exhausts maxStimAttempts below), it queues exactly one clean,
            % un-reshuffled repeat of itself at the end of the sequence;
            % see EP.REWARD and EP.ERROR_FB's "Requeue exhausted trial".
            % (With fixedTargetLayout, there is nothing to reshuffle; every
            % category already always sits at its own fixed direction, so
            % this retry lands on the exact same layout as before, same as
            % a fresh randi(4) draw would if it happened to match.)
            % In training phase 2 this also redraws WHICH foil colour the
            % distractor wears (see CategoriesForTrial); same reasoning as
            % the position reshuffle: the retry must not be solvable by
            % remembering last attempt's wrong answer. trueCat is unchanged
            % by construction (it follows the bar length), so
            % trialCatIndices stays valid.
            nc = trialNumCat(trial_sequence_index);
            [retryCatRows, retryTrueCat] = CategoriesForTrial(nc, trialBarIndices(trial_sequence_index), ...
                trainingPhase, lengthCategory, lengthCat2, colorRows2, colorRows3);
            [slotDir, slotCol, correctSlot] = layoutForTrial(fixedTargetLayout, catDirMap, ...
                nc, retryTrueCat, retryCatRows, randi(4));
            trialDirs(trial_sequence_index, 1:nc)      = slotDir;
            trialColorRows(trial_sequence_index, 1:nc) = slotCol;
            trialCorrectSlot(trial_sequence_index)     = correctSlot;
        end
        repeat_trial = 0;
        curNumCat = trialNumCat(trial_sequence_index);   % 1, 2 or 3 targets

        % --- Live status: where this trial sits in the whole session ------
        % Both totals GROW during a run: every error that forces a clean
        % repeat appends a slot (requeuedTrials), so the denominators track
        % what the session will actually cost rather than what it would
        % have cost had the subject never erred. "left" counts the way the
        % stop condition counts (per (length, position) combination,
        % capped at minPerLength) so it reaches 0 exactly when the run
        % ends, which a raw correct-trial total would not.
        budgetTrialsNow = plannedTrials + requeuedTrials;
        set(orgParams.handles.editTrainRepe, 'String', num2str(budgetTrialsNow));
        % Painted from the SAME two helpers the end-of-trial repaint in
        % EP.BOOKKEEP uses, so the two can never drift into showing the
        % session differently depending on which one wrote last.
        paintProgressStatus(orgParams.handles, trial_sequence_index, budgetTrialsNow, ...
            plannedBlocks, blockSize, stimAttempt, maxStimAttempts, ...
            quotaRemaining(quota_lenpos), quotaNoun);
        paintProgressBreakdown(orgParams.handles, trial_sequence_index, budgetTrialsNow, ...
            plannedBlocks, blockSize, seqSize, trialNumCat, quota_lenpos, ...
            minPerLength, lengthCategory, numCategories);
        drawnow();

        nextEpoch = EP.ENTER_CENTER;
    end

    this_time = GetSecs();

    % --- Console: live elapsed-session-time readout, throttled to ~1/s ---
    % (every frame would mean hundreds of needless set()/redraws per second)
    % Counts from the first hold (sessionHoldT0), the same instant the
    % end-of-session total counts from; so the box on screen and the
    % number in the report can never disagree. Stays at 00:00:00 while
    % trial 1 waits for the subject to enter the centre for the first time.
    if ~isempty(sessionHoldT0) && this_time - lastSessionTimeUpdate >= 1
        set(orgParams.handles.textSessionTime, 'String', FormatElapsedTime(this_time - sessionHoldT0));
        lastSessionTimeUpdate = this_time;
    end

    % --- Read input device -> cursor position ---
    [x, y] = ReadCursorPosition(taskWindow, inputSource, joy, rz2, xCenter, yCenter, screenXpixels, screenYpixels, pointer_offset, joyGain);
    % sampleTime: the instant THIS cursor sample was taken, and the only
    % clock the base trajectory rows below are stamped with. Deliberately
    % not this_time (captured at the top of the iteration, i.e. BEFORE the
    % once-a-second console set() above and before the read itself): a
    % trajectory row has to carry the instant its own x/y was measured, and
    % the oversampled rows further down already stamp themselves that way.
    % Reusing this_time for the base row made rows in the SAME file follow
    % two different conventions, off by the cost of the read plus, on the
    % frames the console ticked, a graphics set().
    % this_time itself is untouched on purpose: the epoch state machine
    % below compares against it, and moving it would shift real task timing
    % (hold durations, bar/cue windows, targetDuration) rather than just
    % relabel a logged sample.
    sampleTime = GetSecs();
    inCenterCircle = CheckInCircle(x, y, xCenter, yCenter, centerCircle(1), centerCircle(3));
    if updatePointer
        cursorRect = [x - pointerRad, y - pointerRad, x + pointerRad, y + pointerRad];
    end

    % Record the cursor sample for this frame (trajectory map).
    % Block/TrialNumInBlock split on trial_sequence_index (position in the
    % pseudorandom stimulus sequence), NOT total_trials (raw attempt count).
    % trial_sequence_index only advances once a stimulus is resolved
    % (correct, or maxStimAttempts exhausted; see the trial-loop header
    % comment above); a correction retry re-attempts the SAME index.
    % trial_sequence_index==0 is the handful of frames before trial 1 has
    % actually started (still approaching the center for the first time);
    % guarded separately, since floor/mod on trial_sequence_index-1==-1
    % would otherwise wrap around to TrialNumInBlock=48 (mod(-1,48)==47 in
    % MATLAB), which reads as a real (but wrong) trial position instead of
    % "no trial yet".
    if trial_sequence_index > 0
        trajBlockNum        = floor((trial_sequence_index - 1) / blockSize) + 1;
        trajTrialNumInBlock = mod(trial_sequence_index - 1, blockSize) + 1;
    else
        trajBlockNum        = 0;
        trajTrialNumInBlock = 0;
    end
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
        rz2Batch = TakeRZ2JoystickSamples(rz2.port);   % [time, vx, vy, absIdx], oldest first
        nRz2 = max(size(rz2Batch, 1), 1);   % always >=1 row/frame, like every other input source
        if trajN + nRz2 > size(trajBuf, 1)
            trajBuf(end + max(trajChunk, nRz2), 9) = 0;   % grow in one chunk
        end
        if isempty(rz2Batch)
            % No new UDP sample arrived this frame (rare, only if the
            % relay briefly stalls); log the cached last-known position
            % ReadCursorPosition just returned so trajN still advances
            % exactly once, same as every other input source.
            trajN = trajN + 1;
            trajBuf(trajN, :) = [total_trials, (sampleTime - sessionT0) * 1000, x, y, nextEpoch.Value, trajBlockNum, trajTrialNumInBlock, stimAttempt, NaN];
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
                trajBuf(trajN, :) = [total_trials, rz2TimeMs, bx, by, nextEpoch.Value, trajBlockNum, trajTrialNumInBlock, stimAttempt, rz2Batch(bi, 4)];
            end
        end
    else
        trajN = trajN + 1;
        if trajN > size(trajBuf, 1)
            trajBuf(end + trajChunk, 9) = 0;   % grow in one chunk
        end
        trajBuf(trajN, :) = [total_trials, (sampleTime - sessionT0) * 1000, x, y, nextEpoch.Value, trajBlockNum, trajTrialNumInBlock, stimAttempt, NaN];
    end

    % trigRowIdx/trigTime: the trajectory row (and its timestamp) for the
    % cursor sample the state machine below actually acts on. inCenterCircle
    % and inTarget are both computed from THIS sample's x/y, so every epoch
    % transition the state machine derives from them belongs to this row and
    % to no other.
    %
    % Both are captured here, before the render block, because that block
    % invalidates the obvious alternatives: the oversample loop reassigns
    % sampleTime and advances trajN, so by the time the state machine runs
    % they refer to the LAST extra read, not to the sample that drove the
    % decision.
    %
    % trigTime is read back out of the row rather than copied from
    % sampleTime so that all three write paths above agree: on the rz2adc
    % path row trajN is the newest sample of the drained batch and carries
    % ReadRZ2Joystick.m's interpolated estimate, which is NOT sampleTime.
    % Reading the column keeps trigTime equal to the row's own Time_ms by
    % construction, whichever path wrote it, that identity is what makes
    % t.leaveCenter land exactly on MoveTime_ms == 0 downstream.
    trigRowIdx = trajN;
    trigTime   = sessionT0 + trajBuf(trigRowIdx, 2) / 1000;

    % --- Clock-skew guard (rz2adc only) ----------------------------------
    % sampleTime and trigTime are two readings of the SAME instant: the
    % GetSecs taken at this frame's cursor read, and the timestamp the row
    % that read produced actually carries. On every other input path they
    % are the same number. On rz2adc, trigTime comes from RZ2ClockMap, so
    % their difference is a direct measurement of how far the two time bases
    % have drifted apart -- the one quantity that, left unmeasured, turned a
    % 1.37% rate error into a session whose last ten trials could not be
    % completed at all. Cheap enough to run every frame; see
    % ClockSkewMonitor.m for the two thresholds and what each one means.
    if useRZ2 && skewMonitor.update(sampleTime - trigTime, this_time)
        exitFlag       = 1;
        abortedByClock = true;
    end

    % --- Render ---
    if this_time < foilFlashUntil
        % Transient foil flash (pre-training, only when showErrorFlash is on):
        % alternate white/black WITHOUT aborting the trial. The normal scene is
        % skipped this frame and reappears when the flash expires; a new foil
        % entry re-arms foilFlashUntil (that is the "reset"). See EP.MOVEMENT.
        if mod(floor((this_time - foilFlashStart) / 0.1), 2) == 0
            Screen('FillRect', taskWindow, white_c);
        else
            Screen('FillRect', taskWindow, black_c);
        end
        Screen('Flip', taskWindow);
    elseif showCursor
        for k = 1:3
            if targetOn(k), Screen('FillOval', taskWindow, tarColor{k}, tarPos{k}); end
        end
        if showCue
            if curNumCat == 2
                Screen('FillOval', taskWindow, cueColors2, cueRects2);
            else
                Screen('FillOval', taskWindow, cueColors3, cueRects3);
            end
        end
        if BarOn
            Screen('FillRect', taskWindow, currentColor, barRect);
            if barStaysVisible == 1 && t.barOnset > 0 && this_time > t.barOnset + barTotalDuration
                BarOn = 0;
            end
        end
        Screen('DrawLines', taskWindow, FixPoint, 4, white_c, [xCenter yCenter], 2);
        if targetOn(1) || targetOn(2)
            Screen('FillOval', taskWindow, centerCueColor, scaledCenterRect);
            Screen('FrameOval', taskWindow, centerContourColor, centerCircle, [], 4, 4);
        else
            % Gray while waiting to enter (ENTER_CENTER), green from the
            % moment the hold timer actually starts (EP.HOLD) through
            % BAR/CUE/etc., same convention as CenterInTask.m's holdColor.
            Screen('FrameOval', taskWindow, centerHoldColor, centerCircle, [], 4, 4);
        end
        Screen('FillOval', taskWindow, red_c, cursorRect);

        % Hand the buffer swap to PTB's background flip thread instead of
        % blocking here (see the moveOversample comment above): poll the
        % input device a few more times, moveOversampleDt apart, while the
        % flip is pending, then sync on AsyncFlipEnd right before the next
        % frame needs to draw into this buffer again.
        Screen('AsyncFlipBegin', taskWindow);
        % Skipped entirely for 'rz2adc': the trajBuf block above already
        % logged every UDP sample the relay delivered this frame, which is
        % strictly more resolution than polling ReadCursorPosition a few
        % more times here would add, doing both would just re-drain an
        % already-drained socket and log duplicate cached values.
        if moveOversample > 0 && ~useRZ2
            for oi = 1:moveOversample
                pause(moveOversampleDt);
                [xOver, yOver] = ReadCursorPosition(taskWindow, inputSource, joy, rz2, xCenter, yCenter, screenXpixels, screenYpixels, pointer_offset, joyGain);
                sampleTime = GetSecs();   % same convention as the base row above: stamp at this sample's own read
                trajN = trajN + 1;
                if trajN > size(trajBuf, 1)
                    trajBuf(end + trajChunk, 9) = 0;   % grow in one chunk
                end
                trajBuf(trajN, :) = [total_trials, (sampleTime - sessionT0) * 1000, xOver, yOver, nextEpoch.Value, trajBlockNum, trajTrialNumInBlock, stimAttempt, NaN];
            end
        end
        [~, stimOnsetTime] = Screen('AsyncFlipEnd', taskWindow);

        % Target onset = the instant the targets actually became VISIBLE, not
        % the instant the state machine decided to show them. placeTargets()
        % deliberately does not stamp t.targetOnset itself: it only raises
        % awaitTargetOnset, and the first flip that carries the targets to
        % the screen (this one; targetOn was already set when the frame
        % above was drawn) is what stamps it. Stamping at decision time
        % would overestimate DecisionTime_s by up to a full frame (~16.7 ms
        % at 60 Hz), because the targets are still one flip away from being
        % on screen.
        %
        % StimulusOnsetTime (2nd output), not VBLTimestamp: it is PTB's
        % estimate of true perceptual onset. On this rig's LCD the two
        % coincide, but the distinction is free here and stays correct on a
        % CRT. It comes off the same GetSecs clock as every trajectory row,
        % so DecisionTime_s and Time_ms remain directly comparable.
        %
        % Placed before the state machine below on purpose: the frame that
        % first draws the targets is also the frame EP.DECISION_TIME first runs,
        % so t.targetOnset is already valid when DECISION_TIME reads it; there
        % is never an iteration where it is still 0.
        if awaitTargetOnset
            t.targetOnset    = stimOnsetTime;
            awaitTargetOnset = 0;
        end
    end

    % Target hit-tests are only meaningful once targets are up
    if nextEpoch == EP.DECISION_TIME || nextEpoch == EP.MOVEMENT
        inTarget = [0 0 0];
        for k = 1:curNumCat, inTarget(k) = CheckInTargetCenterOut(x, y, tarPos{k}); end
    end

    % --- Console "Abort" button: Polled every frame, same as the keyboard.
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
                    Screen('DrawLines', taskWindow, FixPoint, 4, white_c, [xCenter yCenter], 2);
                    Screen('FrameOval', taskWindow, centerWaitColor, centerCircle, [], 4, 4);
                    t.holdFlip = Screen('Flip', taskWindow);
                    setOnce_Hold = 0;
                    targetOn(1) = 0;  targetOn(2) = 0;  showCursor = 1;
                end
                nextEpoch = EP.HOLD_START;
            end

        case EP.HOLD_START
            if inCenterCircle
                total_trials = total_trials + 1;
                grp = trialCatIndices(trial_sequence_index);   % category (1-3)
                total_trials_grp(grp) = total_trials_grp(grp) + 1;
                % Session clock starts at the FIRST hold and is never reset
                % (see sessionHoldT0 above). trigTime, not GetSecs(), for
                % the same reason t.centerHold uses it below.
                if isempty(sessionHoldT0)
                    sessionHoldT0 = trigTime;
                end
                % trigTime, not GetSecs(): entry to the centre was detected
                % from THIS frame's sample, so the hold timer starts at the
                % instant the cursor was MEASURED inside, matching every
                % other sample-derived stamp in this loop and CenterInTask.m's
                % t.centerHold.
                %
                % Unlike CenterInTask.m's, this marker is not logged, it
                % only anchors the holdTime window below. The change is
                % therefore a timing change, not a measurement change: within
                % a frame trigTime is read after this_time, so the hold now
                % ends a fraction of a millisecond later than before. That is
                % orders of magnitude below the +/- holdTimeDelta jitter the
                % hold is drawn with, and it buys a single, consistent
                % convention across both engines instead of one marker
                % quietly following a different rule.
                t.centerHold = trigTime;
                nextEpoch = EP.HOLD;
            end

        case EP.HOLD
            centerHoldColor = green_c;
            if this_time > t.centerHold + holdTime && inCenterCircle
                lenIdx = trialBarIndices(trial_sequence_index);   % length (1-12)
                grp    = trialCatIndices(trial_sequence_index);   % category (1-3)
                currentBarWidth   = allBarSizes(lenIdx);          % width from length
                currentBarHeight  = barHeight_default;
                currentBarOffsetY = barOffsetY_default;
                if trialNumCat(trial_sequence_index) == 2
                    curColorArray = colorArray2Cat;
                else
                    curColorArray = colorArray3Cat;
                end
                currentColor = curColorArray(grp, :) * barColorIntensity + white_c * (1 - barColorIntensity);
                % Bar geometry is fixed for the rest of the trial: build it once.
                barRect = [xCenter - currentBarWidth/2, yCenter + currentBarOffsetY - currentBarHeight/2, ...
                        xCenter + currentBarWidth/2, yCenter + currentBarOffsetY + currentBarHeight/2];
                BarOn = 1;
                t.barOnset = GetSecs();
                nextEpoch = EP.BAR;
            elseif this_time < t.centerHold + holdTime && ~inCenterCircle
                [nextEpoch, t, error_type] = earlyExit(EP, t, trigTime);
            end

        case EP.BAR
            if this_time < t.barOnset + barDuration && ~inCenterCircle
                [nextEpoch, t, error_type] = earlyExit(EP, t, trigTime);
            elseif this_time >= t.barOnset + barDuration && inCenterCircle
                if barStaysVisible == 0, BarOn = 0; end
                if delayStimToRule > 0   % delay 1: stimulus -> rule
                    t.barEnd = GetSecs();
                    nextEpoch = EP.STIM_DELAY;
                else
                    showCue = useCue;
                    t.cueOnset = GetSecs();
                    nextEpoch = EP.CUE;
                end
            end

        case EP.STIM_DELAY   % hold the centre through the stimulus->rule delay
            if this_time < t.barEnd + delayStimToRule && ~inCenterCircle
                [nextEpoch, t, error_type] = earlyExit(EP, t, trigTime);
            elseif this_time >= t.barEnd + delayStimToRule && inCenterCircle
                showCue = useCue;
                t.cueOnset = GetSecs();
                nextEpoch = EP.CUE;
            end

        case EP.CUE
            if this_time < t.cueOnset + cueDuration && ~inCenterCircle
                [nextEpoch, t, error_type] = earlyExit(EP, t, trigTime);
            elseif this_time >= t.cueOnset + cueDuration && inCenterCircle
                showCue = 0;
                t.cueEnd = GetSecs();
                if barToTargetDelay > 0
                    nextEpoch = EP.CUE_DELAY;
                else
                    [tarPos, tarColor, correctTarget, current_trial_color, ...
                        current_trial_direction, centerCueColor, curNumCat, targetOn] = placeTargets( ...
                        trial_sequence_index, trialNumCat, trialDirs, trialColorRows, ...
                        trialCorrectSlot, trialCatIndices, colorArray2Cat, colorArray3Cat, Targets4Dir);
                    awaitTargetOnset = 1;   % stamped by the next flip, not here
                    nextEpoch = EP.DECISION_TIME;
                end
            end

        case EP.CUE_DELAY
            if this_time < t.cueEnd + barToTargetDelay && ~inCenterCircle
                [nextEpoch, t, error_type] = earlyExit(EP, t, trigTime);
            elseif this_time > t.cueEnd + barToTargetDelay && inCenterCircle
                [tarPos, tarColor, correctTarget, current_trial_color, ...
                    current_trial_direction, centerCueColor, curNumCat, targetOn] = placeTargets( ...
                    trial_sequence_index, trialNumCat, trialDirs, trialColorRows, ...
                    trialCorrectSlot, trialCatIndices, colorArray2Cat, colorArray3Cat, Targets4Dir);
                awaitTargetOnset = 1;   % stamped by the next flip, not here
                nextEpoch = EP.DECISION_TIME;
            end

        case EP.DECISION_TIME
            % Safety net only: t.targetOnset is normally already stamped by
            % the flip in the render block above, on this very frame. It can
            % only still be pending if that flip did not run at all (i.e.
            % showCursor was off), in which case anchor the timeout on this
            % frame's sample rather than leave targetDuration measured from
            % 0, which would fire the timeout instantly.
            if awaitTargetOnset
                t.targetOnset    = trigTime;
                awaitTargetOnset = 0;
            end
            if this_time <= t.targetOnset + maxDecisionTime
                if ~inCenterCircle && ~t.leaveCenter
                    % trigTime, not GetSecs(): the exit was detected from
                    % THIS frame's sample, which was read before the render
                    % and the oversample burst. GetSecs() here would be up
                    % to a frame later than the position it describes.
                    t.leaveCenter = trigTime;
                    % Re-tag the sample that detected the exit (and the
                    % oversampled rows taken after it, all already outside
                    % the centre) as MOVEMENT. Without this the epoch
                    % label lands one frame late: the triggering sample
                    % stays DECISION_TIME and the first MOVEMENT row is the next
                    % frame's, putting MoveTime_ms == 0 a frame behind
                    % t.leaveCenter. Re-tagging also puts the real first
                    % point of the movement into the export, which it was
                    % previously missing.
                    trajBuf(trigRowIdx:trajN, 5) = EP.MOVEMENT.Value;
                    nextEpoch = EP.MOVEMENT;
                end
            elseif inCenterCircle
                nextEpoch = EP.ERROR_FB;  error_type = 1;
            end

        case EP.MOVEMENT
            % Ventana de movimiento vigente en ESTE frame.
            withinWindow = this_time <= t.leaveCenter + maxExecutionTime;

            % --- Diagnostico: entrada a un foil por FLANCO (no por frame) ---
            % Solo cuenta; no cambia el estado ni penaliza. En modo indulgente
            % el sujeto puede tocar varios foils antes de acertar.
            inFoilNow = any(inTarget) && ~inTarget(correctTarget);
            if forgiveFoils && inFoilNow && ~wasInFoil && withinWindow
                % Cada ENTRADA nueva a un foil (por flanco) cuenta como un error
                % de target equivocado. El ensayo NO se aborta: el mismo estimulo
                % se queda y el sujeto sigue hasta el target correcto (o hasta que
                % expire targetDuration). Como el estimulo no cambia, cada
                % reentrada al foil vuelve a contar aqui como otro error.
                foilTouches = foilTouches + 1;
                error_wrong_target = error_wrong_target + 1;
                if current_trial_color >= 1
                    foilTouches_grp(current_trial_color) = foilTouches_grp(current_trial_color) + 1;
                    error_wrong_grp(current_trial_color) = error_wrong_grp(current_trial_color) + 1;
                end
                % Flash SOLO si el checkbox "Show error flash" esta activado. Se
                % re-arma en cada entrada (por eso "se reinicia"): un flash
                % transitorio que NO aborta el ensayo (ver el bloque de Render).
                % Con el checkbox apagado, el error se cuenta igual pero sin flash.
                if showErrorFlash
                    foilFlashStart = this_time;
                    foilFlashUntil = this_time + tarErrorFeed;
                end
                % Registro por-entrada: qué foil se tocó y cuándo, bufferizado
                % en memoria (sin I/O de disco aquí). Se vuelca en BOOKKEEP.
                foilK = find(inTarget, 1);   % el slot del foil entrado (inTarget del correcto es falso aquí)
                nFoilPending = nFoilPending + 1;
                foilEventBuf(nFoilPending, :) = [trajBlockNum, trajTrialNumInBlock, stimAttempt, ...
                    current_trial_color, trialColorRows(trial_sequence_index, foilK), ...
                    current_trial_direction, trialDirs(trial_sequence_index, foilK), ...
                    trialBarIndices(trial_sequence_index), this_time - t.targetOnset];
            end
            wasInFoil = inFoilNow;

            if withinWindow
                if inTarget(correctTarget)
                    if ~t.reachTarget
                        % trigTime for the same reason as t.leaveCenter
                        % above: inTarget was hit-tested against THIS
                        % frame's sample. Both ends of executionTime are now
                        % sample timestamps, so the interval matches what
                        % the trajectory files show instead of carrying a
                        % frame of state-machine latency at each end.
                        t.reachTarget = trigTime;
                        decisionTime  = t.leaveCenter - t.targetOnset;   % target-onset -> leave-center
                        executionTime  = t.reachTarget - t.leaveCenter;   % leave-center -> reach-target
                        chosen_target_color = trialColorRows(trial_sequence_index, correctTarget);
                        chosen_target_direction = trialDirs(trial_sequence_index, correctTarget);
                        if current_trial_color > 0 && current_trial_direction > 0
                            % This cell holds decisionTime (target-onset ->
                            % leave-center), and is named for it. An older
                            % generation gave it a name suggesting the whole
                            % stimulus-to-completion interval, which collided
                            % with the CSV's own TotalTime_s (the TOTAL) -- the
                            % tables, the perf_*.mat fields and the
                            % SessionReport labels are now all named after the
                            % interval they actually carry.
                            decision_times{current_trial_color, current_trial_direction}(end+1) = decisionTime;
                            total_trials_matrix(current_trial_color, current_trial_direction) = ...
                                total_trials_matrix(current_trial_color, current_trial_direction) + 1;
                            % Same tally, one resolution finer: bar LENGTH
                            % instead of the category it belongs to (see
                            % the *_lenpos block where these are declared).
                            lenIdxNow = trialBarIndices(trial_sequence_index);
                            decision_times_lenpos{lenIdxNow, current_trial_direction}(end+1) = decisionTime;
                            total_trials_lenpos(lenIdxNow, current_trial_direction) = ...
                                total_trials_lenpos(lenIdxNow, current_trial_direction) + 1;
                        end
                        nextEpoch = EP.TARGET_HOLD;
                    end
                elseif any(inTarget)   % a wrong-colour target was entered
                    if forgiveFoils
                        % ENTRENAMIENTO INDULGENTE: el foil NO aborta ni cuenta
                        % como error. Sin cambio de epoca: el ensayo permanece
                        % en EP.MOVEMENT y el sujeto puede seguir hasta el
                        % target correcto (o hasta que expire targetDuration,
                        % gestionado por la rama ~withinWindow de abajo). El
                        % tanteo ya quedo contabilizado por flanco arriba.
                    else
                        % Conducta original: elegir un target de color incorrecto
                        % es un wrong-target error (error_type = 2, con flash).
                        wrongK = find(inTarget, 1);
                        executionTime = trigTime - t.leaveCenter;   % leave-center -> reach-target (wrong one)
                        chosen_target_color = trialColorRows(trial_sequence_index, wrongK);
                        chosen_target_direction = trialDirs(trial_sequence_index, wrongK);
                        if current_trial_color > 0 && current_trial_direction > 0
                            cell_n = total_trials_matrix(current_trial_color, current_trial_direction);
                            if cell_n == 0 || (cell_n > 0 && error_type == 0)
                                total_trials_matrix(current_trial_color, current_trial_direction) = cell_n + 1;
                                % Counted under the SAME condition as the line
                                % above, not independently, so the per-length
                                % table can never disagree with the per-category
                                % one it refines.
                                lenIdxNow = trialBarIndices(trial_sequence_index);
                                total_trials_lenpos(lenIdxNow, current_trial_direction) = ...
                                    total_trials_lenpos(lenIdxNow, current_trial_direction) + 1;
                            end
                        end
                        nextEpoch = EP.ERROR_FB;  error_type = 2;
                    end
                end
            elseif ~withinWindow
                % Expiro targetDuration sin alcanzar el target correcto. Se
                % cierra como error_type = 1. A diferencia del original, esto
                % dispara AUNQUE el cursor este dentro de un foil: en modo
                % indulgente el foil ya no genera transicion, asi que la
                % ventana es lo unico que garantiza el fin del ensayo.
                nextEpoch = EP.ERROR_FB;  error_type = 1;
            end

        case EP.TARGET_HOLD
            % Tres modos. Los dos primeros son ESTRICTOS y comparten la misma
            % logica (hold continuo desde t.reachTarget); solo cambia con que
            % codigo de error cierran el ensayo:
            %
            % strictTraining = true (PRE-ENTRENAMIENTO, "Training error flash").
            %   Tiene PRIORIDAD sobre strictHold. Salir del target correcto
            %   antes de completar minTarHoldTime cierra como error_type = 3
            %   (hold-break) CON flash, y se cuenta en error_holdbreak, aparte
            %   de los early exits. Solo puede darse con trainingPhase > 0.
            %
            % strictHold = true (ESTRICTO): el cursor debe permanecer DENTRO del
            %   target correcto minTarHoldTime CONTINUOS desde el primer contacto
            %   (t.reachTarget). Salir aunque sea una vez ABORTA el ensayo como
            %   salida temprana (error_type = 1, sin reward, sin flash); no hay
            %   segunda oportunidad en el mismo ensayo.
            %
            % Ambos = false (INDULGENTE, default): salir del target NO aborta;
            %   solo REINICIA el conteo (t.holdStart), y el sujeto puede volver al
            %   target y, si se queda minTarHoldTime seguidos, IGUAL cobra reward.
            %   Acotado por la ventana de movimiento (t.leaveCenter +
            %   maxExecutionTime): si no logra un hold limpio dentro de ella,
            %   cierra sin reward (error_type = 1).
            %
            % En los TRES casos, al cerrar por fallo de hold se resetea
            % chosen_target_color/direction a 0. Para error_type 1 eso conserva la
            % invariante "early exit => sin eleccion de categoria". Para el
            % hold-break (3) es una decision deliberada: el sujeto SI llego al
            % target correcto, pero el ensayo no se resolvio como una eleccion, y
            % contarlo en la diagonal de la matriz de confusion romperia la
            % igualdad diagonal == good_trials. No se pierde informacion: un
            % ErrorType = 3 en el CSV ya dice, por si solo, que el target
            % alcanzado era el correcto (y DirectionCorrect dice cual era).
            if strictTraining || strictHold
                if ~inTarget(correctTarget)
                    chosen_target_color = 0;
                    chosen_target_direction = 0;
                    nextEpoch = EP.ERROR_FB;
                    if strictTraining
                        error_type = 3;   % hold-break (pre-entrenamiento, con flash)
                    else
                        error_type = 1;   % early exit (sin flash)
                    end
                elseif this_time > t.reachTarget + minTarHoldTime
                    t.reward = GetSecs();
                    reward = rewTime;
                    nextEpoch = EP.REWARD;
                end
            else
                rewarded = false;
                if inTarget(correctTarget)
                    if ~t.holdStart
                        t.holdStart = this_time;   % ancla al (re)ingreso al target
                    end
                    if this_time >= t.holdStart + minTarHoldTime
                        t.reward = GetSecs();
                        reward = rewTime;
                        nextEpoch = EP.REWARD;
                        rewarded = true;
                    end
                else
                    t.holdStart = 0;   % salir reinicia el conteo (sin abortar)
                end
                if ~rewarded && this_time > t.leaveCenter + maxExecutionTime
                    chosen_target_color = 0;
                    chosen_target_direction = 0;
                    nextEpoch = EP.ERROR_FB;  error_type = 1;
                end
            end

        case EP.REWARD
            t.reward = GetSecs();
            rewardSecTask    = rewardSecTask + Rewards(reward, 1, uSynapse);
            rewardPulsesTask = rewardPulsesTask + 1;
            good_trials = good_trials + 1;
            good_trial = 1;
            if current_trial_color > 0 && current_trial_direction > 0
                correct_trials_matrix(current_trial_color, current_trial_direction) = ...
                    correct_trials_matrix(current_trial_color, current_trial_direction) + 1;
                good_trials_grp(current_trial_color) = good_trials_grp(current_trial_color) + 1;
                correct_trials_lenpos(trialBarIndices(trial_sequence_index), current_trial_direction) = ...
                    correct_trials_lenpos(trialBarIndices(trial_sequence_index), current_trial_direction) + 1;
            end
            lenIdx = trialBarIndices(trial_sequence_index);
            posIdx = trialPositions(trial_sequence_index);
            % good_trials_lenpos is credited when THIS success genuinely
            % verifies the (bar, position) combination at its scheduled,
            % un-reshuffled position; i.e. stimAttempt == 1 (succeeded on
            % the very first try, before any retry reshuffle ever moved the
            % correct target); regardless of whether this is an original
            % slot or an already-requeued repeat. It is ALSO credited
            % whenever isRequeuedSlot is true even if stimAttempt > 1: this
            % is the one guaranteed repeat (see the queue-branch below and
            % EP.ERROR_FB), there is no second repeat to chase, so its
            % outcome (however it resolved) is accepted as final.
            %
            % The one case that is NOT credited here: an ORIGINAL slot
            % (isRequeuedSlot false) that needed a retry to succeed
            % (stimAttempt > 1); the retry reshuffle means this success
            % may be at a DIFFERENT screen position than the one this slot
            % was actually scheduled to balance, so it does not verify THIS
            % combination specifically. That case queues exactly ONE clean,
            % un-reshuffled repeat of itself at the end of the sequence
            % instead (see the else branch), and THAT repeat's own outcome
            % is what gets credited when it resolves.
            %
            % With requeue switched off (orgParams.useRequeue false) the
            % credit is unconditional: deferring it needs a repeat to defer
            % it TO, and there is none, so a retry-success would otherwise
            % credit nothing and queue nothing, leaving that combination
            % permanently short of its quota and the session unable to end.
            % (Requeue off normally travels with retries off, in which case
            % stimAttempt is always 1 and this changes nothing at all; it
            % matters only if an operator unchecks requeue alone.)
            if stimAttempt == 1 || isRequeuedSlot(trial_sequence_index) || ~useRequeue
                good_trials_lenpos(lenIdx, posIdx) = good_trials_lenpos(lenIdx, posIdx) + 1;
                % < 3, not == 2, so a training phase-1 trial (1 target) is
                % not filed under the 3-category framing it never used.
                if trialNumCat(trial_sequence_index) < 3
                    good_trials_lenpos_2cat(lenIdx, posIdx) = good_trials_lenpos_2cat(lenIdx, posIdx) + 1;
                else
                    good_trials_lenpos_3cat(lenIdx, posIdx) = good_trials_lenpos_3cat(lenIdx, posIdx) + 1;
                end
            else
                ncRequeue = trialNumCat(trial_sequence_index);
                [catRowsRequeue, trueCatRequeue] = CategoriesForTrial(ncRequeue, lenIdx, ...
                    trainingPhase, lengthCategory, lengthCat2, colorRows2, colorRows3);
                [slotDirRequeue, slotColRequeue, correctSlotRequeue] = ...
                    layoutForTrial(fixedTargetLayout, catDirMap, ncRequeue, trueCatRequeue, catRowsRequeue, posIdx);

                seqSize = seqSize + 1;
                trialBarIndices(seqSize)              = lenIdx;
                trialPositions(seqSize)                = posIdx;
                trialNumCat(seqSize)                   = ncRequeue;
                trialDirs(seqSize, 1:ncRequeue)        = slotDirRequeue;
                trialColorRows(seqSize, 1:ncRequeue)   = slotColRequeue;
                trialCorrectSlot(seqSize)              = correctSlotRequeue;
                trialCatIndices(seqSize)               = trueCatRequeue;
                isRequeuedSlot(seqSize)                = true;
                requeuedTrials                         = requeuedTrials + 1;   % session budget grew by one trial
                fprintf('Trial %d (length %d, position %s) only succeeded after a reshuffled retry (attempt %d) -- requeued at slot %d for a clean, unshuffled verification.\n', ...
                    trial_sequence_index, lenIdx, directionNames_log{posIdx}, stimAttempt, seqSize);
            end
            updatePointer = 0;
            nextEpoch = EP.SUCCESS_FB;

        case EP.SUCCESS_FB
            if this_time > t.reward + tarHoldFeed
                targetOn = [0 0 0];  BarOn = 0;  showCue = 0;  showCursor = 0;
                t.blank = BlankScreen(taskWindow, black_c);
                nextEpoch = EP.ITI;
            end

        case EP.ERROR_FB
            good_trial = 0;  repeat_trial = stimAttempt < maxStimAttempts;
            if ~t.marker
                t.marker = GetSecs();
                if error_type == 1
                    error_early_exit = error_early_exit + 1;
                    if current_trial_color >= 1
                        error_early_grp(current_trial_color) = error_early_grp(current_trial_color) + 1;
                    end
                elseif error_type == 2
                    error_wrong_target = error_wrong_target + 1;
                    if current_trial_color >= 1
                        error_wrong_grp(current_trial_color) = error_wrong_grp(current_trial_color) + 1;
                    end
                elseif error_type == 3
                    % Hold-break: llego al target CORRECTO y lo solto antes de
                    % completar minTarHoldTime. Solo se produce bajo
                    % strictTraining (pre-entrenamiento); contador propio para
                    % que no se diluya entre los early exits, que es de lo que
                    % se trataba separarlo.
                    error_holdbreak = error_holdbreak + 1;
                    if current_trial_color >= 1
                        error_holdbreak_grp(current_trial_color) = error_holdbreak_grp(current_trial_color) + 1;
                    end
                end

                % Requeue exhausted trial: the FAILURE-side mirror of
                % EP.REWARD's requeue (see its comments), every original
                % presentation queues exactly one clean, un-reshuffled
                % repeat of itself, whether it just succeeded (EP.REWARD) or,
                % as here, exhausted every attempt up to maxStimAttempts
                % without succeeding and is about to be abandoned
                % (repeat_trial is false, so the trial-start block will move
                % on to the next slot). Give it exactly one more shot, fresh
                % (not marked as a retry; full maxStimAttempts again, and
                % NOT reshuffled: same bar length, same originally planned
                % position, same category count), appended at the end of the
                % sequence.
                %
                % isRequeuedSlot normally prevents this from firing twice for
                % the SAME original combination (a requeued slot that also
                % fails is not requeued again; see EP.REWARD for where
                % good_trials_lenpos is actually credited, only from this
                % guaranteed repeat's own eventual outcome); EXCEPT when the
                % requeued slot's own exhaustion was itself due to early exits
                % (error_type == 1) or hold-breaks (error_type == 3), never a
                % deliberate wrong-target pick: neither is a genuine attempt at
                % the CATEGORY, so neither should be what finally closes the
                % combination out (a hold-break in particular means the subject
                % got the category right and only failed to hold). In those
                % cases keep chaining fresh requeues indefinitely; only an
                % exhaustion caused by a wrong-target error (error_type == 2)
                % is accepted as this combination's final outcome once it has
                % already had its one guaranteed clean repeat.
                %
                % Skipped entirely when orgParams.useRequeue is false: the
                % trial's failure is then simply this combination's outcome
                % and the sequence moves on, so the session never grows past
                % the trials it planned (see the mirror in EP.REWARD).
                if useRequeue && ~repeat_trial && (~isRequeuedSlot(trial_sequence_index) || error_type == 1 || error_type == 3)
                    lenIdxRequeue = trialBarIndices(trial_sequence_index);
                    posIdxRequeue = trialPositions(trial_sequence_index);
                    ncRequeue     = trialNumCat(trial_sequence_index);
                    [catRowsRequeue, trueCatRequeue] = CategoriesForTrial(ncRequeue, lenIdxRequeue, ...
                        trainingPhase, lengthCategory, lengthCat2, colorRows2, colorRows3);
                    [slotDirRequeue, slotColRequeue, correctSlotRequeue] = ...
                        layoutForTrial(fixedTargetLayout, catDirMap, ncRequeue, trueCatRequeue, catRowsRequeue, posIdxRequeue);

                    seqSize = seqSize + 1;
                    trialBarIndices(seqSize)              = lenIdxRequeue;
                    trialPositions(seqSize)                = posIdxRequeue;
                    trialNumCat(seqSize)                   = ncRequeue;
                    trialDirs(seqSize, 1:ncRequeue)        = slotDirRequeue;
                    trialColorRows(seqSize, 1:ncRequeue)   = slotColRequeue;
                    trialCorrectSlot(seqSize)              = correctSlotRequeue;
                    trialCatIndices(seqSize)               = trueCatRequeue;
                    isRequeuedSlot(seqSize)                = true;
                    requeuedTrials                         = requeuedTrials + 1;   % session budget grew by one trial
                    fprintf('Trial %d (length %d, position %s) exhausted %d attempts -- requeued at slot %d for one clean retry.\n', ...
                        trial_sequence_index, lenIdxRequeue, directionNames_log{posIdxRequeue}, maxStimAttempts, seqSize);
                end
            end
            showCursor = 0;
            % Flash policy, by error type:
            %   1 (early exit / timeout) NEVER flashes -- the trial just ends
            %     without reward.
            %   2 (wrong target) flashes in the NORMAL categorization task
            %     (trainingPhase == 0) ALWAYS, because it IS the trial's
            %     response and must be marked. In pre-training it flashes only
            %     if the operator asked for it, via either the "Show error
            %     flash" checkbox (showErrorFlash) or "Training error flash"
            %     (strictTraining, which exists precisely to penalize the foil).
            %   3 (hold-break) ALWAYS flashes: it only ever occurs under
            %     strictTraining, i.e. the operator already asked for the
            %     stricter feedback that produces it.
            flashError = (error_type == 2 && (trainingPhase == 0 || showErrorFlash || strictTraining)) ...
                || error_type == 3;
            if flashError
                if mod(floor((this_time - t.marker) / 0.1), 2) == 0
                    Screen('FillRect', taskWindow, white_c);
                else
                    Screen('FillRect', taskWindow, black_c);
                end
                Screen('Flip', taskWindow);
            else
                BlankScreen(taskWindow, black_c);
            end
            if this_time > t.marker + minTarHoldTime + tarHoldFeed + tarErrorFeed
                targetOn = [0 0 0];  BarOn = 0;  showCue = 0;
                t.blank = BlankScreen(taskWindow, black_c);
                t.marker = 0;
                nextEpoch = EP.ITI;
            end

        case EP.ITI
            BlankScreen(taskWindow, black_c);
            thisITI = ITI_error;
            if good_trial == 1, thisITI = current_ITI; end
            if this_time > t.blank + thisITI && ~t.marker
                BlankScreen(taskWindow, black_c);
                t.marker = GetSecs();
                nextEpoch = EP.BOOKKEEP;
            end

        case EP.BOOKKEEP
            set(orgParams.handles.edit91, 'String', num2str(good_trials));
            set(orgParams.handles.edit92, 'String', num2str(good_trials / total_trials * 100));
            if total_trials > numel(trial_outcomes)
                trial_outcomes(end + bufferBudgetTrials)   = 0;   % grow buffers
                trial_error_type(end + bufferBudgetTrials) = 0;
            end
            trial_outcomes(total_trials)   = good_trial;
            trial_error_type(total_trials) = error_type;

            % Split on trial_sequence_index, not total_trials: a correction
            % retry re-attempts the same sequence slot without advancing it,
            % so this keeps Block pinned to the configured numBlocks instead
            % of rolling over early from retry-inflated total_trials (see the
            % trajectory-buffer comment above). Computed unconditionally
            % (not just for the CSV row below) so the per-block stats right
            % after it stay complete even for early exits that happened
            % before target placement (current_trial_color is still 0 for
            % those; see the CSV gate below).
            blockNum        = floor((trial_sequence_index - 1) / blockSize) + 1;
            trialNumInBlock = mod(trial_sequence_index - 1, blockSize) + 1;

            % --- Per-block statistics (Level 1 report; see blockStats above).
            % grp/nc come straight from the pseudorandom sequence
            % (trialCatIndices/trialNumCat), not from current_trial_color, so
            % this tallies correctly under sessionMode = 'alternate' (2-cat/
            % 3-cat segments that don't line up with blockSize boundaries)
            % and 'interleaved' (2-cat/3-cat chosen per trial): each block
            % just accumulates whatever mix of category counts actually ran.
            if blockNum > numel(blockStats)
                blockStats(end + 1 : blockNum) = blockStatsTemplate;   % grow on demand
            end
            numBlocksUsed = max(numBlocksUsed, blockNum);
            blkGrp = trialCatIndices(trial_sequence_index);
            blkNc  = trialNumCat(trial_sequence_index);
            blockStats(blockNum).total = blockStats(blockNum).total + 1;
            blockStats(blockNum).totalGrp(blkGrp) = blockStats(blockNum).totalGrp(blkGrp) + 1;
            if blkNc < 3   % see good_trials_lenpos_2cat above for why < 3, not == 2
                blockStats(blockNum).nCat2 = blockStats(blockNum).nCat2 + 1;
            else
                blockStats(blockNum).nCat3 = blockStats(blockNum).nCat3 + 1;
            end
            if good_trial
                blockStats(blockNum).good = blockStats(blockNum).good + 1;
                blockStats(blockNum).goodGrp(blkGrp) = blockStats(blockNum).goodGrp(blkGrp) + 1;
            elseif error_type == 1
                blockStats(blockNum).errorEarly = blockStats(blockNum).errorEarly + 1;
            elseif error_type == 2
                blockStats(blockNum).errorWrong = blockStats(blockNum).errorWrong + 1;
            elseif error_type == 3
                blockStats(blockNum).errorHoldbreak = blockStats(blockNum).errorHoldbreak + 1;
            end

            % --- Confusion matrix (true category = blkGrp above, chosen
            % category = chosen_target_color, which is already the category
            % 1-3 of whichever target got entered; see ColorCategoryMap.m
            % and the MOVEMENT epoch above; no separate colour->category
            % table to keep in sync here). Only tallied when a target was
            % actually entered; an early exit (-1, never entered any target)
            % has no "chosen category" to record, so it's excluded (see
            % confusionMat above).
            if chosen_target_color >= 1
                confusionMat(blkGrp, chosen_target_color) = confusionMat(blkGrp, chosen_target_color) + 1;
            end

            if current_trial_color > 0 && current_trial_direction > 0
                if t.targetOnset > 0 && t.leaveCenter > 0
                    decisionTime = t.leaveCenter - t.targetOnset;
                end
                if ~isnan(decisionTime) && ~isnan(executionTime)
                    totalTime = decisionTime + executionTime;   % total stimulus-to-completion time
                end
                barVA_log = target_angles(trialBarIndices(trial_sequence_index));
                if chosen_target_direction >= 1
                    dirChosenStr = directionNames_log{chosen_target_direction};
                else
                    dirChosenStr = 'None';   % no target entered (early exit)
                end
                % PlannedDirection: the ORIGINALLY planned position for this
                % sequence slot (trialPositions, unaffected by a correction
                % retry's in-place reshuffle); see the CSV header comment
                % above for why this sits alongside DirectionCorrect (this
                % attempt's actual shown position) instead of replacing it.
                plannedDirForLog = directionNames_log{trialPositions(trial_sequence_index)};
                % Column order is Date,...,DecisionTime,ExecutionTime,TotalTime --
                % the same three intervals in the same positions v2_2-era
                % files use; only the third column's header differs (see the
                % pooling note where these are initialised):
                %   DecisionTime_s  = decisionTime  (target-onset -> leave-center)
                %   ExecutionTime_s = executionTime (leave-center -> reach-target)
                %   TotalTime_s     = totalTime     (decision + execution, i.e.
                %                     target-onset -> reach-target)
                % NOTE for the analysis side: ExecutionTime_s is filled in as
                % soon as a target is entered, so a row with ErrorType == 1 and
                % a non-NaN ExecutionTime_s is a lenient hold failure on the
                % CORRECT target. Under strictTraining that same event is
                % labelled explicitly instead, as ErrorType == 3.
                %
                % NumCategories = THIS trial's own category count (1 in
                % training phase 1, 2 in phase 2 or a 2-cat trial, else 3),
                % taken from blkNc above rather than recomputed. SessionMode is
                % the session-level string, repeated on every row. Both exist
                % because sessionMode 'alternate'/'interleaved' MIX 2-cat and
                % 3-cat trials within one file, and the 2-cat and 3-cat tasks
                % use DIFFERENT length->category splits (lengthCat2 vs
                % lengthCategory), so without these two columns a pooled
                % analysis cannot tell which regime produced a given row.
                fid_log = fopen(trialLogFile, 'a');
                fprintf(fid_log, '%s,%d,%d,%s,%.2f,%.4f,%.4f,%.4f,%d,%d,%s,%s,%s,%d,%d,%s,%d,%d,%s\n', ...
                    sessionDate, blockNum, trialNumInBlock, colorNames_log{current_trial_color}, ...
                    barVA_log, decisionTime, executionTime, totalTime, good_trial, error_type, ...
                    dirChosenStr, directionNames_log{current_trial_direction}, plannedDirForLog, chosen_target_color, ...
                    prevTrialCorrect, prevTrialDirection, stimAttempt, blkNc, sessionMode);
                fclose(fid_log);
                prevTrialCorrect   = good_trial;
                prevTrialDirection = dirChosenStr;
            end

            % Flush this trial's buffered foil entries (one row per entry) to
            % foil_events_<runTag>.csv. Done here in BOOKKEEP, not inside the
            % tracking loop, so no disk I/O ever hits the real-time cursor path.
            if forgiveFoils && nFoilPending > 0
                nFoilPending = flushFoilBuffer(foilEventsLogFile, foilEventBuf, nFoilPending, ...
                    sessionDate, colorNames_log, directionNames_log, target_angles);
                foilEventBuf = zeros(0, 9);
            end

            % Refresh what the quota counts, for THIS trial, before testing
            % it. Presentations are credited here rather than at EP.REWARD
            % because this is the one place every resolved trial passes
            % through, correct or not, which is the whole point of the
            % mode. The cell credited is the one the slot was SCHEDULED to
            % balance (trialBarIndices/trialPositions), not the position a
            % retry reshuffle may have moved the target to, so the table
            % stays comparable with good_trials_lenpos.
            if quotaByPresentations
                quota_lenpos(trialBarIndices(trial_sequence_index), ...
                             trialPositions(trial_sequence_index)) = ...
                    quota_lenpos(trialBarIndices(trial_sequence_index), ...
                                 trialPositions(trial_sequence_index)) + 1;
            else
                quota_lenpos = good_trials_lenpos;
            end

            % Repaint the progress readouts with the outcome of the trial
            % that just CLOSED, not only at the start of the next one.
            % Painting only at trial start meant the last trial of a session
            % never got a repaint (there is no next trial) so the status
            % line's last state was always "1 correct left" and the console
            % appeared to jump straight from unfinished to "Task done". The
            % counter now reaches 0 on screen before the loop exits.
            paintProgressStatus(orgParams.handles, trial_sequence_index, ...
                plannedTrials + requeuedTrials, plannedBlocks, blockSize, ...
                stimAttempt, maxStimAttempts, quotaRemaining(quota_lenpos), quotaNoun);
            paintProgressBreakdown(orgParams.handles, trial_sequence_index, ...
                plannedTrials + requeuedTrials, plannedBlocks, blockSize, seqSize, ...
                trialNumCat, quota_lenpos, minPerLength, lengthCategory, numCategories);

            % Quota check moved here (see the while-loop header comment
            % above) so it fires only after THIS trial's row is fully
            % written to trial_outcomes/trial_data_*.csv, never mid-trial,
            % right after the REWARD that satisfies the last cell.
            if ~any(quota_lenpos(:) < minPerLength)
                exitFlag = 1;
            end

            setOnce_Trial = 1;
            pause(flipInterval);
            nextEpoch = EP.ENTER_CENTER;
    end

    % --- Pause handling ---
    % PauseLoop blocks until the operator resumes; its sentinel return value
    % is not a TaskEpoch, so it is intentionally discarded here rather than
    % assigned to nextEpoch; the trial simply resumes at whichever epoch
    % was already active before the pause, with nothing else to restore.
    if pauseTask == 1
        PauseLoop(taskWindow, black_c, orgParams, kbDevice, useKbQueue, KEY_SPACE);
        pauseTask = 0;
        % A pause blocks this loop for an unbounded time while the relay
        % keeps streaming; same backlog problem as session start, so drop
        % it the same way rather than making the next frames chew through a
        % pause's worth of samples the subject never produced.
        if useRZ2
            FlushRZ2Joystick(rz2);
        end
    end
end % trial loop

% Stop the session clock HERE, not further down: everything below is
% teardown (closing the window, aggregating, printing, saving) and none of
% it is time the subject spent on the task. sessionHoldT0 stays empty if no
% trial ever reached the hold, which is reported as such rather than as a
% zero-second session.
if isempty(sessionHoldT0)
    sessionSeconds = [];
else
    sessionSeconds = GetSecs() - sessionHoldT0;
    % Write the final value to the console's live box, which is throttled to
    % ~1/s and would otherwise be left up to a second short of the total the
    % report prints, two different numbers for the same session.
    set(orgParams.handles.textSessionTime, 'String', FormatElapsedTime(sessionSeconds));
end

% Release the fullscreen Psychtoolbox window immediately once the quota is
% met (or the session ends early); the teardown below (save/print) doesn't
% touch taskWindow at all, so leaving the display captured until CloseTask()
% at the very end made it look stuck in Psychtoolbox on macOS for that whole
% stretch. ForceCloseScreen is idempotent; harmless no-op if CloseTask()
% below repeats it, or if the onCleanup-registered call at the top already
% ran (e.g. after an error).
ForceCloseScreen(taskWindow);

% =========================================================================
% TEARDOWN: aggregate, save, report
% =========================================================================
if total_trials > 0, perf = good_trials / total_trials * 100; else, perf = 0; end

if total_trials == 0
    % Aborted before any trial ran: nothing to aggregate, so skip
    % save/report/plot and just close the devices below. If the
    % recording-link gate was declined, keep that message on screen (more
    % informative than a generic one); abortedByOperator is still false
    % in that case, since it's set only by the in-loop Abort/ESC handlers
    % above, not the pre-loop gate.
    fprintf('No trials run; no session files written.\n');
    % Water can still have been delivered with no completed trial: the
    % operator's 'r' key works from the very first frame, so a session
    % aborted during setup or shaping would otherwise report nothing about
    % what the subject actually drank.
    if rewardPulsesTask + rewardPulsesManual > 0
        SessionReport.reward(rewardPulsesTask, rewardSecTask, ...
            rewardPulsesManual, rewardSecManual, rewardMlPerSec);
    end
    if abortedByClock
        set(orgParams.handles.text77, 'String', 'Stopped: input clock fault');
        set(orgParams.handles.text77, 'ForegroundColor', 'red');
    elseif abortedByOperator
        set(orgParams.handles.text77, 'String', 'Task stopped');
        set(orgParams.handles.text77, 'ForegroundColor', 'red');
    end
else
try
    mean_decision_matrix = nan(3, 4);
    percent_correct_matrix = nan(3, 4);
    for i = 1:3
        for j = 1:4
            if ~isempty(decision_times{i, j})
                mean_decision_matrix(i, j) = mean(decision_times{i, j});
            end
            if total_trials_matrix(i, j) > 0
                percent_correct_matrix(i, j) = ...
                    correct_trials_matrix(i, j) / total_trials_matrix(i, j) * 100;
            end
        end
    end

    % Same two derived matrices at (length x position) resolution, the 48
    % combinations. NaN, not 0, wherever a combination produced no trial to
    % average or divide by: "not measured" and "measured 0%" are different
    % statements, and a session stopped early has plenty of the former.
    mean_decision_lenpos = nan(numLengths, 4);
    percent_correct_lenpos = nan(numLengths, 4);
    for i = 1:numLengths
        for j = 1:4
            if ~isempty(decision_times_lenpos{i, j})
                mean_decision_lenpos(i, j) = mean(decision_times_lenpos{i, j});
            end
            if total_trials_lenpos(i, j) > 0
                percent_correct_lenpos(i, j) = ...
                    correct_trials_lenpos(i, j) / total_trials_lenpos(i, j) * 100;
            end
        end
    end

    S.good_trials = good_trials;            S.total_trials = total_trials;
    % Session duration, measured from the first hold (see sessionHoldT0).
    % Empty when no trial ever reached the hold, kept empty rather than 0
    % so a later analysis can tell "never started" from "instantaneous".
    S.sessionSeconds = sessionSeconds;
    S.error_early_exit = error_early_exit;  S.error_wrong_target = error_wrong_target;
    S.error_holdbreak = error_holdbreak;    S.error_holdbreak_grp = error_holdbreak_grp;
    S.trainingErrorFlash = trainingErrorFlash;  S.strictTraining = strictTraining;
    S.foilTouches = foilTouches;            S.foilTouches_grp = foilTouches_grp;
    S.foilNoAbort = foilNoAbort;            S.forgiveFoils = forgiveFoils;
    S.good_trials_grp = good_trials_grp;    S.total_trials_grp = total_trials_grp;
    S.error_early_grp = error_early_grp;    S.error_wrong_grp = error_wrong_grp;
    S.decision_times = decision_times;
    S.total_trials_matrix = total_trials_matrix;
    S.correct_trials_matrix = correct_trials_matrix;
    S.mean_decision_matrix = mean_decision_matrix;      S.percent_correct_matrix = percent_correct_matrix;
    % Per-(length x position) versions of the four above, plus the bar
    % lengths themselves so a row can be read without the session's params
    % file to hand. The category-level fields are kept alongside them: they
    % cost nothing, and every earlier analysis script that loads perf_*.mat
    % keeps working unchanged.
    S.decision_times_lenpos = decision_times_lenpos;
    S.total_trials_lenpos = total_trials_lenpos;
    S.correct_trials_lenpos = correct_trials_lenpos;
    S.mean_decision_lenpos = mean_decision_lenpos;      S.percent_correct_lenpos = percent_correct_lenpos;
    S.target_angles = target_angles;        S.lengthCategory = lengthCategory;
    S.trial_outcomes = trial_outcomes;      S.trial_error_type = trial_error_type;
    % Water delivered, kept split by source (see SessionReport.reward). Saved
    % as valve-open SECONDS plus the calibration used, rather than only a
    % derived mL figure, so a session recorded before the rig was calibrated
    % -- or recalibrated afterwards; can still be converted later.
    S.rewardPulsesTask = rewardPulsesTask;  S.rewardSecTask   = rewardSecTask;
    S.rewardPulsesManual = rewardPulsesManual;  S.rewardSecManual = rewardSecManual;
    S.rewardMlPerSec = rewardMlPerSec;
    save(fullfile(outDir, ['perf_' d '.mat']), '-struct', 'S');
    fprintf('\nSession data saved to:  %s\n', fullfile(outDir, ['perf_' d '.mat']));

    % Aggregate per-condition CSV, ONE ROW PER (bar length x direction),
    % i.e. the 48 combinations of a full12 session, rather than a 12-row
    % per-category roll-up. The category is still a column (StimulusGroup),
    % so grouping up to 12 rows is one line in any analysis; going the other
    % way, from a roll-up back down to the lengths, is not possible at all,
    % which is why the finer resolution is what gets written. BarLengthIndex
    % indexes the ACTIVE stimulus set (after "Bar set" and any bar subset),
    % and BarSizeVA_deg is that length's own visual angle, not a category
    % mean shared by all four of its lengths.
    csvFile = fullfile(outDir, ['session_data_' d '.csv']);
    fid = fopen(csvFile, 'w');
    fprintf(fid, ['BarLengthIndex,BarSizeVA_deg,StimulusGroup,Direction,' ...
        'CorrectTrials,TotalTrials,PctCorrect_pct\n']);
    for li = 1:numLengths
        for di = 1:4
            fprintf(fid, '%d,%.4f,%s,%s,%d,%d,%.4f\n', ...
                li, target_angles(li), colorNames_log{lengthCategory(li)}, directionNames_log{di}, ...
                correct_trials_lenpos(li, di), total_trials_lenpos(li, di), ...
                percent_correct_lenpos(li, di));
        end
    end
    fclose(fid);
    fprintf('CSV exported to:        %s\n', csvFile);

    % Cursor trajectory (X,Y over time): the MOVEMENT-ONLY export, and only
    % that one. The full multi-epoch export (SaveTrajectory.m, still used by
    % CenterInTask.m) was dropped from this engine on purpose; every
    % analysis this task feeds differentiates the movement epoch, which is
    % exactly the cut written here, and the full file was several times
    % larger for rows (centre hold, cue, ITI) nothing downstream read.
    %
    % What that costs, stated plainly: the pre-movement epochs are no longer
    % recorded anywhere, so trajectory maps of the hold/cue period cannot be
    % made from this session's files afterwards. Put SaveTrajectory back
    % here if that ever becomes wanted; the two are independent peers with
    % the same first five arguments, neither calls the other.
    %
    % Strips the raw TrialNum column itself (trajBuf's column 1, =
    % total_trials): Block/TrialNumInBlock/Attempt (also in
    % trial_data_*.csv) already identify each row uniquely. Rows here match
    % trial_data_*.csv 1:1 on Block+TrialNumInBlock+Attempt, and both files
    % share the runTag/session id via `d`.
    % FULL multi-epoch trajectory (every epoch, every sample) -- always
    % written now, so trajectory maps of the hold/cue/decision period exist
    % alongside the movement-only cut below. The two are independent peers
    % sharing the same runTag `d`; neither calls the other.
    SaveTrajectory(trajBuf, trajN, outDir, d, sessionDate, true, true);
    % Filtered movement cut: DECISION_TIME + MOVEMENT + TARGET_HOLD only
    % (movementExportEpochs). A separate, smaller file for movement analysis,
    % alongside the full export above. Per-trial kinematics are not computed,
    % but this trajectory file is still written.
    SaveMovementTrajectory(trajBuf, trajN, outDir, d, sessionDate, movementExportEpochs);
    % Final flush: foil entries from a last trial that ended (stop key / operator
    % abort) before its BOOKKEEP ran are written here so none are lost.
    if forgiveFoils && nFoilPending > 0
        nFoilPending = flushFoilBuffer(foilEventsLogFile, foilEventBuf, nFoilPending, ...
            sessionDate, colorNames_log, directionNames_log, target_angles);
        foilEventBuf = zeros(0, 9);
    end
catch ME_save
    fprintf('WARNING: error during matrix computation or save: %s\n', ME_save.message);
end

try
    % Two-level report: Level 1 (per block) first, then Level 2 (session =
    % all blocks combined); see blockStats above for why the per-block
    % tally stays correct under sessionMode = 'alternate'/'interleaved'.
    SessionReport.blocks(blockStats(1:numBlocksUsed), sessionMode);
catch ME_blockPrint
    fprintf('WARNING: error during per-block printout: %s\n', ME_blockPrint.message);
end

try
    SessionReport.session(total_trials, good_trials, perf, error_early_exit, ...
        error_wrong_target, total_trials_grp, good_trials_grp, ...
        mean_decision_matrix, percent_correct_matrix, total_trials_matrix, ...
        good_trials_lenpos, good_trials_lenpos_2cat, good_trials_lenpos_3cat, ...
        minPerLength, target_angles, sessionMode, ...
        mean_decision_lenpos, percent_correct_lenpos, total_trials_lenpos, ...
        correct_trials_lenpos, lengthCategory, error_holdbreak);
catch ME_print
    fprintf('WARNING: error during console printout: %s\n', ME_print.message);
end

% --- Resumen de foils indulgentes (solo si el modo estuvo activo) --------
if forgiveFoils
    fprintf(['Foil-forgiving: %d entradas a distractores (no penalizadas). ' ...
        'Por grupo [S M L]: [%d %d %d].\n'], ...
        foilTouches, foilTouches_grp(1), foilTouches_grp(2), foilTouches_grp(3));
end

try
    SessionReport.reward(rewardPulsesTask, rewardSecTask, ...
        rewardPulsesManual, rewardSecManual, rewardMlPerSec);
catch ME_reward
    fprintf('WARNING: error during reward printout: %s\n', ME_reward.message);
end

try
    SessionReport.duration(sessionSeconds, total_trials);
catch ME_duration
    fprintf('WARNING: error during session-time printout: %s\n', ME_duration.message);
end

try
    SessionReport.confusion(confusionMat, sessionMode);
catch ME_confusion
    fprintf('WARNING: error during confusion-matrix printout: %s\n', ME_confusion.message);
end

try
    SessionReport.signalDetection(confusionMat, sessionMode);
catch ME_sdt
    fprintf('WARNING: error during signal-detection printout: %s\n', ME_sdt.message);
end

% Three outcomes, three messages. "Task ended early" is the one that would
% otherwise be invisible: the session stopped because the sequence ran out,
% not because the quota was met, and without its own message the only trace
% would be a line in the log.
if abortedByClock
    set(orgParams.handles.text77, 'String', 'Stopped: input clock fault');
elseif abortedByOperator
    set(orgParams.handles.text77, 'String', 'Task stopped');
elseif endedEarly
    set(orgParams.handles.text77, 'String', sprintf( ...
        'Task ended early -- quota not met (%d %s left)', ...
        quotaRemaining(quota_lenpos), quotaNoun));
else
    set(orgParams.handles.text77, 'String', 'Task done');
end
set(orgParams.handles.text77, 'ForegroundColor', 'red');
end   % total_trials guard

% Printed last, and deliberately while the diary is still on, so the file
% ends by naming itself; an operator who opens the .txt later can see it is
% the complete transcript and not a truncated copy.
fprintf('\nSession report saved to: %s\n', sessionLogFile);

try, CloseTask; catch, end
if useKbQueue, try, KbQueueStop(kbDevice); KbQueueRelease(kbDevice); catch, end, end
if ~isempty(uSynapse)
    SetRZ2RelayEnable(false, uSynapse);   % stop Computer 1's relay along with this session
    fclose(uSynapse);
end
CleanupRZ2Joystick(rz2);   % release port 8831, or the next rz2adc run fails to rebind it
close(orgParams.handles.dlgTrainingMain);

catch ME
    disp(ME.identifier);  disp(ME.message);
    if ~isempty(ME.stack), disp(ME.stack(1)); end
    if numel(ME.stack) > 1, disp(ME.stack(2)); end
    % Salvage the in-memory trajectory buffer on a hard crash: the normal
    % export below the trial loop never runs once execution reaches this
    % catch block, and trajBuf holds the WHOLE session, so without this an uncaught error mid-session loses
    % all of it, not just the current trial.
    if exist('trajBuf', 'var') && exist('trajN', 'var') && trajN > 0 ...
            && exist('outDir', 'var') && exist('d', 'var')
        try
            if exist('sessionDate', 'var'), dateForLog = sessionDate; else, dateForLog = datestr(now, 'dd-mm-yyyy'); end
            % Movement-only, same as the normal exit path above; this
            % engine does not write the full multi-epoch export. The EP
            % guard is the cost of that: EP is built early in SETUP, so a
            % crash before that point (or one that corrupted it) salvages
            % nothing rather than the whole buffer. That window is a handful
            % of setup lines, before any trial has run and therefore before
            % trajBuf holds anything but zeros, which is why the trade is
            % acceptable here.
            % Full multi-epoch export always salvaged; the movement-only cut
            % additionally when the epoch table survived the crash.
            SaveTrajectory(trajBuf, trajN, outDir, d, dateForLog, true, true);
            fprintf('Full trajectory salvaged after crash: %d samples in buffer\n', trajN);
            if exist('EP', 'var') && exist('movementExportEpochs', 'var')
                SaveMovementTrajectory(trajBuf, trajN, outDir, d, dateForLog, movementExportEpochs);
                fprintf('Movement cut salvaged after crash: %d samples in buffer\n', trajN);
            end
        catch
            fprintf('WARNING: could not salvage trajectory after crash.\n');
        end
    end
    % Salvage any buffered foil entries that never reached BOOKKEEP. Guarded by
    % exist() because a crash may predate these variables.
    if exist('forgiveFoils', 'var') && forgiveFoils && exist('nFoilPending', 'var') && nFoilPending > 0 ...
            && exist('foilEventBuf', 'var') && exist('foilEventsLogFile', 'var')
        try
            if exist('sessionDate', 'var'), foilDateForLog = sessionDate; else, foilDateForLog = datestr(now, 'dd-mm-yyyy'); end
            nFoilPending = flushFoilBuffer(foilEventsLogFile, foilEventBuf, nFoilPending, ...
                foilDateForLog, colorNames_log, directionNames_log, target_angles);
            fprintf('Foil-events salvaged after crash.\n');
        catch
            fprintf('WARNING: could not salvage foil events after crash.\n');
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
    try, close(orgParams.handles.dlgTrainingMain); catch, end
end
end % CenterOutTask


% =========================================================================
% LOCAL HELPER FUNCTIONS
% =========================================================================
function n = flushFoilBuffer(logFile, buf, n, sessionDate, colorNames_log, directionNames_log, target_angles)
% Append the first n buffered foil-entry rows of `buf` to `logFile` (append
% mode) and return 0 (buffer considered flushed). No-op when n <= 0. One
% source of truth for both the per-trial flush in BOOKKEEP and the final
% teardown/crash flush, so the row format cannot drift between them.
if n <= 0
    return;
end
fid = fopen(logFile, 'a');
if fid < 0
    return;   % could not open (e.g. path gone); leave n unchanged so a later attempt can retry
end
for fe = 1:n
    r = buf(fe, :);
    grpIx = r(4);  foilColIx = r(5);  corDir = r(6);  foilDir = r(7);  barIx = r(8);
    if grpIx     >= 1, grpName     = colorNames_log{grpIx};       else, grpName     = 'NA';   end
    if foilColIx >= 1, foilColName = colorNames_log{foilColIx};   else, foilColName = 'NA';   end
    if corDir    >= 1, corDirName  = directionNames_log{corDir};  else, corDirName  = 'None'; end
    if foilDir   >= 1, foilDirName = directionNames_log{foilDir}; else, foilDirName = 'None'; end
    fprintf(fid, '%s,%d,%d,%d,%s,%.2f,%s,%s,%s,%.4f\n', ...
        sessionDate, r(1), r(2), r(3), grpName, target_angles(barIx), ...
        corDirName, foilDirName, foilColName, r(9));
end
fclose(fid);
n = 0;
end

function t = initTimes()
% Named time markers for one trial (replaces the magic-indexed array).
t = struct('holdFlip', 0, 'centerHold', 0, 'barOnset', 0, 'barEnd', 0, ...
        'targetOnset', 0, 'leaveCenter', 0, 'reachTarget', 0, 'reward', 0, ...
        'blank', 0, 'marker', 0, 'cueEnd', 0, 'cueOnset', 0, 'holdStart', 0);
end

function paintProgressStatus(handles, trialIdx, budgetTrials, plannedBlocks, ...
        blockSize, stimAttempt, maxStimAttempts, remaining, quotaNoun)
% Console Status line. Called twice per trial (once as the trial opens and
% once as it closes) so the text lives here rather than at either call
% site, where two copies would drift apart the first time the wording
% changed.
%
% budgetTrials GROWS during a run: every error that forces a clean repeat
% appends a slot (requeuedTrials at the call site), so the denominator
% tracks what the session will actually cost rather than what it would have
% cost had the subject never erred. `remaining` counts the way the stop
% condition counts (per (length, position) combination, capped at
% minPerLength) so it reaches 0 exactly when the run ends, which a raw
% correct-trial total would not.
budgetBlocks = max(plannedBlocks, ceil(budgetTrials / blockSize));
blockNow     = floor((trialIdx - 1) / blockSize) + 1;
if stimAttempt > 1
    retryStr = sprintf(', retry %d/%d', stimAttempt, maxStimAttempts);
else
    retryStr = '';
end
set(handles.text77, 'String', sprintf( ...
    'Task is running -- trial %d/%d (block %d/%d)%s -- %d %s left', ...
    trialIdx, budgetTrials, blockNow, budgetBlocks, retryStr, remaining, quotaNoun));
set(handles.text77, 'ForegroundColor', 'blue');
end

function paintProgressBreakdown(handles, trialIdx, budgetTrials, plannedBlocks, ...
        blockSize, seqSize, trialNumCat, quotaTable, minPerLength, ...
        lengthCategory, numCategories)
% The same "what is left" one level down: where the current block stands,
% and how the trials still owed split across the bar-length categories.
% Shown live rather than only in the end-of-session report, which is too
% late to act on; the operator can see mid-session that (say) Long is
% lagging.
%
% `owed` is the Status line's "N left" before it is summed: per (length,
% position) combination, capped at minPerLength, so the category figures
% always add up to it exactly.
%
% Optional handle: a caller that built its handles struct by hand
% (OffrigPlay, or anything predating this field) simply doesn't get the
% breakdown, never an error.
if ~isfield(handles, 'textBreakdown')
    return;
end
budgetBlocks = max(plannedBlocks, ceil(budgetTrials / blockSize));
blockNow     = floor((trialIdx - 1) / blockSize) + 1;
owed = max(0, minPerLength - quotaTable);
remainingByCat = accumarray(lengthCategory(:), sum(owed, 2), [numCategories 1])';
% Only categories the ACTIVE length set can actually produce: a bar subset
% (or a reduced set + subset) can leave a category with no lengths at all,
% and listing it as "0 left" would read as finished rather than never
% scheduled.
catPresent = accumarray(lengthCategory(:), 1, [numCategories 1])' > 0;
catNamesAll = ColorCategoryMap.categoryNames();
% This block's scheduled 2-cat/3-cat mix, straight from the sequence.
% Clipped to seqSize: the last block is partial once the budget doesn't
% divide evenly into whole blocks.
blockSlots = (blockNow - 1) * blockSize + (1:blockSize);
blockSlots = blockSlots(blockSlots <= seqSize);
set(handles.textBreakdown, 'String', ProgressBreakdownText( ...
    blockNow, budgetBlocks, mod(trialIdx - 1, blockSize) + 1, blockSize, ...
    catNamesAll(catPresent), remainingByCat(catPresent), ...
    sum(trialNumCat(blockSlots) < 3), sum(trialNumCat(blockSlots) == 3)));
end

function [nextEpoch, t, error_type] = earlyExit(EP, t, trigTime)
% Common transition when the cursor leaves the centre too early.
%
% trigTime (the timestamp of the sample that showed the cursor outside the
% centre) rather than GetSecs(): same convention as every other
% sample-derived stamp in the loop, so t.leaveCenter always means "when the
% cursor was measured outside", never "when the state machine noticed".
nextEpoch  = EP.ERROR_FB;
t.leaveCenter = trigTime;
error_type = 1;
end

function [tarPos, tarColor, correctTarget, trialColor, trialDir, centerCueColor, numCat, targetOn] = ...
        placeTargets(idx, trialNumCat, trialDirs, trialColorRows, ...
                    trialCorrectSlot, trialCatIndices, colorArray2Cat, colorArray3Cat, Targets4Dir)
% Thin wrapper around AssignTargets() that also turns on the right number of
% targets; the line both AssignTargets call sites need (end of EP.CUE and
% EP.CUE_DELAY).
%
% Deliberately does NOT stamp t.targetOnset: doing it here would record the
% moment the state machine DECIDED to show the targets, one flip before they
% were actually visible. Each call site raises awaitTargetOnset instead, and
% the render block's AsyncFlipEnd stamps t.targetOnset with the real
% stimulus-onset timestamp. `t` is therefore not passed in or out; see the
% trial loop.
%
% Picks colorArray2Cat or colorArray3Cat by THIS trial's own category count
% (trialNumCat(idx)); needed because sessionMode='alternate'/'interleaved'
% can mix 2-cat and 3-cat trials within the same session, each drawing from
% its own independently hex-configurable colour set (see CenterOutTask.m's
% SETUP section).
if trialNumCat(idx) == 2
    colorArray = colorArray2Cat;
else
    colorArray = colorArray3Cat;
end
[tarPos, tarColor, correctTarget, trialColor, trialDir, centerCueColor, numCat] = ...
    AssignTargets(idx, trialNumCat, trialDirs, trialColorRows, ...
        trialCorrectSlot, trialCatIndices, colorArray, Targets4Dir);
targetOn = [0 0 0];  targetOn(1:numCat) = 1;
end

function [slotDir, slotCol, correctSlot] = layoutForTrial(fixedTargetLayout, catDirMap, nc, trueCat, catRows, correctDir)
% Dispatches to FixedTargetLayout.m (every category always at its own
% fixed direction) or DrawTrialLayout.m (per-trial colour/position
% shuffle), per orgParams.fixedTargetLayout; the single place all four
% CenterOutTask.m call sites (initial build, correction retry, and the two
% requeues) go through so they can't drift out of sync with each other.
if fixedTargetLayout
    [slotDir, slotCol, correctSlot] = FixedTargetLayout(nc, trueCat, catRows, catDirMap);
else
    [slotDir, slotCol, correctSlot] = DrawTrialLayout(nc, trueCat, catRows, correctDir);
end
end

% BuildTrialSequence lives in its own file (centerTask/BuildTrialSequence.m)
% rather than as a local function here: it has no Psychtoolbox/hardware
% dependency, so offrig_mocks/TestLogic.m can share the same copy.