classdef TaskEpoch
    % TASKEPOCH  Enumeration of behavioral task epochs (states).
    %
    %   Replaces fragile magic constants (EP.CUE=4.5, EP.STIM_DELAY=13, etc.)
    %   with a named enumeration, so a stray number in a log or a comparison
    %   can no longer silently mean the wrong state.
    %
    %   Execution order within a trial (this is the real flow; see the
    %   numbering caveat below):
    %     ENTER_CENTER -> HOLD_START -> HOLD -> BAR -> [STIM_DELAY] ->
    %     CUE -> [CUE_DELAY] -> REACTION -> MOVEMENT -> TARGET_HOLD ->
    %     REWARD -> SUCCESS_FB -> ITI -> BOOKKEEP
    %   with ERROR_FB replacing REWARD/SUCCESS_FB on a failed attempt, and
    %   the two bracketed epochs entered only when their delay is non-zero.
    %
    %   STIM_DELAY and CUE_DELAY ARE REAL STATES, not log-only markers.
    %   CenterOutTask.m assigns them to nextEpoch and has a full case block
    %   for each (the cursor must keep holding the centre through the delay,
    %   and leaving early is an error, exactly as in HOLD/BAR/CUE). They are
    %   simply never reached with the shipped defaults, because
    %   orgParams.delayStimToRule and orgParams.barToTargetDelay both
    %   default to 0. Raising either one during working-memory training
    %   activates the corresponding state. Do not delete those case blocks
    %   as dead code; they are the working-memory manipulation.
    %
    %   NUMBERING CAVEAT. The numeric Values are NOT in execution order:
    %   STIM_DELAY (14) runs between BAR (4) and CUE (5), and CUE_DELAY (15)
    %   between CUE (5) and REACTION (6). They were appended at the end so
    %   that adding them would not renumber the epochs already written into
    %   existing trajectory_*.csv files. Consequence: do not infer trial
    %   order by sorting the Epoch column. Sort by the Time column instead,
    %   or map codes through the flow listed above. (Relational operators
    %   are not defined on this class (it does not derive from a numeric
    %   type) so an accidental `epoch < TaskEpoch.CUE` errors out rather
    %   than quietly returning a wrong answer.)
    %
    %   Usage:
    %     epoch = TaskEpoch.ENTER_CENTER;   % get the enum member
    %     if epoch == TaskEpoch.REWARD      % compare (== is native to enums)
    %       ...
    %     end
    %     code = TaskEpoch.MOVEMENT.Value;  % numeric code, for log columns
    %                                       % and for TrialKinematics.m /
    %                                       % SaveMovementTrajectory.m

    enumeration
        ENTER_CENTER  (1)    % wait for cursor entry to centre
        HOLD_START    (2)    % count attempt, start hold timer
        HOLD          (3)    % hold in centre, display bar if ready
        BAR           (4)    % bar visible, then optional stimulus-to-rule delay
        CUE           (5)    % cue visible (optional), then optional rule-to-target delay
        REACTION      (6)    % cursor leaves centre (abort if too early)
        MOVEMENT      (7)    % cursor reaches target
        TARGET_HOLD   (8)    % brief hold inside correct target
        REWARD        (9)    % deliver reward
        SUCCESS_FB    (10)   % success feedback
        ERROR_FB      (11)   % error feedback
        ITI           (12)   % inter-trial interval
        BOOKKEEP      (13)   % update GUI, log, arm next trial
        % ---- Appended out of execution order to preserve existing log codes;
        % ---- these are live states, entered when their delay is non-zero.
        STIM_DELAY    (14)   % hold centre through the bar -> cue delay
        CUE_DELAY     (15)   % hold centre through the cue -> target delay
    end

    properties (SetAccess = immutable)
        Value  % underlying numeric code, written to the Epoch log column
    end

    methods
        function obj = TaskEpoch(val)
            obj.Value = val;
        end
    end
end