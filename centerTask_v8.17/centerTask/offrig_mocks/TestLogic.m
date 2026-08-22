function TestLogic()
% TEST_LOGIC  Off-rig checks for the hardware-independent logic of the suite.
%   Paola Castillo 2026-07-31
%
%   Runs in plain MATLAB/Octave with NO Psychtoolbox, joystick, or UDP. It
%   validates the parts of CenterOutTask that do not touch hardware:
%     1. the geometric hit-tests (CheckInCircle / CheckInTargetCenterOut),
%     2. the balanced pseudorandom trial sequence and its constraints,
%     3. the bar-group -> correct-target colour mapping,
%     4. the operator's bar-length subset (ParseBarSubset), including the
%        single-length case that makes the sequence's run constraint moot,
%     5. the colour-matching training phases (CategoriesForTrial) and the
%        1-/2-target layouts they put through DrawTrialLayout /
%        FixedTargetLayout / AssignTargets.
%
%   Usage (from this folder):  addpath(pwd); addpath('..'); TestLogic
%   (CheckInCircle, CheckInTargetCenterOut, BuildTrialSequence,
%   ParseBarSubset, CategoriesForTrial, DrawTrialLayout, FixedTargetLayout
%   and AssignTargets are real, shared production code -- they live one
%   level up, next to CenterOutTask.m, not in this off-rig-only folder.)
%   Each block prints PASS/FAIL and the function errors out on any failure.

fprintf('\n=== Off-rig logic tests ===\n');
nFail = 0;

% ---- 1. Geometric hit-tests --------------------------------------------
% Centre window: square rect around (500,400), diameter 120 -> radius 60.
xC = 500; yC = 400; r = 120;
rectC = [xC - r/2, yC - r/2, xC + r/2, yC + r/2];
nFail = nFail + check('centre: exact centre is inside', ...
    CheckInCircle(xC, yC, xC, yC, rectC(1), rectC(3)) == true);
nFail = nFail + check('centre: point at 0.9R is inside', ...
    CheckInCircle(xC + 0.9*r/2, yC, xC, yC, rectC(1), rectC(3)) == true);
nFail = nFail + check('centre: point past the edge is outside', ...
    CheckInCircle(xC + r, yC, xC, yC, rectC(1), rectC(3)) == false);

% Target disc: rect [340 540 460 660] -> centre (400,600), radius 60.
tRect = [340 540 460 660];
nFail = nFail + check('target: centre is inside', ...
    CheckInTargetCenterOut(400, 600, tRect) == true);
nFail = nFail + check('target: far point is outside', ...
    CheckInTargetCenterOut(800, 600, tRect) == false);
nFail = nFail + check('target: unplaced rect ([0 0 0 0]) is outside', ...
    CheckInTargetCenterOut(0, 0, [0 0 0 0]) == false);

% ---- 2. Trial sequence constraints -------------------------------------
numBars = 3;  seqSize = numBars * 4 * 50;   % 600 trials
[bars, pos] = BuildTrialSequence(seqSize, numBars);

nFail = nFail + check('seq: length matches request', numel(bars) == seqSize);
nFail = nFail + check('seq: bar indices in 1..numBars', ...
    all(bars >= 1 & bars <= numBars));
nFail = nFail + check('seq: directions in 1..4', all(pos >= 1 & pos <= 4));

% No more than 2 identical bar indices in a row (incl. across block boundaries).
maxRun = longestRun(bars);
nFail = nFail + check(sprintf('seq: no >2 same bar in a row (max run=%d)', maxRun), ...
    maxRun <= 2);

% No identical (bar, direction) pair twice in a row.
repeatedPair = any(bars(2:end) == bars(1:end-1) & pos(2:end) == pos(1:end-1));
nFail = nFail + check('seq: no repeated (bar,dir) pair back-to-back', ~repeatedPair);

