function state = StepJoystickRelay(state)
% STEPJOYSTICKRELAY  Do ONE relay cycle's worth of work, but ONLY if
% RELAY_PERIOD has actually elapsed since the last one; otherwise
% returns state unchanged immediately. Call this once per iteration of
% whatever loop is driving it (JoystickRelayToTask.m's own standalone
% while loop, or CommunicationCategTaskACTX.m's reward/marker loop);
% the early-return makes it safe to call far more often than RELAY_HZ
% without over-reading/over-sending, and (critically for the
% CommunicationCategTaskACTX.m case) this function never calls
% pause(), so it never blocks that loop's own, unrelated reward/marker
% polling. All errors (read failures, recalibration failures) are caught
% internally so a transient joystick-relay problem can't propagate up and
% take down whatever loop is calling this.
%
% RECALIBRATION IS NON-BLOCKING. Periodic recalibration deliberately does
% NOT call CalibrateActiveIndex.m, which does pause(CALIBRATION_WAIT_SEC)
% TWICE (once per channel, ~0.3s total) and would directly contradict the
% "never calls pause()" claim above. Because CommunicationCategTaskACTX.m
% drives both this relay AND reward delivery from the same single-threaded
% loop, such a pause freezes reward delivery for up to ~0.3s whenever a
% target hit lands during a recalibration window (observed 2026-07-30 as
% intermittent reward lag, only when the hit's timing collided with a
% recalibration). Instead, the two buffer snapshots CalibrateActiveIndex.m
% takes are split across TWO SEPARATE calls of this function rather than
% pausing between them (see the recalibration block below): the read/send
% section further down keeps using the OLD curIdxX/curIdxY while a
% recalibration is pending, which is fine; they stay valid (just
% accumulating the small ~3 Hz/s drift, see InitJoystickRelay.m) until the
% pending one resolves.
if toc(state.tLoopRef) < state.RELAY_PERIOD
    return;
end
state.tLoopRef = tic;

% --- Periodic recalibration: re-sync both cursors to the real write
% position (see ActiveIndexFromSnapshots.m for the technique) so the lag
% N_READ's below-real-rate advance accumulates never grows past
% RECAL_INTERVAL_SEC, as a two-phase, non-blocking state machine instead
% of CalibrateActiveIndex.m's pause()-based version (see this file's
% header for why). Phase 1 takes the first snapshot of both channels and
% returns immediately; phase 2, on a LATER call once CALIBRATION_WAIT_SEC
% has actually elapsed, takes the second snapshot and resolves the new
% indices. Neither phase calls pause().
if ~state.calibPending
    if toc(state.tRecalRef) >= state.RECAL_INTERVAL_SEC
        try
            state.calibDataX1   = double(state.syn.getParameterValues('APICh1X', 'data1', state.BUF_SIZE, 0));
            state.calibDataY1   = double(state.syn.getParameterValues('APICh2Y', 'data1', state.BUF_SIZE, 0));
            state.calibStartRef = tic;
            state.calibPending  = true;
        catch ME
            warning('Joystick relay recalibration start error: %s', ME.message);
        end
    end
