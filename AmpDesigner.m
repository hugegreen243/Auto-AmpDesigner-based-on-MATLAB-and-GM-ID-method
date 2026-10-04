function ui = AmpDesigner()
%AMPDESIGNER  大顶层：把四层装配成界面并调度（唯一入口）。
%
%   ui = AmpDesigner()
%
% 分层：
%   GmIdPanel      面板层（控件/布局，传统 figure/uicontrol/axes）
%   GmIdData       数据层（NMOS / PMOS 各一套，按路径加载 LUT）
%   GmIdCircuit    电路层（每管工作点 + 求解：电流/节点电压/饱和/增益）
%   GmIdSchematic  图层（原理图 + 器件热区 + 图上标注）
%
% 交互：点原理图里的管子 → 属性栏改 L / VDS / gm/ID（改 gm 会反推总 Iss）
%       → 图与读数实时更新；「计算」出增益/摆幅/饱和判定与结果表。
%       所有器件参数（W/Vgs/Vdsat/fT/gm-gds）一律查 LUT，无 µCox/Vth 解析模型。
%
% 兼容 MATLAB R2018b：不使用 uifigure / uigridlayout / uibutton 等 App Building 组件
% （uigridlayout 是 R2019a 才引入），也没有 uiaxes 在 Windows 上触发堆损坏（0xc0000374）
% 导致 MATLAB 闪退的风险。

C = struct('BG',[0.93 0.94 0.96], 'PANEL',[1 1 1], 'TITLE',[0.12 0.22 0.42], ...
    'ACCENT',[0.20 0.50 0.82], 'OK',[0.16 0.55 0.32], 'DANGER',[0.85 0.32 0.30], ...
    'LINE',[0.12 0.12 0.12], 'LINE2',[0.10 0.35 0.65], 'NMOS',[0.15 0.42 0.78], 'PMOS',[0.80 0.32 0.18], ...
    'BODY',[0.18 0.18 0.18]);
% 字体：跨平台取本机确实存在的中文字体（纯函数，无 UiKit 中间层）。
%   ★ 中文版 Windows 的 listfonts 返回「微软雅黑」而不是 "Microsoft YaHei"，
%     所以候选里必须中英文名都给，否则匹配不上就退化成方框（tofu）。
%   原理图标注含中文（无数据/饱和/临界），必须用带 CJK 字形的字体。
FCN = pickCjkFont();
FEN = pickLatinFont();
FSC = FCN;

ui = struct();
ui.C = C;  ui.FCN = FCN;  ui.FEN = FEN;
% 传统 figure（非 uifigure）：R2018b 上最稳，也避开 Windows 图形栈的堆损坏闪退。
ui.fig = figure('Name', 'gm/ID 交互设计器（点器件改参数）', ...
    'NumberTitle', 'off', 'MenuBar', 'none', ...
    'Units', 'pixels', 'Position', [60 40 1460 900], ...
    'Color', C.BG, 'Renderer', 'painters', ...
    'Resize', 'on', 'HandleVisibility', 'on', 'Visible', 'on');
drawnow;
W0 = ui.fig.Position(3);  H0 = ui.fig.Position(4);
ui.P = GmIdPanel(ui.fig, C, FCN, FEN);
ui.P.layout(W0, H0);
ui.DN = GmIdData();   % NMOS gm/ID 数据
ui.DP = GmIdData();   % PMOS gm/ID 数据
ui.S = GmIdSchematic(ui.P.ax, C, FSC);

