function HideCursorSafe(taskWindow)
% HIDECURSORSAFE  Purely cosmetic (hides the OS cursor icon over the
% stimulus window): on some Linux/multi-screen setups the underlying
% mouse-device resolution can fail even though taskWindow itself is a
% valid onscreen window, which must not be allowed to abort an
% otherwise-working session.
% Paola Castillo 2026-07-31
try
    HideCursor(taskWindow);
catch ME_hideCursor
    fprintf('WARNING: HideCursor failed (cursor will stay visible): %s\n', ME_hideCursor.message);
end
end