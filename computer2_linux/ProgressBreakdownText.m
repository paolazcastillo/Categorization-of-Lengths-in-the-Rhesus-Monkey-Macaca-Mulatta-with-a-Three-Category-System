function lines = ProgressBreakdownText(blockNow, blocksTotal, trialInBlock, blockSize, ...
        catNames, remainingByCat, nCat2Block, nCat3Block)
% PROGRESSBREAKDOWNTEXT  Live "what is left" breakdown for the console's Run panel.
%   Paola Castillo 2026-08-04
%
%   The console's Status line already reports the session as a whole
%   ("trial 37/480 (block 2/10) -- 143 correct left"). This is the level
%   below it: how far the CURRENT block has got, and how the correct trials
%   still owed split across the bar-length categories -- numbers that
%   otherwise only appeared in the end-of-session report (SessionReport.blocks
%   / .session), i.e. after the session, when they can no longer inform it.
%
%   Kept as a pure text builder (no graphics, no engine state) so the layout
%   can be checked without running a session: it takes numbers and returns
%   the cellstr a multi-line uicontrol 'text' displays.
%
%   INPUT
%     blockNow       : block this trial belongs to (1-based)
%     blocksTotal    : blocks this session will take (grows with requeues)
%     trialInBlock   : this trial's position inside blockNow (1-based)
%     blockSize      : trials in a full block (numLengths x 4 positions)
%     catNames       : {1 x k} category names to list, e.g. {'Short','Mid','Long'}
%     remainingByCat : [1 x k] correct trials still owed per catNames entry
%     nCat2Block     : trials scheduled as 2-category in blockNow
%     nCat3Block     : trials scheduled as 3-category in blockNow
%
%   OUTPUT
%     lines : cellstr, one entry per displayed line
%
% See also: CenterOutTask, CenterConsole, SessionReport

lines = cell(4, 1);
lines{1} = sprintf('Block %d/%d   --   trial %d/%d in this block (%d to go)', ...
    blockNow, blocksTotal, trialInBlock, blockSize, max(0, blockSize - trialInBlock));

% Per-category owed counts. "Owed" is deliberately the same quantity the
% stop condition uses, only split up: a category that has over-achieved
% cannot pay off another one's shortfall, so these always sum to the
% "N correct left" figure on the Status line.
lines{2} = 'Correct trials left, by bar-length category:';
parts = cell(1, numel(catNames));
for i = 1:numel(catNames)
    parts{i} = sprintf('%s %d', catNames{i}, remainingByCat(i));
end
lines{3} = ['    ' strjoin(parts, '    ')];

% How this block's slots were scheduled between the 2-category and
% 3-category framings -- fixed for the whole block under sessionMode
% '2cat'/'3cat'/'alternate', mixed under 'interleaved'.
lines{4} = sprintf('This block''s scheduled mix:   2-cat %d   /   3-cat %d', ...
    nCat2Block, nCat3Block);
end