% Balance: each (bar,dir) cell appears within +/-1 of the mean per block.
counts = accumarray([bars, pos], 1, [numBars, 4]);
nFail = nFail + check('seq: all 12 (bar,dir) cells are populated', all(counts(:) > 0));
nFail = nFail + check('seq: cells balanced within +/-2 of the mean', ...
    max(abs(counts(:) - mean(counts(:)))) <= 2);

% ---- 2b. Trial sequence with the REAL 12-length stimulus set -----------
% Mirrors production: BuildTrialSequence is called with numLengths = 12
% (CenterOutTask.m), each length mapped to one of 3 categories via
% lengthCategory = ceil((1:12)/4)  (4 lengths per category).
numLengths12   = 12;
lengthCategory12 = ceil((1:numLengths12) / 4);   % 1-4=Short,5-8=Mid,9-12=Long
seqSize12 = numLengths12 * 4 * 20;               % 960 trials
[bars12, pos12] = BuildTrialSequence(seqSize12, numLengths12);

nFail = nFail + check('seq12: length matches request', numel(bars12) == seqSize12);
nFail = nFail + check('seq12: bar indices in 1..12', ...
    all(bars12 >= 1 & bars12 <= numLengths12));
nFail = nFail + check('seq12: directions in 1..4', all(pos12 >= 1 & pos12 <= 4));

maxRun12 = longestRun(bars12);
nFail = nFail + check(sprintf('seq12: no >2 same length in a row (max run=%d)', maxRun12), ...
    maxRun12 <= 2);

repeatedPair12 = any(bars12(2:end) == bars12(1:end-1) & pos12(2:end) == pos12(1:end-1));
nFail = nFail + check('seq12: no repeated (length,dir) pair back-to-back', ~repeatedPair12);

counts12 = accumarray([bars12, pos12], 1, [numLengths12, 4]);
nFail = nFail + check('seq12: all 48 (length,dir) cells are populated', all(counts12(:) > 0));
nFail = nFail + check('seq12: cells balanced within +/-2 of the mean', ...
    max(abs(counts12(:) - mean(counts12(:)))) <= 2);

% Category-level balance: each of the 3 categories (4 lengths each) should
% get a roughly equal share of trials.
trialCat12 = lengthCategory12(bars12)';
catCounts12 = accumarray(trialCat12, 1, [3, 1]);
nFail = nFail + check('seq12: 3 categories balanced within +/-8 of the mean', ...
    max(abs(catCounts12 - mean(catCounts12))) <= 8);

% ---- 3. Bar-category -> correct-target-slot assignment -----------------
% Standalone copy of the per-trial target/colour assignment loop inside
% CenterOutTask.m (the block right after BuildTrialSequence). Keep in
% sync with the engine if that logic changes.
colorRows3 = [1 2 3];   % Short/Mid/Long -> Orange/Green/Blue
nAssign = 2000;
trueCatSeq  = colorRows3(randi(3, nAssign, 1));      % random true category per trial
correctDirSeq = randi(4, nAssign, 1);                % random balanced direction per trial
[asgDirs, asgCols, asgCorrectSlot] = assignTrialColors(trueCatSeq, correctDirSeq, colorRows3);

okPermutation = true;  okCorrectColor = true;  okCorrectDir = true;  okUniqueDirs = true;
for t = 1:nAssign
    slotCol = asgCols(t, :);   slotDir = asgDirs(t, :);
    if ~isequal(sort(slotCol), colorRows3), okPermutation = false; end
    cs = asgCorrectSlot(t);
    if slotCol(cs) ~= trueCatSeq(t), okCorrectColor = false; end
    if slotDir(cs) ~= correctDirSeq(t), okCorrectDir = false; end
    if numel(unique(slotDir)) ~= 3, okUniqueDirs = false; end