elseif toc(state.calibStartRef) >= state.CALIBRATION_WAIT_SEC
    tRecal = tic;
    try
        dataX2 = double(state.syn.getParameterValues('APICh1X', 'data1', state.BUF_SIZE, 0));
        dataY2 = double(state.syn.getParameterValues('APICh2Y', 'data1', state.BUF_SIZE, 0));
        newIdxX = ActiveIndexFromSnapshots(state.calibDataX1, dataX2);
        newIdxY = ActiveIndexFromSnapshots(state.calibDataY1, dataY2);

        % Sanity-check the proposed indices against where the WRITE HEAD
        % must be by now, not against how far the cursor has drifted.
        %
        % Checking the jump size was the obvious formulation and it is
        % wrong, in a way that deadlocks: the cursor's gap to the head also
        % contains whatever the startup calibration left behind and every
        % previously-rejected correction, so a perfectly good large
        % correction gets refused, the gap it would have closed stays, and
        % every later attempt sees the same too-small budget. Measured on
        % the mock rig: cursor 1435 behind, correct proposal 1290, refused
        % against a 512 budget, forever.
        %
        % The head, by contrast, is predictable without knowing anything
        % about the cursor: it was at lastHeadIdx at tHeadRef and advances
        % at WRITE_FS. A diff-peak that lands near that prediction is a real
        % measurement of the head; one that lands far from it is a bad peak
        % or a lapped buffer, which is the failure worth refusing (see the
        % RECAL_TOL_* note in InitJoystickRelay.m). This also makes the
        % check independent of whether the driving loop achieved RELAY_HZ;
        % CommunicationCategTaskACTX.m's loop often will not, and any
        % cursor-based budget would have to model that.
        elapsedHead = toc(state.tHeadRef);
        predHead    = mod(state.lastHeadIdx + state.WRITE_FS * elapsedHead, state.BUF_SIZE);
        tol = max(state.RECAL_TOL_FLOOR, state.RECAL_TOL_FRAC * state.WRITE_FS * elapsedHead);
        errX = circDist(newIdxX, predHead, state.BUF_SIZE);
        errY = circDist(newIdxY, predHead, state.BUF_SIZE);
        acceptX = errX <= tol;
        acceptY = errY <= tol;
        % Kept on state so a rejection is diagnosable after the fact, not
        % just at the instant its warning fires.
        state.lastErrX  = errX;
        state.lastErrY  = errY;
        state.lastTol   = tol;

        if acceptX
            % Carry the accepted jump into absIdx so it keeps counting REAL
            % RZ2 samples, not just the ones this relay forwarded. A
            % recalibration skips over samples written while we were behind;
            % without adding that skip, absIdx would imply they never
            % happened and Computer 2 would compute times as if the stream
            % were continuous across the jump, compressing a real gap into
            % zero. X is the reference for absIdx; X and Y advance in
            % lockstep by construction.
            state.absIdx  = state.absIdx + mod(newIdxX - state.curIdxX, state.BUF_SIZE);
            state.curIdxX = newIdxX;
            % Re-anchor the head prediction on this measurement. Only an
            % ACCEPTED index may do this: re-anchoring on a rejected one
            % would let a single bad peak redefine where the head "is" and
            % drag every later check along with it.
            state.lastHeadIdx = newIdxX;
            state.tHeadRef    = tic;
        end
        if acceptY
            state.curIdxY = newIdxY;
        end

        state.nRecal = state.nRecal + 1;
        if acceptX && acceptY
            state.recalConsecBad = 0;
        else
            state.nRecalRejected = state.nRecalRejected + 1;
            state.recalConsecBad = state.recalConsecBad + 1;
            % Rejecting is safe once; rejecting repeatedly means the cursor
            % is never being corrected and the drift is growing unchecked,
            % which the operator needs to know about while the session is
            % still running.
            if state.recalConsecBad == 3
                warning(['Joystick relay: %d recalibrations in a row proposed a write-head ' ...
                    'index far from where it must be (X off by %d, Y by %d samples, tolerance ' ...
                    '%d) and were rejected. The read cursor is drifting uncorrected -- check ' ...
                    'that the SerStore buffers are actually being written.'], ...
                    state.recalConsecBad, round(errX), round(errY), round(tol));
            end
        end
    catch ME
        warning('Joystick relay recalibration finish error: %s', ME.message);
    end
    state.recalMs = toc(tRecal) * 1000;
    % Four full-buffer reads per recalibration is the price of a short
    % RECAL_INTERVAL_SEC; warn once if that price is high enough to matter
    % against the relay period it has to fit inside.
    if state.recalMs > 100 && ~state.recalSlowWarned
        state.recalSlowWarned = true;
        warning(['Joystick relay: a recalibration took %.0f ms of SynapseAPI time. At ' ...
            'RECAL_INTERVAL_SEC=%g that is %.1f%% of the relay''s duty cycle -- consider ' ...
            'raising the interval (see InitJoystickRelay.m).'], ...
            state.recalMs, state.RECAL_INTERVAL_SEC, 100 * (state.recalMs/1000) / state.RECAL_INTERVAL_SEC);
    end
    state.calibPending = false;
    state.tRecalRef    = tic;
