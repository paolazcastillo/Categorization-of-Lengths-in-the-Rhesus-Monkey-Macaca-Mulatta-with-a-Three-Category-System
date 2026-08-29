function nDropped = FlushRZ2Joystick(rz2)
% FLUSHRZ2JOYSTICK  Throw away everything the relay has queued and start the
% link fresh. Call at any point where the task loop was NOT draining for an
% appreciable time -- the samples that piled up during that gap describe a
% period the task was not running, so they are not data, they are backlog.
%
% WHY THIS EXISTS. SetupRZ2Joystick.m opens the socket well before the trial
% loop starts, and Computer 1 begins streaming 1014 samples/s at once. In
% between sit the rest of setup and, critically, ConfirmRecordingLink.m's
% MODAL questdlg -- the task sits there for as long as the operator takes to
% read a checklist. Ten seconds of that queues ~10,000 samples. Two things
% then go wrong on the first frames of the session:
%
%   * The drain hits its per-frame cap for seconds on end while it works the
%     queue off (see ReadRZ2Joystick.m), so the cursor renders visibly stale
%     samples for the first stretch of the first trials.
%   * Worse, and silently: ReadRZ2Joystick.m anchors its time base on the
%     FIRST sample it ever drains, pairing that sample's index with the
%     local clock at that moment. If that sample was captured ten seconds
%     ago, the whole session's trajectory clock is shifted by ten seconds --
%     and CenterOutTask.m derives t.leaveCenter from that clock
%     (trigTime = sessionT0 + trajBuf(row,2)/1000), so decision/total
%     times on the rz2adc path would be wrong by that offset. Flushing
%     before the loop starts is what makes the anchor land on a fresh
%     sample.
%
% Safe to call with rz2 = [] (input source is not 'rz2adc'), and never
% throws: a flush failing must not be able to take down a session.
%
% OUTPUT nDropped : datagrams discarded (udpport) or bytes discarded (legacy
%                   udp object -- that interface only exposes BytesAvailable).
%                   Reported by the caller, and accumulated on
%                   UserData.nFlushed for the teardown summary.
nDropped = 0;
if isempty(rz2) || ~isfield(rz2, 'port') || isempty(rz2.port)
    return;
end

u = rz2.port;
try
    if rz2.useNewUDP
        nDropped = u.NumDatagramsAvailable;
        if nDropped > 0
            flush(u, 'input');
        end
    else
        nDropped = u.BytesAvailable;
        if nDropped > 0
            flushinput(u);
        end
    end
catch
    return;   % nothing discarded, nothing broken
end

try
    ud = u.UserData;
    if isstruct(ud)
        ud.batch = zeros(0, 3);
        % lastIdx = NaN so the NEXT drain does not read this deliberate
        % discard as a gap in the sample stream: nSkipped is meant to count
        % datagrams LOST (network drops, relay recalibration jumps), and
        % folding a flush into it would make a healthy session look lossy.
        % The discarded count goes to its own nFlushed instead.
        ud.lastIdx       = nan;
        ud.nFlushed      = ud.nFlushed + nDropped;
        ud.lastDrainTime = GetSecs();
        % A fresh queue is not a capping situation any more.
        ud.capConsec     = 0;
        % idxAnchor/tAnchor are deliberately NOT reset: they keep the whole
        % session on one timeline, which is what the trajectory export needs.
        % Only the very first flush (before any sample has been drained)
        % matters for the anchor, and at that point it is still NaN anyway.
        u.UserData = ud;
    end
catch
end
end
