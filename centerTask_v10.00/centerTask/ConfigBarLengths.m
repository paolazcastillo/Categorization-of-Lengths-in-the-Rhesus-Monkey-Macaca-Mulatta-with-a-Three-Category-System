function [bars, barSubsetErr] = ConfigBarLengths(orgParams)
% CONFIGBARLENGTHS  Stimulus-set / bar-length configuration for CenterOutTask.
%
%   Single source of truth for the physical bar sizes and the stimulus-set
%   selection. Was inline in CenterOutTask.m; extracted here so the bar
%   table, the reduced 3-length sets and the operator's bar subset can be
%   edited in one place. EDIT THIS FILE to change the physical bar sizes.
%
%   Category colours: 1=Short/Orange, 2=Mid/Green, 3=Long/Blue (the cue and
%   targets are coloured by CATEGORY). 4 lengths per category in ascending
%   order for the full set.
%
%   INPUT
%     orgParams : session parameter struct. Reads (via OrgGet, with the
%                 defaults shown):
%                   screenViewingDist_mm (400)
%                   screenPixelPitch     (0.3108)
%                   stimulusSet          ('full12' | 'prototypes3' |
%                                         'prototypes2' | 'extremes3')
%                   barLengthSubset      ('' / 'all' | '5' | '1-4,9-12' ...)
%
%   OUTPUT
%     bars : struct with the fields CenterOutTask.m unpacks:
%              numCategories       ColorCategoryMap.NUM_CATEGORIES
%              stimulusSet         resolved set name actually used
%              categorySet         per-length category of the ACTIVE set,
%                                  pre-subset (tested for one-length-per-cat)
%              angles              selected lengths' visual angle (deg VA)
%              category            selected lengths' 3-cat category
%              category2           selected lengths' placeholder 2-cat split
%              lengthsPerCategory  max lengths in any one category, post-subset
%              sizesPx             selected bar sizes in pixels
%              numLengths          numel(sizesPx)
%              pixelPitch          mm/px (also used for cm/px in kinematics)
%              subset              selected indices into the active set
%              anglesSet           the ACTIVE set's angles, pre-subset
%     barSubsetErr : '' on success, otherwise ParseBarSubset's message.
%                    Returned rather than thrown so the caller can decide how
%                    to surface it (CenterOutTask.m turns it into error();
%                    CenterConsole.m can paint the field red instead).

barSubsetErr = '';

viewing_dist_mm = OrgGet(orgParams, 'screenViewingDist_mm', 400);
pixel_pitch     = OrgGet(orgParams, 'screenPixelPitch', 0.3108);
target_angles_full  = [4.00 4.10 4.70 5.00 5.10 5.70 ...
                    6.00 6.10 6.70 7.00 7.60 7.80];   % deg VA
lengthCategory_full = ceil((1:12) / 4);             % 1-4=Short, 5-8=Mid, 9-12=Long
numCategories   = ColorCategoryMap.NUM_CATEGORIES;

% Representative VA per category -- the MEDIAN of its lengths, which is what
% the two reduced stimulus sets below are built from. Computed from the full
% 12-length set regardless of stimulusSet, so it is always the same reference
% value whichever set is running. Median (not mean) because the four lengths
% in a category are not evenly spaced; with 4 lengths per category the median
% is the midpoint (mean of the two central values), so each category is
% represented by its own middle rather than by its skew.
%
% POOLING WARNING. The median build CHANGES the stimuli of both reduced sets,
% so sessions recorded before it are not directly comparable: prototypes3 ran
% 4.45/5.725/7.275 deg VA and now runs 4.40/5.85/7.30, and extremes3's middle
% bar moved 5.725 -> 5.85. full12 is unaffected. Check the session date (or
% BarSizeVA_deg in trial_data_*.csv, which records the value actually shown)
% before pooling reduced-set sessions across the change.
catMedianVA = arrayfun(@(c) median(target_angles_full(lengthCategory_full == c)), 1:numCategories);

stimulusSet = OrgGet(orgParams, 'stimulusSet', 'full12');   % 'full12' | 'prototypes3' | 'extremes3'
if strcmpi(stimulusSet, 'prototypes3')
    % One prototype length per category (its median VA): a full pass is then
    % 3 lengths x 4 positions = 12 trials/block instead of 12 x 4 = 48.
    target_angles_set  = catMedianVA;
    lengthCategory_set = 1:numCategories;   % each length IS its own category
    % No 2-cat split exists for this set; sessionMode is forced to '3cat'
    % downstream so lengthCat2 is never read, filled only because
    % CategoriesForTrial takes it as an argument.
    lengthCat2_set     = ones(1, numCategories);
