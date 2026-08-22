function state = InitJoystickRelay(syn)
% INITJOYSTICKRELAY  Set up the analog-joystick-over-UDP relay (Computer 1
% -> Computer 2, port 8831) WITHOUT starting its own loop -- pairs with
% StepJoystickRelay.m (call once per iteration of whatever loop is
% driving it) and CleanupJoystickRelay.m. Split out from a single
% self-contained script so the relay can run either standalone (see
% JoystickRelayToTask.m) or interleaved inside another script's own loop
% (Communication_CategTask_ACTX.m's reward/marker loop), sharing that
% loop's single MATLAB process instead of needing a second MATLAB window.
% Paola Castillo 2026-07-31
%
% Reads JoyX (APICh1X.data1, RZ2(1) Adc1) and JoyY (APICh2Y.data1, RZ2(1)
% Adc2), each from its own independently-tracked circular buffer offset.
% Computer 2 side of this link: SetupRZ2Joystick.m/ReadRZ2Joystick.m/
% TakeRZ2JoystickSamples.m (centerTask/, one level up from here), selected
% in the console as Input source = 'rz2adc'. UDP_PORT below must match
% orgParams.rz2UdpPort (ConfigOrgParams.m, default 8831); REMOTE_HOST must
% point at Computer 2's IP (orgParams.localMachineHost, default
% 172.24.60.146).
%
% N_READ / RECALIBRATION (2026-07-29): APICh1X/APICh2Y.data1 are written at
% ~1017 Hz (this RZ2 circuit's real fs, confirmed on the rig). An earlier
% version of this relay advanced its read cursor at ~7500 samples/s --
% far faster than that real write rate -- so the cursor lapped the whole
% circular buffer (BUF_SIZE) roughly every 15 s and, from then on,
% silently started reading data from the PREVIOUS lap (older and older)
% instead of the joystick's real, current position. No error was raised;
% the values still looked like plausible movement. N_READ/RELAY_HZ below
% are therefore chosen so the advance rate (N_READ * RELAY_HZ) sits
% DELIBERATELY BELOW ~1017 Hz, never above -- the cursor can only fall
% BEHIND the writer (added latency) rather than lap ahead of it (stale
% data resent as if current). StepJoystickRelay.m recalibrates both
% cursors every RECAL_INTERVAL_SEC using the same difference-based
% technique as the startup calibration below (see ActiveIndexFromSnapshots.m),
% bounding worst-case lag to that interval instead of letting it grow
% without limit -- as a non-blocking state machine there, NOT by calling
% calibrateActiveIndex.m's blocking pause()-based version (see
% StepJoystickRelay.m's header for why that distinction matters for
% Communication_CategTask_ACTX.m's shared reward/marker loop).
%
% RELAY_HZ tuning (2026-07-30): with N_READ=6, RELAY_HZ=150 only advances
% at 900 Hz -- a 117 Hz deficit against the ~1017 Hz writer that visibly
% built up as a growing cursor-position lag (up to ~RECAL_INTERVAL_SEC's
% worth, ~0.57 s) before each recalibration snapped it back. RELAY_HZ=169
% (with the same N_READ=6) advances at 1014 Hz instead -- a ~3 Hz deficit,
% ~40x smaller -- while staying safely below the ~1017 Hz writer (no
% lapping risk). Re-tune this pair together if the rig's measured write
% fs ever changes: keep N_READ * RELAY_HZ a few Hz under it, not above.
%
% WIRE FORMAT (changed 2026-08-04): ONE datagram per relay cycle carrying
% all N_READ samples, each as a line
%     N:<absIdx>,X:<x>,Y:<y>\n
% replacing the previous one-datagram-per-SAMPLE, "X:%.4f,Y:%.4f\n" format.
% Two reasons, both measured on Computer 2's side of the link:
%
%   * COST. The old format put 1014 datagrams/s on the wire, and Computer 2
%     drains that queue once per task frame, inside the Psychtoolbox loop.
%     Benchmarked at ~264 us per sample to drain+parse one datagram each
%     (~4.5 ms of every 16.7 ms frame) versus ~45 us batched -- a 5.9x
%     saving. The old shape had no margin: at 1014 pkts/s the drain has
%     0.99 ms per packet before it stops keeping up, and once it stops
%     keeping up the backlog grows without bound and Computer 2's cursor
%     renders older and older samples. Six samples per datagram is ~180
%     bytes, far under any MTU, so this costs nothing on the network.
%
%   * TIME BASE. absIdx is a MONOTONIC count of RZ2 samples consumed since
%     this relay started -- buffer positions, not packets -- so consecutive
%     indices are exactly 1/fs apart at the ADC's real rate no matter when
%     the datagram carrying them is drained. Computer 2 previously had to
%     GUESS each sample's time by spreading a drained batch evenly between
%     drains (see ReadRZ2Joystick.m's old timestamp caveat), which is
%     fiction the moment a backlog exists: samples captured seconds ago got
%     stamped as if they had just arrived, and those timestamps are what the
%     trajectory export and TrialKinematics.m's velocities are computed
%     from. The index also makes losses VISIBLE -- a gap in absIdx is a
%     dropped datagram or a recalibration jump, where before both were
%     silently invisible.
%
% absIdx is advanced by N_READ per cycle AND by the size of the cursor jump
% at each recalibration (see StepJoystickRelay.m), so it keeps counting real
% RZ2 samples rather than just samples this relay happened to send -- that
% is what lets Computer 2 treat index differences as true elapsed time.
%
% Y AXIS assumes X and Y share the same JOY_RANGE and native sample rate
% (same RZ2 circuit, different ADC channel) -- verify this if the two
% axes ever behave differently.
%
% INPUT
%   syn : (optional) an already-open SynapseAPI('localhost') handle to
%         reuse (e.g. Communication_CategTask_ACTX.m's own `syn`) instead
%         of opening a second, redundant connection. Opens and mode-
%         checks its own when omitted (standalone use).
%
% OUTPUT
%   state : struct consumed by StepJoystickRelay.m/CleanupJoystickRelay.m
%           -- treat its fields as private to those two files.
%
% REQUIREMENTS:
%   - Synapse in Preview or Record
%   - Gizmo APICh1X under RZ2(1), input Adc1 (X)
%   - Gizmo APICh2Y under RZ2(1), input Adc2 (Y)
%   - Computer 2 listening on port 8831
if nargin < 1 || isempty(syn)
    addpath('C:\TDT\Synapse\SynapseAPI\Matlab');
    fprintf('Connecting to Synapse...\n');
    syn = SynapseAPI('localhost');
    if syn.getMode() < 2
        error('centerTask:noSynapseMode', ...
            'Synapse must be in Preview (2) or Record (3). Current mode: %d', syn.getMode());
    end
end
state.syn = syn;

% --- Config ---
state.REMOTE_HOST = '172.24.60.146';  % Computer 2 IP
state.UDP_PORT     = 8831;            % separate from the task's own link (8830)
% Fixed source port for our OUTGOING socket -- must match
% orgParams.rz2RelaySourcePort in ConfigOrgParams.m (Computer 2). Binding a
% fixed port here (instead of an OS-assigned ephemeral one) lets Computer
% 2's legacy udp()-object fallback (pre-udpport MATLAB, e.g. R2016b) filter
% incoming datagrams by RemoteHost+RemotePort and actually match us.
state.RELAY_LOCAL_PORT = 8832;
state.RELAY_HZ     = 169;
state.RELAY_PERIOD = 1 / state.RELAY_HZ;
state.JOY_RANGE    = 4.6;             % joystick's max range (V), same for X and Y
state.BUF_SIZE     = 100000;          % SerStore size in APICh1X/APICh2Y
% N_READ=6 -> 6*169=1014 samples/s advance, deliberately BELOW the real
% ~1017 Hz (see header note above) -- never gets ahead of the writer, but
% only ~3 Hz behind it (vs. the old 150 Hz's 117 Hz deficit).
state.N_READ              = 6;
% TIME-BASED read pacing (2026-08). The read cursor is advanced by
% READ_FS * (wall-clock since the last read), NOT by a fixed N_READ per cycle.
% The fixed-N_READ advance only kept pace when the driving loop actually hit
% RELAY_HZ; Communication_CategTask_ACTX.m's shared reward/marker loop
% routinely runs slower, so the cursor advanced slower than the ~1017 Hz
% writer and fell behind proportionally to how slow the loop was -- the main,
% loop-rate-dependent source of the rz2adc lag. Pacing by elapsed time makes
% the cursor track the writer regardless of loop speed: a slow cycle simply
% reads more samples to catch up. READ_FS is held just BELOW the real write
% rate (same 1014 vs ~1017 philosophy) so the cursor can only fall a little
% behind, never lap AHEAD onto stale/unwritten data; the small residual drift
% is what the windowed recalibration corrects.
state.READ_FS             = state.N_READ * state.RELAY_HZ;   % 1014 samples/s target read rate
% Ceiling on samples read in one cycle, so a long stall (a pause, a slow
% frame) cannot turn into an unbounded getParameterValues read; the surplus
% is caught up over the following cycles.
state.MAX_READ_PER_CYCLE  = 4096;
% 10s, was 60s (2026-08-04). This interval IS the cursor-lag ceiling: the
% read cursor advances 1014/s against a ~1017 Hz writer, so it falls behind
% by ~3 samples/s and a recalibration snaps it back. At 60s that ceiling was
% ~180 samples (~0.18 s) of cursor lag right before each recalibration --
% perceptible on a reaching task; at 10s it is ~30 samples (~0.03 s).
%
% This costs nothing in DATA: the samples skipped by a recalibration jump are
% the drift accumulated since the last one, so the skip RATE is ~3 samples/s
% no matter what this interval is -- shortening it makes each gap smaller and
% more frequent, not more total. What it does cost is 4 full-buffer
% getParameterValues reads (2 channels x 2 snapshots, BUF_SIZE each) per
% interval instead of per minute, on Computer 1's SynapseAPI. That cost is
% now MEASURED rather than assumed: StepJoystickRelay.m times each
% recalibration and prints it in the relay's log line, and warns if one
% starts eating real relay time. Raise this back toward 60 if that number
% turns out to be large on the rig's Synapse.
%
% (This used to also bound how often a ~2*CALIBRATION_WAIT_SEC stall hit
% Communication_CategTask_ACTX.m's reward loop -- that stall is gone now
% that StepJoystickRelay.m's periodic recalibration is non-blocking, see
% that file's header, so this only trades lag ceiling vs. API load.)
%
% A/B test 2026-07-30: bumped this to 3600 (effectively disabling periodic
% recalibration) to test whether ActiveIndexFromSnapshots.m's diff-peak
% technique was landing on the wrong buffer index and freezing the cursor
% on stale data until the next recalibration -- suspected because it was
% tuned before the downsample/enab_buff SerStore write-gating was
% discovered. RULED OUT: the same "frozen ~60s, jumps, frozen again"
% pattern persisted even with recalibration disabled, so the cause is
% elsewhere (not this file).
state.RECAL_INTERVAL_SEC  = 10;    % how often StepJoystickRelay.m re-syncs both cursors (only when RECAL_ENABLED)
% RECAL_ENABLED re-enables the periodic recalibration, now WINDOWED
% (2026-08). The earlier full-buffer version read the whole BUF_SIZE=100000
% SerStore four times per interval (2 channels x 2 snapshots), ~2.2 s each,
% so ~8.8 s of a single-threaded loop frozen every interval -- the dominant
% cursor-lag/freeze source, which is why it was briefly disabled. But
% disabling it removed the ONLY thing that re-syncs the read cursor: paced at
% N_READ*RELAY_HZ = 1014/s against the ~1017 Hz writer, the cursor falls
% ~3 samples/s behind by construction and, with no recalibration, that lag
% grows unbounded over a session (added latency that never resets). The fix
% is to keep the re-sync but make it cheap: StepJoystickRelay.m now reads only
% a RECAL_WINDOW-sample slice around the PREDICTED head instead of the whole
% buffer, so recalibration costs a small fraction of the old full-buffer read
% and no longer freezes the loop. It can only fall BEHIND, never lap AHEAD
% onto stale data (the advance rate is held below WRITE_FS). If the SerStore
% write-gating still makes the diff-peak reject (see the rejection warning in
% StepJoystickRelay.m), this degrades to the disabled behaviour -- no re-sync
% -- but without the freeze, so it is never worse than off.
state.RECAL_ENABLED       = true;
% Samples read per snapshot, centred on the predicted head. Must comfortably
% exceed the worst tolerated head error (RECAL_TOL_FLOOR = 512) plus the
% ~WRITE_FS*CALIBRATION_WAIT_SEC samples written between the two snapshots and
% ActiveIndexFromSnapshots.m's 100-sample smoothing window; 6000 (+/-3000
% around the prediction) covers all three with wide margin while reading ~17x
% less than the full 100000 buffer. Raise it if recalibrations start being
% rejected with the head landing just outside the window; lower it to make
% each recalibration cheaper still.
state.RECAL_WINDOW        = 6000;
% The writer's real rate, used to predict how far the cursor should have
% drifted since the last recalibration -- which is what makes the sanity
% check on the new index below possible. Same ~1017 Hz the N_READ/RELAY_HZ
% pair is held under.
state.WRITE_FS = 1017;
% How far a recalibration's proposed write-head index may sit from where the
% head MUST be by now before StepJoystickRelay.m refuses it: a fraction of
% the samples written since the last accepted recalibration, with an
% absolute floor under it.
%
% THIS GUARD IS WHAT MAKES A SHORT INTERVAL SAFE. ActiveIndexFromSnapshots.m
% locates the write head by smoothing the snapshot difference with a
% 100-sample window and taking its peak, so the answer is only good to
% roughly that many samples. At a 60s interval the correction (~180 samples)
% was comfortably larger than that noise; at 10s it is ~30 samples --
% SMALLER than the measurement's own resolution. An unchecked recalibration
% could then move the cursor FORWARD PAST the write head, which is the one
% failure this whole design exists to avoid: reading a buffer region the
% writer has not reached yet means re-sending the PREVIOUS lap's data as if
% it were current, silently and plausibly (see the N_READ/RECALIBRATION note
% at the top of this file).
%
% The test is against the predicted HEAD, deliberately not against the size
% of the cursor jump. A jump-size budget was tried first and deadlocks: the
% cursor's gap to the head also contains whatever the startup calibration
% left behind and every previously-rejected correction, so a correct large
% correction gets refused and the gap it would have closed then makes every
% later attempt look wrong too. The head has no such memory -- it was at
% lastHeadIdx at tHeadRef and moves at WRITE_FS, full stop -- so predicting
% it is both simpler and immune to how far behind the cursor happens to be.
% It is also immune to the driving loop missing RELAY_HZ, which
% Communication_CategTask_ACTX.m's shared loop routinely does.
%
% FLOOR = 512 covers the peak estimate's own noise (~100-sample smoothing
% window plus the ~150 samples written between the two snapshots) with
% margin. FRAC = 0.02 lets the tolerance grow with the interval, absorbing
% the error from WRITE_FS not being exactly right: at 10s and 1017 Hz that
% is ~200 samples, i.e. it tolerates the true fs being off by 2%.
state.RECAL_TOL_FLOOR = 512;    % samples
state.RECAL_TOL_FRAC  = 0.02;   % of the samples written since the last accepted recalibration
% Window for the difference-based calibration (startup and periodic
% alike, see ActiveIndexFromSnapshots.m). Lower = shorter window between
% the two snapshots, but fewer freshly-written samples for its
% peak-detection to work with -- at the real ~1017 Hz, 0.15s is ~153
% samples, ~1.5x ActiveIndexFromSnapshots.m's 100-sample smoothing window
% (a comfortable margin). Going much below ~0.1s (~100 samples, right at
% the smoothing window's own width) risks a
% noisy, unreliable peak -- shrink that smoothing window too if lower is needed.
state.CALIBRATION_WAIT_SEC = 0.15;

% --- Calibration: find each channel's active buffer index ---
fprintf('Calibrating buffer indices (waiting ~%.2gs)...\n', 2 * state.CALIBRATION_WAIT_SEC);
state.curIdxX = calibrateActiveIndex(syn, 'APICh1X', state.BUF_SIZE, state.CALIBRATION_WAIT_SEC);
state.curIdxY = calibrateActiveIndex(syn, 'APICh2Y', state.BUF_SIZE, state.CALIBRATION_WAIT_SEC);
fprintf('Initial index -- X: %d  Y: %d\n', state.curIdxX, state.curIdxY);
% Anchor for the write-head prediction the periodic recalibration is checked
% against (see StepJoystickRelay.m): the head was here, now. Only an ACCEPTED
% recalibration moves this anchor afterwards.
state.lastHeadIdx = state.curIdxX;
state.tHeadRef    = tic;

% --- OPTIONAL: write-index mode (recommended once the gizmo exposes it) ----
% If the APIStreamer1Ch gizmo exposes the SerStore write head as its own
% API-readable scalar tag (expose ID_widx with a read-mode gizmoControl in
% the RCX, see notes), set WRITE_IDX_TAG to that tag's API name (the part
% after the ID_ prefix, e.g. 'widx'). StepJoystickRelay.m then reads the head
% directly each cycle and drains exactly the samples since its last read,
% which ELIMINATES the diff-peak recalibration (ActiveIndexFromSnapshots),
% its tolerance guards, and the time-based pacing -- the read cursor can no
% longer drift, so nothing needs correcting. Verify the tag first with
% ProbeJoystickBuffers (it must appear AND its handshake DELTA must grow).
% Empty '' (default) keeps the legacy diff-peak/time-paced path, so behaviour
% is unchanged until the tag exists and this is set.
% Enabled: X reads its head from tag 'widx' on APICh1X, Y from 'widy' on
% APICh2Y. If you exposed a SINGLE tag name on both gizmos, set both fields to
% that same name. Set either to '' to force the legacy diff-peak/time-paced
% path. Safety: the reader degrades to legacy pacing automatically (NOT a
% freeze) on any cycle a tag cannot be read, so a wrong/missing tag never
% stalls the cursor -- it just logs a one-time warning.
state.WRITE_IDX_TAG_X = 'widx';
state.WRITE_IDX_TAG_Y = 'widy';
state.widxInited      = false;   % true once curIdx is anchored to the live head
state.widxNew         = 0;       % samples waiting per cycle (relay-side backlog), for the log
state.widxFellBack    = false;   % warn-once flag if a tag read fails and we use legacy pacing

% --- UDP init ---
fprintf('Opening UDP to %s:%d...\n', state.REMOTE_HOST, state.UDP_PORT);
try
    state.udpObj    = udpport('byte', 'LocalPort', state.RELAY_LOCAL_PORT);
    state.useNewUDP = true;
catch
    % OutputBufferSize raised well above one datagram's worth: the legacy
    % udp() default (512 bytes) is what threw "number of bytes written must
    % be <= OutputBufferSize-BytesToOutput" once time-based pacing let a
    % cycle read more than a handful of samples. StepJoystickRelay.m also
    % chunks sends to stay under one MTU, so this is just headroom.
    state.udpObj    = udp(state.REMOTE_HOST, state.UDP_PORT, 'LocalPort', state.RELAY_LOCAL_PORT, ...
        'OutputBufferSize', 65536);
    fopen(state.udpObj);
    state.useNewUDP = false;
end
% Max samples packed into a single UDP datagram. Time-based pacing can read
% many samples in one cycle (a slow cycle catches up), so the send loop below
% splits them across several datagrams rather than one oversized one; 40
% samples is ~1.4 KB, comfortably under a 1500-byte MTU and the buffer above.
% Computer 2 already handles many samples per datagram and many datagrams per
% frame (ReadRZ2Joystick.m).
state.MAX_SAMPLES_PER_DGRAM = 40;
if state.useNewUDP
    fprintf('UDP OK (udpport interface, source port %d)\n', state.RELAY_LOCAL_PORT);
else
    fprintf('UDP OK (legacy udp() interface, source port %d)\n', state.RELAY_LOCAL_PORT);
end

% --- Running counters/last-values for StepJoystickRelay.m's log line ---
state.sendErrorWarned = false;   % StepJoystickRelay.m warns once, not once per packet
state.xRaw = 0; state.xNorm = 0;
state.yRaw = 0; state.yNorm = 0;
state.nPkts = 0;      % RZ2 samples sent (not datagrams -- see nDatagrams)
state.nDatagrams = 0; % datagrams put on the wire; nPkts/nDatagrams == N_READ when healthy
% Monotonic count of RZ2 samples consumed since startup, stamped into every
% sample line so Computer 2 gets a real time base instead of an estimate
% (see the WIRE FORMAT note above). Starts at 0: it is an ORIGIN for
% differences, not an absolute position in the SerStore buffer.
state.absIdx = 0;
state.tLoopRef  = tic;
state.tReadRef  = tic;   % wall-clock of the last read, for time-based pacing
state.tRecalRef = tic;
state.tLogRef   = tic;

% --- Non-blocking periodic recalibration state (see StepJoystickRelay.m) ---
% calibPending marks that the FIRST of the two calibration snapshots has
% been taken and we're waiting (across separate calls, not a pause()) for
% CALIBRATION_WAIT_SEC to elapse before taking the second one.
state.calibPending  = false;
state.calibDataX1   = [];
state.calibDataY1   = [];
state.calibWinStart = 0;     % circular offset of the windowed snapshot, fixed at phase 1 and reused at phase 2
state.calibStartRef = tic;   % overwritten once a recalibration actually starts
% Recalibration accounting, printed in the log line below: how many ran, how
% many were rejected by the jump guard, and what the last one cost in wall
% time. nRecalRejected climbing steadily means the diff-peak is not finding
% the write head -- the cursor is then drifting unchecked, which is worth
% seeing rather than inferring from a sluggish cursor.
state.nRecal          = 0;
state.nRecalRejected  = 0;
state.lastErrX        = 0;   % how far the last proposed head index sat from the prediction
state.lastErrY        = 0;
state.lastTol         = 0;
state.recalConsecBad  = 0;
state.recalMs         = 0;
state.recalSlowWarned = false;

if state.RECAL_ENABLED
    recalStr = sprintf('recalibrating every %g s (windowed, %d samples)', ...
        state.RECAL_INTERVAL_SEC, state.RECAL_WINDOW);
else
    recalStr = 'periodic recalibration DISABLED (startup calibration only)';
end
fprintf('\nJoystick relay ready: %d Hz, %d samples/channel/cycle (~%d samples/s/channel, %s).\n', ...
    state.RELAY_HZ, state.N_READ, state.RELAY_HZ * state.N_READ, recalStr);
fprintf('%-8s %-8s %-11s %-9s %-11s %-11s %-11s %-11s\n', ...
    'Samples', 'Dgrams', 'Recal_ok', 'Recal_ms', 'JoyX_raw', 'JoyX_norm', 'JoyY_raw', 'JoyY_norm');
end
