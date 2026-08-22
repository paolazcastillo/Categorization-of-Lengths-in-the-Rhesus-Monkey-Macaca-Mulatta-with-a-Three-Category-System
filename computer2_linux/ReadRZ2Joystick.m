function [vx, vy] = ReadRZ2Joystick(rz2)
% READRZ2JOYSTICK  Drain the datagrams JoystickRelayToTask.m has sent since
% the last call, cache the newest [vx, vy] on rz2.port.UserData for this
% call's return value (used for cursor rendering), and stash the FULL
% drained batch (not just the newest) on rz2.port.UserData.batch for
% TakeRZ2JoystickSamples.m to log to the trajectory -- see that file for
% why logging needs the whole batch instead of the single sample this
% function returns.
% Paola Castillo 2026-07-31
%
% WIRE FORMAT. Each datagram is one relay cycle and carries N_READ sample
% lines, "N:<absIdx>,X:<x>,Y:<y>\n" (see InitJoystickRelay.m's WIRE FORMAT
% note). Datagrams from a relay that has NOT been updated -- one sample per
% datagram, no index, "X:<x>,Y:<y>\n" -- are still accepted, so the two
% machines can be upgraded one at a time; those samples fall back to the old
% estimated timestamps and are counted in UserData.nLegacyFmt.
%
% TIME BASE. absIdx counts RZ2 samples at the ADC's own rate, so the time of
% any sample is (idx - idxAnchor)/sampleRateHz after the local clock reading
% taken when the anchor sample arrived. That is what makes a backlogged
% sample carry the time it was CAPTURED rather than the time it was finally
% read -- the previous version spread each drained batch evenly between
% drains, which is fiction as soon as a queue exists, and those timestamps
% are what the trajectory export and TrialKinematics.m's velocities are
% built from. Two honest caveats: the anchor absorbs whatever one-way
% latency existed at the first drain as a CONSTANT offset (harmless for
% velocities and for within-trial timing, since it cancels in differences),
% and the RZ2's clock and this machine's clock drift apart by their crystals'
% ppm over a session -- neither is corrected here.
%
% DRAIN CAP. The loop stops after rz2.maxSamplesPerDrain samples instead of
% draining whatever has piled up. An unbounded drain inside the Psychtoolbox
% frame loop is what let a backlog turn into a runaway: the longer the queue
% got, the longer the frame that had to swallow it, which grew the queue
% further. With a cap, a bad frame costs a bounded amount and the surplus is
% simply read on the following frames. What is left over is NOT hidden --
% UserData.maxBacklog/nCapped record it and CleanupRZ2Joystick.m prints them,
% because a backlog that never clears is exactly the failure this link had
% and it was previously invisible from inside MATLAB.
u  = rz2.port;
ud = u.UserData;

maxSamples = rz2.maxSamplesPerDrain;
t1 = ud.lastDrainTime;
t2 = GetSecs();

% The cap is checked BEFORE starting a datagram and a datagram that has been
% read is always consumed whole, so the real ceiling is maxSamples plus one
% relay cycle. Capping mid-datagram instead would mean discarding samples
% this process has already taken off the socket and can never get back --
% strictly worse than leaving them queued, which is the whole point.
rows   = zeros(maxSamples + 32, 3);   % [idx, vx, vy] while filling; +slack for the last datagram
nRows  = 0;
capped = false;

while true
    if rz2.useNewUDP
        anyPending = u.NumDatagramsAvailable > 0;
    else
        anyPending = u.BytesAvailable > 0;
    end
    if ~anyPending
        break;
    end
    if nRows >= maxSamples
        capped = true;
        break;
    end

    if rz2.useNewUDP
        d   = read(u, 1, 'char');   % exactly one datagram (see SetupRZ2Joystick.m)
        raw = d.Data;
    else
        raw = fscanf(u);            % DatagramTerminateMode='on' -> one datagram
    end

    % sscanf over the whole datagram, not regexp+str2double per line: 25x
    % cheaper per sample measured, and this runs inside the frame loop.
    %
    % Read flat and reshape HERE rather than asking sscanf for [3 Inf]: given
    % a size, sscanf ZERO-PADS a final record that the data does not fill.
    % A datagram torn mid-line (a partial read, a sender killed mid-write)
    % would therefore not be rejected but silently completed -- "N:101,X:0.6"
    % comes back as [101; 0.6; 0], a fabricated sample that puts the cursor
    % at Y=0. Worse, a tear one field earlier returns a 2-row matrix, whose
    % transpose does not fit the 3-column buffer below and throws INSIDE the
    % frame loop. Counting whole records and discarding the remainder is
    % correct in both cases: a torn record is data we do not have.
    v = reshapeRecords(sscanf(raw, 'N:%f,X:%f,Y:%f\n'), 3);
    if isempty(v)
        vXY = reshapeRecords(sscanf(raw, 'X:%f,Y:%f\n'), 2);   % pre-2026-08-04 relay
        if isempty(vXY)
            continue;   % malformed read; same tolerant convention as the sender
        end
        v = nan(3, size(vXY, 2));   % row 1 stays NaN: no index in that format
        v(2:3, :) = vXY;
    end

    nNew = size(v, 2);
    if nRows + nNew > size(rows, 1)
        rows(nRows + nNew, 3) = 0;   % grow once; only if a datagram is unusually long
    end
    rows(nRows + (1:nNew), :) = v';
    nRows = nRows + nNew;