% ---- 绑定回调 ----
P = ui.P;  DN = ui.DN;  DP = ui.DP;  S = ui.S;
sBind = @(cb) @(src,ev) cb();          % 回调签名统一是 (src,ev)
% 按钮是「自绘圆角 axes」（不是 uicontrol）：axes 上没有 'Callback' 属性，
% 必须写 ButtonDownFcn。P.bindBtn 会根据句柄类型自动选属性。
P.bindBtn(P.btnScan, @() onScan(P, DN, DP, S));
P.bindBtn(P.btnLoad, @() onLoad(P, DN, DP, S));
P.ddTopo.Callback    = sBind(@() rebuild(P, DN, DP, S, true));
P.ddInType.Callback  = sBind(@() rebuild(P, DN, DP, S, true));
P.ddOutType.Callback = sBind(@() rebuild(P, DN, DP, S, true));
P.ax.ButtonDownFcn   = sBind(@() onClick(P, S));
P.ddL.Callback       = sBind(@() onProp(P, DN, DP, S));
P.edtVDS.Callback    = sBind(@() onProp(P, DN, DP, S));
P.edtGmid.Callback   = sBind(@() onProp(P, DN, DP, S));
P.edtGm.Callback     = sBind(@() onProp(P, DN, DP, S));
P.ddMetric.Callback        = sBind(@() onMetric(P, DN, DP));
P.ddMetricSurf.Callback    = sBind(@() onSurf(P, DN, DP));
P.ddVDScurve.Callback      = sBind(@() onMetric(P, DN, DP));
P.ddVDSsurf.Callback       = sBind(@() onSurf(P, DN, DP));
P.axCurve.ButtonDownFcn    = sBind(@() onCurveClick(P, DN, DP, S));
P.axSurf.ButtonDownFcn     = sBind(@() onSurfClick(P, DN, DP, S));
% 切页时按页重画：曲线/曲面页首次进入时必须画一次，否则是一片空白且点击无意义。
P.onTabChanged = @(i) onTabChanged(P, DN, DP, i);
P.bindBtn(P.btnInit,   @() onInit(P, DN, DP, S));
P.bindBtn(P.btnCalc,   @() onCompute(P, DN, DP, S));
P.bindBtn(P.btnExport, @() onExport(P, DN, DP, S));
P.bindBtn(P.btnClear,  @() onClear(P, DN, DP, S));

% ---- 窗口尺寸变化：整体重排（传统控件的 Position 需自己维护）----
ui.onResize = @() P.layout(ui.fig.Position(3), ui.fig.Position(4));
set(ui.fig, 'SizeChangedFcn', @(src,ev) P.layout(src.Position(3), src.Position(4)));

% ---- 脚本化入口（供测试/命令行调用，不必真点鼠标）----
%   ui.pickSurf(gmid, L_um)   吸附到最近的 (gm/ID, L)（选中管则写回，否则更新探查点）
%   ui.pickCurve(gmid, y)     曲线页吸附（y 为指标值）
ui.pickSurf  = @(g, L_um) pickAt(P, DN, DP, S, g, L_um, 'surf');
ui.pickCurve = @(g, y)    pickAt(P, DN, DP, S, g, y, 'curve');
ui.redrawSurf = @() onSurf(P, DN, DP);

% ---- 初始状态 ----
P.setTopoItems(GmIdTopology());
onScan(P, DN, DP, S);
onLoad(P, DN, DP, S);
end

%% ============================================================
%  回调（状态存在 P.circ / P.res 里）
%% ============================================================
function onScan(P, DN, DP, S) %#ok<INUSD>
%ONSCAN 自动探测：扫描工作目录，把可加载（格式 B）的 NMOS/PMOS 目录填到路径框。
DN.scan();
src = DN.src;
pathN = '';  pathP = '';
for k = 1:numel(src)
    if ~src(k).ok, continue; end
    if strcmpi(src(k).type, 'nmos') && isempty(pathN), pathN = src(k).dataDir; end
    if strcmpi(src(k).type, 'pmos') && isempty(pathP), pathP = src(k).dataDir; end
end
P.setPaths(pathN, pathP);
nOk = sum([src.ok]);
P.setStatus(sprintf('自动探测到 %d 个数据源（%d 个可加载）', numel(src), nOk), 'warn');
P.log(sprintf('--- 数据源探测：%d 个，可加载 %d 个 ---', numel(src), nOk));
for k = 1:numel(src)
    P.log(sprintf('  %-48s fmt=%s ok=%d', src(k).label, src(k).fmt, src(k).ok));
end
end

function onLoad(P, DN, DP, S)
%ONLOAD 读取 N/P 两个路径框，分别加载（路径为空或不可加载则跳过）。
pathN = strtrim(P.getText(P.edtPathN));
pathP = strtrim(P.getText(P.edtPathP));
okN = false;  okP = false;
if ~isempty(pathN), okN = DN.loadDir(pathN); end
if ~isempty(pathP), okP = DP.loadDir(pathP); end

[L, V, gr] = defaultAxes(DN, DP); %#ok<ASGLU>
P.setLItems(L);
P.setVDSitems(V);

