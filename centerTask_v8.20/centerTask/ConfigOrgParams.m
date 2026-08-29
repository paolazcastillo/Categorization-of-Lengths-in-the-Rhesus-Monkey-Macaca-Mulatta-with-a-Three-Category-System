classdef ConfigOrgParams
    % CONFIGORGPARAMS  Default organization parameters for task engines.
    %
    % Single source of truth for all task-configurable parameters. Rather than
    % scattering editable QUICK-EDIT lines throughout task functions, all
    % defaults are centralized here. Code paths call
    % OrgGet(orgParams, 'fieldName', defaultValue) to retrieve values with
    % fallback semantics -- the OrgGet default is a last-resort guard, not the
    % intended source of truth. Fields that appear in getTaskDefaults() below
    % are the canonical defaults; OrgGet's own literal should match them.
    %
    % USAGE
    %  params = ConfigOrgParams.getTaskDefaults();
    %  params.stopMode = 'blocks';
    %  params.numBlocks = 5;
    %  CenterOutTask(params);
    %
    % CONSOLE MERGE PATTERN (CenterConsole.runTask):
    %  userParams = console.getSessionParams();
    %  orgParams  = ConfigOrgParams.mergeStructs( ...
    %                   ConfigOrgParams.getTaskDefaults(), userParams);
    %
    % See also: OrgGet, CenterConsole

    methods (Static)
        function orgParams = getTaskDefaults()
            % Returns a struct of all default organisation parameters.
            %
            % All fields here are read by the engine via OrgGet and can be
            % overridden from orgParams (console GUI or offline script). The two
            % exceptions are marked [NOT WIRED]: barStaysVisible (hardcoded in
            % the engine loop) and targetRadius (derived from centerToTargetDist,
            % so setting it directly has no effect).

            % === SESSION ===
            orgParams.runTag   = datestr(now, 'dd-mmm-yyyy_HH-MM');  % file naming
            orgParams.sessionID = '';

            % === STOP CONDITION ===
            orgParams.stopMode         = 'correctTrials'; % 'correctTrials' | 'blocks'
            orgParams.numBlocks        = 1;               % only if stopMode='blocks'
            orgParams.maxCorrectTrials = 100;             % only if stopMode='correctTrials'
            % What the quota above COUNTS. The number itself (from either
            % stop mode) is unchanged; this only decides what fills it.
            %
            %   false (default) -- CORRECT trials. A combination that is
            %       failed keeps owing its quota and comes round again later
            %       in the sequence, so errors make the session longer. This
            %       is the design the task was built on for monkeys, where
            %       the point is a verified correct trial per combination.
            %   true -- PRESENTATIONS. Every resolved trial fills its
            %       combination's quota whether it was correct or not, so an
            %       error costs the participant a slot instead of buying a
            %       retry, performance is simply the percentage correct over
            %       a fixed set, and the session length is known in advance
            %       (exactly plannedTrials trials). That predictability is
            %       what a human session in one sitting needs -- see
            %       ConfigSession.m -- and it keeps the design balanced:
            %       every combination is shown the same number of times.
            %
            % CENTEROUTTASK ONLY. CenterInTask.m does not read this field:
            % its quota is always rewarded holds. What a presentation quota
            % buys above is a fixed session length over a BALANCED design --
            % every (length, position) combination shown the same number of
            % times. Center-In has no such grid, so there it would only mean
            % "stop after N attempts, however many earned reward", and a
            % subject who never holds could finish a training session with
            % zero. See CenterInTask.m's own stop-condition block.
            %
            % FROM THE CONSOLE this is not set independently: it follows the
            % Retries checkbox (quotaByPresentations = ~useRetries), because
            % insisting on a correct trial per combination is the same
            % intent as the correction procedure, and retries ON with a
            % presentation quota would have each retry eat its own
            % combination's quota. An offline script calling the engines
            % directly can still set the two fields independently -- the
            % engines read them separately and honour whatever they are
            % given.
            %
            % Defaults to true because useRetries now defaults to false: the
            % console would derive exactly this value (~useRetries), so the
            % code default matches what a new session actually runs rather
            % than contradicting it.
            orgParams.quotaByPresentations = true;

            % === STIMULUS SET ===
            % 'full12'      -- all 12 graded bar lengths (4 per category)
            % 'prototypes3' -- one midpoint length per category (its median VA)
            % 'extremes3'   -- shortest bar, Mid category's midpoint, longest
            %                  bar (targets Short/Mid/Long): the same three
            %                  categories with the widest separation the
            %                  stimulus table allows. See CenterOutTask.m.
            % 'prototypes2' -- midpoint length of the Short and Long categories
            %                  only, Mid dropped (2 bars, targets Short/Long).
            %                  Locks the session to 2cat. See ConfigBarLengths.m.
            orgParams.stimulusSet = 'full12';
            orgParams.sessionMode = '3cat';    % '2cat' | '3cat' | 'alternate' | 'interleaved'
            % Which lengths of the active stimulus set actually run. '' (or
            % 'all') = every one of them; '5' = a single length; '1-4,9-12'
            % = a mix of ranges and single indices. See ParseBarSubset.m.
            orgParams.barLengthSubset = '';
            % Colour-matching training that precedes the categorization task
            % (CenterOutTask.m's "Training phases" block): 0 = off, the real
            % categorization task; 1 = a single target in the bar's own
            % colour; 2 = that target plus one foil in a different category
            % colour (foil pick = wrong-target error + flash). Both force the
            % bar to full colour and hide the cue dots. Usually paired with
            % barLengthSubset above to drill one colour at a time.
            orgParams.trainingPhase = 0;
            % false (default) = DrawTrialLayout.m shuffles which cardinal
            % direction/colour each category lands on every trial. true =
            % FixedTargetLayout.m instead: category 1 (Short) always Right,
            % category 2 (Mid) always Up, category 3 (Long) always Left --
            % same spot every trial, Down never used.
            orgParams.fixedTargetLayout = false;

            % === TIMING (seconds) ===
            orgParams.holdTimeBase      = 1.0;   %
            orgParams.holdTimeDelta     = 0.5;   %
            orgParams.barDuration       = 1.0;   %
            orgParams.barStaysVisible   = 0;     % [NOT WIRED] hardcoded in engine; set via OrgGet when engine is updated
            orgParams.delayStimToRule   = 0;     % bar -> cue working-memory delay
            orgParams.barToTargetDelay  = 0;     % cue -> target working-memory delay
            orgParams.useCue            = true;  %
            orgParams.cueDuration       = 0.5;   %
            orgParams.targetDuration    = 5;     % legacy combined window (fallback for the two below)
            orgParams.maxDecisionTime   = 2;     % max time (s) from target onset to LEAVE the centre
            orgParams.maxExecutionTime  = 2.5;   % max time (s) from leaving the centre to REACH the target
            orgParams.ITI               = 2.0;   %
            orgParams.ITIDelta          = 0.5;   %
            orgParams.ITIError          = 3.0;   %
            orgParams.tarHoldFeed       = 0.2;   % success feedback duration
            orgParams.tarErrorFeed      = 0.2;   % error feedback duration
            orgParams.Reward            = 0.15;  % juice valve time (seconds)
            % Valve calibration: mL of water delivered per SECOND of
            % valve-open time. Used only to turn the session's total
            % valve-open time into a mL figure in the end-of-session report
            % (SessionReport.reward) -- it never changes what the valve does.
            % 0 = not calibrated: the report then prints valve time only,
            % rather than inventing a conversion. Depends on line pressure
            % and tubing, so it is a real per-rig measurement, which is why
            % there is no plausible non-zero default here.
            orgParams.rewardMlPerSec    = 0.74;
            orgParams.minTarHoldTime    = 0.05;  % required hold inside target before it counts as good (s); 0 = touch is enough

            % === TRIAL REPETITION (correction procedure / requeue) ===
            % Both are console checkboxes in the Session panel, and both are
            % unchecked automatically when the subject type is Human (see
            % ConfigSession.m's humanUseRetries/humanUseRequeue for why).
            %
            % BOTH DEFAULT TO false, so every NEW session starts with one
            % deliberate answer per stimulus and a sequence of exactly the
            % planned length. They are training aids, not the measurement
            % condition: retries re-show a stimulus the subject just got
            % wrong, and requeue grows the sequence, so both distort the
            % per-stimulus response distribution the psychometric fits read.
            % An operator who wants them for a training session ticks the
            % two checkboxes in the console.
            %
            % useRetries: the correction procedure -- a failed attempt shows
            % the SAME stimulus again (reshuffled), up to maxStimAttempts
            % attempts in total. false runs exactly one attempt per stimulus
            % no matter what maxStimAttempts says (both engines clamp it to
            % 1), so every trial is a single deliberate answer.
            orgParams.useRetries        = false;
            orgParams.maxStimAttempts   = 5;     % attempts per stimulus, only meaningful while useRetries is true
            % useRequeue: CenterOutTask.m only. When an original (bar
            % length, position) presentation resolves ambiguously -- it
            % succeeded only after a reshuffled retry, or exhausted every
            % attempt -- one clean, un-reshuffled repeat of it is appended
            % to the end of the sequence, and THAT repeat's outcome is what
            % credits the quota. false credits every trial where it stands
            % and never grows the sequence, so the session runs exactly the
            % planned number of trials.
            orgParams.useRequeue        = false;

            % === CUE APPEARANCE (pixels) ===
            orgParams.cueYOffset  = -220;  % vertical offset (negative = up)
            orgParams.cueSize     = 125;   % dot diameter
            orgParams.cueDistance = 220;   % horizontal spacing between dots

            % === BAR APPEARANCE ===
            orgParams.barHeight         = 50;   %
            orgParams.barOffsetY        = -150;  % vertical offset from centre (negative = up)
            orgParams.barColorIntensity = 0;    % 0=white (length only), 1=full colour reveals category

            % === RIG GEOMETRY (pixels) ===
            % centerRad MUST match the OrgGet default in both engines (200).
            % v2_2 used 150; a wider window means fewer early-exit errors for
            % reasons unrelated to learning. Pin explicitly when comparing
            % sessions across code generations.
            orgParams.centerRad           = 200;    % centre hold-window diameter
            orgParams.targetRad           = 180;    % peripheral target diameter (CenterOutTask.m and CenterInTask.m reach mode)
            orgParams.centerToTargetDist  = 320;    % centre-to-target distance (px); ring radius = this * 1.27
            orgParams.targetRadius        = 100;    % [NOT WIRED] engine derives this from centerToTargetDist; setting it here has no effect
            orgParams.screenViewingDist_mm = 400;   % viewing distance (mm); affects bar sizes in deg VA
            orgParams.screenPixelPitch    = 0.3108; % pixel pitch (mm/px); affects bar sizes (deg VA -> px)

            % === CENTER-IN ONLY (CenterInTask.m) ===
            orgParams.useTargetReach     = false;              % adds a peripheral target after the centre hold (see CenterInTask.m)
            orgParams.targetWeights      = [25 25 25 25];       % relative proportion per direction [Right Up Left Down], only used when useTargetReach is true
            % +/- px random offset of the hold-target's drawn position, only
            % applied in PURE hold mode (useTargetReach = false) -- see the
            % "CENTRE JITTER" section of CenterInTask.m's header comment.
            % Ignored entirely when useTargetReach is true (hold-target stays
            % pinned to true centre in that mode).
            orgParams.centerJitterRange = 150;
            % Peripheral reach-mode target fill colour (hex) -- only ever
            % drawn when useTargetReach is true. See OrgGetColor.m/HexToRGB.m.
            orgParams.centerInTargetColor = '00FF00';
            % Distractor (foil) target, reach mode only. false (default) keeps
            % the single-target reach unchanged. true adds one foil on another
            % direction; reaching it is silent (no reward, no flash, no abort)
            % and the identical trial repeats until the correct target is
            % reached. See CenterInTask.m's reach-mode block.
            % Error flash on the WRONG-TARGET pick (console "Show error flash",
            % pre-training). false (default) = reaching the phase-2 foil does
            % not flash; true = it does. A failed hold/reach always flashes
            % regardless. See CenterOutTask.m's EP.ERROR_FB. (Center-In has no
            % foil, so it always flashes its hold/reach failures.)
            orgParams.showErrorFlash          = false;
            % Hold strictness (console "Strict hold"). false (default): lenient
            % -- leaving the target resets the hold timer, and returning to hold
            % minTarHoldTime still earns reward. true: any exit from the target
            % before completing the hold aborts the trial with no reward.
            orgParams.strictHold              = false;
            % Strict pre-training feedback (console "Training error flash").
            % Applies ONLY when trainingPhase > 0; the categorization task is
            % untouched by it. true (default): reaching the foil is a
            % wrong-target error WITH flash (which also disables foilNoAbort),
            % and releasing the correct target before completing the hold is a
            % hold-break error (ErrorType 3) WITH flash. false: the lenient
            % pre-training behaviour -- the foil does not abort and leaving the
            % target only restarts the hold timer. See strictTraining in
            % CenterOutTask.m's SETUP and its EP.TARGET_HOLD.
            orgParams.trainingErrorFlash      = true;
            % true (default) = gray-until-holding cue: the centre hold-ring is
            % gray while waiting to enter/before the hold starts, green once it
            % begins. false = the ring is always green. See CenterInTask.m's
            % "HOLD-RING COLOUR EFFECT" header section.
            orgParams.useHoldColorEffect = true;

            % === CATEGORY COLOURS (hex, CenterOutTask.m) ===
            % Independent 2-cat/3-cat sets -- see HexToRGB.m and
            % CenterOutTask.m's colorArray2Cat/colorArray3Cat. Defaults
            % reproduce ColorCategoryMap's built-in ORANGE/GREEN/BLUE.
            orgParams.color3CatShort = 'FFA500';
            orgParams.color3CatMid   = '00FF00';
            orgParams.color3CatLong  = '0000FF';
            orgParams.color2CatShort = 'FFA500';
            orgParams.color2CatLong  = '0000FF';

            % === INPUT ===
            orgParams.inputSource       = 'joystick'; % 'joystick' | 'mouse' | 'rz2adc'
            orgParams.moveOversample    = 1;           %
            orgParams.moveOversampleDt  = 0.008;       %

            % NOTE: the KINEMATICS FILTERING block that used to sit here
            % (kinematicsCutoffHz, kinematicsOutlierMethod, hampelHalfWindow,
            % hampelNSigma, kinematicsMinMoveSamples, kinematicsMinMoveDurSec)
            % configured the per-trial kinematics engine, which has been
            % removed from the suite along with its filters. Speeds and
            % accelerations are derived offline in the Python EDA notebook
            % from the trajectory exports, which carry every epoch and sample.

            % === RZ2 ANALOG JOYSTICK (only used when inputSource='rz2adc') ===
            % A SECOND, ADC-wired analog joystick, sampled on Computer 1 via
            % TDT Synapse and relayed here over UDP by JoystickRelayToTask.m
            % (see SetupRZ2Joystick.m/ReadRZ2Joystick.m). rz2ScaleX/rz2ScaleY
            % (gain) are console-editable (CenterConsole.m's "RZ2 gain X/Y"
            % fields, Rig geometry column) since gain is a per-session tuning
            % knob, not fixed rig wiring; these two are just the fallback
            % defaults used to pre-fill that GUI. rz2UdpPort/rz2OffsetY stay
            % code-only -- true rig wiring an operator should not need to
            % touch per session.
            %
            % Must match JoystickRelayToTask.m's UDP_PORT on Computer 1 (its
            % REMOTE_HOST must point at this machine's IP -- see
            % ConfigOrgParams.m's localMachineHost below).
            orgParams.rz2UdpPort     = 8831;
            % Fixed source port InitJoystickRelay.m's outgoing socket binds
            % on Computer 1 (must be fixed, not OS-assigned/ephemeral) so
            % that on Computer 2, when udpport() is unavailable (pre-R2019b
            % MATLAB -- confirmed on this rig's Computer 2, R2016b) and
            % SetupRZ2Joystick.m falls back to the legacy udp() object, that
            % object's RemoteHost/RemotePort receive filter has a fixed,
            % known port to match against instead of an unpredictable one.
            orgParams.rz2RelaySourcePort = 8832;
            % USB 'joystick' axis gain (ReadCursorPosition.m). Sign = axis
            % direction, magnitude = pixels-per-unit travel. Was hardcoded -1.3.
            orgParams.joyGain        = -1.3;
            orgParams.rz2ScaleX      = 1;   % relay already normalizes to [-1,1] -- this is pixel scale on top of that
            orgParams.rz2ScaleY      = 1;   % JoystickRelayToTask.m now sends real JoyY too (APICh2/Adc2)
            orgParams.rz2OffsetY     = 0;   % Y only -- see SetupRZ2Joystick.m
            % The ADC's REAL sample rate, used by ReadRZ2Joystick.m to turn
            % the relay's sample index into elapsed time. NOT the relay's
            % forwarding rate (N_READ*RELAY_HZ, held under the writer on
            % purpose): the index counts ADC samples, so dividing by anything
            % else stretches or compresses every trial's timeline.
            %
            % CORRECTED 2026-08-25, 1017 -> 952. The old 1017 was inferred
            % from the storage rate JoyX/JoyY and NPro2 display in Synapse,
            % but those are DIFFERENT gizmos with their own decimation.
            % APICh1X/APICh2Y run APIStreamer1Ch.rcx off the PZ5's ~25 kHz
            % stream through its own 'downsample' divider (26 on this rig),
            % and that is what sets THIS buffer's write rate. Measured
            % directly for the first time by polling the newly-exposed
            % SerStore write-index tag for 30 s: 952.11 Hz. The old value was
            % stretching every trajectory timestamp by ~7%. Re-measure the
            % same way if 'downsample' or the PZ5 rate ever change -- do not
            % infer it from another gizmo's display again. NOTE: 'downsample'
            % is a RUNTIME parameter and can reset to 1 when Synapse
            % restarts, which sends the rate to ~26,000 Hz; worth confirming
            % at the start of a session. See SetupRZ2Joystick.m.
            orgParams.rz2SampleRateHz = 952;
            % Ceiling on samples ReadRZ2Joystick.m drains in one frame. A
            % healthy link delivers ~16 samples/frame at 60 Hz, so any value
            % well above that leaves room to catch up after a hiccup while
            % bounding what a single frame can be made to swallow -- an
            % unbounded drain is what let a backlog feed on itself. Surplus
            % stays queued and is read on later frames; nothing is discarded.
            %
            % RAISED 64 -> 2048 (2026-08-22), in two steps (64 -> 256 -> 2048).
            % 64 and 256 were both sized for normal traffic, not for
            % recovering from a real burst: a session on this rig logged an
            % index gap (nSkipped) of ~97,100 samples in one step. Even with
            % rz2InputBufferSize below keeping a burst that size from being
            % LOST, draining it at 256/frame would take 97100/256/60 =~ 6.3 s
            % to clear, with the cursor visibly stale the whole time; at
            % 2048/frame that drops to =~ 0.8 s. Cost: a frame that really
            % has 2048 samples queued spends longer in ReadRZ2Joystick.m's
            % parse loop before it can render. If frames stutter specifically
            % WHILE draining a backlog (check DiagnoseRZ2Cursor.m's maxPeriod
            % / nCapped), this is the value to lower again.
            orgParams.rz2MaxSamplesPerDrain = 2048;
            % Receive buffer on the UDP socket SetupRZ2Joystick.m opens, in
            % bytes. Was hardcoded 262144 and sized for STEADY-state traffic
            % (~8 s of backlog), not for absorbing a single large burst: at
            % ~29 bytes/sample it holds only ~9,000 samples before the OS
            % starts dropping, an order of magnitude short of the ~97,100
            % sample burst seen on this rig. 4 MB holds ~145,000 samples
            % (~152 s at 952 Hz), at a RAM cost that is irrelevant on any
            % machine running this task. This does NOT fix whatever causes
            % the burst -- it only keeps a burst of this size from being lost
            % once it happens. Matched deliberately to InitJoystickRelay.m's
            % OutputBufferSize on Computer 1, which was raised to the same
            % 4 MB for the same reason on the send side.
            orgParams.rz2InputBufferSize = 4194304;
            % Consecutive capped frames before ReadRZ2Joystick.m warns that
            % the link is falling behind. A short run of capped frames is the
            % normal, self-clearing way any backlog gets worked off, so this
            % is deliberately not 1: ~1s at 60 fps distinguishes "catching
            % up" from "not keeping up".
            orgParams.rz2CapWarnFrames = 60;

            % === NETWORK ===
            % Hardcoded in engine; kept here for documentation and future
            % configurability.
            orgParams.remoteSynapseHost = '172.24.60.152'; % Synapse UDP endpoint
            orgParams.localMachineHost  = '172.24.60.146'; % local UDP bind address

            % === GUI HANDLES ===
            % Set by CenterConsole.runTask; auto-created by InitTaskHandles
            % if not provided (engine checks isfield/isempty on startup).
            orgParams.handles = [];
        end

        function orgParams = mergeStructs(defaults, overrides)
            % Merge two structs, with overrides taking precedence over defaults.
            %
            % INPUT
            %  defaults  : base struct (e.g. from ConfigOrgParams.getTaskDefaults())
            %  overrides : struct with fields to override (from GUI or offline caller)
            %
            % OUTPUT
            %  orgParams : merged struct; every field from defaults is present,
            %              with overrides.(field) substituted when it is non-empty.
            %
            % IMPORTANT -- what counts as "override wins":
            %  non-empty scalar (including 0, false, NaN) -> override wins
            %  []  (empty matrix)                         -> default wins
            %  ''  (empty string)                         -> default wins
            %
            % This means a caller CAN override a field to 0 or false (e.g.
            % delayStimToRule = 0 explicitly beats a non-zero default). It
            % CANNOT override a field to [] (empty is treated as "not set").
            % That is intentional: the console uses [] as "I didn't touch this
            % field", and the engine uses OrgGet's own fallback as the last
            % resort. If you need to force a field to [], set it after the merge.

            orgParams = defaults;
            if isempty(overrides) || ~isstruct(overrides)
                return;
            end

            overrideFields = fieldnames(overrides);
            for i = 1:numel(overrideFields)
                fieldName = overrideFields{i};
                val = overrides.(fieldName);
                if ~isempty(val)
                    orgParams.(fieldName) = val;
                end
            end
        end
    end
end