end
nFail = nFail + check('assign: target colours are a valid permutation of the category set', okPermutation);
nFail = nFail + check('assign: correct slot colour matches the true category', okCorrectColor);
nFail = nFail + check('assign: correct slot direction matches the balanced direction', okCorrectDir);
nFail = nFail + check('assign: the 3 target slots get 3 distinct directions', okUniqueDirs);

% ---- 4. Bar-length subset (ParseBarSubset) -----------------------------
[iAll, eAll]  = ParseBarSubset('', 12);
[iOne, eOne]  = ParseBarSubset('5', 12);
[iList, eLst] = ParseBarSubset('1-4,9-12', 12);
[iDup, eDup]  = ParseBarSubset(' 9 , 1 ,1 ', 12);
nFail = nFail + check('subset: empty selects every length', isempty(eAll) && isequal(iAll, 1:12));
nFail = nFail + check('subset: single index', isempty(eOne) && isequal(iOne, 5));
nFail = nFail + check('subset: ranges expand', isempty(eLst) && isequal(iList, [1 2 3 4 9 10 11 12]));
nFail = nFail + check('subset: duplicates dropped and sorted', isempty(eDup) && isequal(iDup, [1 9]));
[~, eHigh] = ParseBarSubset('13', 12);
[~, eZero] = ParseBarSubset('0', 12);
[~, eBack] = ParseBarSubset('4-2', 12);
[~, eJunk] = ParseBarSubset('2,x', 12);
[~, eProto] = ParseBarSubset('4', 3);   % prototypes3 has only 3 lengths
nFail = nFail + check('subset: out-of-range index rejected', ~isempty(eHigh));
nFail = nFail + check('subset: zero rejected', ~isempty(eZero));
nFail = nFail + check('subset: backwards range rejected', ~isempty(eBack));
nFail = nFail + check('subset: unparseable token rejected', ~isempty(eJunk));
nFail = nFail + check('subset: validated against the active stimulus set', ~isempty(eProto));

% A one-length subset makes the "no >2 identical bars in a row" rule
% unsatisfiable, so BuildTrialSequence must drop it rather than fall through
% to the greedy path and warn on every slot (see its maxConsecBarIdx guard).
lastwarn('');
[bars1, pos1] = BuildTrialSequence(4 * 25, 1);
counts1 = accumarray([bars1, pos1], 1, [1, 4]);
nFail = nFail + check('seq1: single-bar set produces no greedy-fallback warning', isempty(lastwarn()));
nFail = nFail + check('seq1: all 4 (bar,dir) cells equally used', all(counts1(:) == 25));
nFail = nFail + check('seq1: no repeated (bar,dir) pair back-to-back', ...
    ~any(bars1(2:end) == bars1(1:end-1) & pos1(2:end) == pos1(1:end-1)));

% ---- 5. Training phases (CategoriesForTrial + 1-/2-target layouts) -----
% Phase 1 shows a single target in the bar's own colour; phase 2 adds one
% foil in a different category colour. Phase 0 must reproduce the
% categorization behaviour these tests already cover above, unchanged.
lengthCat2_12 = double((1:12) > 6) + 1;   % 2-cat split, as in CenterOutTask.m
colorRows2 = [1 3];
okPhase0 = true; okPhase1 = true; okPhase2 = true;
foilsSeen = cell(1, 3);
for lenIdx = 1:12
    [cr0, tc0] = CategoriesForTrial(3, lenIdx, 0, lengthCategory12, lengthCat2_12, colorRows2, colorRows3);
    if ~isequal(cr0, colorRows3) || tc0 ~= lengthCategory12(lenIdx), okPhase0 = false; end
    [cr0b, tc0b] = CategoriesForTrial(2, lenIdx, 0, lengthCategory12, lengthCat2_12, colorRows2, colorRows3);
    if ~isequal(cr0b, colorRows2) || tc0b ~= colorRows2(lengthCat2_12(lenIdx)), okPhase0 = false; end

    [cr1, tc1] = CategoriesForTrial(1, lenIdx, 1, lengthCategory12, lengthCat2_12, colorRows2, colorRows3);
    if ~isscalar(cr1) || cr1 ~= tc1 || tc1 ~= lengthCategory12(lenIdx), okPhase1 = false; end

    for rep = 1:100
        [cr2, tc2] = CategoriesForTrial(2, lenIdx, 2, lengthCategory12, lengthCat2_12, colorRows2, colorRows3);
        if numel(cr2) ~= 2 || cr2(1) ~= tc2 || cr2(2) == tc2 || ~ismember(cr2(2), colorRows3)
            okPhase2 = false;
        end
        if tc2 ~= lengthCategory12(lenIdx), okPhase2 = false; end
        foilsSeen{tc2} = unique([foilsSeen{tc2}, cr2(2)]);
    end