if ~okN && ~okP
    P.setStatus('没有加载到任何数据（检查 N/P 路径，需格式 B）', 'err');
    P.log('!! 没有加载到数据。请在数据源区填入 NMOS / PMOS 的 gm/ID 数据目录路径（格式 B）。');
    rebuild(P, DN, DP, S, true);
    return;
end

msgs = {};
if okN
    [LN, VN, gN] = DN.axesInfo();
    msgs{end+1} = sprintf('NMOS: L=%d,VDS=%d,gm/ID=%.2f~%.2f', numel(LN), numel(VN), gN(1), gN(2)); %#ok<AGROW>
    P.log(sprintf('--- 已加载 NMOS 数据 %s ---', DN.sourceName()));
    for k = 1:numel(DN.lut.log), P.log(['  ' DN.lut.log{k}]); end
end
if okP
    [LP, VP, gP] = DP.axesInfo();
    msgs{end+1} = sprintf('PMOS: L=%d,VDS=%d,gm/ID=%.2f~%.2f', numel(LP), numel(VP), gP(1), gP(2)); %#ok<AGROW>
    P.log(sprintf('--- 已加载 PMOS 数据 %s ---', DP.sourceName()));
    for k = 1:numel(DP.lut.log), P.log(['  ' DP.lut.log{k}]); end
end
P.setStatus(strjoin(msgs, '  |  '), 'ok');
rebuild(P, DN, DP, S, true);
end

function rebuild(P, DN, DP, S, doInit)
%REBUILD 拓扑/输入对/输出形式或数据变化后重建电路层并重画
if nargin < 5, doInit = true; end
P.circ = GmIdCircuit(DN, DP, P.getText(P.ddTopo), P.inputType(), P.isFD());
P.circ.setSpecs(P.readSpecs());
P.setSelected('');  S.setSelected('');      % 换拓扑/形式后清掉旧选中
P.explore = [];
if DN.isLoaded() || DP.isLoaded()
    [L, V, ~] = defaultAxes(DN, DP);
    P.setLItems(L);
    P.setVDSitems(V);
    if doInit
        w = P.circ.initFromSpecs(P.readSpecs());
        for k = 1:numel(w), P.log(['  · ' w{k}]); end
    end
end
refreshAll(P, DN, DP, S, true);
end

function refreshAll(P, DN, DP, S, redraw)
%REFRESHALL 求解 → 刷表/属性栏/图（redraw=false 时只更新图上标注）
if nargin < 5, redraw = false; end
if isempty(P.circ), return; end
P.res = P.circ.solve();
P.refreshTable(P.res);
if redraw || isempty(S.idx.dev)
    S.draw(P.circ, P.res);
else
    S.refresh(P.circ, P.res);
end
P.refreshProp(P.circ, P.res);
onMetric(P, DN, DP);
onSurf(P, DN, DP);
end

function onClick(P, S)
cp = P.ax.CurrentPoint;
nm = S.pickDevice(cp(1,1), cp(1,2));
if isempty(nm)
    S.setSelected('');  P.setSelected('');
    if ~isempty(P.circ), S.refresh(P.circ, P.res); end
    return;
end
S.setSelected(nm);  P.setSelected(nm);
if ~isempty(P.circ)
    S.refresh(P.circ, P.res);
    P.refreshProp(P.circ, P.res);
end
end

function onProp(P, DN, DP, S)
%ONPROP 属性栏改动 → 写回电路 → 实时刷新（图上只重画标注）
if isempty(P.circ) || isempty(P.selDev), return; end
try
    Lval = sscanf(P.getText(P.ddL), '%f')*1e-6;    % 下拉是 '0.500 um' 这样的字符串
    if isempty(Lval), Lval = P.circ.state(P.selDev).L; end
    P.circ.setDevice(P.selDev, 'L', Lval);
    P.circ.setDevice(P.selDev, 'VDS', P.getNum(P.edtVDS, 0.5));
    P.circ.setDevice(P.selDev, 'gmID', P.getNum(P.edtGmid, 10));
    % gm 也当锚：改了它就把总 Iss 反推过来（电流由拓扑自动分配）
    g = P.getNum(P.edtGm, 0)*1e-6;
    if isfinite(g) && g > 0, P.circ.setAnchor(g, 'gm', P.selDev); end
catch ME
    P.setStatus(['参数无效：' ME.message], 'err');
    return;
end
refreshAll(P, DN, DP, S, false);
end

