function results = AnalyzePsychometricCurves(csvPath, varargin)
% ANALYZEPSYCHOMETRICCURVES  Fit categorization ("psychometric") curves
% from a CenterOutTask.m trial_data_*.csv file (bar-length categorization,
% Short/Mid/Long or Short/Long) -- one curve per category, one-vs-rest:
% P(respond Short) vs length, P(respond Mid) vs length, P(respond Long) vs
% length (2 curves instead of 3 for a 2-category session).
%
%   WHY NOT 3 INDEPENDENT SIGMOID FITS
%   ------------------------------------------------------------------

%   1) THE MIDDLE CATEGORY IS NOT MONOTONIC. P(respond Mid) is near 0 for
%      short bars, rises to a peak somewhere in the middle of the length
%      range, and falls back to near 0 for long bars, not an
%      S-curve. A monotonic sigmoid (logistic or probit) cannot represent
%      that shape: forced onto bump-shaped data it will either fail to
%      converge or converge to a meaningless alpha/beta. Mid's curve needs
%      a different summary (peak location, peak height, width), not a
%      threshold+slope -- see below.
%
%   2) THREE INDEPENDENTLY-FIT CURVES ARE NOT A VALID PROBABILITY MODEL.
%      Fit separately, nothing forces P(Short)+P(Mid)+P(Long) = 1 at a
%      given bar length, each fit only sees its own binary outcome and
%      knows nothing about the other two. With finite samples the three
%      curves can visibly disagree (e.g. sum to 1.08 at some length),
%      which makes the three curves harder to
%      compare honestly against each other.
%
%   Fit only the (nCat-1) ORDINAL CUMULATIVE boundaries
%   P(response >= Mid), P(response >= Long), etc., each of which is
%   monotonic, then DERIVE all nCat one-vs-rest
%   category curves from them:
%       P(Short) = 1 - P(response >= Mid)
%       P(Mid)   = P(response >= Mid) - P(response >= Long)
%       P(Long)  = P(response >= Long)
%   which sums to 1 at every bar length BY CONSTRUCTION.


%
%   NO STATISTICS/OPTIMIZATION TOOLBOX IS USED. itting uses fminsearch (base MATLAB) on the binomial
%   negative log-likelihood, not glmfit/mnrfit/fitglm/nlinfit. 
%
%   INPUT
%     csvPath : path to a trial_data_*.csv from CenterOutTask.m. Column
%               names are resolved by content not by exact position, so
%               this tolerates the naming variant actually seen in this
%               project's real output files (e.g. 'BarSizeVA_deg') as well
%               as the plain-name variant documented in CenterOutTask.m's
%               own fprintf header comment (e.g. 'BarSizeVA').
%
%   NAME-VALUE OPTIONS
%     'UseFirstAttemptOnly' (default true)     -- see (1) above
%     'LinkFunction'        (default 'logistic') -- 'logistic' | 'probit'
%     'UseLapseRates'       (default false)    -- see (3) above
%     'LapseMax'            (default 0.10)     -- cap on gamma/lambda each, only used if UseLapseRates=true
%     'NBootstrap'          (default 1000)     -- joint bootstrap reps for CIs; 0 disables
%     'BootstrapAlpha'      (default 0.05)     -- 95% CI
%     'MakePlots'           (default true)     -- false skips figures entirely (still writes .mat/.csv)
%     'FigureVisible'       (default true)     -- true pops up each figure window AND saves it as .png;
%                                                  set false for batch loops over many sessions --
%                                                  the .png is still written either way.
%     'FitOrdinalModel'     (default true)     -- see STEP 4 below
%     'OutDir'              (default: <csv folder>/psychometric_analysis)
%     'Verbose'             (default true)

%   USAGE
%     results = AnalyzePsychometricCurves('trial_data_sessROM_31Jul2026_1605.csv');
%     results = AnalyzePsychometricCurves(csvPath, 'UseFirstAttemptOnly', false, ...
%                                          'NBootstrap', 2000, 'LinkFunction', 'probit');


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
addParameter(p, 'ChronometricTimeSource', 'TargetReached', @(s) ischar(s) || iscell(s) || isstring(s));
parse(p, csvPath, varargin{:});
opt = p.Results;
csvPath = char(opt.csvPath);
link = lower(opt.LinkFunction);
verbose = logical(opt.Verbose);

if ~exist(csvPath, 'file')
    error('AnalyzePsychometricCurves:fileNotFound', 'CSV not found: %s', csvPath);
end

[csvDir, csvBase, ~] = fileparts(csvPath);
if isempty(opt.OutDir)
    outDir = fullfile(csvDir, 'psychometric_analysis');
else
    outDir = char(opt.OutDir);
end
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

vprintf(verbose, '\n======= AnalyzePsychometricCurves: %s =======\n', csvBase);

% ===========================================================================
% LOAD + RESOLVE COLUMNS + CATEGORY STRUCTURE + EXCLUSIONS
% ===========================================================================
% Delegated to LoadSessionTrialData.m (MUST be on the path alongside this
% file) so AnalyzePsychometricCurvesMultiSession.m can load each session
% with EXACTLY this same logic when pooling several sessions together --
% see that function's own header for why a shared loader matters here
% (same ChosenTarget-code-learning / exclusion edge cases must apply
% identically to every session being pooled, not just the first one).
S = LoadSessionTrialData(csvPath, logical(opt.UseFirstAttemptOnly), verbose, opt.ChronometricTimeSource);
groupNames = S.groupNames;  groupCode = S.groupCode;  nCat = S.nCat;
nRowsRaw = S.nRowsRaw;  nRows = S.nRows;
nOmission = S.nOmission;  nExcludedRetry = S.nExcludedRetry;  nUnexpected = S.nUnexpected;
xFit = S.xFit;  rankFit = S.rankFit;  stimRankFit = S.stimRankFit;  dirFit = S.dirFit;