end
nFail = nFail + check('phase0: categorization category assignment is unchanged', okPhase0);
nFail = nFail + check('phase1: one target, in the bar''s own category colour', okPhase1);
nFail = nFail + check('phase2: matching target + one foil of a different colour', okPhase2);
nFail = nFail + check('phase2: each category eventually draws both other colours as foils', ...
    all(cellfun(@numel, foilsSeen) == 2));

% The layout/draw helpers must cope with nc = 1 (phase 1), which never
% occurred before: DrawTrialLayout's distractor arrays go empty, and
% AssignTargets must leave slots 2 and 3 on their sentinel colour.
Targets4Dir = zeros(4, 4);
for i = 1:4, Targets4Dir(i, :) = [i i+10 i+20 i+30]; end
colorArray3Cat = [255 165 0; 0 255 0; 0 0 255];
okLayout = true; okAssign = true; okSentinel = true; okFoilColour = true;
for phase = [1 2]
    for lenIdx = 1:12
        nc = phase;
        [cr, tc] = CategoriesForTrial(nc, lenIdx, phase, lengthCategory12, lengthCat2_12, colorRows2, colorRows3);
        correctDir = randi(4);
        [slotDir, slotCol, correctSlot] = DrawTrialLayout(nc, tc, cr, correctDir);
        if numel(slotDir) ~= nc || numel(unique(slotDir)) ~= nc || ...
                slotCol(correctSlot) ~= tc || slotDir(correctSlot) ~= correctDir
            okLayout = false;
        end
        [fDir, fCol, fSlot] = FixedTargetLayout(nc, tc, cr, [1 2 3]);
        if fCol(fSlot) ~= tc || ~isequal(fDir, fCol), okLayout = false; end

        trialDirs = zeros(1, 3);  trialColorRows = zeros(1, 3);
        trialDirs(1, 1:nc) = slotDir;  trialColorRows(1, 1:nc) = slotCol;
        [tarPos, tarColor, correctTarget, trialColor, trialDir, centerCueColor, numCat] = ...
            AssignTargets(1, nc, trialDirs, trialColorRows, correctSlot, tc, colorArray3Cat, Targets4Dir);
        if numCat ~= nc || trialColor ~= tc || trialDir ~= slotDir(correctSlot) || ...
                ~isequal(tarColor{correctTarget}, colorArray3Cat(tc, :)) || ...
                ~isequal(centerCueColor, colorArray3Cat(tc, :))
            okAssign = false;
        end
        for k = nc+1:3
            if ~isequal(tarColor{k}, [-1 -1 -1]) || ~isequal(tarPos{k}, [0 0 0 0])
                okSentinel = false;
            end
        end
        if nc == 2 && isequal(tarColor{1}, tarColor{2}), okFoilColour = false; end
    end
end
nFail = nFail + check('training: 1- and 2-target layouts keep the correct slot/direction', okLayout);
nFail = nFail + check('training: correct target and centre cue wear the bar''s colour', okAssign);
nFail = nFail + check('training: unused target slots keep the sentinel colour', okSentinel);
nFail = nFail + check('training: phase-2 foil is drawn in a visibly different colour', okFoilColour);