function onInit(P, DN, DP, S)
if isempty(P.circ), rebuild(P, DN, DP, S, true); return; end
w = P.circ.initFromSpecs(P.readSpecs());
P.log('--- 初始化（按指标选 L / gm-ID；VDS 给默认值，可逐管自定义）---');
for k = 1:numel(w), P.log(['  · ' w{k}]); end
if isempty(w), P.log('  （无告警）'); end
P.setStatus('初始化完成', 'ok');
refreshAll(P, DN, DP, S, false);
end

function onCompute(P, DN, DP, S)
if isempty(P.circ), return; end
P.circ.setSpecs(P.readSpecs());
res = P.circ.solve();
P.res = res;
P.refreshTable(res);
S.refresh(P.circ, res);
P.refreshProp(P.circ, res);
onMetric(P, DN, DP);
onSurf(P, DN, DP);
nBad = sum(~strcmp({res.devices.sat}, '饱和'));
P.setStatus(sprintf('计算完成：Av=%.2f dB，%d 个管子非饱和', res.avDb, nBad), 'ok');
P.log('--- 计算 ---');
for k = 1:numel(res.warnings), P.log(['  * ' res.warnings{k}]);
    if k > 40, P.log('  * …（更多见命令窗口）'); break; end
end
lines = ampDesignReport(res, DN.lut, DP.lut, P.readSpecs());
for k = 1:numel(lines), fprintf('%s\n', lines{k}); end
P.showTab('res');            % 切到「设计结果」页
end

function onExport(P, DN, DP, S)
if isempty(P.res), onCompute(P, DN, DP, S); end
if isempty(P.res), return; end
[fn, fp] = uiputfile({'*.mat','MAT';'*.csv','CSV';'*.txt','文本报告'}, '导出设计', 'gmid_design.mat');
if isequal(fn, 0), return; end
[~, base] = fileparts(fn);
if isempty(base), base = 'gmid_design'; end
try
    specs = P.readSpecs();  res = P.res;
    lutN = DN.lut;  lutP = DP.lut; %#ok<NASGU>
    save(fullfile(fp, [base '.mat']), 'specs', 'res', 'lutN', 'lutP');
    fid = fopen(fullfile(fp, [base '.csv']), 'w', 'n', 'UTF-8');
    fprintf(fid, '%s,', res.tableCols{1:end-1});  fprintf(fid, '%s\n', res.tableCols{end});
    for k = 1:size(res.tableData,1)
        fprintf(fid, '%s,', res.tableData{k,1:end-1});  fprintf(fid, '%s\n', res.tableData{k,end});
    end
    fclose(fid);
    lines = ampDesignReport(res, DN.lut, DP.lut, specs);
    fid = fopen(fullfile(fp, [base '.txt']), 'w', 'n', 'UTF-8');
    for k = 1:numel(lines), fprintf(fid, '%s\n', lines{k}); end
    fclose(fid);
catch ME
    P.setStatus(['导出失败：' ME.message], 'err');  return;
end
P.setStatus(sprintf('已导出 %s{,.mat,.csv,.txt} → %s', base, fp), 'ok');
P.log(sprintf('--- 导出 %s.mat/.csv/.txt 到 %s ---', base, fp));
end

function onClear(P, DN, DP, S)
for k = 1:P.nSpec, set(P.edtSpec(k), 'String', sprintf('%.6g', P.specDef{k,3})); end
P.selDev = '';  P.setSelected('');  P.explore = [];
rebuild(P, DN, DP, S, true);
P.setStatus('已清空并复位', 'info');
P.log('--- 清空 ---');
end

%% ============================================================
%  曲线 / 曲面（不绑定管子：VDS 由下拉独立选，坐标轴固定到数据范围）
%% ============================================================
function onMetric(P, DN, DP)
%ONMETRIC 曲线页：某指标 vs gm/ID 的 L 曲线族，VDS 由 ddVDScurve 独立选（不绑定管子）。
D = pickData(DN, DP);
if isempty(D) || ~D.isLoaded(), return; end
lut = D.lut;
[~, VDSall, ~] = D.axesInfo();
iV = vdsIdx(P, P.ddVDScurve, VDSall);
iM = find(strcmp(P.metricItems, P.getText(P.ddMetric)), 1);
if isempty(iM), iM = 1; end
name = P.metricKeys{iM};
Y = reshape(lut.grid.(name)(:, iV, :), lut.nL, lut.nGm);
if lut.METRICLOG(lut.metricIndex(name)), Y = 10.^Y; end
ax = P.axCurve;
cla(ax); hold(ax, 'on');
g = lut.gmGrid;
for iL = 1:lut.nL
    h = plot(ax, g, Y(iL,:), '-', 'Color', [0.80 0.80 0.80], 'LineWidth', 0.9);
    set(h, 'PickableParts', 'none');
