function SaveTrajectory(trajBuf, trajN, outDir, runTag, sessionDate, saveAsMat, saveCsv)
    % SAVETRAJECTORY  Full multi-epoch trajectory export (normal and crash-recovery).
    %   Paola Castillo 2026-07-31
    %
    %   Consolidates the identical trajectory-saving logic that used to appear
    %   four times (normal export and crash-recovery, in each of the two task
    %   engines). Writes the WHOLE buffer: every epoch, not just MOVEMENT.
    %
    %   This function no longer writes the movement-only cut. That export is
    %   now SaveMovementTrajectory.m, called separately by the task alongside
    %   this one, so the two are independent: a caller can write the full
    %   trajectory without the movement cut, write the movement cut without
    %   the full trajectory, or reorder them, and neither silently depends on
    %   the other's intermediate state. Both take the SAME inputs (trajBuf,
    %   trajN, outDir, runTag, sessionDate), so they are drop-in peers.
    %
    %   INPUT
    %     trajBuf      : raw trajectory buffer. Two layouts are supported,
    %                    detected from the column count:
    %                      CenterOutTask.m (N x 8): TrialNum, Time, X, Y,
    %                        Epoch, Block, TrialNumInBlock, Attempt
    %                      CenterInTask.m     (N x 6): TrialNum, Time, X, Y,
    %                        Epoch, Attempt (no Block/TrialNumInBlock -- there
    %                        is no length/position grid to split on)
    %     trajN        : number of valid rows in trajBuf
    %     outDir       : output directory (created if missing)
    %     runTag       : run identifier (used in output filenames)
    %     sessionDate  : session date string for CSV rows
    %     saveAsMat    : bool, save .mat file (default: true)
    %     saveCsv      : bool, save .csv file (default: true)
    %
    %   OUTPUT
    %     none (side effects: files written to disk)
    %
    %   NOTES
    %     - If trajN <= 0, silently returns without saving (nothing to export).
    %     - trajectory = trajBuf(1:trajN, 2:end) removes the TrialNum column
    %       (redundant: Block/TrialNumInBlock/Attempt already identify a row).
    %     - All errors are caught and reported; no exception propagation. That
    %       matters most on the crash-recovery path, where this runs inside an
    %       already-failing catch block.
    %
    %   EXAMPLE (normal export, CenterOutTask.m)
    %     SaveTrajectory(trajBuf, trajN, outDir, d, sessionDate, true, true);
    %     SaveMovementTrajectory(trajBuf, trajN, outDir, d, sessionDate, EP.MOVEMENT.Value);

    % Defaults
    if nargin < 6 || isempty(saveAsMat)
        saveAsMat = true;
    end
    if nargin < 7 || isempty(saveCsv)
        saveCsv = true;
    end
    % Guard: nothing to save
    if isempty(trajBuf) || trajN <= 0
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

    % Extract trajectory (remove TrialNum column 1)
    try
        trajectory = trajBuf(1:trajN, 2:end);
    catch ME
        fprintf('WARNING: could not extract trajectory from buffer: %s\n', ME.message);
        return;
    end

    % Save .mat file
    if saveAsMat
        try
            matFile = fullfile(outDir, sprintf('trajectory_%s.mat', runTag));
            save(matFile, 'trajectory');
            fprintf('Trajectory saved to: %s (%d samples)\n', matFile, trajN);
        catch ME
            fprintf('WARNING: could not save trajectory .mat: %s\n', ME.message);
        end
    end

    % Save .csv file
    if saveCsv
        try
            % TrajectoryColumnNames is the single source of truth for column
            % headers; add a new engine layout there, not here.
            csvFile = fullfile(outDir, sprintf('trajectory_%s.csv', runTag));
            varNames = TrajectoryColumnNames(size(trajectory, 2));
            trajCols = num2cell(trajectory, 1);
            trajTable = table(repmat({sessionDate}, trajN, 1), trajCols{:}, 'VariableNames', varNames);
            writetable(trajTable, csvFile);
            fprintf('Trajectory CSV exported to: %s (%d samples)\n', csvFile, trajN);
        catch ME
            fprintf('WARNING: could not save trajectory .csv: %s\n', ME.message);
        end
    end
end