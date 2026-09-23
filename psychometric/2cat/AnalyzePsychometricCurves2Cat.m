function results = AnalyzePsychometricCurves2Cat(csvPath, varargin)
% ANALYZEPSYCHOMETRICCURVES2CAT This is an alternate version of AnalyzePsychometricCurves.m
% (the 3-category script), adapted for 2-category (Short/Long) sessions.
%
%The two are directly comparable with no methodological
% discrepancy: same sigmoid MLE fit (fminsearch on
% the binomial log-likelihood, alpha=threshold/beta=scale parametrization),
% same Wilson score CI, same deviance goodness-of-fit G-test, same SDT d'/
% criterion c (raw trial counts + Hautus 1995 log-linear correction, ALWAYS
% applied), same joint bootstrap for confidence intervals, same
% Width50to84 as the difference-limen-style width metric.
%
% THE ENGINE BELOW (STEP 1-4, all local helper functions) IS A DELIBERATE,
% COPY of AnalyzePsychometricCurves.m's own engine . T
% he ONLY change from the original is which loader gets
% called (LoadSessionTrialData2Cat instead of LoadSessionTrialData) and
% this function's own name.
% IMPORTANT:
%  If the 3-cat engine's math is ever changed, mirror the change here too.
%
% WHY A SEPARATE LOADER WAS NECESSARY: LoadSessionTrialData.m (the 3-cat loader) requires an
% 'Attempt' column (absent in every real 2-cat CSV seen so far) and infers
% "no response" from ChosenTarget>0, but 2-cat sessions code
% ChosenTarget=0 for "chose Short" (a REAL response). Running the 3-cat
% loader directly against a real 2-cat CSV (verified 2026-08-25, with a
% synthetic Attempt column patched in just to isolate the question) silently
% reclassified all "chose Short" trials as omissions AND collided both
% categories onto the same learned ChosenTarget code via an unguarded
% containers.Map overwrite. LoadSessionTrialData2Cat.m (this function's own
% loader, see its own header) fixes both issues at the source using
% ErrorType==1 as the omission sentinel instead of ChosenTarget's sign, and
% erroring explicitly instead of silently overwriting on any code collision
% so this fitting engine below never sees corrupted input.
%
% For nCat=2 (the only case this loader supports), there is exactly 1
% ordinal boundary (Short vs Long) and both categories get
% summaryType='threshold' (no interior "peak" category, since nCat-2=0
% interior categories)  this falls out of the SAME generic STEP 1-4 code
% below without any 2-cat-specific branching, exactly as it does in the
% 3-cat script when nCat happens to be 2 (see that script's own header,
% "2 curves instead of 3 for a 2-category session").
%
%   INPUT
%     csvPath : path to a 2-category trial_data_*.csv (see
%               LoadSessionTrialData2Cat.m for the exact schema handled)
%
%   NAME-VALUE OPTIONS -- identical set/defaults to AnalyzePsychometricCurves.m:
%     'UseFirstAttemptOnly' (default true)     -- no-op if no Attempt column
%     'LinkFunction'        (default 'logistic') -- 'logistic' | 'probit'
%     'UseLapseRates'       (default false)
%     'LapseMax'            (default 0.10)
%     'NBootstrap'          (default 1000)
%     'BootstrapAlpha'      (default 0.05)
%     'MakePlots'           (default true)
%     'FigureVisible'       (default true)
%     'FitOrdinalModel'     (default true)     -- always skipped for nCat=2
%                                                  (needs >=2 boundaries),
%                                                  kept only for parity/
%                                                  future extensibility
%     'OutDir'              (default: <csv folder>/psychometric_analysis_2cat)
%     'Verbose'             (default true)
%
%   OUTPUT: same results struct shape as AnalyzePsychometricCurves.m
%     (.meta, .boundary(1), .category(1:2), .ordinalModel) -- see that
%     file's header for the full field-by-field description, unchanged here.
%
%   USAGE
%     results = AnalyzePsychometricCurves2Cat('trial_data_23May2026_1444.csv');
%
% See also: AnalyzePsychometricCurves (3-category original, this project),
%           LoadSessionTrialData2Cat, AnalyzePsychometricCurvesMultiSession2Cat

