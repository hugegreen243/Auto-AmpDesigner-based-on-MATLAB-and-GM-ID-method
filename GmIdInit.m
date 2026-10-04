function [st, warn] = GmIdInit(dataN, dataP, topo, specs, opt)
%GMIDINIT  「初始化」层：按指标给每个器件选一个起点（L / VDS / gm/ID）。
%
%   [st, warn] = GmIdInit(dataN, dataP, topo, specs, opt)
%     dataN    NMOS 的 GmIdData（可为空，表示没有 NMOS 数据）
%     dataP    PMOS 的 GmIdData（可为空，表示没有 PMOS 数据）
%     topo     GmIdTopology 结果（含每管的选点策略）
%     specs   结构体 .GBW .SR .ISS .CL .VDD
%     opt     可选：objective('area'|'gain'|'balanced')、vdsMargin、vdsatBudgetIn/
%             Tail/Cas、vgsMargin、vdsTargetIn/Tol、wmax、vgsMin
%   返回 st(k).name/.L/.VDS/.gmID（与 topo.devices 同序），warn 为提示 cellstr。
%
% 只负责“选点”，不算增益/摆幅（那些由 GmIdCircuit.solve 用真实器件参数算）。
% 没有对应 type 数据的器件只给一个默认起点，求解阶段会标「无数据」。
%
% 兼容 MATLAB R2018b。

if nargin < 5, opt = struct(); end
o = defaultOpts(opt);
warn = {};

%% ---------- 指标 -> gm1 / gm/ID ----------
gm1   = 2*pi*specs.GBW*specs.CL;
iss   = specs.ISS;
idIn  = iss/2;
gmidReq = gm1/idIn;
srAct = iss/specs.CL;
if specs.SR > 0 && abs(srAct - specs.SR)/specs.SR > 0.25
    warn{end+1} = sprintf(['SR 不自洽：ISS/CL=%.4g V/us，指标 SR=%.4g V/us。' ...
        '若以 SR 为准，尾电流应取 %.4g uA。'], srAct*1e-6, specs.SR*1e-6, specs.SR*specs.CL*1e6);
end

%% ---------- 输入对（L, VDS）择优 ----------
iIn = find(strcmp({topo.devices.role},'输入对') | strcmp({topo.devices.role},'共源管'), 1);
if isempty(iIn), iIn = 1; end
inTy   = topo.devices(iIn).type;
dataIn = dataForType(dataN, dataP, inTy);
hasIn  = ~isempty(dataIn) && dataIn.isLoaded();

if hasIn
    [~, ~, gr] = dataIn.axesInfo();
    gmidIn = gmidReq;
    if gmidReq < gr(1) || gmidReq > gr(2)
        warn{end+1} = sprintf(['输入对需要的 gm/ID=%.3f 超出数据范围 [%.3f, %.3f]。' ...
            '建议把 ISS 从 %.4g uA 改到 %.4g uA 附近。已按边界值继续。'], ...
            gmidReq, gr(1), gr(2), iss*1e6, (gm1/gr(1))*2*1e6);
        gmidIn = min(max(gmidReq, gr(1)), gr(2));
    end

    cand = dataIn.lut.scan(gmidIn);
    if isempty(cand.VDS)
        error('GmIdInit:noCandidate', 'gm/ID=%.3f 在数据网格上没有有效点。', gmidIn);
    end
    keep = cand.VDS >= cand.Vdsat + o.vdsMargin & cand.Vgs <= specs.VDD - o.vgsMargin & ...
           cand.Vdsat <= o.vdsatBudgetIn;
    if ~any(keep)
        keep = cand.VDS >= cand.Vdsat + o.vdsMargin & cand.Vgs <= specs.VDD - o.vgsMargin;
        warn{end+1} = sprintf('输入对没有满足 Vdsat<=%.2f V 的点，已放宽该预算。', o.vdsatBudgetIn);
    end
    if ~any(keep)
        keep = true(size(cand.VDS));
        warn{end+1} = '输入对没有满足饱和/偏置裕量的点，已完全放宽，请人工复核。';
    end
    if ~isnan(o.vdsTargetIn)
        near = keep & abs(cand.VDS - o.vdsTargetIn) <= o.vdsTargetTol;
        if any(near), keep = near; end
    end
    idx = find(keep);
    switch lower(o.objective)
        case 'area', score = cand.IdW(idx);
        case 'gain', score = cand.selfGain(idx);
        otherwise,   score = (cand.IdW(idx)/max(cand.IdW(idx))) .* (cand.selfGain(idx)/max(cand.selfGain(idx)));
    end
    [~, ib] = max(score);
    p = idx(ib);
    inL = cand.L(p);  inVDS = cand.VDS(p);  inVdsat = cand.Vdsat(p);
else
    warn{end+1} = sprintf('输入对（%s）无 gm/ID 数据，用默认起点（请在数据源区填入对应数据）。', inTy);
    gmidIn = min(max(gmidReq, 3), 25);
    inL = 0.5e-6;  inVDS = 0.5;  inVdsat = 0.2;
