function report = ProbeJoystickBuffers(syn, waitSec)
% PROBEJOYSTICKBUFFERS  Diagnostic for the RZ2 joystick relay: lists every
% parameter (tag) each gizmo exposes to SynapseAPI, classifies each one, and
% runs a live handshake test to find a write-index tag (the *_i / idx_tag
% that would replace the diff-peak recalibration in StepJoystickRelay.m).
%
% Run on Computer 1 with Synapse in Preview (2) or Record (3). Pass an already
% open SynapseAPI handle, or call with no arguments to open one on localhost.
%
% report : struct array, one entry per (gizmo, parameter), with the raw info
%          plus the classification and, for scalar tags, the handshake delta.
%
% WAITSEC (2026-08-22): the handshake window, in seconds. Default 0.5, same
% as the original. IMPORTANT -- this is now ONE shared wait for ALL scalar
% candidates together (read v1 for everything, wait once, read v2 for
% everything), NOT one wait per parameter as before. The original design
% would have taken waitSec * (number of scalar candidates) to run --
% harmless at 0.5s (~1 min for ~100 params), but at waitSec=60 that would
% have been ~1-2 HOURS instead of 60 seconds. This way, ProbeJoystickBuffers(syn, 60)
% really does take about a minute, regardless of how many parameters exist.

    if nargin < 1 || isempty(syn)
        if isempty(which('SynapseAPI'))
            addpath('C:\TDT\Synapse\SynapseAPI\Matlab');
        end
        syn = SynapseAPI('localhost');
    end
    if nargin < 2 || isempty(waitSec)
        waitSec = 0.5;
    end
    if syn.getMode() < 2
        error('ProbeJoystickBuffers:mode', ...
            'Synapse must be in Preview (2) or Record (3). Current mode: %d', syn.getMode());
    end

    gizmos = cellstr(syn.getGizmoNames());
    fprintf('\n==== GIZMOS (%d) ====\n', numel(gizmos));
    for g = 1:numel(gizmos)
        fprintf('  %s\n', gizmos{g});
    end

    report = struct('gizmo', {}, 'param', {}, 'type', {}, 'access', {}, ...
        'size', {}, 'class', {}, 'v1', {}, 'v2', {}, 'delta', {});

    fprintf('\n%-14s %-16s %-8s %-10s %-10s %-16s\n', ...
        'GIZMO', 'PARAM', 'TYPE', 'ACCESS', 'SIZE', 'CLASS');
    fprintf('%s\n', repmat('-', 1, 78));

    for g = 1:numel(gizmos)
        gz = gizmos{g};
        params = safeParamNames(syn, gz);
        for p = 1:numel(params)
            pr = params{p};
            [ptype, paccess] = safeParamInfo(syn, gz, pr);
            psize = safeParamSize(syn, gz, pr);
            pclass = classifyParam(pr, psize, ptype);
            fprintf('%-14s %-16s %-8s %-10s %-10s %-16s\n', ...
                gz, pr, ptype, paccess, num2str(psize), pclass);
            report(end+1) = struct('gizmo', gz, 'param', pr, 'type', ptype, ...
                'access', paccess, 'size', psize, 'class', pclass, ...
                'v1', nan, 'v2', nan, 'delta', nan); %#ok<AGROW>
        end
    end

    fprintf('\n==== HANDSHAKE TEST (scalar/index candidates) ====\n');
    fprintf('Reading every candidate ONCE, waiting %.1f s (move the joystick\n', waitSec);
    fprintf('the whole time), then reading every candidate again. A value\n');
    fprintf('that changed is the live write index (or at least something live).\n\n');

    candidates = find(strcmp({report.class}, 'index?') | strcmp({report.class}, 'scalar'));

    for idx = candidates
        report(idx).v1 = safeScalar(syn, report(idx).gizmo, report(idx).param); %#ok<AGROW>
    end

    fprintf('Read #1 done (%d candidates). Waiting %.1f s -- move the joystick now...\n', ...
        numel(candidates), waitSec);
    tWait = tic;
    lastNudge = tic;
    while toc(tWait) < waitSec
        pause(min(1, waitSec - toc(tWait)));
        if waitSec > 10 && toc(lastNudge) >= 10
            fprintf('  ...%.0f / %.0f s\n', toc(tWait), waitSec);
            lastNudge = tic;
        end
    end

    for idx = candidates
        report(idx).v2 = safeScalar(syn, report(idx).gizmo, report(idx).param); %#ok<AGROW>
    end

    fprintf('\n%-14s %-16s %-14s %-14s %-12s %s\n', ...
        'GIZMO', 'PARAM', 'READ #1', 'READ #2', 'DELTA', 'VERDICT');
    fprintf('%s\n', repmat('-', 1, 86));

    foundIndex = {};
    for idx = candidates
        v1 = report(idx).v1; v2 = report(idx).v2;
        d = v2 - v1;
        report(idx).delta = d; %#ok<AGROW>
        verdict = 'static';
        if ~isnan(d) && d ~= 0
            verdict = 'CHANGING -> likely write index';
            foundIndex{end+1} = sprintf('%s.%s', report(idx).gizmo, report(idx).param); %#ok<AGROW>
        end
        fprintf('%-14s %-16s %-14s %-14s %-12s %s\n', ...
            report(idx).gizmo, report(idx).param, num2str(v1), num2str(v2), num2str(d), verdict);
    end

    fprintf('\n==== VERDICT ====\n');
    if isempty(foundIndex)
        fprintf(['No live write-index tag detected. The gizmos expose the data\n' ...
                 'buffer(s) but no *_i / index handshake tag reachable by the API.\n' ...
                 'To remove the diff-peak recalibration you must expose an index\n' ...
                 'tag in the gizmo (see Creating User Gizmos), then the relay can\n' ...
                 'read the write head directly.\n']);
    else
        fprintf('Live write-index tag(s) detected:\n');
        for k = 1:numel(foundIndex)
            fprintf('   %s\n', foundIndex{k});
        end
        fprintf(['\nUse this tag as the authoritative write head: read it each\n' ...
                 'cycle and pull only the samples between your last read and it.\n' ...
                 'This replaces ActiveIndexFromSnapshots / recalibration entirely.\n']);
    end
