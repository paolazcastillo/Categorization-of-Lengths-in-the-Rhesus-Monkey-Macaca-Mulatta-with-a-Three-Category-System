function data = ReadUDP(uObject, block)
% READUDP  Read one UDP packet and decode it.
%   Packets from the task computer come in two shapes:
%     - Assignment statements, e.g. "reward=1;rewDuration=50;"; meant to
%       be eval'd in the CALLER's workspace (CommunicationCategTaskACTX
%       does eval(tmpStr) on the returned string), NOT captured as a return
%       value here. data = eval(pak) fails for these with "The expression
%       to the left of the equals sign is not a valid target for an
%       assignment," gets swallowed by this file's own catch, and returns
%       data = [], silently dropping every reward packet. Confirmed
%       2026-07-10.
%     - Expressions, e.g. a struct(...) constructor for new-trial info;
%       these DO produce a value and are safe to eval and capture directly.
%
%   Fix: detect assignment-statement packets by pattern (leading
%   "identifier =") and return them as the raw string, unevaluated; only
%   eval() packets that look like expressions.
if nargin < 2
    block = 0;
end
data = [];

try
    if block
        pak = fscanf(uObject);
    else
        if uObject.BytesAvailable
            pak = fscanf(uObject);
        else
            pak = '';
        end
    end

    if isempty(pak)
        data = [];
    elseif isAssignmentStatement(pak)
        data = pak;   % raw string; caller evals it (e.g. reward=1;rewDuration=50;)
    else
        data = eval(pak);   % expression, e.g. struct(...) for new-trial info
    end

catch e
    % One warning line carrying both the error and the offending packet,
    % instead of the inherited bare `pak` / display() pair; those echoed
    % the packet as an unsuppressed statement ("pak = ..."), so a relay that
    % starts receiving malformed datagrams floods the console of a running
    % session with untagged output. A warning is filterable and identifies
    % itself; the packet text is still there, which is the whole point of
    % having printed it.
    if exist('pak', 'var') && ~isempty(pak)
        warning('readUDP:decodeFailed', 'Could not decode UDP packet "%s": %s', ...
            strtrim(pak), e.message);
    else
        warning('readUDP:readFailed', 'UDP read failed: %s', e.message);
    end
    data = [];
end
end

% ===========================================================================
function tf = isAssignmentStatement(s)
% True if s starts with "identifier =" (not "==", "~=", "<=", ">=");
% i.e. it's a statement to eval() in the caller's workspace, not an
% expression whose value can be captured here.
tf = ~isempty(regexp(strtrim(s), '^[A-Za-z_]\w*\s*=[^=]', 'once'));
end