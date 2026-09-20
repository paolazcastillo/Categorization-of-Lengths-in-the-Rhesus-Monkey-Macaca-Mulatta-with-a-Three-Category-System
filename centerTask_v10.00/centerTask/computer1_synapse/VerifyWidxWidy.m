function report = VerifyWidxWidy()
% VERIFYWIDXWIDY  Confirms the widx/widy gizmoOutput fix (APICh1X/APICh2Y)
% actually works, in four independent checks, before you trust it enough
% to flip WRITE_IDX_TAG_X/Y back on in InitJoystickRelay.m:
%
%   1) EXISTS   -- 'widx'/'widy' actually appear in the live SynapseAPI
%                  parameter list (i.e. the .rcx compiled with them wired).
%   2) LIVE     -- the value CHANGES over a few seconds. A tag that exists
%                  but never changes is the exact silent-freeze failure
%                  this whole thing was built to fix in the first place --
%                  see InitJoystickRelay.m's WRITE_IDX_TAG_X/Y note.
%   3) RATE     -- how many samples/s the change implies, compared against
%                  the WRITE_FS=1017 assumption already baked into
%                  InitJoystickRelay.m (open question -- see the circuit
%                  reference doc, Section 5.4).
%   4) CROSS-CHECK -- compares widx/widy's live value against an
%                  independent measurement using the OLD diff-peak method
%                  (calibrateActiveIndex.m). If both agree, that is strong,
%                  independent confirmation the new tag is reporting the
%                  real write head and not something else.
%
% Run on Computer 1, with Synapse in Preview or Record, and preferably
% while the joystick is being moved (so there's real, non-idle variation
% to look at).

syn = SynapseAPI('localhost');
fprintf('Synapse mode: %s\n', syn.getModeStr());
if syn.getMode() < 2
    error('VerifyWidxWidy:notRunning', ...
        'Synapse must be in Preview or Record for this to mean anything.');
end

gizmos   = {'APICh1X', 'APICh2Y'};
tags     = {'widx',    'widy'};
BUF_SIZE = 100000;      % SerStore Size, see APIStreamer1Ch.rcx
ASSUMED_FS = 1017;      % WRITE_FS as currently hardcoded in InitJoystickRelay.m
N_SAMPLES  = 8;         % live-handshake readings
SAMPLE_DT  = 0.25;      % seconds between them

report = struct();