end
% 选中管（仅数据管）L 曲线高亮
iSel = [];
if ~isempty(P.res) && ~isempty(P.selDev)
    j = find(strcmp({P.res.devices.name}, P.selDev), 1);
    if ~isempty(j) && strcmp(P.res.devices(j).source, 'data')
        iSel = find(abs(lut.L - P.res.devices(j).L) < 1e-12, 1);
    end
end
if ~isempty(iSel)
    h = plot(ax, g, Y(iSel,:), '-', 'Color', P.C.NMOS, 'LineWidth', 2.0);
    set(h, 'PickableParts', 'none');
    legend(ax, h, sprintf('选中管 L=%.3f um', lut.L(iSel)*1e6), 'Location', 'best');
end
% 各管工作点（只有数据管能画）
if ~isempty(P.res)
    for k = 1:numel(P.res.devices)
        d = P.res.devices(k);
        if ~strcmp(d.source, 'data'), continue; end
        if ~strcmp(d.name, P.selDev)
            h = plot(ax, d.gmid, valOf(d, name), 'o', 'MarkerSize', 5, ...
                'Color', P.C.BODY, 'MarkerFaceColor', [1 1 1]);
            set(h, 'PickableParts', 'none');
        end
    end
    j = find(strcmp({P.res.devices.name}, P.selDev), 1);
    if ~isempty(j)
        d = P.res.devices(j);
        if strcmp(d.source, 'data')
            h = plot(ax, d.gmid, valOf(d, name), 'o', 'MarkerSize', 9, 'LineWidth', 1.8, ...
                'Color', [0.85 0.20 0.15]);
            set(h, 'PickableParts', 'none');
        end
    end
end
% 探查点（不绑定管子的自由选点）
if ~isempty(P.explore) && isfinite(P.explore.gmID)
    q = lut.lookup(P.explore.L, VDSall(iV), P.explore.gmID);
    if q.valid
        h = plot(ax, P.explore.gmID, valOfQ(q, name), 'p', 'MarkerSize', 11, ...
            'Color', [0.85 0.20 0.15], 'MarkerFaceColor', [1 0.85 0.85]);
        set(h, 'PickableParts', 'none');
    end
end
% 固定坐标轴（防止缩放/平移后找不到曲线）
xlim(ax, lut.gmidRange);
vr = lut.valRange.(name);
if isfield(lut.valRange, name) && isfinite(vr(1)) && isfinite(vr(2)), ylim(ax, vr); end
grid(ax, 'on');
xlabel(ax, 'g_m/I_D (1/V)');
ylabel(ax, sprintf('%s [%s]', P.getText(P.ddMetric), lut.metricUnit(name)));
set(ax, 'FontSize', 9);
set(P.lblCurve, 'String', sprintf('%s：VDS=%.2f V | 灰线=%d 条 L 曲线 | 空心点=各数据管 | 红点=选中管 | 红星=探查点', ...
    D.sourceName(), VDSall(iV), lut.nL));
end

