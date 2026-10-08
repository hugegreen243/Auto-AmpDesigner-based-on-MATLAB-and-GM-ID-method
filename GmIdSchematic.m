classdef GmIdSchematic < handle
%GMIDSCHEMATIC  图层小顶层：画拓扑原理图 + 注册器件热区/net 位置 + 图上标注。
%
%   S = GmIdSchematic(ax, colors, fontEn)
%   S.draw(circ, res)       画电路并标注（器件参数 / Id / 各 net 电压）
%   S.refresh(circ, res)    只更新标注文字（器件/连线不动）
%   n = S.pickDevice(x,y)   由点击坐标返回器件名（'' = 未命中）
%   S.setSelected(name)     选中高亮
%
% 标注口径：每管两行（`M1 gm/ID=12.57`、`W=1.91u Id=10.0u`）；
% 选中管把管名行改为重色加粗、并画一个器件高亮框（图上**不再**展开 5 行参数，
% 详情只在下方「选中器件参数」面板里看，避免遮挡连线）；
% 每个 net 标 `名字 电压`（偏置蓝、普通深蓝、电源轨灰、冲突红）。
%
% ★ 图元池化：所有 line/text/patch 都从固定池里复用，刷新时只 set 属性、
%   多余项 Visible='off'，**不做 delete + 重建**。这条是为了绕开 Windows 上
%   MATLAB 图形栈的高频句柄增删导致的堆损坏（0xc0000374）崩溃。
%
% 兼容 MATLAB R2018b。

    properties
        ax
        C
        FNT = 'Microsoft YaHei'   % 图上标注含中文（器件名/网络名/「无数据」提示等）；
                                  % 构造函数会用 pickCjkFont 换成本机可用 CJK 字体
        sel = ''
        idx = struct('dev', struct('name',{},'x',{},'y',{},'H',{},'side',{},'kind',{}), ...
                     'net', struct('name',{},'x',{},'y',{},'align',{}))
        mirror = false      % 已废弃：VDD/GND 固定上下，各 geom 显式处理 PMOS 输入布局
        pmosIn = false
        fd = false
        % ---- 图上文字排版（比面板字号大：原理图缩放后仍要能看清）----
        % 注意：这组数值与「器件标注矩形预估 / 避让余量」强耦合（见 annotate 与 resolveY），
        % 单独调大会触发叠字（test_gmid_draw 会红）。这里只把「节点电压 / 电源轨 / 输出」
        % 这三类较短的标注放大一档，器件标注块（最宽、最易撞车）维持 12.5 不变。
        FS_DEV = 12.5       % 器件标注（管名 gm/ID、W/Id、L/Vgs、Vdsat…）
        FS_SEL = 13.5       % 选中器件的管名行（加粗高亮）
        FS_NET = 14         % net 节点电压标注（VDD/GND/VB*/VIN±/OUT…）
        FS_RAIL= 15         % 电源轨标签（VDD/GND）
        FS_OUT = 14         % 输出节点文字（Vout / Vout±）
        DS = 1.45           % 字号缩放系数：相对 base 8.5 的放大倍率
        DX = 2.5            % 标注水平偏移基准（进入 0.55*H + DX）
        DY = 3.15           % 标注行距（放大后必须同步加大，否则行间会叠字）
        FS_NET2 = 12        % 节点标注撞车时的降级字号（避开器件常驻标注）
        CLR_NET = [0.10 0.35 0.65]  % 节点标注默认色（与 annotate 内一致）
    end

    properties (Access = private)
        circ
        % ---- 图元池（消除 delete/重建的高频句柄增删，绕开 Windows 图形栈堆损坏）----
        pL = gobjects(1,0)      % line 池
        pT = gobjects(1,0)      % text 池（图示文字 + 标注）
        pA = gobjects(1,0)      % patch 池（节点圆点 / MOS 箭头）
        iL = 0; iT = 0; iA = 0  % 池水位
        iLLock = 0; iALock = 0  % 几何层固定占用的 line / patch 数
        iTLock = 0              % 几何层固定占用的 text 数（装置文字），refresh 时从这里开始覆盖
    end

    methods
        function obj = GmIdSchematic(ax, colors, fontEn)
            obj.ax = ax;  obj.C = colors;
            if nargin >= 3 && ~isempty(fontEn), obj.FNT = fontEn; end
            % 落到本机确实存在的中文字体，保证 Windows / CentOS7 上都有 CJK 字形
            obj.FNT = pickCjkFont();
        end

        %% ---------------- 顶层：画 ----------------
        function draw(obj, circ, res)
            obj.circ = circ;
            obj.pmosIn = strncmpi(circ.topo.inType, 'p', 1);
            obj.fd = circ.fd;
            % VDD 永远在上、GND 永远在下；PMOS 输入时各 geom 显式交换负载/尾电流位置，
            % 不做整体上下翻转（否则 VDD/GND 会反转）。
            obj.mirror = false;
            obj.idx.dev = struct('name',{},'x',{},'y',{},'H',{},'side',{},'kind',{});
            obj.idx.net = struct('name',{},'x',{},'y',{},'align',{});
            % 图元池复位：不删句柄，只把水面降到 0，后面按需复用
            obj.resetPools();
            set(obj.ax, 'XLim', [0 100], 'YLim', [0 100], ...
                'XTick', [], 'YTick', [], 'Visible', 'on');
            switch circ.topo.name
                case 'Five-Transistor OTA',    obj.geom5T();
                case 'Folded Cascode OTA',     obj.geomFolded();
                case 'Telescopic Cascode OTA', obj.geomTelescopic();
                case 'Common Source',          obj.geomCS();
            end
            % 几何画完 → 锁住静态层水位：装置文字/连线属于「静态层」，
            % annotate() 反复刷新时不该去抢它们的槽位。
            obj.lockStatic();
            obj.annotate(circ, res);
            obj.shrinkPools();
        end

        function refresh(obj, circ, res)
            %REFRESH 只重写标注层（装置文字与连线原地不动）。同样是复用，不删句柄。
            %   但拓扑/器件方向改变会改装置文字，故这两项变化时补做一次几何重画。
            reGeom = false;
            if ~isempty(obj.circ)
                reGeom = ~strcmp(obj.circ.topo.name, circ.topo.name) || ...
                         strncmpi(obj.circ.topo.inType,'p',1) ~= strncmpi(circ.topo.inType,'p',1) || ...
                         obj.circ.fd ~= circ.fd;
            end
            if reGeom
                obj.draw(circ, res);
                return;
            end
            obj.circ = circ;
            obj.iT = obj.iTLock;       % 标注文字从锁定水位之后覆盖写
            obj.iL = obj.iLLock;       % 选中框复用锁定之后的 line 槽位
            obj.iA = obj.iALock;
            obj.annotate(circ, res);
            obj.shrinkPools();
        end

        function resetPools(obj)
            %RESETPOOLS 把池水位归零（句柄保留，仅重新分配）。
            obj.iL = 0;  obj.iT = 0;  obj.iA = 0;
            obj.iLLock = 0; obj.iTLock = 0; obj.iALock = 0;
        end

        function shrinkPools(obj)
            %SHRINKPOOLS 把本轮没用到的池成员设为不可见（而非删除，避免句柄增删）。
            for k = obj.iL+1:numel(obj.pL)
                if isgraphics(obj.pL(k)), set(obj.pL(k), 'Visible', 'off'); end
            end
            for k = obj.iT+1:numel(obj.pT)
                if isgraphics(obj.pT(k)), set(obj.pT(k), 'Visible', 'off'); end
            end
            for k = obj.iA+1:numel(obj.pA)
                if isgraphics(obj.pA(k)), set(obj.pA(k), 'Visible', 'off'); end
            end
        end

        function lockStatic(obj)
            %LOCKSTATIC 几何层画完后调用：记下静态层的水位。
            obj.iLLock = obj.iL;  obj.iTLock = obj.iT;  obj.iALock = obj.iA;
        end

        function n = pickLine(obj)
            obj.iL = obj.iL + 1;  n = obj.iL;
            if n > numel(obj.pL)
                obj.pL(n) = line('Parent', obj.ax, 'XData', [], 'YData', [], ...
                    'Color', obj.C.LINE, 'LineWidth', 1.2);
            end
        end

        function n = pickText(obj)
            obj.iT = obj.iT + 1;  n = obj.iT;
            if n > numel(obj.pT)
                obj.pT(n) = text('Parent', obj.ax, 'Position', [0 0], 'String', '', ...
                    'HorizontalAlignment', 'left', 'FontName', obj.FNT, 'FontSize', obj.FS_DEV, ...
                    'Color', [0 0 0], 'Interpreter', 'none');
            end
        end

        function n = pickPatch(obj)
            obj.iA = obj.iA + 1;  n = obj.iA;
            if n > numel(obj.pA)
                obj.pA(n) = patch('Parent', obj.ax, 'XData', NaN, 'YData', NaN, ...
                    'FaceColor', obj.C.LINE, 'EdgeColor', 'none');
            end
        end

        function n = pickDevice(obj, x, y)
            n = '';  best = inf;
            for k = 1:numel(obj.idx.dev)
                d = obj.idx.dev(k);
                w = 0.9*d.H;
                if x >= d.x-w && x <= d.x+w && y >= d.y-d.H/2-1.5 && y <= d.y+d.H/2+1.5
                    dd = abs(x-d.x) + abs(y-d.y);
                    if dd < best, best = dd; n = d.name; end
                end
            end
        end

        function setSelected(obj, name), obj.sel = name; end

        %% ---------------- 标注 ----------------
        function annotate(obj, circ, res) %#ok<INUSL>
            if isempty(res) || ~isfield(res,'devices'), return; end
            dev = res.devices;
            rects = zeros(0,4);      % 已排布标注的 [x1 x2 y1 y2]（用于互相避让）
            % 先把 net 节点标注占位塞进去：节点名/电压是原理图的硬标注，
            % 不允许器件标注压过去；自身位置由几何决定，不再挪。
            if isfield(res,'nodes')
                for k = 1:numel(obj.idx.net)
                    g = obj.idx.net(k);
                    j = find(strcmp({res.nodes.name}, g.name), 1);
                    if isempty(j), continue; end
                    n = res.nodes(j);
                    if ~isfinite(n.value), continue; end
                    if strcmpi(g.align,'right'), nx1 = g.x - 16; nx2 = g.x;
                    else,                         nx1 = g.x;      nx2 = g.x + 16; end
                    rects(end+1,:) = [nx1 nx2 g.y-0.8 g.y+0.8]; %#ok<AGROW>
                end
            end
            sSel = 0;                % 选中管的序号（0 = 无）
            K = [];  KD = {};        % 有标注的器件序号 / 对应求解结果（阶段三统一绘制）
            K2Y = [];                % 每个器件的最终 y0（首行位置）
            for k = 1:numel(obj.idx.dev)
                g = obj.idx.dev(k);
                j = find(strcmp({dev.name}, g.name), 1);
                if isempty(j), continue; end
                d = dev(j);
                isSel = strcmp(obj.sel, g.name);
                % 选中管与常驻标注用同一套几何与避让：图上只多一个高亮框 + 管名行高亮，
                % 不再额外展开 5 行参数（那些只在下方面板里展示）。
                [lx, ~, ~, sgn] = obj.annGeom(g);
                y0 = g.y + 0.40*g.H;
                x1 = min(lx, lx + sgn*18);           % 矩形横向范围（按最大行宽 18 估）
                x2 = max(lx, lx + sgn*18);
                y0 = obj.resolveY(x1, x2, y0, obj.DY, rects);   % 两行标注统一避让
                rects(end+1,:) = [x1 x2 y0-obj.DY y0+0.75]; %#ok<AGROW>
                K(end+1) = k; %#ok<AGROW>
                KD{end+1} = d; %#ok<AGROW>
                K2Y(end+1) = y0; %#ok<AGROW>
                if isSel, sSel = numel(K); end     % sSel 是 KD/K2Y 的下标（非 idx.dev 下标）
            end
            % ---- 阶段二：选中块优先级最高，把与它相交的常驻块推走 ----
            %   关键：pushRect 只「改位置」，不重复画字（否则同一管会画两遍、看起来像两个字）。
            % ---- 阶段二（已移除）----
            %   早期选中管会在图上展开 5 行参数，需要把相交的常驻标注 / 节点标注推走，
            %   故有 pushRect / nudgeNet 这一整套避让。现在选中管与常驻标注同为 2 行、
            %   走同一套 resolveY 避让，不再产生「高优先级大块」，这套推挤逻辑作废。
            % ---- 阶段三：统一画器件标注（用 K2Y 里的最终 y0，绝不重复绘制）----
            for k = 1:numel(K)
                g = obj.idx.dev(K(k));
                d = KD{k};
                y0 = K2Y(k);
                [lx, dy, ha] = obj.annGeom(g);
                if k == sSel     % 选中管：管名行加粗高亮（颜色区分即可，不再多画参数）
                    obj.txt(lx, y0, sprintf('%s gm/ID=%.2f', g.name, d.gmid), ha, obj.FS_SEL, obj.C.ACCENT, 'bold');
                else
                    obj.txt(lx, y0, sprintf('%s gm/ID=%.2f', g.name, d.gmid), ha, obj.FS_DEV, [0.30 0.30 0.30], 'normal');
                end
                obj.txt(lx, y0-dy, obj.wLine(d), ha, obj.FS_DEV, [0.30 0.30 0.30], 'normal');
            end
            % ---- 阶段四：选中管的器件高亮框（只画框，不在图上堆参数）----
            if sSel >= 1
                g = obj.idx.dev(K(sSel));
                % 框半宽取 0.70*H：刚好包住 MOS 符号本体（栅极引线最远到 0.68*H），
                % 又不会越过器件标注的锚点（0.55*H + DX = 10.2），避免蓝框切过管名文字。
                w = 0.70*g.H;
                nb = obj.pickLine();     % 选中框也走池（refresh 时复用，不删不建）
                set(obj.pL(nb), 'XData', [g.x-w g.x+w g.x+w g.x-w g.x-w], ...
                    'YData', [g.y-g.H/2-1.2 g.y-g.H/2-1.2 g.y+g.H/2+1.2 g.y+g.H/2+1.2 g.y-g.H/2-1.2], ...
                    'Color', obj.C.ACCENT, 'LineWidth', 1.0, 'Visible', 'on');
            end
            if isfield(res, 'nodes')
                for k = 1:numel(obj.idx.net)
                    g = obj.idx.net(k);
                    j = find(strcmp({res.nodes.name}, g.name), 1);
                    if isempty(j), continue; end
                    n = res.nodes(j);
                    if ~isfinite(n.value), continue; end
                    if n.conflict, col = obj.C.DANGER;
                    elseif strcmp(n.kind,'bias'), col = obj.C.ACCENT;
                    elseif strcmp(n.kind,'rail'), col = [0.30 0.30 0.30];
                    else, col = obj.netColor(); end
                    % 节点标注横向从 (g.x,g.y) 向外展开（左对齐向右、右对齐向左），
                    % 估一个矩形，撞到器件标注时先上下挪、再缩字号。
                    if strcmpi(g.align,'right'), nx1 = g.x - 16; nx2 = g.x;
                    else,                         nx1 = g.x;      nx2 = g.x + 16; end
                    ny = obj.resolveY(nx1, nx2, g.y, 0, rects);
                    fsN = obj.FS_NET;
                    if abs(ny - g.y) > 0.5
                        fsN = obj.FS_NET2;
                        ny = obj.resolveY(nx1, nx2, g.y, 0, rects, obj.FS_NET2);
                    end
                    rects(end+1,:) = [nx1 nx2 ny-0.8 ny+0.8]; %#ok<AGROW>
                    obj.txt(g.x, ny, sprintf('%s %.3fV', g.name, n.value), g.align, fsN, col, 'bold');
                end
            end
        end

        %% ---------------- 标注几何 / 文本 ----------------
        function [lx, dy, ha, sgn] = annGeom(obj, g)
            %ANNGEOM 某器件标注块的横向锚点、行距与对齐。
            %   标注一律朝「远离画布中缝」的一侧排：x<50 标左，x>=50 标右。
            %   不用 g.side —— 该字段描述栅极朝向，与本处排布方向不一致（如 M4）。
            %   选中管与常驻标注共用本几何（选中只改颜色/字重，不再外推、不再加行）。
            if g.x < 50, sgn = -1; ha = 'right'; else, sgn = +1; ha = 'left'; end
            lx = g.x + sgn*(0.55*g.H + obj.DX);
            dy = obj.DY;
        end

        function c = netColor(obj)
            %NETCOLOR 普通 net 标注色。兼容旧调用方未提供 LINE2 字段的情况。
            if isfield(obj.C, 'LINE2'), c = obj.C.LINE2; else, c = [0.10 0.35 0.65]; end
        end

        function s = wLine(obj, d)
            %WLINE 器件标注第二行的 W/Id 文本（无数据时给出「（无数据）」提示）。
            if strcmp(d.source, 'data')
                if isfinite(d.W) && isfinite(d.Id)
                    s = sprintf('W=%.3gu Id=%.4gu', d.W*1e6, d.Id*1e6);
                else
                    s = 'W=-- Id=--';
                end
            elseif isfinite(d.Id)
                s = sprintf('W=-- Id=%.4gu（无数据）', d.Id*1e6);
            else
                s = 'W=-- Id=--（无数据）';
            end
        end

        function y = resolveY(obj, x1, x2, yWant, dyBlock, rects, fs)
            %RESOLVEY 让 [x1 x2] × 以 yWant 为顶（含 dyBlock 向下延伸）的块不与 rects 相交。
            %   常驻器件标注 dyBlock>0；节点标注 dyBlock=0（单行）。
            %   节点标注还允许整个块上移，避免压到 VDD/VDD 轨或画布下沿。
            if nargin < 7, fs = 0; end
            xlo = min(x1,x2);  xhi = max(x1,x2);
            yBottomMin = 2.5;  yTopMax = 97.5;
            ext = (dyBlock > 0) * 0.35 + (fs > 0) * 0.45;   % 双向余量
            cands = [0 1.6 -1.6 2.9 -2.9 4.2 -4.2 5.5 -5.5 7.0 -7.0 9.0 -9.0 11 -11];
            if dyBlock > 0, cands = cands(1:min(9,numel(cands))); end   % 常驻标注只小幅挪
            bestOv = inf;  yBest = yWant;
            for ci = 1:numel(cands)
                yy = yWant + cands(ci);
                ry1 = yy - dyBlock - ext;   ry2 = yy + 0.75 + ext;
                if yy - dyBlock < yBottomMin || yy > yTopMax, continue; end
                ov = 0;
                for q = 1:size(rects,1)
                    ix = min(xhi,rects(q,2)) - max(xlo,rects(q,1));
                    iy = min(ry2,rects(q,4)) - max(ry1,rects(q,3));
                    if ix > 0 && iy > 0, ov = ov + ix*iy; end
                end
                if ov < bestOv - 1e-9
                    bestOv = ov;  yBest = yy;
                    if ov <= 1e-9, break; end
                end
            end
            y = yBest;
        end

        %% ---------------- 图元（全部走池，不做 delete/重建） ----------------
        function txt(obj, x, y, s, ha, fs, col, fw, itp)
            %TXT 图上文字。itp 默认 'none'：器件参数含 'u'（微米）与 '--'，
            %   若走 TeX 解释器 'u' 会被吃成 \mu、'--' 会被吃成连字符，必须 none。
            %   只有带下标的花体标签（V_{out}）才显式传 'tex'。
            if nargin < 8, fw = 'normal'; end
            if nargin < 9, itp = 'none'; end
            n = obj.pickText();
            set(obj.pT(n), 'Position', [x y], 'String', s, 'HorizontalAlignment', ha, ...
                'FontName', obj.FNT, 'FontSize', fs, 'Color', col, 'FontWeight', fw, ...
                'Interpreter', itp, 'Visible', 'on');
        end

        function w = W(obj, xs, ys)
            n = obj.pickLine();
            w = obj.pL(n);
            set(w, 'XData', xs, 'YData', ys, 'Color', obj.C.LINE, 'LineWidth', 1.2, ...
                'Visible', 'on');
        end
        function WH(obj, x1, x2, y), obj.W([x1 x2], [y y]); end
        function WV(obj, x, y1, y2), obj.W([x x], [y1 y2]); end

        function nd(obj, x, y)
            r = 0.8;  th = linspace(0, 2*pi, 16);
            n = obj.pickPatch();
            set(obj.pA(n), 'XData', x+r*cos(th), 'YData', y+r*sin(th), ...
                'FaceColor', obj.C.LINE, 'EdgeColor', 'none', 'Visible', 'on');
        end

        function gnd(obj, x, y)
            %GND 接地符号：从 y 处的接线端起，**先向下拉一段竖直线**（lead），
            %   再在最下端画三条依次减短的横线（最上面最长 7，然后 5，最下面最短 3），
            %   这是教科书的标准画法（器件源极 → 一段引线 → 三条横线的地符号）。
            %   注意：本工程 VDD 恒在上、GND 恒在下（mirror 永远为 false），
            %   所以接地符号一律朝下（-y 方向），不用 sgn 翻转，避免画反。
            lead = 3.0;           % 竖直引线长度
            y0 = y - lead;        % 三条横线的最上一条所在高度
            w0 = 3.5;  g = 1.5;   % 半宽基准 + 线间距
            obj.WV(x, y, y0);     % ★ 先往下拉一段直线
            obj.WH(x-w0,      x+w0,      y0);
            obj.WH(x-(w0-1),  x+(w0-1),  y0 - g);
            obj.WH(x-(w0-2),  x+(w0-2),  y0 - 2*g);
        end

        function rail(obj, x1, x2, yLog, s)
            y = obj.Y(yLog);
            obj.WH(x1, x2, y);
            obj.txt((x1+x2)/2, y + obj.sgn*2.6, s, 'center', obj.FS_RAIL, obj.C.BODY, 'bold', 'tex');
        end

        function t = sym(obj, name, x, yLog, H, kind, side)
            %SYM 竖直 MOS 符号；注册热区。yLog 为逻辑坐标（镜像时自动翻）
            yc = obj.Y(yLog);
            kk = obj.K(kind);
            isN = (lower(kk) == 'n');
            if lower(side) == 'l', dir = -1; else, dir = +1; end
            yTop = yc + H/2;  yBot = yc - H/2;
            chH = 0.62*H;  chTop = yc + chH/2;  chBot = yc - chH/2;
            stub = 0.24*H;  gap = 0.10*H;  gateH = 0.80*chH;  leadL = 0.34*H;
            xCh = x + dir*stub;  xg = xCh + dir*gap;  xgEnd = xg + dir*leadL;
            obj.WV(x, chTop, yTop);  obj.WV(x, yBot, chBot);
            obj.WH(x, xCh, chTop);   obj.WH(x, xCh, chBot);
            n1 = obj.pickLine();
            set(obj.pL(n1), 'XData', [xCh xCh], 'YData', [chBot chTop], ...
                'Color', obj.C.LINE, 'LineWidth', 2.6, 'Visible', 'on');
            n2 = obj.pickLine();
            set(obj.pL(n2), 'XData', [xg xg], 'YData', [yc-gateH/2 yc+gateH/2], ...
                'Color', obj.C.LINE, 'LineWidth', 1.7, 'Visible', 'on');
            obj.WH(xgEnd, xg, yc);
            th = 0.80*stub;  tw = 0.70*th;  xc0 = x + dir*stub/2;
            if isN, col = obj.C.NMOS; yA = chBot; d = -dir;      % NMOS 箭头朝外
            else,   col = obj.C.PMOS; yA = chTop; d = dir;  end  % PMOS 箭头朝里
            x0 = xc0 - d*th/2;
            n3 = obj.pickPatch();
            set(obj.pA(n3), 'XData', [x0, x0, x0+d*th], 'YData', [yA-tw, yA+tw, yA], ...
                'FaceColor', col, 'EdgeColor', 'none', 'Visible', 'on');
            obj.idx.dev(end+1) = struct('name',name,'x',x,'y',yc,'H',H,'side',side,'kind',kk);
            t = struct('top',[x yTop], 'bot',[x yBot], 'G',[xgEnd yc]);
        end

        function regNet(obj, name, x, y, align)
            if nargin < 5, align = 'left'; end
            if any(strcmp({obj.idx.net.name}, name)), return; end
            obj.idx.net(end+1) = struct('name',name,'x',x,'y',y,'align',align);
        end

        function y = Y(obj, v), if obj.mirror, y = 100 - v; else, y = v; end, end
        function s = sgn(obj), if obj.mirror, s = -1; else, s = +1; end, end
        function k = K(obj, kind)
            k = kind;
            if obj.mirror
                if lower(kind) == 'n', k = 'p'; else, k = 'n'; end
            end
        end
        function g = gate(obj, t, dx, dy)
            % 栅极引出线；返回该 net 标注位置（放在引线上方，避免压线/压器件文字）
            obj.WH(t.G(1), t.G(1)+dx, t.G(2));
            g = [t.G(1)+dx + sign(dx)*1.0, t.G(2) + obj.sgn*2.8 + dy];
        end
    end

    %% ============================================================
    %  各拓扑几何（逻辑坐标：VDD 在上、GND 在下；镜像由 Y/K 处理）
    %% ============================================================
    methods (Access = private)
        function geom5T(obj)
            H = 14;  xL = 32;  xR = 68;  xC = 50;
            yVDD = 95;  yGND = 14;
            if obj.pmosIn
                obj.geom5T_pmos(H, xL, xR, xC, yVDD, yGND);
            else
                obj.geom5T_nmos(H, xL, xR, xC, yVDD, yGND);
            end
        end

        function geom5T_nmos(obj, H, xL, xR, xC, yVDD, yGND)
            % NMOS 输入：PMOS 负载在上（S 接 VDD）、NMOS 输入对在中、NMOS 尾电流在下（S 接 GND）
            yLd = 78;  yIn = 52;  yTl = 26;
            obj.rail(xL-4, xR+4, yVDD, 'V_{DD}');
            m3 = obj.sym('M3', xL, yLd, H, 'p', 'l');
            m4 = obj.sym('M4', xR, yLd, H, 'p', 'l');
            obj.WV(xL, m3.top(2), yVDD);  obj.WV(xR, m4.top(2), yVDD);
            if obj.fd
                g3 = obj.gate(m3, -6, 0);  obj.regNet('VB', g3(1), g3(2), 'right');
                g4 = obj.gate(m4, +6, 0);  obj.regNet('VB', g4(1), g4(2), 'left');
            else
                xBus = xL - 14;
                obj.WH(m3.G(1), xBus, m3.G(2));  obj.WH(m4.G(1), xBus, m4.G(2));
                yD = m3.bot(2);  yDip = yD + 2;
                obj.WV(xBus, m3.G(2), yDip);  obj.WH(xBus, xL, yDip);  obj.WV(xL, yDip, yD);
                obj.nd(xL, yDip);
                obj.regNet('X', xL - 6, yDip + 3.4, 'right');
            end
            m1 = obj.sym('M1', xL, yIn, H, 'n', 'l');
            m2 = obj.sym('M2', xR, yIn, H, 'n', 'r');
            obj.WV(xL, m1.top(2), m3.bot(2));  obj.WV(xR, m2.top(2), m4.bot(2));
            g1 = obj.gate(m1, -8, 0);  obj.regNet('VIN+', g1(1), g1(2), 'right');
            g2 = obj.gate(m2, +8, 0);  obj.regNet('VIN-', g2(1), g2(2), 'left');
            yMid = m1.bot(2);
            obj.WH(xL, xR, yMid);  obj.nd(xC, yMid);
            obj.regNet('P', xC + 2, yMid + 2.2, 'left');
            m5 = obj.sym('M5', xC, yTl, H-2, 'n', 'l');
            obj.WV(xC, m5.top(2), yMid);
            obj.WV(xC, m5.bot(2), yGND);
            obj.gnd(xC, yGND);
            g5 = obj.gate(m5, -8, 0);  obj.regNet('VB0', g5(1), g5(2), 'right');
            obj.out5T(xL, xR, m3.bot(2));
            obj.regNet('VDD', xL-3.5, yVDD - 4.0, 'right');
            obj.regNet('GND', xC+4, yGND + 3.6, 'left');
        end

        function geom5T_pmos(obj, H, xL, xR, xC, yVDD, yGND)
            % PMOS 输入：PMOS 尾电流在上（S 接 VDD）、PMOS 输入对在中、NMOS 负载在下（S 接 GND）
            yTl = 78;  yIn = 52;  yLd = 26;
            obj.rail(xL-4, xR+4, yVDD, 'V_{DD}');
            m5 = obj.sym('M5', xC, yTl, H-2, 'p', 'l');
            obj.WV(xC, m5.top(2), yVDD);      % S 接 VDD
            g5 = obj.gate(m5, -8, 0);  obj.regNet('VB0', g5(1), g5(2), 'right');
            yP = m5.bot(2);                    % D 接 P
            m1 = obj.sym('M1', xL, yIn, H, 'p', 'l');
            m2 = obj.sym('M2', xR, yIn, H, 'p', 'r');
            obj.WV(xL, m1.top(2), yP);  obj.WV(xR, m2.top(2), yP);
            obj.WH(xL, xR, yP);  obj.nd(xC, yP);
            obj.regNet('P', xC + 2, yP + 2.2, 'left');
            g1 = obj.gate(m1, -8, 0);  obj.regNet('VIN+', g1(1), g1(2), 'right');
            g2 = obj.gate(m2, +8, 0);  obj.regNet('VIN-', g2(1), g2(2), 'left');
            m3 = obj.sym('M3', xL, yLd, H, 'n', 'l');
            m4 = obj.sym('M4', xR, yLd, H, 'n', 'r');
            obj.WV(xL, m3.top(2), m1.bot(2));  obj.WV(xR, m4.top(2), m2.bot(2));
            obj.WV(xL, m3.bot(2), yGND);  obj.WV(xR, m4.bot(2), yGND);
            obj.gnd(xC, yGND);
            if obj.fd
                g3 = obj.gate(m3, -6, 0);  obj.regNet('VB', g3(1), g3(2), 'right');
                g4 = obj.gate(m4, +6, 0);  obj.regNet('VB', g4(1), g4(2), 'left');
            else
                xBus = xL - 14;
                obj.WH(m3.G(1), xBus, m3.G(2));  obj.WH(m4.G(1), xBus, m4.G(2));
                yD = m3.top(2);  yDip = yD - 2;
                obj.WV(xBus, m3.G(2), yDip);  obj.WH(xBus, xL, yDip);  obj.WV(xL, yDip, yD);
                obj.nd(xL, yDip);
                obj.regNet('X', xL - 6, yDip - 3.4, 'right');
            end
            obj.out5T(xL, xR, m1.bot(2));
            obj.regNet('VDD', xL-3.5, yVDD - 4.0, 'right');
            obj.regNet('GND', xC+4, yGND + 3.6, 'left');
        end

        function out5T(obj, xL, xR, yOut)
            % 5T 输出引出：单端 Vout（右），全差分 Vout+/Vout-（左右两路，net 为 X / OUT）
            if obj.fd
                obj.WH(xL, xL-12, yOut);  obj.WH(xR, xR+12, yOut);
                obj.txt(xL-13, yOut, 'V_{out+}', 'right', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
                obj.txt(xR+13, yOut, 'V_{out-}', 'left', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
                obj.regNet('X',   xL-13, yOut - 3.4, 'right');
                obj.regNet('OUT', xR+13, yOut - 5.0, 'left');
            else
                obj.WH(xR, xR+12, yOut);
                obj.txt(xR+13, yOut, 'V_{out}', 'left', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
                obj.regNet('OUT', xR + 13, yOut - 5.0, 'left');
            end
        end

        function geomFolded(obj)
            xOL = 24;  xIL = 43;  xC = 50;  xIR = 57;  xOR = 76;
            yVDD = 94;  yGND = 22;
            if obj.pmosIn
                % PMOS 版外侧竖列有 5 级（M10/M7/M3/M5 + OUT 折返），比 NMOS 版更挤，
                % 故单独用较小的符号高 H=10、行距 15，给标注留出足够间隙。
                obj.geomFolded_pmos(10, xOL, xIL, xC, xIR, xOR, yVDD, yGND);
            else
                obj.geomFolded_nmos(12, xOL, xIL, xC, xIR, xOR, yVDD, yGND);
            end
        end

        function geomFolded_nmos(obj, H, xOL, xIL, xC, xIR, xOR, yVDD, yGND)
            % NMOS 输入：P 折叠电流源 M5/M6 在上(源接 VDD, Iss) → X/Y；
            %  P cascode M3/M4 由 X/Y 上到 OUT；N 输入对 M1/M2 在中(源接 P)；
            %  N cascode M7/M8 由 Q/R 上到 OUT；N 电流沉 M10/M11 在下(源接 GND, Iss/2)；
            %  N 尾电流 M9 在最下(源接 GND) → P。VDD 恒在上、GND 恒在下。
            yCS = 89;  yA = 79;  yC1 = 69;  yOut = 60;  yC2 = 50;  yB = 40;  yBot = 31;
            yIn = 62;  yP = 52;  yTl = 34;
            obj.rail(xOL-8, xOR+8, yVDD, 'V_{DD}');
            obj.WH(xOL, xOR, yGND);  obj.gnd(xC, yGND);
            m5 = obj.sym('M5', xOL, yCS, H, 'p', 'l');
            m6 = obj.sym('M6', xOR, yCS, H, 'p', 'r');
            obj.WV(xOL, m5.top(2), yVDD);  obj.WV(xOR, m6.top(2), yVDD);
            g5 = obj.gate(m5, -6, 0);  obj.regNet('VB3', g5(1), g5(2), 'right');
            g6 = obj.gate(m6, +6, 0);  obj.regNet('VB3', g6(1), g6(2), 'left');
            m3 = obj.sym('M3', xOL, yC1, H, 'p', 'l');
            m4 = obj.sym('M4', xOR, yC1, H, 'p', 'r');
            obj.WV(xOL, m5.bot(2), m3.top(2));  obj.WV(xOR, m6.bot(2), m4.top(2));
            obj.nd(xOL, yA);  obj.nd(xOR, yA);
            g3 = obj.gate(m3, -6, 0);  obj.regNet('VB2', g3(1), g3(2), 'right');
            g4 = obj.gate(m4, +6, 0);  obj.regNet('VB2', g4(1), g4(2), 'left');
            m7 = obj.sym('M7', xOL, yC2, H, 'n', 'l');
            m8 = obj.sym('M8', xOR, yC2, H, 'n', 'r');
            obj.WV(xOL, m3.bot(2), yOut);  obj.WV(xOR, m4.bot(2), yOut);
            obj.WV(xOL, m7.top(2), yOut);  obj.WV(xOR, m8.top(2), yOut);
            obj.foldedOut(xOL, xOR, yOut);
            g7 = obj.gate(m7, -6, 0);  obj.regNet('VB1', g7(1), g7(2), 'right');
            g8 = obj.gate(m8, +6, 0);  obj.regNet('VB1', g8(1), g8(2), 'left');
            m10 = obj.sym('M10', xOL, yBot, H, 'n', 'l');
            m11 = obj.sym('M11', xOR, yBot, H, 'n', 'r');
            obj.WV(xOL, m7.bot(2), m10.top(2));  obj.WV(xOR, m8.bot(2), m11.top(2));
            obj.WV(xOL, m10.bot(2), yGND);       obj.WV(xOR, m11.bot(2), yGND);
            g10 = obj.gate(m10, -6, 0);  obj.regNet('VB4', g10(1), g10(2), 'right');
            g11 = obj.gate(m11, +6, 0);  obj.regNet('VB4', g11(1), g11(2), 'left');
            % 输入支路（N 输入对，漏接 X/Y，源接 P）
            m1 = obj.sym('M1', xIL, yIn, H, 'n', 'l');
            m2 = obj.sym('M2', xIR, yIn, H, 'n', 'r');
            gi1 = obj.gate(m1, -6, 0);  obj.regNet('VIN+', gi1(1), gi1(2), 'right');
            gi2 = obj.gate(m2, +6, 0);  obj.regNet('VIN-', gi2(1), gi2(2), 'left');
            obj.WV(xIL, m1.top(2), yA);  obj.WV(xIR, m2.top(2), yA);
            obj.WH(xOL, xIL, yA);  obj.WH(xOR, xIR, yA);
            obj.WV(xIL, m1.bot(2), yP);  obj.WV(xIR, m2.bot(2), yP);
            obj.regNet('X', xOL-2, yA + 2.4, 'right');
            obj.regNet('Y', xOR+2, yA + 2.4, 'left');
            obj.regNet('Q', xOL-2, yB - 2.6, 'right');
            obj.WH(xIL, xIR, yP);  obj.nd(xC, yP);
            obj.regNet('P', xC+2, yP + 2.4, 'left');
            m9 = obj.sym('M9', xC, yTl, H, 'n', 'l');
            g9 = obj.gate(m9, -6, 0);  obj.regNet('VB0', g9(1), g9(2), 'right');
            obj.WV(xC, m9.top(2), yP);  obj.WV(xC, m9.bot(2), yGND);
            obj.regNet('VDD', xOL-4, yVDD - 3.6, 'right');
            obj.regNet('GND', xC+4, yGND + 3.4, 'left');
        end

        function geomFolded_pmos(obj, H, xOL, xIL, xC, xIR, xOR, yVDD, yGND)
            % PMOS 输入（电学镜像）：行结构相对 NMOS 版**上下颠倒**，但 VDD 仍在上、GND 仍在下。
            % 实测节点电压（高→低）：VDD1.80 → Q/R1.35 → P0.90 → OUT0.90 → X/Y0.45 → GND0。
            %   外侧左/右支路（自上而下）：P 电流沉 M10/M11(源 VDD, Iss/2) → P cascode M7/M8 → OUT
            %                              → N cascode M3/M4 → N 折叠电流源 M5/M6(源 GND, Iss) → GND
            %   内侧：P 输入对 M1/M2（源接 P，漏接 X/Y）；中央：P 尾电流 M9（源 VDD，漏 P）
            ySink = 82;  yCasP = 68;  yOut = 55;  yCasN = 42;  yA = 36;  yCS = 25;
            yIn = 47;  yP = 61;  yTl = 84;
            obj.rail(xOL-8, xOR+8, yVDD, 'V_{DD}');
            obj.WH(xOL, xOR, yGND);  obj.gnd(xC, yGND);
            % --- 顶部外侧：P 电流沉 M10/M11（源接 VDD，漏 Q/R，Iss/2）---
            m10 = obj.sym('M10', xOL, ySink, H, 'p', 'l');
            m11 = obj.sym('M11', xOR, ySink, H, 'p', 'r');
            obj.WV(xOL, m10.top(2), yVDD);  obj.WV(xOR, m11.top(2), yVDD);
            g10 = obj.gate(m10, -6, 0);  obj.regNet('VB4', g10(1), g10(2), 'right');
            g11 = obj.gate(m11, +6, 0);  obj.regNet('VB4', g11(1), g11(2), 'left');
            % --- P cascode M7/M8（源接 Q/R，漏下到 OUT）---
            m7 = obj.sym('M7', xOL, yCasP, H, 'p', 'l');
            m8 = obj.sym('M8', xOR, yCasP, H, 'p', 'r');
            obj.WV(xOL, m10.bot(2), m7.top(2));  obj.WV(xOR, m11.bot(2), m8.top(2));
            obj.nd(xOL, (m10.bot(2)+m7.top(2))/2);  obj.nd(xOR, (m11.bot(2)+m8.top(2))/2);
            obj.regNet('Q', xOL-2, yCasP + H/2 + 3.0, 'right');
            obj.regNet('R', xOR+2, yCasP + H/2 + 3.0, 'left');
            g7 = obj.gate(m7, -6, 0);  obj.regNet('VB1', g7(1), g7(2), 'right');
            g8 = obj.gate(m8, +6, 0);  obj.regNet('VB1', g8(1), g8(2), 'left');
            obj.WV(xOL, m7.bot(2), yOut);  obj.WV(xOR, m8.bot(2), yOut);
            obj.foldedOut(xOL, xOR, yOut);
            % --- N cascode M3/M4（漏接 OUT，源接 X/Y）---
            m3 = obj.sym('M3', xOL, yCasN, H, 'n', 'l');
            m4 = obj.sym('M4', xOR, yCasN, H, 'n', 'r');
            obj.WV(xOL, m3.top(2), yOut);  obj.WV(xOR, m4.top(2), yOut);
            g3 = obj.gate(m3, -6, 0);  obj.regNet('VB2', g3(1), g3(2), 'right');
            g4 = obj.gate(m4, +6, 0);  obj.regNet('VB2', g4(1), g4(2), 'left');
            % --- 底部外侧：N 折叠电流源 M5/M6（源接 GND，漏 X/Y，Iss）---
            m5 = obj.sym('M5', xOL, yCS, H, 'n', 'l');
            m6 = obj.sym('M6', xOR, yCS, H, 'n', 'r');
            obj.WV(xOL, m3.bot(2), yA);   obj.WV(xOR, m4.bot(2), yA);
            obj.WV(xOL, m5.top(2), yA);   obj.WV(xOR, m6.top(2), yA);
            obj.WH(xOL, xIL, yA);  obj.WH(xOR, xIR, yA);
            obj.nd(xOL, yA);  obj.nd(xOR, yA);
            obj.WV(xOL, m5.bot(2), yGND);  obj.WV(xOR, m6.bot(2), yGND);
            g5 = obj.gate(m5, -6, 0);  obj.regNet('VB3', g5(1), g5(2), 'right');
            g6 = obj.gate(m6, +6, 0);  obj.regNet('VB3', g6(1), g6(2), 'left');
            obj.regNet('X', (xOL+xIL)/2, yA + 2.8, 'center');
            obj.regNet('Y', (xIR+xOR)/2, yA + 2.8, 'center');
            % --- 内侧：P 输入对 M1/M2（源接 P 在上，漏接 X/Y 在下）---
            m1 = obj.sym('M1', xIL, yIn, H, 'p', 'l');
            m2 = obj.sym('M2', xIR, yIn, H, 'p', 'r');
            gi1 = obj.gate(m1, -6, 0);  obj.regNet('VIN+', gi1(1), gi1(2), 'right');
            gi2 = obj.gate(m2, +6, 0);  obj.regNet('VIN-', gi2(1), gi2(2), 'left');
            obj.WV(xIL, m1.bot(2), yA);  obj.WV(xIR, m2.bot(2), yA);
            obj.WV(xIL, m1.top(2), yP);  obj.WV(xIR, m2.top(2), yP);
            % P 母线：横穿内侧两根输入管源极，并在中央接尾电流漏
            obj.WH(xIL, xIR, yP);  obj.nd(xC, yP);
            obj.regNet('P', xC+2.5, yP - 3.0, 'left');
            % --- 中央：P 尾电流 M9（源接 VDD，漏下到 P 母线）---
            m9 = obj.sym('M9', xC, yTl, H, 'p', 'l');
            g9 = obj.gate(m9, -6, 0);  obj.regNet('VB0', g9(1), g9(2), 'right');
            obj.WV(xC, m9.top(2), yVDD);  obj.WV(xC, m9.bot(2), yP);
            obj.regNet('VDD', xC+13, yVDD - 3.2, 'left');
            obj.regNet('GND', xC+4, yGND + 3.4, 'left');
        end

        function foldedOut(obj, xOL, xOR, yOut)
            % 折叠共栅的单/双端输出引出（net 恒为 OUTm 左 / OUTp 右）
            if obj.fd
                obj.WH(xOL, xOL-6, yOut);  obj.WH(xOR, xOR+6, yOut);
                obj.txt(xOL-7, yOut, 'V_{out+}', 'right', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
                obj.txt(xOR+7, yOut, 'V_{out-}', 'left', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
                obj.regNet('OUTm', xOL-7, yOut - 5.2, 'right');
            else
                obj.WH(xOR, xOR+6, yOut);
                obj.txt(xOR+7, yOut, 'V_{out}', 'left', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
            end
            obj.regNet('OUTp', xOR+7, yOut - 5.2, 'left');
        end

        function geomTelescopic(obj)
            H = 11;  xL = 32;  xR = 68;  xC = 50;
            if obj.pmosIn
                obj.geomTelescopic_pmos(H, xL, xR, xC);
            else
                obj.geomTelescopic_nmos(H, xL, xR, xC);
            end
        end

        function geomTelescopic_nmos(obj, H, xL, xR, xC)
            % NMOS 输入：P 电流源在上（源接 VDD）、P cascode、OUT、N cascode、
            % NMOS 输入对、NMOS 尾电流在下（源接 GND）。竖向层距均匀，两侧严格对齐。
            %   yTl/yGND 的取值要给接地符号留够空间：源极底(约 11.5) → 一段引线 → 三条横线，
            %   最低一条落在 y-6，故 yGND 不能低于 ~7（留 1 单位画布余量）。
            yVDD = 96;  yPS = 86;  yPC = 72;  yOut = 56;  yNC = 42;  yIn = 29;  yTl = 17;  yGND = 10;
            obj.rail(xL-6, xR+6, yVDD, 'V_{DD}');
            a1 = obj.sym('M8', xL, yPS, H, 'p', 'l');
            a2 = obj.sym('M9', xR, yPS, H, 'p', 'r');
            obj.WV(xL, a1.top(2), yVDD);  obj.WV(xR, a2.top(2), yVDD);
            g = obj.gate(a1, -7, 0);  obj.regNet('VB3', g(1), g(2), 'right');
            g = obj.gate(a2, +7, 0);  obj.regNet('VB3', g(1), g(2), 'left');
            b1 = obj.sym('M6', xL, yPC, H, 'p', 'l');
            b2 = obj.sym('M7', xR, yPC, H, 'p', 'r');
            obj.WV(xL, b1.top(2), a1.bot(2));  obj.WV(xR, b2.top(2), a2.bot(2));
            g = obj.gate(b1, -7, 0);  obj.regNet('VB2', g(1), g(2), 'right');
            g = obj.gate(b2, +7, 0);  obj.regNet('VB2', g(1), g(2), 'left');
            obj.nd(xL, yOut);  obj.nd(xR, yOut);
            obj.WV(xL, b1.bot(2), yOut);  obj.WV(xR, b2.bot(2), yOut);
            c1 = obj.sym('M3', xL, yNC, H, 'n', 'l');
            c2 = obj.sym('M4', xR, yNC, H, 'n', 'r');
            obj.WV(xL, c1.top(2), yOut);  obj.WV(xR, c2.top(2), yOut);
            g = obj.gate(c1, -7, 0);  obj.regNet('VB1', g(1), g(2), 'right');
            g = obj.gate(c2, +7, 0);  obj.regNet('VB1', g(1), g(2), 'left');
            d1 = obj.sym('M1', xL, yIn, H, 'n', 'l');
            d2 = obj.sym('M2', xR, yIn, H, 'n', 'r');
            obj.WV(xL, d1.top(2), c1.bot(2));  obj.WV(xR, d2.top(2), c2.bot(2));
            g = obj.gate(d1, -7, 0);  obj.regNet('VIN+', g(1), g(2), 'right');
            g = obj.gate(d2, +7, 0);  obj.regNet('VIN-', g(1), g(2), 'left');
            % --- P 节点母线（输入对源极公共点）---
            yMid = d1.bot(2);
            obj.WH(xL, xR, yMid);  obj.nd(xC, yMid);
            obj.regNet('P', xC+2.6, yMid - 3.0, 'left');
            % --- 尾电流 M5（源接 GND）---
            e1 = obj.sym('M5', xC, yTl, H, 'n', 'l');
            obj.WV(xC, e1.top(2), yMid);
            obj.WV(xC, e1.bot(2), yGND);
            obj.gnd(xC, yGND);
            g = obj.gate(e1, -7, 0);  obj.regNet('VB0', g(1), g(2), 'right');
            obj.outTel(xL, xR, yOut);
            obj.regNet('VDD', xL-6, yVDD + 3.4, 'right');
            obj.regNet('GND', xC+6, yGND - 3.0, 'left');
        end

        function geomTelescopic_pmos(obj, H, xL, xR, xC)
            % PMOS 输入（电学镜像）：PMOS 尾电流在上、PMOS 输入对、PMOS cascode、OUT、
            % NMOS cascode、NMOS 电流源在下（VDD 仍上、GND 仍下）
            %
            % 布局要点（修「画得不好看」）：
            %   ① 竖向分 7 层，层间距均匀（每层 13~14），两侧支路严格上下对齐；
            %   ② 底部 M8/M9 两条支路的源极先各自下探到同一 yGNDBus，
            %      再用一条横向 GND 母线连通，接地符号画在母线的中心 —— 不再悬空；
            %   ③ yGNDBus 抬高到 8，给接地符号的三条横线留出画布余量；
            %   ④ 尾电流 M5 的栅极引线单独向左侧引出（避免与 VDD 轨相撞）。
            yVDD = 96;  yGNDBus = 11;
            yTl = 87;  yIn = 73;  yPC = 59;  yOut = 45;  yNC = 31;  yPS = 18;
            obj.rail(xL-6, xR+6, yVDD, 'V_{DD}');
            % --- 尾电流 M5（P，源接 VDD，漏出 P 节点）---
            e1 = obj.sym('M5', xC, yTl, H, 'p', 'l');
            obj.WV(xC, e1.top(2), yVDD);
            g = obj.gate(e1, -7, 0);  obj.regNet('VB0', g(1), g(2), 'right');
            yMid = e1.bot(2);                                    % D 接 P（输入对源）
            % --- P 输入对 M1/M2（源接 P）---
            d1 = obj.sym('M1', xL, yIn, H, 'p', 'l');
            d2 = obj.sym('M2', xR, yIn, H, 'p', 'r');
            obj.WV(xL, d1.top(2), yMid);  obj.WV(xR, d2.top(2), yMid);
            obj.WH(xL, xR, yMid);  obj.nd(xC, yMid);             % P 节点母线
            obj.regNet('P', xC+2.6, yMid + 2.3, 'left');
            g = obj.gate(d1, -7, 0);  obj.regNet('VIN+', g(1), g(2), 'right');
            g = obj.gate(d2, +7, 0);  obj.regNet('VIN-', g(1), g(2), 'left');
            % --- P cascode M3/M4（源接输入对漏）---
            c1 = obj.sym('M3', xL, yPC, H, 'p', 'l');
            c2 = obj.sym('M4', xR, yPC, H, 'p', 'r');
            obj.WV(xL, c1.top(2), d1.bot(2));  obj.WV(xR, c2.top(2), d2.bot(2));
            g = obj.gate(c1, -7, 0);  obj.regNet('VB1', g(1), g(2), 'right');
            g = obj.gate(c2, +7, 0);  obj.regNet('VB1', g(1), g(2), 'left');
            % --- 输出节点 OUT（cascode 漏极）---
            obj.nd(xL, yOut);  obj.nd(xR, yOut);
            obj.WV(xL, c1.bot(2), yOut);  obj.WV(xR, c2.bot(2), yOut);
            % --- N cascode M6/M7（漏接 OUT）---
            b1 = obj.sym('M6', xL, yNC, H, 'n', 'l');
            b2 = obj.sym('M7', xR, yNC, H, 'n', 'r');
            obj.WV(xL, b1.top(2), yOut);  obj.WV(xR, b2.top(2), yOut);
            g = obj.gate(b1, -7, 0);  obj.regNet('VB2', g(1), g(2), 'right');
            g = obj.gate(b2, +7, 0);  obj.regNet('VB2', g(1), g(2), 'left');
            % --- N 电流源 M8/M9（漏接 N cascode，源接 GND）---
            a1 = obj.sym('M8', xL, yPS, H, 'n', 'l');
            a2 = obj.sym('M9', xR, yPS, H, 'n', 'r');
            obj.WV(xL, a1.top(2), b1.bot(2));  obj.WV(xR, a2.top(2), b2.bot(2));
            obj.WV(xL, a1.bot(2), yGNDBus);  obj.WV(xR, a2.bot(2), yGNDBus);
            obj.WH(xL, xR, yGNDBus);                             % ★ GND 横向母线（把两侧接地点连起来）
            obj.gnd(xC, yGNDBus);                                % ★ 接地符号落在母线中心
            g = obj.gate(a1, -7, 0);  obj.regNet('VB3', g(1), g(2), 'right');
            g = obj.gate(a2, +7, 0);  obj.regNet('VB3', g(1), g(2), 'left');
            obj.outTel(xL, xR, yOut);
            obj.regNet('VDD', xL-6, yVDD + 3.4, 'right');
            obj.regNet('GND', xR+6, yGNDBus - 3.0, 'left');
        end

        function outTel(obj, xL, xR, yOut)
            % 套筒式输出引出：net 恒为 OUTm（左）/ OUTp（右）
            if obj.fd
                obj.WH(xL, xL-8, yOut);  obj.WH(xR, xR+8, yOut);
                obj.txt(xL-9, yOut, 'V_{out+}', 'right', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
                obj.txt(xR+9, yOut, 'V_{out-}', 'left', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
                obj.regNet('OUTm', xL-9, yOut - 4.8, 'right');
            else
                obj.WH(xR, xR+8, yOut);
                obj.txt(xR+9, yOut, 'V_{out}', 'left', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
            end
            obj.regNet('OUTp', xR+9, yOut - 4.8, 'left');
        end

        function geomCS(obj)
            H = 14;
            if obj.fd, xs = [30 70]; else, xs = 50; end
            for i = 1:numel(xs)
                x = xs(i);
                if obj.fd && i == 1, sfx = '+'; else, sfx = ''; end
                if obj.fd && i == 2, sfx = '-'; end
                obj.csArm(x, H, sfx);
            end
        end

        function csArm(obj, x, H, sfx)
            if isempty(sfx) && obj.fd, sfx = '+'; end
            yVDD = 95;  yTop = 78;  yOut = 58;  yBot = 38;  yGND = 12;
            obj.rail(x-8, x+8, yVDD, 'V_{DD}');
            if obj.pmosIn
                % PMOS 输入：M1(P 共源管) 在上（S 接 VDD），M2(N 电流源负载) 在下（S 接 GND）
                tCS = obj.sym('M1', x, yTop, H, 'p', 'l');
                obj.WV(x, tCS.top(2), yVDD);                 % S 接 VDD
                g = obj.gate(tCS, -10, 0);  obj.regNet('VIN', g(1), g(2), 'right');
                tLd = obj.sym('M2', x, yBot, H, 'n', 'r');
                obj.WV(x, tLd.top(2), tCS.bot(2));  obj.nd(x, yOut);   % D 接 OUT
                obj.WV(x, tLd.bot(2), yGND);  obj.gnd(x, yGND);        % S 接 GND
                g = obj.gate(tLd, +8, 0);  obj.regNet('VB1', g(1), g(2), 'left');
            else
                % NMOS 输入：M2(P 负载) 在上（S 接 VDD），M1(N 共源管) 在下（S 接 GND）
                tLd = obj.sym('M2', x, yTop, H, 'p', 'r');
                obj.WV(x, tLd.top(2), yVDD);                 % S 接 VDD
                g = obj.gate(tLd, +8, 0);  obj.regNet('VB1', g(1), g(2), 'left');
                tCS = obj.sym('M1', x, yBot, H, 'n', 'l');
                obj.WV(x, tCS.top(2), tLd.bot(2));  obj.nd(x, yOut);   % D 接 OUT
                obj.WV(x, tCS.bot(2), yGND);  obj.gnd(x, yGND);        % S 接 GND
                g = obj.gate(tCS, -10, 0);  obj.regNet('VIN', g(1), g(2), 'right');
            end
            obj.regNet('OUT', x+16, yOut - 4.4, 'left');
            obj.txt(x+16, yOut, ['V_{out' sfx '}'], 'left', obj.FS_OUT, obj.C.BODY, 'normal', 'tex');
            obj.regNet('VDD', x-3, yVDD + 3.4, 'right');
            obj.regNet('GND', x+4, yGND + 3.4, 'left');
        end
    end
end