% ---- 6. Reward accounting (Rewards return value) -----------------------
% The engines total the session's water from what Rewards() REPORTS it
% commanded, so that return value has to be right in exactly the two cases a
% naive (correct trials x reward time) total would get wrong: no UDP link,
% and the Synapse gizmo's 1-1000 ms clamp.
%
% This section must run against the PRODUCTION Rewards.m, never the stub
% next to this file. Taking offrig_mocks off the path is not enough to
% guarantee that, and used to fail here: MATLAB resolves the CURRENT FOLDER
% ahead of everything on the path, and this file's own documented usage
% ("cd offrig_mocks; addpath(pwd); addpath('..'); TestLogic") makes
% offrig_mocks the current folder -- so the stub won regardless of path
% order, and the three checks that distinguish the two (the no-link return
% value and both wire-message checks) failed against a stub that never
% sends anything and never reports zero.
%
% Switching the current folder to the engine folder is what actually
% decides it; the rmpath stays, so the stub loses on BOTH resolution rules
% no matter which folder TestLogic was started from. The check right after
% asserts the file under test rather than trusting either mechanism.
mocksDir  = fileparts(mfilename('fullpath'));
engineDir = fileparts(mocksDir);
origDir   = pwd;
rmpath(mocksDir);
cd(engineDir);
restoreMocksPath = onCleanup(@() restoreEnv(origDir, mocksDir));

nFail = nFail + check('reward: these checks run the production Rewards.m, not the stub', ...
    strcmp(which('Rewards'), fullfile(engineDir, 'Rewards.m')));

% No link -> nothing sent, so nothing may be claimed. This branch returns
% before Rewards.m touches WaitSecs, so it works with no Psychtoolbox.
w = warning('off', 'rewards:noLink');
noLinkSec = Rewards(0.15, 1, []);
warning(w);
nFail = nFail + check('reward: no Synapse link delivers (and reports) zero seconds', noLinkSec == 0);

% Delivery path. Rewards.m writes with fprintf(uSynapse, ...), which takes a
% plain file id just as happily as a udp object -- so a temp file stands in
% for Synapse and lets the wire message be read back afterwards. Skipped
% without Psychtoolbox, since this path calls WaitSecs (see this file's
% header: the rest of the suite stays PTB-free).
if exist('WaitSecs', 'file')
    tmpFile = [tempname '.txt'];
    fid = fopen(tmpFile, 'w');
    secNominal = Rewards(0.15, 1, fid);
    secTwo     = Rewards(0.15, 2, fid);
    secClamped = Rewards(1.2,  1, fid);   % over the gizmo's 1000 ms ceiling
    fclose(fid);
    wire = fileread(tmpFile);
    delete(tmpFile);
    nFail = nFail + check('reward: nominal pulse reports its own duration', ...
        abs(secNominal - 0.15) < 1e-9);
    nFail = nFail + check('reward: n pulses scale the reported total', ...
        abs(secTwo - 0.30) < 1e-9);
    nFail = nFail + check('reward: over-long pulse reports the clamped 1 s, not the 1.2 s asked for', ...
        abs(secClamped - 1.0) < 1e-9);
    nFail = nFail + check('reward: wire message carries the duration in ms', ...
        ~isempty(strfind(wire, 'reward=1;rewDuration=150;')));
    nFail = nFail + check('reward: wire message carries the CLAMPED ms, not the raw request', ...
        ~isempty(strfind(wire, 'rewDuration=1000;')) && isempty(strfind(wire, 'rewDuration=1200;')));
else
    fprintf('  SKIP  reward: delivery-path checks need Psychtoolbox (WaitSecs)\n');
end

