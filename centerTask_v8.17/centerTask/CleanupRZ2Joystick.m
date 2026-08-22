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
% Paola Castillo 2026-07-31
%
% Safe to call with rz2=[] (Input source wasn't 'rz2adc', so nothing was
% ever opened) -- no-ops instead of erroring, same convention
% CleanupJoystickRelay.m/SetRZ2RelayEnable.m already use for their own
% "was this even set up" guard.
if isempty(rz2) || ~isfield(rz2, 'port') || isempty(rz2.port)
    return;
end

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
    end
catch
end

try
    if ~rz2.useNewUDP
        fclose(rz2.port);
    end
    delete(rz2.port);
catch
end
end
