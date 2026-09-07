function deliveredSec = Rewards(amount, n, uSynapse)
% REWARDS  Deliver `n` reward pulses of `amount` seconds each, over the UDP
%   link to the Synapse computer (Computer 1).
%
%   Wire protocol matches what computer1_synapse/Communication_CategTask_ACTX.m
%   already listens for: an evaluable string "reward=1;rewDuration=<ms>;"
%   (see that file's header comment). Its main loop does
%   `eval(tmpStr)` on whatever arrives, setting its local `reward`/
%   `rewDuration`, then pulses the TDT RewardGizmo once `rewDuration > 0`.
%   rewDuration there is a Synapse gizmo parameter (TriggerDuration accepts
%   1-1000), so `amount` (seconds) is converted to milliseconds and clamped
%   to that range here.
%
%   INPUT  amount    : reward duration in SECONDS (same units as
%                      orgParams.Reward, which is what CenterOutTask.m /
%                      CenterInTask.m pass here)
%          n         : number of reward pulses to deliver (default 1)
%          uSynapse  : open, fopen'd udp object connected to the Synapse
%                      computer (created by SetupSynapseUDP.m)
%
%   OUTPUT deliveredSec : total valve-open time actually COMMANDED, in
%          seconds. This is what the engines accumulate for the session's
%          water total, and it is deliberately not just `amount * n`:
%            * it is 0 when there is no UDP link, since nothing was sent;
%            * it reflects the 1-1000 ms clamp below, so a mis-set 2 s
%              reward is reported as the 1 s the valve really opens for
%              rather than the 2 s that was asked for.
%          Callers that don't care can ignore it; every existing call site
%          used to invoke this as a bare statement and still can.
%
%   Each pulse is followed by a short pause so Communication_CategTask_ACTX.m's
%   polling loop has time to consume one message (reset rewDuration to 0)
%   before the next one arrives -- mirroring the inter-pulse gap the
%   parallel-port version of this function (WaitSecs(0.3) between pulses)
%   already uses.
deliveredSec = 0;
if nargin < 2 || isempty(n), n = 1; end
if nargin < 3 || isempty(uSynapse)
    warning('rewards:noLink', 'No uSynapse UDP link provided; reward not sent.');
    return;
end

rewDurationMs = round(amount * 1000);
rewDurationMs = min(max(rewDurationMs, 1), 1000);   % Synapse TriggerDuration range: 1-1000
deliveredSec  = n * rewDurationMs / 1000;           % post-clamp: what the valve actually opens for

% Wait out the CLAMPED pulse (rewDurationMs), not the raw `amount`: the
% valve only ever opens for what was actually sent on the wire, so waiting
% the un-clamped request would idle the task an extra second per pulse on a
% mis-set 2 s reward -- time charged to the trial for a pulse that ended
% long before. This is the same duration deliveredSec reports.
pulseSec = rewDurationMs / 1000;
for i = 1:n
    fprintf(uSynapse, sprintf('reward=1;rewDuration=%d;\n', rewDurationMs));  % Agregar \n
    WaitSecs(pulseSec);
    WaitSecs(0.3);
end
end