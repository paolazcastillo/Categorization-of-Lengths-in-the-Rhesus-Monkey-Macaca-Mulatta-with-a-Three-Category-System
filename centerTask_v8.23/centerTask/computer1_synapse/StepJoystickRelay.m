function state = StepJoystickRelay(state)
% STEPJOYSTICKRELAY  Do ONE relay cycle's worth of work, but ONLY if
% RELAY_PERIOD has actually elapsed since the last one -- otherwise
% returns state unchanged immediately. Call this once per iteration of
% whatever loop is driving it (JoystickRelayToTask.m's own standalone
% while loop, or Communication_CategTask_ACTX.m's reward/marker loop);
% the early-return makes it safe to call far more often than RELAY_HZ
% without over-reading/over-sending, and -- critically for the
% Communication_CategTask_ACTX.m case -- this function never calls
% pause(), so it never blocks that loop's own, unrelated reward/marker
% polling. All errors (read failures, recalibration failures) are caught
% internally so a transient joystick-relay problem can't propagate up and
% take down whatever loop is calling this.
%
% RECALIBRATION IS NON-BLOCKING (2026-07-30 fix): this used to call
% calibrateActiveIndex.m directly for its periodic recalibration, which
% does pause(CALIBRATION_WAIT_SEC) TWICE (once per channel, ~0.3s total) --
% directly contradicting the "never calls pause()" claim above. Because
% Communication_CategTask_ACTX.m drives both this relay AND reward
% delivery from the same single-threaded loop, that pause froze reward
% delivery for up to ~0.3s whenever a target hit landed during a
% recalibration window -- confirmed 2026-07-30 (intermittent reward lag,
% only when the hit's timing collided with a recalibration). Fixed by
% splitting the two buffer snapshots calibrateActiveIndex.m takes across
% TWO SEPARATE calls of this function instead of pausing between them
% (see the recalibration block below): the read/send section further down
% keeps using the OLD curIdxX/curIdxY while a recalibration is pending,
% which is fine -- they stay valid (just accumulating the small ~3 Hz/s
% drift, see InitJoystickRelay.m) until the pending one resolves.
if toc(state.tLoopRef) < state.RELAY_PERIOD
    return;
end
state.tLoopRef = tic;

% Write-index mode is active when state.WRITE_IDX_TAG names an API-readable
% SerStore write-head tag (see InitJoystickRelay.m and the ID_widx circuit
% edit). When active it replaces the diff-peak recalibration AND the
% time-based pacing with a direct read of the write head: exactly the samples
% between our last read cursor and the head are drained each cycle. Empty ''
% (default) keeps the legacy behaviour unchanged.
useWriteIdx = isfield(state, 'WRITE_IDX_TAG_X') && ~isempty(state.WRITE_IDX_TAG_X) ...
           && isfield(state, 'WRITE_IDX_TAG_Y') && ~isempty(state.WRITE_IDX_TAG_Y);

% --- Periodic recalibration: re-sync both cursors to the real write
% position (see ActiveIndexFromSnapshots.m for the technique) so the lag
% N_READ's below-real-rate advance accumulates never grows past
% RECAL_INTERVAL_SEC -- as a two-phase, non-blocking state machine instead
% of calibrateActiveIndex.m's pause()-based version (see this file's
% header for why). Phase 1 takes the first snapshot of both channels and
% returns immediately; phase 2, on a LATER call once CALIBRATION_WAIT_SEC
% has actually elapsed, takes the second snapshot and resolves the new
% indices. Neither phase calls pause().
%
% Skipped entirely in write-index mode (useWriteIdx): the write head is read
% directly in the read section below, so there is nothing to recalibrate and
% ActiveIndexFromSnapshots is never called.
if ~useWriteIdx
if ~state.calibPending
    % RECAL_ENABLED gates the START of a recalibration only. calibPending
    % begins false and is set true solely inside this branch, so gating here
    % keeps the expensive phase-2 read (below) from ever running when
    % recalibration is disabled, without touching the read/send path. See the
    % RECAL_ENABLED note in InitJoystickRelay.m for why it is off by default.
    if state.RECAL_ENABLED && toc(state.tRecalRef) >= state.RECAL_INTERVAL_SEC
        try
            % WINDOWED snapshot: read only RECAL_WINDOW samples around the
            % PREDICTED head instead of the whole buffer (see InitJoystickRelay.m's
            % RECAL_WINDOW note for why this is what makes recalibration cheap
            % enough not to freeze the loop). winStart is fixed here and reused
            % for phase 2 below, so both snapshots cover the SAME slice and
            % their difference localises the freshly-written head within it.
            predHead1 = mod(state.lastHeadIdx + state.WRITE_FS * toc(state.tHeadRef), state.BUF_SIZE);
            state.calibWinStart = mod(round(predHead1 - state.RECAL_WINDOW / 2), state.BUF_SIZE);
            state.calibDataX1   = readBufWindow(state.syn, 'APICh1X', state.BUF_SIZE, state.calibWinStart, state.RECAL_WINDOW);
            state.calibDataY1   = readBufWindow(state.syn, 'APICh2Y', state.BUF_SIZE, state.calibWinStart, state.RECAL_WINDOW);
            state.calibStartRef = tic;
            state.calibPending  = true;
        catch ME
            warning('Joystick relay recalibration start error: %s', ME.message);
        end
    end
elseif toc(state.calibStartRef) >= state.CALIBRATION_WAIT_SEC
    tRecal = tic;
    try
        % Second snapshot of the SAME window fixed at phase 1. ActiveIndex-
        % FromSnapshots returns a 1-based index WITHIN the window; map it back
        % to an absolute buffer position (mod handles a window that wrapped
        % across the end of the ring -- readBufWindow keeps the samples in
        % circular order, so winStart + (k-1) is the true position of peak k).
        dataX2 = readBufWindow(state.syn, 'APICh1X', state.BUF_SIZE, state.calibWinStart, state.RECAL_WINDOW);
        dataY2 = readBufWindow(state.syn, 'APICh2Y', state.BUF_SIZE, state.calibWinStart, state.RECAL_WINDOW);
        newIdxX = mod(state.calibWinStart + ActiveIndexFromSnapshots(state.calibDataX1, dataX2) - 1, state.BUF_SIZE);
        newIdxY = mod(state.calibWinStart + ActiveIndexFromSnapshots(state.calibDataY1, dataY2) - 1, state.BUF_SIZE);

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
        % check independent of whether the driving loop achieved RELAY_HZ --
        % Communication_CategTask_ACTX.m's loop often will not, and any
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
            % were continuous across the jump -- compressing a real gap into
            % zero. X is the reference for absIdx; X and Y advance in
            % lockstep by construction.
            %
            % BUG FIX 2026-08-25: this line used to be
            %     state.absIdx + mod(newIdxX - state.curIdxX, state.BUF_SIZE)
            % which is correct ONLY when the correction moves the cursor
            % FORWARD. When an accepted recalibration moves it BACKWARD
            % (newIdxX < curIdxX -- i.e. the read cursor had over-run the
            % write head and is being pulled back), the subtraction is
            % negative and mod() wraps it to nearly a full buffer: a 2,912
            % sample backward correction became a 97,088 sample FORWARD
            % jump. Confirmed on real logs (session 25Aug2026_1853): the
            % single accepted recalibration of that session, at t=225s,
            % moved absIdx by exactly +97,088 while the datagram and sample
            % counters advanced completely normally (+19 and +179) -- no
            % data was lost, the INDEX lied. Computer 2 then read that as
            % 97,088 skipped samples and timestamped the stream
            % 97,088/1017 = 95.5 s in the past, which is precisely the
            % "-95.5 s" lag jump seen there and in the 22Aug session.
            % Same arithmetic explains why the jump was always ~95 s and
            % never some other value: it is BUF_SIZE, not a variable stall.
            delta = circDelta(newIdxX, state.curIdxX, state.BUF_SIZE);
            if delta >= 0
                state.absIdx = state.absIdx + delta;
            else
                % Backward correction. absIdx MUST stay monotonic (Computer
                % 2 derives sample times from it and treats a decrease as a
                % gap), so we do not rewind it -- but we must not fabricate
                % a forward jump either, which is the bug above. Advancing
                % by 0 leaves absIdx overstating real elapsed samples by
                % |delta|, a bounded error (~2.9 s at the magnitude seen)
                % instead of an unbounded ~95 s one. Warned, not silent:
                % this event was invisible before, which is why it took a
                % cross-machine log comparison to find it at all.
                state.nBackwardRecal = state.nBackwardRecal + 1;
                warning(['Joystick relay: accepted recalibration moved the read cursor ' ...
                    'BACKWARD by %d samples (read cursor had over-run the write head). ' ...
                    'absIdx held (not rewound, not jumped); trajectory times after this ' ...
                    'point overstate elapsed samples by that much. Occurrence %d this ' ...
                    'session.'], -delta, state.nBackwardRecal);
            end
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
    % With the windowed read this should be a small fraction of the old
    % full-buffer cost; warn once if it is still high enough to matter against
    % the relay period (e.g. RECAL_WINDOW set too large, or a slow Synapse).
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
end   % if ~useWriteIdx  (recalibration is skipped in write-index mode)

% --- Decide how many samples to read this cycle ---
% Two modes:
%  * write-index (useWriteIdx): read the SerStore write head straight from the
%    API tag state.WRITE_IDX_TAG and drain exactly the samples between our last
%    read cursor and it. No diff-peak, no recalibration, no pacing guess. X and
%    Y are paired by taking the smaller of the two per-channel new-sample counts
%    (identical when the two gizmos are in lockstep, which they are by design).
%  * legacy (default): nRead comes from wall-clock elapsed x READ_FS (time-based
%    pacing), so the cursor keeps pace with the ~1017 Hz writer no matter how
%    slowly the driving loop calls this. MAX_READ_PER_CYCLE bounds a long stall.
if useWriteIdx
    idxOk = true;
    tProf = tic;
    try
        Wx = mod(round(double(readWriteIndex(state.syn, 'APICh1X', state.WRITE_IDX_TAG_X))), state.BUF_SIZE);
        Wy = mod(round(double(readWriteIndex(state.syn, 'APICh2Y', state.WRITE_IDX_TAG_Y))), state.BUF_SIZE);
    catch ME_idx
        idxOk = false;
        if ~state.widxFellBack
            state.widxFellBack = true;
            warning(['Joystick relay: could not read write-index tags (%s / %s): %s. ' ...
                'Falling back to legacy time-based pacing so the cursor does not freeze.'], ...
                state.WRITE_IDX_TAG_X, state.WRITE_IDX_TAG_Y, ME_idx.message);
        end
    end
    state.profIdxMs = state.profIdxMs + toc(tProf) * 1000;
    if idxOk && ~state.widxInited
        % First good read: anchor the read cursor to the live head so we do
        % NOT dump the whole backlog buffer at startup; stream forward from here.
        state.curIdxX = Wx;  state.curIdxY = Wy;
        state.widxInited = true;
        state.widxNew = 0;
        nRead = 0;
    elseif idxOk
        % Signed, not mod(): if the head reads BEHIND our cursor (we
        % over-ran it, or the tag glitched), mod() would wrap that into
        % nearly a full buffer and we would re-stream ~BUF_SIZE stale
        % samples as if they were new -- the same class of bug that made
        % the accepted-recalibration path inject phantom 95 s jumps before
        % the 2026-08-25 fix. Here we clamp to 0 instead: read nothing this
        % cycle and let the writer move ahead of us again.
        newX = circDelta(Wx, state.curIdxX, state.BUF_SIZE);
        newY = circDelta(Wy, state.curIdxY, state.BUF_SIZE);
        if newX < 0 || newY < 0
            state.nHeadBehind = state.nHeadBehind + 1;
            if state.nHeadBehind == 1 || mod(state.nHeadBehind, 100) == 0
                warning(['Joystick relay: write head read BEHIND the read cursor ' ...
                    '(X %+d, Y %+d samples). Reading 0 this cycle. Occurrence %d. ' ...
                    'A few of these are normal jitter; a steady stream means the ' ...
                    'read pacing is outrunning the writer.'], newX, newY, state.nHeadBehind);
            end
            newX = max(newX, 0);
            newY = max(newY, 0);
        end
        state.widxNew = min(newX, newY);               % relay-side backlog (samples waiting, pre-cap)
        nRead = min(state.widxNew, state.MAX_READ_PER_CYCLE);   % bound a post-stall burst
    else
        % Tag unreadable this cycle: degrade to legacy pacing rather than 0, so
        % a missing/wrong tag never stalls the stream.
        nRead = round(state.READ_FS * toc(state.tReadRef));
        nRead = max(1, min(nRead, state.MAX_READ_PER_CYCLE));
    end
else
    nRead = round(state.READ_FS * toc(state.tReadRef));
    nRead = max(1, min(nRead, state.MAX_READ_PER_CYCLE));
end
state.tReadRef = tic;
% nDone is how far the read cursors ACTUALLY advanced this cycle: nRead once
% both buffer reads succeed, 0 if either throws. absIdx below advances by
% nDone, not nRead. It used to advance by nRead unconditionally, outside the
% try, while the cursor advance sat inside it -- so a failed readBufWindow
% left the cursors in place and pushed absIdx forward anyway, and the next
% cycle re-read and re-sent the same samples under new, higher indices:
% duplicated positions with two different timestamps, and an index that
% overstated real elapsed samples by nRead. Found by review 2026-09-05; not
% seen firing on the rig (no 'read error' lines in any log), but latent.
nDone = 0;
try
    if nRead > 0
    offsetX = mod(state.curIdxX, state.BUF_SIZE);
    offsetY = mod(state.curIdxY, state.BUF_SIZE);
    tProf   = tic;
    dataX   = readBufWindow(state.syn, 'APICh1X', state.BUF_SIZE, offsetX, nRead);
    dataY   = readBufWindow(state.syn, 'APICh2Y', state.BUF_SIZE, offsetY, nRead);
    state.profReadMs = state.profReadMs + toc(tProf) * 1000;
    state.curIdxX = mod(state.curIdxX + nRead, state.BUF_SIZE);
    state.curIdxY = mod(state.curIdxY + nRead, state.BUF_SIZE);
    nDone = nRead;

    % Send this cycle's samples, SPLIT into datagrams of at most
    % MAX_SAMPLES_PER_DGRAM so no single datagram exceeds the UDP output
    % buffer or one MTU. Time-based pacing can read many samples in a cycle
    % (a slow cycle catches up), and packing them all into one datagram is
    % what threw the "bytes written must be <= OutputBufferSize" send error.
    % Computer 2 reassembles by absIdx, so several datagrams this cycle are
    % identical in effect to one big one (see ReadRZ2Joystick.m). X and Y are
    % paired index-by-index, valid as long as both gizmos share the same fs.
    nSamples = min(length(dataX), length(dataY));
    if nSamples > 0
        xNorm = max(-1, min(1, dataX(1:nSamples) / state.JOY_RANGE));
        yNorm = max(-1, min(1, dataY(1:nSamples) / state.JOY_RANGE));
        idxAll = state.absIdx + (0:nSamples-1);
        tProf  = tic;
        for c0 = 1:state.MAX_SAMPLES_PER_DGRAM:nSamples
            c1  = min(c0 + state.MAX_SAMPLES_PER_DGRAM - 1, nSamples);
            sel = c0:c1;
            % Column-major sprintf: a 3 x n matrix of [absIdx; x; y] emits
            % the lines in sample order.
            msg = sprintf('N:%.0f,X:%.4f,Y:%.4f\n', ...
                [idxAll(sel).', xNorm(sel), yNorm(sel)].');
            try
                if state.useNewUDP
                    write(state.udpObj, uint8(msg), state.REMOTE_HOST, state.UDP_PORT);
                else
                    fwrite(state.udpObj, msg);
                end
                state.nDatagrams = state.nDatagrams + 1;
            catch ME_send
                % DIAGNOSTIC (2026-08-22): this used to warn exactly ONCE for
                % the whole session, then go completely silent -- if the send
                % buffer overflowed again later (or kept overflowing through
                % an entire burst), there was no trace anywhere. Now counts
                % every failure and re-prints periodically (every 5s while
                % it's actively happening), so a send-side loss episode is
                % visible for its whole duration, not just its first instant.
                state.sendErrorCount = state.sendErrorCount + 1;
                if isinf(state.lastSendErrorAt) || GetSecs() - state.lastSendErrorAt >= 5
                    warning('Joystick relay send error (%d total this session): %s', ...
                        state.sendErrorCount, ME_send.message);
                    state.lastSendErrorAt = GetSecs();
                end
            end
        end

        state.profSendMs = state.profSendMs + toc(tProf) * 1000;

        % Keep the last values for the log line below
        state.xRaw  = dataX(nSamples);
        state.yRaw  = dataY(nSamples);
        state.xNorm = xNorm(nSamples);
        state.yNorm = yNorm(nSamples);
    end
    end   % if nRead > 0

catch ME
    state.nReadErrors = state.nReadErrors + 1;
    warning('Joystick relay read error (%d this session): %s', state.nReadErrors, ME.message);
end

% Advance by nDone, not nSamples and not nRead: absIdx has to track the
% CURSOR (real RZ2 samples consumed) for index differences to mean elapsed
% time, and the cursor only moved if the reads succeeded (see nDone above).
state.absIdx        = state.absIdx        + nDone;
state.nPkts         = state.nPkts         + nDone;
state.profCycles    = state.profCycles    + 1;

% --- Log every 5 seconds ---
if toc(state.tLogRef) >= 5
    % Recal is shown as accepted/rejected: a rejected count that keeps
    % climbing is the cursor drifting uncorrected, which otherwise only
    % shows up as a vaguely laggy cursor on the other machine.
    fprintf('%-8d %-8d %-11s %-9.1f %-11.5f %-11.5f %-11.5f %-11.5f\n', ...
        state.nPkts, state.nDatagrams, ...
        sprintf('%d/%d', state.nRecal - state.nRecalRejected, state.nRecal), ...
        state.recalMs, state.xRaw, state.xNorm, state.yRaw, state.yNorm);
    if state.sendErrorCount > 0
        % DIAGNOSTIC (2026-08-22): visible in the normal log line too, not
        % just the throttled warning() above -- samples that were READ from
        % SerStore but never left this machine (send failed) count toward
        % nPkts but NOT nDatagrams, so a gap between the two plus this being
        % nonzero is the signature of send-side loss specifically (as
        % opposed to a receive-side drop, which shows up as Comp2's
        % nSkipped instead).
        fprintf('   sendErrorCount: %d (samples read but never sent this session)\n', ...
            state.sendErrorCount);
    end
    if state.nBackwardRecal > 0
        % DIAGNOSTIC (2026-08-25): the event that caused the ~95 s phantom
        % lag jumps before the absIdx wraparound fix. Now bounded and
        % counted rather than silently corrupting every timestamp after it.
        fprintf('   nBackwardRecal: %d (recalibrations that pulled the cursor back)\n', ...
            state.nBackwardRecal);
    end
    % Per-cycle cost breakdown (2026-09-05). The sum of the three is the
    % floor on this loop's period: at 169.4 Hz the budget is 5.9 ms, and on
    % 05-Sep the loop was measured at ~23 ms per cycle without a single line
    % saying where it went. Whichever of these dominates is the fix.
    if state.profCycles > 0
        fprintf('   cycle cost: idx %.2f ms + read %.2f ms + send %.2f ms = %.2f ms/cycle over %d cycles', ...
            state.profIdxMs / state.profCycles, state.profReadMs / state.profCycles, ...
            state.profSendMs / state.profCycles, ...
            (state.profIdxMs + state.profReadMs + state.profSendMs) / state.profCycles, state.profCycles);
        if state.nReadErrors > 0
            fprintf(' | readErrors %d', state.nReadErrors);
        end
        fprintf('\n');
        state.profIdxMs = 0; state.profReadMs = 0; state.profSendMs = 0; state.profCycles = 0;
    end
    if useWriteIdx
        % Relay-side lag: how many samples were waiting behind the write head
        % this cycle, and that in ms at WRITE_FS. Should stay small and STEADY
        % (~READ_FS/RELAY_HZ). A number that climbs means the relay is falling
        % behind the writer (not a render/monitor problem).
        fprintf('   write-index: backlog ~%d samples (~%.1f ms behind head)\n', ...
            state.widxNew, 1000 * state.widxNew / state.WRITE_FS);
    end
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

% ===========================================================================
function d = circDelta(a, b, n)
% SIGNED shortest displacement from b to a on a circular buffer of length n:
% positive if a is ahead of b, NEGATIVE if a is behind it. circDist() above
% deliberately discards that sign (it answers "how far apart", not "which
% way"), which is fine for its tolerance check but is exactly what must NOT
% be discarded when accounting absIdx -- see the 2026-08-25 bug fix note in
% the acceptX block. Any displacement past the halfway point of the ring is
% read as the shorter move in the opposite direction, which is the correct
% interpretation here: a recalibration correcting a read cursor by a few
% thousand samples is a small local adjustment, never a near-full-lap jump.
d = mod(a - b, n);
if d > n / 2
    d = d - n;
end
end

% ===========================================================================
function data = readBufWindow(syn, gizmo, bufSize, winStart, winLen)
% Read winLen samples of gizmo's 'data1' starting at circular offset winStart,
% wrapping across the end of the bufSize ring when the window straddles it.
% Returns a winLen-long column vector in circular order (so the k-th element
% is buffer position mod(winStart + k - 1, bufSize)), which is what lets the
% caller map ActiveIndexFromSnapshots.m's in-window peak back to an absolute
% index. Only splits into two getParameterValues calls when the window wraps;
% the common case is a single read.
winStart = mod(winStart, bufSize);
winLen   = min(winLen, bufSize);
if winStart + winLen <= bufSize
    data = double(syn.getParameterValues(gizmo, 'data1', winLen, winStart));
    data = data(:);
else
    n1 = bufSize - winStart;
    d1 = double(syn.getParameterValues(gizmo, 'data1', n1, winStart));
    d2 = double(syn.getParameterValues(gizmo, 'data1', winLen - n1, 0));
    data = [d1(:); d2(:)];
end
end

% ===========================================================================
function v = readWriteIndex(syn, gizmo, tag)
% Read a scalar write-head index parameter (e.g. 'widx') from a gizmo via
% SynapseAPI. Uses getParameterValue when available, falling back to a
% single-element getParameterValues read for older API objects.
try
    v = syn.getParameterValue(gizmo, tag);
catch
    tmp = double(syn.getParameterValues(gizmo, tag, 1, 0));
    v = tmp(1);
end
end