for i = 1:2
    g = gizmos{i};
    t = tags{i};
    fprintf('\n================  %s / %s  ================\n', g, t);

    % ---- 1) EXISTS ---------------------------------------------------
    names  = syn.getParameterNames(g);
    exists = any(strcmpi(names, t));
    fprintf('[1/4] Tag in parameter list: %s\n', boolStr(exists));
    report.(g).exists = exists;
    if ~exists
        fprintf(['      STOP -- ''%s'' not found on %s. The .rcx most likely did not\n' ...
            '      recompile with your change. Check the RZ2(1) icon in Synapse''s\n' ...
            '      Processing Tree for a build-error indicator before re-checking here.\n'], t, g);
        continue;
    end

    try
        info = syn.getParameterInfo(g, t);
        fprintf('      Parameter info: %s\n', safeJson(info));
    catch ME_info
        fprintf('      (getParameterInfo failed -- not fatal: %s)\n', ME_info.message);
    end

    % ---- 2) LIVE -------------------------------------------------------
    fprintf('[2/4] Reading %d samples, %.2fs apart (move the joystick now if you can)...\n', ...
        N_SAMPLES, SAMPLE_DT);
    vals  = nan(1, N_SAMPLES);
    times = nan(1, N_SAMPLES);
    for k = 1:N_SAMPLES
        vals(k)  = syn.getParameterValue(g, t);
        times(k) = GetSecs();
        pause(SAMPLE_DT);
    end
    fprintf('      Values : %s\n', mat2str(vals, 7));
    changed = any(diff(vals) ~= 0);
    fprintf('      Changes over time: %s\n', boolStr(changed));
    report.(g).vals    = vals;
    report.(g).times   = times;
    report.(g).changed = changed;
    if ~changed
        fprintf(['      STOP -- the tag exists but is FROZEN. This is the same silent-\n' ...
            '      freeze pattern as the original widx bug: a tag that resolves without\n' ...
            '      erroring but never actually updates. Re-check the wire from\n' ...
            '      SerStore.Index into the gizmoOutput macro itself, not just that the\n' ...
            '      circuit compiled.\n']);
        continue;
    end

    % ---- 3) RATE ---------------------------------------------------------
    d  = diff(vals);
    d(d < 0) = d(d < 0) + BUF_SIZE;   % unwrap a circular-buffer wraparound, if any occurred
    dt = diff(times);
    rateEst = sum(d) / sum(dt);
    pctOff  = 100 * abs(rateEst - ASSUMED_FS) / ASSUMED_FS;
    fprintf('[3/4] Empirical rate from %s: %.1f samples/s (assumed WRITE_FS = %d Hz, %.1f%% off)\n', ...
        t, rateEst, ASSUMED_FS, pctOff);
    report.(g).rateEst = rateEst;
    report.(g).pctOffAssumedFS = pctOff;
    if pctOff > 20
        fprintf(['      NOTE -- that''s a large enough gap to be worth revisiting WRITE_FS\n' ...
            '      in InitJoystickRelay.m (see the circuit reference doc, Section 5.4:\n' ...
            '      the assumed rate was never confirmed against the live buffer).\n']);
    end

    % ---- 4) CROSS-CHECK against the OLD diff-peak method ------------------
    fprintf('[4/4] Cross-checking against the old diff-peak method (calibrateActiveIndex.m)...\n');
    idxDiffPeak = calibrateActiveIndex(syn, g, BUF_SIZE, 0.15);
    idxWidx     = syn.getParameterValue(g, t);
    fwd  = mod(idxWidx - idxDiffPeak, BUF_SIZE);
    bwd  = mod(idxDiffPeak - idxWidx, BUF_SIZE);
    distSamples = min(fwd, bwd);
    fprintf('      diff-peak estimate : %d\n', idxDiffPeak);
    fprintf('      %-5s live value    : %d\n', t, idxWidx);
    fprintf('      circular distance  : %d samples (%.3f s at %.0f Hz)\n', ...
        distSamples, distSamples / ASSUMED_FS, ASSUMED_FS);
    report.(g).diffPeakIdx    = idxDiffPeak;
    report.(g).widxLiveIdx    = idxWidx;
    report.(g).crossCheckDist = distSamples;
    % A few thousand samples apart is expected -- diff-peak is a snapshot
    % from moments ago, widx is read live afterward, and real time passed
    % between the two. What matters is that they're in the same
    % neighborhood (thousands, not tens of thousands / half the buffer),
    % which is what "close" means here.
    sameNeighborhood = distSamples < (BUF_SIZE / 4);
    fprintf('      Same neighborhood as the independent diff-peak estimate: %s\n', boolStr(sameNeighborhood));
    report.(g).crossCheckOk = sameNeighborhood;
end

% ---- Summary ---------------------------------------------------------------
fprintf('\n================  SUMMARY  ================\n');
allGood = true;
for i = 1:2
    g = gizmos{i};
    ok = isfield(report, g) && isfield(report.(g), 'changed') && report.(g).changed ...
        && (~isfield(report.(g), 'crossCheckOk') || report.(g).crossCheckOk);
    fprintf('%-10s : %s\n', g, boolStr(ok, 'PASS', 'FAIL -- see detail above'));
    allGood = allGood && ok;
end

if allGood
    fprintf(['\nAll checks passed. It should now be safe to set, in InitJoystickRelay.m:\n' ...
        '    state.WRITE_IDX_TAG_X = ''widx'';\n' ...
        '    state.WRITE_IDX_TAG_Y = ''widy'';\n' ...
        'and re-test with the standalone relay loop (or DiagnoseRZ2Cursor.m) before\n' ...
        'trusting it in a real session.\n']);
else
    fprintf('\nDo NOT re-enable WRITE_IDX_TAG_X/Y yet -- see the failing check(s) above.\n');
end
end

% ===========================================================================
function s = boolStr(tf, yesStr, noStr)
if nargin < 2, yesStr = 'YES'; end
if nargin < 3, noStr  = 'NO';  end
if tf, s = yesStr; else, s = noStr; end
end

% ===========================================================================
function s = safeJson(x)
try
    s = jsonencode(x);
catch
    s = '(could not encode)';
end
end
