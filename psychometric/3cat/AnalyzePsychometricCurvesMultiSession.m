function results = AnalyzePsychometricCurvesMultiSession(csvPaths, varargin)
% ANALYZEPSYCHOMETRICCURVESMULTISESSION  Fit categorization ("psychometric")
% curves POOLING several trial_data_*.csv sessions together into ONE
% combined analysis, plus a per-session comparison table . This is the multi-
% session counterpart to AnalyzePsychometricCurves.m (which analyzes
% only one session).

%   TWO OUTPUTS:
%   1) POOLED/COMBINED curves: one set of boundary/category fits (PSE,
%      slope, d', criterion c, Mid width/center, etc.) for ALL sessions
%      together, with the session-cluster-bootstrap CI described above.
%      This is results.boundary / results.category / results.ordinalModel,
%      and the "..._pooled_summary_*.csv" / pooled .png outputs.
%   2) PER-SESSION COMPARISON TABLE: each session is ALSO run completely
%      independently through AnalyzePsychometricCurves.m  and the resulting PSE/slope/d'/c/etc. are
%      collected into one row-per-session CSV plus a simple comparison
%      plot (per-session PSE with its own CI, against the pooled estimate's
%      band). USE THIS to sanity-check homogeneity BEFORE trusting the
%      pooled curve: if sessions visibly disagree here, pooling them into
%      one curve is hiding real between-session structure, not summarizing
%      noise around a common value; meaning the pooled numbers can still be
%      reported, but should be warned as such, not treated as if all
%      sessions came from one stable behavioral state.
%   3) COMBINED CHRONOMETRIC CURVE: mean time (in MILLISECONDS) from
%      target-onset to the cursor entering the target, vs. bar length.
%      Correct trials plotted separately from error trials
%      (results.chronometric), with the SAME
%      session-cluster-bootstrap CI as (1) above.
%
%   CATEGORY-STRUCTURE COMPATIBILITY CHECK:
%   every session being pooled MUST have the same number of categories AND
%   the same category names in the same order (e.g. all 3-category
%   Short/Mid/Long, not a mix of 2- and 3-category sessions) to avoid confusing the analysis and mixing categories. This is checked explicitly before any pooling happens
%   (see CATEGORY-STRUCTURE COMPATIBILITY CHECK below); a mismatch stops
%   the whole run with a loud, specific error identifying which session
%   differs and how.

%
%   NO STATISTICS/OPTIMIZATION TOOLBOX IS USED (fminsearch + erf/erfinv
%   only).
%
%   INPUT
%     csvPaths : cell array of paths to trial_data_*.csv files (one per
%                session), OR a single path (auto-wrapped in a 1-cell
%                array, but you need >=2 sessions for this script to make
%                sense; use AnalyzePsychometricCurves.m directly for 1).