end

ctx = struct('gmidIn', gmidIn, 'Lin', inL, 'VDSin', inVDS, 'vdsatIn', inVdsat, ...
    'budgetTail', o.vdsatBudgetTail, 'budgetCas', o.vdsatBudgetCas, ...
    'wmax', o.wmax, 'vgsMin', o.vgsMin, 'specs', specs);

%% ---------- 逐管选点 ----------
n = numel(topo.devices);
st = repmat(struct('name','','L',NaN,'VDS',NaN,'gmID',NaN), 1, n);
for k = 1:n
    d  = topo.devices(k);
    dk = dataForType(dataN, dataP, d.type);
    has = ~isempty(dk) && dk.isLoaded();
    if ~has
        % 无该 type 数据：给默认起点（求解阶段标「无数据」）
        L = 0.5e-6;  VDS = 0.5;
        switch lower(d.gmidPolicy)
            case 'input',     g = gmidIn;
            case 'headroom',  g = 15;
            otherwise,        g = min(max(d.gmidValue, 3), 25);
        end
    else
        L = pickL(d.lPolicy, ctx, dk);
        VDS = pickVDS(d.vdsPolicy, ctx, dk);
        switch lower(d.gmidPolicy)
            case 'input'
                g = gmidIn;
            case 'headroom'
                g = chooseGmid(dk, iss*d.idFactor, L, VDS, 'headroom', 15, ctx.budgetTail, o.wmax);
            otherwise
                g = chooseGmid(dk, iss*d.idFactor, L, VDS, 'moderate', d.gmidValue, ctx.budgetCas, o.wmax);
        end
    end
    st(k) = struct('name', d.name, 'L', L, 'VDS', VDS, 'gmID', g);
end
end

% ---------------------------------------------------------------- 辅助
function d = dataForType(dataN, dataP, ty)
% 按器件 type（'N'/'P'）选对应数据源
if ty(1) == 'N', d = dataN; else, d = dataP; end
end

function o = defaultOpts(opts)
o = struct('objective','balanced', 'vdsMargin',0.05, ...
    'vdsatBudgetIn',0.35, 'vdsatBudgetTail',0.25, 'vdsatBudgetCas',0.35, ...
    'vgsMargin',0.15, 'vdsTargetIn',0.5, 'vdsTargetTol',0.15, ...
    'wmax',200e-6, 'vgsMin',0.3);
fn = fieldnames(opts);
for k = 1:numel(fn)
    if ~isfield(o, fn{k}), error('GmIdInit:badOpt', '未知选项 %s', fn{k}); end
    o.(fn{k}) = opts.(fn{k});
end
end

function L = pickL(policy, ctx, data)
[Lall, ~, ~] = data.axesInfo();
switch lower(policy)
    case {'input','same'}, L = ctx.Lin;
    case 'min',            L = min(Lall);
    case 'max',            L = max(Lall);
    case 'twiceinput'
        c = Lall(Lall >= 2*ctx.Lin);
        if isempty(c), L = max(Lall); else, L = min(c); end
    otherwise
        error('GmIdInit:badPolicy', '未知 L 策略 %s', policy);
end
end

function VDS = pickVDS(policy, ctx, data)
[~, Vall, ~] = data.axesInfo();
switch lower(policy)
    case 'input',      VDS = ctx.VDSin;
    case 'vdsatinput', VDS = min(max(ctx.vdsatIn, min(Vall)), max(Vall));
    case 'mid'
        vm = mean([min(Vall), max(Vall)]);
        [~, i] = min(abs(Vall - vm));  VDS = Vall(i);
    case 'min',        VDS = min(Vall);
    otherwise
        error('GmIdInit:badPolicy', '未知 VDS 策略 %s', policy);
end
end

function g = chooseGmid(data, Id, L, VDS, policy, value, budget, wmax)
%CHOOSEGMID 在给定 (L,VDS) 上按策略挑 gm/ID，并施加 Vdsat 预算 / 宽度上限
gg = data.lut.gmGrid(:);
qg = data.query(L*ones(size(gg)), VDS*ones(size(gg)), gg);
Wg = Id ./ qg.IdW;
Wg(~qg.valid) = inf;
base = qg.valid & Wg <= wmax;
ok   = base & qg.Vdsat <= budget;
switch lower(policy)
    case 'headroom'
        if any(ok),        g = max(gg(ok));
        elseif any(base)
            v = qg.Vdsat; v(~base) = inf; [~, i] = min(v); g = gg(i);
        else
            [~, i] = min(Wg); g = gg(i);
        end
    otherwise
        if any(ok)
            s = gg(ok); [~, i] = min(abs(s - value)); g = s(i);
        elseif any(base)
            v = qg.Vdsat; v(~base) = inf; [~, i] = min(v); g = gg(i);
        else
            [~, i] = min(Wg); g = gg(i);
        end
end
end
