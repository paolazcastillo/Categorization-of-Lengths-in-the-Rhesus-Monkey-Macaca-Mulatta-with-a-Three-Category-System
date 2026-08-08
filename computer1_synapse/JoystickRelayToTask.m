function JoystickRelayToTask()
% JOYSTICKRELAYTOTASK  Standalone entry point for the analog-joystick-
% over-UDP relay (Computer 1 -> Computer 2, port 8831). Runs its own loop
% until Ctrl+C. See InitJoystickRelay.m for the full link description and
% the N_READ/recalibration rationale (APICh1X/APICh2Y written at ~1017 Hz;
% the read cursor is deliberately paced a bit under that and periodically
% resynced instead of racing ahead of the real writer).
%
% To run the relay INSIDE another script's own loop instead; e.g.
% CommunicationCategTaskACTX.m, so one "Run" click starts both
% reward/marker handling and this relay in a single MATLAB process/loop
% instead of needing a second MATLAB window; call InitJoystickRelay.m/
% StepJoystickRelay.m/CleanupJoystickRelay.m directly rather than this
% function; that is exactly how CommunicationCategTaskACTX.m uses them.
%
% USAGE: JoystickRelayToTask()
% STOP: Ctrl+C
state = InitJoystickRelay();
cleanupObj = onCleanup(@() CleanupJoystickRelay(state));
fprintf('Press Ctrl+C to stop.\n\n');

while true
    state = StepJoystickRelay(state);
    % StepJoystickRelay is a no-op until RELAY_PERIOD elapses (see its own
    % header); this short pause just keeps that polling from busy-
    % spinning at 100% CPU while nothing else shares this loop. (When
    % embedded in CommunicationCategTaskACTX.m's loop instead, that loop
    % has its own reward/marker work to do between calls and skips this
    % pause entirely, StepJoystickRelay itself never pauses.)
    pause(0.001);
end
end
