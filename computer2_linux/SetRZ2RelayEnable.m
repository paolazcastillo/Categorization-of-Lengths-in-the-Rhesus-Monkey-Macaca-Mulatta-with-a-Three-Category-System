function SetRZ2RelayEnable(enable, uSynapse)
% SETRZ2RELAYENABLE  Tell Computer 1's CommunicationCategTaskACTX.m to
% start (enable=true) or stop (enable=false) the analog-joystick-over-UDP
% relay (JoystickRelayToTask.m's InitJoystickRelay.m/StepJoystickRelay.m/
% CleanupJoystickRelay.m) -- so it only runs while THIS machine actually has
% Input source = 'rz2adc' selected, instead of running for Computer 1's
% entire "Run" session regardless of what Computer 2 is doing with it.
% Paola Castillo 2026-07-31
%
% Wire protocol matches Rewards.m's convention: an evaluable assignment
% string ("rz2RelayEnable=1;" or "rz2RelayEnable=0;") that
% CommunicationCategTaskACTX.m's main loop eval()s the same way it
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
fprintf(uSynapse, sprintf('rz2RelayEnable=%d;\n', double(logical(enable))));  % Agregar \n
end
