classdef RZ2Link < handle
% RZ2LINK  The UDP receive side of the RZ2 joystick relay, behind one API.
%
% WHY THIS EXISTS (2026-09-10). Computer 2 is MATLAB R2016b, so udpport() is
% unavailable and the link ran on the legacy udp() object. That object
% delivers datagrams to MATLAB through a Java helper thread that fills
% BytesAvailable on its own schedule, and on this rig that schedule is
% coarse: with the relay sending every ~23 ms, 33% of 67 ms drain windows
% in DiagnoseRZ2Cursor came back EMPTY, which is impossible if datagrams
% were being handed over as they arrive (three relay cycles fit in one
% window). They were being handed over in clumps, and the wait for the next
% clump is most of the ~72 ms sample age measured on 09-Sep. The other
% part is Computer 1's own cycle time; see StepJoystickRelay.m.
%
% java.nio.channels.DatagramChannel in non-blocking mode has no helper
% thread. receive() returns immediately with a datagram if the OS has one
% and null if it does not, so the drain loop in ReadRZ2Joystick.m sees the
% OS queue directly, at frame rate. It ships with every JRE MATLAB has
% bundled since long before R2016b.
%
% Preference order: java (nio) -> udpport (R2019b+) -> legacy udp(). The
% mode actually in use is in .mode and printed by CleanupRZ2Joystick.m.
% UserData lives HERE, on this handle, in every mode, so the rest of the
% code reads rz2.port.UserData exactly as it did when rz2.port was the udp
% object.
%
% API
%   link = RZ2Link(localHost, localPort, remoteHost, remotePort, rcvBufBytes, inputDatagramBytes)
%   [raw, ok] = link.readOne()    % one datagram as char; ok=false when none queued
%   n = link.pending()            % queued datagrams/bytes; java: 0 if the last
%                                 % readOne found the queue empty, else 1 (unknown, >0)
%   n = link.flush(maxDatagrams)  % discard everything queued, return count
%   link.close()
%   s = link.describe()           % one-line description for logs
%
% See also: SetupRZ2Joystick, ReadRZ2Joystick, FlushRZ2Joystick, CleanupRZ2Joystick

    properties
        UserData            % the link's running state struct (see SetupRZ2Joystick.m)
    end

    properties (SetAccess = private)
        mode                % 'java' | 'udpport' | 'legacy'
        localHost
        localPort
        remoteHost
        remotePort
        InputBufferSize     % bytes requested for the OS/receive buffer
        lastReadEmpty       % true when the last readOne() found nothing (java mode)
        nReadCalls
        nReadEmpty
        nReadErrors         % readOne() calls that threw (java mode) and were treated as empty
    end

    properties (Access = private)
        ch                  % java DatagramChannel (java mode)
        jbuf                % java ByteBuffer (java mode)
        u                   % udpport or udp object (other modes)
    end

    methods
        function obj = RZ2Link(localHost, localPort, remoteHost, remotePort, rcvBufBytes, inputDatagramBytes)
            if nargin < 5 || isempty(rcvBufBytes), rcvBufBytes = 4194304; end
            if nargin < 6 || isempty(inputDatagramBytes), inputDatagramBytes = 8192; end
            obj.localHost       = localHost;
            obj.localPort       = localPort;
            obj.remoteHost      = remoteHost;
            obj.remotePort      = remotePort;
            obj.InputBufferSize = rcvBufBytes;
            obj.lastReadEmpty   = true;
            obj.nReadCalls      = 0;
            obj.nReadEmpty      = 0;
            obj.nReadErrors     = 0;
            obj.UserData        = struct();

            errs = {};

            % --- 1. Java NIO, non-blocking ----------------------------------
            % javaMethod/javaObject rather than dotted static calls, so the
            % same file also parses and runs under Octave for testing.
            try
                ch = javaMethod('open', 'java.nio.channels.DatagramChannel');
                ch.configureBlocking(false);
                sock = ch.socket();
                sock.setReceiveBufferSize(int32(rcvBufBytes));
                inet = javaMethod('getByName', 'java.net.InetAddress', localHost);
                addr = javaObject('java.net.InetSocketAddress', inet, int32(localPort));
                sock.bind(addr);
                obj.ch   = ch;
                obj.jbuf = javaMethod('allocate', 'java.nio.ByteBuffer', int32(max(inputDatagramBytes, 65535)));
                obj.mode = 'java';
                return;
            catch ME
                errs{end+1} = ['java: ' ME.message];
                try, ch.close(); catch, end
            end

            % --- 2. udpport (R2019b+) ---------------------------------------
            try
                u = udpport('datagram', 'IPV4', 'LocalHost', localHost, 'LocalPort', localPort);
                try, configureTerminator(u, 'LF'); catch, end
                obj.u    = u;
                obj.mode = 'udpport';
                return;
            catch ME
                errs{end+1} = ['udpport: ' ME.message];
            end

            % --- 3. legacy udp() --------------------------------------------
            try
                u = udp(remoteHost, remotePort, 'LocalHost', localHost, 'LocalPort', localPort);
                u.DatagramTerminateMode  = 'on';
                u.InputBufferSize        = rcvBufBytes;
                u.InputDatagramPacketSize = inputDatagramBytes;
                fopen(u);
                obj.u    = u;
                obj.mode = 'legacy';
                return;
            catch ME
                errs{end+1} = ['legacy udp: ' ME.message];
            end

            error('RZ2Link:noTransport', 'No UDP transport could be opened on %s:%d -- %s', ...
                localHost, localPort, strjoin(errs, ' | '));
        end

        function [raw, ok] = readOne(obj)
            obj.nReadCalls = obj.nReadCalls + 1;
            raw = '';
            ok  = false;
            switch obj.mode
                case 'java'
                    obj.jbuf.clear();
                    try
                        src = obj.ch.receive(obj.jbuf);
                    catch ME
                        % A transient Java exception on the non-blocking
                        % receive (e.g. an ICMP port-unreachable if the
                        % Computer 1 relay bounces) used to propagate out of
                        % readOne() uncaught and abort the whole session for
                        % a condition that, like an empty datagram, is
                        % recoverable on the next frame. Count and treat it
                        % as an empty read instead.
                        obj.nReadErrors = obj.nReadErrors + 1;
                        obj.lastReadEmpty = true;
                        obj.nReadEmpty = obj.nReadEmpty + 1;
                        return;
                    end
                    if isempty(src)
                        obj.lastReadEmpty = true;
                        obj.nReadEmpty = obj.nReadEmpty + 1;
                        return;
                    end
                    n = obj.jbuf.position();
                    if n <= 0
                        obj.lastReadEmpty = true;
                        obj.nReadEmpty = obj.nReadEmpty + 1;
                        return;
                    end
                    obj.jbuf.flip();
                    bytes = obj.jbuf.array();
                    raw = char(typecast(int8(bytes(1:n)), 'uint8'));
                    raw = raw(:)';
                    obj.lastReadEmpty = false;
                    ok = true;
                case 'udpport'
                    if obj.u.NumDatagramsAvailable <= 0
                        obj.lastReadEmpty = true;
                        obj.nReadEmpty = obj.nReadEmpty + 1;
                        return;
                    end
                    d   = read(obj.u, 1, 'char');
                    raw = char(d.Data);
                    obj.lastReadEmpty = false;
                    ok = true;
                otherwise
                    if obj.u.BytesAvailable <= 0
                        obj.lastReadEmpty = true;
                        obj.nReadEmpty = obj.nReadEmpty + 1;
                        return;
                    end
                    raw = fscanf(obj.u);
                    obj.lastReadEmpty = false;
                    ok = true;
            end
        end

        function n = pending(obj)
            switch obj.mode
                case 'java'
                    n = double(~obj.lastReadEmpty);
                case 'udpport'
                    n = obj.u.NumDatagramsAvailable;
                otherwise
                    n = obj.u.BytesAvailable;
            end
        end

        function n = flush(obj, maxDatagrams)
            if nargin < 2 || isempty(maxDatagrams), maxDatagrams = 200000; end
            n = 0;
            switch obj.mode
                case 'java'
                    while n < maxDatagrams
                        [~, ok] = obj.readOne();
                        if ~ok, break; end
                        n = n + 1;
                    end
                case 'udpport'
                    n = obj.u.NumDatagramsAvailable;
                    if n > 0, flush(obj.u, 'input'); end
                otherwise
                    n = obj.u.BytesAvailable;
                    if n > 0, flushinput(obj.u); end
            end
            obj.lastReadEmpty = true;
        end

        function close(obj)
            switch obj.mode
                case 'java'
                    try, obj.ch.close(); catch, end
                case 'udpport'
                    try, delete(obj.u); catch, end
                otherwise
                    try, fclose(obj.u); catch, end
                    try, delete(obj.u); catch, end
            end
        end

        function s = describe(obj)
            switch obj.mode
                case 'java'
                    s = sprintf('java.nio DatagramChannel, non-blocking, %s:%d, rcvbuf %d B', ...
                        obj.localHost, obj.localPort, obj.InputBufferSize);
                case 'udpport'
                    s = sprintf('udpport datagram, %s:%d', obj.localHost, obj.localPort);
                otherwise
                    s = sprintf('legacy udp(), %s:%d, InputBufferSize %d B', ...
                        obj.localHost, obj.localPort, obj.InputBufferSize);
            end
        end

        function tf = isLegacy(obj)
            tf = strcmp(obj.mode, 'legacy');
        end

        function tf = countsBytes(obj)
            tf = strcmp(obj.mode, 'legacy');
        end
    end
end