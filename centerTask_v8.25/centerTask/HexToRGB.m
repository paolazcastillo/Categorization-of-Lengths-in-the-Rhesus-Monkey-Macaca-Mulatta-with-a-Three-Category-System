function rgb = HexToRGB(hexStr)
% HEXTORGB  Convert a 6-digit hex colour string to an [R G B] triplet in
% the 0-255 range (ColorCategoryMap's own convention, e.g. ORANGE = [255
% 165 0]). Accepts an optional leading '#' ('FFA500' or '#FFA500').
hexStr = strrep(hexStr, '#', '');
if numel(hexStr) ~= 6 || isempty(regexp(hexStr, '^[0-9A-Fa-f]{6}$', 'once'))
    error('HexToRGB:badFormat', ...
        'Expected a 6-digit hex colour (e.g. "FFA500" or "#FFA500"); got "%s".', hexStr);
end
rgb = [hex2dec(hexStr(1:2)), hex2dec(hexStr(3:4)), hex2dec(hexStr(5:6))];
end
