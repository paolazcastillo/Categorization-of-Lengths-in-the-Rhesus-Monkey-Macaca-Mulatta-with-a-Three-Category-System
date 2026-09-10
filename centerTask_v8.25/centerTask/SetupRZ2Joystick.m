function rz2 = SetupRZ2Joystick(orgParams, remoteHost)
% SETUPRZ2JOYSTICK  Connect to the analog joystick stream that
% JoystickRelayToTask.m (running on Computer 1) pushes over UDP -- one
% independently-sampled ADC-wired joystick, read on Computer 1 via
% SynapseAPI and relayed here as "X:%.4f,Y:%.4f\n" datagrams (already
% normalized to [-1, 1] there by JOY_RANGE), instead of this machine
% polling Synapse directly over the network once per frame. That direct-
% poll approach (a getParameterValue round trip per frame) is what this
% function used to do; it capped effective joystick resolution at the
% task's own frame rate and paid a network round trip on every read.
% Computer 1's relay pre-buffers samples locally and pushes 1014 samples/s
% (RELAY_HZ * N_READ in JoystickRelayToTask.m -- 7500 was an earlier, buggy
% version's rate; see InitJoystickRelay.m's N_READ/RECALIBRATION header
% note) packed N_READ per datagram, i.e. ~169 datagrams/s on the wire, so
% this machine only needs to LISTEN -- see ReadRZ2Joystick.m (drains the
% socket, caches the newest sample) and TakeRZ2JoystickSamples.m (hands
% CenterOutTask.m/CenterInTask.m every sample drained since the last
% frame, so the trajectory log keeps the joystick's native sampling rate
% instead of one row per screen frame).
%
% INPUT
%   orgParams  : struct of run parameters (rz2UdpPort/rz2RelaySourcePort/
%                rz2ScaleX/rz2ScaleY/rz2OffsetY -- see ConfigOrgParams.m's
%                "RZ2 ANALOG JOYSTICK" section)
%   remoteHost : Computer 1's address (orgParams.remoteSynapseHost). The
%                new udpport() interface doesn't need this -- a UDP
%                listener just binds a local port -- but the legacy udp()
%                fallback below does (pre-udpport MATLAB, e.g. this rig's
%                Computer 2 on R2016b): its RemoteHost/RemotePort pair is
%                how that object filters which incoming datagrams to
%                accept.
%
% OUTPUT
%   rz2 : struct with fields .port (udpport or legacy udp handle),
%         .useNewUDP (which interface .port is, for ReadRZ2Joystick.m),
%         .scaleX, .scaleY, .offsetY -- see ReadRZ2Joystick.m/
%         ReadCursorPosition.m for how it's read.
%
% A firewall/NAT hole-punch workaround (having this machine write to
% rz2.port first, to try to open a path for Computer 1's relay traffic
% back) was tried here 2026-07-30 and reverted the same day: writing from
% this object -- previously receive-only -- broke keyboard responsiveness
% (KbCheck/KbQueueCheck for space/R/ESC all stopped working) for the rest
% of the session once it ran, confirmed on this rig. Prime suspect: the
% legacy udp() object below is opened without OutputBufferSize set (unlike
% SetupSynapseUDP.m's uSynapse, which does), and writing to it for the
% first time likely left it in a bad state that then wedged every
% subsequent per-frame READ on the same object too. Do not re-add a write
% path here without first setting OutputBufferSize AND testing in
% isolation (not live in a session) whether writes leave reads healthy.

udpPort      = OrgGet(orgParams, 'rz2UdpPort', 8831);          % JoystickRelayToTask.m's documented default
localHost    = OrgGet(orgParams, 'localMachineHost', '172.24.60.146');
relaySrcPort = OrgGet(orgParams, 'rz2RelaySourcePort', 8832);  % InitJoystickRelay.m's fixed outgoing port

% Computer 1 pushes ~45 datagram pairs/s (two per relay cycle since
% MAX_SAMPLES_PER_DGRAM went to 17 -- see InitJoystickRelay.m); this machine
% drains that queue once per task frame (see ReadRZ2Joystick.m).
%
% TRANSPORT (2026-09-10). RZ2Link.m now owns the socket and picks the best
% transport this MATLAB can offer: a non-blocking java.nio DatagramChannel
% first, then udpport(), then the legacy udp() object. The legacy object is
% what this R2016b machine used until now, and its Java helper thread hands
% datagrams to MATLAB in clumps -- 33% of 67 ms drain windows arrived empty
% on 09-Sep although the relay sends every ~23 ms. That clumping was most
% of the ~72 ms sample age measured that day. The NIO channel reads the OS
% queue directly; tested against a synthetic relay, the newest sample's age
% at the drain is half a frame (9.5 ms median at 60 fps) and nothing else.
% Which transport was actually opened is printed below and at teardown.
%
% InputBufferSize / InputDatagramPacketSize are still applied on the legacy
% fallback; on the NIO channel the OS receive buffer is set to the same
% size. See the pre-2026-09-10 history of this file for why both mattered.
try
    u = RZ2Link(localHost, udpPort, remoteHost, relaySrcPort, ...
        OrgGet(orgParams, 'rz2InputBufferSize', 4194304), ...
        OrgGet(orgParams, 'rz2InputDatagramPacketSize', 8192));
    fprintf('RZ2 link: transport = %s\n', u.describe());
    useNewUDP = ~u.isLegacy();
catch ME_udp
    error('centerTask:noRZ2UDP', ...
        ['Could not open UDP listener on port %d for the RZ2 analog joystick relay: %s\n' ...
         'Verify no other process (a stale MATLAB session, another task instance) ' ...
         'already holds that port, and that JoystickRelayToTask.m on Computer 1 is ' ...
         'configured to send to this machine on the same port.'], udpPort, ME_udp.message);
end

% .UserData carries the mutable state ReadRZ2Joystick.m/
% TakeRZ2JoystickSamples.m update in place on every call -- both udpport
% and the legacy udp object are handle objects, so this persists across
% calls without rz2 itself (a plain, non-handle struct) needing to be
% reassigned by its caller.
u.UserData = struct( ...
    'lastX', 0, 'lastY', 0, ...
    'lastDrainTime', GetSecs(), ...
    'batch', zeros(0, 4), ...   % accumulated, not-yet-logged [time, vx, vy, absIdx] rows
    ... % lastIdx is the newest index seen, kept only to count gaps across
    ... % the seam between drains (see ReadRZ2Joystick.m). The time base
    ... % itself no longer lives here: the fixed (idxAnchor, tAnchor) pair
    ... % that used to define it was replaced by rz2.clock (RZ2ClockMap),
    ... % because a pair plus a constant rate cannot absorb an error in that
    ... % rate -- it integrates it. NaN until the first indexed sample.
    'lastIdx', nan, ...
    ... % Link health, reported by CleanupRZ2Joystick.m at teardown.
    'nSamples', 0, ...        % samples handed to the trajectory
    'nSkipped', 0, ...        % gaps in the index (lost datagrams + recalibration jumps)
    'nCapped', 0, ...         % frames where the per-frame drain cap was hit
    'capConsec', 0, ...       % consecutive such frames right now (see capWarnFrames)
    'maxBacklog', 0, ...      % worst datagram backlog seen after a drain
    'nLegacyFmt', 0, ...      % samples that arrived without an index (old relay)
    'nFlushed', 0, ...        % discarded by FlushRZ2Joystick.m (backlog, not loss)
    'nDatagrams', 0);         % DIAGNOSTIC (2026-08-21): raw datagrams consumed,
                               % independent of how many samples were packed in each

rz2 = struct( ...
    'port',      u, ...
    'useNewUDP', useNewUDP, ...
    'scaleX',    OrgGet(orgParams, 'rz2ScaleX',  1), ...
    'scaleY',    OrgGet(orgParams, 'rz2ScaleY',  1), ...  % JoystickRelayToTask.m sends real JoyY (APICh2Y/Adc2)
    'offsetY',   OrgGet(orgParams, 'rz2OffsetY', 0), ...
    ... % SEED for the clock map below, and the centre of its slope clamp.
    ... % No longer the divisor that converts index to time on its own: see
    ... % RZ2ClockMap.m and the 'clock' field further down.
    ... % CORRECTED 2026-09-04, 952 -> 939.0024 Hz. 952.11 came from polling
    ... % the SerStore write index for 30 s, but session sessPX-309 measured
    ... % the RZ2 stamps falling behind GetSecs at 13.69 ms/s (r = 0.9998),
    ... % which puts the true write rate at 952/1.01369 = 939.1 Hz. That is
    ... % 24414.0625/26 = 939.0024 Hz to within 0.015%: the standard TDT base
    ... % rate through APIStreamer1Ch.rcx's own 'downsample' divider (26 on
    ... % this rig). The old value implied a base of 24755 Hz, which is not a
    ... % TDT rate. Confirm on the rig with getSamplingRates plus the live
    ... % 'downsample' value; with the clock map in place a wrong seed now
    ... % costs a warm-up, not a whole session.
    'sampleRateHz', OrgGet(orgParams, 'rz2SampleRateHz', 939.0024), ...
    ... % Ceiling on samples drained per frame -- see ReadRZ2Joystick.m.
    ... % Raised 64 -> 256 (earlier fix): a normal frame plus any post-
    ... % recalibration burst (~1014/s => ~17/frame, up to ~70 right after a
    ... % recal) is drained WHOLE each frame: the cursor then renders the
    ... % freshest sample every 60 Hz frame with no leftover-backlog lag.
    ...
    ... % RAISED AGAIN 256 -> 2048 (2026-08-22): 256 was sized for normal
    ... % traffic, not for recovering from a real burst. Confirmed on this
    ... % rig: a session logged an index gap (nSkipped) of ~97,100 samples in
    ... % one step (see the InputBufferSize note above -- same session). Even
    ... % with the bigger InputBufferSize keeping a burst that size from being
    ... % LOST, draining it at 256/frame would still take
    ... % 97100/256/60fps =~ 6.3s to fully clear, during which the cursor is
    ... % visibly stale. At 2048/frame that drops to =~ 0.8s. Cost: a frame
    ... % that actually has 2048 samples queued now spends more time in
    ... % ReadRZ2Joystick.m's parse loop before that frame can render --
    ... % un-measured here, but each line is a cheap sscanf/regexp, so this
    ... % should stay well under one frame's budget even at the new ceiling.
    ... % If frames start visibly stuttering specifically WHILE draining a
    ... % backlog (check DiagnoseRZ2Cursor.m's maxPeriod / nCapped), that
    ... % parse cost is where to look first, and this is the value to lower
    ... % again.
    'maxSamplesPerDrain', OrgGet(orgParams, 'rz2MaxSamplesPerDrain', 2048), ...
    ... % Consecutive capped frames before ReadRZ2Joystick.m warns. ~1s at
    ... % 60 fps: long enough that no self-clearing backlog reaches it, short
    ... % enough to catch a link that is genuinely falling behind. Config, so
    ... % it lives here rather than on UserData, which holds only the mutable
    ... % per-drain state.
    'capWarnFrames', OrgGet(orgParams, 'rz2CapWarnFrames', 60), ...
    ... % The index -> GetSecs map itself. A handle object, so it lives in
    ... % this plain struct and still mutates in place on every drain, the
    ... % same trick u.UserData uses above. Window length is in
    ... % observations, one per drain: 600 is ~10 s at 60 fps, long enough
    ... % that the slope is well conditioned and short enough to follow a
    ... % real change in the link. maxRateDev bounds how far the estimate
    ... % may travel from the seed, so a corrupt stretch of indices cannot
    ... % rewrite the time base wholesale -- it clamps, the residual skew
    ... % grows, and ClockSkewMonitor stops the session instead.
    'clock', RZ2ClockMap( ...
        OrgGet(orgParams, 'rz2SampleRateHz', 939.0024), ...
        OrgGet(orgParams, 'rz2ClockWindow', 600), ...
        OrgGet(orgParams, 'rz2ClockMaxRateDev', 0.01), ...
        [], ...
        OrgGet(orgParams, 'rz2ClockOffsetQuantile', 0.10), ...
        OrgGet(orgParams, 'rz2ClockMaxSlewSec', 0.002), ...
        OrgGet(orgParams, 'rz2ClockOffsetWindow', 100), ...
        OrgGet(orgParams, 'rz2ClockMinSpanSec', 30)));
end