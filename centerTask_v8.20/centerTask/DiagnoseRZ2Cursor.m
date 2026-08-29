function DiagnoseRZ2Cursor(varargin)
% DIAGNOSERZ2CURSOR  Minimal, cursor-only harness for isolating the rz2adc
% lag reported in this session's debugging: no targets, no trials, no
% reward -- just SetupRZ2Joystick -> ReadRZ2Joystick -> draw a dot, every
% frame, with a live diagnostic overlay and a console line printed once a
% second. Reuses the EXACT same functions and UserData counters the real
% task (CenterOutTask.m) uses -- SetupRZ2Joystick.m, FlushRZ2Joystick.m,
% ReadRZ2Joystick.m, CleanupRZ2Joystick.m are all called unmodified -- so
% what you see here is what the task sees, minus every other confound
% (targets, recompensa, la GUI de consola, etc.).
%
% BUG FIXED 2026-08-22: earlier versions of this script never told Computer 1
% to actually START the relay -- Communication_CategTask_ACTX.m's relay only
% runs after receiving a 'rz2RelayEnable=1;' UDP message (normally sent by
% CenterOutTask.m at task startup via SetRZ2RelayEnable.m). Without it, the
% GUI runs fine, Synapse can be in Preview/Record fine, and StepJoystickRelay.m
% is simply never called -- 0 datagrams, indistinguishable from a real
% problem. This build sends that enable message itself, and turns it back
% off on exit, exactly like CenterOutTask.m does.
%
% BUG FIXED 2026-08-22 (2): a window left open by an earlier/interrupted run
% (Ctrl+C, an error before cleanup ran, etc.) stayed on screen showing its
% last frame forever. Re-running then opened a SECOND window next to/over it
% -- looked exactly like "two cursors, one stuck." This build now closes any
% stale Psychtoolbox window on every startup, automatically, before opening
% its own.
%
% USAGE
%   DiagnoseRZ2Cursor()
%   DiagnoseRZ2Cursor('remoteHost', '172.24.60.152')   % default shown
%   DiagnoseRZ2Cursor('localHost', '172.24.60.146')    % default shown -- must
%                                                       % match THIS machine's
%                                                       % real IP (see SetupSynapseUDP.m)
%   DiagnoseRZ2Cursor('screenNumber', 1)               % default: max(Screen('Screens'))
%   DiagnoseRZ2Cursor('windowed', false)               % default true (900x700 window,
%                                                       % so the console stays visible too)
%   DiagnoseRZ2Cursor('logToFile', false)              % default true -- see EXPORT below
%   DiagnoseRZ2Cursor('outputDir', 'C:\data\diag')      % default: pwd (current folder)
%
% EXPORT
% Every frame (not throttled -- this is separate from the 15s rolling plot)
% is logged to an in-memory buffer and, on exit, written to BOTH a .csv
% (DiagnoseRZ2Cursor_<timestamp>.csv, for Python/Excel/whatever) and a .mat
% (same name, a MATLAB table T) in outputDir. Columns: t, frameN, vx, vy,
% preBacklog, bufPct, nDatagramsCum, nSamplesCum, samplesThisFrame,
% bytesThisFrame, nSkipped, nCapped, capConsec, maxBacklog, lagSec -- i.e.
% everything the live overlay shows, one row per frame, for the whole
% session. Written even if the session ends in an error (as long as at
% least one frame ran) -- see the teardown section.
%
% Press ESC to quit cleanly (prints the same teardown summary the real
% task prints, via CleanupRZ2Joystick.m -- unmodified).
%
% WHAT THE OVERLAY MEANS
%   preBacklog     : how much was queued and UNREAD the instant this frame
%                    started, BEFORE this frame's drain ran. This is what
%                    ReadRZ2Joystick.m is about to work through -- if it's
%                    consistently large and not shrinking, the queue is not
%                    clearing (see maxBacklog/nCapped below).
%   recv buffer occupancy : preBacklog against the socket's configured
%                    InputBufferSize ceiling (legacy udp() object only --
%                    udpport doesn't expose a fixed ceiling the same way).
%                    Climbing toward 100% means packets are about to be
%                    silently dropped by the OS/MATLAB, not just delayed.
%   nDatagrams     : raw UDP datagrams consumed since the link opened,
%                    independent of how many samples were packed into each
%                    (see InitJoystickRelay.m's MAX_SAMPLES_PER_DGRAM=40) --
%                    counted inside ReadRZ2Joystick.m itself (this build
%                    only; see the DIAGNOSTIC line added there).
%   nSamples       : total samples successfully drained since the link opened.
%   samples this frame / batch bytes cumulative : ud.batch is popped and
%                    cleared every frame via TakeRZ2JoystickSamples.m (same
%                    call BOOKKEEP makes in the real task) so this harness
%                    can run for minutes without ud.batch itself growing
%                    without bound and becoming a second, separate slowdown.
%                    The cumulative figure is bytes that have PASSED
%                    THROUGH, not bytes currently held.
%   nSkipped       : index gaps seen (dropped datagrams + relay recalibration
%                    jumps) -- see ReadRZ2Joystick.m's own header.
%   nCapped        : how many FRAMES hit the per-frame drain cap
%                    (rz2.maxSamplesPerDrain, default 256) and had to leave
%                    the rest for the next frame. A handful right after a
%                    stall is normal; a number that keeps climbing every
%                    second means the queue is growing faster than it drains.
%   capConsec      : how many of THOSE capped frames happened in a row, right
%                    now. This is the live version of what triggers
%                    ReadRZ2Joystick.m's rz2:drainCapped warning (fires at
%                    rz2.capWarnFrames, default 60 ~= 1s of continuous capping).
%   maxBacklog     : the worst preBacklog value seen all session -- the
%                    high-water mark.
%   LAG estimate   : how OLD, in seconds, the sample currently driving the
%                    cursor is, computed the same way ReadRZ2Joystick.m
%                    itself timestamps samples (see that file's TIME BASE
%                    note): tAnchor + (lastIdx-idxAnchor)/sampleRateHz, vs.
%                    GetSecs() now. This is the direct, in-seconds answer to
%                    "how far behind is what I'm looking at."
%
% A separate MATLAB figure (not the Psychtoolbox window) plots vx and vy
% over the last PLOT_WINDOW_SEC seconds, updated a few times a second --
% independent of the on-screen cursor, useful for eyeballing step changes,
% noise floor, or a channel that stops updating while the other keeps going.

p = inputParser;
p.addParameter('remoteHost', '172.24.60.152');
p.addParameter('localHost', '172.24.60.146');
p.addParameter('screenNumber', []);
p.addParameter('windowed', true);
p.addParameter('logToFile', true);
p.addParameter('outputDir', pwd);
p.parse(varargin{:});
remoteHost = p.Results.remoteHost;
localHost  = p.Results.localHost;
logToFile  = p.Results.logToFile;
outputDir  = p.Results.outputDir;

orgParams = struct();   % empty -- every rz2* setting falls through to the
                         % OrgGet() default baked into SetupRZ2Joystick.m
                         % (rz2SampleRateHz=952, rz2MaxSamplesPerDrain=2048,
                         % rz2InputBufferSize=4194304). ConfigOrgParams.m sets
                         % those three to the SAME values for the real task, so
                         % this harness sees what the task sees. If you retune
                         % one of them, change it in BOTH places or this stops
                         % being a faithful reproduction of the task's link.

KbName('UnifyKeyNames');
Screen('Preference', 'SkipSyncTests', 1);

% --- Close any stale Psychtoolbox window(s) from a previous/interrupted run -
% If a prior run (this script or anything else) never reached ForceCloseScreen
% below -- Ctrl+C, an error before the try block, etc. -- its window is still
% open, showing its last frame frozen forever. A fresh call here then opens a
% SECOND window on top of/next to it, and it looks like "two cursors, one
% stuck" (confirmed 2026-08-22: it wasn't a second cursor at all, just an old
% window). Screen('CloseAll') is safe to call even when nothing is open.
Screen('CloseAll');