end

% --- Read N_READ samples per channel from the current indices ---
try
    offsetX = mod(state.curIdxX, state.BUF_SIZE);
    offsetY = mod(state.curIdxY, state.BUF_SIZE);
    dataX   = double(state.syn.getParameterValues('APICh1X', 'data1', state.N_READ, offsetX));
    dataY   = double(state.syn.getParameterValues('APICh2Y', 'data1', state.N_READ, offsetY));
    state.curIdxX = mod(state.curIdxX + state.N_READ, state.BUF_SIZE);
    state.curIdxY = mod(state.curIdxY + state.N_READ, state.BUF_SIZE);

    % Send this cycle's samples as ONE datagram (see InitJoystickRelay.m's
    % WIRE FORMAT note for why this is not one datagram per sample any
    % more). Both channels are read with the same N_READ/cycle, so pairing
    % them index-by-index assumes X and Y advance in lockstep, true as
    % long as both gizmos share the same fs (see the Y AXIS note there).
    nSamples = min(length(dataX), length(dataY));
    if nSamples > 0
        xNorm = max(-1, min(1, dataX(1:nSamples) / state.JOY_RANGE));
        yNorm = max(-1, min(1, dataY(1:nSamples) / state.JOY_RANGE));
        % One vectorised sprintf, not a loop: the format is consumed
        % column-major, so a 3 x nSamples matrix of [absIdx; x; y] emits
        % the lines in sample order.
        idx = state.absIdx + (0:nSamples-1);
        msg = sprintf('N:%.0f,X:%.4f,Y:%.4f\n', [idx(:), xNorm(:), yNorm(:)]');
        try
            if state.useNewUDP
                write(state.udpObj, uint8(msg), state.REMOTE_HOST, state.UDP_PORT);
            else
                fwrite(state.udpObj, msg);
            end
            state.nDatagrams = state.nDatagrams + 1;
        catch ME_send
            % Warn once, not once per cycle; a send failure here is
            % otherwise completely silent, and previously looked identical
            % to a healthy relay from Computer 1's own console.
            if ~state.sendErrorWarned
                warning('Joystick relay send error (further sends will not be logged): %s', ME_send.message);
                state.sendErrorWarned = true;
            end
        end

        % Keep the last values for the log line below
        state.xRaw  = dataX(nSamples);
        state.yRaw  = dataY(nSamples);
        state.xNorm = xNorm(nSamples);
        state.yNorm = yNorm(nSamples);
    end

catch ME
    warning('Joystick relay read error: %s', ME.message);
end

% Advance by N_READ, not nSamples: the read cursors above advanced by
% N_READ unconditionally, and absIdx has to track the CURSOR (real RZ2
% samples consumed) for index differences to mean elapsed time.
state.absIdx        = state.absIdx        + state.N_READ;
state.nPkts         = state.nPkts         + state.N_READ;

% --- Log every 5 seconds ---
if toc(state.tLogRef) >= 5
    % Recal is shown as accepted/rejected: a rejected count that keeps
    % climbing is the cursor drifting uncorrected, which otherwise only
    % shows up as a vaguely laggy cursor on the other machine.
    fprintf('%-8d %-8d %-11s %-9.1f %-11.5f %-11.5f %-11.5f %-11.5f\n', ...
        state.nPkts, state.nDatagrams, ...
        sprintf('%d/%d', state.nRecal - state.nRecalRejected, state.nRecal), ...
        state.recalMs, state.xRaw, state.xNorm, state.yRaw, state.yNorm);
    state.tLogRef = tic;
end
end

% ===========================================================================
function d = circDist(a, b, n)
% Shortest distance between two positions on a circular buffer of length n.
% Plain |a-b| would call two adjacent positions straddling the wrap point
% almost a full buffer apart, which is exactly the case the recalibration
% guard above has to judge correctly.
d = mod(a - b, n);
d = min(d, n - d);
end