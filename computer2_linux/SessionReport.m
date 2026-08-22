
classdef SessionReport
% SESSIONREPORT  End-of-session console reporting for the center-out
% length-categorization task.
% Paola Castillo 2026-07-31
%
% Grouped here because the four printouts form one coherent stage of the
% pipeline (they all consume the final session tallies and write to the
% console) and because keeping them out of CenterOutTask.m makes them
% reusable: a saved perf_*.mat can be re-reported later without re-running
% a session, and offrig_mocks can exercise them with synthetic tallies.
%
% These are STATIC methods, i.e. this class is a namespace rather than a
% stateful object. That is deliberate: the printers hold no state between
% calls -- each takes the tallies it needs and writes them out -- so giving
% the class properties would invent coupling that the code does not have,
% and would force every caller to build an object before it could print a
% single table. If the argument lists later grow unwieldy, the natural next
% step is a stats struct passed to a constructor, not properties bolted on
% now.
%
% Report levels, printed in this order by the task's teardown:
%   Level 1  blocks           per-block tallies
%   Level 2  session          session-wide totals, quotas, RT/accuracy
%   plus     reward           water delivered (trial + manual), shared with
%                             CenterInTask.m -- the one printer here that is
%                             not center-out specific
%   plus     confusion        true x chosen category matrix
%   plus     signalDetection  one-vs-rest SDT breakdown of that matrix
%
% Depends on NormInvNoTB.m (toolbox-free normal quantile) for d'.

    methods (Static)

        function blocks(blockStats, sessionMode)
        % BLOCKS  Level 1 of the 2-level end-of-session report: one row
        % per block (block = one blockSize-trial rotation through the pseudorandom
        % sequence -- see blockStats/blockSize in the main function), printed
        % before SessionReport.session's Level 2 (session = all blocks combined).
        %
        % Mix(2/3) is how many of this block's trials were 2-category vs.
        % 3-category, tallied straight from the sequence for every attempt (not
        % assumed from a fixed layout) -- so a block stays correct whether it's a
        % uniform '3cat'/'2cat' session, a block that happens to straddle an
        % 'alternate' 2-cat/3-cat switch, or an 'interleaved' block with both mixed
        % trial-by-trial.
        %
        % A PURE 2-cat session (sessionMode == '2cat') drops the Mid column from
        % "By category" -- it would only ever show 0/0 there, since 2-cat trials
        % never draw Mid. 'alternate'/'interleaved' sessions genuinely mix in Mid
        % trials, so they keep all three columns.
        if nargin < 2, sessionMode = ''; end
        if isempty(blockStats)
            fprintf('\nNo completed blocks to report.\n');
            return;
        end
        grpNames = ColorCategoryMap.categoryNames();
        if strcmpi(sessionMode, '2cat')
            activeCats = [1 3];
        else
            activeCats = 1:3;
        end
        fprintf('\n======= PER-BLOCK SUMMARY (Level 1) =======\n');
        fprintf('%-6s %-9s %6s %6s %8s %8s %8s   %s\n', ...
            'Block', 'Mix(2/3)', 'Total', 'Good', '%Corr', 'EarlyEx', 'WrongTg', 'By category (good/total)');
        for b = 1:numel(blockStats)
            bs = blockStats(b);
            if bs.total == 0, continue; end
            pct = 100 * bs.good / bs.total;
            catStr = '';
            for g = activeCats
                catStr = [catStr sprintf('%s %d/%d  ', grpNames{g}, bs.goodGrp(g), bs.totalGrp(g))]; %#ok<AGROW>
            end
            fprintf('%-6d %2d/%-6d %6d %6d %7.1f%% %8d %8d   %s\n', ...
                b, bs.nCat2, bs.nCat3, bs.total, bs.good, pct, bs.errorEarly, bs.errorWrong, catStr);
        end
        fprintf('============================================\n');
        end

        function session(total_trials, good_trials, perf, error_early_exit, ...
                error_wrong_target, total_trials_grp, good_trials_grp, ...
                mean_RT_matrix, percent_correct_matrix, total_trials_matrix, ...
                good_trials_lenpos, good_trials_lenpos_2cat, good_trials_lenpos_3cat, ...
                minPerLength, target_angles, sessionMode, ...
                mean_RT_lenpos, percent_correct_lenpos, total_trials_lenpos, ...
                correct_trials_lenpos, lengthCategory)
        % The five *_lenpos/lengthCategory arguments are optional: without
        % them this prints exactly what it always did (category roll-up
        % only), so any caller written before the per-length tables existed
        % still works. CenterOutTask.m always passes them.
        if nargin < 16, sessionMode = ''; end
        haveLenPos = nargin >= 21 && ~isempty(mean_RT_lenpos);
        if strcmpi(sessionMode, '2cat')
            % Pure 2-cat session: Mid never occurs, so skip it below instead
            % of printing an always-zero row. 'alternate'/'interleaved'
            % genuinely draw Mid trials some of the time and keep all three.
            activeCats = [1 3];
        else
            activeCats = 1:3;
        end
        fprintf('\n======= SESSION SUMMARY (Level 2 -- all blocks combined) ==========\n');
        fprintf('Total Trials:        %d\n', total_trials);
        fprintf('Good Trials:         %d\n', good_trials);
        fprintf('Overall Performance: %.2f%%\n\n', perf);
        if total_trials > 0
            fprintf('--- Error Breakdown ---\n');
            fprintf('Early Exit Errors:   %d (%.2f%%)\n', error_early_exit,   error_early_exit/total_trials*100);
            fprintf('Wrong Target Errors: %d (%.2f%%)\n', error_wrong_target, error_wrong_target/total_trials*100);
        end
        sel = good_trials + error_wrong_target;
        if sel > 0
            fprintf('\n--- Target Selection Performance ---\n');
            fprintf('Trials that reached target selection: %d\n', sel);
            fprintf('Target selection accuracy: %.2f%%\n', good_trials/sel*100);
        end
        fprintf('=============================================\n\n');

        names = upper(ColorCategoryMap.categoryNames());
        for g = activeCats
            fprintf('--- %-5s GROUP trials: %d total, %d correct (%.1f%%)\n', names{g}, ...
                total_trials_grp(g), good_trials_grp(g), 100*good_trials_grp(g)/max(total_trials_grp(g), 1));
        end

        % Header built from the SAME field widths the data row below uses
        % (21-char prefix: '  %2d. %6.4f deg VA: ', then four '%3d ' columns)
        % instead of hand-typed spaces, so R/U/L/D sit directly above their
        % column no matter how the prefix changes later.
        fprintf('\n--- Per (length x position) quota (min %d correct each) ---\n', minPerLength);
        fprintf('%21s%3s %3s %3s %3s\n', '', 'R', 'U', 'L', 'D');
        for L = 1:size(good_trials_lenpos, 1)
            met = '';
            if any(good_trials_lenpos(L, :) < minPerLength), met = '  <-- short'; end
            fprintf('  %2d. %6.4f deg VA: %3d %3d %3d %3d%s\n', L, target_angles(L), good_trials_lenpos(L, :), met);
        end

        % Same (length x position) tally, split by how many categories that attempt
        % was drawn from -- the "total" table above pools 2-cat and 3-cat attempts
        % at the same length together, which hides a real distinction in sessionMode
        % = 'alternate'/'interleaved': the 2-cat and 3-cat tasks use DIFFERENT
        % length->category splits (see lengthCat2 vs lengthCategory in the main
        % function), so a length's correct trials can come from either framing, or
        % both. Every row below satisfies 2-cat + 3-cat == the total row above; a
        % session that never mixed categories ('3cat' or '2cat' only) will just
        % show all zeros in the other half, which itself confirms nothing got
        % conflated.
        % Same idea as the header above: prefix is 23 chars here
        % ('  %2d. %6.4f deg VA:   '), then two 15-char '%3d %3d %3d %3d'
        % blocks separated by a 6-char gap -- built from those exact widths
        % instead of hand-typed spaces (which had drifted out of alignment).
        fprintf('\n--- Same, split by category-count (2-cat / 3-cat) --- (2cat + 3cat = total above)\n');
        fprintf('%23s%-15s      %-15s\n', '', '2-cat', '3-cat');
        fprintf('%23s%3s %3s %3s %3s      %3s %3s %3s %3s\n', '', 'R', 'U', 'L', 'D', 'R', 'U', 'L', 'D');
        for L = 1:size(good_trials_lenpos, 1)
            fprintf('  %2d. %6.4f deg VA:   %3d %3d %3d %3d      %3d %3d %3d %3d\n', ...
                L, target_angles(L), good_trials_lenpos_2cat(L, :), good_trials_lenpos_3cat(L, :));
        end

        if strcmpi(sessionMode, '2cat')
            matrixRowsLabel = '(rows 1=Short 3=Long | cols Right Up Left Down)';
        else
            matrixRowsLabel = '(rows 1=Short 2=Mid 3=Long | cols Right Up Left Down)';
        end
        % Header built from the SAME field widths each data row below uses
        % (10-char prefix: 6-char rowName + 4 literal spaces, then four
        % 8-char columns separated by 2 spaces) -- the previous hand-typed
        % header spaces drifted out of alignment by a full column's width
        % by the time they reached "Down".
        dirHeader = sprintf('%10s%8s  %8s  %8s  %8s', '', 'Right', 'Up', 'Left', 'Down');
        fprintf('\n--- Performance Matrix --- %s\n\n', matrixRowsLabel);
        fprintf('Mean Reaction Time (s) [target-onset -> leave-center]:\n%s\n', dirHeader);
        rowName = {'Short:', 'Mid:  ', 'Long: '};
        for g = activeCats
            fprintf('%s    %8.3f  %8.3f  %8.3f  %8.3f\n', rowName{g}, mean_RT_matrix(g, :));
        end
        fprintf('\nPercentage Correct (%%):\n%s\n', dirHeader);
        for g = activeCats
            fprintf('%s    %8.2f  %8.2f  %8.2f  %8.2f\n', rowName{g}, percent_correct_matrix(g, :));
        end
        fprintf('\nTrial Counts:\n%s\n', dirHeader);
        for g = activeCats
            fprintf('%s    %8d  %8d  %8d  %8d\n', rowName{g}, total_trials_matrix(g, :));
        end
        fprintf('\n');

        % ---- The same three tables, ONE ROW PER BAR LENGTH ---------------
        % 12 lengths x 4 directions = the 48 combinations a full12 session
        % is built from. The category tables above are the roll-up of
        % exactly these numbers (each cell here is credited inside the same
        % guard as its category counterpart in CenterOutTask.m), and they
        % stay printed because they are the at-a-glance summary -- but the
        % roll-up averages over the 4 lengths inside a category, which is
        % where this task's signal lives: the lengths nearest a category
        % boundary are the hard ones, and a category mean hides them
        % against the easy extremes.
        %
        % '  --  ' rather than a number wherever a combination never ran:
        % printing 0.00%% correct or 0.000 s for a condition that produced
        % no trial reads as a measured result, which it is not. That
        % distinction matters most on exactly the sessions where this table
        % is most useful (one stopped early, or run on a bar subset).
        if ~haveLenPos, return; end
        nLengths = size(mean_RT_lenpos, 1);
        catNames = ColorCategoryMap.categoryNames();
        % Header built from the same widths the rows use: a 24-char label
        % (see lenRowLabel) then four 8-wide columns with a 2-space gap,
        % the same data-column geometry as the category tables above.
        lenHeader = sprintf('%24s%8s  %8s  %8s  %8s', '', 'Right', 'Up', 'Left', 'Down');
        fprintf('--- Same, per (bar length x position) --- the %d combinations this session ran\n', ...
            nLengths * 4);
        fprintf('\nMean Reaction Time (s) [target-onset -> leave-center]:\n%s\n', lenHeader);
        for L = 1:nLengths
            fprintf('%s%s\n', SessionReport.lenRowLabel(L, target_angles, lengthCategory, catNames), ...
                SessionReport.numRow(mean_RT_lenpos(L, :), '%8.3f'));
        end
        fprintf('\nPercentage Correct (%%):\n%s\n', lenHeader);
        for L = 1:nLengths
            fprintf('%s%s\n', SessionReport.lenRowLabel(L, target_angles, lengthCategory, catNames), ...
                SessionReport.numRow(percent_correct_lenpos(L, :), '%8.2f'));
        end
        fprintf('\nTrial Counts (correct / total):\n%s\n', lenHeader);
        for L = 1:nLengths
            counts = cell(1, 4);
            for j = 1:4
                counts{j} = sprintf('%8s', sprintf('%d/%d', ...
                    correct_trials_lenpos(L, j), total_trials_lenpos(L, j)));
            end
            fprintf('%s%s\n', SessionReport.lenRowLabel(L, target_angles, lengthCategory, catNames), ...
                strjoin(counts, '  '));
        end
        fprintf('\n');
        end

        function duration(sessionSeconds, nTrials)
        % DURATION  How long the session actually took, from the first hold.
        %
        % Shared by BOTH engines, like reward() below and for the same
        % reason: they measure it identically, so it is formatted here once
        % instead of twice. Printed while the diary is still on, so it lands
        % in the exported session log as well as the command window.
        %
        % The clock starts when the subject first holds in the centre, not
        % when the task launched: trial 1 can wait a long time for a subject
        % to engage, and that wait says nothing about how long the session
        % took. From there it runs unbroken to the end of the trial loop --
        % an early exit does not stop it, so that trial's time counts up to
        % the next trial's hold. Wall clock, so an operator pause is
        % included; teardown (saving, printing, closing the window) is not.
        %
        % INPUT
        %   sessionSeconds : elapsed seconds, or [] if no trial ever reached
        %                    the hold (reported as such, not as 0)
        %   nTrials        : trials the session ran, for the per-trial mean.
        %                    Optional; omit or 0 to print the total only.
        if nargin < 2 || isempty(nTrials), nTrials = 0; end
        fprintf('\n======= SESSION TIME =======\n');
        if isempty(sessionSeconds)
            fprintf('No trial ever reached the hold -- the session clock never started.\n');
            return;
        end
        fprintf('Total          : %s  (%.1f s, from the first hold to the end of the last trial)\n', ...
            FormatElapsedTime(sessionSeconds), sessionSeconds);
        if nTrials > 0
            fprintf('Per trial      : %.1f s over %d trial(s)\n', sessionSeconds / nTrials, nTrials);
        end
        end

        function reward(pulsesTask, secTask, pulsesManual, secManual, mlPerSec)
        % REWARD  How much water the subject was given this session, split
        % into the two independent ways it can be delivered: the automatic
        % pulse on every correct trial (EP.REWARD), and the operator's manual
        % 'r' key presses. Shared by BOTH engines -- CenterOutTask.m and
        % CenterInTask.m have the same two reward paths and the same key, so
        % the accounting lives here once instead of being formatted twice.
        %
        % The seconds reported are VALVE-OPEN TIME actually commanded, summed
        % from what Rewards.m returns per call -- not (trials x nominal reward
        % time). That distinction matters: Rewards.m clamps each pulse to
        % 1-1000 ms for the Synapse gizmo and sends nothing at all when the
        % UDP link is absent, so a total recomputed from the GUI's Reward
        % field would overstate the water in exactly the cases an operator
        % most needs to catch.
        %
        % mlPerSec is the rig's own valve calibration (orgParams.rewardMlPerSec,
        % mL delivered per second of valve-open time). It has no sensible
        % default -- it depends on line pressure and tubing -- so when it is
        % 0/empty this prints the valve time alone and says how to get mL,
        % rather than inventing a conversion factor.
        if nargin < 5 || isempty(mlPerSec), mlPerSec = 0; end
        totalPulses = pulsesTask + pulsesManual;
        totalSec    = secTask + secManual;
        fprintf('\n======= REWARD DELIVERED =======\n');
        fprintf('%-24s %6d pulse(s)  %9.3f s\n', 'Correct trials:', pulsesTask, secTask);
        fprintf('%-24s %6d pulse(s)  %9.3f s\n', 'Manual (r key):', pulsesManual, secManual);
        fprintf('%-24s %6d pulse(s)  %9.3f s\n', 'TOTAL valve-open time:', totalPulses, totalSec);
        if mlPerSec > 0
            fprintf('%-24s %9.2f mL   (calibration %.3f mL/s)\n', 'Estimated water:', ...
                totalSec * mlPerSec, mlPerSec);
        else
            fprintf(['%-24s set orgParams.rewardMlPerSec (console "Water mL per valve-s")\n' ...
                '%-24s to this rig''s valve calibration to also report mL.\n'], ...
                'Estimated water:', '');
        end
        % A run that triggered rewards but delivered no valve time means every
        % Rewards() call bailed out -- the UDP link to Synapse was missing, so
        % the subject worked for nothing. Worth shouting about: the trial log
        % will still be full of "correct" rows.
        if totalPulses > 0 && totalSec == 0
            fprintf(['WARNING: %d reward pulse(s) were triggered but NONE were delivered ' ...
                '(no Synapse UDP link).\n'], totalPulses);
        end
        fprintf('================================\n');
        end

        function confusion(confusionMat, sessionMode)
        % CONFUSION  ML-style confusion matrix: rows = true category,
        % columns = chosen category, tallied from every attempt that actually
        % reached a target selection -- see confusionMat in the main function
        % (early exits, which never chose a category, are excluded; those are
        % already reported separately as early-exit errors elsewhere). The
        % diagonal is correct trials; an off-diagonal cell (row t, col c) is a
        % wrong-target error where the subject picked category c's colour instead
        % of the true category t.
        %
        % A PURE 2-cat session (sessionMode == '2cat') collapses this to a 2x2
        % Short/Long matrix instead of padding a 3x3 with an always-zero Mid
        % row/column -- Mid never occurs there. 'alternate'/'interleaved'
        % sessions genuinely draw Mid trials some of the time, so they keep the
        % full 3x3.
        if nargin < 2, sessionMode = ''; end
        names = ColorCategoryMap.categoryNames();
        if strcmpi(sessionMode, '2cat')
            confusionMat = confusionMat([1 3], [1 3]);
            names = names([1 3]);
        end
        nCat = numel(names);
        total = sum(confusionMat(:));
        if total == 0
            fprintf('\nNo target selections recorded; skipping confusion matrix.\n');
            return;
        end
        fprintf('\n======= CONFUSION MATRIX (true category x chosen category) =======\n');
        fprintf('%14s', '');
        for c = 1:nCat, fprintf('  %8s', names{c}); end
        fprintf('  %8s  %8s\n', 'Total', 'Recall');
        for r = 1:nCat
            rowTotal = sum(confusionMat(r, :));
            if rowTotal > 0
                recallStr = sprintf('%6.1f%%', 100 * confusionMat(r, r) / rowTotal);
            else
                recallStr = '     n/a';
            end
            fprintf('True %-9s', names{r});
            for c = 1:nCat, fprintf('  %8d', confusionMat(r, c)); end
            fprintf('  %8d  %8s\n', rowTotal, recallStr);
        end
        fprintf('%14s', 'Column total');
        for c = 1:nCat, fprintf('  %8d', sum(confusionMat(:, c))); end
        fprintf('\n');
        fprintf('\nOverall accuracy (of trials that reached a selection): %.1f%%  (%d/%d)\n', ...
            100 * trace(confusionMat) / total, trace(confusionMat), total);
        fprintf('====================================================================\n');
        end

        function signalDetection(confusionMat, sessionMode)
        % SIGNALDETECTION  Signal-detection-theory (SDT) breakdown of the same
        % confusionMat SessionReport.confusion reports, one 2x2 table per category.
        %
        % A PURE 2-cat session (sessionMode == '2cat') runs this over the
        % collapsed 2x2 Short/Long matrix (see SessionReport.confusion) instead
        % of the full 3x3 -- category 3 (Mid) never occurs there, so there is no
        % one-vs-rest table to report for it.
        %
        % CAVEAT, read before reporting these numbers. The classical SDT 2x2 table
        % (hits / misses / false alarms / correct rejections) is defined for a
        % BINARY yes-no decision about one signal. This task is a 3-category
        % ordinal classification, so there is no single 2x2 table for it. What is
        % printed below is the standard ONE-VS-REST decomposition: for category c,
        % "the bar really was c" is the signal and the other two categories are
        % noise, giving three separate 2x2 tables. That is a descriptive
        % convenience borrowed from multiclass classification, NOT a generative
        % model of the task -- it discards the ordering of Short < Mid < Long and
        % treats a Short-for-Long confusion as equivalent to a Short-for-Mid one,
        % which for a graded length continuum it is not. The model that does
        % respect the ordering is the two-boundary (cumulative / indecision) model
        % fit elsewhere in the analysis pipeline. Use d' here as a per-category
        % descriptive summary, not as the task's sensitivity parameter.
        %
        % Rates use the LOG-LINEAR correction (add 0.5 to each cell count and 1 to
        % each row total) applied unconditionally, not only to extreme cells. With
        % raw proportions, a category with no misses gives a hit rate of exactly 1
        % and a d' of infinity, which is an artifact of finite sampling rather than
        % perfect sensitivity; correcting only the offending cells biases the
        % remaining ones by comparison, so the correction is applied to every cell
        % for internal consistency.
        %
        %   d'        = z(H) - z(F)     -- separation between the signal and noise
        %                                  distributions, in SD units. 0 = chance.
        %   criterion = -(z(H) + z(F))/2 -- how conservative the observer is.
        %                                  0 = unbiased, >0 = reluctant to answer
        %                                  "this category", <0 = over-reports it.
        if nargin < 2, sessionMode = ''; end
        names = ColorCategoryMap.categoryNames();
        if strcmpi(sessionMode, '2cat')
            confusionMat = confusionMat([1 3], [1 3]);
            names = names([1 3]);
        end
        nCat = numel(names);
        total = sum(confusionMat(:));
        if total == 0
            fprintf('\nNo target selections recorded; skipping signal-detection breakdown.\n');
            return;
        end

        fprintf('\n======= SIGNAL DETECTION (one-vs-rest per category) =======\n');
        dPrimeAll = nan(1, nCat);
        critAll   = nan(1, nCat);
        for c = 1:nCat
            hits    = confusionMat(c, c);
            misses  = sum(confusionMat(c, :)) - hits;
            falseAl = sum(confusionMat(:, c)) - hits;
            correjs = total - hits - misses - falseAl;
            if (hits + misses) == 0 && (falseAl + correjs) == 0
                continue;
            end

            fprintf('\n--- Signal = %s ---\n', names{c});
            fprintf('%18s %10s %10s %8s\n', '', 'Resp YES', 'Resp NO', 'Total');
            fprintf('%-12s %5s %10d %10d %8d\n', ['Stim ' names{c}], '', hits, misses, hits + misses);
            fprintf('%-12s %5s %10d %10d %8d\n', 'Stim other',       '', falseAl, correjs, falseAl + correjs);
            fprintf('%18s %10d %10d %8d\n', 'Total', hits + falseAl, misses + correjs, total);

            hitRate = (hits    + 0.5) / (hits    + misses  + 1);
            faRate  = (falseAl + 0.5) / (falseAl + correjs + 1);
            dPrime  = NormInvNoTB(hitRate) - NormInvNoTB(faRate);
            crit    = -0.5 * (NormInvNoTB(hitRate) + NormInvNoTB(faRate));
            dPrimeAll(c) = dPrime;
            critAll(c)   = crit;

            if (hits + falseAl) > 0
                precision = hits / (hits + falseAl);
            else
                precision = nan;
            end
            if (hits + misses) > 0
                recall = hits / (hits + misses);
            else
                recall = nan;
            end
            if ~isnan(precision) && ~isnan(recall) && (precision + recall) > 0
                f1 = 2 * precision * recall / (precision + recall);
            else
                f1 = nan;
            end

            fprintf('  Hit rate %.3f   FA rate %.3f   (log-linear corrected)\n', hitRate, faRate);
            fprintf('  d'' = %.3f   criterion = %+.3f\n', dPrime, crit);
            fprintf('  Precision %.3f   Recall %.3f   F1 %.3f\n', precision, recall, f1);
        end

        fprintf('\n--- Summary across categories ---\n');
        fprintf('%10s %10s %12s\n', 'Category', 'd''', 'criterion');
        for c = 1:nCat
            if isnan(dPrimeAll(c))
                fprintf('%10s %10s %12s\n', names{c}, 'n/a', 'n/a');
            else
                fprintf('%10s %10.3f %+12.3f\n', names{c}, dPrimeAll(c), critAll(c));
            end
        end
        fprintf('==========================================================\n');
        end

    end

    methods (Static, Access = private)

        function s = lenRowLabel(L, target_angles, lengthCategory, catNames)
        % Row label shared by all three per-(length x position) tables:
        % '  L. <VA> deg <Category>: ', padded to a fixed 24 characters so
        % the four data columns after it line up down the whole table, and
        % so the header can be built from the same width instead of
        % hand-typed spaces (which is how the older tables in this file
        % drifted out of alignment).
        %
        % The category name is on every row on purpose: with a bar subset
        % active, row 3 is not necessarily the third length of the full set
        % and "lengths 1-4 are Short" stops being true.
        name = '';
        if ~isempty(lengthCategory) && L <= numel(lengthCategory)
            name = catNames{lengthCategory(L)};
        end
        s = sprintf('  %2d. %6.4f deg %-5s: ', L, target_angles(L), name);
        end

        function s = numRow(vals, fmt)
        % One table row's four numeric columns, NaN printed as a dash.
        % NaN here means "this combination produced no trial to average or
        % divide by", which is a different statement from a measured 0 --
        % and a dash cannot be mistaken for one the way '0.00' can.
        parts = cell(1, numel(vals));
        for j = 1:numel(vals)
            if isnan(vals(j))
                parts{j} = sprintf('%8s', '--');
            else
                parts{j} = sprintf(fmt, vals(j));
            end
        end
        s = strjoin(parts, '  ');
        end

    end
end