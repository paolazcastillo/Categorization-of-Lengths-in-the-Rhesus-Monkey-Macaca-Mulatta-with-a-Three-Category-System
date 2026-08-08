function [bars, errMsg] = ConfigBarLengths(orgParams)
% CONFIGBARLENGTHS  The bar-length stimulus table, and everything derived
%   from it. Split out of CenterOutTask.m 2026-08-07 so the physical bar
%   sizes can be changed in ONE place, without reading through the task's
%   state machine to find them.
%
%   TO CHANGE THE BAR SIZES: edit BAR_ANGLES_DEG_VA in the "EDIT HERE"
%   block below (and BARS_PER_CATEGORY if the grouping changes with it).
%   Everything downstream is derived from that table; the reduced
%   stimulus sets, the bar subset, the pixel widths, the length of the
%   pseudorandom sequence, the per-(length,position) stop quota and the
%   end-of-session tables; so nothing else has to be touched.
%
%   The table is in DEGREES OF VISUAL ANGLE, not pixels: that is what keeps
%   a stimulus comparable across rigs and viewing distances. The conversion
%   to pixels happens at the bottom of this file, using the screen geometry
%   in orgParams (screenViewingDist_mm, screenPixelPitch); change the
%   MONITOR or the chair distance and the bar table stays valid.
%
%   Category colours are 1=Short/Orange, 2=Mid/Green, 3=Long/Blue; the cue
%   and the targets are coloured by CATEGORY, never by individual length.
%
%   INPUT
%     orgParams : the console's parameter struct. Read here:
%                 screenViewingDist_mm, screenPixelPitch, stimulusSet,
%                 barLengthSubset.
%
%   OUTPUT
%     bars   : struct, see the field-by-field list where it is assembled
%              below. CenterOutTask.m unpacks it into its own local names.
%     errMsg : '' on success, otherwise a message naming what was wrong
%              with the OPERATOR'S bar-subset selection. Returned rather
%              than thrown, the same contract ParseBarSubset.m uses, so the
%              console can paint the field red instead of crashing a
%              session; CenterOutTask.m turns a non-empty errMsg into an
%              error(). Mistakes in the TABLE itself are a different thing
% ; those are a source edit, not operator input, so they
%              error() immediately below rather than coming back here.

% =========================================================================
% EDIT HERE
% =========================================================================
% The 12 graded bar lengths, in degrees of visual angle, ASCENDING.
% Ascending order is required: categories are assigned by position in this
% list (first BARS_PER_CATEGORY entries = category 1, and so on), and the
% check further down enforces it rather than letting a mis-sorted table
% silently mislabel every trial.
BAR_ANGLES_DEG_VA = [4.00 4.10 4.70 5.00 5.10 5.70 ...
                    6.00 6.10 6.70 7.00 7.60 7.80];

% How many consecutive lengths make up one category. numel of the table
% above must be exactly this times the number of categories.
BARS_PER_CATEGORY = 4;
% =========================================================================
% END EDIT HERE; below is derivation, not configuration.
% =========================================================================

% errMsg is always assigned by the ParseBarSubset call further down; the
% validations in between throw rather than return, so there is no path out
% of here that leaves it unset.
numCategories = ColorCategoryMap.NUM_CATEGORIES;
anglesFull    = BAR_ANGLES_DEG_VA(:)';
nFull         = numel(anglesFull);

% --- Validate the table (source-edit mistakes fail loudly, and now) -------
% Without these, editing the table to a length that does not divide evenly
% leaves the last category short and every downstream count subtly wrong,
% with no error anywhere, exactly the silent failure this file exists to
% make impossible.
if nFull ~= BARS_PER_CATEGORY * numCategories
    error('ConfigBarLengths:tableSize', ...
        ['BAR_ANGLES_DEG_VA has %d lengths, but BARS_PER_CATEGORY=%d x %d categories ' ...
        'needs %d. Edit the table or BARS_PER_CATEGORY in ConfigBarLengths.m.'], ...
        nFull, BARS_PER_CATEGORY, numCategories, BARS_PER_CATEGORY * numCategories);
end
if any(diff(anglesFull) <= 0)
    error('ConfigBarLengths:notAscending', ...
        ['BAR_ANGLES_DEG_VA must be strictly ascending (categories are assigned by ' ...
        'position in the list). Got: %s'], mat2str(anglesFull));
end
if any(anglesFull <= 0)
    error('ConfigBarLengths:notPositive', ...
        'BAR_ANGLES_DEG_VA must be positive visual angles in degrees. Got: %s', ...
        mat2str(anglesFull));
end

categoryFull = ceil((1:nFull) / BARS_PER_CATEGORY);   % 1-4=Short, 5-8=Mid, 9-12=Long

% Representative VA per category (mean of its lengths). Computed from the
% FULL table regardless of stimulusSet, so it is always the same reference
% value no matter which set a session runs.
catMeanVA = arrayfun(@(c) mean(anglesFull(categoryFull == c)), 1:numCategories);

