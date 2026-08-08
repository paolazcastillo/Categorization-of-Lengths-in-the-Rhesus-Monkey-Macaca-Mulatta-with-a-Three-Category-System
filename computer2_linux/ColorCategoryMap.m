classdef ColorCategoryMap
    % COLORCATEGORYMAP  Centralized colour <-> category mapping and naming.
    %
    %   Single source of truth for every colour-category association and for
    %   the category names written to logs and console reports, so the cue
    %   dots, the bar, the targets, the CSV's StimulusGroup column and the
    %   end-of-session tables can never drift out of sync the way a table
    %   copied into several files can.
    %
    %   Mapping:
    %     Category 1 (Short)  <-> Orange [255 165 0]
    %     Category 2 (Mid)    <-> Green  [0 255 0]
    %     Category 3 (Long)   <-> Blue   [0 0 255]
    %
    %   Usage:
    %     map = ColorCategoryMap();
    %     rgb     = map.categoryToRGB(2);        % [0 255 0] (green)
    %     allRGBs = map.allCategoryRGBs();       % [255 165 0; 0 255 0; 0 0 255]
    %     ColorCategoryMap.categoryToName(2)     % 'Mid'      (static, no instance)
    %     ColorCategoryMap.categoryNames()       % {'Short','Mid','Long'}
    %     ColorCategoryMap.categoryCSVNames()    % {'ShortGroup',...}
    %
    %   The naming accessors are STATIC because they depend on nothing but
    %   the category index; that lets report code fetch a label without
    %   constructing an object just to read a constant list.
    %
    %   The mapping is one-way by design: there is no RGB -> category
    %   lookup. The category is never lost in the first place, so nothing
    %   needs to decode the colour painted on a target to recover what the
    %   subject chose; the per-trial layout stores trialColorRows, which
    %   IS the category index, and the RGB is derived from it. Keying on an
    %   exact integer RGB triplet would also be fragile: any blended colour
    %   (e.g. the bar under barColorIntensity, which interpolates toward
    %   white) would miss the table.
    %
    %   Note: Categories are always 1-indexed (1=Short, 2=Mid, 3=Long).
    %         RGB values are always 0-255 (not normalized to [0,1]).

    properties (Constant)
        % Category identifiers
        NUM_CATEGORIES = 3
        CATEGORY_SHORT = 1
        CATEGORY_MID = 2
        CATEGORY_LONG = 3

        % RGB colors (0-255 range)
        ORANGE = [255 165 0]
        GREEN  = [0 255 0]
        BLUE   = [0 0 255]

        % Other standard colors used in feedback/ui
        RED    = [255 0 0]
        WHITE  = [255 255 255]
        BLACK  = [0 0 0]
        YELLOW = [255 255 0]
    end

    properties (Access = private)
        category_to_rgb_table    % [3 x 3]: rows 1-3 = categories, cols = R,G,B
    end

    methods
        function self = ColorCategoryMap()
            % Constructor: build the category -> RGB lookup table.
            self.category_to_rgb_table = [
                self.ORANGE;   % category 1
                self.GREEN;    % category 2
                self.BLUE      % category 3
            ];
        end

        function rgb = categoryToRGB(self, cat)
            % Map category to RGB.
            %   INPUT
            %     cat : category (1, 2, or 3)
            %   OUTPUT
            %     rgb : [1 x 3] RGB values (0-255)

            if cat < 1 || cat > self.NUM_CATEGORIES
                error('Category must be 1, 2, or 3; got %d', cat);
            end
            rgb = self.category_to_rgb_table(cat, :);
        end

        function allRGBs = allCategoryRGBs(self)
            % Return [3 x 3] matrix of all category RGBs (rows = categories).
            allRGBs = self.category_to_rgb_table;
        end
    end

    methods (Static)
        function names = categoryNames()
            % Human-readable category names, in category order.
            names = {'Short', 'Mid', 'Long'};
        end

        function names = categoryCSVNames()
            % CSV-friendly category names, in category order. These are the
            % literals written to the StimulusGroup column of trial_data_*.csv
            % and session_data_*.csv.
            names = {'ShortGroup', 'MidGroup', 'LongGroup'};
        end

        function categoryName = categoryToName(cat)
            % Human-readable name for one category; 'Unknown' if out of range.
            names = ColorCategoryMap.categoryNames();
            if cat < 1 || cat > numel(names)
                categoryName = 'Unknown';
            else
                categoryName = names{cat};
            end
        end

        function categoryNameCSV = categoryToCSVName(cat)
            % CSV-friendly name for one category; 'UnknownGroup' if out of range.
            names = ColorCategoryMap.categoryCSVNames();
            if cat < 1 || cat > numel(names)
                categoryNameCSV = 'UnknownGroup';
            else
                categoryNameCSV = names{cat};
            end
        end
    end
end