clear restoreMocksPath;   % run the onCleanup now (path + current folder back) rather than at function exit
% NOTE: this file does NOT test offrig_mocks/Rewards.m's own return value.
% Once MATLAB has resolved and cached `Rewards` within a run, restoring the
% folder/path does not reliably redirect the name, so a check here could
% keep hitting the production file it just tested and pass for the wrong
% reason. The stub only has to mirror the clamp asserted above; run it under
% CenterConsole's "Off-rig test (mouse)" mode to see it end to end.

% SessionReport.reward must print without erroring in both the calibrated
% and uncalibrated cases, and must flag pulses that delivered nothing.
printedOk = true;
try
    evalc('SessionReport.reward(96, 14.4, 7, 0.525, 0.4)');    % calibrated -> mL line
    evalc('SessionReport.reward(96, 14.4, 7, 0.525, 0)');      % uncalibrated -> seconds only
    evalc('SessionReport.reward(0, 0, 0, 0, 0)');              % nothing delivered at all
catch
    printedOk = false;
end
nFail = nFail + check('reward: report prints for calibrated / uncalibrated / empty sessions', printedOk);
warnTxt = evalc('SessionReport.reward(10, 0, 2, 0, 0)');       % triggered but nothing delivered
nFail = nFail + check('reward: report warns when pulses fired but no valve time was delivered', ...
    ~isempty(strfind(warnTxt, 'WARNING')));
mlTxt = evalc('SessionReport.reward(100, 10, 0, 0, 0.4)');
nFail = nFail + check('reward: mL figure is valve-seconds x calibration', ...
    ~isempty(strfind(mlTxt, '4.00 mL')));

% ---- Summary -----------------------------------------------------------
fprintf('---------------------------\n');
if nFail == 0
    fprintf('ALL TESTS PASSED\n\n');
else
    error('TestLogic:failures', '%d test(s) FAILED', nFail);
end
end

% ===========================================================================
function failed = check(label, cond)
% Print PASS/FAIL for a boolean condition; return 1 on failure, 0 on pass.
if cond
    fprintf('  PASS  %s\n', label);
    failed = 0;
else
    fprintf('  FAIL  %s\n', label);
    failed = 1;
end
end

function restoreEnv(origDir, mocksDir)
% Undo the reward section's current-folder switch and rmpath, in that order
% and independently: if the original folder is gone (deleted while the test
% ran), the path still has to be put back.
try, cd(origDir); catch, end
if isempty(strfind([path pathsep], [mocksDir pathsep]))
    addpath(mocksDir);
end
end

function m = longestRun(v)
% Length of the longest run of identical consecutive values.
m = 1; run = 1;
for i = 2:numel(v)
    if v(i) == v(i-1), run = run + 1; else, run = 1; end
    if run > m, m = run; end
end
if isempty(v), m = 0; end
end

function [trialDirs, trialColorRows, trialCorrectSlot] = ...
        assignTrialColors(trueCatSeq, correctDirSeq, catRows)
% ASSIGNTRIALCOLORS  (off-rig copy) Standalone copy of the per-trial
% colour/direction assignment loop inside CenterOutTask.m (the block
% right after BuildTrialSequence, 3-category case). Keep in sync with the
% engine if that logic changes.
n  = numel(trueCatSeq);
nc = numel(catRows);
trialDirs       = zeros(n, nc);
trialColorRows  = zeros(n, nc);
trialCorrectSlot = zeros(n, 1);
for t = 1:n
    trueCat = trueCatSeq(t);
    correctDir  = correctDirSeq(t);
    otherDirs   = setdiff(1:4, correctDir);
    distractDir = otherDirs(randperm(numel(otherDirs), nc - 1));
    distractCols = catRows(catRows ~= trueCat);
    slotDir = [correctDir, distractDir];
    slotCol = [trueCat,    distractCols];
    ord = randperm(nc);
    slotDir = slotDir(ord);  slotCol = slotCol(ord);

    trialDirs(t, :)      = slotDir;
    trialColorRows(t, :) = slotCol;
    trialCorrectSlot(t)  = find(slotCol == trueCat, 1);
end
end