% --- Stimulus set (console "Bar set", orgParams.stimulusSet) -------------
stimulusSet = OrgGet(orgParams, 'stimulusSet', 'full12');   % 'full12' | 'prototypes3' | 'extremes3'
if strcmpi(stimulusSet, 'prototypes3')
    % One prototype length per category (its mean VA, = catMeanVA above): a
    % full pass is then 3 lengths x 4 positions = 12 trials/block instead of
    % 12 x 4 = 48.
    anglesSet    = catMeanVA;
    categorySet  = 1:numCategories;   % each length IS its own category
    % No 2-cat split exists for this set: one length per category means a
    % 2-category framing would only regroup prototypes, not test a
    % Short/Long boundary. CenterOutTask.m forces sessionMode to '3cat' for
    % this set, so category2Set is never read; filled in only because
    % CategoriesForTrial takes it as an argument.
    category2Set = ones(1, numCategories);
elseif strcmpi(stimulusSet, 'extremes3')
    % Also three lengths, one per category, but pushed as far apart as the
    % full set allows: the SHORTEST bar, the MIDPOINT of the Mid category
    % (its mean VA, the same midpoint prototypes3 uses for that category),
    % and the LONGEST bar, targets Short, Mid and Long respectively.
    %
    % Where prototypes3 asks "can the subject tell the three category means
    % apart", this asks the easier question first: the two extremes are the
    % most separable pair the stimulus table contains (4.00 vs 7.80 deg VA,
    % against 4.45 vs 7.27 for the category means), with the middle length
    % kept at the Mid category's own centre so the three stay evenly placed
    % rather than the middle one drifting towards either extreme. Useful as
    % the first rung above the training phases, and for a human session that
    % has to establish the mapping quickly before the full set.
    %
    % min/max rather than indices 1 and end so this keeps meaning "the
    % extremes" if the table above is ever edited or reordered.
    anglesSet    = [min(anglesFull), catMeanVA(2), max(anglesFull)];
    categorySet  = 1:numCategories;   % each length IS its own category
    category2Set = ones(1, numCategories);   % unused: forced to 3cat, as prototypes3
else
    anglesSet   = anglesFull;
    categorySet = categoryFull;
    % PLACEHOLDER 2-cat split: lower half Short, upper half Long (not
    % aligned to the 3-category boundaries above). Indexes into colorRows2
    % in CenterOutTask.m.
    category2Set = double((1:nFull) > ceil(nFull / 2)) + 1;
end

% --- Bar-length subset (console "Bar lengths (subset)") -------------------
% Cuts the active stimulus set down to just the lengths this session should
% run: '' / 'all' (default) keeps every length, '5' runs one, '1-4,9-12' a
% mix; see ParseBarSubset.m. Everything downstream is driven by
% numLengths, so a subset automatically shrinks the pseudorandom sequence,
% the per-(length,position) stop quota, and the end-of-session tables to
% only the selected lengths. Motivating case is CenterOutTask.m's training
% phases (drill one bar, hence one target colour, before opening the set
% up), but it applies to a normal categorization session just as well.
[subset, errMsg] = ParseBarSubset(OrgGet(orgParams, 'barLengthSubset', ''), numel(anglesSet));
if ~isempty(errMsg)
    bars = struct();   % caller checks errMsg before touching bars
    return;
end
angles    = anglesSet(subset);
category  = categorySet(subset);
category2 = category2Set(subset);

% Lengths belonging to the most-represented category, used only for
% bufferBudgetTrials (display/buffer sizing) in CenterOutTask.m, derived
% from the selection rather than assumed from the stimulus set, so a subset
% doesn't leave the buffers sized for lengths that never run.
lengthsPerCategory = max(accumarray(category(:), 1, [numCategories 1]));

% --- Visual angle -> pixels ----------------------------------------------
% Screen geometry is read here, not in CenterOutTask.m, so the VA->px
% conversion and its two inputs stay in one place and cannot drift apart
% into two copies of the same default. pixelPitch is handed back because
% CenterOutTask.m also needs it for the cm/px scaling in its kinematics
% block.
viewingDistMm = OrgGet(orgParams, 'screenViewingDist_mm', 400);
pixelPitch    = OrgGet(orgParams, 'screenPixelPitch', 0.3108);
widthsMm      = 2 * viewingDistMm * tan(deg2rad(angles / 2));
sizesPx       = round(widthsMm / pixelPitch);

% --- Assemble ------------------------------------------------------------
bars.anglesFull         = anglesFull;          % the editable table (deg VA)
bars.categoryFull       = categoryFull;        % category of each table entry
bars.barsPerCategory    = BARS_PER_CATEGORY;
bars.catMeanVA          = catMeanVA;           % mean VA per category, from the full table
bars.numCategories      = numCategories;
bars.stimulusSet        = stimulusSet;         % resolved set name
bars.anglesSet          = anglesSet;           % after stimulusSet, BEFORE the subset
bars.categorySet        = categorySet;         % ditto (CenterOutTask tests this for 1-length-per-category)
bars.category2Set       = category2Set;        % ditto, 2-cat split
bars.subset             = subset;              % indices into *Set, ascending
bars.angles             = angles;              % ACTIVE lengths (deg VA)
bars.category           = category;            % ACTIVE 3-cat labels
bars.category2          = category2;           % ACTIVE 2-cat labels
bars.lengthsPerCategory = lengthsPerCategory;
bars.sizesPx            = sizesPx;             % ACTIVE lengths in pixels
bars.numLengths         = numel(sizesPx);      % 12, 3 in either reduced set, or fewer with a subset
bars.viewingDistMm      = viewingDistMm;
bars.pixelPitch         = pixelPitch;
end