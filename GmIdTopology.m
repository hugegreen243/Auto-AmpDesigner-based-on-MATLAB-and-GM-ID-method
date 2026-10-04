function t = GmIdTopology(name, inType, fd)
%GMIDTOPOLOGY  拓扑定义层：器件表 + 端子/网表 + 选点策略。
%
%   names = GmIdTopology()                    % 所有可用拓扑名（cellstr）
%   t     = GmIdTopology('Five-Transistor OTA')          % NMOS 输入版
%   t     = GmIdTopology('Five-Transistor OTA','pmos')   % PMOS 输入版（电学镜像）
%   t     = GmIdTopology('Five-Transistor OTA','nmos', true)  % 全差分（负载管栅接 VB）
%
% 每个器件（t.devices(k)）：
%   name type role idFactor            % 标号 / N|P / 角色 / 电流 = idFactor*Iss
%   gmidPolicy gmidValue               % 'input' | 'moderate' | 'headroom'
%   lPolicy vdsPolicy                  % L 与 VDS 的选点策略（初始化用）
%   D S G                              % 三个端子所在的 net 名
%
% 拓扑级信息：
%   t.rails        {'VDD','GND'}       电源轨 net（求解器把它们当电压锚点）
%   t.biasNets     偏置/输入 net 列表（这些 net 电压由 Vgs 反推，不参与 KVL 链）
%   t.vdsDrivers   哪些管的 VDS 是"自由输入"（决定 KVL 链）；其余管的 VDS
%                  由节点电压反推（初始化/回填时用）
%   t.nBaseRole / t.pBaseRole          输出节点 N/P 侧 cascode 的基底器件角色
%   t.voutMinStack / t.voutMaxStack    摆幅 = 这些角色的 Vdsat 之和
%
% 电学约定：NMOS 的 VDS 取 漏-源，PMOS 取 源-漏（都是正数），与 LUT 的 VDS 轴一致。
% vgs 由 LUT 给出：NMOS 的 Vg = Vs + Vgs，PMOS 的 Vg = Vs - |Vgs|。
%
% 兼容 MATLAB R2018b。

if nargin < 1 || isempty(name)
    t = {'Five-Transistor OTA', 'Common Source', ...
         'Folded Cascode OTA', 'Telescopic Cascode OTA'};
    return;
end
if nargin < 2 || isempty(inType), inType = 'nmos'; end
if nargin < 3 || isempty(fd), fd = false; end
pmosIn = strncmpi(inType, 'p', 1);

