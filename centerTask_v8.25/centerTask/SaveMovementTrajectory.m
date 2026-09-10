function SaveMovementTrajectory(trajBuf, trajN, outDir, runTag, sessionDate, movementEpochs, saveAsMat, saveCsv)
    % SAVEMOVEMENTTRAJECTORY  Movement-only trajectory export.
    %
    %   Same columns as trajectory_*.{mat,csv}, but rows restricted to
    %   Epoch in movementEpochs -- the response window an offline kinematics
    %   analysis would differentiate -- plus ONE extra trailing column,
    %   MoveTime_ms. Writes
    %   trajectory_movement_<runTag>.{mat,csv}.
    %
    %   Time_ms (column 1) is untouched: ms since the session's first trial,
    %   the same clock the full export uses, so a row here can still be
    %   matched against the full file. MoveTime_ms is that same per-record
    %   measurement re-zeroed at each trial's own movement onset, so every
    %   record carries its time within the movement without the analyst
    %   having to subtract the trial's first timestamp downstream.
    %
    %   Independent of SaveTrajectory.m, not called by it. The two are peers
    %   with the SAME first five arguments, so the task calls whichever it
    %   wants, in whichever order:
    %     SaveTrajectory(trajBuf, trajN, outDir, d, sessionDate, true, true);
    %     SaveMovementTrajectory(trajBuf, trajN, outDir, d, sessionDate, kinematicsEpochs);
    %   The full multi-epoch export stays the source of truth for trajectory
    %   maps that need the pre-movement epochs; this is a convenience cut for
    %   kinematics-only analysis, and re-derivable from the full file at any
    %   time by filtering on the Epoch column.
    %
    %   Taking trajBuf (not the already-stripped trajectory matrix) is what
    %   makes the two interchangeable: this function removes the TrialNum
    %   column itself, exactly as SaveTrajectory does, so neither depends on
    %   the other having run first.
    %
    %   INPUT
    %     trajBuf        : raw trajectory buffer, N x 8 (CenterOutTask.m) or
    %                      N x 6 (CenterInTask.m); see SaveTrajectory.m for
    %                      the column meanings. Epoch sits at the same position
    %                      in both layouts once TrialNum is stripped (column 4),
    %                      so the row filter below is layout-independent; only
    %                      the CSV header differs.
    %     trajN          : number of valid rows in trajBuf
    %     outDir         : output directory (created if missing)
    %     runTag         : run identifier (used in output filenames)
    %     sessionDate    : session date string for CSV rows
    %     movementEpochs : numeric epoch code, OR VECTOR of codes, to keep
    %                      (e.g. EP.MOVEMENT.Value alone, or
    %                      [EP.DECISION_TIME.Value, EP.MOVEMENT.Value] --
    %                      CenterOutTask.m's movementExportEpochs -- which
    %                      window of the response to keep for this session;
    %                      a row is kept when its
    %                      Epoch matches ANY listed code). Empty or missing =
    %                      nothing to filter on, returns without writing
    %                      (CenterInTask.m has no MOVEMENT epoch and simply
    %                      never calls this).
    %     saveAsMat      : bool, save .mat file (default: true)
    %     saveCsv        : bool, save .csv file (default: true)
    %
    %   OUTPUT
    %     none (side effects: files written to disk)
    %
    %   NOTES
    %     - All errors are caught and reported; no exception propagation, so
    %       this is safe to call from the crash-recovery catch block where it
    %       must not mask the original error.
    %     - Writing zero matching rows is not an error: a session that ended
    %       before any matching epoch legitimately has none, and an empty
    %       file records that fact rather than hiding it.

    % Defaults
    if nargin < 6
        movementEpochs = [];
    end
    if nargin < 7 || isempty(saveAsMat)
        saveAsMat = true;
    end
    if nargin < 8 || isempty(saveCsv)
        saveCsv = true;
    end

    % Guards: nothing to save, or nothing to filter on
    if isempty(trajBuf) || trajN <= 0 || isempty(movementEpochs)
        return;
    end

    % Ensure output directory exists
    if ~exist(outDir, 'dir')
        try
            mkdir(outDir);
        catch
            fprintf('WARNING: could not create output directory %s\n', outDir);
            return;
        end
    end

    % Extract trajectory (remove TrialNum column 1) and keep rows matching
    % ANY of movementEpochs (ismember; a scalar movementEpochs behaves
    % exactly as the old single-epoch == comparison did).
    try
        trajectory = trajBuf(1:trajN, 2:end);
        moveRows = ismember(trajectory(:, 4), movementEpochs);
        trajectoryMovement = trajectory(moveRows, :);
        nMoveRows = size(trajectoryMovement, 1);
    catch ME
        fprintf('WARNING: could not extract movement trajectory from buffer: %s\n', ME.message);
        return;
    end

    % Per-record time WITHIN the movement, appended as a trailing column.
    % Column 1 (Time_ms) stays exactly what the full export carries (ms
    % since the session's first trial) so both files remain directly
    % comparable; MoveTime_ms adds the same measurement re-zeroed at each
    % trial's own movement onset, which is the clock kinematics are read in
    % (t=0 is the first sample of this trial's kept epoch(s), i.e. whichever
    % of them the trial actually reached). Trailing position keeps the
    % existing column indices valid for anything already reading these files
    % (plotMovementTrajectories.m, and any offline reader of this layout).
    try
        trajectoryMovement = AppendMoveTime(trajectoryMovement);
    catch ME
        fprintf('WARNING: could not compute per-record movement time: %s\n', ME.message);
        return;
    end

    % Same non-decreasing-time check the full export runs; see
    % ReportTimeMonotonicity.m. Run AFTER the movement filter on purpose:
    % this file is the one kinematics are actually differentiated from, so
    % what matters is whether the ROWS THAT SURVIVED the cut are ordered,
    % not whether the buffer they came from was.
    ReportTimeMonotonicity(trajectoryMovement(:, 1), 'movement trajectory');

    % Save .mat file
    if saveAsMat
        try
            matFile = fullfile(outDir, sprintf('trajectory_movement_%s.mat', runTag));
            save(matFile, 'trajectoryMovement');
            fprintf('Movement-only trajectory saved to: %s (%d samples)\n', matFile, nMoveRows);
        catch ME
            fprintf('WARNING: could not save movement trajectory .mat: %s\n', ME.message);
        end
    end

    % Save .csv file
    if saveCsv
        try
            % TrajectoryColumnNames is the single source of truth for column
            % headers: add a new engine layout there, not here.
            csvFile = fullfile(outDir, sprintf('trajectory_movement_%s.csv', runTag));
            % -1 because the trailing MoveTime_ms column added above is not
            % part of the shared layout; TrajectoryColumnNames appends its
            % name when asked with the second argument.
            varNames = TrajectoryColumnNames(size(trajectoryMovement, 2) - 1, true);
            trajCols = num2cell(trajectoryMovement, 1);
            trajMoveTable = table(repmat({sessionDate}, nMoveRows, 1), trajCols{:}, 'VariableNames', varNames);
            writetable(trajMoveTable, csvFile);
            fprintf('Movement-only trajectory exported to: %s (%d samples)\n', csvFile, nMoveRows);
        catch ME
            fprintf('WARNING: could not save movement trajectory .csv: %s\n', ME.message);
        end
    end
end

function m = AppendMoveTime(m)
    % Append MoveTime_ms: Time_ms re-zeroed at each trial's movement onset.
    %
    % Trials are identified the same way plotMovementTrajectories.m does it:
    % by every identity column that follows Epoch; Block/TrialNumInBlock/
    % Attempt for the CenterOutTask layout, Attempt alone for the
    % CenterInTask one -- so this works for both without knowing which
    % engine wrote the rows. The latter has no per-trial identity beyond
    % Attempt, so trials sharing an attempt number would share one onset;
    % that layout is CenterInTask's, which has no MOVEMENT epoch and never
    % calls this.
    %
    % 5:end-1, not 5:end (2026-09-04): the trailing column is now RZ2Idx,
    % which is a per-SAMPLE index, not trial identity. Including it would
    % make every row its own group, every onset its own timestamp, and
    % every MoveTime_ms exactly zero -- silently, since a column of zeros
    % is a perfectly well-formed column. The identity columns are the ones
    % between Epoch and RZ2Idx.
    %
    % Onset is min(Time_ms) of the group, not the first row of it: the
    % rz2adc path appends a whole batch of samples per frame (see trajBuf in
    % CenterOutTask.m), and a batch's timestamps can land slightly out of
    % row order, which would otherwise make the first record's MoveTime_ms
    % negative and shift the whole trial.
    if isempty(m)
        m = [m, zeros(size(m, 1), 1)];   % keep the column count consistent for empty sessions
        return;
    end
    t = m(:, 1);
    [~, ~, trialIdx] = unique(m(:, 5:end-1), 'rows');
    onset = accumarray(trialIdx, t, [], @min);
    m = [m, t - onset(trialIdx)];
end