function [outlierIndices, cleanedData] = HampelOutlierDetector(data, windowSize, thresholdMAD)
    % HAMPELOUTLIERDETECTOR  Robust outlier rejection via a moving median.
    %
    %   For each point, compares it to the moving median (not mean) of its
    %   window; flags/replaces it if its deviation from that median exceeds
    %   thresholdMAD scaled-MADs (not std); a single spike barely moves
    %   either statistic of its own neighborhood, so it can't inflate the
    %   very threshold used to catch it the way a mean+stdev test would.
    %   Built on movmedian, so it's O(n log w) rather than a per-point
    %   sliding-window loop; irrelevant at small per-trial n, but avoids
    %   the one quadratic term that would otherwise sit in the pipeline.
    %
    %   Both the centre statistic AND the spread statistic are LOCAL: the
    %   deviations are compared against a MOVING MAD over the same window,
    %   not against one global MAD for the whole column. With a global MAD,
    %   a signal that is genuinely fast in one phase and slow in another
    %   (a cursor reach: quick launch, slow settle) has its spread set
    %   mostly by the fast phase, which raises the bar high enough to hide
    %   a glitch sitting in the slow phase. A moving MAD judges each point
    %   only against its own neighborhood.
    %
    %   MADSCALE = 1.4826 makes the MAD a consistent estimator of the
    %   standard deviation under normality, so thresholdMAD reads on the
    %   same scale as the familiar "n sigma" rule. Without it, a nominal
    %   threshold of 3 behaves like ~2 sigma and lets roughly half again as
    %   many real glitches through.
    %
    %   INPUT
    %     data           : [N x 1] or [N x D] (processed column-wise)
    %     windowSize     : moving-median window width; incremented by 1 if even
    %     thresholdMAD   : scaled-MAD multiples before a point counts as an
    %                      outlier (typical: 3.0-5.0; higher = fewer outliers)
    %
    %   OUTPUT
    %     outlierIndices : [N x 1] logical, true where a point was replaced
    %                      in ANY column (union across columns)
    %     cleanedData    : [N x D], outliers replaced by their window median

    MADSCALE = 1.4826;   % MAD -> std-equivalent under normality

    if nargin < 2 || isempty(windowSize)
        windowSize = 5;  % default: +/-2 neighbors per side
    end
    if nargin < 3 || isempty(thresholdMAD)
        thresholdMAD = 3.0;  % 3-sigma rule of thumb
    end

    % Ensure windowSize is odd
    if mod(windowSize, 2) == 0
        windowSize = windowSize + 1;
    end

    % Ensure data is column-oriented
    if isrow(data)
        data = data';
    end

    [N, D] = size(data);
    outlierIndices = false(N, 1);
    cleanedData = data;

    % Per-column Hampel
    for d = 1:D
        col = data(:, d);

        % Step 1: moving median (local centre)
        medians = movmedian(col, windowSize, 'Endpoints', 'shrink');

        % Step 2: absolute deviations from the local median
        deviations = abs(col - medians);

        % Step 3: moving MAD (local spread), scaled to std-equivalent
        localMAD = MADSCALE * movmedian(deviations, windowSize, 'Endpoints', 'shrink');

        % Step 4: flag outliers, elementwise. The localMAD > 0 guard is not
        % cosmetic: on a stretch where the window is perfectly flat (a
        % stationary cursor reading the same value repeatedly) the local
        % MAD is exactly 0, so the threshold collapses to 0 and ANY nonzero
        % deviation, however small, would be flagged. Points in such a
        % window are left alone; there is no local scale against which to
        % judge them.
        threshold = thresholdMAD * localMAD;
        colOutliers = (localMAD > 0) & (deviations > threshold);

        % Mark outliers
        outlierIndices = outlierIndices | colOutliers;

        % Replace outliers with the window median
        cleanedData(colOutliers, d) = medians(colOutliers);
    end
end