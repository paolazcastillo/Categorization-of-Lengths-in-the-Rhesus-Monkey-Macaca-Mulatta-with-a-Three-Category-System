function uSynapse = SetupSynapseUDP(remoteHost, localHost)
% SETUPSYNAPSEUDP  Open and fopen() the UDP link to the Synapse computer
% used for reward / event markers -- see Rewards.m for the wire protocol.
% Off-rig (mouse) callers should skip calling this entirely: the host
% network and the Instrument Control Toolbox may be absent there, and no
% markers/reward are needed.
uSynapse = udp(remoteHost, 'LocalHost', localHost, ...
            'RemotePort', 8830, 'LocalPort', 8830);
uSynapse.OutputBufferSize = 100;
uSynapse.Timeout = 1;
uSynapse.DatagramTerminateMode = 'on';
fopen(uSynapse);
end