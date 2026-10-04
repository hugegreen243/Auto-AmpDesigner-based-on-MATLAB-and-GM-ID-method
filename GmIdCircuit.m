classdef GmIdCircuit < handle
%GMIDCIRCUIT  电路层小顶层：一个具体拓扑 + 每管工作点 + 求解。
%
%   C = GmIdCircuit(dataN, dataP, 'Five-Transistor OTA', 'nmos', false)
%   C.setSpecs(struct('GBW',10e6,'SR',10e6,'ISS',20e-6,'CL',2e-12,'VDD',1.8))
%   C.initFromSpecs()                   「初始化」：按策略选点（VDS 给默认值，可逐管改）
%   C.setDevice('M1','VDS',0.25)         改单管 L / VDS / gmID（VDS 全部用户自定义）
%   res = C.solve()                      求解（电流/节点电压/饱和/增益/KCL）
%
% 数据源：dataN 是 NMOS 的 gm/ID 数据（GmIdData），dataP 是 PMOS 的；哪个没加载，
%         对应 type 的器件就标「无数据」（source='nodata'，W/Vgs/Vdsat/selfGain 为 NaN）。
%         不再用 µCox/Vth/gm-gds 解析模型糊弄，所有器件参数一律查 LUT。
%
% 求解口径（电流由拓扑自动分配）：
%   Id(i) = idFactor(i)*Iss     gm(i) = gmID(i)*Id(i)
%   W(i)  = Id(i)/(Id/W)         （查对应 type 的 LUT；无数据则 NaN）
%
% 节点电压口径（★ 无权威链、无“VDS 自洽”）：
%   唯一锚点是 GND = 0 V。每个 net 的电压由器件 VDS 沿 KVL 从 0 V 一路推出来：
%   一个器件的 |VDS| = 高电位 net 与低电位 net 之差（NMOS 高=漏、PMOS 高=源）。
%   每管 VDS 都是**用户自由输入**，工具不再按拓扑“自动分配 / 回填”任何 VDS。
%   · 只要从 GND 出发的路径上 VDS 齐全，该 net 电压就被唯一确定；
%   · 某条边 VDS 还没填（NaN）→ 该方向传不过去，下游 net 显示「—」，不报错；
%   · net 电压 > VDD（或 < 0）→ 标红警告（超压 / 负压），但照常显示。
%   VDD 不再是预设 rail：它的电压同样由链推出来，与 specs.VDD 比较即可看出裕量。
%
% 兼容 MATLAB R2018b。

    properties (SetAccess = private)
        dataN
        dataP
        topo
        st                    % 每管状态：L VDS gmID
        specs = struct('GBW',10e6,'SR',10e6,'ISS',20e-6,'CL',2e-12,'VDD',1.8);
        anchor = 'ISS';
        fd = false
        tol = 1e-3            % 节点电压一致性容差 [V]
        satMargin = 0.05      % VDS-Vdsat 超过它算“饱和”
        rails = {'GND','VDD'} % 电源轨名（GND 是唯一电压锚点；VDD 由链推出）
        last = []
    end

    %% ---------------- 构造与设置 ----------------
    methods
        function obj = GmIdCircuit(dataN, dataP, topoName, inType, fd)
            if nargin < 4 || isempty(inType), inType = 'nmos'; end
            if nargin < 5 || isempty(fd), fd = false; end
            obj.dataN = dataN;
            obj.dataP = dataP;
            obj.fd = logical(fd);
            obj.topo = GmIdTopology(topoName, inType, obj.fd);
            [L, VDS, gr] = obj.axesInfoDefault();
            n = numel(obj.topo.devices);
            obj.st = repmat(struct('L',NaN,'VDS',NaN,'gmID',NaN), 1, n);
            for k = 1:n
                if isempty(L)
                    obj.st(k).L = 0.5e-6;  obj.st(k).VDS = 0.5;  obj.st(k).gmID = 10;
                else
                    obj.st(k).L = L(1);
                    obj.st(k).VDS = VDS(min(3, numel(VDS)));
                    obj.st(k).gmID = min(max(10, gr(1)), gr(2));
                end
            end
        end

        function setSpecs(obj, s)
            f = {'GBW','SR','ISS','CL','VDD'};
            for k = 1:numel(f)
                if isfield(s, f{k}) && isfinite(s.(f{k})) && s.(f{k}) > 0
                    obj.specs.(f{k}) = s.(f{k});
                end
            end
            if ~isfield(s,'VDD'), obj.specs.VDD = 1.8; end
        end

        function setFD(obj, tf), obj.fd = logical(tf); end
        function nm = deviceNames(obj), nm = {obj.topo.devices.name}; end
        function d = deviceDef(obj, name), d = obj.topo.devices(obj.devIndex(name)); end
        function s = state(obj, name), s = obj.st(obj.devIndex(name)); end

        function tf = usesData(obj, name)
            %USESDATA 该器件对应 type（N/P）的数据是否已加载。
            k = obj.devIndex(name);
            tf = obj.hasData(obj.topo.devices(k).type);
        end

        function tf = hasData(obj, ty)
            %HASDATA 该 type 的数据是否已加载。
            if ty(1) == 'N', tf = ~isempty(obj.dataN) && obj.dataN.isLoaded();
            else,            tf = ~isempty(obj.dataP) && obj.dataP.isLoaded(); end
        end

        function d = dataFor(obj, ty)
            %DATAFOR 返回该 type 对应的 GmIdData。
            if ty(1) == 'N', d = obj.dataN; else, d = obj.dataP; end
        end

        function [L, VDS, gr] = axesInfoDefault(obj)
            %AXESINFODEFAULT 取「有数据」的那个 type 的坐标轴（两者都没有则返回空）。
            L = []; VDS = []; gr = [NaN NaN];
            if obj.hasData('N')
                [L, VDS, gr] = obj.dataN.axesInfo();
            elseif obj.hasData('P')
                [L, VDS, gr] = obj.dataP.axesInfo();
            end
        end

        function setDevice(obj, name, field, val)
            k = obj.devIndex(name);
            switch field
                case 'L'
                    if ~isscalar(val) || ~isnumeric(val) || ~isfinite(val) || val <= 0
                        error('GmIdCircuit:badL', 'L 必须是正的数值标量（单位 m）。');
                    end
                    d = obj.dataFor(obj.topo.devices(k).type);
                    L = [];
                    if ~isempty(d) && d.isLoaded(), [L, ~, ~] = d.axesInfo(); end
                    if ~isempty(L)
                        [~, i] = min(abs(L - val));
                        val = L(i);
                    end
                    obj.st(k).L = val;
                case 'VDS'
                    % VDS 允许留空（NaN）：表示该管 VDS 未填，节点链不经过它传递。
                    if ~isscalar(val) || ~isnumeric(val) || (~isnan(val) && ~isfinite(val))
                        error('GmIdCircuit:badVal', 'VDS 必须是有限标量或 NaN（留空）。');
                    end
                    if ~isnan(val) && val <= 0
                        error('GmIdCircuit:badVal', 'VDS 必须为正（或 NaN 表示留空）。');
                    end
                    obj.st(k).VDS = val;
                case 'gmID'
                    if ~isscalar(val) || ~isfinite(val) || val <= 0
                        error('GmIdCircuit:badVal', '%s 必须是正的有限标量。', field);
                    end
                    obj.st(k).(field) = val;
                otherwise
                    error('GmIdCircuit:badField', '未知字段 %s', field);
            end
        end

        function setAll(obj, st)
            for k = 1:numel(st)
                i = obj.devIndex(st(k).name);
                f = {'L','VDS','gmID'};
                for j = 1:numel(f)
                    if isfield(st, f{j}) && isfinite(st(k).(f{j})), obj.st(i).(f{j}) = st(k).(f{j}); end
                end
            end
        end

        function setAnchor(obj, val, how, name)
            if nargin < 4, name = ''; end
            switch lower(how)
                case 'iss'
                    obj.specs.ISS = val;
                case {'gm','id'}
                    if isempty(name), error('GmIdCircuit:needDev', '用 gm/Id 做锚必须给器件名。'); end
                    k = obj.devIndex(name);
                    Id = val / obj.st(k).gmID;
                    obj.specs.ISS = Id / obj.topo.devices(k).idFactor;
                otherwise
                    error('GmIdCircuit:badAnchor', '未知锚类型 %s', how);
            end
            obj.anchor = upper(how);
        end

        %% ---------------- 初始化 ----------------
        function warn = initFromSpecs(obj, specs, opt)
            %INITFROMSPECS 按指标/策略为每管选 L 与 gm/ID，并给 VDS 一个默认起手值。
            % 不再做“按层分配节点电压”的 VDS 自洽：每管 VDS 都是独立自由量，
            % 用户可逐个改；节点电压由 solve() 从 GND=0 V 沿 VDS 推出。
            if nargin >= 2 && ~isempty(specs), obj.setSpecs(specs); end
            if nargin < 3, opt = struct(); end
            [st, warn] = GmIdInit(obj.dataN, obj.dataP, obj.topo, obj.specs, opt);
            obj.setAll(st);
            obj.anchor = 'ISS';
            % 保证每管 VDS 都有个有限默认值（GmIdInit 已给；万一 NaN 就补 LUT 中点）
            warn = warn(:);
            [~, Vall, ~] = obj.axesInfoDefault();
            if isempty(Vall), Vall = 0.5; end
            vdef = Vall(min(3, numel(Vall)));
            for k = 1:numel(obj.st)
                if ~isfinite(obj.st(k).VDS), obj.st(k).VDS = vdef; end
            end
        end

        %% ---------------- 求解 ----------------
        function res = solve(obj)
            dev = obj.deviceSolution();
            nodes = obj.solveNodes();
            n = numel(dev);
            for k = 1:n
                vh = obj.netVal(nodes, obj.hiNet(obj.topo.devices(k)));
                vl = obj.netVal(nodes, obj.loNet(obj.topo.devices(k)));
                if isfinite(vh) && isfinite(vl), vdsAct = abs(vh - vl); else, vdsAct = NaN; end
                dev(k).VDSact = vdsAct;
                if ~dev(k).ok
                    % 无数据 / 不可用：不判饱和
                    dev(k).margin = NaN;
                    dev(k).sat = '不可用';
                else
                    % 饱和判据一律用「查表实际用的工作点 VDS」（dev(k).VDS = 用户输入）。
                    % 无权威链后，同一 net 上各边 VDS 由用户各自填写，节点差可能与该管
                    % 输入值略有出入；器件特性毕竟是按用户给的 VDS 查的表，故以它为准。
                    dev(k).margin = dev(k).VDS - dev(k).Vdsat;
                    if dev(k).margin >= obj.satMargin
                        dev(k).sat = '饱和';
                    elseif dev(k).margin >= 0
                        dev(k).sat = '临界';
                    else
                        dev(k).sat = '不饱和';
                    end
                end
            end
            g = obj.solveGain(dev);
            h = obj.solveHeadroom(dev, nodes);
            a = obj.kclAudit(dev);
            res = obj.packResult(dev, nodes, g, h, a);
            obj.last = res;
        end

        function res = result(obj)
            if isempty(obj.last), res = obj.solve(); else, res = obj.last; end
        end

        function dev = deviceSolution(obj)
            n = numel(obj.topo.devices);
            Iss = obj.specs.ISS;
            dev = repmat(obj.blankDev(), 1, n);
            for k = 1:n
                d = obj.topo.devices(k);  s = obj.st(k);
                dev(k).name = d.name;  dev(k).type = d.type;  dev(k).role = d.role;
                dev(k).L = s.L;  dev(k).VDS = s.VDS;  dev(k).gmid = s.gmID;
                dev(k).Id = d.idFactor * Iss;
                dev(k).gm = s.gmID * dev(k).Id;
                if obj.usesData(d.name)
                    dev(k).source = 'data';
                    dk = obj.dataFor(d.type);
                    [~, Vr, ~] = dk.axesInfo();
                    vdsLook = min(max(s.VDS, min(Vr)), max(Vr));   % 超出数据范围时用最近点取 Vdsat
                    q = dk.query(s.L, vdsLook, s.gmID);
                    if q.valid
                        dev(k).ok = true;
                        dev(k).Vgs = q.Vgs;  dev(k).Vdsat = q.Vdsat;
                        dev(k).fT = q.fT;    dev(k).selfGain = q.selfGain;
                        dev(k).W = dev(k).Id / q.IdW;
                        if abs(vdsLook - s.VDS) > 1e-9
                            dev(k).note = sprintf(['VDS=%.3f V 超出数据范围 [%.2f, %.2f] V：' ...
                                'Vdsat/Vgs/selfGain 取自最近点 VDS=%.2f V，饱和判定仍用真实 VDS。'], ...
                                s.VDS, min(Vr), max(Vr), vdsLook);
                        end
                    else
                        dev(k).note = sprintf('(L=%.3g, VDS=%.3g, gm/ID=%.3g) 超出数据范围，取值无效', ...
                            s.L, s.VDS, s.gmID);
                    end
                else
                    dev(k).ok = false;
                    dev(k).source = 'nodata';
                    dev(k).note = sprintf('无 %s 数据：请在数据源区填入 %s 的 gm/ID 数据路径', ...
                        d.type, upper(d.type));
                end
            end
        end

        function nodes = solveNodes(obj)
            %SOLVENODES 节点电压：唯一锚点 GND=0 V，沿器件 VDS 从 GND 逐条推出（BFS）。
            %
            % 每条器件的电学约束是  V(高电位端) - V(低电位端) = |VDS|：
            %   NMOS：高=漏 D、低=源 S；  PMOS：高=源 S、低=漏 D。
            % 从 GND(0 V) 出发，遇到电压已知的一端，就把另一端推出来；可双向推。
            % · 某条边的 VDS 未填（NaN）→ 该边不参与，下游 net 保持「—」（NaN）。
            % · 同一 net 被多条边推出不同值 → 取首个非冲突值并标红（矛盾）。
            % · 推出的 net 电压 > VDD 或 < 0 → 标红（超压 / 负压）。
            dev = obj.topo.devices;
            names = {};
            for k = 1:numel(dev), names = [names, {dev(k).D, dev(k).S, dev(k).G}]; end %#ok<AGROW>
            names = unique([names, obj.rails]);
            n = numel(names);
            val  = nan(1, n);
            kind = repmat({'node'}, 1, n);
            val(strcmp(names,'GND'))  = 0;
            kind(strcmp(names,'GND')) = {'rail'};

            e = repmat(struct('dev','','hiIdx',0,'loIdx',0,'vds',NaN,'type',''), 0, numel(dev));
            for k = 1:numel(dev)
                e(k).dev   = dev(k).name;
                e(k).hiIdx = find(strcmp(names, obj.hiNet(dev(k))), 1);
                e(k).loIdx = find(strcmp(names, obj.loNet(dev(k))), 1);
                e(k).vds   = obj.st(k).VDS;
                e(k).type  = dev(k).type;
            end

            conflict = false(1, n);
            cmsg = repmat({''}, 1, n);
            % ---- BFS：从已定电压的 net 出发，沿 VDS 已知的边扩散 ----
            for it = 1:(n + 2)
                changed = false;
                for k = 1:numel(e)
                    if ~isfinite(e(k).vds), continue; end        % 未填 VDS：跳过
                    i = e(k).hiIdx;  j = e(k).loIdx;
                    if isfinite(val(i)) && ~isfinite(val(j))
                        val(j) = val(i) - e(k).vds;  kind{j} = 'derived';  changed = true;
                    elseif ~isfinite(val(i)) && isfinite(val(j))
                        val(i) = val(j) + e(k).vds;  kind{i} = 'derived';  changed = true;
                    elseif isfinite(val(i)) && isfinite(val(j))
                        if abs((val(i) - val(j)) - e(k).vds) > obj.tol
                            conflict(i) = true;  conflict(j) = true;
                            cmsg{i} = sprintf('%s 的 VDS=%.3f V 与节点电压差 %.3f V 不一致（差 %.3f V）', ...
                                e(k).dev, e(k).vds, val(i)-val(j), abs(val(i)-val(j)-e(k).vds));
                            cmsg{j} = cmsg{i};
                        end
                    end
                end
                if ~changed, break; end
            end

            % ---- 超压 / 负压：照常显示，但标红警告 ----
            VDD = obj.specs.VDD;
            for i = 1:n
                if ~isfinite(val(i)) || any(strcmp(obj.rails, names{i})), continue; end
                if val(i) > VDD + 1e-9
                    conflict(i) = true;
                    if isempty(cmsg{i})
                        cmsg{i} = sprintf('节点 %s = %.3f V 超过 VDD=%.3f V（超压 %.3f V）', ...
                            names{i}, val(i), VDD, val(i)-VDD);
                    end
                elseif val(i) < -1e-9
                    conflict(i) = true;
                    if isempty(cmsg{i})
                        cmsg{i} = sprintf('节点 %s = %.3f V 低于 GND（负压 %.3f V）', names{i}, val(i), -val(i));
                    end
                end
            end

            % ---- 栅极：由源极 + Vgs 反推（仅当源极电压已定）----
            dsol = obj.deviceSolution();
            for k = 1:numel(dev)
                gi = find(strcmp(names, dev(k).G), 1);
                si = find(strcmp(names, dev(k).S), 1);
                if ~isfinite(val(si)) || ~dsol(k).ok, continue; end
                if dev(k).type == 'N', vg = val(si) + dsol(k).Vgs;
                else,                  vg = val(si) - dsol(k).Vgs; end
                if ~isfinite(val(gi))
                    val(gi) = vg;
                    if ~isempty(regexp(dev(k).G, '^(VB|VIN)', 'once')), kind{gi} = 'bias'; end
                elseif abs(val(gi) - vg) > 0.02 && isempty(cmsg{gi})
                    kind{gi} = 'bias';
                    cmsg{gi} = sprintf('%s 由多管共用，各管 Vgs 反推值相差 %.3f V（左右不对称）', ...
                        dev(k).G, abs(val(gi) - vg));
                end
            end
            nodes = struct('name', names, 'value', num2cell(val), 'kind', kind, ...
                'conflict', num2cell(conflict), 'msg', cmsg);
        end

        function g = solveGain(obj, dev)
            iIn = obj.inputIdx(dev);
            gmIn = dev(iIn).gm;
            rN = obj.branchR(dev, 'N');
            rP = obj.branchR(dev, 'P');
            if isnan(rN) && isnan(rP),     rout = NaN;
            elseif isnan(rN),              rout = rP;
            elseif isnan(rP),              rout = rN;
            else,                          rout = 1/(1/rN + 1/rP);
            end
            g = struct('gmIn', gmIn, 'rN', rN, 'rP', rP, 'rout', rout, 'av', gmIn*rout, ...
                'avDb', 20*log10(gmIn*rout), ...
                'note', sprintf('gm_in=%.4g uS, R_outN=%.4g ohm, R_outP=%.4g ohm', gmIn*1e6, rN, rP));
        end

        function r = branchR(obj, dev, type)
            if type == 'N', baseRole = obj.topo.nBaseRole; else, baseRole = obj.topo.pBaseRole; end
            roBase = obj.roOf(dev, type, baseRole);
            m = strcmp({obj.topo.devices.type}, type);
            roles = unique({obj.topo.devices(m).role});
            casRole = '';
            for j = 1:numel(roles)
                if ~isempty(strfind(lower(roles{j}), 'cascode')) %#ok<STREMP>
                    casRole = roles{j};
                end
            end
            if isempty(casRole), r = roBase; return; end
            [roCas, gmCas] = obj.roOf(dev, type, casRole);
            if isnan(roCas) || isnan(roBase), r = roBase;
            else, r = roCas*(1 + gmCas*roBase) + roBase;
            end
        end

        function [ro, gm] = roOf(obj, dev, type, role)
            ro = NaN;  gm = NaN;
            if isempty(role), return; end
            for j = 1:numel(dev)
                if dev(j).type == type && strcmp(dev(j).role, role) && dev(j).ok
                    gm = dev(j).gm;  ro = dev(j).selfGain / gm;  return;
                end
            end
        end

        function h = solveHeadroom(obj, dev, nodes)
            vmin = 0;
            for k = 1:numel(obj.topo.voutMinStack)
                vmin = vmin + obj.roleVdsat(dev, obj.topo.voutMinStack{k});
            end
            vmax = 0;
            for k = 1:numel(obj.topo.voutMaxStack)
                vmax = vmax + obj.roleVdsat(dev, obj.topo.voutMaxStack{k});
            end
            iIn = obj.inputIdx(dev);
            iTl = find(~cellfun(@isempty, strfind({dev.role}, '尾电流')), 1); %#ok<STRCLFH>
            vcmMin = dev(iIn).Vgs;
            if ~isempty(iTl), vcmMin = vcmMin + dev(iTl).Vdsat; end
            % 输入共模上限：由“负载/电流源”管所在轨决定，**不能写死 type=='P'**。
            %   镜像（PMOS 输入）后该管可能变成 N 型、源极接 GND，此时是下限约束。
            %   判据用其源极网名：接 VDD -> vcmMax = VDD - |Vgs|；接 GND -> 并入 vcmMin。
            vcmMax = NaN;
            for k = 1:numel(dev)
                r = dev(k).role;
                if isempty(strfind(r,'负载')) && isempty(strfind(r,'电流源')) %#ok<STREMP>
                    continue;
                end
                sRail = obj.topo.devices(k).S;   % 轨判据取拓扑端子（解的 dev 无 S 字段）
                if strcmp(sRail, 'VDD')
                    if isfinite(dev(k).Vgs)
                        vcmMax = obj.specs.VDD - abs(dev(k).Vgs);
                    end
                    break;
                elseif strcmp(sRail, 'GND')
                    if isnan(vcmMax) && isfinite(dev(k).Vgs)
                        vcmMin = max(vcmMin, abs(dev(k).Vgs));
                    end
                end
            end
            h = struct('voutMin', vmin, 'voutMax', obj.specs.VDD - vmax, ...
                'vcmMin', vcmMin, 'vcmMaxEst', vcmMax, 'vinReq', obj.netVal(nodes, 'VIN+'));
        end

        function a = kclAudit(obj, dev)
            names = {};
            for k = 1:numel(obj.topo.devices)
                names = [names, {obj.topo.devices(k).D, obj.topo.devices(k).S}]; %#ok<AGROW>
            end
            names = unique(names);
            rows = {};  worst = 0;
            for i = 1:numel(names)
                net = names{i};
                if any(strcmp(obj.topo.rails, net)), continue; end
                s = 0;
                for k = 1:numel(obj.topo.devices)
                    d = obj.topo.devices(k);
                    if strcmp(obj.hiNet(d), net), s = s - dev(k).Id; end
                    if strcmp(obj.loNet(d), net), s = s + dev(k).Id; end
                end
                worst = max(worst, abs(s));
                if abs(s) > 1e-12, rows{end+1} = sprintf('%s 电流不平衡 %.4g A', net, s); end %#ok<AGROW>
            end
            a = struct('worst', worst, 'rows', {rows});
        end

        function res = packResult(obj, dev, nodes, g, h, a)
            res = struct();
            res.topo = obj.topo;   res.specs = obj.specs;
            res.devices = dev;     res.nodes = nodes;
            res.kcl = a;           res.anchor = obj.anchor;   res.fd = obj.fd;
            issTot = 0;
            for k = 1:numel(obj.topo.devices)
                if strcmp(obj.topo.devices(k).S, 'VDD'), issTot = issTot + dev(k).Id; end
            end
            iIn = obj.inputIdx(dev);
            res.issTotal = issTot;
            res.power = obj.specs.VDD * issTot;
            res.gm1 = g.gmIn;   res.rout = g.rout;   res.av = g.av;   res.avDb = g.avDb;
            res.gainNote = g.note;   res.avReqDb = NaN;
            res.voutMin = h.voutMin;  res.voutMax = h.voutMax;
            res.voutSwing = h.voutMax - h.voutMin;
            res.vcmMin = h.vcmMin;    res.vcmMaxEst = h.vcmMaxEst;   res.vinReq = h.vinReq;
            res.iss = obj.specs.ISS;  res.srReq = obj.specs.SR;  res.sr = issTot/obj.specs.CL;
            res.idIn = dev(iIn).Id;
            res.gmidInReq = NaN;      res.gmidInUsed = dev(iIn).gmid;
            res.objectiveUsed = 'manual/interactive';
            res.inputSel = struct('L', dev(iIn).L, 'VDS', dev(iIn).VDS, 'gmid', dev(iIn).gmid, ...
                'IdW', dev(iIn).Id/max(dev(iIn).W,eps), 'Vgs', dev(iIn).Vgs, ...
                'Vdsat', dev(iIn).Vdsat, 'fT', dev(iIn).fT, 'selfGain', dev(iIn).selfGain);
            res.warnings = obj.collectWarnings(dev, nodes, g, a);
            [res.tableCols, res.tableData] = ampDesignTable(res);
        end

        function w = collectWarnings(obj, dev, nodes, g, a)
            w = {};
            for k = 1:numel(dev)
                if ~dev(k).ok
                    w{end+1} = sprintf('%s: %s', dev(k).name, dev(k).note); %#ok<AGROW>
                elseif strcmp(dev(k).sat, '不饱和')
                    w{end+1} = sprintf('%s 不饱和：工作点 |VDS|=%.3f V < Vdsat=%.3f V（差 %.3f V）', ...
                        dev(k).name, dev(k).VDS, dev(k).Vdsat, -dev(k).margin); %#ok<AGROW>
                elseif strcmp(dev(k).sat, '临界')
                    w{end+1} = sprintf('%s 临界饱和：|VDS|-Vdsat=%.3f V，裕量偏小', ...
                        dev(k).name, dev(k).margin); %#ok<AGROW>
                end
            end
            for i = 1:numel(nodes)
                if ~isempty(nodes(i).msg)
                    w{end+1} = sprintf('节点 %s: %s', nodes(i).name, nodes(i).msg); %#ok<AGROW>
                elseif ~isfinite(nodes(i).value) && ~any(strcmp(obj.rails, nodes(i).name))
                    w{end+1} = sprintf('节点 %s 电压未定：从 GND 出发的 VDS 路径上还有管子没填 VDS', ...
                        nodes(i).name); %#ok<AGROW>
                end
            end
            if a.worst > 1e-12
                w{end+1} = sprintf('拓扑电流分配不自洽（最大不平衡 %.4g A），检查 GmIdTopology 的 idFactor', a.worst);
            end
            if isfinite(g.avDb)
                w{end+1} = sprintf('增益为纯计算结果（无 Av 指标）：Av=%.2f dB', g.avDb);
            end
        end
    end

    %% ---------------- 私有 ----------------
    methods (Access = private)
        function k = devIndex(obj, name)
            k = find(strcmp({obj.topo.devices.name}, name), 1);
            if isempty(k), error('GmIdCircuit:noDevice', '没有器件 %s', name); end
        end

        function i = inputIdx(obj, dev)
            i = find(strcmp({dev.role},'输入对') | strcmp({dev.role},'共源管'), 1);
            if isempty(i), i = 1; end
        end

        function hi = hiNet(obj, d) %#ok<INUSL>
            if d.type == 'N', hi = d.D; else, hi = d.S; end
        end

        function lo = loNet(obj, d) %#ok<INUSL>
            if d.type == 'N', lo = d.S; else, lo = d.D; end
        end

        function v = netVal(obj, nodes, name)
            k = find(strcmp({nodes.name}, name), 1);
            if isempty(k), v = NaN; else, v = nodes(k).value; end
        end

        function v = roleVdsat(obj, dev, role) %#ok<INUSL>
            v = 0;
            for j = 1:numel(dev)
                if strcmp(dev(j).role, role) && dev(j).ok, v = dev(j).Vdsat; return; end
            end
        end

        function d = blankDev(obj) %#ok<MANU>
            d = struct('name','','type','','role','','Id',NaN,'gmid',NaN,'L',NaN, ...
                'VDS',NaN,'VDSact',NaN,'Vgs',NaN,'Vdsat',NaN,'fT',NaN,'selfGain',NaN, ...
                'W',NaN,'gm',NaN,'source','','ok',false,'margin',NaN,'sat','','note','');
        end
    end
end