% ===========================================================================
% OPTIONS
% ===========================================================================
p = inputParser;
addRequired(p, 'csvPaths', @(x) iscell(x) || ischar(x) || isstring(x));
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
addParameter(p, 'RunPerSessionComparison', true, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'PerSessionMakePlots', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'MakeComparisonPlots', false, @(x) islogical(x) || isnumeric(x));
addParameter(p, 'PerSessionOutDir', '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
parse(p, csvPaths, varargin{:});
opt = p.Results;
link = lower(opt.LinkFunction);
verbose = logical(opt.Verbose);

% Normalize csvPaths to a cell array of char row vectors: tolerates a
% single path (char/string), a cell array of char, or a string array (the
% same flexibility uigetfile's 'MultiSelect' output needs downstream in
% RunPsychometricAnalysisMultiSession.m).
if ischar(csvPaths)
    csvPaths = {csvPaths};
elseif isstring(csvPaths)
    csvPaths = cellstr(csvPaths);
end
csvPaths = csvPaths(:)';
nSessions = numel(csvPaths);
if nSessions < 2
    error('AnalyzePsychometricCurvesMultiSession:tooFewSessions', ...
        ['At least 2 sessions are needed for a combined analysis (%d received). ' ...
         'For a single session use AnalyzePsychometricCurves.m directly.'], nSessions);
end
for i = 1:nSessions
    csvPaths{i} = char(csvPaths{i});
    if ~exist(csvPaths{i}, 'file')
        error('AnalyzePsychometricCurvesMultiSession:fileNotFound', 'CSV not found: %s', csvPaths{i});
    end
end

[firstDir, ~, ~] = fileparts(csvPaths{1});
if isempty(opt.OutDir)
    outDir = fullfile(firstDir, 'psychometric_analysis_multisession');
else
    outDir = char(opt.OutDir);
end
if ~exist(outDir, 'dir')
    mkdir(outDir);
end
if isempty(opt.PerSessionOutDir)
    perSessionOutDir = fullfile(outDir, 'per_session');
else
    perSessionOutDir = char(opt.PerSessionOutDir);
end

poolBase = sprintf('MultiSession_N%dsessions', nSessions);

vprintf(verbose, '\n======= AnalyzePsychometricCurvesMultiSession: %d sessions =======\n', nSessions);

% ===========================================================================
% LOAD EACH SESSION (shared logic in LoadSessionTrialData.m)
% ===========================================================================
S = cell(1, nSessions);
for i = 1:nSessions
    vprintf(verbose, '\n--- Loading session %d/%d ---\n', i, nSessions);
    S{i} = LoadSessionTrialData(csvPaths{i}, logical(opt.UseFirstAttemptOnly), verbose);
end

% ===========================================================================
% CATEGORY-STRUCTURE COMPATIBILITY CHECK 
% see header note above for why thiscan result in an error.
% ===========================================================================
refGroupNames = S{1}.groupNames;
refNCat = S{1}.nCat;
for i = 2:nSessions
    if S{i}.nCat ~= refNCat || ~isequal(S{i}.groupNames(:), refGroupNames(:))
        error('AnalyzePsychometricCurvesMultiSession:categoryMismatch', ...
            ['Session %d (%s) has a different category structure from session 1 (%s):\n' ...
             '  Session 1: nCat=%d, categories = {%s}\n' ...
             '  Session %d: nCat=%d, categories = {%s}\n' ...
             'Sessions with different numbers or names/order of categories cannot be combined -- ' ...
             'make sure all sessions are from the same task type (2 vs 3 categories).'], ...
            i, S{i}.csvBase, S{1}.csvBase, refNCat, strjoin(refGroupNames, ', '), ...
            i, S{i}.nCat, strjoin(S{i}.groupNames, ', '));
    end
end
nCat = refNCat;
groupNames = refGroupNames;
nBoundaries = nCat - 1;
vprintf(verbose, '\nCategory structure verified, compatible across all %d sessions: %s\n', ...
    nSessions, strjoin(groupNames, ' < '));

% ===========================================================================
% POOL TRIAL DATA -- concatenate all sessions, tagging each trial with its
% session of origin (sessionIdxAll). This tag is what the cluster bootstrap
% resamples ON below, NOT the trial rows themselves.
% ===========================================================================
xFitAll = []; rankFitAll = []; stimRankFitAll = []; dirFitAll = {}; sessionIdxAll = [];
sessionN = zeros(1, nSessions);
for i = 1:nSessions
    ni = numel(S{i}.xFit);
    sessionN(i) = ni;
    xFitAll = [xFitAll; S{i}.xFit(:)]; %#ok<AGROW>
    rankFitAll = [rankFitAll; S{i}.rankFit(:)]; %#ok<AGROW>
    stimRankFitAll = [stimRankFitAll; S{i}.stimRankFit(:)]; %#ok<AGROW>
    dirFitAll = [dirFitAll; S{i}.dirFit(:)]; %#ok<AGROW>
    sessionIdxAll = [sessionIdxAll; repmat(i, ni, 1)]; %#ok<AGROW>
end
nRowsPooled = numel(xFitAll);
vprintf(verbose, ['\n--- Pooled data ---\n' ...
    '  Sessions included: %d\n' ...
    '  Total trials pooled (after per-session exclusions): %d\n' ...
    '  Trials per session: %s\n'], ...
    nSessions, nRowsPooled, mat2str(sessionN));
if nSessions < 5
    warning('AnalyzePsychometricCurvesMultiSession:fewSessions', ...
        ['Only %d sessions -- the session-level cluster bootstrap can generate at most %d^%d ' ...
         'distinct resamples, so the resulting confidence interval will be of LOW/coarse resolution ' ...
         '(uninformative about the true distribution shape, even if the point estimate is still valid). ' ...
         'Not an error, but report this as a limitation: with so few sessions, a fine CI is not achievable ' ...
         'regardless of NBootstrap.'], nSessions, nSessions, nSessions);
end

% ===========================================================================
% POOL CHRONOMETRIC DATA (target-onset -> cursor-entra-al-target).
% If a trial is excluded due to inexisting reaction times it's exluded
% ONLY here, but still contributes to the psychometric curve.
% ===========================================================================
chronoSessionMask = false(1, nSessions);
for i = 1:nSessions
    chronoSessionMask(i) = ~strcmp(S{i}.timingSchema, 'unresolved');
end
chronoSessionList = find(chronoSessionMask);
nSessionsChrono = numel(chronoSessionList);
chronoExcludedNames = {};
if nSessionsChrono < nSessions
    excluded = S(~chronoSessionMask);
    chronoExcludedNames = cellfun(@(s) s.csvBase, excluded, 'UniformOutput', false);
    warning('AnalyzePsychometricCurvesMultiSession:chronoSessionsExcluded', ...
        ['%d of %d session(s) excluded from the combined chronometric curve due to unresolved ' ...
         'timing schema: %s (see LoadSessionTrialData warnings above). The rest of the analysis ' ...
         '(psychometric curves) is NOT affected.'], ...
        nSessions - nSessionsChrono, nSessions, strjoin(chronoExcludedNames, ', '));
end

xChronoAll = []; timeToTargetAll = []; isCorrectChronoAll = []; sessionIdxChronoAll = [];
for k = 1:nSessionsChrono
    i = chronoSessionList(k);
    ni = numel(S{i}.xFit);
    xChronoAll = [xChronoAll; S{i}.xFit(:)]; %#ok<AGROW>
    timeToTargetAll = [timeToTargetAll; S{i}.timeToTargetFit(:)]; %#ok<AGROW>
    isCorrectChronoAll = [isCorrectChronoAll; S{i}.isCorrectFit(:)]; %#ok<AGROW>
    sessionIdxChronoAll = [sessionIdxChronoAll; repmat(k, ni, 1)]; %#ok<AGROW>
end
% Rows with a still-NaN timing value  are dropped here rather than propagated into
% a mean.
chronoValidRow = ~isnan(timeToTargetAll);
xChronoAll = xChronoAll(chronoValidRow);
timeToTargetAll = timeToTargetAll(chronoValidRow);
isCorrectChronoAll = isCorrectChronoAll(chronoValidRow);
sessionIdxChronoAll = sessionIdxChronoAll(chronoValidRow);

% Conversion from seconds to miliseconds.
timeToTargetAll = timeToTargetAll * 1000;

% ===========================================================================
% STEP 1: FIT THE (nCat-1) ORDINAL BOUNDARIES ON THE POOLED DATA (point
% estimate) -- identical fitting to AnalyzePsychometricCurves.m's
% STEP 1 (duplicated by design). The only real methodological
% difference vs. the single-session script is WHAT gets resampled for the
% confidence interval.
% ===========================================================================
boundaryFits = struct([]);
for b = 1:nBoundaries
    lowName  = strjoin(groupNames(1:b), '+');
    highName = strjoin(groupNames(b+1:end), '+');
    yBin = double(rankFitAll >= (b + 1));

    [xLevels, k, n] = aggregateByLevel(xFitAll, yBin);
    fit = fitSigmoidMLE(xFitAll, yBin, link, logical(opt.UseLapseRates), opt.LapseMax);
    gof = goodnessOfFitDeviance(xLevels, k, n, fit, link);

    stimBin = double(stimRankFitAll >= (b + 1));
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

    % Theoretical (design) PSE: midpoint between the largest bar length
    % presented for the lower TRUE category and the smallest for the next
    % category up.
    theoLowerMax = max(xFitAll(stimRankFitAll <= b));
    theoUpperMin = min(xFitAll(stimRankFitAll >= (b + 1)));
    bf.theoreticalPSE = (theoLowerMax + theoUpperMin) / 2;
    bf.theoreticalLowerMax = theoLowerMax;
    bf.theoreticalUpperMin = theoUpperMin;

    boundaryFits = [boundaryFits, bf]; %#ok<AGROW>
end

% ===========================================================================
% STEP 2: SESSION-CLUSTER BOOTSTRAP. This is the methodological core of this script.
% ===========================================================================
xGrid = linspace(min(xFitAll), max(xFitAll), 300)';
if opt.NBootstrap > 0
    jb = sessionClusterBootstrap(xFitAll, rankFitAll, stimRankFitAll, sessionIdxAll, nSessions, ...
        nCat, link, logical(opt.UseLapseRates), opt.LapseMax, opt.NBootstrap, opt.BootstrapAlpha, xGrid);
else
    jb = emptyJointBootstrap(nBoundaries, nCat, xGrid);
    jb.dprimeCI = cell(1, nBoundaries);
    jb.criterionCI = cell(1, nBoundaries);
    for b = 1:nBoundaries
        jb.dprimeCI{b} = [nan nan];
        jb.criterionCI{b} = [nan nan];
    end
end

for b = 1:nBoundaries
    boundaryFits(b).thresholdCI = jb.boundaryAlphaCI(b, :);
    boundaryFits(b).slopeCI = jb.boundaryBetaCI(b, :);
    boundaryFits(b).nBootstrap = jb.nBoot;
    boundaryFits(b).dprimeCI = jb.dprimeCI{b};
    boundaryFits(b).criterionCI = jb.criterionCI{b};
    sdt = boundaryFits(b).sdt;
    vprintf(verbose, ['\n--- Boundary %d (POOLED, %d sessions): %s ---\n' ...
        '  N total (used in fit): %d\n' ...
        '  Observed PSE (alpha, 50%% crossing): %.4f deg VA   95%% cluster-bootstrap CI: [%.4f, %.4f]\n' ...
        '  Theoretical PSE (design boundary):  %.4f deg VA   (midpoint between %.4f and %.4f)\n' ...
        '  Bias (observed - theoretical):      %.4f deg VA\n' ...
        '  Slope (beta, scale):               %.4f deg VA   95%% cluster-bootstrap CI: [%.4f, %.4f]\n' ...
        '  Goodness of fit (trial-level, NOT session-adjusted): G = %.3f, df = %d, p = %.4f\n' ...
        '  --- SDT (empirical, pooled) ---\n' ...
        '  Hit rate  H = %.4f (%d/%d)   False alarm F = %.4f (%d/%d)\n' ...
        '  d'' = %.4f  95%% cluster-bootstrap CI: [%.4f, %.4f]\n' ...
        '  criterion c = %.4f  95%% cluster-bootstrap CI: [%.4f, %.4f]  (c=0 no bias; c>0 bias toward "%s"; c<0 bias toward "%s")\n'], ...
        b, nSessions, boundaryFits(b).name, sum(boundaryFits(b).n), boundaryFits(b).fit.alpha, ...
        jb.boundaryAlphaCI(b, 1), jb.boundaryAlphaCI(b, 2), ...
        boundaryFits(b).theoreticalPSE, boundaryFits(b).theoreticalLowerMax, boundaryFits(b).theoreticalUpperMin, ...
        boundaryFits(b).fit.alpha - boundaryFits(b).theoreticalPSE, ...
        boundaryFits(b).fit.beta, jb.boundaryBetaCI(b, 1), jb.boundaryBetaCI(b, 2), ...
        boundaryFits(b).goodnessOfFit.G, boundaryFits(b).goodnessOfFit.df, boundaryFits(b).goodnessOfFit.p, ...
        sdt.Hraw, sdt.hits, sdt.nSignal, sdt.Fraw, sdt.falseAlarms, sdt.nNoise, ...
        sdt.dprime, boundaryFits(b).dprimeCI(1), boundaryFits(b).dprimeCI(2), ...
        sdt.criterion, boundaryFits(b).criterionCI(1), boundaryFits(b).criterionCI(2), ...
        boundaryFits(b).lowLabel, boundaryFits(b).highLabel);
end

% ===========================================================================
% STEP 3: DERIVE THE nCat ONE-VS-REST CATEGORY CURVES FROM THE POOLED
% BOUNDARY FITS (point estimate) + session-cluster-bootstrap bands (STEP 2).
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
    yInd = double(rankFitAll == c);
    [xLevels, k, n] = aggregateByLevel(xFitAll, yInd);
    [wLo, wHi] = wilsonCI(k, n, 0.05);

    xLevelTrueRank = nan(size(xLevels));
    for iLev = 1:numel(xLevels)
        xLevelTrueRank(iLev) = mode(stimRankFitAll(xFitAll == xLevels(iLev)));
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

    % Placeholders -- threshold branch:
    cc.threshold = NaN;  cc.thresholdCI = [NaN NaN];
    cc.slope = NaN;      cc.slopeCI = [NaN NaN];
    cc.theoreticalThreshold = NaN;  cc.thresholdBias = NaN;
    % Placeholders -- peak branch:
    cc.peakX = NaN;  cc.peakXCI = [NaN NaN];
    cc.peakY = NaN;  cc.peakYCI = [NaN NaN];
    % Placeholders -- interior width/center (observed and theoretical):
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
        cc.centerCI = jb.categoryCenterCI{c};
        cc.pseLowerTheoretical = boundaryFits(c - 1).theoreticalPSE;
        cc.pseUpperTheoretical = boundaryFits(c).theoreticalPSE;
        cc.widthTheoretical  = cc.pseUpperTheoretical - cc.pseLowerTheoretical;
        cc.centerTheoretical = (cc.pseLowerTheoretical + cc.pseUpperTheoretical) / 2;
        cc.centerBias = cc.center - cc.centerTheoretical;
    end
    category = [category, cc]; %#ok<AGROW>

    if strcmp(cc.summaryType, 'threshold')
        vprintf(verbose, ['\n--- Category (POOLED): %s (vs. rest) ---\n' ...
            '  Observed PSE (50%%):   %.4f deg VA   95%% cluster-bootstrap CI: [%.4f, %.4f]\n' ...
            '  Slope:                %.4f deg VA   95%% cluster-bootstrap CI: [%.4f, %.4f]\n' ...
            '  Theoretical PSE:      %.4f deg VA   (bias = observed - theoretical = %.4f deg VA)\n'], ...
            cc.name, cc.threshold, cc.thresholdCI(1), cc.thresholdCI(2), ...
            cc.slope, cc.slopeCI(1), cc.slopeCI(2), cc.theoreticalThreshold, cc.thresholdBias);
    else
        vprintf(verbose, ['\n--- Category (POOLED): %s (vs. rest) ---\n' ...
            '  Peak:  x = %.4f deg VA  95%% CI: [%.4f, %.4f]   P(max) = %.3f  95%% CI: [%.3f, %.3f]\n' ...
            '  Lower PSE (%s|%s+...): %.4f deg VA\n' ...
            '  Upper PSE (...+%s|%s): %.4f deg VA\n' ...
            '  Subjective width  = %.4f deg VA   95%% cluster-bootstrap CI: [%.4f, %.4f]\n' ...
            '  Subjective center = %.4f deg VA   95%% cluster-bootstrap CI: [%.4f, %.4f]\n' ...
            '  Theoretical width = %.4f deg VA   Theoretical center = %.4f deg VA   (center bias = %.4f deg VA)\n'], ...
            cc.name, cc.peakX, cc.peakXCI(1), cc.peakXCI(2), cc.peakY, cc.peakYCI(1), cc.peakYCI(2), ...
            groupNames{c - 1}, cc.name, cc.pseLower, groupNames{c}, groupNames{c + 1}, cc.pseUpper, ...
            cc.width, cc.widthCI(1), cc.widthCI(2), cc.center, cc.centerCI(1), cc.centerCI(2), ...
            cc.widthTheoretical, cc.centerTheoretical, cc.centerBias);
    end
end

% ===========================================================================
% STEP 4: ORDINAL MODEL COMPARISON ON POOLED DATA (point estimate only).
% CAVEAT SPECIFIC TO THIS SCRIPT: the LR test below assumes trial-level
% independence. With pooled sessions, the EFFECTIVE sample size for that
% assumption is closer to nSessions than to nRowsPooled, so this p-value
% can be ANTICONSERVATIVE (too easily "significant") if there is
% intra-session correlation in the slope pattern. Treat it as a
% descriptive diagnostic and not a confirmatory test; the session-cluster-
% bootstrap CI on the boundaries (STEP 1-2 above) is the more trustworthy
% source of uncertainty in this script.
% ===========================================================================
ordinalModel = struct('available', false, 'note', '');
clusterCaveat = [' WARNING (specific to pooled data): this test assumes trial-level independence; ' ...
    'with pooled sessions the effective N is closer to nSessions than to nRowsPooled, so ' ...
    'this p-value can be ANTICONSERVATIVE (too easily significant). Treat as a descriptive ' ...
    'diagnostic, not a confirmatory test -- the cluster-bootstrap CI on the boundaries is the ' ...
    'more reliable uncertainty reference here.'];
if logical(opt.FitOrdinalModel) && nBoundaries >= 2
    try
        alpha0 = arrayfun(@(b) boundaryFits(b).fit.alpha, 1:nBoundaries);
        beta0  = arrayfun(@(b) boundaryFits(b).fit.beta,  1:nBoundaries);
        fitFree   = fitOrdinalMLE(xFitAll, rankFitAll, nCat, link, false, alpha0, beta0);
        fitShared = fitOrdinalMLE(xFitAll, rankFitAll, nCat, link, true,  alpha0, beta0);
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
        if pLR < 0.05
            veredicto = ['REJECTS shared slope (p<0.05) -- boundary slopes DO differ significantly in the pooled data.' clusterCaveat];
        else
            veredicto = ['DOES NOT reject shared slope (p>=0.05) -- consistent with "proportional odds" in the pooled data.' clusterCaveat];
        end
        ordinalModel.verdictText = veredicto;

        vprintf(verbose, ['\n--- Ordinal model comparison (POOLED data, %d sessions) ---\n' ...
            '  Unconstrained model (separate slopes):\n'], nSessions);
        for b = 1:nBoundaries
            vprintf(verbose, '    Boundary %d: alpha = %.4f deg VA, beta = %.4f deg VA\n', ...
                b, fitFree.alpha(b), fitFree.beta(b));
        end
        vprintf(verbose, '  Shared-slope model ("proportional odds"):\n    shared beta = %.4f deg VA\n', fitShared.beta(1));
        for b = 1:nBoundaries
            vprintf(verbose, '    Boundary %d: alpha (PSE) = %.4f deg VA\n', b, fitShared.alpha(b));
        end
        vprintf(verbose, ['  Likelihood-ratio test:\n    G = %.3f, df = %d, p = %.4f\n' ...
            '    -> %s\n'], Gstat, dfLR, pLR, veredicto);
    catch ME_ord
        ordinalModel = struct('available', false, ...
            'note', sprintf('Ordinal model fit (pooled) failed: %s', ME_ord.message));
        warning('AnalyzePsychometricCurvesMultiSession:ordinalModelFailed', '%s', ordinalModel.note);
    end
else
    if ~logical(opt.FitOrdinalModel)
        ordinalModel.note = 'FitOrdinalModel=false -- diagnostic skipped option.';
    else
        ordinalModel.note = 'Not applicable: >=2 boundaries (>=3 categories) are needed to compare shared vs. separate slopes.';
    end
end

% ===========================================================================
% PER-SESSION COMPARISON TABLE. You can run each session through the UNCHANGED
% single-session pipeline (AnalyzePsychometricCurves.m) independently, so
% PSE/slope/d'/c/etc. can be compared session-by-session. See header for
% why this matters BEFORE trusting the pooled curve above. A session
% failing here is reported as a warning and skipped from the table but it still
% contributes its trials to the pooled fit above regardless.
% ===========================================================================
comparisonRows = struct([]);
sessionResultsFull = cell(1, nSessions);
if logical(opt.RunPerSessionComparison)
    vprintf(verbose, '\n======= Per-session analysis (for comparison table) =======\n');
    for i = 1:nSessions
        try
            r = AnalyzePsychometricCurves(csvPaths{i}, ...
                'UseFirstAttemptOnly', opt.UseFirstAttemptOnly, ...
                'LinkFunction', opt.LinkFunction, ...
                'UseLapseRates', opt.UseLapseRates, ...
                'LapseMax', opt.LapseMax, ...
                'NBootstrap', opt.NBootstrap, ...
                'BootstrapAlpha', opt.BootstrapAlpha, ...
                'MakePlots', opt.PerSessionMakePlots, ...
                'FigureVisible', opt.FigureVisible, ...
                'FitOrdinalModel', opt.FitOrdinalModel, ...
                'OutDir', perSessionOutDir, ...
                'Verbose', verbose);
            sessionResultsFull{i} = r;
            comparisonRows = [comparisonRows, buildComparisonRow(r, i, S{i}.csvBase, nCat)]; %#ok<AGROW>
        catch ME_sess
            warning('AnalyzePsychometricCurvesMultiSession:sessionCompareFailed', ...
                'Per-session analysis of %s failed (%s): %s -- skipped from comparison table.', ...
                S{i}.csvBase, ME_sess.identifier, ME_sess.message);
        end
    end
else
    vprintf(verbose, '\n(RunPerSessionComparison=false -- per-session comparison table skipped.)\n');
end

% ===========================================================================
% CHRONOMETRIC CURVES (POOLED) -- target-onset -> cursor-enters-target
% vs. bar length, correct vs. error trials kept separate. Same statistical methods as the
% psychometric curves above and for the SAME reason: RT is also nested
% within session, so the CI here
% reuses the session-cluster bootstrap, not a naive per-bin SD/SEM computed
% straight off the pooled trials to avoid pseudoreplication.

% ===========================================================================
chronometric = struct('available', false, 'note', '');
try
    if nSessionsChrono < 1
        chronometric.note = 'No session has a resolved timing schema -- chronometric curve not generated.';
    elseif isempty(xChronoAll)
        chronometric.note = 'Timing schema resolved in at least 1 session, but 0 rows with valid timing -- chronometric curve not generated.';
    else
        xLevelsChrono = unique(xChronoAll);
        nLevelsChrono = numel(xLevelsChrono);
        meanTimeCorrect = nan(nLevelsChrono, 1);  nCorrect = zeros(nLevelsChrono, 1);
        meanTimeError   = nan(nLevelsChrono, 1);  nError   = zeros(nLevelsChrono, 1);
        for iLev = 1:nLevelsChrono
            rowsLev = (xChronoAll == xLevelsChrono(iLev));
            rowsC = rowsLev & (isCorrectChronoAll == 1);
            rowsE = rowsLev & (isCorrectChronoAll == 0);
            nCorrect(iLev) = nnz(rowsC);
            nError(iLev)   = nnz(rowsE);
            if nCorrect(iLev) > 0, meanTimeCorrect(iLev) = mean(timeToTargetAll(rowsC)); end
            if nError(iLev)   > 0, meanTimeError(iLev)   = mean(timeToTargetAll(rowsE)); end
        end

        if opt.NBootstrap > 0
            [ciCorrect, ciError] = chronometricSessionClusterBootstrap(xLevelsChrono, xChronoAll, ...
                timeToTargetAll, isCorrectChronoAll, sessionIdxChronoAll, nSessionsChrono, ...
                opt.NBootstrap, opt.BootstrapAlpha);
        else
            ciCorrect = nan(nLevelsChrono, 2);
            ciError   = nan(nLevelsChrono, 2);
        end

        chronometric.available = true;
        chronometric.timeDefinition = ['target-onset -> cursor enters target (DecisionTime_s + ' ...
            'ReactionTime_s in current rig terminology; see LoadSessionTrialData.m for era-aware ' ...
            'column resolution), reported in MILLISECONDS'];
        chronometric.timeUnits = 'ms';
        chronometric.xLevels = xLevelsChrono;
        chronometric.meanTimeCorrect = meanTimeCorrect;  chronometric.ciCorrect = ciCorrect;  chronometric.nCorrect = nCorrect;
        chronometric.meanTimeError   = meanTimeError;    chronometric.ciError   = ciError;    chronometric.nError   = nError;
        chronometric.nSessionsChrono = nSessionsChrono;
        chronometric.excludedSessions = chronoExcludedNames;
        chronometric.nBootstrap = opt.NBootstrap;

        vprintf(verbose, ['\n--- Chronometric curve (POOLED, %d of %d sessions) ---\n' ...
            '  Definition: %s\n'], nSessionsChrono, nSessions, chronometric.timeDefinition);
        for iLev = 1:nLevelsChrono
            vprintf(verbose, '  %.3f deg VA:  correct N=%3d mean=%7.1fms 95%%CI[%.1f,%.1f]   error N=%3d mean=%7.1fms 95%%CI[%.1f,%.1f]\n', ...
                xLevelsChrono(iLev), nCorrect(iLev), meanTimeCorrect(iLev), ciCorrect(iLev,1), ciCorrect(iLev,2), ...
                nError(iLev), meanTimeError(iLev), ciError(iLev,1), ciError(iLev,2));
        end
    end
catch ME_chrono
    chronometric = struct('available', false, ...
        'note', sprintf('Chronometric curve computation failed: %s', ME_chrono.message));
    warning('AnalyzePsychometricCurvesMultiSession:chronometricFailed', '%s', chronometric.note);
end

% ===========================================================================
% PACKAGE RESULTS + SAVE
% ===========================================================================
results = struct();
results.meta = opt;
results.meta.csvPaths = {csvPaths{:}};
results.meta.nSessions = nSessions;
results.meta.sessionBaseNames = cellfun(@(s) s.csvBase, S, 'UniformOutput', false);
results.meta.sessionN = sessionN;
results.meta.groupNames = {groupNames{:}};
results.meta.nCat = nCat;
results.meta.nRowsPooled = nRowsPooled;
results.boundary = boundaryFits;
results.category = category;
results.ordinalModel = ordinalModel;
results.perSessionComparison = comparisonRows;
results.perSessionFullResults = sessionResultsFull;
results.chronometric = chronometric;

matFile = fullfile(outDir, [poolBase '_psychometric_pooled.mat']);
save(matFile, 'results');
vprintf(verbose, '\nSaved: %s\n', matFile);

summaryFileB = fullfile(outDir, [poolBase '_psychometric_pooled_summary_boundaries.csv']);
writeBoundarySummaryCsvPooled(summaryFileB, boundaryFits, link, opt, nSessions, sessionN);
vprintf(verbose, 'Saved: %s\n', summaryFileB);

summaryFileC = fullfile(outDir, [poolBase '_psychometric_pooled_summary_categories.csv']);
writeCategorySummaryCsvPooled(summaryFileC, category, link, opt, nSessions);
vprintf(verbose, 'Saved: %s\n', summaryFileC);

if ordinalModel.available
    summaryFileO = fullfile(outDir, [poolBase '_psychometric_pooled_summary_ordinalmodel.csv']);
    writeOrdinalModelCsvPooled(summaryFileO, ordinalModel, nBoundaries, nSessions);
    vprintf(verbose, 'Saved: %s\n', summaryFileO);
end

compareFile = fullfile(outDir, [poolBase '_compare_sessions.csv']);
writeSessionComparisonCsv(compareFile, comparisonRows, groupNames, nCat);
vprintf(verbose, 'Saved: %s\n', compareFile);

if chronometric.available
    chronoFile = fullfile(outDir, [poolBase '_chronometric_pooled_summary.csv']);
    writeChronometricSummaryCsv(chronoFile, chronometric, nSessions);
    vprintf(verbose, 'Saved: %s\n', chronoFile);
end

if logical(opt.MakePlots)
    try
        makeCategoryPlots(category, outDir, poolBase, link, logical(opt.FigureVisible), nRowsPooled, nSessions);
        vprintf(verbose, 'Pooled figures saved to: %s\n', outDir);
    catch ME_plot
        warning('AnalyzePsychometricCurvesMultiSession:plotFailed', ...
            'Could not generate pooled figures (%s): %s', ME_plot.identifier, ME_plot.message);
    end
    if chronometric.available
        try
            makeChronometricPlot(chronometric, outDir, poolBase, logical(opt.FigureVisible), nSessions);
            vprintf(verbose, 'Chronometric figure saved to: %s\n', outDir);
        catch ME_plotChrono
            warning('AnalyzePsychometricCurvesMultiSession:chronometricPlotFailed', ...
                'Could not generate chronometric figure (%s): %s', ME_plotChrono.identifier, ME_plotChrono.message);
        end
    end
end
if logical(opt.MakePlots) && logical(opt.MakeComparisonPlots)
    try
        makeSessionComparisonPlots(comparisonRows, boundaryFits, outDir, poolBase, link, logical(opt.FigureVisible));
        vprintf(verbose, 'Session-comparison figures saved to: %s\n', outDir);
    catch ME_plot2
        warning('AnalyzePsychometricCurvesMultiSession:comparePlotFailed', ...
            'Could not generate session-comparison figures (%s): %s', ME_plot2.identifier, ME_plot2.message);
    end
end

vprintf(verbose, '\n=======================================================\n');
end % AnalyzePsychometricCurvesMultiSession


% =========================================================================
% LOCAL HELPER FUNCTIONS
% =========================================================================

function vprintf(verbose, varargin)
if verbose, fprintf(varargin{:}); end
end

function jb = sessionClusterBootstrap(x, rankVec, stimRankVec, sessionIdx, nSessions, nCat, link, ...
    useLapse, lapseMax, nBoot, alphaCI, xGrid)
% SESSIONCLUSTERBOOTSTRAP  Block/cluster bootstrap that resamples WHOLE
% SESSIONS with replacement.
%
% Also tracks Dprime/CriterionC per replicate (per boundary), so the pooled
% SDT numbers get a proper cluster-aware CI too, not just alpha/beta; the
% single-session script does not need this.
n = numel(x);
nBoundaries = nCat - 1;
alphaBoot = nan(nBoundaries, nBoot);
betaBoot = nan(nBoundaries, nBoot);
dprimeBoot = nan(nBoundaries, nBoot);
criterionBoot = nan(nBoundaries, nBoot);
categoryCurveBoot = cell(1, nCat);
peakXBoot = cell(1, nCat);
peakYBoot = cell(1, nCat);
for c = 1:nCat
    categoryCurveBoot{c} = nan(nBoot, numel(xGrid));
    peakXBoot{c} = nan(nBoot, 1);
    peakYBoot{c} = nan(nBoot, 1);
end

for i = 1:nBoot
    drawnSessions = randi(nSessions, nSessions, 1);   % this is the actual "cluster" resample step
    % A session drawn k times must contribute its trials k times (not just
    % once).
    % Built by explicit concatenation of row indices for exactly that reason.
    rowIdx = [];
    for s = 1:nSessions
        rowIdx = [rowIdx; find(sessionIdx == drawnSessions(s))]; %#ok<AGROW>
    end
    xRes = x(rowIdx);
    rankRes = rankVec(rowIdx);
    stimRankRes = stimRankVec(rowIdx);

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

            stimBinRes = double(stimRankRes >= (b + 1));
            nSig = nnz(stimBinRes == 1); nNz = nnz(stimBinRes == 0);
            hitsR = nnz(yBinRes == 1 & stimBinRes == 1);
            fasR  = nnz(yBinRes == 1 & stimBinRes == 0);
            HadjR = (hitsR + 0.5) / (nSig + 1);
            FadjR = (fasR  + 0.5) / (nNz + 1);
            zHR = linkInvCDF(HadjR, 'probit');
            zFR = linkInvCDF(FadjR, 'probit');
            dprimeBoot(b, i) = zHR - zFR;
            criterionBoot(b, i) = -0.5 * (zHR + zFR);
        catch
            % A wrong resample can make a fit
            % degenerate; skip the WHOLE replicate, not just this
            % boundary, same reasoning as jointBootstrap.
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
jb.dprimeCI = cell(1, nBoundaries);
jb.criterionCI = cell(1, nBoundaries);
for b = 1:nBoundaries
    jb.boundaryAlphaCI(b, :) = quantileNoTB(alphaBoot(b, :)', [loP, hiP]);
    jb.boundaryBetaCI(b, :) = quantileNoTB(betaBoot(b, :)', [loP, hiP]);
    jb.dprimeCI{b} = quantileNoTB(dprimeBoot(b, :)', [loP, hiP]);
    jb.criterionCI{b} = quantileNoTB(criterionBoot(b, :)', [loP, hiP]);
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
% Used when NBootstrap=0: same field layout as sessionClusterBootstrap's
% output, all-NaN, so downstream code needs no branching on whether the
% bootstrap ran.
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
        error('AnalyzePsychometricCurvesMultiSession:unknownLink', 'Unknown link function "%s".', link);
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
        error('AnalyzePsychometricCurvesMultiSession:unknownLink', 'Unknown link function "%s".', link);
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
if exitflag ~= 1
    warning('AnalyzePsychometricCurvesMultiSession:ordinalFitNoConverge', ...
        'The ordinal fit (sharedSlope=%d, pooled data) did not report clean fminsearch convergence (exitflag=%d).', ...
        sharedSlope, exitflag);
end
end

function s = curveSummary(xGrid, yGrid)
% Peak location/height only 
% curveSummary for the full methods (same function, kept in sync).
[peakY, iPk] = max(yGrid);
peakX = xGrid(iPk);
s = struct('peakX', peakX, 'peakY', peakY);
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

function row = buildComparisonRow(r, sessIdx, csvBase, nCat)
% Flattens one session's full AnalyzePsychometricCurves.m results struct
% into a single row of scalar fields for the comparison table; writeSessionComparisonCsv writes a
% "Boundary<b> = ..." / "Cat<c> = ..." legend as comment lines instead.
row = struct();
row.SessionIdx = sessIdx;
row.CsvFile = csvBase;
row.N = sum(r.boundary(1).n);
row.N_omission = r.meta.nOmission;
row.N_excludedRetry = r.meta.nExcludedRetry;
nBoundaries = nCat - 1;
for b = 1:nBoundaries
    fp = sprintf('Boundary%d_', b);
    row.([fp 'PSE']) = r.boundary(b).fit.alpha;
    row.([fp 'PSE_CIlo']) = r.boundary(b).thresholdCI(1);
    row.([fp 'PSE_CIhi']) = r.boundary(b).thresholdCI(2);
    row.([fp 'Slope']) = r.boundary(b).fit.beta;
    row.([fp 'Dprime']) = r.boundary(b).sdt.dprime;
    row.([fp 'CriterionC']) = r.boundary(b).sdt.criterion;
end
for c = 1:nCat
    cc = r.category(c);
    fp = sprintf('Cat%d_', c);
    if strcmp(cc.summaryType, 'threshold')
        row.([fp 'PSE']) = cc.threshold;
        row.([fp 'Slope']) = cc.slope;
        row.([fp 'PeakX']) = nan;
        row.([fp 'Width']) = nan;
        row.([fp 'Center']) = nan;
    else
        row.([fp 'PSE']) = nan;
        row.([fp 'Slope']) = nan;
        row.([fp 'PeakX']) = cc.peakX;
        row.([fp 'Width']) = cc.width;
        row.([fp 'Center']) = cc.center;
    end
end
if r.ordinalModel.available
    row.OrdinalLR_G = r.ordinalModel.LR.G;
    row.OrdinalLR_p = r.ordinalModel.LR.p;
else
    row.OrdinalLR_G = nan;
    row.OrdinalLR_p = nan;
end
end

function writeSessionComparisonCsv(fname, comparisonRows, groupNames, nCat)
fid = fopen(fname, 'w');
fprintf(fid, '# Categories (ascending order by true length): %s\n', strjoin(groupNames, ' < '));
nBoundaries = nCat - 1;
for b = 1:nBoundaries
    fprintf(fid, '# Boundary%d = %s | %s\n', b, strjoin(groupNames(1:b), '+'), strjoin(groupNames(b+1:end), '+'));
end
for c = 1:nCat
    fprintf(fid, '# Cat%d = %s\n', c, groupNames{c});
end
if isempty(comparisonRows)
    fprintf(fid, '# (no sessions in the table -- the individual analysis failed for all of them, or RunPerSessionComparison=false)\n');
    fclose(fid);
    return;
end
fn = fieldnames(comparisonRows);
fprintf(fid, '%s\n', strjoin(fn, ','));
for i = 1:numel(comparisonRows)
    vals = cell(1, numel(fn));
    for j = 1:numel(fn)
        v = comparisonRows(i).(fn{j});
        if ischar(v)
            vals{j} = v;
        elseif isnan(v)
            vals{j} = '';
        else
            vals{j} = sprintf('%.6g', v);
        end
    end
    fprintf(fid, '%s\n', strjoin(vals, ','));
end
fclose(fid);
end

function [ciCorrect, ciError] = chronometricSessionClusterBootstrap(xLevels, xAll, timeAll, isCorrectAll, ...
    sessionIdxAll, nSessionsChrono, nBoot, alphaCI)
% CHRONOMETRICSESSIONCLUSTERBOOTSTRAP  Same resampling unit as
% sessionClusterBootstrap above 
nLevels = numel(xLevels);
meanBootC = nan(nBoot, nLevels);
meanBootE = nan(nBoot, nLevels);
for i = 1:nBoot
    drawnSessions = randi(nSessionsChrono, nSessionsChrono, 1);
    rowIdx = [];
    for s = 1:nSessionsChrono
        rowIdx = [rowIdx; find(sessionIdxAll == drawnSessions(s))]; %#ok<AGROW>
    end
    xRes = xAll(rowIdx);  tRes = timeAll(rowIdx);  cRes = isCorrectAll(rowIdx);
    for iLev = 1:nLevels
        rowsLev = (xRes == xLevels(iLev));
        rowsC = rowsLev & (cRes == 1);
        rowsE = rowsLev & (cRes == 0);
        if any(rowsC), meanBootC(i, iLev) = mean(tRes(rowsC)); end
        if any(rowsE), meanBootE(i, iLev) = mean(tRes(rowsE)); end
    end
end
loP = alphaCI / 2; hiP = 1 - alphaCI / 2;
ciCorrect = quantileNoTB(meanBootC, [loP, hiP], 1);
ciError   = quantileNoTB(meanBootE, [loP, hiP], 1);
end

function writeChronometricSummaryCsv(fname, chrono, nSessions)
fid = fopen(fname, 'w');
fprintf(fid, '# %s\n', chrono.timeDefinition);
fprintf(fid, '# NSessionsChrono=%d of %d total', chrono.nSessionsChrono, nSessions);
if ~isempty(chrono.excludedSessions)
    fprintf(fid, ' -- excluded (unresolved timing schema): %s', strjoin(chrono.excludedSessions, '; '));
end
fprintf(fid, '\n');
fprintf(fid, 'BarSizeVA_deg,N_Correct,MeanTime_Correct_ms,CI_lo_Correct_ms,CI_hi_Correct_ms,N_Error,MeanTime_Error_ms,CI_lo_Error_ms,CI_hi_Error_ms,NClusterBootstrap\n');
for iLev = 1:numel(chrono.xLevels)
    fprintf(fid, '%.6f,%d,%.6f,%.6f,%.6f,%d,%.6f,%.6f,%.6f,%d\n', ...
        chrono.xLevels(iLev), chrono.nCorrect(iLev), chrono.meanTimeCorrect(iLev), ...
        chrono.ciCorrect(iLev,1), chrono.ciCorrect(iLev,2), ...
        chrono.nError(iLev), chrono.meanTimeError(iLev), ...
        chrono.ciError(iLev,1), chrono.ciError(iLev,2), chrono.nBootstrap);
end
fclose(fid);
end

function makeChronometricPlot(chrono, outDir, poolBase, figVisible, nSessions)
% One figure: mean time-to-target (target-onset -> cursor-entra-al-target)
% vs. bar length, correct trials vs. error trials as two separate series, each with its session-cluster-bootstrap
% IC95% band.
if figVisible, visStr = 'on'; else, visStr = 'off'; end
x = chrono.xLevels;
fig = figure('Visible', visStr, 'Position', [100 100 720 480]);
hold on;
colCorrect = [0.10 0.45 0.75];
colError   = [0.80 0.25 0.15];
legendH = [];  legendLabels = {};

hasC = ~all(isnan(chrono.meanTimeCorrect));
hasE = ~all(isnan(chrono.meanTimeError));

if hasC && ~all(isnan(chrono.ciCorrect(:)))
    okC = ~isnan(chrono.ciCorrect(:,1)) & ~isnan(chrono.ciCorrect(:,2));
    if any(okC)
        xFill = [x(okC); flipud(x(okC))];
        yFill = [chrono.ciCorrect(okC,1); flipud(chrono.ciCorrect(okC,2))];
        fill(xFill, yFill, colCorrect, 'EdgeColor', 'none', 'FaceAlpha', 0.20);
    end
end
if hasE && ~all(isnan(chrono.ciError(:)))
    okE = ~isnan(chrono.ciError(:,1)) & ~isnan(chrono.ciError(:,2));
    if any(okE)
        xFill = [x(okE); flipud(x(okE))];
        yFill = [chrono.ciError(okE,1); flipud(chrono.ciError(okE,2))];
        fill(xFill, yFill, colError, 'EdgeColor', 'none', 'FaceAlpha', 0.20);
    end
end
if hasC
    hC = plot(x, chrono.meanTimeCorrect, '-o', 'Color', colCorrect, ...
        'MarkerFaceColor', colCorrect, 'MarkerEdgeColor', 'k', 'LineWidth', 2, 'MarkerSize', 6);
    legendH = [legendH, hC];  legendLabels{end+1} = sprintf('correcto (N=%d)', sum(chrono.nCorrect));
end
if hasE
    hE = plot(x, chrono.meanTimeError, '--s', 'Color', colError, ...
        'MarkerFaceColor', colError, 'MarkerEdgeColor', 'k', 'LineWidth', 2, 'MarkerSize', 6);
    legendH = [legendH, hE];  legendLabels{end+1} = sprintf('error (N=%d)', sum(chrono.nError));
end
xlabel('Bar length (deg VA)');
ylabel('Target-onset -> cursor-in-target time (ms)');
title(sprintf('Pooled chronometric curve (%d of %d sessions) -- 95%% cluster-bootstrap CI per session', ...
    chrono.nSessionsChrono, nSessions), 'Interpreter', 'none');
grid on; box on;
if ~isempty(legendH)
    legend(legendH, legendLabels, 'Location', 'best');
end
outFile = fullfile(outDir, sprintf('%s_chronometric_pooled.png', poolBase));
try
    print(fig, outFile, '-dpng', '-r150');
catch
    saveas(fig, outFile);
end
if ~figVisible, close(fig); end
end

function writeBoundarySummaryCsvPooled(fname, boundaryFits, link, opt, nSessions, sessionN)
fid = fopen(fname, 'w');
fprintf(fid, '# NSessions=%d, SessionTrialCounts=%s\n', nSessions, strrep(mat2str(sessionN), ',', ';'));
fprintf(fid, ['Boundary,LinkFunction,N,Threshold_alpha_degVA,ThresholdCI_lo,ThresholdCI_hi,' ...
    'Slope_beta_degVA,SlopeCI_lo,SlopeCI_hi,Width50to84_degVA,Gamma,Lambda,' ...
    'AIC,DevianceG,DevianceDF,DeviancePvalue,' ...
    'Hraw,Fraw,Hits,Nsignal,FalseAlarms,Nnoise,Dprime,DprimeCI_lo,DprimeCI_hi,CriterionC,CriterionCI_lo,CriterionCI_hi,' ...
    'NClusterBootstrap,UseFirstAttemptOnly\n']);
for b = 1:numel(boundaryFits)
    bb = boundaryFits(b);
    sdt = bb.sdt;
    fprintf(fid, '%s,%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.4f,%.4f,%d,%.4f,%.6f,%.6f,%d,%d,%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d\n', ...
        bb.name, link, sum(bb.n), bb.fit.alpha, bb.thresholdCI(1), bb.thresholdCI(2), ...
        bb.fit.beta, bb.slopeCI(1), bb.slopeCI(2), bb.fit.width50to84, bb.fit.gamma, bb.fit.lambda, ...
        bb.fit.aic, bb.goodnessOfFit.G, bb.goodnessOfFit.df, bb.goodnessOfFit.p, ...
        sdt.Hraw, sdt.Fraw, sdt.hits, sdt.nSignal, sdt.falseAlarms, sdt.nNoise, ...
        sdt.dprime, bb.dprimeCI(1), bb.dprimeCI(2), sdt.criterion, bb.criterionCI(1), bb.criterionCI(2), ...
        bb.nBootstrap, logical(opt.UseFirstAttemptOnly));
end
fclose(fid);
end

function writeCategorySummaryCsvPooled(fname, category, link, opt, nSessions)
fid = fopen(fname, 'w');
fprintf(fid, '# NSessions=%d\n', nSessions);
fprintf(fid, ['Category,SummaryType,LinkFunction,N,' ...
    'PSE_50pct_degVA,PSE_CI_lo,PSE_CI_hi,Slope_degVA,SlopeCI_lo,SlopeCI_hi,' ...
    'PeakX_degVA,PeakXCI_lo,PeakXCI_hi,PeakY,PeakYCI_lo,PeakYCI_hi,' ...
    'PSElower_degVA,PSEupper_degVA,Width_degVA,WidthCI_lo,WidthCI_hi,' ...
    'Center_degVA,CenterCI_lo,CenterCI_hi,NBootstrap,UseFirstAttemptOnly\n']);
for c = 1:numel(category)
    cc = category(c);
    if strcmp(cc.summaryType, 'threshold')
        fprintf(fid, '%s,threshold,%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,,,,,,,,,,,,,,,%d,%d\n', ...
            cc.name, link, sum(cc.n), cc.threshold, cc.thresholdCI(1), cc.thresholdCI(2), ...
            cc.slope, cc.slopeCI(1), cc.slopeCI(2), cc.nBootstrap, logical(opt.UseFirstAttemptOnly));
    else
        fprintf(fid, '%s,peak,%s,%d,,,,,,,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d\n', ...
            cc.name, link, sum(cc.n), cc.peakX, cc.peakXCI(1), cc.peakXCI(2), ...
            cc.peakY, cc.peakYCI(1), cc.peakYCI(2), ...
            cc.pseLower, cc.pseUpper, cc.width, cc.widthCI(1), cc.widthCI(2), ...
            cc.center, cc.centerCI(1), cc.centerCI(2), ...
            cc.nBootstrap, logical(opt.UseFirstAttemptOnly));
    end
end
fclose(fid);
end

function writeOrdinalModelCsvPooled(fname, ordinalModel, nBoundaries, nSessions)
fid = fopen(fname, 'w');
fprintf(fid, '# NSessions=%d -- see ordinalModel.verdictText / this LR_test row for the clustering caveat\n', nSessions);
fprintf(fid, 'Model,Boundary,Alpha_PSE_degVA,Beta_degVA,NLL,NParams,LR_G,LR_df,LR_p,Verdict\n');
fu = ordinalModel.unconstrained;
fs = ordinalModel.proportionalOdds;
lr = ordinalModel.LR;
for b = 1:nBoundaries
    fprintf(fid, 'unconstrained_separate_slopes,%d,%.6f,%.6f,%.4f,%d,,,,\n', ...
        b, fu.alpha(b), fu.beta(b), fu.nll, fu.nParams);
end
for b = 1:nBoundaries
    fprintf(fid, 'proportional_odds_shared_slope,%d,%.6f,%.6f,%.4f,%d,,,,\n', ...
        b, fs.alpha(b), fs.beta(b), fs.nll, fs.nParams);
end
fprintf(fid, 'LR_test,,,,,,%.4f,%d,%.6f,"%s"\n', lr.G, lr.df, lr.p, strrep(ordinalModel.verdictText, '"', ''''));
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

function makeCategoryPlots(category, outDir, csvBase, link, figVisible, nTrialsUsed, nSessions)
% Same visual params as AnalyzePsychometricCurves.m's makeCategoryPlots
% (point coloring by TRUE category, PSE stars, chance-level reference,
% width/center delimitation for interior categories) duplicated here
% (see this file's header), with overview titles additionally
% reporting nSessions so a saved .png is labeled as a POOLED result,
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
        legendH = [legendH, hFill];  legendLabels{end+1} = '95% cluster-bootstrap CI';
    end
    hCurve = plot(cc.curveX, cc.curveY, '-', 'Color', colors(c, :) * 0.75, 'LineWidth', 2);
    legendH = [legendH, hCurve];  legendLabels{end+1} = 'Fitted curve (pooled)';
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
        ttlLine1 = sprintf('%s vs. %s', cc.name, strjoin({category(setdiff(1:nCat, c)).name}, '+'));
        ttlLine2 = sprintf('Sessions: %d  |  Trials: %d', nSessions, nTrialsUsed);
        title({ttlLine1, ttlLine2}, 'Interpreter', 'none');
    else
        % --- Mid (interior) category: peak + teal theoretical boundaries only ---
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
        ttlLine2 = sprintf('Sessions: %d  |  Trials: %d', nSessions, nTrialsUsed);
        title({ttlLine1, ttlLine2}, 'Interpreter', 'none');
    end
    xlabel('Bar length (deg VA)');
    ylabel(sprintf('P(response = %s)', cc.name));
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

% --- Overview (graphic with ALL curves together) ---
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
% Teal theoretical boundaries for interior (Mid) categories
for c = 1:nCat
    cc = category(c);
    if strcmp(cc.summaryType, 'peak') && ~isnan(cc.pseLowerTheoretical) && ~isnan(cc.pseUpperTheoretical)
        plot([cc.pseLowerTheoretical cc.pseLowerTheoretical], [0 1], '--', 'Color', theoColor, 'LineWidth', 1);
        plot([cc.pseUpperTheoretical cc.pseUpperTheoretical], [0 1], '--', 'Color', theoColor, 'LineWidth', 1);
        plot(cc.centerTheoretical, 0.02, 'v', 'MarkerSize', 8, ...
            'MarkerFaceColor', theoColor, 'MarkerEdgeColor', 'k');
    end
end
xlabel('Bar length (deg VA)');
ylabel('P(response = category)');
catNames = strjoin({category.name}, ' vs ');
ttlLine1 = catNames;
ttlLine2 = sprintf('Sessions: %d  |  Trials: %d', nSessions, nTrialsUsed);
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

function makeSessionComparisonPlots(comparisonRows, boundaryFits, outDir, poolBase, link, figVisible)
% One figure PER BOUNDARY: each session's own PSE (with ITS OWN
% single-session bootstrap CI, from the per-session comparison table)
% plotted against the POOLED estimate's session-cluster-bootstrap band: check sessions with error bars too far apart in the pooling
if isempty(comparisonRows)
    return;
end
if figVisible, visStr = 'on'; else, visStr = 'off'; end
nBoundaries = numel(boundaryFits);
nSess = numel(comparisonRows);
sessLabels = {comparisonRows.CsvFile};
for b = 1:nBoundaries
    fieldPSE = sprintf('Boundary%d_PSE', b);
    fieldLo  = sprintf('Boundary%d_PSE_CIlo', b);
    fieldHi  = sprintf('Boundary%d_PSE_CIhi', b);
    pseVals = arrayfun(@(r) r.(fieldPSE), comparisonRows);
    pseLo   = arrayfun(@(r) r.(fieldLo), comparisonRows);
    pseHi   = arrayfun(@(r) r.(fieldHi), comparisonRows);
    errLo = pseVals - pseLo;
    errHi = pseHi - pseVals;
    sessX = 1:nSess;

    fig = figure('Visible', visStr, 'Position', [100 100 760 480]);
    hold on;
    poolCI = boundaryFits(b).thresholdCI;
    poolPSE = boundaryFits(b).fit.alpha;
    xFillB = [0.5, nSess + 0.5, nSess + 0.5, 0.5];
    yFillB = [poolCI(1), poolCI(1), poolCI(2), poolCI(2)];
    fill(xFillB, yFillB, [0.80 0.80 0.95], 'EdgeColor', 'none', 'FaceAlpha', 0.7);
    plot([0.5, nSess + 0.5], [poolPSE poolPSE], '-', 'Color', [0.15 0.15 0.55], 'LineWidth', 2);
    hSess = errorbar(sessX, pseVals, errLo, errHi, 'o');
    set(hSess, 'Color', [0.1 0.1 0.1], 'MarkerFaceColor', [0.9 0.45 0.1], ...
        'MarkerEdgeColor', 'k', 'MarkerSize', 7, 'LineWidth', 1.3);
    xlim([0.5, nSess + 0.5]);
    try
        set(gca, 'XTick', sessX, 'XTickLabel', sessLabels, 'XTickLabelRotation', 45);
    catch
        set(gca, 'XTick', sessX, 'XTickLabel', sessLabels);
    end
    xlabel('Session');
    ylabel(sprintf('Boundary %d PSE (deg VA)', b));

    title(sprintf('Boundary %d: %s -- pooled %.3f [%.3f, %.3f] 95%% cluster-bootstrap CI (blue band) vs. each session (orange)', ...
        b, boundaryFits(b).name, poolPSE, poolCI(1), poolCI(2)), 'Interpreter', 'none');
    grid on; box on;
    outFile = fullfile(outDir, sprintf('%s_compare_boundary%d_%s.png', poolBase, b, link));
    try
        print(fig, outFile, '-dpng', '-r150');
    catch
        saveas(fig, outFile);
    end
    if ~figVisible, close(fig); end
end
end

function xr = xlim_safe2(x)
xr = [min(x), max(x)];
end
