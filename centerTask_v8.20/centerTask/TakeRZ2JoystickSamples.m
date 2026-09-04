function samples = TakeRZ2JoystickSamples(rz2Port)
% TAKERZ2JOYSTICKSAMPLES  Pop and clear the batch of [time, vx, vy, absIdx] rows
% ReadRZ2Joystick.m has accumulated in rz2Port.UserData.batch since the
% last call. Separate from ReadRZ2Joystick.m itself so the UDP socket is
% only ever drained once per frame (inside ReadCursorPosition's call, for
% rendering) while the FULL batch it drained is still available here for
% CenterOutTask.m/CenterInTask.m to log one trajectory row per joystick
% sample, not just one row per frame -- the whole reason
% JoystickRelayToTask.m streams at up to ~7500 pkts/s instead of this
% engine polling Synapse once per frame. (That 7500 figure was an earlier,
% buggy relay rate -- the real stream is 1014 samples/s, batched N_READ per
% datagram; see InitJoystickRelay.m.)
%
% INPUT
%   rz2Port : the udpport handle, i.e. rz2.port (NOT the rz2 struct
%             itself -- callers pass rz2.port so this file has no
%             dependency on the rz2 struct's other fields).
%
% OUTPUT
%   samples : N x 4 [time, vx, vy, absIdx], oldest first. vx/vy are raw
%             normalized joystick units (not yet scaled to screen pixels --
%             see rz2.scaleX/scaleY/offsetY in ReadCursorPosition.m).
%             time is in this machine's GetSecs frame (RZ2ClockMap, see
%             ReadRZ2Joystick.m), NOT a free-running index clock.
%             absIdx is the relay's absolute sample index, or NaN for a
%             sample that arrived without one (pre-2026-08-04 relay format,
%             counted as UserData.nLegacyFmt): NaN therefore marks a row
%             whose time is ESTIMATED rather than index-derived, which is
%             the provenance flag the trajectory export carries.
%             N == 0 (empty 0x4) when nothing new arrived this frame.
samples = rz2Port.UserData.batch;
rz2Port.UserData.batch = zeros(0, 4);
end