screens = Screen('Screens');
if isempty(p.Results.screenNumber)
    screenNumber = max(screens);
else
    screenNumber = p.Results.screenNumber;
end

if p.Results.windowed
    winRect = [50 50 950 750];
else
    winRect = [];
end

win = [];
rz2 = [];

try
    [win, winRect] = PsychImaging('OpenWindow', screenNumber, [30 30 30], winRect);
    [xc, yc] = RectCenter(winRect);
    sw = RectWidth(winRect);
    sh = RectHeight(winRect);
    HideCursorSafe(win);

    % --- Startup cleanliness ------------------------------------------------
    % Clean up any UDP/serial objects THIS MATLAB session left open from
    % earlier manual testing (a very real risk after a long debugging
    % session like this one) -- safe and idempotent even if there is
    % nothing to clean.
    stale = instrfind;
    if ~isempty(stale)
        fprintf('Found %d leftover instrument object(s) from this MATLAB session -- closing them first.\n', ...
            numel(stale));
        try, fclose(stale); catch, end
        try, delete(stale); catch, end
    end

    fprintf('Opening RZ2 joystick link to %s...\n', remoteHost);
    try
        rz2 = SetupRZ2Joystick(orgParams, remoteHost);
    catch ME_setup
        fprintf(2, ['\nCould not open the RZ2 link (port %d): %s\n\n' ...
            'This almost always means something ELSE already has that port bound -- the real\n' ...
            'task''s GUI, or a leftover console from earlier testing, in EITHER MATLAB session on\n' ...
            'this computer (closing instrument objects above only cleans up THIS session).\n'], ...
            OrgGet(orgParams, 'rz2UdpPort', 8831), ME_setup.message);
        if isunix
            fprintf(2, 'Checking what currently holds it (read-only, nothing is being closed automatically):\n');
            [~, out] = system(sprintf('lsof -i :%d -Pn 2>/dev/null || fuser %d/udp 2>&1', ...
                OrgGet(orgParams, 'rz2UdpPort', 8831), OrgGet(orgParams, 'rz2UdpPort', 8831)));
            if isempty(strtrim(out))
                fprintf(2, '  (nothing found by lsof/fuser -- may need sudo, or it is a stale kernel-level bind)\n');
            else
                fprintf(2, '%s\n', out);
            end
        end
        rethrow(ME_setup);
    end

    fprintf('Flushing any startup backlog (see FlushRZ2Joystick.m)...\n');
    nFlushed = FlushRZ2Joystick(rz2);
    fprintf('Flushed %d %s.\n', nFlushed, ternary(rz2.useNewUDP, 'datagram(s)', 'byte(s)'));

    % --- Tell Computer 1 to actually start the relay ------------------------
    % See the header note: without this, Communication_CategTask_ACTX.m's
    % relay never turns on, no matter how correctly the receiving side (above)
    % is set up. Same wire protocol as CenterOutTask.m -- SetupSynapseUDP.m +
    % SetRZ2RelayEnable.m, unmodified.
    uSynapse = [];
    try
        fprintf('Opening marker/enable link to Computer 1 (%s) and enabling the relay...\n', remoteHost);
        uSynapse = SetupSynapseUDP(remoteHost, localHost);
        SetRZ2RelayEnable(true, uSynapse);
        fprintf('Sent rz2RelayEnable=1. If Communication_CategTask_ACTX.m is running and\n');
        fprintf('Synapse is in Preview/Record, its console should now start printing relay lines.\n');
    catch ME_enable
        fprintf(2, ['Could not open the Computer 1 marker link (port 8830): %s\n' ...
            'The relay will most likely stay off. Is categTaskCommunication actually\n' ...
            'running on Computer 1, and is this the same port SetupSynapseUDP.m uses?\n'], ...
            ME_enable.message);
    end

    fprintf('\nRunning. ESC to quit.\n\n');

    % --- Live X/Y plot, separate MATLAB figure ------------------------------
    % Rolling window, not a full session history -- kept bounded on purpose
    % (same reasoning as the ud.batch drain below: this harness is meant to
    % sit open for minutes, an ever-growing plot buffer would become its own
    % slowdown eventually). Updated on a timer, not every frame, so the plot
    % itself doesn't add meaningful overhead to the loop being measured.
    PLOT_WINDOW_SEC   = 15;
    PLOT_UPDATE_SEC   = 0.15;
    plotT = []; plotX = []; plotY = [];
    hFig = figure('Name', 'DiagnoseRZ2Cursor -- vx / vy', 'NumberTitle', 'off');
    hAx  = axes('Parent', hFig);
    hold(hAx, 'on');
    hLineX = plot(hAx, NaN, NaN, '-', 'Color', [0.85 0.20 0.20], 'DisplayName', 'vx');
    hLineY = plot(hAx, NaN, NaN, '-', 'Color', [0.20 0.45 0.85], 'DisplayName', 'vy');
    hold(hAx, 'off');
    xlabel(hAx, 'time (s)');
    ylabel(hAx, 'normalized position [-1, 1]');
    title(hAx, 'Joystick vx / vy, live');
    legend(hAx, 'Location', 'northeast');
    ylim(hAx, [-1.1 1.1]);
    grid(hAx, 'on');
    lastPlotUpdate = GetSecs();

    % --- Full-session log, for export -- SEPARATE from the 15s plot window
    % above. This is the complete record, every frame, no trimming: what you
    % actually want for post-hoc analysis of a session (does LAG trend up
    % over 5 minutes? does maxBacklog correlate with recalibration timing?
    % etc.) rather than just watching it live. Grows by doubling instead of
    % one row at a time, same reasoning as everywhere else in this script:
    % a naive row-by-row grow becomes its own slowdown over a long session.
    LOG_COLS = {'t', 'frameN', 'vx', 'vy', 'preBacklog', 'bufPct', ...
        'nDatagramsCum', 'nSamplesCum', 'samplesThisFrame', 'bytesThisFrame', ...
        'nSkipped', 'nCapped', 'capConsec', 'maxBacklog', 'lagSec'};
    logCap = 20000;
    logBuf = nan(logCap, numel(LOG_COLS));
    logN   = 0;

    t0 = GetSecs();
    lastPrint = t0;
    quitNow = false;   % set BEFORE the button below -- a click before the loop
                        % starts must not get overwritten by a later reset
    frameN = 0;
    batchBytesTotal = 0;   % cumulative memory that has PASSED THROUGH ud.batch
                            % (not memory currently held -- that's drained
                            % and cleared every frame below, on purpose)

    % --- End Session button ---------------------------------------------
    % Nested function (shares this workspace, so it can set quitNow
    % directly) rather than a normal subfunction -- a plain subfunction
    % has no access to the loop's variables. Click it any time, or ESC on
    % the Psychtoolbox window works exactly as before -- this is an
    % addition, not a replacement.
    hEndBtn = uicontrol('Parent', hFig, 'Style', 'pushbutton', ...
        'String', 'End Session', 'FontSize', 11, 'FontWeight', 'bold', ...
        'ForegroundColor', [0.6 0 0], ...
        'Units', 'normalized', 'Position', [0.80 0.93 0.18 0.06], ...
        'Callback', @endSessionCallback);
    % Closing the figure with the window's own [X] does the same thing as
    % clicking the button -- sets quitNow and lets the loop exit and tear
    % down normally, instead of destroying the figure out from under a loop
    % that's still trying to update it.
    set(hFig, 'CloseRequestFcn', @endSessionCallback);

    while ~quitNow
        frameN = frameN + 1;

        % Peek BEFORE this frame's drain -- see header note on preBacklog.
        if rz2.useNewUDP
            preBacklog = rz2.port.NumDatagramsAvailable;
        else
            preBacklog = rz2.port.BytesAvailable;
        end

        [vx, vy] = ReadRZ2Joystick(rz2);   % same call the real task makes (this build
                                            % also counts raw datagrams -- see
                                            % ReadRZ2Joystick.m's DIAGNOSTIC line)

        % Pop+clear ud.batch every frame, same as the real task's
        % TakeRZ2JoystickSamples.m call does during BOOKKEEP. Without this,
        % ud.batch grows for as long as this script runs and NOTHING ever
        % shrinks it -- for a harness meant to sit open for minutes while
        % chasing a lag, that turns into its own, separate slowdown (an
        % ever-growing array being reallocated on every ReadRZ2Joystick.m
        % call). We don't need the samples themselves here, only their count
        % and size, so they're discarded right after measuring.
        batchThisFrame  = TakeRZ2JoystickSamples(rz2.port);
        nRowsThisFrame  = size(batchThisFrame, 1);
        bytesThisFrame  = numel(batchThisFrame) * 8;   % doubles = 8 bytes each
        batchBytesTotal = batchBytesTotal + bytesThisFrame;

        ud = rz2.port.UserData;

        if ~isnan(ud.idxAnchor) && ~isnan(ud.lastIdx)
            sampleTime = ud.tAnchor + (ud.lastIdx - ud.idxAnchor) / rz2.sampleRateHz;
            lagSec = GetSecs() - sampleTime;
        else
            lagSec = NaN;   % no indexed sample drained yet
        end

        % Receive-buffer occupancy: how full the OS/MATLAB socket buffer is
        % RIGHT NOW relative to its configured ceiling. Only meaningful for
        % the legacy udp() object (InputBufferSize) -- udpport manages its
        % own buffer and doesn't expose a fixed ceiling the same way.
        if ~rz2.useNewUDP
            try
                bufCeiling = rz2.port.InputBufferSize;
                bufPct = 100 * preBacklog / bufCeiling;
            catch
                bufCeiling = NaN; bufPct = NaN;
            end
        else
            bufCeiling = NaN; bufPct = NaN;
        end

        px = xc + vx * (sw / 2);
        py = yc + vy * (sh / 2);
        px = min(max(px, winRect(1)), winRect(3));
        py = min(max(py, winRect(2)), winRect(4));

        Screen('FillRect', win, [30 30 30]);
        Screen('FillOval', win, [220 40 40], [px - 10, py - 10, px + 10, py + 10]);

        lagStr = ternary(isnan(lagSec), 'n/a (no indexed sample yet)', sprintf('%.2f s', lagSec));
        bufStr = ternary(isnan(bufPct), 'n/a (udpport)', sprintf('%d / %d bytes (%.1f%%)', preBacklog, bufCeiling, bufPct));
        lines = { ...
            sprintf('frame %d   t=%.1fs', frameN, GetSecs() - t0), ...
            sprintf('vx=%+.4f  vy=%+.4f', vx, vy), ...
            sprintf('preBacklog (%s): %d', ternary(rz2.useNewUDP, 'datagrams', 'bytes'), preBacklog), ...
            sprintf('recv buffer occupancy: %s', bufStr), ...
            sprintf('nDatagrams total: %d', ud.nDatagrams), ...
            sprintf('nSamples total: %d', ud.nSamples), ...
            sprintf('samples this frame: %d  (%d bytes)', nRowsThisFrame, bytesThisFrame), ...
            sprintf('batch bytes seen cumulative: %s', formatBytes(batchBytesTotal)), ...
            sprintf('nSkipped (index gaps): %d', ud.nSkipped), ...
            sprintf('nCapped (frames at drain cap): %d', ud.nCapped), ...
            sprintf('capConsec (capped frames IN A ROW right now): %d / %d', ud.capConsec, rz2.capWarnFrames), ...
            sprintf('maxBacklog seen this session: %d', ud.maxBacklog), ...
            sprintf('nFlushed (discarded at start/pauses): %d', ud.nFlushed), ...
            sprintf('nLegacyFmt (un-indexed samples): %d', ud.nLegacyFmt), ...
            ' ', ...
            sprintf('LAG estimate: %s', lagStr) ...
            };
        for i = 1:numel(lines)
            DrawFormattedText(win, lines{i}, 20, 20 + 24 * (i - 1), [255 255 255]);
        end
        Screen('Flip', win);

        [keyDown, ~, keyCode] = KbCheck;
        if keyDown && keyCode(KbName('ESCAPE'))
            quitNow = true;
        end

        % --- Live plot: append, trim to rolling window, redraw on a timer ---
        nowT = GetSecs() - t0;
        plotT(end + 1) = nowT; %#ok<AGROW>
        plotX(end + 1) = vx;   %#ok<AGROW>
        plotY(end + 1) = vy;   %#ok<AGROW>
        keep = plotT >= (nowT - PLOT_WINDOW_SEC);
        plotT = plotT(keep); plotX = plotX(keep); plotY = plotY(keep);

        % --- Full-session log: one row per frame, unthrottled (unlike the
        % live plot above) -- this is the data that gets exported at the end.
        logN = logN + 1;
        if logN > logCap
            logCap = logCap * 2;
            logBuf(end + 1:logCap, :) = NaN;
        end
        logBuf(logN, :) = [nowT, frameN, vx, vy, preBacklog, bufPct, ...
            ud.nDatagrams, ud.nSamples, nRowsThisFrame, bytesThisFrame, ...
            ud.nSkipped, ud.nCapped, ud.capConsec, ud.maxBacklog, lagSec];

        if GetSecs() - lastPlotUpdate >= PLOT_UPDATE_SEC && ishghandle(hFig)
            set(hLineX, 'XData', plotT, 'YData', plotX);
            set(hLineY, 'XData', plotT, 'YData', plotY);
            xlim(hAx, [max(0, nowT - PLOT_WINDOW_SEC), max(nowT, PLOT_WINDOW_SEC)]);
            drawnow limitrate;
            lastPlotUpdate = GetSecs();
        end

        if GetSecs() - lastPrint >= 1
            fprintf(['[t=%6.1fs] preBacklog=%-7d buf=%-6s nDgrams=%-8d nSamples=%-8d nSkipped=%-6d ' ...
                'nCapped=%-6d capConsec=%-4d maxBacklog=%-7d lag=%s\n'], ...
                GetSecs() - t0, preBacklog, ternary(isnan(bufPct), 'n/a', sprintf('%.0f%%', bufPct)), ...
                ud.nDatagrams, ud.nSamples, ud.nSkipped, ud.nCapped, ...
                ud.capConsec, ud.maxBacklog, lagStr);
            lastPrint = GetSecs();
        end
    end

catch ME
    fprintf('DiagnoseRZ2Cursor ERROR: %s\n', ME.message);
    if ~isempty(ME.stack)
        fprintf('  at %s (line %d)\n', ME.stack(1).name, ME.stack(1).line);
    end
end

% Same teardown order/spirit as CenterOutTask.m: turn the relay back off
% first (so Comp1 doesn't keep streaming after this window closes), then
% release the screen, then report the RZ2 link last so its summary is the
% final thing printed.
if exist('uSynapse', 'var') && ~isempty(uSynapse)
    try, SetRZ2RelayEnable(false, uSynapse); catch, end
    try, fclose(uSynapse); catch, end
end
if exist('hFig', 'var') && ishghandle(hFig)
    try, close(hFig); catch, end
end
if ~isempty(win)
    ForceCloseScreen(win);
end
if ~isempty(rz2)
    CleanupRZ2Joystick(rz2);   % unmodified -- prints nSamples/nSkipped/nCapped/
                                % maxBacklog/nFlushed summary, or the DIAGNOSTIC
                                % lines if you're using the instrumented version
                                % from earlier in this conversation.
end

% --- Export the full-session log ---------------------------------------
if logToFile && exist('logN', 'var') && logN > 0
    logBuf = logBuf(1:logN, :);   % trim the doubled-but-unused tail
    T = array2table(logBuf, 'VariableNames', LOG_COLS);
    ts = datestr(now, 'ddmmmyyyy_HHMM');
    csvPath = fullfile(outputDir, sprintf('DiagnoseRZ2Cursor_%s.csv', ts));
    matPath = fullfile(outputDir, sprintf('DiagnoseRZ2Cursor_%s.mat', ts));
    try
        writetable(T, csvPath);
        fprintf('\nSaved %d rows (full session) to:\n  %s\n', logN, csvPath);
    catch ME_save
        fprintf(2, 'Could not save CSV log: %s\n', ME_save.message);
    end
    try
        save(matPath, 'T', 'LOG_COLS');
        fprintf('  %s\n', matPath);
    catch ME_save2
        fprintf(2, 'Could not save .mat log: %s\n', ME_save2.message);
    end
elseif logToFile
    fprintf('\n(No frames were logged -- nothing to export.)\n');
end

    % ===== nested function: must live INSIDE DiagnoseRZ2Cursor, before its
    % closing 'end' below, to share this workspace and be able to set
    % quitNow directly from the button click. =====
    function endSessionCallback(~, ~)
        fprintf('\n"End Session" clicked -- stopping...\n');
        quitNow = true;
    end
end

% ===========================================================================
function out = ternary(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end

% ===========================================================================
function s = formatBytes(n)
if n >= 1e9
    s = sprintf('%.2f GB', n / 1e9);
elseif n >= 1e6
    s = sprintf('%.2f MB', n / 1e6);
elseif n >= 1e3
    s = sprintf('%.2f KB', n / 1e3);
else
    s = sprintf('%d B', n);
end
end
