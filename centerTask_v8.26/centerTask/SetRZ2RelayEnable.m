function SetRZ2RelayEnable(enable, uSynapse)
% SETRZ2RELAYENABLE  Tell Computer 1's Communication_CategTask_ACTX.m to
% start (enable=true) or stop (enable=false) the analog-joystick-over-UDP
% relay (JoystickRelayToTask.m's InitJoystickRelay.m/StepJoystickRelay.m/
% CleanupJoystickRelay.m) -- so it only runs while THIS machine actually has
% Input source = 'rz2adc' selected, instead of running for Computer 1's
% entire "Run" session regardless of what Computer 2 is doing with it.
%
% Wire protocol matches Rewards.m's convention: an evaluable assignment
% string ("rz2RelayEnable=1;" or "rz2RelayEnable=0;") that
% Communication_CategTask_ACTX.m's main loop eval()s the same way it
% already does for reward/rewDuration.
%
% INPUT  enable    : true to start the relay, false to stop it
%        uSynapse  : open, fopen'd udp object connected to the Synapse
%                    computer (created by SetupSynapseUDP.m) -- silently
%                    no-ops if empty (off-rig mouse mode never opens this
%                    link at all, so there is nothing to tell).
if nargin < 2 || isempty(uSynapse)
    return;
end
try
    fprintf(uSynapse, sprintf('rz2RelayEnable=%d;\n', double(logical(enable))));  % Agregar \n
catch ME
    % Same philosophy as ConfirmRecordingLink.m / Rewards.m: a marker write
    % must never abort the session. If uSynapse was already closed by an
    % out-of-order teardown, warn and continue rather than propagate.
    warning('SetRZ2RelayEnable:writeFailed', ...
        'Could not write rz2RelayEnable=%d to Synapse link: %s', ...
        double(logical(enable)), ME.message);
end
end