% QC: crude spatial-bias screen -- proportion of "chose highest category"
% broken down by chosen direction; large imbalance is a flag to
% investigate, not a formal test (see header note 4).
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
% STEP 1: FIT THE (nCat-1) ORDINAL CUMULATIVE BOUNDARIES
% ===========================================================================
nBoundaries = nCat - 1;
boundaryFits = struct([]);
for b = 1:nBoundaries
    lowName  = strjoin(groupNames(1:b), '+');
    highName = strjoin(groupNames(b+1:end), '+');
    yBin = double(rankFit >= (b + 1));   % 1 = responded at/above this boundary

    [xLevels, k, n] = aggregateByLevel(xFit, yBin);
    fit = fitSigmoidMLE(xFit, yBin, link, logical(opt.UseLapseRates), opt.LapseMax);
    gof = goodnessOfFitDeviance(xLevels, k, n, fit, link);

    % --- Signal detection theory (SDT): d' and criterion c -----------------
    % EMPIRICAL/nonparametric calculation for this boundary (does not depend
    % on the sigmoid fitted above, uses raw counts):
    %   "Signal" = TRUE category (StimulusGroup) on the HIGH side of this
    %              boundary (rank >= b+1)
    %   "Noise"  = TRUE category on the LOW side (rank <= b)
    %   "Yes"   (response) = the monkey responded on the high side
    %                        (rankFit>=b+1)
    %   H (Hit rate)  = P(responds high | truth = high)
    %   F (FA rate)   = P(responds high | truth = low)
    %   d' = z(H) - z(F)      -- z = the standard NORMAL quantile ALWAYS, by
    %                            the definition of d' in SDT, regardless of
    %                            whether the fit's 'LinkFunction' is logistic
    %   c  = -0.5*(z(H)+z(F)) -- c=0 no bias; c>0 bias toward responding the
    %                            LOW side (conservative); c<0 bias toward
    %                            the HIGH side (liberal).
    %   Log-linear correction (Hautus, 1995: +0.5 numerator, +1 denominator)
    %   is ALWAYS applied before z(), to avoid z(0)=-Inf / z(1)=+Inf with a
    %   small N per level -- the UNcorrected H/F (Hraw/Fraw) are also
    %   reported for auditing.
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

    % --- Theoretical (design) PSE for this boundary -------------------------
    % The midpoint between the LARGEST bar length presented for
    % the lower TRUE category (StimulusGroup) and the SMALLEST bar length
    % presented for the next category up. This depends ONLY on which physical
    % stimuli you assigned to each category; it does NOT use
    % the subject's responses at all, unlike fit.alpha above (the OBSERVED/
    % behavioral PSE, i.e. where the subject's own choices cross 50%). The
    % difference (observed - theoretical) is a direct measure of the
    % subject's categorization bias at this boundary.
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
% STEP 2: JOINT BOOTSTRAP: one resample of trial rows per replicate,
% refitting ALL boundaries from that SAME resample.
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
        '  Observed PSE (alpha, 50%% crossing): %.4f deg VA   95%% bootstrap CI: [%.4f, %.4f]\n' ...
        '  Slope (beta, scale):                %.4f deg VA   95%% bootstrap CI: [%.4f, %.4f]\n' ...
        '  Theoretical PSE (design boundary):  %.4f deg VA   (midpoint between %.4f and %.4f)\n' ...
        '  Bias (observed - theoretical):      %.4f deg VA\n' ...
        '  Goodness of fit: G = %.3f, df = %d, p = %.4f  (small p = the model does not explain the data well)\n' ...
        '  --- SDT (empirical, does not depend on the sigmoid) ---\n' ...
        '  Hit rate  H = %.4f (%d/%d)   False alarm F = %.4f (%d/%d)   (H,F uncorrected)\n' ...
        '  d'' = %.4f   criterion c = %.4f  (c=0 no bias; c>0 bias toward "%s"; c<0 bias toward "%s")\n'], ...
        b, boundaryFits(b).name, sum(boundaryFits(b).n), boundaryFits(b).fit.alpha, ...
        jb.boundaryAlphaCI(b, 1), jb.boundaryAlphaCI(b, 2), boundaryFits(b).fit.beta, ...
        jb.boundaryBetaCI(b, 1), jb.boundaryBetaCI(b, 2), ...
        boundaryFits(b).theoreticalPSE, boundaryFits(b).theoreticalLowerMax, boundaryFits(b).theoreticalUpperMin, ...
        boundaryFits(b).fit.alpha - boundaryFits(b).theoreticalPSE, ...
        boundaryFits(b).goodnessOfFit.G, ...
        boundaryFits(b).goodnessOfFit.df, boundaryFits(b).goodnessOfFit.p, ...
        sdt.Hraw, sdt.hits, sdt.nSignal, sdt.Fraw, sdt.falseAlarms, sdt.nNoise, ...
        sdt.dprime, sdt.criterion, boundaryFits(b).lowLabel, boundaryFits(b).highLabel);
end