% ===========================================================================
% OPTIONS
% ===========================================================================
p = inputParser;
addRequired(p, 'csvPath', @(s) ischar(s) || (isstring(s) && isscalar(s)));
addParameter(p, 'UseFirstAttemptOnly', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'LinkFunction', 'logistic', @(s) any(strcmpi(s, {'logistic', 'probit'})));
addParameter(p, 'UseLapseRates', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'LapseMax', 0.10, @(x) isnumeric(x) && isscalar(x) && x > 0 && x < 0.5);
addParameter(p, 'NBootstrap', 1000, @(x) isnumeric(x) && isscalar(x) && x >= 0);
addParameter(p, 'BootstrapAlpha', 0.05, @(x) isnumeric(x) && isscalar(x) && x > 0 && x < 1);
addParameter(p, 'MakePlots', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'FigureVisible', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'FitOrdinalModel', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'OutDir', '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
addParameter(p, 'Verbose', true, @(x) islogical(x) || isnumeric(x));
parse(p, csvPath, varargin{:});
opt = p.Results;
csvPath = char(opt.csvPath);
link = lower(opt.LinkFunction);
verbose = logical(opt.Verbose);

if ~exist(csvPath, 'file')
    error('AnalyzePsychometricCurves2Cat:fileNotFound', 'CSV not found: %s', csvPath);
end

[csvDir, csvBase, ~] = fileparts(csvPath);
if isempty(opt.OutDir)
    outDir = fullfile(csvDir, 'psychometric_analysis_2cat');
else
    outDir = char(opt.OutDir);
end
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

vprintf(verbose, '\n======= AnalyzePsychometricCurves2Cat: %s =======\n', csvBase);

% ===========================================================================
% LOAD + RESOLVE COLUMNS + CATEGORY STRUCTURE + EXCLUSIONS
% ===========================================================================
% ONLY DIFFERENCE FROM AnalyzePsychometricCurves.m: LoadSessionTrialData2Cat
% instead of LoadSessionTrialData.
S = LoadSessionTrialData2Cat(csvPath, logical(opt.UseFirstAttemptOnly), verbose);
groupNames = S.groupNames;  groupCode = S.groupCode;  nCat = S.nCat;
nRowsRaw = S.nRowsRaw;  nRows = S.nRows;
nOmission = S.nOmission;  nExcludedRetry = S.nExcludedRetry;  nUnexpected = S.nUnexpected;
xFit = S.xFit;  rankFit = S.rankFit;  stimRankFit = S.stimRankFit;  dirFit = S.dirFit;

if strcmp(S.barSizeUnit, 'px')
    vprintf(verbose, ['WARNING: %s reports bar size in PIXELS, not degrees of visual angle. ' ...
        'PSE/threshold/width remain in pixels -- not directly comparable with sessions ' ...
        'in degrees without a confirmed conversion factor.\n'], csvBase);
end

% QC: crude spatial-bias screen (identical to the 3-cat script)
if verbose && ~isempty(dirFit)
    uDir = unique(dirFit(~cellfun(@isempty, dirFit)));
    if numel(uDir) > 1
        fprintf('\n--- QC: proportion of response = highest category (%s), by chosen direction ---\n', groupNames{end});
        for d = 1:numel(uDir)
            rows_d = strcmp(dirFit, uDir{d});
            fprintf('  %-10s  n=%4d   P(resp=%s) = %.3f\n', uDir{d}, nnz(rows_d), groupNames{end}, ...
                mean(rankFit(rows_d) == nCat));
        end
        fprintf('  (Large differences between directions suggest a motor/spatial bias that this\n');
        fprintf('   curve does not separate from perceptual bias -- investigate if this shows up.)\n');
    end
end

% ===========================================================================
% STEP 1: FIT THE (nCat-1) ORDINAL CUMULATIVE BOUNDARIES: for nCat=2 this
% is exactly 1 boundary (Short vs Long). Identical code to the 3-cat script.
% ===========================================================================
nBoundaries = nCat - 1;
boundaryFits = struct([]);
for b = 1:nBoundaries
    lowName  = strjoin(groupNames(1:b), '+');
    highName = strjoin(groupNames(b+1:end), '+');
    yBin = double(rankFit >= (b + 1));

    [xLevels, k, n] = aggregateByLevel(xFit, yBin);
    fit = fitSigmoidMLE(xFit, yBin, link, logical(opt.UseLapseRates), opt.LapseMax);
    gof = goodnessOfFitDeviance(xLevels, k, n, fit, link);

    % --- SDT: d' and criterion c  EXACTLY the same calculation as the
    % 3-category script (raw counts + Hautus 1995 log-linear correction
    % ALWAYS applied, not only in extreme cases) 
    stimBin = double(stimRankFit >= (b + 1));
    nSignal = nnz(stimBin == 1);
    nNoise  = nnz(stimBin == 0);
    hitsN = nnz(yBin == 1 & stimBin == 1);
    fasN  = nnz(yBin == 1 & stimBin == 0);
    Hraw = hitsN / max(nSignal, 1);
    Fraw = fasN  / max(nNoise, 1);
    Hadj = (hitsN + 0.5) / (nSignal + 1);
    Fadj = (fasN  + 0.5) / (nNoise + 1);
    zH = linkInvCDF(Hadj, 'probit');
    zF = linkInvCDF(Fadj, 'probit');
    sdt = struct('nSignal', nSignal, 'nNoise', nNoise, 'hits', hitsN, 'falseAlarms', fasN, ...
        'Hraw', Hraw, 'Fraw', Fraw, 'Hadj', Hadj, 'Fadj', Fadj, ...
        'dprime', zH - zF, 'criterion', -0.5 * (zH + zF));

    % Theoretical (design) PSE: midpoint between the largest bar length
    % presented for the lower TRUE category and the smallest for the next
    % category up based only on StimulusGroup, NOT on responses. Same
    % construction as AnalyzePsychometricCurves.m's STEP 1.
    theoLowerMax = max(xFit(stimRankFit <= b));
    theoUpperMin = min(xFit(stimRankFit >= (b + 1)));
    theoreticalPSE = (theoLowerMax + theoUpperMin) / 2;

    bf = struct();
    bf.name = sprintf('%s | %s', lowName, highName);
    bf.lowLabel = lowName;  bf.highLabel = highName;
    bf.xLevels = xLevels;  bf.k = k;  bf.n = n;
    bf.propObs = k ./ n;
    [wLo, wHi] = wilsonCI(k, n, 0.05);
    bf.propWilsonLo = wLo;  bf.propWilsonHi = wHi;
    bf.fit = fit;
    bf.goodnessOfFit = gof;
    bf.sdt = sdt;
    bf.theoreticalPSE = theoreticalPSE;
    bf.theoreticalLowerMax = theoLowerMax;
    bf.theoreticalUpperMin = theoUpperMin;
    boundaryFits = [boundaryFits, bf]; %#ok<AGROW>
end

% ===========================================================================
% STEP 2: JOINT BOOTSTRAP (trial-row resample, single session)  identical
% to the 3-cat script's single-session bootstrap.
% ===========================================================================
xGrid = linspace(min(xFit), max(xFit), 300)';
if opt.NBootstrap > 0
    jb = jointBootstrap(xFit, rankFit, nCat, link, logical(opt.UseLapseRates), opt.LapseMax, ...
        opt.NBootstrap, opt.BootstrapAlpha, xGrid);
else
    jb = emptyJointBootstrap(nBoundaries, nCat, xGrid);
end

for b = 1:nBoundaries
    boundaryFits(b).thresholdCI = jb.boundaryAlphaCI(b, :);
    boundaryFits(b).slopeCI = jb.boundaryBetaCI(b, :);
    boundaryFits(b).nBootstrap = jb.nBoot;
    sdt = boundaryFits(b).sdt;
    vprintf(verbose, ['\n--- Boundary %d: %s ---\n' ...
        '  N (used in the fit): %d\n' ...
        '  Observed PSE (alpha, 50%% crossing): %.4f %s   95%% bootstrap CI: [%.4f, %.4f]\n' ...
        '  Slope (beta, scale):                %.4f %s   95%% bootstrap CI: [%.4f, %.4f]\n' ...
        '  Width 50-84%% (Width50to84):         %.4f %s\n' ...
        '  Theoretical PSE (design boundary):  %.4f %s   (midpoint between %.4f and %.4f)\n' ...
        '  Bias (observed - theoretical):      %.4f %s\n' ...
        '  Goodness of fit: G = %.3f, df = %d, p = %.4f  (small p = the model does not explain the data well)\n' ...
        '  --- SDT (empirical, does not depend on the sigmoid) ---\n' ...
        '  Hit rate  H = %.4f (%d/%d)   False alarm F = %.4f (%d/%d)   (H,F uncorrected)\n' ...
        '  d'' = %.4f   criterion c = %.4f  (c=0 no bias; c>0 bias toward "%s"; c<0 bias toward "%s")\n'], ...
        b, boundaryFits(b).name, sum(boundaryFits(b).n), boundaryFits(b).fit.alpha, S.barSizeUnit, ...
        jb.boundaryAlphaCI(b, 1), jb.boundaryAlphaCI(b, 2), boundaryFits(b).fit.beta, S.barSizeUnit, ...
        jb.boundaryBetaCI(b, 1), jb.boundaryBetaCI(b, 2), boundaryFits(b).fit.width50to84, S.barSizeUnit, ...
        boundaryFits(b).theoreticalPSE, S.barSizeUnit, boundaryFits(b).theoreticalLowerMax, boundaryFits(b).theoreticalUpperMin, ...
        boundaryFits(b).fit.alpha - boundaryFits(b).theoreticalPSE, S.barSizeUnit, ...
        boundaryFits(b).goodnessOfFit.G, boundaryFits(b).goodnessOfFit.df, boundaryFits(b).goodnessOfFit.p, ...
        sdt.Hraw, sdt.hits, sdt.nSignal, sdt.Fraw, sdt.falseAlarms, sdt.nNoise, ...
        sdt.dprime, sdt.criterion, boundaryFits(b).lowLabel, boundaryFits(b).highLabel);
end

% ===========================================================================
% STEP 3: DERIVE THE nCat ONE-VS-REST CATEGORY CURVES. For nCat=2 both
% categories fall into the c==1 / c==nCat edge branches (no interior
% category ever executes)  identical code to the 3-cat script.
% ===========================================================================
bpPoint = struct('alpha', {}, 'beta', {}, 'gamma', {}, 'lambda', {});
for b = 1:nBoundaries
    bpPoint(b).alpha = boundaryFits(b).fit.alpha;
    bpPoint(b).beta = boundaryFits(b).fit.beta;
    bpPoint(b).gamma = boundaryFits(b).fit.gamma;
    bpPoint(b).lambda = boundaryFits(b).fit.lambda;
end
Gpoint = allCumulativeCurves(xGrid, bpPoint, nCat, link);
Ppoint = categoryCurvesFromG(Gpoint);

category = struct([]);
for c = 1:nCat
    yInd = double(rankFit == c);
    [xLevels, k, n] = aggregateByLevel(xFit, yInd);
    [wLo, wHi] = wilsonCI(k, n, 0.05);

    xLevelTrueRank = nan(size(xLevels));
    for iLev = 1:numel(xLevels)
        xLevelTrueRank(iLev) = mode(stimRankFit(xFit == xLevels(iLev)));
    end

    cc = struct();
    cc.name = groupNames{c};
    cc.rank = c;
    cc.xLevels = xLevels;  cc.k = k;  cc.n = n;  cc.propObs = k ./ n;
    cc.propWilsonLo = wLo;  cc.propWilsonHi = wHi;
    cc.xLevelTrueRank = xLevelTrueRank;
    cc.curveX = xGrid;  cc.curveY = Ppoint(:, c);
    cc.curveLo = jb.categoryLo{c};  cc.curveHi = jb.categoryHi{c};
    cc.nBootstrap = jb.nBoot;

    cc.threshold = NaN;  cc.thresholdCI = [NaN NaN];
    cc.slope = NaN;      cc.slopeCI = [NaN NaN];
    cc.theoreticalThreshold = NaN;  cc.thresholdBias = NaN;
    cc.peakX = NaN;  cc.peakXCI = [NaN NaN];
    cc.peakY = NaN;  cc.peakYCI = [NaN NaN];
    cc.pseLower = NaN;  cc.pseUpper = NaN;
    cc.width = NaN;     cc.widthCI = [NaN NaN];
    cc.center = NaN;    cc.centerCI = [NaN NaN];
    cc.pseLowerTheoretical = NaN;  cc.pseUpperTheoretical = NaN;
    cc.widthTheoretical = NaN;     cc.centerTheoretical = NaN;
    cc.centerBias = NaN;
    cc.goodnessOfFit = struct('G', NaN, 'df', NaN, 'p', NaN);
    cc.summaryType = '';

    if c == 1
        cc.summaryType = 'threshold';
        cc.threshold = boundaryFits(1).fit.alpha;
        cc.thresholdCI = jb.boundaryAlphaCI(1, :);
        cc.slope = boundaryFits(1).fit.beta;
        cc.slopeCI = jb.boundaryBetaCI(1, :);
        cc.goodnessOfFit = boundaryFits(1).goodnessOfFit;
        cc.theoreticalThreshold = boundaryFits(1).theoreticalPSE;
        cc.thresholdBias = cc.threshold - cc.theoreticalThreshold;
    elseif c == nCat
        cc.summaryType = 'threshold';
        cc.threshold = boundaryFits(end).fit.alpha;
        cc.thresholdCI = jb.boundaryAlphaCI(end, :);
        cc.slope = boundaryFits(end).fit.beta;
        cc.slopeCI = jb.boundaryBetaCI(end, :);
        cc.goodnessOfFit = boundaryFits(end).goodnessOfFit;
        cc.theoreticalThreshold = boundaryFits(end).theoreticalPSE;
        cc.thresholdBias = cc.threshold - cc.theoreticalThreshold;
    else
        cc.summaryType = 'peak';
        s = curveSummary(xGrid, Ppoint(:, c));
        cc.peakX = s.peakX;  cc.peakY = s.peakY;
        cc.peakXCI = jb.categoryPeakXCI{c};
        cc.peakYCI = jb.categoryPeakYCI{c};
        cc.goodnessOfFit = struct('G', nan, 'df', nan, 'p', nan);
        cc.pseLower = boundaryFits(c - 1).fit.alpha;
        cc.pseUpper = boundaryFits(c).fit.alpha;
        cc.width  = cc.pseUpper - cc.pseLower;
        cc.center = (cc.pseLower + cc.pseUpper) / 2;
        cc.widthCI  = jb.categoryWidthCI{c};
        cc.pseLowerTheoretical = boundaryFits(c - 1).theoreticalPSE;
        cc.pseUpperTheoretical = boundaryFits(c).theoreticalPSE;
        cc.widthTheoretical  = cc.pseUpperTheoretical - cc.pseLowerTheoretical;
        cc.centerTheoretical = (cc.pseLowerTheoretical + cc.pseUpperTheoretical) / 2;
        cc.centerBias = cc.center - cc.centerTheoretical;
        cc.centerCI = jb.categoryCenterCI{c};
    end
    category = [category, cc]; %#ok<AGROW>

    if strcmp(cc.summaryType, 'threshold')
        vprintf(verbose, ['\n--- Category: %s (vs. rest) ---\n' ...
            '  Observed PSE (50%%): %.4f %s   95%% bootstrap CI: [%.4f, %.4f]\n' ...
            '  Slope:              %.4f %s   95%% bootstrap CI: [%.4f, %.4f]\n' ...
            '  Theoretical PSE:    %.4f %s   (bias = observed - theoretical = %.4f %s)\n'], ...
            cc.name, cc.threshold, S.barSizeUnit, cc.thresholdCI(1), cc.thresholdCI(2), ...
            cc.slope, S.barSizeUnit, cc.slopeCI(1), cc.slopeCI(2), ...
            cc.theoreticalThreshold, S.barSizeUnit, cc.thresholdBias, S.barSizeUnit);
    end
end

% ===========================================================================
% STEP 4: ORDINAL MODEL COMPARISON  always skipped for nCat=2 (needs
% nBoundaries>=2), same conditional as the 3-cat script. Kept only so this
% file stays structurally parallel to the 3cat version.
% ===========================================================================
ordinalModel = struct('available', false, 'note', '');
if logical(opt.FitOrdinalModel) && nBoundaries >= 2
    try
        alpha0 = arrayfun(@(b) boundaryFits(b).fit.alpha, 1:nBoundaries);
        beta0  = arrayfun(@(b) boundaryFits(b).fit.beta,  1:nBoundaries);
        fitFree   = fitOrdinalMLE(xFit, rankFit, nCat, link, false, alpha0, beta0);
        fitShared = fitOrdinalMLE(xFit, rankFit, nCat, link, true,  alpha0, beta0);
        Gstat = 2 * (fitShared.nll - fitFree.nll);
        Gstat = max(Gstat, 0);
        dfLR = fitFree.nParams - fitShared.nParams;
        pLR = 1 - chi2cdfNoTB(Gstat, dfLR);

        ordinalModel = struct();
        ordinalModel.available = true;
        ordinalModel.link = link;
        ordinalModel.unconstrained = fitFree;
        ordinalModel.proportionalOdds = fitShared;
        ordinalModel.LR = struct('G', Gstat, 'df', dfLR, 'p', pLR);
        ordinalModel.verdictText = 'N/A for nCat=2 (only 1 boundary, slope comparison does not apply).';
    catch ME_ord
        ordinalModel = struct('available', false, ...
            'note', sprintf('Ordinal model fit failed: %s', ME_ord.message));
    end
else
    ordinalModel.note = 'Not applicable: >=2 boundaries (>=3 categories) are needed to compare shared vs. separate slopes -- nCat=2 never satisfies this.';
end

% ===========================================================================
% PACKAGE RESULTS + SAVE
% ===========================================================================
results = struct();
results.meta = opt;
results.meta.csvPath = csvPath;
results.meta.groupNames = {groupNames{:}};
results.meta.groupCode = groupCode;
results.meta.nRowsRaw = nRowsRaw;
results.meta.nRowsUsable = nRows;
results.meta.nOmission = nOmission;
results.meta.nExcludedRetry = nExcludedRetry;
results.meta.nUnexpectedCode = nUnexpected;
results.meta.barSizeUnit = S.barSizeUnit;
results.meta.hasAttemptColumn = S.hasAttemptColumn;
results.boundary = boundaryFits;
results.category = category;
results.ordinalModel = ordinalModel;

matFile = fullfile(outDir, [csvBase '_psychometric2cat.mat']);
save(matFile, 'results');
vprintf(verbose, '\nSaved: %s\n', matFile);

summaryFileB = fullfile(outDir, [csvBase '_psychometric2cat_summary_boundaries.csv']);
writeBoundarySummaryCsv(summaryFileB, boundaryFits, link, opt, S.barSizeUnit);
vprintf(verbose, 'Saved: %s\n', summaryFileB);

summaryFileC = fullfile(outDir, [csvBase '_psychometric2cat_summary_categories.csv']);
writeCategorySummaryCsv(summaryFileC, category, link, opt, S.barSizeUnit);
vprintf(verbose, 'Saved: %s\n', summaryFileC);

if logical(opt.MakePlots)
    try
        makeCategoryPlots(category, outDir, csvBase, link, logical(opt.FigureVisible), numel(xFit), S.barSizeUnit);
        vprintf(verbose, 'Figures saved to: %s\n', outDir);
    catch ME_plot
        warning('AnalyzePsychometricCurves2Cat:plotFailed', ...
            'Could not generate the figures (%s): %s', ME_plot.identifier, ME_plot.message);
    end
end

vprintf(verbose, '\n=======================================================\n');
end % AnalyzePsychometricCurves2Cat


% =========================================================================
% LOCAL HELPER FUNCTIONS: copies of AnalyzePsychometricCurves.m's own.
%  Only writeBoundarySummaryCsv/
% writeCategorySummaryCsv/makeCategoryPlots gained a barSizeUnit parameter
% (cosmetic -labels axes/columns in 'deg' or 'px' instead of a hardcoded
% "degVA", since a 2-cat session can legitimately be in either unit; see
% LoadSessionTrialData2Cat.m).
% =========================================================================

function vprintf(verbose, varargin)
if verbose, fprintf(varargin{:}); end
end

function [xLevels, k, n] = aggregateByLevel(x, yBin)
xLevels = unique(x);
k = zeros(size(xLevels));
n = zeros(size(xLevels));
for i = 1:numel(xLevels)
    rows = x == xLevels(i);
    n(i) = nnz(rows);
    k(i) = sum(yBin(rows));
end
end

function [lo, hi] = wilsonCI(k, n, alpha)
z = sqrt(2) * erfinv(2 * (1 - alpha / 2) - 1);
phat = k ./ n;
denom = 1 + z^2 ./ n;
centre = (phat + z^2 ./ (2 * n)) ./ denom;
halfwidth = (z ./ denom) .* sqrt(phat .* (1 - phat) ./ n + z^2 ./ (4 * n.^2));
lo = max(0, centre - halfwidth);
hi = min(1, centre + halfwidth);
lo(n == 0) = nan; hi(n == 0) = nan;
end

function F = linkCDF(z, link)
switch link
    case 'logistic'
        F = 1 ./ (1 + exp(-z));
    case 'probit'
        F = 0.5 * (1 + erf(z / sqrt(2)));
    otherwise
        error('AnalyzePsychometricCurves2Cat:unknownLink', 'Unknown link function "%s".', link);
end
end

function zq = linkInvCDF(q, link)
switch link
    case 'logistic'
        q = min(max(q, eps), 1 - eps);
        zq = log(q ./ (1 - q));
    case 'probit'
        zq = sqrt(2) * erfinv(2 * min(max(q, eps), 1 - eps) - 1);
    otherwise
        error('AnalyzePsychometricCurves2Cat:unknownLink', 'Unknown link function "%s".', link);
end
end

function p = sigmoidP(x, alpha, beta, gamma, lambda, link)
p = gamma + (1 - gamma - lambda) .* linkCDF((x - alpha) ./ beta, link);
end

function nll = negLogLikBinom(theta, x, yBin, link, useLapse, lapseMax)
alpha = theta(1);
beta = exp(theta(2));
if useLapse
    gamma  = lapseMax * (1 ./ (1 + exp(-theta(3))));
    lambda = lapseMax * (1 ./ (1 + exp(-theta(4))));
else
    gamma = 0; lambda = 0;
end
p = sigmoidP(x, alpha, beta, gamma, lambda, link);
p = min(max(p, 1e-9), 1 - 1e-9);
nll = -sum(yBin .* log(p) + (1 - yBin) .* log(1 - p));
end

function fit = fitSigmoidMLE(x, yBin, link, useLapse, lapseMax)
[xLevels, k, n] = aggregateByLevel(x, yBin);
propAtLevel = k ./ max(n, 1);

[xSorted, ord] = sort(xLevels);
pSorted = propAtLevel(ord);
alpha0 = medianCrossing(xSorted, pSorted, median(x));
beta0 = max((max(x) - min(x)) / 4, eps);

if useLapse
    theta0 = [alpha0, log(beta0), 0, 0];
else
    theta0 = [alpha0, log(beta0)];
end

objective = @(theta) negLogLikBinom(theta, x, yBin, link, useLapse, lapseMax);
optionsFms = optimset('Display', 'off', 'MaxFunEvals', 5000, 'MaxIter', 5000, ...
    'TolX', 1e-8, 'TolFun', 1e-8);
[thetaHat, nllHat, exitflag] = fminsearch(objective, theta0, optionsFms);

fit = struct();
fit.alpha = thetaHat(1);
fit.beta = exp(thetaHat(2));
if useLapse
    fit.gamma = lapseMax * (1 ./ (1 + exp(-thetaHat(3))));
    fit.lambda = lapseMax * (1 ./ (1 + exp(-thetaHat(4))));
    fit.nParams = 4;
else
    fit.gamma = 0; fit.lambda = 0;
    fit.nParams = 2;
end
fit.nll = nllHat;
fit.aic = 2 * fit.nParams + 2 * nllHat;
fit.exitflag = exitflag;
fit.link = link;
fit.useLapse = useLapse;
fit.width50to84 = fit.beta * (linkInvCDF(0.84, link) - linkInvCDF(0.5, link));
end

function x0 = medianCrossing(xSorted, pSorted, fallback)
if numel(xSorted) < 2 || min(pSorted) >= 0.5 || max(pSorted) <= 0.5
    x0 = fallback;
    return;
end
x0 = fallback;
for i = 1:(numel(xSorted) - 1)
    if (pSorted(i) - 0.5) * (pSorted(i + 1) - 0.5) <= 0 && pSorted(i + 1) ~= pSorted(i)
        frac = (0.5 - pSorted(i)) / (pSorted(i + 1) - pSorted(i));
        x0 = xSorted(i) + frac * (xSorted(i + 1) - xSorted(i));
        break;
    end
end
if isnan(x0) || isinf(x0), x0 = fallback; end
end

function gof = goodnessOfFitDeviance(xLevels, k, n, fit, link)
pHat = sigmoidP(xLevels, fit.alpha, fit.beta, fit.gamma, fit.lambda, link);
pHat = min(max(pHat, 1e-9), 1 - 1e-9);
term1 = k .* log(max(k, eps) ./ (n .* pHat));
term2 = (n - k) .* log(max(n - k, eps) ./ (n .* (1 - pHat)));
term1(k == 0) = 0;
term2(k == n) = 0;
G = 2 * sum(term1 + term2);
df = numel(xLevels) - fit.nParams;
gof = struct('G', G, 'df', df, 'p', nan);
if df > 0
    gof.p = 1 - chi2cdfNoTB(G, df);
else
    gof.p = nan;
end
end

function p = chi2cdfNoTB(x, df)
x = max(x, 0);
p = gammainc(x / 2, df / 2);
end

function G = allCumulativeCurves(x, boundaryParams, nCat, link)
nB = nCat - 1;
G = zeros(numel(x), nCat + 1);
G(:, 1) = 1;
for b = 1:nB
    G(:, b + 1) = sigmoidP(x, boundaryParams(b).alpha, boundaryParams(b).beta, ...
        boundaryParams(b).gamma, boundaryParams(b).lambda, link);
end
G(:, end) = 0;
end

function P = categoryCurvesFromG(G)
P = G(:, 1:end-1) - G(:, 2:end);
end

function nll = negLogLikOrdinalMulti(theta, x, rankVec, nCat, link, sharedSlope)
nB = nCat - 1;
alphaVec = theta(1:nB);
if sharedSlope
    betaVec = exp(theta(nB + 1)) * ones(1, nB);
else
    betaVec = exp(theta(nB + 1:end));
end
bp = struct('alpha', {}, 'beta', {}, 'gamma', {}, 'lambda', {});
for b = 1:nB
    bp(b).alpha = alphaVec(b); bp(b).beta = betaVec(b);
    bp(b).gamma = 0; bp(b).lambda = 0;
end
G = allCumulativeCurves(x(:), bp, nCat, link);
P = categoryCurvesFromG(G);
P = min(max(P, 1e-9), 1);
n = numel(rankVec);
idx = sub2ind(size(P), (1:n)', rankVec(:));
nll = -sum(log(P(idx)));
end

function fit = fitOrdinalMLE(x, rankVec, nCat, link, sharedSlope, alpha0, beta0)
nB = nCat - 1;
if sharedSlope
    theta0 = [alpha0(:)', log(mean(beta0))];
else
    theta0 = [alpha0(:)', log(beta0(:))'];
end
objective = @(theta) negLogLikOrdinalMulti(theta, x, rankVec, nCat, link, sharedSlope);
optionsFms = optimset('Display', 'off', 'MaxFunEvals', 8000 * numel(theta0), ...
    'MaxIter', 8000 * numel(theta0), 'TolX', 1e-9, 'TolFun', 1e-9);
[thetaHat, nllHat, exitflag] = fminsearch(objective, theta0, optionsFms);

alphaHat = thetaHat(1:nB);
if sharedSlope
    betaHat = exp(thetaHat(nB + 1)) * ones(1, nB);
    nParams = nB + 1;
else
    betaHat = exp(thetaHat(nB + 1:end));
    nParams = 2 * nB;
end
fit = struct();
fit.alpha = alphaHat;
fit.beta = betaHat;
fit.nll = nllHat;
fit.nParams = nParams;
fit.sharedSlope = sharedSlope;
fit.exitflag = exitflag;
end

function s = curveSummary(xGrid, yGrid)
[peakY, iPk] = max(yGrid);
peakX = xGrid(iPk);
s = struct('peakX', peakX, 'peakY', peakY);
end

function jb = jointBootstrap(x, rankVec, nCat, link, useLapse, lapseMax, nBoot, alphaCI, xGrid)
n = numel(x);
nBoundaries = nCat - 1;
alphaBoot = nan(nBoundaries, nBoot);
betaBoot = nan(nBoundaries, nBoot);
categoryCurveBoot = cell(1, nCat);
peakXBoot = cell(1, nCat);
peakYBoot = cell(1, nCat);
for c = 1:nCat
    categoryCurveBoot{c} = nan(nBoot, numel(xGrid));
    peakXBoot{c} = nan(nBoot, 1);
    peakYBoot{c} = nan(nBoot, 1);
end

for i = 1:nBoot
    idx = randi(n, n, 1);
    xRes = x(idx);
    rankRes = rankVec(idx);
    bp = struct('alpha', {}, 'beta', {}, 'gamma', {}, 'lambda', {});
    okRep = true;
    for b = 1:nBoundaries
        yBinRes = double(rankRes >= (b + 1));
        try
            f = fitSigmoidMLE(xRes, yBinRes, link, useLapse, lapseMax);
            bp(b).alpha = f.alpha; bp(b).beta = f.beta; %#ok<AGROW>
            bp(b).gamma = f.gamma; bp(b).lambda = f.lambda; %#ok<AGROW>
            alphaBoot(b, i) = f.alpha;
            betaBoot(b, i) = f.beta;
        catch
            okRep = false;
            break;
        end
    end
    if ~okRep, continue; end
    G = allCumulativeCurves(xGrid, bp, nCat, link);
    P = categoryCurvesFromG(G);
    for c = 1:nCat
        categoryCurveBoot{c}(i, :) = P(:, c)';
        if c > 1 && c < nCat
            s = curveSummary(xGrid, P(:, c));
            peakXBoot{c}(i) = s.peakX;
            peakYBoot{c}(i) = s.peakY;
        end
    end
end

loP = alphaCI / 2; hiP = 1 - alphaCI / 2;
jb = struct();
jb.nBoot = nnz(~isnan(alphaBoot(1, :)));
jb.boundaryAlphaCI = nan(nBoundaries, 2);
jb.boundaryBetaCI = nan(nBoundaries, 2);
for b = 1:nBoundaries
    jb.boundaryAlphaCI(b, :) = quantileNoTB(alphaBoot(b, :)', [loP, hiP]);
    jb.boundaryBetaCI(b, :) = quantileNoTB(betaBoot(b, :)', [loP, hiP]);
end
jb.categoryLo = cell(1, nCat);
jb.categoryHi = cell(1, nCat);
jb.categoryPeakXCI = cell(1, nCat);
jb.categoryPeakYCI = cell(1, nCat);
jb.categoryWidthCI = cell(1, nCat);
jb.categoryCenterCI = cell(1, nCat);
for c = 1:nCat
    jb.categoryLo{c} = quantileNoTB(categoryCurveBoot{c}, loP, 1);
    jb.categoryHi{c} = quantileNoTB(categoryCurveBoot{c}, hiP, 1);
    if c > 1 && c < nCat
        jb.categoryPeakXCI{c} = quantileNoTB(peakXBoot{c}, [loP, hiP]);
        jb.categoryPeakYCI{c} = quantileNoTB(peakYBoot{c}, [loP, hiP]);
        widthBoot = alphaBoot(c, :) - alphaBoot(c - 1, :);
        centerBoot = (alphaBoot(c, :) + alphaBoot(c - 1, :)) / 2;
        jb.categoryWidthCI{c} = quantileNoTB(widthBoot', [loP, hiP]);
        jb.categoryCenterCI{c} = quantileNoTB(centerBoot', [loP, hiP]);
    else
        jb.categoryPeakXCI{c} = [nan nan];
        jb.categoryPeakYCI{c} = [nan nan];
        jb.categoryWidthCI{c} = [nan nan];
        jb.categoryCenterCI{c} = [nan nan];
    end
end
end

function jb = emptyJointBootstrap(nBoundaries, nCat, xGrid)
jb = struct();
jb.nBoot = 0;
jb.boundaryAlphaCI = nan(nBoundaries, 2);
jb.boundaryBetaCI = nan(nBoundaries, 2);
jb.categoryLo = cell(1, nCat);
jb.categoryHi = cell(1, nCat);
jb.categoryPeakXCI = cell(1, nCat);
jb.categoryPeakYCI = cell(1, nCat);
jb.categoryWidthCI = cell(1, nCat);
jb.categoryCenterCI = cell(1, nCat);
for c = 1:nCat
    jb.categoryLo{c} = nan(size(xGrid));
    jb.categoryHi{c} = nan(size(xGrid));
    jb.categoryPeakXCI{c} = [nan nan];
    jb.categoryPeakYCI{c} = [nan nan];
    jb.categoryWidthCI{c} = [nan nan];
    jb.categoryCenterCI{c} = [nan nan];
end
end

function q = quantileNoTB(v, probs, dim)
if nargin < 3, dim = 1; end
if dim == 1 && isvector(v)
    v = v(~isnan(v));
    v = sort(v);
    m = numel(v);
    if m == 0, q = nan(size(probs)); return; end
    q = arrayfun(@(pp) interpQuantile(v, pp), probs);
else
    q = nan(size(v, 2), numel(probs));
    for c = 1:size(v, 2)
        col = v(:, c);
        col = col(~isnan(col));
        col = sort(col);
        if isempty(col)
            q(c, :) = nan;
        else
            q(c, :) = arrayfun(@(pp) interpQuantile(col, pp), probs);
        end
    end
end
end

function val = interpQuantile(sortedV, p)
m = numel(sortedV);
if m == 1, val = sortedV(1); return; end
pos = 1 + p * (m - 1);
lo = floor(pos); hi = ceil(pos);
lo = min(max(lo, 1), m); hi = min(max(hi, 1), m);
frac = pos - lo;
val = sortedV(lo) + frac * (sortedV(hi) - sortedV(lo));
end

function s = fmtNum(v)
% Renders a numeric value for a CSV cell, or a BLANK (not a literal "NaN"
% string, and never 0) when v is NaN -- a blank unambiguously means "not
% applicable for this row type". Same helper as AnalyzePsychometricCurves.m,
% used here so adding a column never requires hand-counting %.6f
% placeholders against a giant fprintf argument list.
if isnan(v)
    s = '';
else
    s = sprintf('%.6f', v);
end
end

function writeBoundarySummaryCsv(fname, boundaryFits, link, opt, unit)
header = {'Boundary', 'LinkFunction', 'N', sprintf('Threshold_alpha_%s', unit), 'ThresholdCI_lo', 'ThresholdCI_hi', ...
    sprintf('Slope_beta_%s', unit), 'SlopeCI_lo', 'SlopeCI_hi', sprintf('Width50to84_%s', unit), 'Gamma', 'Lambda', ...
    'AIC', 'DevianceG', 'DevianceDF', 'DeviancePvalue', ...
    sprintf('TheoreticalPSE_%s', unit), sprintf('Bias_%s', unit), ...
    'Hraw', 'Fraw', 'Hits', 'Nsignal', 'FalseAlarms', 'Nnoise', 'Dprime', 'CriterionC', ...
    'NBootstrap', 'UseFirstAttemptOnly'};
fid = fopen(fname, 'w');
fprintf(fid, '%s\n', strjoin(header, ','));
for b = 1:numel(boundaryFits)
    bb = boundaryFits(b);
    sdt = bb.sdt;
    fields = {bb.name, link, sprintf('%d', sum(bb.n)), ...
        fmtNum(bb.fit.alpha), fmtNum(bb.thresholdCI(1)), fmtNum(bb.thresholdCI(2)), ...
        fmtNum(bb.fit.beta), fmtNum(bb.slopeCI(1)), fmtNum(bb.slopeCI(2)), ...
        fmtNum(bb.fit.width50to84), fmtNum(bb.fit.gamma), fmtNum(bb.fit.lambda), ...
        sprintf('%.4f', bb.fit.aic), sprintf('%.4f', bb.goodnessOfFit.G), ...
        sprintf('%d', bb.goodnessOfFit.df), fmtNum(bb.goodnessOfFit.p), ...
        fmtNum(bb.theoreticalPSE), fmtNum(bb.fit.alpha - bb.theoreticalPSE), ...
        fmtNum(sdt.Hraw), fmtNum(sdt.Fraw), sprintf('%d', sdt.hits), sprintf('%d', sdt.nSignal), ...
        sprintf('%d', sdt.falseAlarms), sprintf('%d', sdt.nNoise), fmtNum(sdt.dprime), fmtNum(sdt.criterion), ...
        sprintf('%d', bb.nBootstrap), sprintf('%d', logical(opt.UseFirstAttemptOnly))};
    fprintf(fid, '%s\n', strjoin(fields, ','));
end
fclose(fid);
end

function writeCategorySummaryCsv(fname, category, link, opt, unit)
header = {'Category', 'SummaryType', 'LinkFunction', 'N', ...
    sprintf('PSE_50pct_%s', unit), 'PSE_CI_lo', 'PSE_CI_hi', sprintf('PSE_Theoretical_%s', unit), sprintf('PSE_Bias_%s', unit), ...
    sprintf('Slope_%s', unit), 'SlopeCI_lo', 'SlopeCI_hi', ...
    sprintf('PeakX_%s', unit), 'PeakXCI_lo', 'PeakXCI_hi', 'PeakY', 'PeakYCI_lo', 'PeakYCI_hi', ...
    sprintf('PSElower_%s', unit), sprintf('PSEupper_%s', unit), sprintf('Width_%s', unit), 'WidthCI_lo', 'WidthCI_hi', ...
    sprintf('Center_%s', unit), 'CenterCI_lo', 'CenterCI_hi', ...
    sprintf('PSElowerTheoretical_%s', unit), sprintf('PSEupperTheoretical_%s', unit), sprintf('WidthTheoretical_%s', unit), ...
    sprintf('CenterTheoretical_%s', unit), sprintf('CenterBias_%s', unit), ...
    'NBootstrap', 'UseFirstAttemptOnly'};
fid = fopen(fname, 'w');
fprintf(fid, '%s\n', strjoin(header, ','));
for c = 1:numel(category)
    cc = category(c);
    fields = {cc.name, cc.summaryType, link, sprintf('%d', sum(cc.n)), ...
        fmtNum(cc.threshold), fmtNum(cc.thresholdCI(1)), fmtNum(cc.thresholdCI(2)), ...
        fmtNum(cc.theoreticalThreshold), fmtNum(cc.thresholdBias), ...
        fmtNum(cc.slope), fmtNum(cc.slopeCI(1)), fmtNum(cc.slopeCI(2)), ...
        fmtNum(cc.peakX), fmtNum(cc.peakXCI(1)), fmtNum(cc.peakXCI(2)), ...
        fmtNum(cc.peakY), fmtNum(cc.peakYCI(1)), fmtNum(cc.peakYCI(2)), ...
        fmtNum(cc.pseLower), fmtNum(cc.pseUpper), fmtNum(cc.width), fmtNum(cc.widthCI(1)), fmtNum(cc.widthCI(2)), ...
        fmtNum(cc.center), fmtNum(cc.centerCI(1)), fmtNum(cc.centerCI(2)), ...
        fmtNum(cc.pseLowerTheoretical), fmtNum(cc.pseUpperTheoretical), fmtNum(cc.widthTheoretical), ...
        fmtNum(cc.centerTheoretical), fmtNum(cc.centerBias), ...
        sprintf('%d', cc.nBootstrap), sprintf('%d', logical(opt.UseFirstAttemptOnly))};
    fprintf(fid, '%s\n', strjoin(fields, ','));
end
fclose(fid);
end

function colors = defaultCategoryColors(nCat)
orange = [1.00 0.647 0.00];
green  = [0.00 0.70 0.00];
blue   = [0.00 0.00 1.00];
switch nCat
    case 2
        colors = [orange; blue];
    case 3
        colors = [orange; green; blue];
    otherwise
        colors = lines(nCat);
end
end

function makeCategoryPlots(category, outDir, csvBase, link, figVisible, nTrialsUsed, unit)
% Same visual conventions as AnalyzePsychometricCurves.m's makeCategoryPlots
% and AnalyzePsychometricCurvesMultiSession2Cat.m's (point coloring by TRUE
% category, OBSERVED PSE in red with a "PSE_obs" text label, THEORETICAL/
% design PSE in teal-blue with a "PSE_theo" text label, chance-level
% reference, two-line "Name vs Rest" / "Sessions: 1 | Trials: N" titles) --
% duplicated here (see this file's header), with the axis/column unit
% parameterized by `unit` ('deg' or 'px') instead of the 3-cat script's
% hardcoded 'deg VA'. This is always a SINGLE session, so the title always
% reports "Sessions: 1". For nCat=2 every category is 'threshold'-type, so
% the 'peak' branch below is dead code, kept only for structural parity
% with the 3-cat engine.
nCat = numel(category);
colors = defaultCategoryColors(nCat);
chanceLevel = 1 / nCat;
theoColor   = [0.0 0.45 0.7];   % teal-blue: theoretical/design elements
obsPseColor = [0.85 0.1 0.1];   % red: observed PSE elements
if figVisible, visStr = 'on'; else, visStr = 'off'; end

for c = 1:nCat
    cc = category(c);
    fig = figure('Visible', visStr, 'Position', [100 100 640 480]);
    hold on;
    legendH = [];  legendLabels = {};
    if ~isempty(cc.curveLo) && ~all(isnan(cc.curveLo))
        xFill = [cc.curveX; flipud(cc.curveX)];
        yFill = [cc.curveLo; flipud(cc.curveHi)];
        hFill = fill(xFill, yFill, colors(c, :), 'EdgeColor', 'none', 'FaceAlpha', 0.25);
        legendH = [legendH, hFill];  legendLabels{end+1} = '95% bootstrap CI';
    end
    hCurve = plot(cc.curveX, cc.curveY, '-', 'Color', colors(c, :) * 0.75, 'LineWidth', 2);
    legendH = [legendH, hCurve];  legendLabels{end+1} = 'Fitted curve (derived)';
    errLo = cc.propObs - cc.propWilsonLo;
    errHi = cc.propWilsonHi - cc.propObs;
    for g = 1:nCat
        idxG = (cc.xLevelTrueRank == g);
        if ~any(idxG), continue; end
        hEBg = errorbar(cc.xLevels(idxG), cc.propObs(idxG), errLo(idxG), errHi(idxG), 'o');
        set(hEBg, 'Color', colors(g, :) * 0.6, 'MarkerFaceColor', colors(g, :), ...
            'MarkerEdgeColor', colors(g, :) * 0.6, 'MarkerSize', 6, 'LineWidth', 1.2);
        legendH = [legendH, hEBg]; %#ok<AGROW>
        legendLabels{end+1} = sprintf('Data: bar=%s (n=%d)', category(g).name, sum(cc.n(idxG))); %#ok<AGROW>
    end
    hChance = plot(xlim_safe2(cc.curveX), [chanceLevel chanceLevel], '--', ...
        'Color', [0.6 0.6 0.6], 'LineWidth', 1);
    legendH = [legendH, hChance];  legendLabels{end+1} = sprintf('Chance (1/%d = %.3f)', nCat, chanceLevel);
    if strcmp(cc.summaryType, 'threshold')
        % --- Observed PSE (red) ---
        hPseV = plot([cc.threshold cc.threshold], [0 0.5], ':', 'Color', obsPseColor, 'LineWidth', 1.3);
        plot(xlim_safe2(cc.curveX), [0.5 0.5], ':', 'Color', obsPseColor, 'LineWidth', 1.3);
        plot(cc.threshold, 0.5, 'p', 'MarkerSize', 10, 'MarkerFaceColor', obsPseColor, 'MarkerEdgeColor', 'k');
        text(cc.threshold, 0.5 + 0.04, sprintf('PSE_{obs}\n%.3f', cc.threshold), ...
            'Color', obsPseColor, 'FontSize', 8, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center', 'Interpreter', 'tex');
        legendH = [legendH, hPseV]; %#ok<AGROW>
        legendLabels{end+1} = sprintf('PSE obs (50%%) = %.3f [%.3f, %.3f]', ...
            cc.threshold, cc.thresholdCI(1), cc.thresholdCI(2));
        % --- Theoretical PSE (teal) ---
        if ~isnan(cc.theoreticalThreshold)
            hTheoV = plot([cc.theoreticalThreshold cc.theoreticalThreshold], [0 0.5], '--', ...
                'Color', theoColor, 'LineWidth', 1.3);
            plot(cc.theoreticalThreshold, 0.5, 'd', 'MarkerSize', 9, ...
                'MarkerFaceColor', theoColor, 'MarkerEdgeColor', 'k');
            text(cc.theoreticalThreshold, 0.5 - 0.09, sprintf('PSE_{theo}\n%.3f', cc.theoreticalThreshold), ...
                'Color', theoColor, 'FontSize', 8, 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'center', 'Interpreter', 'tex');
            legendH = [legendH, hTheoV]; %#ok<AGROW>
            legendLabels{end+1} = sprintf('PSE theo (design) = %.3f', cc.theoreticalThreshold);
        end
        restLbl = strjoin({category(setdiff(1:nCat, c)).name}, '+');
        ttlLine1 = sprintf('%s vs. %s', cc.name, restLbl);
        ttlLine2 = sprintf('Sessions: 1  |  Trials: %d', nTrialsUsed);
        title({ttlLine1, ttlLine2}, 'Interpreter', 'none');
    else
        % --- Interior category (dead code for nCat=2, kept for parity): peak + teal theoretical boundaries only ---
        plot([cc.peakX cc.peakX], [0 cc.peakY], ':', 'Color', [0.3 0.3 0.3]);
        if ~isnan(cc.pseLowerTheoretical) && ~isnan(cc.pseUpperTheoretical)
            hTheoWidth = plot([cc.pseLowerTheoretical cc.pseLowerTheoretical ...
                               cc.pseUpperTheoretical cc.pseUpperTheoretical], [0 1 1 0], '--', ...
                'Color', theoColor, 'LineWidth', 1.1);
            hTheoWidth = hTheoWidth(1);
            plot(cc.centerTheoretical, 0.02, 'v', 'MarkerSize', 8, ...
                'MarkerFaceColor', theoColor, 'MarkerEdgeColor', 'k');
            legendH = [legendH, hTheoWidth]; %#ok<AGROW>
            legendLabels{end+1} = sprintf('Theoretical bounds [%.3f, %.3f] (width=%.3f)', ...
                cc.pseLowerTheoretical, cc.pseUpperTheoretical, cc.widthTheoretical);
        end
        ttlLine1 = sprintf('%s vs. %s+%s', cc.name, category(1).name, category(nCat).name);
        ttlLine2 = sprintf('Sessions: 1  |  Trials: %d', nTrialsUsed);
        title({ttlLine1, ttlLine2}, 'Interpreter', 'none');
    end
    xlabel(sprintf('Bar length (%s)', unit));
    ylabel(sprintf('P(respuesta = %s)', categoryNameEs(cc.name)));
    ylim([-0.02 1.02]);
    grid on; box on;
    legend(legendH, legendLabels, 'Location', 'best');
    outFile = fullfile(outDir, sprintf('%s_category_%s_%s.png', csvBase, cc.name, link));
    try
        print(fig, outFile, '-dpng', '-r150');
    catch
        saveas(fig, outFile);
    end
    if ~figVisible, close(fig); end
end

% --- Overview (all curves together) ---
fig = figure('Visible', visStr, 'Position', [100 100 720 520]);
hold on;
legendEntries = cell(1, nCat);
for c = 1:nCat
    cc = category(c);
    plot(cc.curveX, cc.curveY, '-', 'Color', colors(c, :) * 0.75, 'LineWidth', 2.2);
    errLo = cc.propObs - cc.propWilsonLo;
    errHi = cc.propWilsonHi - cc.propObs;
    hEB = errorbar(cc.xLevels, cc.propObs, errLo, errHi, 'o');
    set(hEB, 'Color', colors(c, :) * 0.75, 'MarkerFaceColor', colors(c, :), ...
        'MarkerSize', 5, 'LineWidth', 1);
    legendEntries{c} = cc.name;
    if strcmp(cc.summaryType, 'threshold')
        % Observed PSE vertical line + star
        plot([cc.threshold cc.threshold], [0 0.5], ':', 'Color', obsPseColor, 'LineWidth', 1.3);
        plot(cc.threshold, 0.5, 'p', 'MarkerSize', 9, 'MarkerFaceColor', obsPseColor, 'MarkerEdgeColor', 'k');
        text(cc.threshold, 0.5 + 0.04, sprintf('PSE_{obs}\n%.3f', cc.threshold), ...
            'Color', obsPseColor, 'FontSize', 7.5, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center', 'Interpreter', 'tex');
        % Theoretical PSE vertical line + diamond
        if ~isnan(cc.theoreticalThreshold)
            plot([cc.theoreticalThreshold cc.theoreticalThreshold], [0 0.5], '--', ...
                'Color', theoColor, 'LineWidth', 1.3);
            plot(cc.theoreticalThreshold, 0.5, 'd', 'MarkerSize', 8, ...
                'MarkerFaceColor', theoColor, 'MarkerEdgeColor', 'k');
            text(cc.theoreticalThreshold, 0.5 - 0.09, sprintf('PSE_{theo}\n%.3f', cc.theoreticalThreshold), ...
                'Color', theoColor, 'FontSize', 7.5, 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'center', 'Interpreter', 'tex');
        end
    end
end
plot(xlim_safe2(category(1).curveX), [0.5 0.5], ':', 'Color', [0.5 0.5 0.5], 'LineWidth', 1);
plot(xlim_safe2(category(1).curveX), [chanceLevel chanceLevel], '--', 'Color', [0.6 0.6 0.6], 'LineWidth', 1);
text(category(1).curveX(end), 0.5, ' 50% (PSE)', 'Color', [0.4 0.4 0.4], 'VerticalAlignment', 'bottom');
text(category(1).curveX(end), chanceLevel, sprintf(' Chance 1/%d', nCat), 'Color', [0.5 0.5 0.5], 'VerticalAlignment', 'top');
% Teal theoretical boundaries for interior categories (dead code for nCat=2, kept for parity)
for c = 1:nCat
    cc = category(c);
    if strcmp(cc.summaryType, 'peak') && ~isnan(cc.pseLowerTheoretical) && ~isnan(cc.pseUpperTheoretical)
        plot([cc.pseLowerTheoretical cc.pseLowerTheoretical], [0 1], '--', 'Color', theoColor, 'LineWidth', 1);
        plot([cc.pseUpperTheoretical cc.pseUpperTheoretical], [0 1], '--', 'Color', theoColor, 'LineWidth', 1);
        plot(cc.centerTheoretical, 0.02, 'v', 'MarkerSize', 8, ...
            'MarkerFaceColor', theoColor, 'MarkerEdgeColor', 'k');
    end
end
xlabel(sprintf('Bar length (%s)', unit));
ylabel('P(response = category)');
catNames = strjoin({category.name}, ' vs ');
ttlLine1 = catNames;
ttlLine2 = sprintf('Sessions: 1  |  Trials: %d', nTrialsUsed);
title({ttlLine1, ttlLine2}, 'Interpreter', 'none');
ylim([-0.02 1.02]);
grid on; box on;
legend(legendEntries, 'Location', 'best');
outFile = fullfile(outDir, sprintf('%s_categories_overview_%s.png', csvBase, link));
try
    print(fig, outFile, '-dpng', '-r150');
catch
    saveas(fig, outFile);
end
if ~figVisible, close(fig); end
end

function xr = xlim_safe2(x)
xr = [min(x), max(x)];
end

function nameEs = categoryNameEs(nameEn)
% Spanish label for the Y axis of a per-category psychometric curve
% (e.g. "ShortGroup" -> "corto"). Falls back to the original name for
% any group not in this table, so an unexpected category still plots.
switch nameEn
    case 'ShortGroup'
        nameEs = 'corto';
    case 'MidGroup'
        nameEs = 'medio';
    case 'LongGroup'
        nameEs = 'largo';
    otherwise
        nameEs = nameEn;
end
end
