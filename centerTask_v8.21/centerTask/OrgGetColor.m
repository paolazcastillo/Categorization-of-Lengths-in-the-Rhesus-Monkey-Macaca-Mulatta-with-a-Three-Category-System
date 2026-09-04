function rgb = OrgGetColor(orgParams, fieldName, defaultRGB)
% ORGGETCOLOR  Like OrgGet, but for a hex-string colour field: falls back to
% defaultRGB (already an RGB triplet, e.g. ColorCategoryMap.ORANGE) when the
% console field is absent, and converts via HexToRGB.m otherwise.
%
% Shared by CenterOutTask.m (category colours) and CenterInTask.m
% (reach-mode target colour) -- moved out of CenterOutTask.m's own local
% helpers into its own file so both engines call the same code instead of
% each keeping a copy.
hexStr = OrgGet(orgParams, fieldName, '');
if isempty(hexStr)
    rgb = defaultRGB;
else
    rgb = HexToRGB(hexStr);
end
end
