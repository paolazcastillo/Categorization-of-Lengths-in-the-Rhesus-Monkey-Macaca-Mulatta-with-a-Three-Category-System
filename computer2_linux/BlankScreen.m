function vbl = BlankScreen(taskWindow, color)
% BLANKSCREEN  The FillRect+Flip pair used everywhere a task blanks the
% screen (trial start, success/error feedback end, ITI). Always returns
% the Flip timestamp; callers that don't need it just don't capture it,
% same as calling Screen('Flip', ...) directly did.
Screen('FillRect', taskWindow, color);
vbl = Screen('Flip', taskWindow);
end