end

function names = safeParamNames(syn, gizmo)
    try
        raw = syn.getParameterNames(gizmo);
        names = cellstr(raw);
    catch
        names = {};
    end
    names = names(:).';
end

function [ptype, paccess] = safeParamInfo(syn, gizmo, param)
    ptype = '?'; paccess = '?';
    try
        info = syn.getParameterInfo(gizmo, param);
        if isstruct(info)
            if isfield(info, 'Type'),   ptype = char(string(info.Type));   end
            if isfield(info, 'Access'), paccess = char(string(info.Access)); end
        end
    catch
    end
end

function psize = safeParamSize(syn, gizmo, param)
    psize = nan;
    try
        psize = double(syn.getParameterSize(gizmo, param));
    catch
    end
end

function v = safeScalar(syn, gizmo, param)
    v = nan;
    try
        v = double(syn.getParameterValue(gizmo, param));
    catch
        try
            tmp = double(syn.getParameterValues(gizmo, param, 1, 0));
            if ~isempty(tmp), v = tmp(1); end
        catch
        end
    end
end

function c = classifyParam(name, psize, ptype)
    lname = lower(name);
    isIdxName = ~isempty(regexp(lname, '(_i$|idx|index|indx|curread|curwrite|writ|head|point)', 'once'));
    isScalar = ~isnan(psize) && psize <= 2;
    isBuffer = ~isnan(psize) && psize > 2;
    if isBuffer
        c = 'buffer';
    elseif isIdxName && isScalar
        c = 'index?';
    elseif isScalar
        c = 'scalar';
    else
        c = 'other';
    end
    if strcmp(ptype, 'Logic')
        c = [c '/logic'];
    end
end
