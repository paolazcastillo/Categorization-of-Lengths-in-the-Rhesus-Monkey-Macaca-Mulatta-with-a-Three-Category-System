function CleanupJoystickRelay(state)
% CLEANUPJOYSTICKRELAY  Closes the relay's UDP socket. Does NOT touch
% state.syn -- when InitJoystickRelay.m was given an existing SynapseAPI
% handle to reuse (the Communication_CategTask_ACTX.m case), that
% connection belongs to the caller, not to this relay, and closing it
% here would pull it out from under whatever else is still using it.
% Paola Castillo 2026-07-31
fprintf('Stopping joystick relay...\n');
try
    if ~state.useNewUDP
        fclose(state.udpObj);
    end
    delete(state.udpObj);
catch
end
fprintf('Joystick relay stopped.\n');
end