% ===========================================================================
% STEP 3: DERIVE THE nCat ONE-VS-REST CATEGORY CURVES (the 3 curves)
%  FROM THE BOUNDARY FITS -- P(Short)=1-G1, P(Mid)=G1-G2,
% P(Long)=G2, generalized to any nCat via allCumulativeCurves/
% categoryCurvesFromG below.
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

    % Dominant TRUE category at each bar length (mode of stimRankFit among
    % trials at that length)
    xLevelTrueRank = nan(size(xLevels));
    for iLev = 1:numel(xLevels)
        xLevelTrueRank(iLev) = mode(stimRankFit(xFit == xLevels(iLev)));
    end

    % NOTE: cc must end up with the SAME set of fields regardless of
    % summaryType ('threshold' vs 'peak'), otherwise concatenating into the
    % `category` struct array below fails ("field names mismatch in
    % concatenating structs"). So every field from BOTH branches is
    % pre-declared here (NaN/empty placeholder), and each branch only
    % overwrites the ones that apply to it.
    cc = struct();
    cc.name = groupNames{c};
    cc.rank = c;
    cc.xLevels = xLevels;  cc.k = k;  cc.n = n;  cc.propObs = k ./ n;
    cc.propWilsonLo = wLo;  cc.propWilsonHi = wHi;
    cc.xLevelTrueRank = xLevelTrueRank;
    catBars = xLevels(xLevelTrueRank == c);
    if isempty(catBars)
        catBars = xLevels;
    end
    cc.stimLevels = catBars;
    cc.stimMin = min(catBars);
    cc.stimMax = max(catBars);
    cc.curveX = xGrid;  cc.curveY = Ppoint(:, c);
    cc.curveLo = jb.categoryLo{c};  cc.curveHi = jb.categoryHi{c};
    cc.nBootstrap = jb.nBoot;

    % Placeholders for the 'threshold' branch's fields:
    cc.threshold = NaN;  cc.thresholdCI = [NaN NaN];
    cc.slope = NaN;      cc.slopeCI = [NaN NaN];
    cc.theoreticalThreshold = NaN;  cc.thresholdBias = NaN;
    % Placeholders for the 'peak' branch's fields:
    cc.peakX = NaN;  cc.peakXCI = [NaN NaN];
    cc.peakY = NaN;  cc.peakYCI = [NaN NaN];
    % Placeholders for the interior-category "width/center" fields (the
    % subjective width/center of the interior category, delimited by the
    % OBSERVED PSE of its 2 neighboring boundaries) and their THEORETICAL
    % (design-boundary) counterparts. Only apply to interior categories
    % (2..nCat-1); left as NaN on edge categories.
    cc.pseLower = NaN;  cc.pseUpper = NaN;
    cc.width = NaN;     cc.widthCI = [NaN NaN];
    cc.center = NaN;    cc.centerCI = [NaN NaN];
    cc.pseLowerTheoretical = NaN;  cc.pseUpperTheoretical = NaN;
    cc.widthTheoretical = NaN;     cc.centerTheoretical = NaN;
    cc.centerBias = NaN;
    cc.goodnessOfFit = struct('G', NaN, 'df', NaN, 'p', NaN);
    cc.summaryType = '';

    if c == 1
        % Edge category (lowest rank): its curve is exactly 1 - boundary 1
        % (mirror image), so it is monotonic and has a well-defined
        % threshold/slope, both inherited directly from boundary 1.
        cc.summaryType = 'threshold';
        cc.threshold = boundaryFits(1).fit.alpha;
        cc.thresholdCI = jb.boundaryAlphaCI(1, :);
        cc.slope = boundaryFits(1).fit.beta;
        cc.slopeCI = jb.boundaryBetaCI(1, :);
        cc.goodnessOfFit = boundaryFits(1).goodnessOfFit;
        cc.theoreticalThreshold = boundaryFits(1).theoreticalPSE;
        cc.thresholdBias = cc.threshold - cc.theoreticalThreshold;
    elseif c == nCat
        % Edge category (highest rank): its curve IS boundary(end) exactly
        % (P(response>=nCat) is the same event as P(response==nCat), the
        % top category), so likewise monotonic with a direct threshold/slope.
        cc.summaryType = 'threshold';
        cc.threshold = boundaryFits(end).fit.alpha;
        cc.thresholdCI = jb.boundaryAlphaCI(end, :);
        cc.slope = boundaryFits(end).fit.beta;
        cc.slopeCI = jb.boundaryBetaCI(end, :);
        cc.goodnessOfFit = boundaryFits(end).goodnessOfFit;
        cc.theoreticalThreshold = boundaryFits(end).theoreticalPSE;
        cc.thresholdBias = cc.threshold - cc.theoreticalThreshold;
    else
        % Interior category (e.g. Mid): non-monotonic bump.
        % No single formal goodness-of-fit test is computed here -- the
        % curve is a DERIVED quantity (difference of 2 independently-
        % parameterized boundaries), not itself a single fitted binomial
        % model, so the usual deviance df-accounting does not cleanly
        % apply.
        cc.summaryType = 'peak';
        s = curveSummary(xGrid, Ppoint(:, c));
        cc.peakX = s.peakX;  cc.peakY = s.peakY;
        cc.peakXCI = jb.categoryPeakXCI{c};
        cc.peakYCI = jb.categoryPeakYCI{c};
        cc.goodnessOfFit = struct('G', nan, 'df', nan, 'p', nan);

        % --- Subjective width/center (observed + theoretical) --------------
        % Delimits the interior category with the OBSERVED PSE (50%
        % crossing) of its 2 neighboring boundaries: boundary(c-1) is the
        % LOWER boundary (this category vs. the one below) and boundary(c)
        % is the UPPER boundary (this category vs. the one above).The THEORETICAL PSE
        % does the exact same thing using each boundary's design PSE
        % (.theoreticalPSE) instead of its fitted alpha.
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
        vprintf(verbose, ['\n--- Category: %s (vs. rest) ---\n' ...
            '  Observed PSE (50%%):   %.4f deg VA   95%% bootstrap CI: [%.4f, %.4f]\n' ...
            '  Slope:                %.4f deg VA   95%% bootstrap CI: [%.4f, %.4f]\n' ...
            '  Theoretical PSE:      %.4f deg VA   (bias = observed - theoretical = %.4f deg VA)\n'], ...
            cc.name, cc.threshold, cc.thresholdCI(1), cc.thresholdCI(2), ...
            cc.slope, cc.slopeCI(1), cc.slopeCI(2), cc.theoreticalThreshold, cc.thresholdBias);
    else
        vprintf(verbose, ['\n--- Category: %s (vs. rest) ---\n' ...
            '  Peak:  x = %.4f deg VA  95%% CI: [%.4f, %.4f]   P(max) = %.3f  95%% CI: [%.3f, %.3f]\n' ...
            '  (non-monotonic curve -- a "threshold" or a formal goodness of fit does not apply here;\n' ...
            '   check it against the empirical points in the saved figure instead.)\n' ...
            '  --- Delimitation by neighboring PSE (observed) ---\n' ...
            '  Lower PSE (%s|%s+...): %.4f deg VA\n' ...
            '  Upper PSE (...+%s|%s): %.4f deg VA\n' ...
            '  Subjective width  = PSE_upper - PSE_lower = %.4f deg VA   95%% bootstrap CI: [%.4f, %.4f]\n' ...
            '  Subjective center = (PSE_lower+PSE_upper)/2 = %.4f deg VA   95%% bootstrap CI: [%.4f, %.4f]\n' ...
            '  --- Delimitation by neighboring PSE (theoretical / design boundary) ---\n' ...
            '  Lower theoretical PSE: %.4f deg VA   Upper theoretical PSE: %.4f deg VA\n' ...
            '  Theoretical width = %.4f deg VA   Theoretical center = %.4f deg VA   (center bias = %.4f deg VA)\n'], ...
            cc.name, cc.peakX, cc.peakXCI(1), cc.peakXCI(2), cc.peakY, cc.peakYCI(1), cc.peakYCI(2), ...
            groupNames{c - 1}, cc.name, cc.pseLower, groupNames{c}, groupNames{c + 1}, cc.pseUpper, ...
            cc.width, cc.widthCI(1), cc.widthCI(2), cc.center, cc.centerCI(1), cc.centerCI(2), ...
            cc.pseLowerTheoretical, cc.pseUpperTheoretical, cc.widthTheoretical, cc.centerTheoretical, cc.centerBias);
    end
end

% ===========================================================================
% STEP 4: ORDINAL MODEL COMPARISON (diagnostic for the shared-slope ordinal
% logistic regression, the "gold standard" mnrfit(X,Y,'ordinal')-type model).
%
% mnrfit requires the Statistics and Machine Learning Toolbox. This project
%  avoids that dependency (see NormInvNoTB.m).
%
% IMPORTANT -- this is an ADDITIONAL diagnostic, it does NOT replace the
% independent-per-boundary fit above (STEP 1): the shared-slope model assumes
% "proportional odds" (a single discrimination slope for both boundaries)
% an assumption that may or may not hold in the data, and should NOT be
% assumed without testing it. It is formally tested here with a
% likelihood-ratio (LR) test against the UNrestricted model (separate
% slopes, fit with the SAME joint multinomial likelihood.
%  If the test rejects the shared slope (small p), the
% shared-slope model is NOT appropriate for this data and the independent-
% boundaries approach remains the correct choice.
ordinalModel = struct('available', false, 'note', '');
if logical(opt.FitOrdinalModel) && nBoundaries >= 2
    try
        alpha0 = arrayfun(@(b) boundaryFits(b).fit.alpha, 1:nBoundaries);
        beta0  = arrayfun(@(b) boundaryFits(b).fit.beta,  1:nBoundaries);
        fitFree   = fitOrdinalMLE(xFit, rankFit, nCat, link, false, alpha0, beta0);
        fitShared = fitOrdinalMLE(xFit, rankFit, nCat, link, true,  alpha0, beta0);
        Gstat = 2 * (fitShared.nll - fitFree.nll);
        Gstat = max(Gstat, 0);   % can come out slightly negative from optimizer numerical noise
        dfLR = fitFree.nParams - fitShared.nParams;
        pLR = 1 - chi2cdfNoTB(Gstat, dfLR);

        ordinalModel = struct();
        ordinalModel.available = true;
        ordinalModel.link = link;
        ordinalModel.unconstrained = fitFree;    % separate slopes, joint multinomial MLE
        ordinalModel.proportionalOdds = fitShared;  % shared slope == mnrfit(...,'ordinal')
        ordinalModel.LR = struct('G', Gstat, 'df', dfLR, 'p', pLR);
        if pLR < 0.05
            veredicto = ['REJECTS shared slope (p<0.05) -- the shared-slope model is NOT ' ...
                'appropriate as-is; the per-boundary slopes DO differ in a statistically ' ...
                'significant way. Using the independent-boundaries approach (STEP 1) as the ' ...
                'main analysis is recommended.'];
        else
            veredicto = ['DOES NOT reject shared slope (p>=0.05) -- consistent with ' ...
                '"proportional odds"; the shared-slope (single slope) model is defensible for ' ...
                'this data, though "not rejecting" is not strong positive evidence that it holds ' ...
                '(depends on statistical power -- check N and the width of the slope-difference CI).'];
        end
        ordinalModel.verdictText = veredicto;

        vprintf(verbose, ['\n--- Ordinal model comparison (diagnostic) ---\n' ...
            '  UNrestricted model (separate slopes, joint multinomial MLE):\n']);
        for b = 1:nBoundaries
            vprintf(verbose, '    Boundary %d: alpha = %.4f deg VA, beta = %.4f deg VA\n', ...
                b, fitFree.alpha(b), fitFree.beta(b));
        end
        vprintf(verbose, ['  Model with SHARED SLOPE ("proportional odds", = mnrfit ordinal):\n' ...
            '    shared beta = %.4f deg VA\n'], fitShared.beta(1));
        for b = 1:nBoundaries
            vprintf(verbose, '    Boundary %d: alpha (PSE) = %.4f deg VA\n', b, fitShared.alpha(b));
        end
        vprintf(verbose, ['  Likelihood-ratio test (shared slope vs. separate):\n' ...
            '    G = %.3f, df = %d, p = %.4f\n' ...
            '    -> %s\n'], Gstat, dfLR, pLR, veredicto);
    catch ME_ord
        ordinalModel = struct('available', false, ...
            'note', sprintf('Ordinal model fit failed: %s', ME_ord.message));
        warning('AnalyzePsychometricCurves:ordinalModelFailed', '%s', ordinalModel.note);
    end
else
    if ~logical(opt.FitOrdinalModel)
        ordinalModel.note = 'FitOrdinalModel=false -- diagnostic skipped by user option.';
    else
        ordinalModel.note = 'Not applicable: >=2 boundaries (>=3 categories) are needed to compare shared vs. separate slopes.';
    end
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
% Correct / incorrect trial counts derived from isCorrectFit (the useRow-
% selected subset).  "Raw" equivalents count over all nRows usable rows
% BEFORE any exclusion mask (omissions, retries, unexpected codes).
results.meta.nCorrect        = nnz(S.isCorrectFit == 1);
results.meta.nError          = nnz(S.isCorrectFit == 0);
results.meta.nCorrectRaw     = S.nCorrectRaw;
results.meta.nErrorRaw       = S.nErrorRaw;
results.boundary = boundaryFits;
results.category = category;
results.ordinalModel = ordinalModel;

matFile = fullfile(outDir, [csvBase '_psychometric.mat']);
save(matFile, 'results');
vprintf(verbose, '\nSaved: %s\n', matFile);

summaryFileB = fullfile(outDir, [csvBase '_psychometric_summary_boundaries.csv']);
writeBoundarySummaryCsv(summaryFileB, boundaryFits, link, opt);
vprintf(verbose, 'Saved: %s\n', summaryFileB);

summaryFileC = fullfile(outDir, [csvBase '_psychometric_summary_categories.csv']);
writeCategorySummaryCsv(summaryFileC, category, link, opt);
vprintf(verbose, 'Saved: %s\n', summaryFileC);

if ordinalModel.available
    summaryFileO = fullfile(outDir, [csvBase '_psychometric_summary_ordinalmodel.csv']);
    writeOrdinalModelCsv(summaryFileO, ordinalModel, nBoundaries);
    vprintf(verbose, 'Saved: %s\n', summaryFileO);
end

if logical(opt.MakePlots)
    try
        makeCategoryPlots(category, outDir, csvBase, link, logical(opt.FigureVisible), numel(xFit), 1);
        vprintf(verbose, 'Figures saved to: %s\n', outDir);
    catch ME_plot
        % Reported as a warning so a plotting problem never
        % hides the numeric results, which are already saved by this point

        warning('AnalyzePsychometricCurves:plotFailed', ...
            'Could not generate the figures (%s): %s', ME_plot.identifier, ME_plot.message);
    end
end

vprintf(verbose, '\n=======================================================\n');
end % AnalyzePsychometricCurves


% =========================================================================
% LOCAL HELPER FUNCTIONS
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
% WILSONCI  Wilson score interval for a binomial proportion 
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
        error('AnalyzePsychometricCurves:unknownLink', 'Unknown link function "%s".', link);
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
        error('AnalyzePsychometricCurves:unknownLink', 'Unknown link function "%s".', link);
end
end

function p = sigmoidP(x, alpha, beta, gamma, lambda, link)
p = gamma + (1 - gamma - lambda) .* linkCDF((x - alpha) ./ beta, link);
end

function nll = negLogLikBinom(theta, x, yBin, link, useLapse, lapseMax)
alpha = theta(1);
beta = exp(theta(2));   % beta > 0 by construction
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
% Binomial maximum-likelihood fit via fminsearch (base MATLAB, no
% Optimization/Statistics Toolbox). Fitting to the raw trial-level binomial
% likelihood (not least-squares on per-level proportions) naturally weights
% each stimulus level by its true trial count.
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
% Find where the empirical proportion crosses 0.5 by walking the sorted
% levels and interpolating between the two immediate neighbours that
% bracket it. Deliberately NOT interp1(pSorted, xSorted, 0.5, ...):
% pSorted is not guaranteed unique/monotonic (ties at 0 or 1 are common
% with small per-level N, especially inside a bootstrap resample) and
% interp1 needs a well-behaved independent variable 
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
% Deviance (likelihood-ratio) goodness-of-fit G-test against the fully
% saturated model. df = nLevels - nParams; p-value from the chi-square
% survival function via gammainc (base MATLAB).
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
% Chi-square CDF without the Statistics Toolbox: chi2cdf(x,df) ==
% gammainc(x/2, df/2), and gammainc is a base MATLAB function.
x = max(x, 0);
p = gammainc(x / 2, df / 2);
end

function G = allCumulativeCurves(x, boundaryParams, nCat, link)
% G(:,b+1) = P(response >= b+1), for b = 1..nCat-1 (the fitted boundaries).
% G(:,1) = 1 (P(response>=1)=1 trivially) and G(:,end) = 0 (P(response>=
% nCat+1)=0 trivially) are DEFINITIONAL endpoints, not fitted -- they are
% what makes categoryCurvesFromG's subtraction work for the first and last
% category without special-casing them.
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
% P(:,c) = G(:,c) - G(:,c+1), c = 1..nCat -- the one-vs-rest probability of
% category c, derived from the cumulative boundary curves. Sums to 1
% across c at every row BY CONSTRUCTION (telescoping sum): sum_c P(:,c) =
% G(:,1) - G(:,end) = 1 - 0 = 1, always, unlike 3 independently-fit binary
% curves.
P = G(:, 1:end-1) - G(:, 2:end);
end

function nll = negLogLikOrdinalMulti(theta, x, rankVec, nCat, link, sharedSlope)
% Full multinomial  negative log-likelihood for
% the ordinal cumulative-link model. The objective mnrfit(...,'ordinal')
% would maximize internally (via IRLS) when sharedSlope=true. This is used
% for STEP 4's model-comparison diagnostic only, NOT for the main boundary
% fits in STEP 1
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
P = min(max(P, 1e-9), 1);   % guards against log(<=0) if candidate params make curves cross
n = numel(rankVec);
idx = sub2ind(size(P), (1:n)', rankVec(:));
nll = -sum(log(P(idx)));
end

function fit = fitOrdinalMLE(x, rankVec, nCat, link, sharedSlope, alpha0, beta0)
% Joint multinomial MLE  for the ordinal cumulative-link model, either with a single
% shared slope ("proportional odds", sharedSlope=true -- what
% mnrfit(X,Y,'ordinal') fits) or with a free slope per boundary
% (sharedSlope=false : the unconstrained comparison model for the LR
% test). Initialized from the already-fitted per-boundary alpha0/beta0
% (STEP 1), which are close to both of these solutions in practice.
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
    warning('AnalyzePsychometricCurves:ordinalFitNoConverge', ...
        'Ordinal fit (sharedSlope=%d) did not report clean convergence from fminsearch (exitflag=%d) -- review carefully.', ...
        sharedSlope, exitflag);
end
end

function s = curveSummary(xGrid, yGrid)
% Peak location/height of a (possibly non-monotonic) curve on xGrid --
% used for an INTERIOR category's one-vs-rest curve (e.g. Mid), which is
% expected to be a bump, not a sigmoid: a
% "threshold" is not a meaningful summary for a non-monotonic curve, but
% peak location + height (the same kind of summary used for a neural
% tuning curve) is.
[peakY, iPk] = max(yGrid);
peakX = xGrid(iPk);
s = struct('peakX', peakX, 'peakY', peakY);
end

function jb = jointBootstrap(x, rankVec, nCat, link, useLapse, lapseMax, nBoot, alphaCI, xGrid)
% JOINTBOOTSTRAP  Resample trial ROWS ONCE per replicate and refit ALL
% (nCat-1) boundaries from that SAME resampled dataset 
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
            % A pathological resample (e.g. all-one-outcome for some
            % boundary) can make a fit degenerate -- skip the WHOLE
            % replicate (both boundaries), not just this one, so a
            % category curve never mixes a real fit with a failed one.
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
% Subjective Width/Center (Option 1) per interior category is
% computed here, INSIDE the same joint resample as alphaBoot, instead
% of resampling separately: Width = alpha(b) - alpha(b-1) is a
% DERIVED quantity from 2 boundaries, just like the Mid curve itself,
% so its CI is only valid if it comes from the same shared resample.
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
% Used when NBootstrap=0: same field layout as jointBootstrap's output,
% all-NaN, so downstream code needs no branching on whether bootstrap ran.
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
% Simple sample-quantile (linear interpolation, "type 7", same convention
% MATLAB's own quantile() uses) without requiring the Statistics Toolbox.
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
% applicable for this row type", whereas a 0 could be misread as a real
% value. Used by writeBoundarySummaryCsv/writeCategorySummaryCsv below so
% adding a column never requires hand-counting %.6f placeholders against a
% giant fprintf argument list (a mismatch there would silently misalign
% every column after it).
if isnan(v)
    s = '';
else
    s = sprintf('%.6f', v);
end
end

function writeBoundarySummaryCsv(fname, boundaryFits, link, opt)
% The (nCat-1) fitted ORDINAL boundaries (the statistical primitives) --
% see writeCategorySummaryCsv for the derived one-vs-rest category view.
%
% Hraw/Fraw/Hits/FalseAlarms/Nsignal/Nnoise/Dprime/CriterionC: EMPIRICAL
% signal detection theory for this boundary (true StimulusGroup vs.
% response), independent of the sigmoid -- see the comment in STEP 1 of the
% main body for the exact definition and the sign convention for c.
% Dprime/CriterionC use the CORRECTED H/F (log-linear, Hautus 1995);
% Hraw/Fraw are the raw, uncorrected ones, included for auditing.
%
% TheoreticalPSE_degVA/Bias_degVA: the OBJECTIVE/design category boundary
% for this boundary (midpoint between the largest bar length shown for the
% lower true category and the smallest shown for the next one up -- see
% STEP 1's code comment) and Bias = Threshold_alpha - TheoreticalPSE (the
% subject's observed categorization bias at this boundary).
header = {'Boundary', 'LinkFunction', 'N', 'Threshold_alpha_degVA', 'ThresholdCI_lo', 'ThresholdCI_hi', ...
    'Slope_beta_degVA', 'SlopeCI_lo', 'SlopeCI_hi', 'Width50to84_degVA', 'Gamma', 'Lambda', ...
    'AIC', 'DevianceG', 'DevianceDF', 'DeviancePvalue', ...
    'TheoreticalPSE_degVA', 'Bias_degVA', ...
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

function writeCategorySummaryCsv(fname, category, link, opt)
% The nCat DERIVED one-vs-rest category curves (Short vs rest, Mid vs
% rest, Long vs rest). Edge categories (Short/Long) get a
% PSE(50%)+slope row; interior categories (Mid) get a peak row
% the columns not meaningful for a given row are left blank, not zero.
%
% PSE_50pct_degVA = point of subjective equality = 50% crossing of that
% category's one-vs-rest curve (the OBSERVED/behavioral PSE). This is NOT
% rescaled to 1/nCat (33% for 3 categories): each edge category's curve is
% itself a binary decision (this category vs. the other two), so
% 50% is the correct equal-odds criterion regardless of how many categories
% the task has in total. 1/nCat is a different quantity (chance accuracy
% under uniform random guessing across nCat alternatives) 
%
% PSE_Theoretical_degVA/PSE_Bias_degVA (only on 'threshold' rows): the
% OBJECTIVE/design boundary for that category's one boundary, and the
% subject's bias (observed - theoretical) at it.
%
% PSElower/PSEupper/Width/Center (only on 'peak' rows): the delimitation of
% the interior category by the OBSERVED PSE of its 2 neighboring
% boundaries. Width = PSEupper - PSElower; Center = (PSElower+PSEupper)/2.
% CI via the same joint bootstrap as the rest of the file.

header = {'Category', 'SummaryType', 'LinkFunction', 'N', ...
    'PSE_50pct_degVA', 'PSE_CI_lo', 'PSE_CI_hi', 'PSE_Theoretical_degVA', 'PSE_Bias_degVA', ...
    'Slope_degVA', 'SlopeCI_lo', 'SlopeCI_hi', ...
    'PeakX_degVA', 'PeakXCI_lo', 'PeakXCI_hi', 'PeakY', 'PeakYCI_lo', 'PeakYCI_hi', ...
    'PSElower_degVA', 'PSEupper_degVA', 'Width_degVA', 'WidthCI_lo', 'WidthCI_hi', ...
    'Center_degVA', 'CenterCI_lo', 'CenterCI_hi', ...
    'PSElowerTheoretical_degVA', 'PSEupperTheoretical_degVA', 'WidthTheoretical_degVA', ...
    'CenterTheoretical_degVA', 'CenterBias_degVA', ...
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

function writeOrdinalModelCsv(fname, ordinalModel, nBoundaries)
% STEP 4 diagnostic the shared-slope ordinal regression vs. the
% unrestricted model, and the LR test between them. One row per boundary
% for each model, plus one row for the test.
fid = fopen(fname, 'w');
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
% Matches this project's own default stimulus colours.
%If you modify the colors in other parts of the scripts for the curves be sure to
%also modify them here to keep the colors consistent across all figures.
orange = [1.00 0.55 0.00];
green  = [0.10 0.75 0.20];
blue   = [0.05 0.45 0.95];
switch nCat
    case 2
        colors = [orange; blue];
    case 3
        colors = [orange; green; blue];
    otherwise
        colors = lines(nCat);
end   % base MATLAB colormap, generic fallback
end

function makeCategoryPlots(category, outDir, csvBase, link, figVisible, nTrialsUsed, nSessions)

nCat = numel(category);
colors = defaultCategoryColors(nCat);
chanceLevel = 1 / nCat;
if figVisible, visStr = 'on'; else, visStr = 'off'; end
theoColor = [0.0 0.45 0.7];   % teal-blue: used consistently for every THEORETICAL element
obsPseColor = [0.85 0.1 0.1]; % red: used consistently for every OBSERVED PSE element
obsMidColor = [0.5 0.2 0.6];  % purple: OBSERVED subjective width/center of an interior category
% A single-category (one curve per figure) plot does not need to carry a
% category color on its fitted curve line -- black reads better on its
% own. The category color scheme is reserved for the combined ("global")
% overview figure, where it is what distinguishes the curves from each
% other (see makeCategoryPlots' overview section below).
curveColorIndividual = [0 0 0];

% --- One figure per category, with its bootstrap band and raw data ------
for c = 1:nCat
    cc = category(c);
    fig = figure('Visible', visStr, 'Position', [100 100 850 580]);
    hold on;
    legendH = [];  legendLabels = {};
    if ~isempty(cc.curveLo) && ~all(isnan(cc.curveLo))
        xFill = [cc.curveX; flipud(cc.curveX)];
        yFill = [cc.curveLo; flipud(cc.curveHi)];
        fill(xFill, yFill, [0.5 0.5 0.5], 'EdgeColor', 'none', 'FaceAlpha', 0.25);
    end
    plot(cc.curveX, cc.curveY, '-', 'Color', curveColorIndividual, 'LineWidth', 2.8);
    errLo = cc.propObs - cc.propWilsonLo;
    errHi = cc.propWilsonHi - cc.propObs;
    for g = 1:nCat
        idxG = (cc.xLevelTrueRank == g);
        if ~any(idxG), continue; end
        hEBg = errorbar(cc.xLevels(idxG), cc.propObs(idxG), errLo(idxG), errHi(idxG), 'o');
        set(hEBg, 'Color', colors(g, :) * 0.6, 'MarkerFaceColor', colors(g, :), ...
            'MarkerEdgeColor', colors(g, :) * 0.6, 'MarkerSize', 8, 'LineWidth', 1.8);
    end
    plot(xlim_safe2(cc.curveX), [chanceLevel chanceLevel], '--', ...
        'Color', [0.6 0.6 0.6], 'LineWidth', 1.5);
    if strcmp(cc.summaryType, 'threshold')
        hPseV = plot([cc.threshold cc.threshold], [0 0.5], ':', 'Color', obsPseColor, 'LineWidth', 1.8);
        plot([min(cc.curveX) cc.threshold], [0.5 0.5], ':', 'Color', obsPseColor, 'LineWidth', 1.8);
        plot(cc.threshold, 0.5, 'p', 'MarkerSize', 11, 'MarkerFaceColor', obsPseColor, 'MarkerEdgeColor', 'k');
        legendH = [legendH, hPseV]; %#ok<AGROW>
        legendLabels{end+1} = sprintf('PSE observado = %.3f', cc.threshold);
        if ~isnan(cc.theoreticalThreshold)
            hPseTheo = plot([cc.theoreticalThreshold cc.theoreticalThreshold], [0 0.5], '--', ...
                'Color', theoColor, 'LineWidth', 1.8);
            plot(cc.theoreticalThreshold, 0.5, 'd', 'MarkerSize', 10, 'MarkerFaceColor', theoColor, 'MarkerEdgeColor', 'k');
            legendH = [legendH, hPseTheo]; %#ok<AGROW>
            legendLabels{end+1} = sprintf('PSE teórico = %.3f', cc.theoreticalThreshold);
        end
    else
        plot([cc.peakX cc.peakX], [0 cc.peakY], ':', 'Color', [0.3 0.3 0.3], 'LineWidth', 1.5);
        if ~isnan(cc.pseLowerTheoretical) && ~isnan(cc.pseUpperTheoretical)
            hWidthTheo = plot([cc.pseLowerTheoretical cc.pseLowerTheoretical cc.pseUpperTheoretical cc.pseUpperTheoretical], ...
                [0 1 1 0], '--', 'Color', theoColor, 'LineWidth', 1.8);
            hWidthTheo = hWidthTheo(1);
            plot(cc.centerTheoretical, 0.06, 'v', 'MarkerSize', 10, 'MarkerFaceColor', theoColor, 'MarkerEdgeColor', 'k');
            legendH = [legendH, hWidthTheo]; %#ok<AGROW>
            legendLabels{end+1} = sprintf('PSE teórico = %.3f', cc.centerTheoretical);
        end
    end
    ttl = sprintf('Sesiones: %d  |  Ensayos: %d', nSessions, nTrialsUsed);
    xlabel('Longitud de la barra (grados AV)', 'FontSize', 18, 'FontWeight', 'bold');
    ylabel(sprintf('P(respuesta = %s)', categoryNameEs(cc.name)), 'FontSize', 18, 'FontWeight', 'bold');
    title(ttl, 'Interpreter', 'none', 'FontSize', 20, 'FontWeight', 'bold');
    ylim([-0.02 1.02]);
    set(gca, 'FontSize', 18, 'LineWidth', 1.2);
    grid off; box on;
    addCategoryShades(gca, category, colors, 0.12);
    hLeg = legend(legendH, legendLabels, 'Location', 'north', 'FontSize', 18);
    set(hLeg, 'Box', 'off', 'Color', 'none');
    outFile = fullfile(outDir, sprintf('%s_category_%s_%s.png', csvBase, cc.name, link));
    try
        print(fig, outFile, '-dpng', '-r300');
    catch
        saveas(fig, outFile);
    end
    saveFigureAlsoAsVector(fig, outFile);
    if ~figVisible, close(fig); end
end


% ---COMBINED FIGURE WITH ALL GRAPHICS TOGETHER --------------
% Every plotted element gets an EXPLICIT legend entry
% Only the 3-category "global" overview (all 3 one-vs-rest curves
% together) keeps the category color scheme -- it is what distinguishes
% the 3 curves from each other there. Any other curve count (e.g. the
% 2-category case) uses a neutral grayscale ramp instead.
if nCat == 3
    curveColorsOverview = colors;
else
    curveColorsOverview = repmat(linspace(0, 0.55, nCat)', 1, 3);
end
fig = figure('Visible', visStr, 'Position', [100 100 880 600]);
hold on;
legendH = [];  legendLabels = {};
for c = 1:nCat
    cc = category(c);
    plot(cc.curveX, cc.curveY, '-', 'Color', curveColorsOverview(c, :) * 0.75, 'LineWidth', 3.0);
    errLo = cc.propObs - cc.propWilsonLo;
    errHi = cc.propWilsonHi - cc.propObs;
    hEB = errorbar(cc.xLevels, cc.propObs, errLo, errHi, 'o');
    set(hEB, 'Color', curveColorsOverview(c, :) * 0.75, 'MarkerFaceColor', curveColorsOverview(c, :), ...
        'MarkerSize', 8, 'LineWidth', 1.8);
    % PSE markers (only meaningful for the 2 edge/monotonic categories --
    % see this function's header for why the interior category does not get one):
    if strcmp(cc.summaryType, 'threshold')
        plot([cc.threshold cc.threshold], [0 0.5], ':', 'Color', curveColorsOverview(c, :) * 0.6, 'LineWidth', 1.8);
        plot([min(cc.curveX) cc.threshold], [0.5 0.5], ':', 'Color', curveColorsOverview(c, :) * 0.6, 'LineWidth', 1.8);
        hPseC = plot(cc.threshold, 0.5, 'p', 'MarkerSize', 11, 'MarkerFaceColor', curveColorsOverview(c, :), 'MarkerEdgeColor', 'k');
        legendH = [legendH, hPseC]; %#ok<AGROW>
        legendLabels{end+1} = sprintf('PSE observado %s = %.3f', cc.name, cc.threshold); %#ok<AGROW>
        if ~isnan(cc.theoreticalThreshold)
            plot([cc.theoreticalThreshold cc.theoreticalThreshold], [0 0.5], '--', 'Color', theoColor, 'LineWidth', 1.8);
            hPseTheoC = plot(cc.theoreticalThreshold, 0.5, 'd', 'MarkerSize', 10, 'MarkerFaceColor', theoColor, 'MarkerEdgeColor', 'k');
            legendH = [legendH, hPseTheoC]; %#ok<AGROW>
            legendLabels{end+1} = sprintf('PSE teórico %s = %.3f', cc.name, cc.theoreticalThreshold); %#ok<AGROW>
        end
    end
end
% Delimitation of the interior category(ies) by neighboring THEORETICAL
% (design) PSE only -- teal-blue dashed vertical lines with downward triangle:
for c = 1:nCat
    cc = category(c);
    if strcmp(cc.summaryType, 'peak')
        if ~isnan(cc.pseLowerTheoretical) && ~isnan(cc.pseUpperTheoretical)
            plot([cc.pseLowerTheoretical cc.pseLowerTheoretical], [0 1], '--', 'Color', theoColor, 'LineWidth', 1.8);
            plot([cc.pseUpperTheoretical cc.pseUpperTheoretical], [0 1], '--', 'Color', theoColor, 'LineWidth', 1.8);
        end
    end
end
xlabel('Longitud de la barra (grados AV)', 'FontSize', 18, 'FontWeight', 'bold');
ylabel('P(respuesta = categoría)', 'FontSize', 18, 'FontWeight', 'bold');
ttl = sprintf('Sesiones: %d  |  Ensayos: %d', nSessions, nTrialsUsed);
title(ttl, 'Interpreter', 'none', 'FontSize', 20, 'FontWeight', 'bold');
ylim([-0.02 1.02]);
set(gca, 'FontSize', 18, 'LineWidth', 1.2);
grid off; box on;
addCategoryShades(gca, category, colors, 0.12);
if nCat == 3
    legLoc = 'east';
else
    legLoc = 'north';
end
hLeg = legend(legendH, legendLabels, 'Location', legLoc, 'FontSize', 18);
set(hLeg, 'Box', 'off', 'Color', 'none');
outFile = fullfile(outDir, sprintf('%s_categories_overview_%s.png', csvBase, link));
try
    print(fig, outFile, '-dpng', '-r300');
catch
    saveas(fig, outFile);
end
saveFigureAlsoAsVector(fig, outFile);
if ~figVisible, close(fig); end
end


function xr = xlim_safe2(x)
% Returns a 2-element [min max] of x, for drawing full-width horizontal
% reference lines without depending on xlim() having been set yet (order
% of plotting matters in some MATLAB/Octave versions).
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

function saveFigureAlsoAsVector(fig, pngPath)
% Also saves a vector PDF next to the PNG (same name, .pdf extension) so
% the figure can be resized for a slide deck or printed on a poster
% without losing sharpness -- a PNG is a fixed grid of pixels and gets
% blurry/pixelated when scaled up, a PDF is redrawn at any size.
pdfPath = regexprep(pngPath, '\.png$', '.pdf');
try
    exportgraphics(fig, pdfPath, 'ContentType', 'vector');
catch
    try
        print(fig, pdfPath, '-dpdf', '-vector', '-bestfit');
    catch
    end
end
end

function addCategoryShades(ax, category, colors, alphaVal)
% ADDCATEGORYSHADES  Draws vertical background patches for each category
% spanning its exact stimulus range [min(bars), max(bars)].
if nargin < 4 || isempty(alphaVal), alphaVal = 0.15; end
nCat = numel(category);
if nargin < 3 || isempty(colors)
    colors = defaultCategoryColors(nCat);
end

yLim = get(ax, 'YLim');

% First pass: collect each category's OWN observed bar range (may leave
% gaps between categories where no bar length was actually shown).
xMinRaw = nan(1, nCat);  xMaxRaw = nan(1, nCat);
for c = 1:nCat
    cc = category(c);
    if isfield(cc, 'stimMin') && ~isnan(cc.stimMin) && isfield(cc, 'stimMax') && ~isnan(cc.stimMax)
        xMinRaw(c) = cc.stimMin;
        xMaxRaw(c) = cc.stimMax;
    elseif isfield(cc, 'xLevelTrueRank') && isfield(cc, 'xLevels')
        catBars = cc.xLevels(cc.xLevelTrueRank == c);
        if isempty(catBars), continue; end
        xMinRaw(c) = min(catBars);
        xMaxRaw(c) = max(catBars);
    end
end

% Second pass: extend each category's shaded patch halfway to its
% neighbors (categories are already in ascending-length rank order, c=1
% is the shortest), so adjacent patches meet at the EQUIDISTANT midpoint
% between their observed ranges instead of stopping short and leaving a
% white gap where no bar length happens to have been shown.
for c = 1:nCat
    if isnan(xMinRaw(c)), continue; end
    if c > 1 && ~isnan(xMaxRaw(c - 1))
        xLo = (xMaxRaw(c - 1) + xMinRaw(c)) / 2;
    else
        xLo = xMinRaw(c);
    end
    if c < nCat && ~isnan(xMinRaw(c + 1))
        xHi = (xMaxRaw(c) + xMinRaw(c + 1)) / 2;
    else
        xHi = xMaxRaw(c);
    end
    xP = [xLo, xHi, xHi, xLo];
    yP = [yLim(1), yLim(1), yLim(2), yLim(2)];
    h = patch('Parent', ax, 'XData', xP, 'YData', yP, ...
        'FaceColor', colors(c, :), 'EdgeColor', 'none', ...
        'FaceAlpha', alphaVal, 'HitTest', 'off', 'HandleVisibility', 'off');
    uistack(h, 'bottom');
end
set(ax, 'YLim', yLim);
set(ax, 'Layer', 'top');
end

