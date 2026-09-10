classdef CenterConsole < handle
    % CENTERCONSOLE  Unified experiment control console (session + task).
    %
    %   OOP replacement for the original function-based console: properties
    %   instead of scattered setappdata/getappdata, callbacks bound to object
    %   methods instead of nested callback functions sharing state through
    %   guidata. Deliberately still a classic figure()/uicontrol() GUI, NOT
    %   App Designer/uifigure: both task engines talk to their GUI handles
    %   with classic get/set('String', ...) calls, which uifigure components
    %   (uilabel/uieditfield) do not support the same way.
    %
    %   Changes from the original console:
    %     - NO eye-tracking controls/calibration anywhere in this GUI.
    %     - Reward, all timing delays, and rig geometry (centre window,
    %       centre/target/cue positions) are editable here and passed through
    %       to the selected engine via orgParams (previously hardcoded
    %       constants).
    %     - Every run's exact parameters are snapshotted to disk before the
    %       task starts, tagged with the same runTag used for that run's data
    %       files, so any output file can be traced back to the settings
    %       that produced it.
    %     - Live run status while the engine is running (state, good trials,
    %       % correct, trials budget, elapsed session time) is shown directly
    %       in this window's "Run" panel, each in a labeled box, via the same
    %       6-field handles contract (dlgTrainingMain/text77/edit91/edit92/
    %       editTrainRepe/textSessionTime) both engines write into.
    %
    %   Usage:
    %     console = CenterConsole();             % builds and shows the figure
    %     params = console.getSessionParams();   % current GUI values (resolved strings)
    %
    %   SINGLE WINDOW: the console is a singleton. Calling CenterConsole()
    %   again -- which is what an operator naturally does to set up the next
    %   session -- raises the console that is already open and returns that
    %   same object instead of stacking up a second, third, ... console
    %   window (each with its own copy of the parameters, only one of which
    %   is the one the operator actually edited). One run ending (normally
    %   or by Abort) never closes this window either: the session is simply
    %   cleared (see endSession), so the next session is configured and
    %   registered in the very same console.
    %
    %   Task type (ui.popTaskType, Session panel): 'Center-Out (categorization)'
    %   dispatches to CenterOutTask (bar-length categorization, 2/3 targets);
    %   'Center-In (hold)' dispatches to CenterInTask (no bar/cue/targets --
    %   just enter and hold the centre circle for reward, a simpler
    %   pre-categorization training task). Most of the "Task parameters" panel
    %   only applies to Center-Out (Session mode, Bar set, Show cue, Stop-by
    %   quota, rig geometry); the one Center-In-specific field (target correct
    %   trials) is called out inline where it sits in that panel. Both engines
    %   share the Reward/timing/Input source/Max attempts fields and the Run
    %   panel's live-status handles.
    %
    %   Abort works through the same getappdata(fig,'stop') polling both
    %   engines already do every frame: dlgTrainingMain (see runTask) is a
    %   separate, hidden proxy figure -- not this console window itself,
    %   since both engines call close() on it (on normal completion and from
    %   their crash handler), which must not make the whole console vanish.
    %
    % See also: CenterOutTask, CenterInTask, ConfigOrgParams, ConfigSession

    properties (SetAccess = private)
        fig
        running = false
    end

    properties (Access = private)
        ui              % struct of uicontrol handles (grouped by panel)
        proxyFig        % hidden figure exposing the dlgTrainingMain/stop-flag contract
        idSession = ''
        idSubject = ''      % 'Romina' (monkey) or 'PX-3' (human participant)
        subjectType = ''    % 'monkey' | 'human' -- set at registration
        idProject = ''

        titleFont = {'FontSize', 12, 'FontWeight', 'bold'}
        labelFont = {'FontSize', 9}
        panelBG = [0.98 0.98 1.00]
    end

    properties (Constant, Access = private)
        % Figure Tag the singleton check in the constructor looks for -- the
        % console window is identified by this, never by its handle number,
        % which does not survive a "clear" of the calling workspace.
        figTag = 'CenterTaskConsole'
    end

    methods
        function self = CenterConsole()
            % Singleton: reuse the console that is already open rather than
            % building a second window. An operator who has just aborted or
            % finished a run and wants to set up the next session typically
            % re-runs CenterConsole; without this, every one of those calls
            % left another console figure on screen, all of them live and
            % all but one holding stale/default parameters. Handle classes
            % may return an existing instance from their constructor, so the
            % caller transparently gets the console already on screen.
            existing = findall(0, 'Type', 'figure', 'Tag', CenterConsole.figTag);
            if ~isempty(existing)
                prior = getappdata(existing(1), 'consoleObj');
                if isa(prior, 'CenterConsole') && isvalid(prior)
                    figure(existing(1));   % raise it in front of whatever covered it
                    drawnow();
                    self = prior;
                    return;
                end
                % Orphaned window: its object was cleared (e.g. "clear
                % classes" or a closed workspace), so nothing can drive it
                % any more -- drop it and build a working console instead.
                delete(existing);
            end

            % Built hidden ('Visible','off') and only shown at the very end,
            % once every panel/control exists, to avoid any partial-paint
            % flicker while it's under construction.
            self.fig = figure('Name', 'Center Task Console', 'NumberTitle', 'off', ...
                'MenuBar', 'none', 'ToolBar', 'none', 'Resize', 'off', ...
                'Color', [0.94 0.94 0.96], 'Position', [80 60 1240 785], ...
                'Visible', 'off', 'Tag', CenterConsole.figTag, ...
                'CloseRequestFcn', @(~, ~) self.close_Callback());
            % How the singleton check above finds this instance from its
            % figure (appdata rides on the figure, so it dies with it).
            setappdata(self.fig, 'consoleObj', self);

            % Force pixel units for every uipanel/uicontrol/uitable created
            % under this figure from here on, regardless of this MATLAB
            % install's own default -- root cause of a real bug seen on one
            % lab machine, where uipanel's default Units resolved to
            % 'normalized' (uicontrol's stayed 'pixels'), so a panel's
            % literal pixel Position was interpreted as fractions of the
            % figure instead, placing it thousands of percent off-screen.
            set(self.fig, 'DefaultUipanelUnits', 'pixels', ...
                'DefaultUicontrolUnits', 'pixels', 'DefaultUitableUnits', 'pixels');

            self.buildSessionPanel();
            self.buildTaskParamsPanel();
            self.buildRunPanel();

            % Trials budget otherwise only gets written once an engine
            % actually runs (see runTask/taskTypeSelect_Callback) -- compute
            % the initial preview now so it's never left showing the
            % hardcoded '0' from buildRunPanel. Going through the Bar set
            % callback also applies the Session mode lock, so a default of
            % prototypes3/extremes3 in ConfigOrgParams opens the console
            % already consistent instead of only after the operator touches
            % the popup.
            self.stimulusSetSelect_Callback();

            % Center on whatever screen this is (movegui also nudges the
            % figure back onscreen if a chosen position would run off an
            % edge), then reveal the finished window and force a full paint.
            movegui(self.fig, 'center');
            set(self.fig, 'Visible', 'on');
            drawnow();
        end

        % =====================================================================
        % PUBLIC INTERFACE
        % =====================================================================

        function setRunning(self, isRunning)
            self.running = isRunning;
            if isRunning
                set(self.ui.butStart, 'Enable', 'off');
                set(self.ui.butAbort, 'Enable', 'on');
            else
                set(self.ui.butStart, 'Enable', 'on');
                set(self.ui.butAbort, 'Enable', 'off');
            end
        end

        function endSession(self)
            % Called once a run has ended, whatever ended it (finished,
            % Abort, or a crash). The console STAYS OPEN and keeps every
            % task parameter as configured; what is discarded is the
            % session identity itself -- the registration that run's runTag,
            % params snapshot and output files were written under.
            %
            % Consequence, and the point of doing it: Start is disabled
            % until "Register session" is pressed again, so the next session
            % cannot silently reuse the finished one's registration. It gets
            % its own registration and its own record, configured in this
            % same window -- no second console.
            self.idSession = '';
            self.idSubject = '';
            self.subjectType = '';
            self.idProject = '';
            set(self.ui.edSessionId, 'String', '');
            set(self.ui.edDate, 'String', '');
            set(self.ui.butStart, 'Enable', 'off');

            % Stale handle to the run's (now deleted) hidden proxy figure --
            % drop it so a later Abort has nothing to poke at.
            self.proxyFig = [];

            % Keep whatever the engine left in Status ("Task done" / "Task
            % stopped" / an error) and just say what to do next; the run's
            % counters stay on screen too, until the next registration
            % clears them (see registerSession_Callback).
            outcome = get(self.ui.textStatus, 'String');
            if iscell(outcome), outcome = outcome{1}; end
            if isempty(outcome), outcome = 'Run ended'; end
            set(self.ui.textStatus, 'String', ...
                [outcome ' -- register a session to run again']);
        end

        function [params, allValid] = getSessionParams(self)
            % All current GUI values, resolved to the strings/booleans the
            % task engines actually expect (not raw popup indices).
            % allValid is false when any numeric field contains NaN (empty
            % box, comma decimal separator, or stray letters). start_Callback
            % checks this and blocks launching until all fields are valid.
            params = struct();
            allValid = true;
            params.taskType = get(self.ui.popTaskType, 'Value');  % 1=Center-Out, 2=Center-In

            % Reward and MaxAttempts: validate inline the same way
            % gatherFields does for the struct fields.
            rewardVal = str2double(get(self.ui.edReward, 'String'));
            if isnan(rewardVal)
                set(self.ui.edReward, 'BackgroundColor', [1 0.7 0.7]);
                allValid = false;
            else
                set(self.ui.edReward, 'BackgroundColor', [1 1 1]);
            end
            params.Reward = rewardVal;

            maxAttVal = str2double(get(self.ui.edMaxAttempts, 'String'));
            if isnan(maxAttVal)
                set(self.ui.edMaxAttempts, 'BackgroundColor', [1 0.7 0.7]);
                allValid = false;
            else
                set(self.ui.edMaxAttempts, 'BackgroundColor', [1 1 1]);
            end
            params.maxStimAttempts = maxAttVal;

            % Trial repetition, read by BOTH engines via OrgGet (see
            % useRetries/useRequeue in CenterOutTask.m and CenterInTask.m).
            % Without these two lines the checkboxes would move on screen
            % while the engines silently kept ConfigOrgParams' defaults --
            % so a human session, whose whole point is one deliberate answer
            % per stimulus, would still run the correction procedure.
            % useRequeue is Center-Out only; CenterInTask ignores it.
            params.useRetries = logical(get(self.ui.chkUseRetries, 'Value'));
            params.useRequeue = logical(get(self.ui.chkUseRequeue, 'Value'));
            % Whether that quota is filled by correct trials or by every
            % presentation -- the switch that decides if errors lengthen the
            % session or consume a slot. Read by both engines.
            params.quotaByPresentations = logical(get(self.ui.chkQuotaPresentations, 'Value'));

            % Valve calibration (mL per second of valve-open time), used by
            % both engines purely to report water in the end-of-session
            % summary. 0 is a legitimate value meaning "not calibrated", so
            % only NaN and negatives are rejected.
            mlPerSecVal = str2double(get(self.ui.edRewardMlPerSec, 'String'));
            if isnan(mlPerSecVal) || mlPerSecVal < 0
                set(self.ui.edRewardMlPerSec, 'BackgroundColor', [1 0.7 0.7]);
                allValid = false;
            else
                set(self.ui.edRewardMlPerSec, 'BackgroundColor', [1 1 1]);
            end
            params.rewardMlPerSec = mlPerSecVal;

            % Timing fields are gathered generically from whatever edit
            % fields exist in ui.edTiming instead of one hand-written line
            % per field -- adding a row to buildTaskParamsPanel's timingRows
            % is enough, nothing here needs to change to match. Shared by
            % both engines -- CenterInTask only reads holdTimeBase/
            % holdTimeDelta/ITI/ITIDelta/ITIError via OrgGet and silently
            % ignores the Center-Out-only fields (barDuration,
            % delayStimToRule, barToTargetDelay, cueDuration).
            inputSources = get(self.ui.popInputSource, 'String');
            params.inputSource = inputSources{get(self.ui.popInputSource, 'Value')};
            [params, timingValid] = self.gatherFields(params, self.ui.edTiming);
            allValid = allValid && timingValid;

            % RZ2 analog-joystick gain (see buildTaskParamsPanel for the
            % fields' rationale) -- validated the same inline way as
            % Reward/MaxAttempts above, not via gatherFields, since they sit
            % in the Rig geometry column, not ui.edTiming.
            rz2ScaleXVal = str2double(get(self.ui.edRZ2ScaleX, 'String'));
            if isnan(rz2ScaleXVal)
                set(self.ui.edRZ2ScaleX, 'BackgroundColor', [1 0.7 0.7]);
                allValid = false;
            else
                set(self.ui.edRZ2ScaleX, 'BackgroundColor', [1 1 1]);
            end
            params.rz2ScaleX = rz2ScaleXVal;

            rz2ScaleYVal = str2double(get(self.ui.edRZ2ScaleY, 'String'));
            if isnan(rz2ScaleYVal)
                set(self.ui.edRZ2ScaleY, 'BackgroundColor', [1 0.7 0.7]);
                allValid = false;
            else
                set(self.ui.edRZ2ScaleY, 'BackgroundColor', [1 1 1]);
            end
            params.rz2ScaleY = rz2ScaleYVal;

            joyGainVal = str2double(get(self.ui.edJoyGain, 'String'));
            if isnan(joyGainVal) || joyGainVal == 0
                set(self.ui.edJoyGain, 'BackgroundColor', [1 0.7 0.7]);
                allValid = false;
            else
                set(self.ui.edJoyGain, 'BackgroundColor', [1 1 1]);
            end
            params.joyGain = joyGainVal;

            % Kinematics analysis parameters are gone entirely -- the engine
            % no longer computes per-trial kinematics, so there is nothing to
            % configure here or in ConfigOrgParams.m. Speeds are derived
            % offline from the trajectory exports.

            % Category colours (hex): independent 2-cat/3-cat sets (see
            % buildTaskParamsPanel). Gathered regardless of taskType --
            % CenterInTask.m simply never reads them; CenterOutTask.m needs
            % both sets whenever sessionMode mixes categories (alternate/
            % interleaved) or is plain '2cat'. Passed through as raw hex
            % strings; HexToRGB.m does the actual conversion in the engine.
            hexFields = {
                'edColor3CatShort',      'color3CatShort'
                'edColor3CatMid',        'color3CatMid'
                'edColor3CatLong',       'color3CatLong'
                'edColor2CatShort',      'color2CatShort'
                'edColor2CatLong',       'color2CatLong'
                'edCenterInTargetColor', 'centerInTargetColor'
                };
            for i = 1:size(hexFields, 1)
                h = self.ui.(hexFields{i, 1});
                hexStr = strtrim(get(h, 'String'));
                if isempty(regexp(strrep(hexStr, '#', ''), '^[0-9A-Fa-f]{6}$', 'once'))
                    set(h, 'BackgroundColor', [1 0.7 0.7]);
                    allValid = false;
                else
                    set(h, 'BackgroundColor', [1 1 1]);
                    params.(hexFields{i, 2}) = hexStr;
                end
            end

            if params.taskType == 2
                % CenterInTask has no bar/length/position grid to gate a
                % quota per combination like CenterOutTask's Stop-by/quota
                % below -- just a flat "stop once this many hold-in-centre
                % trials have been rewarded".
                params.maxCorrectTrials = str2double(get(self.ui.edCenterInTrials, 'String'));
                % centerRad is the one geometry field that is NOT
                % Center-Out-only: it sets the size of the centre hold
                % window, which is the entire difficulty of the Center-In
                % task. It lives in the same edGeom panel as the Center-Out
                % geometry (one "Rig geometry" block reads better than two),
                % so it is pulled out by hand here rather than gathering all
                % of edGeom, which would also send bar/cue fields this
                % engine has no use for.
                params.centerRad = str2double(get(self.ui.edGeom.centerRad, 'String'));

                % Optional reach-to-target mode (see CenterInTask.m):
                % centerToTargetDist is pulled out by hand for the same
                % reason centerRad is above -- gathering all of edGeom would
                % also send bar/cue fields this engine has no use for.
                params.centerToTargetDist = str2double(get(self.ui.edGeom.centerToTargetDist, 'String'));
                % Pure-hold-mode-only (see CenterInTask.m's "CENTRE JITTER"
                % section) -- gathered regardless of useTargetReach below,
                % since the engine itself is what ignores it in reach mode.
                jitterVal = str2double(get(self.ui.edCenterInJitter, 'String'));
                if isnan(jitterVal) || jitterVal < 0
                    set(self.ui.edCenterInJitter, 'BackgroundColor', [1 0.7 0.7]);
                    allValid = false;
                else
                    set(self.ui.edCenterInJitter, 'BackgroundColor', [1 1 1]);
                    params.centerJitterRange = jitterVal;
                end
                % Center-In: reach-to-target on/off (no foil here).
                params.useTargetReach = logical(get(self.ui.chkCenterInReach, 'Value'));
                if params.useTargetReach
                    weightsStr = get(self.ui.edCenterInWeights, 'String');
                    weightsVal = str2double(strsplit(weightsStr, ','));
                    if numel(weightsVal) ~= 4 || any(isnan(weightsVal)) || any(weightsVal < 0) || sum(weightsVal) <= 0
                        set(self.ui.edCenterInWeights, 'BackgroundColor', [1 0.7 0.7]);
                        allValid = false;
                    else
                        set(self.ui.edCenterInWeights, 'BackgroundColor', [1 1 1]);
                        params.targetWeights = weightsVal;
                    end
                end
                % Off (default) = hold-ring always green; on = restores the
                % gray-while-waiting/green-while-holding cue. See
                % CenterInTask.m's "HOLD-RING COLOUR EFFECT" header section.
                params.useHoldColorEffect = logical(get(self.ui.chkHoldColorEffect, 'Value'));
            else
                % Geometry, session mode, and stimulus set only mean
                % anything for the bar-length categorization task.
                [params, geomValid] = self.gatherFields(params, self.ui.edGeom);
                allValid = allValid && geomValid;
                sessionModes = get(self.ui.popSessionMode, 'String');
                params.sessionMode = sessionModes{get(self.ui.popSessionMode, 'Value')};
                % Alternate mode's blocks-per-segment: gathered and validated
                % unconditionally (same treatment Max attempts gets from
                % Retries) rather than only while 'alternate' is selected, so
                % a value typed in survives switching to another mode and
                % back. Must be a positive integer -- CenterOutTask.m uses it
                % directly as a block-count multiplier.
                blocks2Val = str2double(get(self.ui.edAlternateBlocks2cat, 'String'));
                if isnan(blocks2Val) || blocks2Val < 1 || blocks2Val ~= round(blocks2Val)
                    set(self.ui.edAlternateBlocks2cat, 'BackgroundColor', [1 0.7 0.7]);
                    allValid = false;
                else
                    set(self.ui.edAlternateBlocks2cat, 'BackgroundColor', [1 1 1]);
                end
                params.alternateBlocks2cat = blocks2Val;
                blocks3Val = str2double(get(self.ui.edAlternateBlocks3cat, 'String'));
                if isnan(blocks3Val) || blocks3Val < 1 || blocks3Val ~= round(blocks3Val)
                    set(self.ui.edAlternateBlocks3cat, 'BackgroundColor', [1 0.7 0.7]);
                    allValid = false;
                else
                    set(self.ui.edAlternateBlocks3cat, 'BackgroundColor', [1 1 1]);
                end
                params.alternateBlocks3cat = blocks3Val;
                [params.stimulusSet, numLengths] = self.stimulusSetSelection();
                % 0 = off (categorization), 1 = match, 2 = match + foil.
                params.trainingPhase = get(self.ui.popTrainingPhase, 'Value') - 1;
                % Bar subset: parsed here with the SAME helper the engine
                % uses, against the stimulus set selected just above, so an
                % out-of-range index ("13" with only 12 lengths) paints the
                % field red and blocks Start instead of erroring out of
                % CenterOutTask after the session has already been
                % registered and snapshotted.
                subsetStr = strtrim(get(self.ui.edBarSubset, 'String'));
                [~, subsetErr] = ParseBarSubset(subsetStr, numLengths);
                if isempty(subsetErr)
                    set(self.ui.edBarSubset, 'BackgroundColor', [1 1 1]);
                    params.barLengthSubset = subsetStr;
                else
                    set(self.ui.edBarSubset, 'BackgroundColor', [1 0.7 0.7]);
                    allValid = false;
                end
                params.useCue = logical(get(self.ui.chkShowCue, 'Value'));
                % Pre-training feedback: flash on the wrong-target (foil) pick,
                % and gray-until-holding for the centre ring (Center-Out uses
                % its OWN checkbox here; Center-In uses chkHoldColorEffect).
                params.showErrorFlash = logical(get(self.ui.chkShowErrorFlash, 'Value'));
                params.useHoldColorEffect = logical(get(self.ui.chkHoldColorEffectCO, 'Value'));
                params.strictHold = logical(get(self.ui.chkStrictHold, 'Value'));
                % Pre-training only: foil pick and hold-break both become
                % flashed errors (types 2 and 3). Ignored when Training phase
                % is "0 - off". See strictTraining in CenterOutTask.m.
                params.trainingErrorFlash = logical(get(self.ui.chkTrainingErrorFlash, 'Value'));
                % 0 = white bar (default); 1 = bar drawn in full category colour.
                params.barColorIntensity = double(get(self.ui.chkBarColour, 'Value'));
                % false (default) = per-trial colour/position shuffle; true =
                % every category fixed at its own direction (Short->Right,
                % Mid->Up, Long->Left) -- see FixedTargetLayout.m.
                params.fixedTargetLayout = logical(get(self.ui.chkFixedTargetLayout, 'Value'));
                stopQuota = str2double(get(self.ui.edStopQuota, 'String'));
                if get(self.ui.popStopMode, 'Value') == 1
                    params.stopMode = 'correctTrials';
                    params.maxCorrectTrials = stopQuota;   % correct trials needed per (length,position) combo
                else
                    params.stopMode = 'blocks';
                    params.numBlocks = stopQuota;          % 48-trial blocks (1 rep per combo each)
                end
            end

            % Off-rig test mode: belt-and-suspenders -- offRigToggle_Callback
            % already locks popInputSource to 'mouse' when this is checked.
            if isfield(self.ui, 'chkOffRig') && get(self.ui.chkOffRig, 'Value')
                params.inputSource = 'mouse';
            end
        end

        function setStatus(self, statusStr, color)
            if nargin < 3 || isempty(color)
                color = [0 0 0.6];
            end
            set(self.ui.textStatus, 'String', statusStr, 'ForegroundColor', color);
        end

        % =====================================================================
        % PANEL BUILDERS
        % =====================================================================

        function buildSessionPanel(self)
            % 785 (not the figure's own 745-since-grown height) -- see
            % buildTaskParamsPanel's "Blocks per segment" row: that panel
            % grew 40px taller to fit it, so this panel (and the figure
            % itself) shifted up by the same 40px to keep every original
            % gap/margin unchanged. Keep the two figure-height literals in
            % step if either panel is resized again.
            y = 785 - 20;
            pSession = uipanel('Parent', self.fig, 'Title', 'Session', self.titleFont{:}, ...
                'BackgroundColor', self.panelBG, 'Units', 'pixels', 'Position', [20 y-95 1200 100]);

            cfg = ConfigSession();
            d   = ConfigOrgParams.getTaskDefaults();

            % Subject type drives BOTH the subject list beside it (named
            % monkeys vs. anonymous PX-n participants) and the two trial
            % repetition checkboxes at the right-hand end of this panel --
            % which is why those two sit here, next to the control that
            % flips them, rather than in the Task parameters panel with the
            % rest of the engine settings.
            uicontrol('Parent', pSession, 'Style', 'text', 'String', 'Subject type', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [15 55 90 18], 'HorizontalAlignment', 'left');
            self.ui.popSubjectType = uicontrol('Parent', pSession, 'Style', 'popupmenu', ...
                'String', {'Monkey', 'Human'}, 'Position', [15 35 110 22], ...
                'Callback', @(~, ~) self.subjectTypeSelect_Callback(), ...
                'TooltipString', ['Which population this session is run with. Switching to Human turns ' ...
                'the Subject list into a "Participant #" box -- type 3 and the session registers as ' ...
                'PX-3 -- and unchecks Retries and Requeue automatically, since both exist to train and ' ...
                'verify an animal that cannot be instructed. Either checkbox can still be re-checked by ' ...
                'hand for a particular session. Configure the monkey list and these defaults in ' ...
                'ConfigSession.m.']);

            % Subject and Participant # occupy the SAME rectangle, one
            % visible at a time (subjectTypeSelect_Callback swaps them):
            % they answer the same question for the two populations, and
            % this panel has no free width left for a second control.
            self.ui.txtSubjectLabel = uicontrol('Parent', pSession, 'Style', 'text', ...
                'String', 'Subject', self.labelFont{:}, 'BackgroundColor', self.panelBG, ...
                'Position', [135 55 90 18], 'HorizontalAlignment', 'left');
            self.ui.popSubject = uicontrol('Parent', pSession, 'Style', 'popupmenu', ...
                'String', cfg.validMonkeys, 'Position', [135 35 130 22]);
            self.ui.edHumanNum = uicontrol('Parent', pSession, 'Style', 'edit', 'String', '', ...
                'Position', [135 35 130 22], 'Visible', 'off', ...
                'Callback', @(~, ~) self.humanNumEdit_Callback(), ...
                'TooltipString', ['Participant number for this session. The session registers as ' ...
                cfg.humanIdPrefix '-<number> (type 3, get ' cfg.humanIdPrefix '-3), which is the only ' ...
                'identifier that reaches the output filenames and data files -- no name, no initials. ' ...
                'Must be a positive whole number; the box turns red and the session will not register ' ...
                'otherwise.']);

            uicontrol('Parent', pSession, 'Style', 'text', 'String', 'Project', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [275 55 80 18], 'HorizontalAlignment', 'left');
            self.ui.popProject = uicontrol('Parent', pSession, 'Style', 'popupmenu', ...
                'String', {cfg.validProject}, 'Position', [275 35 165 22]);

            self.ui.butRegister = uicontrol('Parent', pSession, 'Style', 'pushbutton', ...
                'String', 'Register session', 'Position', [450 35 130 26], ...
                'Callback', @(~, ~) self.registerSession_Callback());

            uicontrol('Parent', pSession, 'Style', 'text', 'String', 'Task type', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [590 55 90 18], 'HorizontalAlignment', 'left');
            self.ui.popTaskType = uicontrol('Parent', pSession, 'Style', 'popupmenu', ...
                'String', {'Center-Out (categorization)', 'Center-In (hold)'}, 'Position', [590 35 160 22], ...
                'Callback', @(~, ~) self.taskTypeSelect_Callback(), ...
                'TooltipString', ['Center-Out: bar-length categorization, launches CenterOutTask -- ' ...
                'uses most of the Task parameters panel below (Session mode, Bar set, Show cue, Stop-by ' ...
                'quota, rig geometry), plus Reward/timing/Input source/Max attempts. Center-In: launches ' ...
                'CenterInTask -- no bar/cue/targets, just enter and hold the centre circle for reward; ' ...
                'only uses Reward/timing/Input source/Max attempts plus its own "target correct trials" ' ...
                'field in that panel.']);

            uicontrol('Parent', pSession, 'Style', 'text', 'String', 'Session ID', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [760 55 70 18], 'HorizontalAlignment', 'left');
            self.ui.edSessionId = uicontrol('Parent', pSession, 'Style', 'edit', 'String', '', ...
                'Enable', 'inactive', 'Position', [760 35 90 22]);

            uicontrol('Parent', pSession, 'Style', 'text', 'String', 'Date', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [860 55 70 18], 'HorizontalAlignment', 'left');
            self.ui.edDate = uicontrol('Parent', pSession, 'Style', 'edit', 'String', '', ...
                'Enable', 'inactive', 'Position', [860 35 90 22]);

            % --- Trial repetition (both engines / Center-Out only) --------
            % The two ways a session can run MORE trials than it planned.
            % Checked by default (the monkey configuration), unchecked
            % automatically when Subject type is Human -- see
            % subjectTypeSelect_Callback and ConfigSession.m. Live in the
            % Session panel because the subject is what decides them; the
            % engines read them as orgParams.useRetries/useRequeue.
            self.ui.chkUseRetries = uicontrol('Parent', pSession, 'Style', 'checkbox', ...
                'String', 'Retries (repeat a failed stimulus)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [15 8 245 20], ...
                'Value', double(d.useRetries), 'Callback', @(~, ~) self.retriesToggle_Callback(), ...
                'TooltipString', ['Correction procedure: a failed attempt shows the SAME stimulus again ' ...
                '(reshuffled) up to "Max attempts" times before the sequence moves on, and the stop ' ...
                'quota counts CORRECT trials, so a combination keeps owing its quota until it comes ' ...
                'out right. Unchecked = exactly one attempt per stimulus, whatever Max attempts says ' ...
                '(that field greys out), and the quota counts presentations instead: a wrong answer ' ...
                'costs that slot and lowers the percentage rather than buying another go, so the ' ...
                'session lasts exactly its Trials budget. Both engines honour the attempt limit; the ' ...
                'quota rule it drives (the "Quota counts presentations" readout in Task parameters) ' ...
                'is Center-Out only -- Center-In always counts rewarded holds.']);
            self.ui.chkUseRequeue = uicontrol('Parent', pSession, 'Style', 'checkbox', ...
                'String', 'Requeue original position', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [270 8 245 20], ...
                'Value', double(d.useRequeue), ...
                'TooltipString', ['Center-Out only. When a (bar length, position) combination resolves ' ...
                'ambiguously -- it only succeeded after a reshuffled retry, or it exhausted every ' ...
                'attempt -- one clean, un-reshuffled repeat of it is appended to the end of the ' ...
                'sequence, and that repeat is what counts towards the quota. Unchecked = every trial ' ...
                'counts where it stands and the session runs exactly the trials it planned.']);
        end

        function buildTaskParamsPanel(self)
            % Reward/timing/Input source/Max attempts (shared by both
            % engines) plus the Center-Out-only controls (Session mode, Bar
            % set, Stop-by quota, rig geometry) and the one Center-In-only
            % field (target correct trials).
            %
            % Every initial field value below comes from
            % ConfigOrgParams.getTaskDefaults() -- the SAME struct
            % runTask() merges operator input against -- instead of a
            % second, separate literal here. Edit that one file to change
            % a default; it updates both what this console shows on open
            % AND what an engine falls back to if a field is ever missing.
            d = ConfigOrgParams.getTaskDefaults();
            % Deliberately still the ORIGINAL 745 literal, not the figure's
            % current (785) height: this anchors the panel's BOTTOM edge,
            % which stays put -- only the panel's HEIGHT below grew (435 ->
            % 475, see the "Blocks per segment" row further down), adding
            % its extra 40px as headroom above the existing top row instead
            % of moving anything already laid out. buildSessionPanel's y
            % moved up by that same 40px so the gap between the two panels
            % is unchanged.
            y = 745 - 20 - 100 - 15;
            p = uipanel('Parent', self.fig, 'Title', 'Task parameters', self.titleFont{:}, ...
                'BackgroundColor', self.panelBG, 'Units', 'pixels', 'Position', [20 y-430 1200 475]);

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Reward valve time (s)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [15 392 150 18], 'HorizontalAlignment', 'left');
            self.ui.edReward = self.mkEdit(p, num2str(d.Reward), [170 390 60 22]);

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Stop by', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [260 392 45 18], 'HorizontalAlignment', 'left');
            stopModeStrings = {'Correct trials', 'Blocks'};
            if strcmpi(d.stopMode, 'blocks')
                stopModeValue = 2;
            else
                stopModeValue = 1;
            end
            self.ui.popStopMode = uicontrol('Parent', p, 'Style', 'popupmenu', ...
                'String', stopModeStrings, 'Position', [305 390 105 22], 'Value', stopModeValue, ...
                'Callback', @(~, ~) self.stopModeSelect_Callback());
            % Quota field: correct trials needed per (length,position) combo
            % when "Correct trials" is selected, or number of 48-trial
            % blocks (1 rep per combo each) when "Blocks" is selected --
            % same field, meaning set by the popup above.
            if strcmpi(d.stopMode, 'blocks')
                edStopQuotaInit = num2str(d.numBlocks);
            else
                edStopQuotaInit = num2str(d.maxCorrectTrials);
            end
            self.ui.edStopQuota = self.mkEdit(p, edStopQuotaInit, [415 390 55 22]);
            % Keep the Run panel's "Trials budget" preview honest: it is
            % derived from this quota, the bar set and the bar subset, so
            % every one of those has to refresh it (see taskTypeSelect_Callback).
            set(self.ui.edStopQuota, 'Callback', @(~, ~) self.taskTypeSelect_Callback());
            % What the quota above counts. A READOUT, not a control: it is
            % driven by the Retries checkbox in the Session panel (see
            % retriesToggle_Callback) and always disabled, so the two can
            % never be set to disagree. Its initial value is therefore
            % derived from useRetries, not read from quotaByPresentations --
            % that field stays in ConfigOrgParams for offline scripts, which
            % are free to set the two independently.
            self.ui.chkQuotaPresentations = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Quota counts presentations', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [945 390 250 20], ...
                'Value', double(~d.useRetries), 'Enable', 'off', ...
                'TooltipString', ['Follows the Retries checkbox above -- not set here. Retries ON: the ' ...
                'quota counts CORRECT trials, so a failed combination still owes its quota and comes ' ...
                'round again later; errors make the session longer, which is the point of a correction ' ...
                'procedure. Retries OFF: the quota counts presentations, so one deliberate answer ' ...
                'fills each slot whether it was right or wrong, and the session runs exactly the ' ...
                '"Trials budget" shown on the right no matter how the subject does. Center-Out ' ...
                'only -- a Center-In session always runs until its target number of rewarded holds ' ...
                'is reached, whatever this says.']);

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Session mode', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [510 392 90 18], 'HorizontalAlignment', 'left');
            sessionModeStrings = {'3cat', '2cat', 'alternate', 'interleaved'};
            sessionModeValue = find(strcmpi(sessionModeStrings, d.sessionMode), 1);
            self.ui.popSessionMode = uicontrol('Parent', p, 'Style', 'popupmenu', ...
                'String', sessionModeStrings, 'Position', [608 390 100 22], 'Value', sessionModeValue, ...
                'Callback', @(~, ~) self.sessionModeSelect_Callback(), ...
                'TooltipString', ['How many categories a trial draws from. Locked to 3cat while a ' ...
                'reduced Bar set (prototypes or extremes) is selected: those carry one length per ' ...
                'category, so a 2-category framing would only regroup the three prototypes instead ' ...
                'of testing a Short/Long boundary. Pick the full 12-length set to use the other ' ...
                'modes.']);

            % 'alternate' only: how many consecutive FULL blocks of each
            % category count run before switching (see CenterOutTask.m's
            % alternateBlocks2cat/3cat). Greyed out by sessionModeSelect_Callback
            % for every other mode -- the fields are still always gathered on
            % Start (see gatherParams below) so a value typed in while
            % 'alternate' was selected survives a round trip through another
            % mode, exactly like Max attempts follows Retries.
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Alternate: blocks/segment', ...
                self.labelFont{:}, 'BackgroundColor', self.panelBG, ...
                'Position', [510 444 200 18], 'HorizontalAlignment', 'left');
            uicontrol('Parent', p, 'Style', 'text', 'String', '2cat', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [510 420 35 18], 'HorizontalAlignment', 'left');
            self.ui.edAlternateBlocks2cat = self.mkEdit(p, num2str(d.alternateBlocks2cat), [548 418 45 22]);
            uicontrol('Parent', p, 'Style', 'text', 'String', '3cat', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 420 35 18], 'HorizontalAlignment', 'left');
            self.ui.edAlternateBlocks3cat = self.mkEdit(p, num2str(d.alternateBlocks3cat), [638 418 45 22]);
            set([self.ui.edAlternateBlocks2cat, self.ui.edAlternateBlocks3cat], 'TooltipString', ...
                ['Session mode ''alternate'' only: how many consecutive FULL blocks (blockSize trials ' ...
                'each) of 2-cat run before switching to 3-cat, and how many blocks of 3-cat before ' ...
                'switching back -- e.g. 10 and 10 runs 10 blocks of 2-cat, then 10 blocks of 3-cat, ' ...
                'then 10 more of 2-cat, ... for the rest of the session. Both default to 1, the ' ...
                'original strict one-block-at-a-time alternation. Ignored by every other Session mode.']);

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Input source', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [715 392 80 18], 'HorizontalAlignment', 'left');
            inputSourceStrings = {'joystick', 'mouse', 'rz2adc'};
            inputSourceValue = find(strcmpi(inputSourceStrings, d.inputSource), 1);
            self.ui.popInputSource = uicontrol('Parent', p, 'Style', 'popupmenu', ...
                'String', inputSourceStrings, 'Position', [803 390 130 22], 'Value', inputSourceValue, ...
                'TooltipString', ['rz2adc = second, ADC-wired analog joystick relayed over UDP from ' ...
                'Computer 1 (JoystickRelayToTask.m -> SetupRZ2Joystick.m/ReadRZ2Joystick.m). Its ' ...
                'port/scale/offset wiring is configured in ConfigOrgParams.m (rz2UdpPort etc), not here.']);

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Timing (seconds)', 'FontWeight', 'bold', ...
                'FontSize', 10, 'BackgroundColor', self.panelBG, 'Position', [15 357 200 18], ...
                'HorizontalAlignment', 'left');
            timingRows = {
                'Hold time, base',            'holdTimeBase'
                'Hold time, +/- jitter',      'holdTimeDelta'
                'Bar duration',               'barDuration'
                'Delay: bar -> cue',          'delayStimToRule'
                'Delay: cue -> targets',      'barToTargetDelay'
                'Cue duration',               'cueDuration'
                'Reach: decision limit (s)',   'maxDecisionTime'
                'Reach: movement limit (s)',   'maxExecutionTime'
                'Success feedback (s)',        'tarHoldFeed'
                'Error feedback (s)',          'tarErrorFeed'
                'Min target hold (s)',         'minTarHoldTime'
                'ITI (success)',              'ITI'
                'ITI +/- jitter',             'ITIDelta'
                'ITI (error)',                'ITIError'
                };
            self.ui.edTiming = struct();
            rowY = 330;
            rowPitch = 23;        % tightened from 25 to fit the extra reach-limit row
            minTarHoldRow = 11;   % 'Min target hold (s)' -- extra gap right below it
                                % separates per-trial timing (above) from ITI timing (below)
            for i = 1:size(timingRows, 1)
                uicontrol('Parent', p, 'Style', 'text', 'String', timingRows{i, 1}, self.labelFont{:}, ...
                    'BackgroundColor', self.panelBG, 'Position', [15 rowY 170 18], 'HorizontalAlignment', 'left');
                self.ui.edTiming.(timingRows{i, 2}) = self.mkEdit(p, num2str(d.(timingRows{i, 2})), [190 rowY-2 60 22]);
                if i == minTarHoldRow
                    rowY = rowY - rowPitch - 15;
                else
                    rowY = rowY - rowPitch;
                end
            end

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Rig geometry (pixels)', 'FontWeight', 'bold', ...
                'FontSize', 10, 'BackgroundColor', self.panelBG, 'Position', [300 357 220 18], ...
                'HorizontalAlignment', 'left');
            % centerRad is the diameter of the centre hold window -- the
            % single geometry parameter that changes how hard the task is to
            % hold, so it is editable rather than baked in. Default 200
            % matches CenterOutTask's own OrgGet fallback; note the
            % pre-refactor engine (centerOutTask_v2_2.m, no longer in this
            % repo) used 150, so a wider window means fewer
            % early-exit errors for reasons that have nothing to do with the
            % subject improving. Pin it explicitly when comparing sessions
            % across code generations.
            geomRows = {
                'Centre window diameter',   'centerRad'
                'Target size (diameter)',   'targetRad'
                'Centre -> target distance','centerToTargetDist'
                'Cue dot diameter',         'cueSize'
                'Cue dot spacing',          'cueDistance'
                'Cue vertical offset',      'cueYOffset'
                'Bar height',                'barHeight'
                'Bar vertical offset',      'barOffsetY'
                };
            self.ui.edGeom = struct();
            rowY = 330;
            for i = 1:size(geomRows, 1)
                uicontrol('Parent', p, 'Style', 'text', 'String', geomRows{i, 1}, self.labelFont{:}, ...
                    'BackgroundColor', self.panelBG, 'Position', [300 rowY 170 18], 'HorizontalAlignment', 'left');
                self.ui.edGeom.(geomRows{i, 2}) = self.mkEdit(p, num2str(d.(geomRows{i, 2})), [475 rowY-2 60 22]);
                rowY = rowY - 25;
            end

            % Category colours (hex), independently for 2-cat and 3-cat
            % trials -- CenterOutTask.m builds two separate colour arrays
            % from these instead of one shared table, so a 2-cat trial's
            % Short/Long need not match the colours a 3-cat trial's
            % Short/Long use. Defaults reproduce ColorCategoryMap's built-in
            % ORANGE/GREEN/BLUE exactly (2-cat's defaults match 3-cat's own
            % Short/Long, matching this project's behaviour before these
            % fields existed, when 2-cat trials simply reused those rows).
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Category colours (hex)', 'FontWeight', 'bold', ...
                'FontSize', 10, 'BackgroundColor', self.panelBG, 'Position', [300 rowY-13 220 18], ...
                'HorizontalAlignment', 'left');
            rowY = rowY - 43;
            uicontrol('Parent', p, 'Style', 'text', 'String', '3-cat S/M/L', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [300 rowY 90 18], 'HorizontalAlignment', 'left');
            self.ui.edColor3CatShort = self.mkEdit(p, d.color3CatShort, [395 rowY-2 50 22]);
            self.ui.edColor3CatMid   = self.mkEdit(p, d.color3CatMid,   [450 rowY-2 50 22]);
            self.ui.edColor3CatLong  = self.mkEdit(p, d.color3CatLong,  [505 rowY-2 50 22]);
            rowY = rowY - 30;
            uicontrol('Parent', p, 'Style', 'text', 'String', '2-cat S/L', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [300 rowY 90 18], 'HorizontalAlignment', 'left');
            self.ui.edColor2CatShort = self.mkEdit(p, d.color2CatShort, [395 rowY-2 50 22]);
            self.ui.edColor2CatLong  = self.mkEdit(p, d.color2CatLong,  [450 rowY-2 50 22]);

            % RZ2 analog-joystick gain (only used when Input source =
            % 'rz2adc'): multiplies the relay's already-normalized [-1, 1]
            % X/Y on top of the screen-pixel scaling ReadCursorPosition.m
            % applies (xCenter + screenXpixels * vx * rz2.scaleX). Was a
            % ConfigOrgParams.m-only literal before; exposed here so gain can
            % be tuned per session without editing code. rz2OffsetY (Y-only
            % centring offset) stays code-only -- rig wiring, not something
            % an operator retunes session to session.
            rowY = rowY - 30;
            uicontrol('Parent', p, 'Style', 'text', 'String', 'RZ2 gain X / Y', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [300 rowY 100 18], 'HorizontalAlignment', 'left');
            self.ui.edRZ2ScaleX = self.mkEdit(p, num2str(d.rz2ScaleX), [400 rowY-2 55 22]);
            self.ui.edRZ2ScaleY = self.mkEdit(p, num2str(d.rz2ScaleY), [460 rowY-2 55 22]);
            set(self.ui.edRZ2ScaleX, 'TooltipString', ...
                ['Gain multiplier on the RZ2 analog joystick''s X axis (Input source = ''rz2adc'' only) -- ' ...
                'see SetupRZ2Joystick.m/ReadCursorPosition.m. The relay already normalizes raw volts to ' ...
                '[-1, 1]; this scales on top of that, same role as the USB joystick''s fixed -1.3 factor.']);
            set(self.ui.edRZ2ScaleY, 'TooltipString', ...
                ['Gain multiplier on the RZ2 analog joystick''s Y axis (Input source = ''rz2adc'' only) -- ' ...
                'JoystickRelayToTask.m reads this from a second gizmo, APICh2/Adc2, independently of X.']);

            % USB 'joystick' axis gain (Input source = 'joystick' only) -- the
            % factor that used to be hardcoded -1.3 in ReadCursorPosition.m.
            rowY = rowY - 30;
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Joystick gain (USB)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [300 rowY 100 18], 'HorizontalAlignment', 'left');
            self.ui.edJoyGain = self.mkEdit(p, num2str(d.joyGain), [400 rowY-2 55 22]);
            set(self.ui.edJoyGain, 'TooltipString', ...
                ['Gain on the USB joystick''s X and Y axes (Input source = ''joystick'' only), applied on ' ...
                'top of the screen-pixel scaling in ReadCursorPosition.m. Sign sets axis direction, ' ...
                'magnitude sets pixels-per-unit travel. Was a hardcoded -1.3.']);

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Task options', 'FontWeight', 'bold', ...
                'FontSize', 10, 'BackgroundColor', self.panelBG, 'Position', [600 357 220 18], ...
                'HorizontalAlignment', 'left');
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Max attempts (retries)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 330 170 18], 'HorizontalAlignment', 'left');
            self.ui.edMaxAttempts = self.mkEdit(p, num2str(d.maxStimAttempts), [775 328 60 22]);

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Bar set', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 305 170 18], 'HorizontalAlignment', 'left');
            % Order here defines the popup indices stimulusSetSelection()
            % maps back to engine names -- keep the two in step.
            stimulusSetStrings = {'12 lengths (full)', '3 prototypes (midpoints)', ...
                                  '3 extremes (short/mid/long)', '2 prototypes (Short/Long)'};
            if strcmpi(d.stimulusSet, 'prototypes3')
                stimulusSetValue = 2;
            elseif strcmpi(d.stimulusSet, 'extremes3')
                stimulusSetValue = 3;
            elseif strcmpi(d.stimulusSet, 'prototypes2')
                stimulusSetValue = 4;
            else
                stimulusSetValue = 1;
            end
            self.ui.popStimulusSet = uicontrol('Parent', p, 'Style', 'popupmenu', ...
                'String', stimulusSetStrings, 'Position', [600 283 235 22], 'Value', stimulusSetValue, ...
                'Callback', @(~, ~) self.stimulusSetSelect_Callback(), ...
                'TooltipString', ['Which bar lengths this session runs. Both reduced sets are 3 lengths ' ...
                'x 4 positions = 12 trials per block instead of 48, one length per category, so the ' ...
                'targets stay Short/Mid/Long either way. Prototypes: the MEDIAN length of each ' ...
                'category (4.40 / 5.85 / 7.30 deg VA). Extremes: the shortest bar, the Mid ' ...
                'category''s midpoint ' ...
                'and the longest bar (4.00 / 5.85 / 7.80 deg VA) -- the widest separation the stimulus ' ...
                'table allows, i.e. the easiest discrimination, for a first session above the training ' ...
                'phases.']);

            % Center-Out only: whether the selection-cue dots actually get
            % drawn during the CUE epoch. Off just blanks that window
            % instead of skipping it, so turning this off does not change
            % trial timing -- see orgParams.useCue in CenterOutTask.m.
            self.ui.chkShowCue = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Show cue', self.labelFont{:}, 'BackgroundColor', self.panelBG, ...
                'Position', [600 255 200 20], 'Value', double(d.useCue), ...
                'TooltipString', ['Off blanks the CUE epoch instead of drawing the selection-cue dots -- ' ...
                'trial timing is unchanged (still waits the full Cue duration), only the dots are hidden.']);

            % Center-Out only: whether the bar is white (subject categorizes by
            % length alone) or fully coloured (the category is visually revealed).
            % 0 = white (default, correct task); 1 = full colour (useful in early
            % training to teach the category-colour mapping before length alone).
            self.ui.chkBarColour = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Reveal category colour (bar)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 230 235 20], 'Value', d.barColorIntensity, ...
                'TooltipString', ['When checked: bar is drawn in its category colour (Orange/Green/Blue), ' ...
                'making length irrelevant. Use during early training to teach the colour-category mapping. ' ...
                'When unchecked (default): bar is always white and the subject must use length.']);

            % Center-Out only: pins every category to its own fixed cardinal
            % direction (Short->Right, Mid->Up, Long->Left; Down unused)
            % instead of DrawTrialLayout.m reshuffling colour/position every
            % trial -- see orgParams.fixedTargetLayout in ConfigOrgParams.m.
            self.ui.chkFixedTargetLayout = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Fixed target layout (no shuffle)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 205 300 20], ...
                'Value', double(d.fixedTargetLayout), ...
                'TooltipString', ['When checked: each category always appears at the same spot, every ' ...
                'trial -- Short always Right, Mid always Up, Long always Left (Down is never used). ' ...
                'When unchecked (default): DrawTrialLayout.m reshuffles which direction/colour each ' ...
                'category gets every trial.']);

            % Center-In only: flat target trial count -- see getSessionParams
            % for why this differs from Center-Out's Stop-by/quota. Called
            % out as its own bold sub-section (rather than folded into one
            % inline label) since it's the one field here that has nothing
            % to do with Center-Out.
            %
            % Deliberately NOT sourced from ConfigOrgParams: this field's own
            % identity is Center-In's flat target-trial count, distinct from
            % the shared maxCorrectTrials Center-Out's "Stop by" quota above
            % already uses (default 100) -- giving it its own ConfigOrgParams
            % field just to hold a second, differently-named default would
            % add a field without removing any duplication, so it stays a
            % literal here.
            % Every Center-In control lives in this one column. Fixed grid:
            % header at y=182, then rows every 22 px down to y=6.
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Center-In', 'FontWeight', 'bold', ...
                'FontSize', 10, 'BackgroundColor', self.panelBG, 'Position', [600 182 220 18], ...
                'HorizontalAlignment', 'left');
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Target correct trials', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 160 170 18], 'HorizontalAlignment', 'left');
            self.ui.edCenterInTrials = self.mkEdit(p, '50', [775 160 60 22]);
            % Unconditionally rewarded holds -- unlike Center-Out's quota
            % above, this one is never reinterpreted as presentations by the
            % Retries checkbox, so say so where the operator sets it.
            set(self.ui.edCenterInTrials, 'TooltipString', ...
                ['How many REWARDED centre holds end the session (Center-In only, independent of ' ...
                'Center-Out''s Stop-by quota). Failed attempts do not count towards it, so a session ' ...
                'runs as long as it needs to. Abort is the backstop for a subject that never engages.']);

            % Reach-to-target mode (Center-In): adds a single peripheral target
            % (Right/Up/Left/Down) after the centre hold, at a weighted
            % position. Off = pure hold. There is NO foil in Center-In (that
            % lives in the Center-Out pre-training); every Center-In error is a
            % failed hold/reach and always flashes.
            self.ui.chkCenterInReach = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Reach to target (weighted position)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 138 300 20], ...
                'Value', double(d.useTargetReach), ...
                'TooltipString', ['Adds one peripheral target after the centre hold -- reach it and hold ' ...
                '(Target timeout / Min target hold fields) before reward. Position is drawn from the ' ...
                'weights below. Off = pure hold-in-centre for reward.']);

            % Reach-only: weighted target position (R,U,L,D).
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Target weights (R,U,L,D)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 116 170 18], 'HorizontalAlignment', 'left');
            self.ui.edCenterInWeights = self.mkEdit(p, strjoin(arrayfun(@num2str, d.targetWeights, ...
                'UniformOutput', false), ','), [775 114 100 22]);

            % Reach-only: peripheral target fill colour (hex).
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Target colour (hex)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 94 170 18], 'HorizontalAlignment', 'left');
            self.ui.edCenterInTargetColor = self.mkEdit(p, d.centerInTargetColor, [775 92 60 22]);

            % Pure-hold-only: how far the hold-target can land from true centre
            % each new trial -- see CenterInTask.m's "CENTRE JITTER" header.
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Center jitter (+/- px)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 72 170 18], 'HorizontalAlignment', 'left');
            self.ui.edCenterInJitter = self.mkEdit(p, num2str(d.centerJitterRange), [775 70 60 22]);
            set(self.ui.edCenterInJitter, 'TooltipString', ...
                ['+/- px random offset of the hold-target''s drawn position each new trial. Only applies ' ...
                'in PURE hold mode (ignored in reach mode -- the hold-target pins to true centre).']);

            % Off (default): the hold-ring is always green. On: restores the
            % gray-while-waiting/green-while-holding cue -- see CenterInTask.m.
            self.ui.chkHoldColorEffect = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Gray until holding (else always green)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [600 4 300 20], ...
                'Value', double(d.useHoldColorEffect), ...
                'TooltipString', ['Off (default): the centre hold-ring is always green. On: the ring is ' ...
                'gray while waiting to enter the centre (or before the hold timer starts), and turns ' ...
                'green once the hold officially begins.']);

            % Center-Out only: the two colour-matching drills that precede
            % the categorization task, plus which bar lengths run at all.
            % Their own column because they change what the session IS, not
            % just one of its parameters -- see CenterOutTask.m's "Training
            % phases" block and ParseBarSubset.m.
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Pre-training Center Out', ...
                'FontWeight', 'bold', 'FontSize', 10, 'BackgroundColor', self.panelBG, ...
                'Position', [950 357 220 18], 'HorizontalAlignment', 'left');
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Training phase', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [950 330 170 18], 'HorizontalAlignment', 'left');
            self.ui.popTrainingPhase = uicontrol('Parent', p, 'Style', 'popupmenu', ...
                'String', {'Off (categorization)', '1 - match: one target', ...
                '2 - match + foil'}, 'Position', [950 308 235 22], ...
                'Value', d.trainingPhase + 1, ...
                'TooltipString', ['Phase 1: a single target, painted the same colour as the bar -- ' ...
                'nothing to choose between, so only early exits and timeouts can fail a trial. ' ...
                'Phase 2: that same matching target plus one foil in a different category colour; ' ...
                'reaching the foil is a wrong-target error and gets the usual error flash. Both ' ...
                'phases draw the bar at full category colour and hide the cue dots (trial timing ' ...
                'is unchanged). Off = the real length-categorization task.']);

            uicontrol('Parent', p, 'Style', 'text', 'String', 'Bar lengths (subset)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [950 278 170 18], 'HorizontalAlignment', 'left');
            self.ui.edBarSubset = self.mkEdit(p, d.barLengthSubset, [950 256 100 22]);
            set(self.ui.edBarSubset, 'Callback', @(~, ~) self.taskTypeSelect_Callback());
            set(self.ui.edBarSubset, 'TooltipString', ...
                ['Which lengths of the "Bar set" above actually run. Empty (or "all") = every one ' ...
                'of them. "5" = that single length; "1,5,9" = a list; "1-4,9-12" = ranges. The ' ...
                'trial sequence, the per-(length,position) quota and the end-of-session tables all ' ...
                'shrink to the selection. Pairs with the training phases: one length means one ' ...
                'target colour to learn at a time.']);

            % Valve calibration, used ONLY to report water in the
            % end-of-session summary (SessionReport.reward) -- it never
            % changes what the valve does. Shared by both engines. Sits here
            % rather than beside "Reward valve time" purely because the top
            % row of this panel is full.
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Reward', 'FontWeight', 'bold', ...
                'FontSize', 10, 'BackgroundColor', self.panelBG, ...
                'Position', [950 222 220 18], 'HorizontalAlignment', 'left');
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Water mL per valve-s', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [950 195 170 18], 'HorizontalAlignment', 'left');
            self.ui.edRewardMlPerSec = self.mkEdit(p, num2str(d.rewardMlPerSec), [950 173 100 22]);
            set(self.ui.edRewardMlPerSec, 'TooltipString', ...
                ['This rig''s valve calibration: mL of water delivered per SECOND the valve is ' ...
                'open. Only used to convert the session''s total valve-open time into mL in the ' ...
                'end-of-session report -- it never changes how long the valve actually opens. ' ...
                'Leave at 0 if the valve is not calibrated; the report then prints valve-open ' ...
                'seconds only instead of guessing a volume.']);

            % Pre-training Center-Out feedback options (in the space the
            % removed Kinematics block used to occupy). "Show error flash"
            % controls ONLY the wrong-target (phase-2 foil) flash; a failed
            % hold/reach always flashes. Off by default.
            uicontrol('Parent', p, 'Style', 'text', 'String', 'Pre-training feedback', 'FontWeight', 'bold', ...
                'FontSize', 10, 'BackgroundColor', self.panelBG, ...
                'Position', [950 140 220 18], 'HorizontalAlignment', 'left');
            self.ui.chkShowErrorFlash = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Show error flash (wrong-target pick)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [950 114 300 20], ...
                'Value', double(d.showErrorFlash), ...
                'TooltipString', ['Off (default): reaching the phase-2 foil (wrong target) does not flash. ' ...
                'On: it flashes. A failed hold/reach (early exit) always flashes regardless.']);
            % Gray-until-holding for Center-Out (same effect and default as
            % Center-In's own checkbox). On (default): centre ring gray while
            % waiting, green once the hold starts. Off: always green.
            self.ui.chkHoldColorEffectCO = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Gray until holding', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [950 90 300 20], ...
                'Value', double(d.useHoldColorEffect), ...
                'TooltipString', ['On (default): the centre hold-ring is gray while waiting to enter / ' ...
                'before the hold timer starts, green once the hold begins. Off: always green.']);
            % Strict hold: abort the trial (no reward) if the cursor leaves the
            % target even once before completing the hold. Off (default): the
            % lenient behaviour -- leaving resets the hold timer, and returning
            % to the target and holding minTarHoldTime still earns the reward.
            self.ui.chkStrictHold = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Strict hold (abort if leaves target)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [950 66 300 20], ...
                'Value', double(d.strictHold), ...
                'TooltipString', ['Off (default): leaving the target resets the hold timer; ' ...
                'returning and holding minTarHoldTime still gives reward. On: any exit from ' ...
                'the target before completing the hold aborts the trial with no reward (early exit).']);
            % Training error flash: strict feedback during pre-training ONLY
            % (Training phase 1 or 2). On (default): the foil pick is a flashed
            % wrong-target error -- which also switches OFF the foil-forgiving
            % mode -- and releasing the correct target before the hold is done
            % is a flashed hold-break error (ErrorType 3, counted separately).
            % Has no effect at all when Training phase is "0 - off".
            self.ui.chkTrainingErrorFlash = uicontrol('Parent', p, 'Style', 'checkbox', ...
                'String', 'Training error flash (foil + hold-break)', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [950 42 300 20], ...
                'Value', double(d.trainingErrorFlash), ...
                'TooltipString', ['PRE-TRAINING ONLY (Training phase 1 or 2); ignored in the ' ...
                'categorization task. On (default): reaching the foil is a wrong-target error ' ...
                'with flash (and the foil no longer gets forgiven), and releasing the correct ' ...
                'target before completing the hold is a hold-break error (ErrorType 3) with ' ...
                'flash, counted separately from early exits. Off: the lenient behaviour.']);

            % There are deliberately NO kinematics controls in this GUI:
            % CenterOutTask.m no longer computes per-trial kinematics at all.
            % Nothing here ever affected what gets RECORDED anyway -- the
            % trajectory exports are always written from the raw samples, and
            % every filtering/differentiation choice now belongs to whatever
            % offline analysis reads them.
        end

        function buildRunPanel(self)
            y = 745 - 20 - 100 - 15 - 435 - 15;
            pRun = uipanel('Parent', self.fig, 'Title', 'Run', self.titleFont{:}, ...
                'BackgroundColor', self.panelBG, 'Units', 'pixels', 'Position', [20 y-140 1200 140]);

            self.ui.butStart = uicontrol('Parent', pRun, 'Style', 'pushbutton', 'String', 'Start', ...
                'FontSize', 11, 'FontWeight', 'bold', 'Position', [15 82 120 34], ...
                'Callback', @(~, ~) self.start_Callback(), 'Enable', 'off');
            self.ui.butAbort = uicontrol('Parent', pRun, 'Style', 'pushbutton', 'String', 'Abort', ...
                'FontSize', 11, 'Position', [145 82 120 34], ...
                'Callback', @(~, ~) self.abort_Callback(), 'Enable', 'off');

            uicontrol('Parent', pRun, 'Style', 'text', 'String', 'Status', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [280 100 200 16], 'HorizontalAlignment', 'left');
            self.ui.textStatus = uicontrol('Parent', pRun, 'Style', 'text', 'String', 'Idle', ...
                'FontSize', 10, 'ForegroundColor', [0 0 0.6], 'BackgroundColor', self.panelBG, ...
                'Position', [280 80 550 20], 'HorizontalAlignment', 'left');

            % These 4 boxes (this row's first three + Status above) are the
            % exact same handles whichever engine is running (CenterOutTask
            % or CenterInTask) writes into every frame -- see runTask, which
            % points the engine's fixed handle names directly at these
            % controls, so there's one labeled place to watch a run live
            % regardless of which engine launched.
            uicontrol('Parent', pRun, 'Style', 'text', 'String', 'Good trials', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [15 52 70 18], 'HorizontalAlignment', 'left');
            self.ui.edGoodTrials = uicontrol('Parent', pRun, 'Style', 'edit', 'String', '0', ...
                'Enable', 'inactive', 'Position', [90 50 60 22]);

            uicontrol('Parent', pRun, 'Style', 'text', 'String', '% correct', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [165 52 70 18], 'HorizontalAlignment', 'left');
            self.ui.edPercentCorrect = uicontrol('Parent', pRun, 'Style', 'edit', 'String', '0', ...
                'Enable', 'inactive', 'Position', [240 50 60 22]);

            uicontrol('Parent', pRun, 'Style', 'text', 'String', 'Trials budget', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [320 52 90 18], 'HorizontalAlignment', 'left');
            self.ui.edTargetTrials = uicontrol('Parent', pRun, 'Style', 'edit', 'String', '0', ...
                'Enable', 'inactive', 'Position', [410 50 60 22]);

            % Elapsed time since the first trial started (HH:MM:SS), ticked
            % roughly once a second by the running engine -- see
            % FormatElapsedTime.m and the "sessionT0" block in
            % CenterOutTask.m/CenterInTask.m's trial loop.
            uicontrol('Parent', pRun, 'Style', 'text', 'String', 'Session time', self.labelFont{:}, ...
                'BackgroundColor', self.panelBG, 'Position', [490 52 85 18], 'HorizontalAlignment', 'left');
            self.ui.textSessionTime = uicontrol('Parent', pRun, 'Style', 'edit', 'String', '00:00:00', ...
                'Enable', 'inactive', 'Position', [575 50 75 22]);

            % Off-rig test mode: run the REAL engine (whichever Task type is
            % selected) driven by the mouse, with the offrig_mocks stubs for
            % Rewards/CloseTask on the path instead of the rig's real ones --
            % so the whole GUI + task window flow can be checked end-to-end
            % (registration -> params -> Start -> live status -> the actual
            % PTB task window) on a normal computer, no valve/joystick/UDP/
            % amplifiers needed. See runTask for how this wires in.
            self.ui.chkOffRig = uicontrol('Parent', pRun, 'Style', 'checkbox', ...
                'String', 'Off-rig test (mouse)', self.labelFont{:}, 'BackgroundColor', self.panelBG, ...
                'Position', [690 50 155 22], 'Callback', @(~, ~) self.offRigToggle_Callback(), ...
                'TooltipString', ['Drives the real task with the mouse instead of the joystick, and uses ' ...
                'mock reward/close-task stubs (no valve, no UDP, no amplifiers) -- for testing off the rig.']);

            self.ui.textOutDir = uicontrol('Parent', pRun, 'Style', 'text', 'String', '', ...
                'FontSize', 8, 'BackgroundColor', self.panelBG, 'ForegroundColor', [0.4 0.4 0.4], ...
                'Position', [15 7 830 30], 'HorizontalAlignment', 'left');

            % Live per-block / per-category breakdown (Center-Out only --
            % Center-In has neither, and blanks this box on launch). The
            % Status line above answers "how far into the session are we";
            % this answers "how far into THIS block, and which categories
            % still owe trials" -- figures that used to exist only in the
            % end-of-session report, too late to act on. Written once per
            % trial by the engine through the handles struct (see runTask),
            % same as every other live readout here.
            %
            % Sits in the panel's right-hand column (x >= 860), the only
            % region no other control uses, so nothing had to move and the
            % window keeps its size.
            uicontrol('Parent', pRun, 'Style', 'text', 'String', 'Progress breakdown', ...
                self.labelFont{:}, 'BackgroundColor', self.panelBG, ...
                'Position', [860 100 200 16], 'HorizontalAlignment', 'left');
            % FixedWidth so the category counts stay in columns from one
            % trial to the next instead of jittering as the digits change.
            self.ui.textBreakdown = uicontrol('Parent', pRun, 'Style', 'text', 'String', '', ...
                'FontName', 'FixedWidth', 'FontSize', 9, 'BackgroundColor', self.panelBG, ...
                'ForegroundColor', [0 0 0.5], 'Position', [860 8 325 90], ...
                'HorizontalAlignment', 'left');
        end

        % =====================================================================
        % CALLBACKS
        % =====================================================================

        function offRigToggle_Callback(self)
            % Off-rig mode drives the task with the mouse -- force the Input
            % source popup to match and lock it, so it can't silently
            % disagree with the checkbox (e.g. left on 'joystick' while
            % off-rig is checked).
            if get(self.ui.chkOffRig, 'Value')
                set(self.ui.popInputSource, 'Value', find(strcmp(get(self.ui.popInputSource, 'String'), 'mouse'), 1));
                set(self.ui.popInputSource, 'Enable', 'off');
            else
                set(self.ui.popInputSource, 'Enable', 'on');
            end
        end

        function stopModeSelect_Callback(self)
            % Swap the quota field's default when switching "Correct
            % trials" <-> "Blocks" (maxCorrectTrials per combo vs. numBlocks
            % of 48 trials), so it doesn't carry over a number that made
            % sense in the other mode. Same ConfigOrgParams defaults the
            % field is seeded from on GUI build.
            d = ConfigOrgParams.getTaskDefaults();
            if get(self.ui.popStopMode, 'Value') == 1
                set(self.ui.edStopQuota, 'String', num2str(d.maxCorrectTrials));
            else
                set(self.ui.edStopQuota, 'String', num2str(d.numBlocks));
            end
            self.taskTypeSelect_Callback();   % the quota just changed -> refresh the budget preview
        end

        function stimulusSetSelect_Callback(self)
            % A reduced Bar set carries one length per category, so there is
            % no finer length structure for a 2-category framing to split --
            % it could only regroup the three prototypes, which tests
            % nothing. Rather than let the operator pick a combination the
            % engine would then have to override at launch (it does, for
            % offline scripts -- see CenterOutTask's oneLengthPerCategory
            % guard), force Session mode to 3cat here and lock it, so the
            % console cannot show a mode the session will not run.
            setName = self.stimulusSetSelection();
            modes = get(self.ui.popSessionMode, 'String');
            if strcmpi(setName, 'full12')
                set(self.ui.popSessionMode, 'Enable', 'on');
            elseif strcmpi(setName, 'prototypes2')
                % One Short bar and one Long bar, no Mid: the only framing this
                % set can run is 2-category, so lock the mode there (mirror of
                % the 3cat lock below, and of CenterOutTask's prototypes2
                % guard).
                set(self.ui.popSessionMode, 'Value', find(strcmpi(modes, '2cat'), 1), ...
                    'Enable', 'off');
            else
                set(self.ui.popSessionMode, 'Value', find(strcmpi(modes, '3cat'), 1), ...
                    'Enable', 'off');
            end
            self.sessionModeSelect_Callback();   % the mode may have just been forced -> re-grey the blocks fields
            self.taskTypeSelect_Callback();   % the length count just changed -> refresh the budget
        end

        function sessionModeSelect_Callback(self)
            % The "Alternate: blocks/segment" fields only mean anything
            % under sessionMode 'alternate' (interleaved picks 2cat/3cat at
            % random per trial; plain 2cat/3cat never switch at all) -- grey
            % them out otherwise, the same "disabled but still gathered"
            % treatment Max attempts gets from retriesToggle_Callback, so a
            % typed value is never silently ignored without the field
            % visibly saying so. Called both from this popup's own Callback
            % and from stimulusSetSelect_Callback, since a reduced Bar set
            % can force Session mode away from 'alternate' without the
            % operator ever touching this popup directly.
            if ~isfield(self.ui, 'edAlternateBlocks2cat')
                return;   % Task parameters panel not built yet
            end
            modes = get(self.ui.popSessionMode, 'String');
            isAlternate = strcmpi(modes{get(self.ui.popSessionMode, 'Value')}, 'alternate');
            if isAlternate
                set([self.ui.edAlternateBlocks2cat, self.ui.edAlternateBlocks3cat], 'Enable', 'on');
            else
                set([self.ui.edAlternateBlocks2cat, self.ui.edAlternateBlocks3cat], 'Enable', 'off');
            end
        end

        function applyTaskTypeEnableStates(self)
            % Grey out the controls that do not apply to the selected Task
            % type: Center-Out-only fields when Center-In is chosen, and the
            % Center-In-only fields when Center-Out is chosen. Rig geometry,
            % Reward, timing and Input source are shared by all modes and are
            % never greyed (every mode depends on rig geometry). Session mode
            % and Max attempts are deliberately left out here -- they have
            % their own callbacks (bar-set lock / Retries) that own their
            % enable state, and forcing them here would fight those.
            isCenterIn = get(self.ui.popTaskType, 'Value') == 2;
            onoff = {'on', 'off'};
            coState = onoff{isCenterIn + 1};    % Center-Out-only: off when Center-In
            ciState = onoff{~isCenterIn + 1};   % Center-In-only:  off when Center-Out
            coHandles = {'popStimulusSet','chkShowCue','chkBarColour','popStopMode', ...
                'edStopQuota','popTrainingPhase','edBarSubset','chkShowErrorFlash', ...
                'chkHoldColorEffectCO','chkStrictHold','edColor3CatShort','edColor3CatMid','edColor3CatLong', ...
                'edColor2CatShort','edColor2CatLong'};
            ciHandles = {'chkCenterInReach','edCenterInWeights','edCenterInTargetColor', ...
                'edCenterInJitter','chkHoldColorEffect','edCenterInTrials'};
            for i = 1:numel(coHandles)
                if isfield(self.ui, coHandles{i}), set(self.ui.(coHandles{i}), 'Enable', coState); end
            end
            for i = 1:numel(ciHandles)
                if isfield(self.ui, ciHandles{i}), set(self.ui.(ciHandles{i}), 'Enable', ciState); end
            end
        end

        function taskTypeSelect_Callback(self)
            self.applyTaskTypeEnableStates();
            % Trials budget (edTargetTrials) is otherwise only written by
            % whichever engine actually runs (see runTask's rh.editTrainRepe,
            % written at runtime by CenterOutTask.m/CenterInTask.m) -- so
            % switching Task type alone would leave it showing whatever the
            % OTHER engine last computed there. Preview the real quota here
            % instead, using the same formulas those engines apply at
            % runtime (see plannedTrials in CenterOutTask.m and
            % maxCorrectTrials in CenterInTask.m).
            if get(self.ui.popTaskType, 'Value') == 2
                % Center-In counts rewarded holds only, so this is the
                % session's TARGET, not its length: failed attempts add
                % trials without adding budget.
                budget = str2double(get(self.ui.edCenterInTrials, 'String'));
            else
                stopQuota = str2double(get(self.ui.edStopQuota, 'String'));
                [~, numLengths] = self.stimulusSetSelection();
                % A bar subset shrinks the set the quota is applied over, so
                % the preview has to honour it too -- otherwise selecting one
                % length would still advertise the full set's budget. Falls
                % back to the whole set when the field does not parse; the
                % red-box validation in getSessionParams is what blocks Start.
                selected = ParseBarSubset(strtrim(get(self.ui.edBarSubset, 'String')), numLengths);
                if ~isempty(selected)
                    numLengths = numel(selected);
                end
                % Same as the engine: one correct trial per (length x
                % position) combination, stopQuota times over.
                budget = stopQuota * numLengths * 4;   % 4 = positions (right/up/left/down)
            end
            if isnan(budget)
                budget = 0;
            end
            set(self.ui.edTargetTrials, 'String', num2str(budget));
        end

        function subjectTypeSelect_Callback(self)
            % Monkey <-> Human swaps three things that have to move together:
            % the Subject control (named list vs. typed participant number),
            % the two trial-repetition checkboxes (see ConfigSession.m for
            % why a human session runs without them), and any registration
            % already sitting in the Session ID box, which belongs to the
            % population being switched away from.
            cfg = ConfigSession();
            d = ConfigOrgParams.getTaskDefaults();
            if get(self.ui.popSubjectType, 'Value') == 2   % Human
                set(self.ui.txtSubjectLabel, 'String', 'Participant #');
                set(self.ui.popSubject, 'Visible', 'off');
                set(self.ui.edHumanNum, 'Visible', 'on');
                set(self.ui.chkUseRetries, 'Value', double(cfg.humanUseRetries));
                set(self.ui.chkUseRequeue, 'Value', double(cfg.humanUseRequeue));
            else
                set(self.ui.txtSubjectLabel, 'String', 'Subject');
                set(self.ui.edHumanNum, 'Visible', 'off');
                set(self.ui.popSubject, 'Visible', 'on');
                set(self.ui.chkUseRetries, 'Value', double(d.useRetries));
                set(self.ui.chkUseRequeue, 'Value', double(d.useRequeue));
            end
            self.retriesToggle_Callback();   % Max attempts follows Retries
            self.invalidateRegistration();
        end

        function humanNumEdit_Callback(self)
            % Flag a bad participant number as it is typed rather than at
            % Register, and drop any registration made under the PREVIOUS
            % number -- otherwise changing 3 to 4 would leave the session
            % still registered, and running, as PX-3.
            [~, ok] = self.humanParticipantId();
            if ok
                set(self.ui.edHumanNum, 'BackgroundColor', [1 1 1]);
            else
                set(self.ui.edHumanNum, 'BackgroundColor', [1 0.7 0.7]);
            end
            self.invalidateRegistration();
        end

        function retriesToggle_Callback(self)
            % Retries drives two other things, so they cannot be set to
            % disagree with it:
            %
            % 1. Max attempts only means anything while retries are on: with
            %    useRetries false both engines force exactly one attempt per
            %    stimulus and ignore the number. Grey the field out so it
            %    cannot be read as still in effect (its own tooltip promises
            %    this), instead of leaving a live-looking box the engine
            %    discards.
            % 2. What the stop quota counts. Insisting on a correct trial
            %    per combination is the SAME intent as the correction
            %    procedure -- keep showing it until it comes out right -- so
            %    it belongs to retries being on. With retries off the quota
            %    counts presentations instead: one deliberate answer per
            %    slot, a wrong one costs that slot. The combination this
            %    rules out is retries ON with a presentation quota, where
            %    each retry would eat its own combination's quota, and the
            %    correction procedure would shorten the session it exists to
            %    extend. Shown as a disabled checkbox rather than hidden, so
            %    the operator can still read which rule is in force. It
            %    describes Center-Out only: CenterInTask.m ignores the field
            %    and always runs to its target number of rewarded holds
            %    (see that file's stop-condition block for why).
            if ~isfield(self.ui, 'edMaxAttempts')
                return;   % Task parameters panel not built yet
            end
            retriesOn = get(self.ui.chkUseRetries, 'Value') == 1;
            if retriesOn
                set(self.ui.edMaxAttempts, 'Enable', 'on');
            else
                set(self.ui.edMaxAttempts, 'Enable', 'off');
            end
            set(self.ui.chkQuotaPresentations, 'Value', double(~retriesOn), ...
                'Enable', 'off');
        end

        function registerSession_Callback(self)
            if self.running
                % A run owns the registration it was launched with (runTag,
                % params snapshot, output files) -- re-registering mid-run
                % would silently disagree with them.
                warndlg('A run is in progress. Abort it before registering a new session.', ...
                    'Run in progress');
                return;
            end
            % Every registration starts a NEW session in this same window:
            % wipe the previous run's live counters/output line so nothing
            % from it can be misread as belonging to the session about to
            % start (they are deliberately left on screen until now, so the
            % operator can still read the finished run's result).
            self.clearRunReadouts();

            cfg = ConfigSession();
            % Plain char throughout, NOT string(): this console has to run on
            % the rig's Computer 2 (MATLAB R2016b), the release the string
            % class was introduced in, where graphics properties such as an
            % edit box's 'String' do not reliably accept a string scalar --
            % see the set(edDate, 'String', currDate) below.
            if get(self.ui.popSubjectType, 'Value') == 2
                % Human: the typed number IS the identity. Refuse to register
                % on a bad one -- an id is not something to guess at, and a
                % session that starts unregistered cannot be traced back to
                % its participant afterwards.
                [participantId, ok] = self.humanParticipantId();
                if ~ok
                    set(self.ui.edHumanNum, 'BackgroundColor', [1 0.7 0.7]);
                    warndlg(['Enter the participant number as a positive whole number ' ...
                        '(1, 2, 3, ...). The session registers as ' cfg.humanIdPrefix ...
                        '-<number>.'], 'Participant number');
                    return;
                end
                set(self.ui.edHumanNum, 'BackgroundColor', [1 1 1]);
                self.subjectType = 'human';
                self.idSubject = participantId;
                % The anonymous id IS the session id: it is already short,
                % unique and carries no identifying information, so there is
                % nothing to abbreviate the way a monkey's name is.
                self.idSession = participantId;
            else
                monkeys = get(self.ui.popSubject, 'String');
                self.subjectType = 'monkey';
                self.idSubject = monkeys{get(self.ui.popSubject, 'Value')};
                % Local session id: first 3 letters of the monkey's name
                % (e.g. "ROM" for Romina) -- no database/NAS involved, just
                % makes the id recognizable by monkey at a glance in the
                % outputs/ folder listing. No timestamp here: runTag
                % (start_Callback below) already appends its own
                % human-readable date/time, so a second, compact one on
                % idSession was pure redundancy.
                monkeyChars = char(self.idSubject);
                self.idSession = upper(monkeyChars(1:min(3, numel(monkeyChars))));
            end
            self.idProject = cfg.validProject;

            currDate = datestr(now, 'dd-mm-yyyy');
            set(self.ui.edSessionId, 'String', self.idSession);
            set(self.ui.edDate, 'String', currDate);
            set(self.ui.butStart, 'Enable', 'on');
        end

        function start_Callback(self)
            if self.running, return; end
            if isempty(get(self.ui.edSessionId, 'String'))
                warndlg('Register a session first.', 'No session');
                return;
            end
            % The task window (rig or off-rig) always needs Psychtoolbox --
            % catch a missing install here with one clear message instead of
            % a cryptic error surfacing from inside PsychImaging('OpenWindow',
            % ...) later.
            if ~exist('Screen', 'file')
                warndlg(['Psychtoolbox not found on the MATLAB path.' newline newline ...
                    'The task engine needs it whether running on the rig or off-rig.' newline ...
                    'Install it from psychtoolbox.org, then restart MATLAB.'], ...
                    'Psychtoolbox not found');
                return;
            end

            % Validate all numeric fields before launching. getSessionParams
            % paints invalid boxes red (NaN = empty or unparseable string,
            % e.g. a comma decimal separator or a stray letter). Blocking
            % here is strictly better than letting NaN reach the task engine,
            % where it would hang silently -- e.g. centerRad = NaN makes
            % CheckInCircle always return false, so the task freezes in
            % ENTER_CENTER without any error message.
            [~, fieldsValid] = self.getSessionParams();
            if ~fieldsValid
                self.setStatus('Fix the highlighted fields before starting.', [0.7 0 0]);
                return;
            end

            rng('shuffle');   % fresh pseudorandom sequence for this session
            runTag = sprintf('sess%s_%s', self.idSession, datestr(now, 'dd-mmm-yyyy_HH-MM'));
            % Grouped by month, then by session day, then by SESSION: each run
            % gets its own folder named by the runTag (outputs/<yyyy-mm>/
            % <yyyy-mm-dd>/<runTag>/), matching CenterOutTask.m/CenterInTask.m
            % so the params snapshot saved below lands in the SAME session
            % folder as that run's data files. Using the shared runTag (not an
            % independently re-read clock) is what guarantees the console and
            % the task agree on the folder. mkdir creates every intermediate
            % folder.
            outMonth = datestr(now, 'yyyy-mm');
            outDay   = datestr(now, 'yyyy-mm-dd');
            outDir = fullfile('outputs', outMonth, outDay, runTag);
            if ~exist(outDir, 'dir'), mkdir(outDir); end

            isOffRig = get(self.ui.chkOffRig, 'Value') == 1;
            offRigTag = '';
            if isOffRig, offRigTag = '[OFF-RIG MOCK RUN] '; end

            self.setRunning(true);
            self.setStatus([offRigTag 'Launching...'], [0 0 0.6]);
            set(self.ui.textOutDir, 'String', sprintf('%sOutputs: %s   (runTag = %s)', offRigTag, outDir, runTag));
            drawnow();

            try
                self.runTask(runTag, outDir);
            catch ME
                self.setStatus(sprintf('Error: %s', ME.message), [0.7 0 0]);
            end

            self.setRunning(false);
            % The run is over -- however it ended (completed, aborted from
            % the Abort button or the engine's own stop key, or crashed).
            % Close the session out here, in the ONE place every one of
            % those paths comes back through.
            self.endSession();
        end

        function abort_Callback(self)
            % Only raises the stop flag the engine polls every frame. The
            % engine then unwinds on its own (saving data, printing its
            % report, closing devices) and returns into start_Callback,
            % which is where the session is actually cleared -- clearing it
            % from here would wipe the identity out from under a run that is
            % still writing files under it.
            if ~isempty(self.proxyFig) && isgraphics(self.proxyFig)
                setappdata(self.proxyFig, 'stop', true);
            end
            self.setStatus('Stopping...', [0.7 0 0]);
        end

        function close_Callback(self)
            % Closing the console mid-run would delete the very handles the
            % running engine writes its live status into every frame, so it
            % would error out inside the trial loop and take the session's
            % data with it. Abort first, then the window closes normally.
            if self.running
                warndlg(['A run is in progress. Press Abort and wait for it to finish ' ...
                    'before closing the console.'], 'Run in progress');
                return;
            end
            delete(self.fig);
        end

        % =====================================================================
        % TASK LAUNCH
        % =====================================================================

        function runTask(self, runTag, outDir)
            % Build orgParams for the selected engine (ui.popTaskType: 1 =
            % Center-Out / CenterOutTask, 2 = Center-In / CenterInTask).
            % Both engines expect a handles struct exposing 6 fixed field
            % names (dlgTrainingMain/text77/edit91/edit92/editTrainRepe/
            % textSessionTime) that they write live status into; point them
            % straight at this console's own labeled Status/Good trials/
            % % correct/Trials budget/Session time boxes in the Run panel,
            % so a run's live status shows up in the one window the operator
            % is watching, whichever engine is running.
            %
            % dlgTrainingMain must be a SEPARATE, hidden figure: both
            % engines call close() on it, both when a run finishes normally
            % and from their top-level catch block on a crash -- that must
            % not be this console window itself, or the whole console would
            % vanish the moment a run ends or errors out.
            self.proxyFig = figure('Visible', 'off', 'HandleVisibility', 'off', ...
                'IntegerHandle', 'off', 'Name', 'centerOutTask internal handle (hidden)');
            setappdata(self.proxyFig, 'stop', false);
            cleanupProxy = onCleanup(@() CenterConsole.safeDeleteFig(self.proxyFig)); % belt-and-suspenders if the engine's own close() above is ever skipped

            rh.dlgTrainingMain = self.proxyFig;
            rh.text77 = self.ui.textStatus;
            rh.edit91 = self.ui.edGoodTrials;
            rh.edit92 = self.ui.edPercentCorrect;
            rh.editTrainRepe = self.ui.edTargetTrials;
            rh.textSessionTime = self.ui.textSessionTime;
            % 7th, OPTIONAL field, on top of the 6 fixed ones above: the
            % per-block/per-category breakdown box. Both engines guard it
            % with isfield, so a caller that builds handles by hand and
            % doesn't supply it (OffrigPlay) still runs -- it just doesn't
            % get the breakdown.
            rh.textBreakdown = self.ui.textBreakdown;

            userParams = self.getSessionParams();
            userParams.handles = rh;
            userParams.runTag = runTag;
            isCenterIn = userParams.taskType == 2;
            % Single source of truth for defaults (see ConfigOrgParams.m):
            % only the fields the operator actually touched in the GUI
            % override the defaults, everything else falls back cleanly.
            orgParams = ConfigOrgParams.mergeStructs(ConfigOrgParams.getTaskDefaults(), userParams);

            % Off-rig test mode: use the offrig_mocks stubs (CloseTask/
            % Reward) so no real reward valve / UDP / amplifiers are
            % touched, and never leave that folder shadowing the rig's real
            % functions once this run ends -- offrig_mocks/Rewards.m's own
            % header spells out why ("Do NOT add this folder to the MATLAB
            % path when running on the rig, or no reward will be
            % delivered"). Without this, an off-rig run would hit an undefined
            % CloseTask() at teardown (the real one lives only on the rig's
            % own path, not in this repo). Shared by both engines.
            if isfield(self.ui, 'chkOffRig') && get(self.ui.chkOffRig, 'Value')
                mocksDir = fullfile(fileparts(mfilename('fullpath')), 'offrig_mocks');
                addpath(mocksDir);
                cleanupMocksPath = onCleanup(@() rmpath(mocksDir));
            end

            % Traceability: snapshot the exact parameters BEFORE the task
            % starts, under the same runTag as the data files it's about to
            % produce, so a crash mid-session still leaves a record of what
            % was configured.
            snapshot.runTag = runTag;
            snapshot.idSession = self.idSession;
            % idSubject replaces the old idMonkey field: it holds a monkey's
            % name OR an anonymous participant id ('PX-3'), and subjectType
            % says which without having to infer it from the id's shape.
            snapshot.idSubject = self.idSubject;
            snapshot.subjectType = self.subjectType;
            snapshot.idProject = self.idProject;
            snapshot.dateTime = datestr(now);
            if isCenterIn
                snapshot.engine = 'CenterInTask';
            else
                snapshot.engine = 'CenterOutTask';
            end
            snapshot.orgParams = rmfield(orgParams, 'handles');   % handles aren't serializable
            save(fullfile(outDir, ['params_' runTag '.mat']), '-struct', 'snapshot');

            self.setStatus('Running...', [0 0.5 0]);
            drawnow();

            % ui.textStatus/edGoodTrials/edPercentCorrect/edTargetTrials are
            % the same handles the engine just wrote into throughout the
            % run (see rh above), so they're already showing the final
            % status ("Task done", good trials count, etc.) here -- nothing
            % to copy back.
            if isCenterIn
                CenterInTask(orgParams);
            else
                CenterOutTask(orgParams);
            end
        end
    end

    methods (Access = private)
        function [setName, numLengths] = stimulusSetSelection(self)
            % The Bar set popup, resolved to the name the engine expects and
            % the length count the Trials budget preview needs. One mapping
            % for both, because they used to carry a copy each with an
            % implicit "anything that is not full12 has 3 lengths" -- which
            % happened to be true with two options and silently would not be
            % with a fourth. Popup order is defined in buildTaskParamsPanel.
            switch get(self.ui.popStimulusSet, 'Value')
                case 2
                    setName = 'prototypes3';   % one midpoint length per category
                    numLengths = 3;
                case 3
                    setName = 'extremes3';     % shortest / Mid midpoint / longest
                    numLengths = 3;
                case 4
                    setName = 'prototypes2';   % Short/Long midpoints, 2-category
                    numLengths = 2;
                otherwise
                    setName = 'full12';
                    numLengths = 12;
            end
        end

        function [pid, ok, n] = humanParticipantId(self)
            % The typed participant number, resolved to its id ('PX-3').
            % ok is false for anything that is not a positive whole number:
            % empty, a decimal, a negative, a comma decimal separator or a
            % stray letter (str2double gives NaN for those, the same way
            % every other numeric field in this console is validated).
            % Rejecting rather than rounding is deliberate -- 3.5 is a
            % mistyped id, and silently filing the session under PX-4 would
            % attach it to a different participant.
            cfg = ConfigSession();
            pid = '';
            n = str2double(strtrim(get(self.ui.edHumanNum, 'String')));
            ok = ~isnan(n) && isreal(n) && n > 0 && n == round(n);
            if ok
                pid = sprintf('%s-%d', cfg.humanIdPrefix, n);
            end
        end

        function invalidateRegistration(self)
            % Any change to WHO the session is for makes the id already in
            % the Session ID box wrong, so drop it and disable Start --
            % same reasoning as endSession, which does this once a run has
            % finished. Without it, switching subject type or editing the
            % participant number after registering would launch the next run
            % under the previous subject's id.
            if self.running
                return;   % a run owns its registration; abort it first
            end
            self.idSession = '';
            self.idSubject = '';
            self.subjectType = '';
            set(self.ui.edSessionId, 'String', '');
            set(self.ui.edDate, 'String', '');
            set(self.ui.butStart, 'Enable', 'off');
        end

        function clearRunReadouts(self)
            % Blank every box that shows a RESULT of a run (as opposed to a
            % setting), so no leftover from the previous session is on
            % screen once a new one is registered. Trials budget is not
            % blanked but recomputed, since it is derived from the current
            % task parameters, not from the run that just ended.
            set(self.ui.edGoodTrials, 'String', '0');
            set(self.ui.edPercentCorrect, 'String', '0');
            set(self.ui.textSessionTime, 'String', '00:00:00');
            set(self.ui.textOutDir, 'String', '');
            set(self.ui.textBreakdown, 'String', '');
            self.taskTypeSelect_Callback();
            self.setStatus('Idle', [0 0 0.6]);
        end

        function [s, allValid] = gatherFields(~, s, editStruct)
            % Copy every editStruct.(field) edit box into s.(field) =
            % str2double(...String). Used to turn the ui.edGeom/ui.edTiming
            % structs (built field-by-field from the timingRows/geomRows
            % tables) into orgParams entries without repeating each field
            % name a second time at the call site.
            %
            % Validation: str2double returns NaN whenever the text is not a
            % plain number (empty box, comma decimal separator, stray letter).
            % NaN is not empty, so it would pass OrgGet's isempty guard and
            % reach the task as a real value, where it silently poisons every
            % arithmetic comparison it touches -- a centre-window radius of
            % NaN means the cursor can never register as inside, so the task
            % hangs in ENTER_CENTER forever without any error. Catching it
            % here, before Start fires, is strictly better than catching it
            % inside the task: the operator sees a red box and can correct
            % the typo immediately rather than having a session fail silently.
            % NaN fields are painted red; valid fields are painted white.
            % The caller checks allValid and blocks Start if it is false.
            fn = fieldnames(editStruct);
            allValid = true;
            for i = 1:numel(fn)
                h = editStruct.(fn{i});
                val = str2double(get(h, 'String'));
                s.(fn{i}) = val;
                if isnan(val)
                    set(h, 'BackgroundColor', [1 0.7 0.7]);   % red tint
                    allValid = false;
                else
                    set(h, 'BackgroundColor', [1 1 1]);        % white
                end
            end
        end

        function h = mkEdit(~, parent, str, pos)
            h = uicontrol('Parent', parent, 'Style', 'edit', 'String', str, ...
                'Units', 'pixels', 'Position', pos, 'HorizontalAlignment', 'center');
        end
    end

    methods (Static, Access = private)
        function safeDeleteFig(h)
            if isgraphics(h), delete(h); end
        end
    end
end