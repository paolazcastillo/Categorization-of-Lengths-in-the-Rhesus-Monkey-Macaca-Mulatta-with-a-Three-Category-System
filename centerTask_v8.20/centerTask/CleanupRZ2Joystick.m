function CleanupRZ2Joystick(rz2)
% CLEANUPRZ2JOYSTICK  Closes the UDP listener socket SetupRZ2Joystick.m
% opened (rz2.port) -- the Computer-2 counterpart to Computer 1's
% CleanupJoystickRelay.m, same reasoning: a udpport/udp object left open
% keeps its LocalPort bound, so the next run's SetupRZ2Joystick.m fails
% with "Address already in use" until either this MATLAB session ends or
% something closes it. This used to never get called anywhere -- neither
% CenterOutTask.m's/CenterInTask.m's normal teardown nor their crash/catch
% path released rz2.port -- so any run that ended (normal exit, operator
% abort, or an uncaught error) while Input source = 'rz2adc' left port 8831
% bound for the rest of that MATLAB session, and the NEXT rz2adc run in the
% same session hit exactly that error. Confirmed 2026-07-30.
%
% Safe to call with rz2=[] (Input source wasn't 'rz2adc', so nothing was
% ever opened) -- no-ops instead of erroring, same convention
% CleanupJoystickRelay.m/SetRZ2RelayEnable.m already use for their own
% "was this even set up" guard.
if isempty(rz2) || ~isfield(rz2, 'port') || isempty(rz2.port)
    % DIAGNOSTIC (2026-08-21): this used to be a silent no-op return, making
    % "inputSource wasn't rz2adc" indistinguishable from "rz2adc was active
    % but the summary failed silently downstream." Now it says which one.
    fprintf('RZ2 link: DIAGNOSTIC -- CleanupRZ2Joystick called with rz2=%s, so nothing to report.\n', ...
        class(rz2));
    return;
end
fprintf('RZ2 link: DIAGNOSTIC -- CleanupRZ2Joystick reached with a valid rz2.port.\n');

% Link summary before the socket goes away. These counters are the answer to
% "was the joystick link actually healthy this session?", which used to be
% unanswerable from inside MATLAB: a relay that arrived faster than the frame
% loop could read it looked identical, from here, to one that was keeping up
% -- the cursor just quietly rendered older and older samples. Printed rather
% than returned so it lands in the session log next to everything else, and
% wrapped in its own try so a reporting problem can never keep the port from
% being released below.
try
    ud = rz2.port.UserData;
    if isstruct(ud) && isfield(ud, 'nSamples')
        fprintf('RZ2 link: %d samples, %d skipped (lost datagrams + relay recalibrations)\n', ...
            ud.nSamples, ud.nSkipped);
        if isfield(ud, 'nDatagrams')
            % DIAGNOSTIC (2026-08-23): nDatagrams has been tracked in
            % SetupRZ2Joystick.m/ReadRZ2Joystick.m since 2026-08-21 but was
            % never actually reported here -- added while cross-checking
            % every Computer 1/Computer 2 file against each other for
            % matching field names. isfield-guarded, same as nFlushed below,
            % so this stays harmless against an older SetupRZ2Joystick.m
            % that predates this counter.
            fprintf('RZ2 link: %d datagrams received\n', ud.nDatagrams);
        end
        if isfield(ud, 'nFlushed') && ud.nFlushed > 0
            fprintf(['RZ2 link: %d queued datagram(s)/byte(s) discarded at session start or ' ...
                'after a pause (backlog from time the task was not reading, not data loss)\n'], ud.nFlushed);
        end
        if ud.nCapped > 0
            fprintf(['RZ2 link: the per-frame drain cap was hit on %d frame(s). A short run of ' ...
                'these right after a stall is normal (the queue clears itself); a sustained ' ...
                'run means the loop was not holding frame rate.\n'], ud.nCapped);
        end
        if ud.maxBacklog > 0
            if rz2.useNewUDP
                fprintf('RZ2 link: worst backlog left after a drain: %d datagram(s)\n', ud.maxBacklog);
            else
                fprintf('RZ2 link: worst backlog left after a drain: %d byte(s)\n', ud.maxBacklog);
            end
        end
        if ud.nLegacyFmt > 0
            fprintf(['RZ2 link: NOTE -- %d sample(s) arrived in the pre-2026-08-04 un-indexed ' ...
                'format, so their trajectory timestamps are ESTIMATED, not derived from the ' ...
                'sample index. Update JoystickRelayToTask.m on Computer 1.\n'], ud.nLegacyFmt);
        end
    else
        % DIAGNOSTIC (2026-08-21): this branch used to be silent -- ud existed
        % but wasn't a struct with 'nSamples', and nothing printed at all, so
        % there was no way to tell this apart from CleanupRZ2Joystick.m never
        % having been reached in the first place. Made visible while tracking
        % down a session that printed no RZ2 summary despite inputSource
        % being confirmed 'rz2adc'.
        fprintf('RZ2 link: DIAGNOSTIC -- summary skipped. class(ud)=%s', class(ud));
        if isstruct(ud)
            fprintf(', fields={%s}', strjoin(fieldnames(ud), ','));
        end
        fprintf('\n');
    end
catch ME_rz2sum
    % DIAGNOSTIC (2026-08-21): was a bare "catch, end" -- swallowed whatever
    % broke here with zero trace. Now prints it instead.
    fprintf('RZ2 link: DIAGNOSTIC -- summary block threw: %s (%s)\n', ...
        ME_rz2sum.message, ME_rz2sum.identifier);
end

try
    if ~rz2.useNewUDP
        fclose(rz2.port);
    end
    delete(rz2.port);
catch
end
end