function onSurf(P, DN, DP)
%ONSURF 曲面页：某指标 Z vs gm/ID(X) vs L(Y)，VDS 由 ddVDSsurf 独立选（不绑定管子）。
D = pickData(DN, DP);
if isempty(D) || ~D.isLoaded(), return; end
lut = D.lut;
[~, VDSall, ~] = D.axesInfo();
iV = vdsIdx(P, P.ddVDSsurf, VDSall);
iM = find(strcmp(P.metricItems, P.getText(P.ddMetricSurf)), 1);
if isempty(iM), iM = 1; end
name = P.metricKeys{iM};
Z = reshape(lut.grid.(name)(:, iV, :), lut.nL, lut.nGm);
if lut.METRICLOG(lut.metricIndex(name)), Z = 10.^Z; end
ax = P.axSurf;
cla(ax); hold(ax, 'on');      % 必须 hold on，否则后面的工作点标记会把曲面顶掉
hs = surf(ax, lut.gmGrid, lut.L*1e6, Z, 'EdgeColor', 'none');
set(hs, 'PickableParts', 'none');
xlabel(ax, 'g_m/I_D (1/V)');
ylabel(ax, 'L (um)');
zlabel(ax, sprintf('%s [%s]', P.getText(P.ddMetricSurf), lut.metricUnit(name)));
grid(ax, 'on');
view(ax, [-40 25]);
set(ax, 'FontSize', 9);
try, colormap(ax, parula(64)); catch, end
try, colorbar(ax); catch, end
% 各管工作点（只有数据管在其 L 数据点上能画）
if ~isempty(P.res)
    for k = 1:numel(P.res.devices)
        d = P.res.devices(k);
        if ~strcmp(d.source, 'data'), continue; end
        zv = valOf(d, name);
        if ~isfinite(zv), continue; end
        if strcmp(d.name, P.selDev)
            h = plot3(ax, d.gmid, d.L*1e6, zv, 'o', 'MarkerSize', 9, 'LineWidth', 1.8, ...
                'Color', [0.85 0.20 0.15]);
        else
            h = plot3(ax, d.gmid, d.L*1e6, zv, 'o', 'MarkerSize', 5, ...
                'Color', P.C.BODY, 'MarkerFaceColor', [1 1 1]);
        end
        set(h, 'PickableParts', 'none');
    end
end
% 探查点
if ~isempty(P.explore) && isfinite(P.explore.gmID)
    q = lut.lookup(P.explore.L, VDSall(iV), P.explore.gmID);
    if q.valid
        h = plot3(ax, P.explore.gmID, P.explore.L*1e6, valOfQ(q, name), 'p', ...
            'MarkerSize', 12, 'Color', [0.85 0.20 0.15], 'MarkerFaceColor', [1 0.85 0.85]);
        set(h, 'PickableParts', 'none');
    end
end
% 固定坐标轴
xlim(ax, lut.gmidRange);
ylim(ax, [min(lut.L), max(lut.L)]*1e6);
vr = lut.valRange.(name);
if isfield(lut.valRange, name) && isfinite(vr(1)) && isfinite(vr(2)), zlim(ax, vr); end
set(P.lblSurfInfo, 'String', sprintf('%s：VDS=%.2f V | Z=%s | 空心点=各数据管 | 红点=选中管 | 红星=探查点', ...
    D.sourceName(), VDSall(iV), P.getText(P.ddMetricSurf)));
end

function onTabChanged(P, DN, DP, i)
%ONTABCHANGED 切页后按页重画（1=原理图 2=曲线 3=曲面 4=结果）。
%   曲线/曲面页第一次进入时从未绘制过，必须在这里补一次；结果页的表格同理。
%   全程 try 兜底：某一页画不出来（比如数据没加载）也不能让切页本身报错。
try
    switch i
        case 2, onMetric(P, DN, DP);
        case 3, onSurf(P, DN, DP);
        case 4, refreshResult(P);
    end
catch e
    if ~isempty(P) && ismethod(P, 'setStatus')
        P.setStatus(sprintf('切页重画失败：%s', e.message), 'err');
    end
end
end

function refreshResult(P)
%REFRESHRESULT 结果页表格重填（切到结果页时调用）。
if isempty(P.res), return; end
P.refreshTable(P.res);
end

function onCurveClick(P, DN, DP, S)
if isempty(pickData(DN, DP)) || isempty(P.circ), return; end
cp = P.axCurve.CurrentPoint;
pickAt(P, DN, DP, S, cp(1,1), cp(1,2), 'curve');
end

function onSurfClick(P, DN, DP, S)
if isempty(pickData(DN, DP)) || isempty(P.circ), return; end
cp = P.axSurf.CurrentPoint;
pickAt(P, DN, DP, S, cp(1,1), cp(1,2), 'surf');
end

function pickAt(P, DN, DP, S, x, y, which)
%PICKAT 吸附到最近的 (gm/ID, L) 数据点。
%  选中管子 → 写回该管并重解；未选中 → 更新探查点 P.explore（只查看，不改任何器件）。
D = pickData(DN, DP);
if isempty(D) || ~D.isLoaded() || isempty(P.circ), return; end
lut = D.lut;
[~, VDSall, ~] = D.axesInfo();
g = min(max(x, lut.gmidRange(1)), lut.gmidRange(2));
if strcmp(which, 'surf')
    Lq = min(max(y, min(lut.L)), max(lut.L));   % 曲面 y 轴就是 L
    [~, iL] = min(abs(lut.L - Lq));
    iV = vdsIdx(P, P.ddVDSsurf, VDSall);
