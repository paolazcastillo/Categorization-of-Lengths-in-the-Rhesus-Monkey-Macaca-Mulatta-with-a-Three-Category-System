function ok = ConfirmRecordingLink()
% CONFIRMRECORDINGLINK  Operator confirmation that the recording chain is
% live before a session. UDP marker/reward writes do not fail on a
% missing endpoint, so the task cannot tell on its own whether the
% amplifiers / Synapse are running. The marker port is deliberately not
% probed (an arbitrary datagram could be misread as an event/reward), so
% this is an explicit checklist dialog. Default is "No" so a stray
% keypress cannot start a session with the amplifiers off.
% Paola Castillo 2026-07-31
msg = sprintf(['Confirm the recording chain BEFORE starting:\n\n' ...
    '   - Amplifiers powered ON\n' ...
    '   - Synapse running and in RECORD\n' ...
    '   - UDP link to Synapse active\n\n' ...
    'If these are OFF, trials may be logged as rewarded with NO reward ' ...
    'delivered and NO data recorded.\n\nStart the session?']);
answer = questdlg(msg, 'Recording link check', 'Yes', 'No', 'No');
ok = strcmp(answer, 'Yes');
end