switch name
    case 'Five-Transistor OTA'
        t = base(name, '标准 5T OTA（NMOS 输入对 + PMOS 电流镜负载 + NMOS 尾电流）');
        gLd = 'X';
        if fd, gLd = 'VB'; end   % 全差分：负载管栅接外部偏置 VB，不做二极管电流镜
        t.devices = [ ...
            dev('M1','N','输入对',    0.5,'input',  NaN,'input',     'input',      {'X','P','VIN+'})
            dev('M2','N','输入对',    0.5,'input',  NaN,'input',     'input',      {'OUT','P','VIN-'})
            dev('M5','N','尾电流源',  1.0,'moderate',10,'twiceInput','vdsatInput', {'P','GND','VB0'})
            dev('M3','P','电流镜负载',0.5,'moderate',10,'twiceInput','input',      {'X','VDD',gLd})
            dev('M4','P','电流镜负载',0.5,'moderate',10,'twiceInput','input',      {'OUT','VDD',gLd})];
        t.vdsDrivers   = {'M5','M1'};
        t.vdsFollower  = [foll('M2','same',  'M1'), ...
                          foll('M3','nodes', '', 'VDD','X'), ...
                          foll('M4','same',  'M3')];
        t.nBaseRole    = '输入对';        t.pBaseRole = '电流镜负载';
        t.voutMinStack = {'输入对','尾电流源'};
        t.voutMaxStack = {'电流镜负载'};
        if fd
            t.notes = {'全差分：M3/M4 栅接外部偏置 VB（不做二极管电流镜），VB 由 Vgs 反推。', ...
                       'Av = gm1*(Rout_N ∥ Rout_P)，Rout 由每管 selfGain 算；饱和判据 VDS ≥ Vdsat。', ...
                       '输出节点 = M4/M2 漏极（OUT）、M3/M1 漏极（X），两路差分输出。'};
        else
            t.notes = {'PMOS 负载无数据时标「无数据」，填 PMOS 数据后查表。', ...
                       'Av = gm1*(Rout_N ∥ Rout_P)，Rout 由每管 selfGain 算；饱和判据 VDS ≥ Vdsat。', ...
                       '输出节点 = M4/M2 漏极；M3 二极管接法，栅极与 X 同电位。'};
        end

    case 'Common Source'
        t = base(name, '共源级：NMOS 共源管 + PMOS 电流源负载');
        t.devices = [ ...
            dev('M1','N','共源管',    1.0,'input',   NaN,'input','input',{'OUT','GND','VIN'})
            dev('M2','P','电流源负载',1.0,'moderate',10, 'max',  'input',{'OUT','VDD','VB1'})];
        t.vdsDrivers   = {'M1'};
        t.vdsFollower  = foll('M2','nodes','','VDD','OUT');
        t.nBaseRole    = '共源管';        t.pBaseRole = '电流源负载';
        t.voutMinStack = {'共源管'};
        t.voutMaxStack = {'电流源负载'};
        t.notes = {'负载 L 取数据里最大 L，以获得更高输出电阻（需要的话在面板里手动改）。'};

    case 'Folded Cascode OTA'
        % 11 管标准版：M5/M6 折叠电流源 -> X/Y；M3/M4 cascode -> 输出；
        % M7/M8 cascode -> Q/R；M10/M11 电流沉 -> GND；M9 尾电流；M1/M2 输入对
        %
        % ★ 角色名里**不要嵌 N/P**（如 'PMOS cascode'）：PMOS 输入版会把 type 整体
        %   N<->P 互换，带 N/P 前缀的角色名会与实际 type 不符，导致按角色找器件
        %   （branchR / roleVdsat / voutStack）时匹配错人 —— 这正是「FC 换 PMOS 输入后
        %   管子的功能/电流对不上」的根因。统一成 'cascode'，靠 dev.type 区分 N/P 侧。
        t = base(name, '折叠共源共栅（11 管标准版；PMOS 输入时电学与图纸一起镜像）');
        t.devices = [ ...
            dev('M1', 'N','输入对',       0.5,'input',   NaN,'input',     'input',      {'X','P','VIN+'})
            dev('M2', 'N','输入对',       0.5,'input',   NaN,'input',     'input',      {'Y','P','VIN-'})
            dev('M9', 'N','尾电流源',     1.0,'moderate',10, 'twiceInput','vdsatInput', {'P','GND','VB0'})
            dev('M5', 'P','折叠电流源',   1.0,'moderate',10, 'twiceInput','input',      {'X','VDD','VB3'})
            dev('M6', 'P','折叠电流源',   1.0,'moderate',10, 'twiceInput','input',      {'Y','VDD','VB3'})
            dev('M3', 'P','cascode',      0.5,'moderate',12, 'twiceInput','mid',        {'OUTm','X','VB2'})
            dev('M4', 'P','cascode',      0.5,'moderate',12, 'twiceInput','mid',        {'OUTp','Y','VB2'})
            dev('M7', 'N','cascode',      0.5,'moderate',12, 'twiceInput','mid',        {'OUTm','Q','VB1'})
            dev('M8', 'N','cascode',      0.5,'moderate',12, 'twiceInput','mid',        {'OUTp','R','VB1'})
            dev('M10','N','电流沉',       0.5,'moderate',10, 'twiceInput','mid',        {'Q','GND','VB4'})
            dev('M11','N','电流沉',       0.5,'moderate',10, 'twiceInput','mid',        {'R','GND','VB4'})];
        t.vdsDrivers   = {'M10','M7','M3','M1'};
        t.vdsFollower  = [foll('M11','same','M10'), ...
                          foll('M8', 'same','M7'), ...
                          foll('M2', 'same','M1'), ...
                          foll('M4', 'same','M3'), ...
                          foll('M9', 'nodes','','P','GND'), ...
                          foll('M5', 'nodes','','VDD','X'), ...
                          foll('M6', 'nodes','','VDD','Y')];
        t.nBaseRole    = '电流沉';        t.pBaseRole = '折叠电流源';
        t.voutMinStack = {'cascode','电流沉'};
        t.voutMaxStack = {'cascode','折叠电流源'};
        t.notes = {'直流：I(M5)=Iss，I(M1)=Iss/2，I(M3)=I(M7)=I(M10)=Iss/2（电流由拓扑自动分配）。', ...
                   'KVL 链（从地往上）：Q <- M10，OUT <- M7，X <- M3，P <- M1；M5/M6/M9 及右侧由节点电压反推。', ...
                   'Av = gm1*(Rout_N ∥ Rout_P)，Rout_N 以电流沉 M10 为基底、Rout_P 以折叠电流源 M5 为基底。'};

    case 'Telescopic Cascode OTA'
        t = base(name, '套筒式共源共栅（NMOS 输入对，输出摆幅受限）');
        % 角色名同样不嵌 N/P（见 Folded Cascode 处的说明），统一 'cascode' / '电流源'。
        t.devices = [ ...
            dev('M1','N','输入对',       0.5,'input',   NaN,'input',     'input',      {'N1','P','VIN+'})
            dev('M2','N','输入对',       0.5,'input',   NaN,'input',     'input',      {'N2','P','VIN-'})
            dev('M5','N','尾电流源',     1.0,'moderate',10, 'twiceInput','vdsatInput', {'P','GND','VB0'})
            dev('M3','N','cascode',      0.5,'moderate',12, 'twiceInput','mid',        {'OUTm','N1','VB1'})
            dev('M4','N','cascode',      0.5,'moderate',12, 'twiceInput','mid',        {'OUTp','N2','VB1'})
            dev('M6','P','cascode',      0.5,'moderate',12, 'twiceInput','mid',        {'OUTm','NPm','VB2'})
            dev('M7','P','cascode',      0.5,'moderate',12, 'twiceInput','mid',        {'OUTp','NPp','VB2'})
            dev('M8','P','电流源',       0.5,'moderate',10, 'twiceInput','input',      {'NPm','VDD','VB3'})
            dev('M9','P','电流源',       0.5,'moderate',10, 'twiceInput','input',      {'NPp','VDD','VB3'})];
        t.vdsDrivers   = {'M5','M1','M3','M6'};
        t.vdsFollower  = [foll('M2','same','M1'), ...
                          foll('M4','same','M3'), ...
                          foll('M7','same','M6'), ...
                          foll('M8','nodes','','VDD','NPm'), ...
                          foll('M9','same','M8')];
        t.nBaseRole    = '输入对';        t.pBaseRole = '电流源';
        t.voutMinStack = {'输入对','cascode','尾电流源'};
        t.voutMaxStack = {'电流源','cascode'};
        t.notes = {'KVL 链（从地往上）：P <- M5，N1 <- M1，OUT <- M3，NP <- M6；上侧电流源由节点电压反推。', ...
                   '输出摆幅 = VDD - 2*Vdsat(上侧) - 2*Vdsat(下侧)，很小，务必看裕量。'};

    otherwise
        error('GmIdTopology:unknown', '未知拓扑: %s', name);