else
    iV = vdsIdx(P, P.ddVDScurve, VDSall);
    iM = find(strcmp(P.metricItems, P.getText(P.ddMetric)), 1);
    if isempty(iM), iM = 1; end
    name = P.metricKeys{iM};
    Y = reshape(lut.grid.(name)(:, iV, :), lut.nL, lut.nGm);
    if lut.METRICLOG(lut.metricIndex(name)), Y = 10.^Y; end
    yq = interp1(lut.gmGrid, Y.', g, 'linear', NaN);      % nL x 1
    yr = max(Y(:)) - min(Y(:));
    if ~isfinite(yr) || yr <= 0, yr = 1; end
    [~, iL] = min(abs(yq - y)/yr);
end
Lsel = lut.L(iL);
% 查该点读数（用于探查显示）
q = lut.lookup(Lsel, VDSall(iV), g);
P.explore = struct('L', Lsel, 'gmID', g);
if q.valid
    P.explore = struct('L', Lsel, 'gmID', g, 'IdW', q.IdW, 'Vgs', q.Vgs, ...
        'Vdsat', q.Vdsat, 'fT', q.fT, 'selfGain', q.selfGain);
end

if isempty(P.selDev)
    % 未选中管子：只更新探查点，提示该点读数
    txt = sprintf('探查点 L=%.3f um, gm/ID=%.2f', Lsel*1e6, g);
    if q.valid
        txt = sprintf('%s | Id/W=%.4g A/m, Vgs=%.3f V, Vdsat=%.3f V, fT=%.4g GHz, gm/gds=%.1f', ...
            txt, q.IdW, q.Vgs, q.Vdsat, q.fT/1e9, q.selfGain);
    end
    P.setStatus(txt, 'info');
    onMetric(P, DN, DP);  onSurf(P, DN, DP);
    return;
end
% 选中管子：写回并重解
try
    P.circ.setDevice(P.selDev, 'L', Lsel);
    P.circ.setDevice(P.selDev, 'gmID', g);
catch ME
    P.setStatus(['选点失败：' ME.message], 'err');  return;
end
P.edtGmid.String = sprintf('%.8g', g);
li = find(abs(lut.L - Lsel) < 1e-12, 1);
if ~isempty(li) && li <= numel(get(P.ddL,'String')), set(P.ddL, 'Value', li); end
P.log(sprintf('点选吸附：%s -> L=%.3f um, gm/ID=%.2f', P.selDev, Lsel*1e6, g));
refreshAll(P, DN, DP, S, false);
P.setStatus(sprintf('已把 %s 设到 L=%.3f um, gm/ID=%.2f', P.selDev, Lsel*1e6, g), 'ok');
end

%% ============================================================
%  辅助
%% ============================================================
function D = pickData(DN, DP)
%PICKDATA 返回「有数据」的那个数据源（N 优先）；都没有则返回 []。
D = [];
if DN.isLoaded(), D = DN;
elseif DP.isLoaded(), D = DP; end
end

function [L, V, gr] = defaultAxes(DN, DP)
%DEFAULTAXES 有数据 type 的坐标轴（都没有则空）。
L = []; V = []; gr = [NaN NaN];
D = pickData(DN, DP);
if ~isempty(D), [L, V, gr] = D.axesInfo(); end
end

function iV = vdsIdx(P, dd, VDSall)
%VDSIDX 从下拉字符串 'VDS=0.500' 解析出最近的 VDS 索引。
iV = 1;
v = sscanf(P.getText(dd), 'VDS=%f');
if ~isempty(v), [~, iV] = min(abs(VDSall - v)); end
end

function v = valOf(d, name)
switch name
    case 'currentDensity', v = d.Id/max(d.W,eps);
    case 'vgs',   v = d.Vgs;
    case 'vdsat', v = d.Vdsat;
    case 'fug',   v = d.fT;
    case 'selfGain', v = d.selfGain;
    otherwise, v = NaN;
end
end

function v = valOfQ(q, name)
switch name
    case 'currentDensity', v = q.IdW;
    case 'vgs',   v = q.Vgs;
    case 'vdsat', v = q.Vdsat;
    case 'fug',   v = q.fT;
    case 'selfGain', v = q.selfGain;
    otherwise, v = NaN;
end
end