elseif strcmpi(stimulusSet, 'prototypes2')
    % Two-category prototype set: the median (midpoint) visual angle of the
    % Short and Long categories only, Mid dropped. A full pass is 2 lengths x
    % 4 positions = 8 trials/block. Built to run in sessionMode '2cat'
    % (CenterOutTask.m forces it there): the two on-screen targets are Short
    % and Long, and the correct one is Short for the short bar, Long for the
    % long bar. Uses the SAME category medians as prototypes3, so its two bars
    % coincide with prototypes3's Short and Long bars (the POOLING WARNING
    % above applies equally here).
    target_angles_set  = [catMedianVA(1), catMedianVA(numCategories)];
    lengthCategory_set = [1, numCategories];   % 3-cat colour labels: Short, Long
    % 2-cat scheme: each length indexes into colorRows2 (= [Short Long]); the
    % short bar -> 1 (Short), the long bar -> 2 (Long). This is what nc == 2
    % trials read in CategoriesForTrial.m.
    lengthCat2_set     = [1, 2];
elseif strcmpi(stimulusSet, 'extremes3')
    % Three lengths, one per category, pushed as far apart as the full set
    % allows: shortest bar, Mid category's midpoint, longest bar. The two
    % extremes are the most separable pair the table contains (4.00 vs 7.80
    % deg VA), with the middle kept at the Mid category's centre so the three
    % stay evenly placed. min/max (not indices 1 and 12) so this keeps meaning
    % "the extremes" if the table above is ever edited or reordered.
    target_angles_set  = [min(target_angles_full), catMedianVA(2), max(target_angles_full)];
    lengthCategory_set = 1:numCategories;   % each length IS its own category
    lengthCat2_set     = ones(1, numCategories);   % unused: forced to 3cat, as prototypes3
else
    target_angles_set  = target_angles_full;
    lengthCategory_set = lengthCategory_full;
    % PLACEHOLDER 2-cat split: 1-6 Short, 7-12 Long (not aligned to the
    % 3-category boundaries above). Indexes into colorRows2 downstream.
    lengthCat2_set     = double((1:12) > 6) + 1;
end

% --- Bar-length subset (console "Bar lengths (subset)") -------------------
% Cuts the active stimulus set down to just the lengths this session should
% run: '' / 'all' (default) keeps every length, '5' runs one, '1-4,9-12' a
% mix -- see ParseBarSubset.m. Everything downstream is driven by numLengths,
% so a subset automatically shrinks the pseudorandom sequence, the
% per-(length,position) stop quota, and the end-of-session tables.
[barSubset, barSubsetErr] = ParseBarSubset(OrgGet(orgParams, 'barLengthSubset', ''), numel(target_angles_set));
if ~isempty(barSubsetErr)
    % Return early with what is defined so far; the caller inspects
    % barSubsetErr before touching any indexed field, so the partial struct
    % below is never read on this path (populated only to satisfy the
    % two-output contract without erroring on an empty barSubset index).
    bars = struct('numCategories', numCategories, 'stimulusSet', stimulusSet, ...
        'categorySet', lengthCategory_set, 'anglesSet', target_angles_set, ...
        'pixelPitch', pixel_pitch, 'subset', barSubset, 'angles', [], ...
        'category', [], 'category2', [], 'lengthsPerCategory', 0, ...
        'sizesPx', [], 'numLengths', 0);
    return;
end

target_angles  = target_angles_set(barSubset);
lengthCategory = lengthCategory_set(barSubset);
lengthCat2     = lengthCat2_set(barSubset);

% Lengths belonging to the most-represented category, used only for buffer
% sizing downstream -- derived from the selection rather than assumed from
% the stimulus set, so a subset doesn't leave buffers sized for lengths that
% never run.
lengthsPerCategory = max(accumarray(lengthCategory(:), 1, [numCategories 1]));
your_mm     = 2 * viewing_dist_mm * tan(deg2rad(target_angles / 2));
allBarSizes = round(your_mm / pixel_pitch);   % px
numLengths  = numel(allBarSizes);

bars = struct( ...
    'numCategories',      numCategories, ...
    'stimulusSet',        stimulusSet, ...
    'categorySet',        lengthCategory_set, ...
    'angles',             target_angles, ...
    'category',           lengthCategory, ...
    'category2',          lengthCat2, ...
    'lengthsPerCategory', lengthsPerCategory, ...
    'sizesPx',            allBarSizes, ...
    'numLengths',         numLengths, ...
    'pixelPitch',         pixel_pitch, ...
    'subset',             barSubset, ...
    'anglesSet',          target_angles_set);
end