end

rows = rows(1:nRows, :);

if nRows > 0
    idx = rows(:, 1);
    haveIdx = ~isnan(idx);

    % Anchor the time base on the first indexed sample of the session.
    if any(haveIdx) && isnan(ud.idxAnchor)
        first = find(haveIdx, 1);
        ud.idxAnchor = idx(first);
        ud.tAnchor   = t2;
    end

    % Count index gaps: dropped datagrams AND the relay's periodic
    % recalibration jumps both show up here. Both are REAL discontinuities
    % in the sample stream -- the point of the counter is that neither is
    % silent any more -- so they are reported together rather than
    % pretending they can be told apart from this side. Gaps BETWEEN
    % datagrams of this same drain are counted too, not just the seam
    % against the previous drain: a single lost datagram in the middle of a
    % busy frame is exactly the case a seam-only check would miss.
    if any(haveIdx)
        ii = idx(haveIdx);
        if ~isnan(ud.lastIdx)
            ii = [ud.lastIdx; ii];   % include the seam with the previous drain
        end
        step = diff(ii);
        ud.nSkipped = ud.nSkipped + sum(step(step > 1) - 1);
        ud.lastIdx  = ii(end);
    end

    % Indexed samples get a real time; legacy ones keep the old
    % evenly-spread estimate across this drain interval.
    tOut = zeros(nRows, 1);
    if any(haveIdx)
        tOut(haveIdx) = ud.tAnchor + (idx(haveIdx) - ud.idxAnchor) / rz2.sampleRateHz;
    end
    if any(~haveIdx)
        nLegacy = sum(~haveIdx);
        tOut(~haveIdx) = t1 + (t2 - t1) * ((1:nLegacy)' / nLegacy);
        ud.nLegacyFmt = ud.nLegacyFmt + nLegacy;
    end
    rows(:, 1) = tOut;

    ud.batch    = [ud.batch; rows];
    ud.lastX    = rows(end, 2);
    ud.lastY    = rows(end, 3);
    ud.nSamples = ud.nSamples + nRows;
end

% Whatever is still queued after this drain -- the health signal that used
% to be invisible.
if rz2.useNewUDP
    backlog = u.NumDatagramsAvailable;
else
    backlog = u.BytesAvailable;   % bytes, not datagrams (legacy object)
end
if backlog > ud.maxBacklog
    ud.maxBacklog = backlog;
end
if capped
    ud.nCapped   = ud.nCapped + 1;
    ud.capConsec = ud.capConsec + 1;
    % Warn on SUSTAINED capping, not on the first frame that hits the cap.
    % One capped frame -- or a run of them -- is the normal, self-clearing
    % way a backlog gets worked off after any stall the task loop takes
    % (a trial-transition write, an operator pause, session start before
    % FlushRZ2Joystick.m runs). Warning on the first hit cried wolf every
    % session. What actually needs attention is a queue that is NOT
    % clearing: at 60 fps this threshold is about a second of continuous
    % capping, which no transient burst reaches.
    if ud.capConsec == rz2.capWarnFrames
        warning('rz2:drainCapped', ...
            ['RZ2 drain has been at its %d-sample per-frame cap for %d frames straight -- ' ...
             'the relay is arriving faster than this loop is reading it and the queue is ' ...
             'not clearing, so cursor lag is building. Check that the task loop is holding ' ...
             'frame rate; the teardown summary reports the worst backlog seen.'], ...
            maxSamples, rz2.capWarnFrames);
    end
else
    ud.capConsec = 0;
end

ud.lastDrainTime = t2;
u.UserData = ud;

vx = ud.lastX;
vy = ud.lastY;
end

% ===========================================================================
function m = reshapeRecords(vals, fieldsPerRecord)
% Flat sscanf output -> [fieldsPerRecord x nComplete], dropping a trailing
% partial record instead of letting it be zero-padded into a real-looking
% sample. See the call site for why that padding is dangerous here.
n = floor(numel(vals) / fieldsPerRecord);
m = reshape(vals(1:fieldsPerRecord * n), fieldsPerRecord, n);
end
