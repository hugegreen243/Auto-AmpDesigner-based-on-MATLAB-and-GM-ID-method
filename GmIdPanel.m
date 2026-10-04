classdef GmIdPanel < handle
%GMIDPANEL  面板层小顶层：所有控件与布局（不含业务逻辑，逻辑在 AmpDesigner 大顶层）。
%
%   P = GmIdPanel(fig, colors, fontCn, fontEn)
%   specs = P.readSpecs()                 当前指标（已无 Av）
%   P.refreshProp(circ, res)              刷新「选中器件」属性栏与读数
%   P.setSourceLabels(labels, idx)        占位（改用 setPaths）
%   P.setPaths(pathN, pathP)              填 NMOS / PMOS 两个数据路径框
%   P.setStatus(txt, kind)                状态文本（info|ok|warn|err）
%   P.log(lines)                          信息区追加文本
%
%   ★ 部署目标 R2018b：全部使用传统 figure / uipanel / uicontrol / axes。
%     不使用 uigridlayout（R2019a+）、uitabgroup、uibutton 等 App Building 组件。
%
%   ★ 本版**彻底取消 UiKit 中间层**：所有控件就地用原生 uicontrol 创建。
%     理由：UiKit 里的「自绘圆角按钮」（axes + rectangle + text）引入了
%     text 返回值、Callback vs ButtonDownFcn、axes 隐藏仍吞事件等一堆坑，
%     且传统 uicontrol 的 Java 边框本来就无法改圆角。原生方角最稳。
%     缩放进位由本类的 sc()/fs() 承担，字体探测由 pickCjkFont/pickLatinFont 承担。
%
%   ★ 页签切显隐用「改 Position 挪出可视区」而不是只改 Visible：
%     uipanel 设 Visible='off' 时其内部子控件仍可能接收鼠标事件（表现为点不动），
%     挪走 Position 是彻底可靠的做法。
%
% 兼容 MATLAB R2018b。

    properties
        fig; C; FCN; FEN; FMO
        S = 1                   % DPI 缩放系数（设计像素 → 实际像素）
        specDef; nSpec = 5
        layoutMode = 'normal'   % normal | compact（窄窗口时压缩属性栏行距）

        pnlSpec; lblSpec; edtSpec; untSpec
        pnlData; lblData; lblPathN; edtPathN; lblPathP; edtPathP; btnScan; btnLoad
        pnlTopo; lblTopo; ddTopo; lblIn; ddInType; lblOut; ddOutType
        pnlInfo; txtInfo
        tabBar; tabBtns; tabIdx = 1
        onTabChanged = []        % 顶层挂的切页回调：@(i) ...（用于按页重绘）
        pnlSch; pnlCurve; pnlSurf; pnlRes
        ax; pnlProp; lblDev; lblL2; ddL; lblVDS; edtVDS; lblGmid; edtGmid
        lblGm; edtGm; lblSrc
        lblRead1; lblRead2; lblHint
        ddMetric; lblCurve; axCurve
        ddMetricSurf; axSurf; lblSurfInfo
        ddVDScurve; ddVDSsurf
        tblDesign
        btnInit; btnCalc; btnExport; btnClear
        metricItems; metricKeys

        selDev = ''
        circ = []          % 当前电路层对象（大顶层维护）
        res  = []          % 最近一次求解结果
        explore = []       % 曲线/曲面探查点 struct(L, gmID)（不绑定管子的自由选点）

        % --- 布局缓存（用于 resize 时按比例重排）---
        W = 1460; H = 900
        contPos  = []      % 内容页可见位置 [x y w h]
        contPark = []      % 内容页隐藏位置（挪到画布外，彻底断事件穿透）
    end

    %% ================= 构造 =================
    methods
        function P = GmIdPanel(fig, colors, fontCn, fontEn)
            P.fig = fig;  P.C = colors;
            if nargin >= 3 && ~isempty(fontCn), P.FCN = fontCn; end
            if nargin >= 4 && ~isempty(fontEn), P.FEN = fontEn; end
            if isempty(P.FCN), P.FCN = pickCjkFont(); end
            if isempty(P.FEN), P.FEN = pickLatinFont(); end
            % FMO：数值/读数用的「等宽」字体。
            %   ★ 关键：Consolas 这类纯拉丁等宽字体没有 CJK 字形，一旦被套到
            %     含中文的字符串（如「裕量」「（无数据）」）上就会显示成 □□□ 方块。
            %     所以这里优先挑「带 CJK 的等宽字体」，全都找不到才退回 Consolas，
            %     并且调用方只在「纯数字/纯拉丁」的框上使用 FMO。
            P.FMO = pickMonoFont(P.FCN);
            P.S   = P.dpiScale();

            P.specDef = {'GBW','MHz',10.0; 'SR','V/us',10.0; 'ISS','uA',20.0; ...
                         'CL','pF',2.0; 'VDD','V',1.8};
            P.nSpec = size(P.specDef,1);
            P.build();
            P.layout(P.W, P.H);
        end
    end

    %% ================= 缩放 / 字体 =================
    methods
        function s = dpiScale(~)
            %DPISCALE 传统 figure 用像素定位，不同 DPI 下物理尺寸会变，这里统一折算。
            s = 1;
            try
                ppi = get(0, 'ScreenPixelsPerInch');
                if isfinite(ppi) && ppi > 0, s = ppi / 96; end
            catch
            end
            s = min(max(s, 0.75), 2.0);   % 夹紧，避免极端设置把界面撑爆
        end

        function px = sc(P, v)
            %SC 设计像素 → 实际像素（支持标量 / 向量）。
            px = arrayfun(@(x) P.scalar(x), v);
        end

        function f = fs(P, v)
            %FS 字号同步缩放（否则高分屏字太小）。
            f = v * P.S;
        end

        function v = scalar(P, x)
            if ~isfinite(x), v = x; else, v = x * P.S; end
        end
    end

    %% ================= 建控件 =================
    methods
        function build(P)
            C = P.C;  F = P.fig;

            % ===== (1) 设计指标 =====
            P.pnlSpec = P.mkPanel(F, '  (1) 设计指标 / Specs');
            P.lblSpec = gobjects(P.nSpec,1);  P.edtSpec = gobjects(P.nSpec,1);
            P.untSpec = gobjects(P.nSpec,1);
            for k = 1:P.nSpec
                P.lblSpec(k) = P.mkLabel(P.pnlSpec, P.specDef{k,1}, ...
                    'HorizontalAlignment','right', 'FontName', P.FEN, ...
                    'FontSize', P.fs(10), 'FontWeight','bold');
                P.edtSpec(k) = P.mkEditNum(P.pnlSpec, P.specDef{k,3});
                P.edtSpec(k).FontSize = P.fs(11);
                P.untSpec(k) = P.mkLabel(P.pnlSpec, P.specDef{k,2}, ...
                    'FontName', P.FEN, 'FontSize', P.fs(9), 'ForegroundColor', [0.45 0.45 0.45]);
            end

            % ===== (2) 数据源 =====
            P.pnlData = P.mkPanel(F, '  (2) 数据源 / Data（N/P 各一套）');
            P.lblPathN = P.mkLabel(P.pnlData, 'NMOS', ...
                'HorizontalAlignment','right', 'FontName', P.FEN, 'FontSize', P.fs(9), ...
                'BackgroundColor', C.PANEL);
            P.edtPathN = P.mkEdit(P.pnlData, '');
            P.lblPathP = P.mkLabel(P.pnlData, 'PMOS', ...
                'HorizontalAlignment','right', 'FontName', P.FEN, 'FontSize', P.fs(9), ...
                'BackgroundColor', C.PANEL);
            P.edtPathP = P.mkEdit(P.pnlData, '');
            P.btnScan = P.mkButton(P.pnlData, '自动探测', false, []);
            P.btnLoad = P.mkButton(P.pnlData, '加载 N/P', true, C.OK);
            P.lblData = P.mkLabel(P.pnlData, '未加载', ...
                'FontSize', P.fs(9), 'ForegroundColor', [0.55 0.25 0.15]);

            % ===== (3) 拓扑与形式 =====
            P.pnlTopo = P.mkPanel(F, '  (3) 拓扑与形式 / Topology');
            P.lblTopo = P.mkLabel(P.pnlTopo, '拓扑', 'FontSize', P.fs(9));
            P.ddTopo = P.mkDropdown(P.pnlTopo, {'--'});
            P.ddTopo.FontName = P.FEN;
            P.lblIn = P.mkLabel(P.pnlTopo, '输入对', 'FontSize', P.fs(9));
            P.ddInType = P.mkDropdown(P.pnlTopo, {'NMOS 输入对','PMOS 输入对'});
            P.lblOut = P.mkLabel(P.pnlTopo, '输出', 'FontSize', P.fs(9));
            P.ddOutType = P.mkDropdown(P.pnlTopo, {'单端 Single-Ended','全差分 Fully-Diff'});

            % ===== (4) 状态与告警 =====
            P.pnlInfo = P.mkPanel(F, '  (4) 状态与告警');
            P.txtInfo = P.mkTextArea(P.pnlInfo);
            set(P.txtInfo, 'String', {'就绪'});

            % ===== 页签条 + 四个内容面板 =====
            P.tabBar = uipanel('Parent', F, 'Units', 'pixels', ...
                'BorderType', 'none', 'BackgroundColor', [0.88 0.89 0.92]);
            P.mkTabs(P.tabBar, ...
                {'  原理图（点器件选中）  ','  gm/ID 曲线  ','  gm/ID 曲面  ','  设计结果  '});

            % 原理图页
            P.pnlSch = P.mkPlainPanel(F, C.BG);
            P.ax = P.mkAxesBox(P.pnlSch);
            P.pnlProp = P.mkPanel(P.pnlSch, '  选中器件参数 / Device（改 gm 反推总 Iss）');
            P.buildProp();

            % 曲线页
            P.pnlCurve = P.mkPlainPanel(F, C.BG);
            P.metricItems = {'Id/W (A/m)','Vgs (V)','Vdsat (V)','fT (Hz)','gm/gds (-)'};
            P.metricKeys  = {'currentDensity','vgs','vdsat','fug','selfGain'};
            P.ddMetric = P.mkDropdown(P.pnlCurve, P.metricItems);
            P.ddMetric.FontName = P.FEN;
            P.ddVDScurve = P.mkDropdown(P.pnlCurve, {'VDS=--'});
            P.ddVDScurve.FontName = P.FMO;
            P.lblCurve = P.mkLabel(P.pnlCurve, ...
                '曲线族：灰线=各 L，蓝线=选中管 L，红点=选中管', ...
                'FontSize', P.fs(10), 'ForegroundColor', [0.35 0.35 0.35]);
            P.axCurve = P.mkAxesBox(P.pnlCurve);
            set(P.axCurve, 'YDir', 'normal', 'XTickMode','auto', 'YTickMode','auto', ...
                'XTickLabelMode','auto', 'YTickLabelMode','auto');

            % 曲面页
            P.pnlSurf = P.mkPlainPanel(F, C.BG);
            P.ddMetricSurf = P.mkDropdown(P.pnlSurf, P.metricItems);
            P.ddMetricSurf.FontName = P.FEN;
            P.ddVDSsurf = P.mkDropdown(P.pnlSurf, {'VDS=--'});
            P.ddVDSsurf.FontName = P.FMO;
            P.lblSurfInfo = P.mkLabel(P.pnlSurf, ...
                'Z = 指标，X = gm/ID，Y = L（VDS 由上方下拉选）', ...
                'FontSize', P.fs(10), 'ForegroundColor', [0.35 0.35 0.35]);
            P.axSurf = axes('Parent', P.pnlSurf, 'Units','pixels', 'Position', P.sc([0 0 100 100]), ...
                'Color', [1 1 1], 'Box', 'on', 'FontName', P.FEN, 'FontSize', P.fs(9));
            try, rotate3d(P.axSurf, 'off'); catch, end

            % 结果页
            P.pnlRes = P.mkPlainPanel(F, C.BG);
            % 表格字体必须用 CJK 字体：表头/单元格里有「类型 / 角色 / 裕量 / 饱和 / 来源」
            % 这些中文，若用 Segoe UI 这类无 CJK 的拉丁字体，Java 表格渲染会出方块 □。
            P.tblDesign = uitable('Parent', P.pnlRes, 'Units', 'pixels', ...
                'Position', P.sc([0 0 100 100]), ...
                'ColumnName', {'尚未计算'}, 'Data', cell(0,1), ...
                'FontName', P.FCN, 'FontSize', P.fs(10), 'RowName', 'numbered');

            % ===== 底部按钮 =====
            P.btnInit   = P.mkButton(F, '初始化 / Init',  true,  C.OK);
            P.btnCalc   = P.mkButton(F, '计算 / Compute', true,  C.ACCENT);
            P.btnExport = P.mkButton(F, '导出 / Export',  false, []);
            P.btnClear  = P.mkButton(F, '清空 / Clear',   false, []);

            % 建完统一按当前 tabIdx 摆一次（layout 里还会再摆）
            P.applyTabVis();
        end

        function buildProp(P)
            %BUILDPROP 属性栏：两排参数 + 三行读数。位置在 layout() 里排。
            P.lblDev  = P.mkLabel(P.pnlProp, '器件：—', ...
                'FontWeight','bold', 'ForegroundColor', P.C.ACCENT, 'FontSize', P.fs(10));
            P.lblL2   = P.mkLabel(P.pnlProp, 'L', 'FontName', P.FEN, ...
                'FontWeight','bold', 'FontSize', P.fs(10));
            P.ddL     = P.mkDropdown(P.pnlProp, {'--'});
            P.ddL.FontName = P.FMO;
            P.lblVDS  = P.mkLabel(P.pnlProp, 'VDS', 'FontName', P.FEN, ...
                'FontWeight','bold', 'FontSize', P.fs(10));
            P.edtVDS  = P.mkEditNum(P.pnlProp, 0.5);
            P.lblGmid = P.mkLabel(P.pnlProp, 'gm/ID', 'FontName', P.FEN, ...
                'FontWeight','bold', 'FontSize', P.fs(10));
            P.edtGmid = P.mkEditNum(P.pnlProp, 10);

            P.lblGm   = P.mkLabel(P.pnlProp, 'gm (uS)', 'FontWeight','bold', 'FontSize', P.fs(9));
            P.edtGm   = P.mkEditNum(P.pnlProp, 0);
            P.lblSrc  = P.mkLabel(P.pnlProp, ...
                '所有器件参数（W/Vgs/Vdsat/fT/gm-gds）一律查 LUT，无需手填模型参数', ...
                'FontSize', P.fs(9), 'ForegroundColor', [0.45 0.45 0.45]);

            P.lblRead1 = P.mkLabel(P.pnlProp, '—', 'FontName', P.FMO, ...
                'FontSize', P.fs(10), 'ForegroundColor', [0.10 0.35 0.65]);
            P.lblRead2 = P.mkLabel(P.pnlProp, '—', 'FontName', P.FMO, ...
                'FontSize', P.fs(10), 'ForegroundColor', [0.10 0.35 0.65]);
            P.lblHint  = P.mkLabel(P.pnlProp, ...
                '用法：点原理图里的管子选中 → 改 L / VDS / gm/ID（VDS 每管自由输入）→ 图、节点电压与读数实时更新；点空白处取消选中', ...
                'FontSize', P.fs(9), 'ForegroundColor', [0.35 0.35 0.35]);
        end
    end

    %% ================= 原生控件工厂（就地创建，无中间层）=================
    methods
        function h = mkPanel(P, parent, title)
            %MKPANEL 带标题的分组框。
            if nargin < 3, title = ''; end
            h = uipanel('Parent', parent, 'Units', 'pixels', ...
                'Position', P.sc([0 0 100 100]), ...
                'Title', title, 'TitlePosition', 'lefttop', ...
                'FontName', P.FCN, 'FontSize', P.fs(11), 'FontWeight', 'bold', ...
                'ForegroundColor', P.C.TITLE, 'BackgroundColor', P.C.PANEL, ...
                'BorderType', 'line', 'HighlightColor', [0.78 0.80 0.84], ...
                'ShadowColor', [0.90 0.91 0.93]);
        end

        function h = mkPlainPanel(P, parent, bg)
            %MKPLAINPANEL 无边框透明容器（放内容页）。
            h = uipanel('Parent', parent, 'Units', 'pixels', ...
                'Position', P.sc([0 0 100 100]), ...
                'BorderType', 'none', 'BackgroundColor', bg);
        end

        function h = mkAxesBox(P, parent)
            %MKAXESBOX 画图用坐标轴。YDir 必须 normal（VDD 在上、GND 在下）。
            h = axes('Parent', parent, 'Units', 'pixels', 'Position', P.sc([0 0 100 100]), ...
                'Color', [1 1 1], 'Box', 'on', 'Layer', 'top', ...
                'XGrid', 'off', 'YGrid', 'off', 'ZGrid', 'off', ...
                'XTick', [], 'YTick', [], 'XTickLabel', {}, 'YTickLabel', {}, ...
                'FontName', P.FEN, 'FontSize', P.fs(9), ...
                'XLim', [0 100], 'YLim', [0 100], 'YDir', 'normal');
            hold(h, 'on');
        end

        function h = mkLabel(P, parent, txt, varargin)
            %MKLABEL 静态文本。名值对透传给 uicontrol。
            h = uicontrol('Parent', parent, 'Style', 'text', ...
                'Units', 'pixels', 'Position', P.sc([0 0 10 10]), ...
                'String', txt, 'HorizontalAlignment', 'left', ...
                'FontName', P.FCN, 'FontSize', P.fs(10), ...
                'BackgroundColor', P.C.PANEL, varargin{:});
        end

        function h = mkButton(P, parent, txt, isPrimary, bg)
            %MKBUTTON 原生方角按钮（R2018b 默认样式；无 Java 改造、无自绘 axes）。
            %   isPrimary=true  → 实心底色 + 白字（主操作）
            %   bg              → 主按钮底色（缺省用强调色）
            if nargin < 4, isPrimary = false; end
            if isPrimary
                if nargin < 5 || isempty(bg), bg = P.C.ACCENT; end
                h = uicontrol('Parent', parent, 'Style', 'pushbutton', ...
                    'Units', 'pixels', 'Position', P.sc([0 0 10 10]), ...
                    'String', txt, 'FontName', P.FCN, 'FontSize', P.fs(11), ...
                    'FontWeight', 'bold', 'BackgroundColor', bg, ...
                    'ForegroundColor', [1 1 1]);
            else
                h = uicontrol('Parent', parent, 'Style', 'pushbutton', ...
                    'Units', 'pixels', 'Position', P.sc([0 0 10 10]), ...
                    'String', txt, 'FontName', P.FCN, 'FontSize', P.fs(10));
            end
        end

        function h = mkDropdown(P, parent, items)
            %MKDROPDOWN 下拉框。items 为元胞字符串数组。
            items = P.cellstr(items);
            if isempty(items), items = {'--'}; end
            h = uicontrol('Parent', parent, 'Style', 'popupmenu', ...
                'Units', 'pixels', 'Position', P.sc([0 0 10 10]), ...
                'String', items, 'Value', 1, ...
                'FontName', P.FCN, 'FontSize', P.fs(10), ...
                'BackgroundColor', [1 1 1]);
        end

        function h = mkEdit(P, parent, txt)
            %MKEDIT 单行文本输入框。
            h = uicontrol('Parent', parent, 'Style', 'edit', ...
                'Units', 'pixels', 'Position', P.sc([0 0 10 10]), ...
                'String', txt, 'HorizontalAlignment', 'left', ...
                'FontName', P.FMO, 'FontSize', P.fs(10), ...
                'BackgroundColor', [1 1 1]);
        end

        function h = mkEditNum(P, parent, v)
            %MKEDITNUM 数值输入框（右对齐）。
            if isnumeric(v), v = sprintf('%.6g', v); end
            h = uicontrol('Parent', parent, 'Style', 'edit', ...
                'Units', 'pixels', 'Position', P.sc([0 0 10 10]), ...
                'String', v, 'HorizontalAlignment', 'right', ...
                'FontName', P.FMO, 'FontSize', P.fs(10), ...
                'BackgroundColor', [1 1 1]);
        end

        function h = mkTextArea(P, parent)
            %MKTEXTAREA 多行只读文本。用 edit 的 Max>1 形式（R2018b 无 uitextarea）。
            h = uicontrol('Parent', parent, 'Style', 'edit', ...
                'Units', 'pixels', 'Position', P.sc([0 0 10 10]), ...
                'String', {''}, 'Max', 2, 'Min', 0, ...
                'HorizontalAlignment', 'left', 'Enable', 'inactive', ...
                'FontName', P.FCN, 'FontSize', P.fs(9), ...
                'BackgroundColor', [1 1 1]);
        end

        function mkTabs(P, parent, titles)
            %MKTABS 自制页签条：一组原生 pushbutton。
            %   （uitabgroup 在 R2018b 存在但布局不稳，这里统一自绘，最可控）
            n = numel(titles);
            P.tabBtns = gobjects(1, n);
            for k = 1:n
                P.tabBtns(k) = uicontrol('Parent', parent, 'Style', 'pushbutton', ...
                    'Units', 'pixels', 'Position', P.sc([0 0 10 10]), ...
                    'String', titles{k}, 'FontName', P.FCN, 'FontSize', P.fs(10), ...
                    'BackgroundColor', [0.80 0.82 0.86], ...
                    'Callback', @(s,e) P.tabSel(k));
            end
            P.tabPick(1);
        end

        function tabPick(P, i)
            %TABPICK 画页签高亮（不动回调，回调由 tabSel 负责）。
            P.tabIdx = i;
            for k = 1:numel(P.tabBtns)
                if k == i
                    set(P.tabBtns(k), 'BackgroundColor', [1 1 1], 'FontWeight', 'bold');
                else
                    set(P.tabBtns(k), 'BackgroundColor', [0.80 0.82 0.86], 'FontWeight', 'normal');
                end
            end
        end

        function out = cellstr(~, items)
            if ischar(items), out = {items};
            elseif isstring(items), out = cellstr(items);
            else, out = items; end
        end
    end

    %% ================= 布局（像素绝对定位） =================
    methods
        function layout(P, W, H)
            %LAYOUT 按窗口尺寸重排全部控件。
            if nargin < 2 || isempty(W), W = P.W; end
            if nargin < 3 || isempty(H), H = P.H; end
            P.W = W;  P.H = H;

            M = 10;                       % 外边界
            specH = 100;                  % 顶部指标栏
            btnH  = 58;                   % 底部按钮栏
            leftW = 300;                  % 左列宽
            gap = 10;

            yBtn  = M;
            yMid  = M + btnH + gap;
            midH  = H - yMid - specH - gap - M;      % 中间区高
            ySpec = yMid + midH + gap;

            % --- (1) 指标栏 ---
            set(P.pnlSpec, 'Position', P.sc([M ySpec W-2*M specH]));
            cw = [46 92 34];  innerX = 12;  innerW = (W-2*M) - 2*innerX;
            unitW = innerW / P.nSpec;
            for k = 1:P.nSpec
                x0 = innerX + (k-1)*unitW;
                yRow = 42;
                set(P.lblSpec(k), 'Position', P.sc([x0 yRow cw(1) 22]));
                set(P.edtSpec(k), 'Position', P.sc([x0+cw(1)+4 yRow cw(2) 22]));
                set(P.untSpec(k), 'Position', P.sc([x0+cw(1)+cw(2)+8 yRow cw(3) 22]));
            end

            % --- 左列：自上而下 = 数据源 / 拓扑 / 状态（像素坐标 y 从下往上）---
            lx = M;  lw = leftW;
            hData = 150;  hTopo = 150;
            gapL = 8;
            % 状态区吃掉剩余高度；剩余不足时按比例压缩三个面板，保证永不越界
            avail = midH - 2*gapL;
            if avail < hData + hTopo + 80
                s2 = avail / (hData + hTopo + 80);
                hData = hData * s2;  hTopo = hTopo * s2;
            end
            hInfo = avail - hData - hTopo;
            yInfo = yMid;                                  % 状态在最下
            yTopo = yInfo + hInfo + gapL;                  % 拓扑居中
            yData = yTopo + hTopo + gapL;                  % 数据源在最上

            set(P.pnlData, 'Position', P.sc([lx yData lw hData]));
            set(P.pnlTopo, 'Position', P.sc([lx yTopo lw hTopo]));
            set(P.pnlInfo, 'Position', P.sc([lx yInfo lw hInfo]));
            P.layoutData(P.pnlData);
            P.layoutTopo(P.pnlTopo);
            set(P.txtInfo, 'Position', P.sc([8 8 lw-16 max(hInfo-24, 30)]));

            % --- 右列：页签条 + 内容 ---
            rx = M + lw + gap;  rw = W - rx - M;
            tabH = 30;
            yTab = yMid + midH - tabH;
            set(P.tabBar, 'Position', P.sc([rx yTab rw tabH]));
            P.relayoutTabs(rw, tabH);
            contH = midH - tabH - 6;
            P.contPos = P.sc([rx yMid rw contH]);      % 缓存内容页目标位置
            P.contPark = P.sc([rx-20000 yMid rw contH]);   % 隐藏页挪去画布外

            % 原理图页：上图（自适应）+ 下属性栏
            P.layoutSch(rw, contH);
            P.layoutCurve(rw, contH);
            P.layoutSurf(rw, contH);
            set(P.tblDesign, 'Position', P.sc([8 8 rw-16 contH-16]));

            % --- 底部按钮（4 个：初始化 / 计算 / 导出 / 清空）---
            bh = max(btnH - 26, 26);
            by = M + 10;
            bw = (W - 2*M - 3*12 - 2*120) / 4;
            bx = M + 120;
            for b = {P.btnInit, P.btnCalc, P.btnExport, P.btnClear}
                set(b{1}, 'Position', P.sc([bx by bw bh]));
                bx = bx + bw + 12;
            end

            P.applyTabVis();
        end

        function relayoutTabs(P, rw, tabH)
            %RELAYOUTTABS 页签按钮按当前宽度均分。
            n = numel(P.tabBtns);
            w = rw / n;
            for k = 1:n
                set(P.tabBtns(k), 'Position', P.sc([(k-1)*w+2 2 w-4 tabH-4]));
            end
        end

        function layoutData(P, pnl)
            %LAYOUTDATA 数据源面板内的控件（按面板实际高度自上而下排）。
            ph = get(pnl, 'Position');  ph = ph(4) / max(P.S, eps);
            lw2 = 300;
            rh = 26;
            y0 = ph - 42;                      % 让开 panel 标题
            set(P.lblPathN, 'Position', P.sc([8  y0      46 22]));
            set(P.edtPathN, 'Position', P.sc([58 y0      lw2-70 22]));
            set(P.lblPathP, 'Position', P.sc([8  y0-rh   46 22]));
            set(P.edtPathP, 'Position', P.sc([58 y0-rh   lw2-70 22]));
            set(P.btnScan,  'Position', P.sc([8  y0-2*rh 120 24]));
            set(P.btnLoad,  'Position', P.sc([140 y0-2*rh 150 24]));
            set(P.lblData,  'Position', P.sc([8  max(y0-2*rh-24, 4) lw2-16 20]));
        end

        function layoutTopo(P, pnl)
            %LAYOUTTOPO 拓扑面板内的控件。
            ph = get(pnl, 'Position');  ph = ph(4) / max(P.S, eps);
            rh = 30;  lw = 46;
            y0 = ph - 48;
            set(P.lblTopo, 'Position', P.sc([10 y0      lw 22]));
            set(P.ddTopo,  'Position', P.sc([58 y0      222 24]));
            set(P.lblIn,   'Position', P.sc([10 y0-rh   lw 22]));
            set(P.ddInType,'Position', P.sc([58 y0-rh   222 24]));
            set(P.lblOut,  'Position', P.sc([10 y0-2*rh lw 22]));
            set(P.ddOutType,'Position',P.sc([58 y0-2*rh 222 24]));
        end

        function layoutSch(P, rw, contH)
            propH = 160;
            axW = rw - 16;  axH = contH - propH - 24;
            set(P.ax, 'Position', P.sc([8 propH+18 axW max(axH,80)]));
            % YDir 必须 normal：原理图约定 VDD 在上（y=95）、GND 在下（y=14）。
            set(P.ax, 'XLim', [0 100], 'YLim', [0 100], 'YDir', 'normal', ...
                'XTick', [], 'YTick', []);
            set(P.pnlProp, 'Position', P.sc([8 8 rw-16 propH]));
            P.layoutProp(rw-16, propH);
        end

        function layoutProp(P, pw, ph) %#ok<INUSD>
            x = 10;  y0 = ph - 48;   % 让开 uipanel 标题
            % 第一排：器件 / L / VDS / gm-ID
            set(P.lblDev,  'Position', P.sc([x y0 150 22]));
            x1 = x + 156;
            set(P.lblL2,   'Position', P.sc([x1 y0 20 22]));
            set(P.ddL,     'Position', P.sc([x1+22 y0 88 24]));
            x2 = x1 + 118;
            set(P.lblVDS,  'Position', P.sc([x2 y0 40 22]));
            set(P.edtVDS,  'Position', P.sc([x2+42 y0 70 24]));
            x3 = x2 + 122;
            set(P.lblGmid, 'Position', P.sc([x3 y0 48 22]));
            set(P.edtGmid, 'Position', P.sc([x3+50 y0 76 24]));
            % 第二排：gm + 说明
            y1 = y0 - 30;
            set(P.lblGm,  'Position', P.sc([x y1 60 22]));
            set(P.edtGm,  'Position', P.sc([x+62 y1 76 24]));
            set(P.lblSrc, 'Position', P.sc([x+146 y1 max(pw-x-156,120) 22]));
            % 三行读数
            ry = y1 - 28;
            set(P.lblRead1, 'Position', P.sc([x ry      pw-20 20]));
            set(P.lblRead2, 'Position', P.sc([x ry-22   pw-20 20]));
            set(P.lblHint,  'Position', P.sc([x ry-46   pw-20 20]));
        end

        function layoutCurve(P, rw, contH)
            topH = 26;
            yTop = contH - topH - 10;
            set(P.ddMetric,   'Position', P.sc([8 yTop 168 24]));
            set(P.ddVDScurve, 'Position', P.sc([182 yTop 128 24]));
            set(P.lblCurve,   'Position', P.sc([318 yTop max(rw-340,120) 22]));
            set(P.axCurve, 'Position', P.sc([8 8 rw-16 contH-topH-26]));
        end

        function layoutSurf(P, rw, contH)
            topH = 26;
            yTop = contH - topH - 10;
            set(P.ddMetricSurf, 'Position', P.sc([8 yTop 168 24]));
            set(P.ddVDSsurf,    'Position', P.sc([182 yTop 128 24]));
            set(P.lblSurfInfo,  'Position', P.sc([318 yTop max(rw-340,120) 22]));
            set(P.axSurf, 'Position', P.sc([8 8 rw-16 contH-topH-26]));
        end
    end

    %% ================= 页签切换 =================
    methods
        function tabSel(P, i)
            P.tabPick(i);          % 画高亮 + 记 tabIdx
            P.applyTabVis();       % 摆内容页显隐
            % 切页后通知顶层「这一页需要重画」：曲线/曲面页首次进入必须画一次，
            % 否则是一片空白，再去动下拉还会因为状态没准备好而报错。
            if ~isempty(P.onTabChanged)
                try, P.onTabChanged(i); catch, end
            end
        end

        function applyTabVis(P)
            %APPLYTABVIS 切换内容页显隐。
            %   ★ 关键：四个内容页 Position 完全重合，且页内 axes/uicontrol 也重合。
            %   只把 uipanel 设 Visible='off' 并不可靠 —— 某些情况下隐藏容器的
            %   子控件仍会接收鼠标事件（表现为「曲线/曲面点不动」「切页报错」）。
            %   所以这里用「把不可见页整体挪到画布外」的方式，彻底断绝事件穿透。
            %   ★ 注意：这里不能用 isfield(P,'contPos') 做存在性判断 ——
            %     isfield 只对 struct 有效，对 classdef 对象恒返回 false，
            %     会把整个函数直接短路成 return（本函数曾因此完全失效）。
            if isempty(P.contPos), return; end
            pages = {P.pnlSch, P.pnlCurve, P.pnlSurf, P.pnlRes};
            for k = 1:4
                if isempty(pages{k}) || ~ishghandle(pages{k}), continue; end
                if k == P.tabIdx
                    set(pages{k}, 'Position', P.contPos);
                    try, uistack(pages{k}, 'top'); catch, end
                else
                    set(pages{k}, 'Position', P.contPark);
                end
            end
        end

        function showTab(P, name)
            %SHOWTAB 按名字切页（供顶层调用）。
            switch name
                case 'res',   i = 4;
                case 'curve', i = 2;
                case 'surf',  i = 3;
                otherwise,    i = 1;
            end
            P.tabSel(i);
        end
    end

    %% ================= 小接口 =================
    methods
        function specs = readSpecs(P)
            v = zeros(P.nSpec,1);
            for k = 1:P.nSpec, v(k) = P.getNum(P.edtSpec(k), P.specDef{k,3}); end
            specs = struct('GBW', v(1)*1e6, 'SR', v(2)*1e6, 'ISS', v(3)*1e-6, ...
                           'CL', v(4)*1e-12, 'VDD', v(5));
        end

        function setStatus(P, txt, kind)
            if nargin < 3, kind = 'info'; end
            set(P.lblData, 'String', txt);
            switch kind
                case 'ok',   set(P.lblData, 'ForegroundColor', P.C.OK);
                case 'warn', set(P.lblData, 'ForegroundColor', [0.6 0.4 0.1]);
                case 'err',  set(P.lblData, 'ForegroundColor', P.C.DANGER);
                otherwise,   set(P.lblData, 'ForegroundColor', [0.2 0.2 0.2]);
            end
        end

        function log(P, lines)
            P.logAppend(P.txtInfo, lines, 300);
        end

        function bindBtn(P, h, cb)
            %BINDBTN 绑按钮回调。本版按钮都是原生 uicontrol pushbutton，直接写 Callback。
            if isempty(h) || ~ishghandle(h), return; end
            set(h, 'Callback', @(src, ev) cb());
        end

        function setSourceLabels(P, labels, idx) %#ok<INUSD>
            % 占位：数据源改为 N/P 双路径框后不再用下拉。
        end

        function setPaths(P, pathN, pathP)
            if nargin >= 2 && ~isempty(pathN), set(P.edtPathN, 'String', pathN); end
            if nargin >= 3 && ~isempty(pathP), set(P.edtPathP, 'String', pathP); end
        end

        function setTopoItems(P, items)
            P.setItems(P.ddTopo, items, false);
        end

        function inType = inputType(P)
            if strncmpi(P.getText(P.ddInType), 'p', 1), inType = 'pmos'; else, inType = 'nmos'; end
        end

        function tf = isFD(P)
            tf = strncmpi(P.getText(P.ddOutType), '全', 1);
        end

        function setLItems(P, L)
            if isempty(L)
                P.setItems(P.ddL, {'--'}, false); return;
            end
            it = cell(1, numel(L));
            for k = 1:numel(L), it{k} = sprintf('%.3f um', L(k)*1e6); end
            P.setItems(P.ddL, it, false);
        end

        function setVDSitems(P, VDSall)
            %SETVDSITEMS 填充曲线/曲面两个独立的 VDS 切片下拉（默认取中间那片）。
            if isempty(VDSall)
                P.setItems(P.ddVDScurve, {'VDS=--'}, false);
                P.setItems(P.ddVDSsurf,  {'VDS=--'}, false);
                return;
            end
            it = cell(1, numel(VDSall));
            for k = 1:numel(VDSall), it{k} = sprintf('VDS=%.3f', VDSall(k)); end
            mid = min(ceil(numel(it)/2), numel(it));
            P.setItems(P.ddVDScurve, it, false);
            P.setItems(P.ddVDSsurf,  it, false);
            set(P.ddVDScurve, 'Value', mid);
            set(P.ddVDSsurf,  'Value', mid);
        end

        function setSelected(P, name)
            P.selDev = name;
            if isempty(name)
                set(P.lblDev, 'String', '器件：—（点原理图里的管子）');
            end
        end

        function refreshProp(P, circ, res)
            %REFRESHPROP 把选中器件的状态与解算结果填进属性栏
            if isempty(circ) || isempty(P.selDev) || isempty(res) || ~isfield(res,'devices')
                return;
            end
            if ~any(strcmp(circ.deviceNames(), P.selDev))   % 换拓扑后旧选中可能已不存在
                P.setSelected('');
                set(P.lblRead1, 'String', '—');  set(P.lblRead2, 'String', '—');
                return;
            end
            j = find(strcmp({res.devices.name}, P.selDev), 1);
            if isempty(j), return; end
            s = circ.state(P.selDev);
            d = res.devices(j);
            set(P.lblDev, 'String', sprintf('器件：%s（%s, %s）', d.name, d.type, d.role));
            set(P.edtVDS,  'String', sprintf('%.8g', s.VDS));
            set(P.edtGmid, 'String', sprintf('%.8g', s.gmID));
            set(P.edtGm,   'String', sprintf('%.8g', d.gm*1e6));   % µS
            dk = circ.dataFor(d.type);
            Lall = [];
            if ~isempty(dk) && dk.isLoaded(), [Lall, ~, ~] = dk.axesInfo(); end
            li = find(abs(Lall - s.L) < 1e-12, 1);
            if ~isempty(li) && li <= numel(get(P.ddL,'String'))
                set(P.ddL, 'Value', li);
            end
            isModel = strcmp(d.source, 'nodata');
            if isModel
                set(P.lblSrc, 'String', '无数据：请在上方填入对应 N/P 的 gm/ID 数据路径');
            else
                set(P.lblSrc, 'String', '查 LUT（有数据）');
            end
            set(P.lblRead1, 'String', sprintf('Id=%.4g uA   W=%.4g um   Vgs=%.4g V   Vdsat=%.4g V   gm/gds=%.1f   fT=%.4g GHz', ...
                d.Id*1e6, d.W*1e6, d.Vgs, d.Vdsat, d.selfGain, d.fT/1e9));
            if strcmp(d.sat, '饱和'), col = [0.10 0.55 0.25];
            elseif strcmp(d.sat, '临界'), col = [0.85 0.55 0.10];
            else, col = P.C.DANGER; end
            set(P.lblRead2, 'String', sprintf('|VDS|act=%.4g V   裕量=%+.4g V   %s   gm=%.4g uS   L(数据)=%.4g um', ...
                d.VDSact, d.margin, d.sat, d.gm*1e6, d.L*1e6));
            set(P.lblRead2, 'ForegroundColor', col);
        end

        function refreshTable(P, res)
            if isempty(res) || ~isfield(res,'tableCols'), return; end
            set(P.tblDesign, 'ColumnName', res.tableCols);
            set(P.tblDesign, 'Data', res.tableData);
            try
                set(P.tblDesign, 'ColumnWidth', {44,28,84,54,58,50,48,48,52,58,52,54,48,52,44,42});
            catch
            end
        end
    end

    %% ================= 文本/数值小工具 =================
    methods
        function t = getText(P, h)
            %GETTEXT 取下拉/编辑框的当前字符串。
            s = get(h, 'String');
            if iscell(s)
                v = get(h, 'Value');
                v = min(max(v, 1), numel(s));
                t = s{v};
            else
                t = s;
            end
        end

        function v = getNum(P, h, default)
            %GETNUM 取编辑框数值；非法时返回 default 并把控件回填成 default。
            if nargin < 3, default = NaN; end
            v = str2double(strtrim(P.getText(h)));
            if ~isfinite(v)
                v = default;
                if isfinite(default), set(h, 'String', sprintf('%.6g', default)); end
            end
        end

        function setItems(P, h, items, keepValue)
            %SETITEMS 重填下拉项（尽量保持当前选中语义）。
            if nargin < 4, keepValue = true; end
            cur = P.getText(h);
            items = P.cellstr(items);
            if isempty(items), items = {'--'}; end
            set(h, 'Value', 1, 'String', items);      % 先置 1 避免 Value 越界
            if keepValue
                j = find(strcmp(items, cur), 1);
                if ~isempty(j), set(h, 'Value', j); end
            end
        end

        function logAppend(P, h, lines, maxLines)
            %LOGAPPEND 追加日志；超过上限只留最后 maxLines 行。
            %   ★ 不碰 Java（旧 UiKit 用 findjobj 试图滚到底，是闪退/警告来源之一），
            %     只做纯 HGC 的字符串追加，最稳。
            if nargin < 4, maxLines = 300; end
            if ischar(lines), lines = {lines}; end
            v = get(h, 'String');
            if ischar(v), v = {v}; end
            v = v(:);
            if numel(v) == 1 && isempty(strtrim(v{1})), v = {}; end
            for k = 1:numel(lines)
                s = lines{k};
                if ~ischar(s), s = char(s); end
                v{end+1} = s; %#ok<AGROW>
            end
            if numel(v) > maxLines, v = v(end-maxLines+1:end); end
            if isempty(v), v = {''}; end
            set(h, 'String', v);
        end
    end
end