end

% ---- net 分类 ----
t.rails     = {'VDD','GND'};
bias = {};
for k = 1:numel(t.devices)
    if ~isempty(regexp(t.devices(k).G, '^(VB|VIN)', 'once'))
        bias{end+1} = t.devices(k).G; %#ok<AGROW>
    end
end
t.biasNets  = unique(bias);
t.inputNets = t.biasNets(~cellfun(@isempty, regexp(t.biasNets, '^VIN', 'once')));
if isempty(t.inputNets), t.inputNets = {}; end

% ---- PMOS 输入 = 电学镜像：N<->P 互换 + 电源轨名字互换（端子 D/S 不换）----
if pmosIn
    t.desc = [t.desc '（PMOS 输入版）'];
    for k = 1:numel(t.devices)
        d = t.devices(k);
        if d.type == 'N', d.type = 'P'; else, d.type = 'N'; end
        d.D = swapRail(d.D);  d.S = swapRail(d.S);  d.G = swapRail(d.G);
        t.devices(k) = d;
    end
    t.biasNets  = cellfun(@swapRail, t.biasNets, 'UniformOutput', false);
    t.inputNets = cellfun(@swapRail, t.inputNets, 'UniformOutput', false);
    % 镜像后 N/P 侧的“基底器件角色”也要互换（否则增益支路电阻找错器件）
    tmp = t.nBaseRole;  t.nBaseRole = t.pBaseRole;  t.pBaseRole = tmp;
end
t.inType = inType;
end

% ---------------------------------------------------------------- 辅助
function t = base(name, desc)
t = struct();
t.name = name;  t.desc = desc;  t.notes = {};
t.devices = struct([]);
t.rails = {'VDD','GND'};  t.biasNets = {};  t.inputNets = {};  t.vdsDrivers = {};
t.vdsFollower = struct('name',{},'mode',{},'ref',{},'hi',{},'lo',{});
t.nBaseRole = '';  t.pBaseRole = '';  t.voutMinStack = {};  t.voutMaxStack = {};
t.inType = 'nmos';
end

function f = foll(name, mode, ref, hi, lo)
%FOLL 追随管规则：mode='same' 复制 ref 管的 VDS；mode='nodes' 由 hi/lo 节点电压之差决定
if nargin < 3, ref = ''; end
if nargin < 4, hi = ''; end
if nargin < 5, lo = ''; end
f = struct('name',name,'mode',mode,'ref',ref,'hi',hi,'lo',lo);
end

function d = dev(name, type, role, idFactor, gmidPolicy, gmidValue, lPolicy, vdsPolicy, term)
d = struct('name',name, 'type',type, 'role',role, 'idFactor',idFactor, ...
    'gmidPolicy',gmidPolicy, 'gmidValue',gmidValue, 'lPolicy',lPolicy, ...
    'vdsPolicy',vdsPolicy, 'D',term{1}, 'S',term{2}, 'G',term{3}, 'note','');
end

function s = swapRail(s)
% 镜像电路时只换电源轨名字，内部节点名不变
if strcmp(s, 'VDD'), s = 'GND'; elseif strcmp(s, 'GND'), s = 'VDD'; end
end
