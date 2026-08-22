function handles = InitTaskHandles(taskName)
% INITTASKHANDLES  Auto-create a minimal status figure exposing the 6
% fixed field names (dlgTrainingMain/text77/edit91/edit92/editTrainRepe/
% textSessionTime) both engines write live status into, plus the optional
% textBreakdown box. Used when the caller didn't pass orgParams.handles
% (e.g. calling CenterOutTask or CenterInTask directly, without going
% through CenterConsole.m) -- the same fields OffrigPlay.m otherwise has to
% mock by hand.
% Paola Castillo 2026-07-31
%
%   INPUT  taskName : used only for the status figure's window title
%          (e.g. 'CenterOutTask', 'CenterInTask').
statusFig = figure('Name', [taskName ' status'], 'NumberTitle', 'off', ...
    'MenuBar', 'none', 'Position', [100 100 340 360]);
handles.dlgTrainingMain = statusFig;
handles.text77 = uicontrol('Parent', statusFig, 'Style', 'text', 'String', 'idle', ...
    'Position', [20 320 300 24], 'HorizontalAlignment', 'left');
% 7th, optional field (see CenterConsole.runTask): CenterOutTask's live
% per-block/per-category breakdown. Supplied here so a direct caller gets
% the same information the console shows; both engines guard it with
% isfield, so omitting it is never an error.
handles.textBreakdown = uicontrol('Parent', statusFig, 'Style', 'text', 'String', '', ...
    'FontName', 'FixedWidth', 'FontSize', 9, 'Position', [20 230 300 80], ...
    'HorizontalAlignment', 'left');
handles.edit91        = uicontrol('Parent', statusFig, 'Style', 'edit', 'String', '0', ...
    'Position', [20 160 300 24]);
handles.edit92        = uicontrol('Parent', statusFig, 'Style', 'edit', 'String', '0', ...
    'Position', [20 130 300 24]);
handles.editTrainRepe = uicontrol('Parent', statusFig, 'Style', 'edit', 'String', '0', ...
    'Position', [20 100 300 24]);
handles.textSessionTime = uicontrol('Parent', statusFig, 'Style', 'edit', 'String', '00:00:00', ...
    'Position', [20 70 300 24]);
setappdata(statusFig, 'stop', 0);
end