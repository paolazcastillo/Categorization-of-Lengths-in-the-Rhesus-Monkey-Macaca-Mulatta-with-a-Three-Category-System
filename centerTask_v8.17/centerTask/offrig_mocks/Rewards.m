function deliveredSec = Rewards(amount, n, uSynapse)
% REWARDS  (off-rig STUB) Pretend to deliver reward / send a marker.
%   Paola Castillo 2026-07-31
%
%   The REAL lab function opens the juice valve and sends reward/event markers
%   to Synapse (TDT) over UDP. The exact byte protocol is NOT in the repo, so
%   this stub only LOGS the call and does not touch any hardware.
%
%   NOTE: this file MUST be named Rewards.m to match the call site in
%   CenterOutTask.m and CenterInTask.m, and to match the real rig helper
%   (also called Rewards). Do NOT add offrig_mocks/ to the path on the rig.
%
%   WARNING: this is a mock for off-rig logic testing. Do NOT place it on the
%   MATLAB path when running on the rig, or no reward will be delivered.
%
%   OUTPUT deliveredSec : the valve-open time the REAL function would have
%          commanded for this call, including its 1-1000 ms clamp -- so the
%          engines' session water total is exercised off-rig instead of
%          always summing to zero. No valve exists here, so read it as
%          "what would have been delivered", not as water actually given.

if nargin < 2 || isempty(n), n = 1; end
deliveredSec = n * min(max(round(amount * 1000), 1), 1000) / 1000;   % mirrors the real Rewards.m clamp
linkState = 'no UDP object';
if nargin >= 3 && ~isempty(uSynapse)
    try
        linkState = uSynapse.Status;   % 'open' / 'closed'
    catch
        linkState = 'unknown';
    end
end
fprintf('[MOCK Rewards] amount=%.3f  n=%d  (synapse: %s)\n', amount, n, linkState);
end