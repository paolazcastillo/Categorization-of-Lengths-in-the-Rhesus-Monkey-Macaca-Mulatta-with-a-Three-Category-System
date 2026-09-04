function OffrigPlay(perLengthTrials, sessionMode, numBlocks)
% OFFRIG_PLAY  Interactive play-through of the REAL task engine, MOUSE-driven.
%
%   Shows the exact animation the animal sees and lets the operator react with
%   the mouse instead of a joystick, to test CenterOutTask end-to-end
%   without the rig hardware.
%
%   Requires Psychtoolbox (Screen, GetMouse, KbName, ...). Uses the stub
%   Rewards.m / CloseTask.m in this folder, so no reward valve / UDP is touched.
%
%   INPUT  perLengthTrials : (optional) stops once EVERY one of the 12
%                            individual bar lengths has reached this many
%                            correct trials -- not a running total, and not
%                            just a category aggregate, so no single length
%                            (e.g. the hardest, boundary-adjacent one in a
%                            category) is left under-sampled (default 10).
%                            Ignored if numBlocks is given.
%          sessionMode     : (optional) '3cat' (default), '2cat', 'alternate',
%                            or 'interleaved' -- how many categories per trial.
%          numBlocks       : (optional) if given, stops after this many
%                            48-trial blocks (1 bar length x 4 rotating
%                            positions each) instead of gating on
%                            perLengthTrials -- e.g. numBlocks=1 for a single
%                            quick pass through all 12 lengths x 4 positions.
%
%   CONTROLS while it runs:
%     - move the mouse into the centre circle and hold until the colour bar
%       appears, then move to the target whose colour matches the bar group;
%     - space = pause/resume,  ESC = quit,  r = manual (mock) reward.
%
%   NOTE: opens FULLSCREEN on the main display (this keeps mouse coordinates
%   aligned with the rendering). Use ESC to quit, then Cmd+Tab back to MATLAB.

if nargin < 1 || isempty(perLengthTrials), perLengthTrials = 10; end
if nargin < 2 || isempty(sessionMode), sessionMode = '3cat'; end
if nargin < 3, numBlocks = []; end

% --- Make the engine + stubs/helpers visible on the path ----------------
here   = fileparts(mfilename('fullpath'));   % .../offrig_mocks
engine = fileparts(here);                    % .../CenterOutTask
addpath(here);      % Rewards, CloseTask (off-rig stubs)
addpath(engine);    % CenterOutTask, CheckInCircle, CheckInTargetCenterOut, BuildTrialSequence

if ~exist('Screen', 'file')
    error('OffrigPlay:noPTB', ...
        ['Psychtoolbox not found. Install it first (psychtoolbox.org), ' ...
        'then run OffrigPlay again.']);
end

% --- Build a minimal mock of the GUI handle struct the engine touches ----
fig = figure('Name', 'offrig play (mock control GUI)', 'NumberTitle', 'off', ...
        'MenuBar', 'none', 'Position', [100 100 340 210]);
handles.dlgTrainingMain = fig;
handles.text77 = uicontrol('Parent', fig, 'Style', 'text', 'String', 'idle', ...
                        'Position', [20 170 300 24], 'HorizontalAlignment', 'left');
handles.edit91          = mkEdit(fig, 'edit91',          '0',        130);  % good trials
handles.edit92          = mkEdit(fig, 'edit92',          '0',        100);  % percent correct
handles.editTrainRepe   = mkEdit(fig, 'editTrainRepe',   '0',         70);  % trial target
handles.editReward      = mkEdit(fig, 'editReward',      '0.2',       40);  % reward time
handles.textSessionTime = mkEdit(fig, 'textSessionTime', '00:00:00',  10);  % elapsed session time
setappdata(fig, 'stop', 0);
setappdata(fig, 'running', 0);

% --- Run parameters the engine reads from orgParams ---------------------
orgParams.handles            = handles;
orgParams.Reward             = 0.20;   % reward valve time (passed to mock rewards)
orgParams.centerRad          = 120;    % centre-window diameter (px)
orgParams.centerToTargetDist = 200;    % centre-to-target distance (px)
orgParams.inputSource        = 'mouse';            % <-- drive with the mouse
orgParams.sessionMode        = sessionMode;        % '3cat'/'2cat'/'alternate'/'interleaved'
if isempty(numBlocks)
    orgParams.stopMode          = 'correctTrials';
    orgParams.maxCorrectTrials  = perLengthTrials;    % short test run (per-length quota)
    fprintf(['\n=== Off-rig play-through (MOUSE control) ===\n' ...
            '  - Move into the centre circle and hold for the colour bar.\n' ...
            '  - Then move to the target whose colour matches the bar.\n' ...
            '  - space = pause/resume,  ESC = quit,  r = manual reward.\n' ...
            '  - Stops once EACH of the 12 bar lengths has %d correct trials.\n\n'], perLengthTrials);
else
    orgParams.stopMode  = 'blocks';
    orgParams.numBlocks = numBlocks;
    fprintf(['\n=== Off-rig play-through (MOUSE control) ===\n' ...
            '  - Move into the centre circle and hold for the colour bar.\n' ...
            '  - Then move to the target whose colour matches the bar.\n' ...
            '  - space = pause/resume,  ESC = quit,  r = manual reward.\n' ...
            '  - Stops after %d block(s) of 48 trials (12 lengths x 4 positions each).\n\n'], numBlocks);
end

CenterOutTask(orgParams);
end

% ===========================================================================
function hc = mkEdit(fig, tag, str, y)
hc = uicontrol('Parent', fig, 'Style', 'edit', 'Tag', tag, 'String', str, ...
        'Units', 'pixels', 'Position', [20 y 150 24]);
end
