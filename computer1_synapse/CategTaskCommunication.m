function CategTaskCommunication()
% CATEGTASKCOMMUNICATION  Launcher for the Synapse-side communication bridge.
%   Programmatic figure()/uicontrol() GUI (no .fig file needed), Computer 1
%   only (Windows). The "Run" button adds the local 'libraries' folder and
%   computer1_synapse/ to the path, publishes the GUI handles globally (as
%   CommunicationCategTaskACTX expects), and calls
%   computer1_synapse/CommunicationCategTaskACTX.m, the ActiveX routine
%   that bridges this (Synapse) computer to the task computer over UDP.
%   No eye-tracking controls (removed per lab request); no database/NAS
%   connection either.
%
% See also: computer1_synapse/CommunicationCategTaskACTX

fig = figure('Name', 'CategTask Communication', 'NumberTitle', 'off', ...
    'MenuBar', 'none', 'ToolBar', 'none', 'Resize', 'off', ...
    'Color', [0.94 0.94 0.96], 'Position', [80 60 420 260]);

titleFont = {'FontSize', 12, 'FontWeight', 'bold'};
labelFont = {'FontSize', 9};
panelBG   = get(fig, 'Color');

uicontrol('Parent', fig, 'Style', 'text', 'String', 'CategTask Communication', ...
    titleFont{:}, 'BackgroundColor', panelBG, ...
    'Position', [15 215 390 24], 'HorizontalAlignment', 'left');

ui.butRun = uicontrol('Parent', fig, 'Style', 'pushbutton', 'String', 'Run', ...
    'FontSize', 11, 'FontWeight', 'bold', 'Position', [15 165 120 34], ...
    'Callback', @pushbuttonRun_Callback);

ui.text6 = uicontrol('Parent', fig, 'Style', 'text', 'String', 'Idle', ...
    'FontSize', 10, 'ForegroundColor', [0 0 0.6], 'BackgroundColor', panelBG, ...
    'Position', [15 120 390 22], 'HorizontalAlignment', 'left');
ui.text7 = uicontrol('Parent', fig, 'Style', 'text', 'String', '', ...
    'FontSize', 10, 'BackgroundColor', panelBG, ...
    'Position', [15 90 390 22], 'HorizontalAlignment', 'left');
ui.text9 = uicontrol('Parent', fig, 'Style', 'text', 'String', '', ...
    'FontSize', 10, 'BackgroundColor', panelBG, ...
    'Position', [15 60 390 22], 'HorizontalAlignment', 'left');

guidata(fig, ui);
end

% ===========================================================================
function pushbuttonRun_Callback(hObject, ~)
% Put libraries and computer1_synapse/ on the path, publish the GUI handles
% globally (CommunicationCategTaskACTX reads handles_glob, same contract
% the old GUIDE version used), then run it.
global handles_glob;
ui = guidata(hObject);
addpath(genpath('libraries'));
% This file already lives IN computer1_synapse/, so its own folder is the
% one to add. It used to append 'computer1_synapse' to that folder, which
% built the non-existent computer1_synapse/computer1_synapse and made
% addpath warn; the Run button only worked because MATLAB happened to have
% this file's own folder on the path already (that is how it got called).
addpath(fileparts(mfilename('fullpath')));
handles_glob = ui;
CommunicationCategTaskACTX();
end
