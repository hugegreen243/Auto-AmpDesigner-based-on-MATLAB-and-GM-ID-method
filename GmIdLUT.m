classdef GmIdLUT < handle
%GMIDLUT  gm/ID 数据层：把 Cadence/Spectre 导出的分块 txt 读成三维插值 LUT。
%
% 支持的导出格式（格式 B，smic18bcd_gmIdData_nmos2v/*.txt）：
%     1/V   waveVsWave(?x "OS(\"/NM0\" \"gmoverid\")" ?y "OS(\"/NM0\" \"vgs\")") (V)
%
%     LEN = 5.00000e-07
%     VDS = 3.00000e-01
%      3.07646e+01       0.00000e+00
%      3.07118e+01       3.60000e-02
%      ...
%
% 每个 (LEN, VDS) 组合是一个 block；block 内第一列是 gm/ID [1/V]，
% 第二列是该文件对应的指标。于是建三维插值：
%
%     F(L, VDS, gm/ID) -> 指标
%
% 单位约定（与 Spectre 导出一致，不做隐式换算）：
%     L, VDS, Vgs, Vdsat : SI，米 / 伏
%     currentDensity     : id/WID，A/m；数值上 1 A/m == 1 uA/um
%     fug                : Hz
%     selfGain           : gm/gds，无量纲
%
% 为什么不需要知道 WID：导出表达式是 OS("/NM0" "id") / pv("top-level" "WID")，
% 而 WID 在 ADE 里是带单位的设计变量（pv 返回 SI 值，例如 1u -> 1e-6），
% 所以 id/WID 已经是真正的电流密度 [A/m]，与 WID 取多少无关（器件宽了电流同比变大）。
% 于是由目标电流求宽度：  W = Id / (Id/W)。
% sanityMuCox() 用方波近似反推隐含 µCox，用来交叉验证这一解读
% （smic18bcd NMOS 在 L=0.5um 处应给出约 200 uA/V^2 这种量级）。
%
% 用法：
%     lut = GmIdLUT('D:\myprj\prj_data\smic18bcd_gmIdData_nmos2v', ...
%                   'smic18bcd_gmIdData_nmos2v');
%     q = lut.lookup(0.5e-6, 0.4, 12);       % -> Id/W, Vgs, Vdsat, fT, gm/gds
%     W = 10e-6 / q.IdW;                     % 目标 Id = 10 uA 时的宽度
%
% 兼容 MATLAB R2018b：不用 string、不用隐式扩展、只依赖 base MATLAB。

    %% ---------------- 常量 ----------------
    properties (Constant)
        % 文件后缀 / 内部字段名 / 显示名 / 单位 / 是否按 log10 建 LUT
        FILESUFFIX  = {'currentDensity','vgs','overdrive','transientFreq','selfGain'};
        METRICKEY   = {'currentDensity','vgs','vdsat','fug','selfGain'};
        METRICLABEL = {'I_D/W (电流密度)','V_GS','V_DSAT','f_T','gm/gds'};
        METRICUNIT  = {'A/m  (= uA/um)','V','V','Hz','-'};
        METRICLOG   = [true false false false false];
        DEFAULT_NGM = 400;
    end

    %% ---------------- 只读属性 ----------------
    properties (SetAccess = private)
        dataDir      = '';
        prefix       = '';
        L            = [];        % nL x 1，升序，单位 m
        VDS          = [];        % nV x 1，升序，单位 V
        gmGrid       = [];        % 1 x nG，公共 gm/ID 网格，单位 1/V
        grid         = struct();  % 指标 -> nL x nV x nG
        F            = struct();  % 指标 -> griddedInterpolant
        valRange     = struct();  % 指标 -> [min max]（原始数据范围）
        gmidRange    = [NaN NaN]; % 全部指标公共 gm/ID 范围
        nL           = 0;
        nVDS         = 0;
        nGm          = 0;
        blockCount   = 0;
        filledSlices = 0;         % 插值补齐的缺失 (L,VDS) 切片数
        isBuilt      = false;
        buildSeconds = 0;
        log          = {};        % 构建过程的提示信息
    end

    properties (Access = private)
        fillMissingFlag = true;
    end

    %% ---------------- 构造与构建 ----------------
    methods
        function obj = GmIdLUT(dataDir, prefix, varargin)
            %GMIDLUT 构造并立即解析 + 建 LUT。
            %   名字值参数：'N_gm'（公共 gm/ID 网格点数，默认 400）
            %               'Verbose'（默认 false）
            if nargin < 1 || isempty(dataDir)
                dataDir = fullfile(fileparts(mfilename('fullpath')), ...
                    'smic18bcd_gmIdData_nmos2v');
            end
            if nargin < 2 || isempty(prefix)
                prefix = 'smic18bcd_gmIdData_nmos2v';
            end
            opt.N_gm    = obj.DEFAULT_NGM;
            opt.Verbose = false;
            opt.FillMissing = true;      % 缺失 (L,VDS) 切片用邻点插值补齐
            opt = GmIdLUT.parseOpt(opt, varargin{:});

            obj.dataDir = dataDir;
            obj.prefix  = prefix;
            obj.nGm     = opt.N_gm;
            obj.fillMissingFlag = opt.FillMissing;

            t0 = tic;
            obj.loadBlocks();
            obj.buildLUT();
            obj.buildSeconds = toc(t0);
            obj.isBuilt = true;

            if opt.Verbose
                fprintf('%s\n', obj.summary());
            end
        end

        function i = metricIndex(obj, name)
            i = find(strcmp(obj.METRICKEY, name), 1);
            if isempty(i)
                error('GmIdLUT:badMetric', '未知指标: %s', name);
            end
        end

        function s = metricLabel(obj, name)
            s = obj.METRICLABEL{obj.metricIndex(name)};
        end

        function s = metricUnit(obj, name)
            s = obj.METRICUNIT{obj.metricIndex(name)};
        end
    end

    %% ---------------- 解析 txt ----------------
    methods (Access = private)
        function loadBlocks(obj)
            n = numel(obj.METRICKEY);
            allBlocks = cell(1, n);

            % ---- 1) 先把 5 个文件都解析出来 ----
            for k = 1:n
                fname = sprintf('%s_%s.txt', obj.prefix, obj.FILESUFFIX{k});
                fpath = fullfile(obj.dataDir, fname);
                if exist(fpath, 'file') ~= 2
                    error('GmIdLUT:missingFile', '缺少数据文件: %s', fpath);
                end
                allBlocks{k} = GmIdLUT.parseBlocks(fpath);
                if isempty(allBlocks{k})
                    error('GmIdLUT:emptyFile', '文件里没有解析到数据块: %s', fpath);
                end
            end

            % ---- 2) 汇总 (L, VDS) 网格（取所有文件的并集）----
            Lall = []; VDSall = []; nblk = 0;
            for k = 1:n
                Lall   = [Lall,   [allBlocks{k}.L]];   %#ok<AGROW>
                VDSall = [VDSall, [allBlocks{k}.VDS]]; %#ok<AGROW>
                nblk   = nblk + numel(allBlocks{k});
            end
            obj.L    = unique(Lall(:));
            obj.VDS  = unique(VDSall(:));
            obj.nL   = numel(obj.L);
            obj.nVDS = numel(obj.VDS);
            if obj.nL == 0 || obj.nVDS == 0
                error('GmIdLUT:noBlocks', '没有解析到任何 (LEN, VDS) 数据块。');
            end
            obj.blockCount = nblk;

            % ---- 3) 公共 gm/ID 范围：所有指标所有 block 的交集 ----
            gLo = -inf; gHi = inf;
            for k = 1:n
                for b = 1:numel(allBlocks{k})
                    g = allBlocks{k}(b).g;
                    if numel(g) >= 2
                        gLo = max(gLo, min(g));
                        gHi = min(gHi, max(g));
                    end
                end
            end
            if ~isfinite(gLo) || ~isfinite(gHi) || gLo >= gHi
                error('GmIdLUT:badRange', '各数据块的 gm/ID 范围没有公共交集。');
            end
            obj.gmidRange = [gLo, gHi];
            obj.gmGrid    = linspace(gLo, gHi, obj.nGm);

            % ---- 4) 每个指标逐 block 插值到公共网格 ----
            nNan = zeros(1, n);
            for k = 1:n
                arr  = nan(obj.nL, obj.nVDS, obj.nGm);
                vmin = inf; vmax = -inf;
                for b = 1:numel(allBlocks{k})
                    blk = allBlocks{k}(b);
                    iL  = GmIdLUT.matchIndex(obj.L,   blk.L);
                    iV  = GmIdLUT.matchIndex(obj.VDS, blk.VDS);
                    if isempty(iL) || isempty(iV)
                        obj.log{end+1} = sprintf('%s: 无法定位 block (L=%g, VDS=%g)', ...
                            obj.FILESUFFIX{k}, blk.L, blk.VDS); %#ok<AGROW>
                        continue;
                    end
                    g = blk.g(:);  y = blk.y(:);
                    if numel(g) < 2, continue; end
                    [g, ia] = unique(g);             % 去重 + 升序
                    y = y(ia);
                    if obj.METRICLOG(k)
                        if any(y <= 0)
                            keep = y > 0;
                            g = g(keep); y = y(keep);
                        end
                        if numel(g) < 2, continue; end
                        yy = log10(y);
                    else
                        yy = y;
                    end
                    tmp = nan(1, obj.nGm);
                    inR = obj.gmGrid >= g(1) & obj.gmGrid <= g(end);
                    tmp(inR) = interp1(g, yy, obj.gmGrid(inR), 'pchip');
                    arr(iL, iV, :) = reshape(tmp, 1, 1, obj.nGm);
                    vmin = min(vmin, min(y));
                    vmax = max(vmax, max(y));
                end
                if ~isfinite(vmin)
                    error('GmIdLUT:emptyMetric', '指标 %s 没有任何有效数据。', obj.METRICKEY{k});
                end
                if obj.fillMissingFlag
                    arr = obj.fillMissingSlices(obj.METRICKEY{k}, arr);
                end
                obj.valRange.(obj.METRICKEY{k}) = [vmin vmax];
                nNan(k) = sum(isnan(arr(:)));
                obj.grid.(obj.METRICKEY{k}) = arr;
            end

            obj.log{end+1} = sprintf(['解析 %d 个 block；L=%d 点 (%.4g~%.4g m)，' ...
                'VDS=%d 点 (%.3g~%.3g V)，gm/ID 公共网格 %d 点 [%.3f, %.3f] 1/V'], ...
                nblk, obj.nL, min(obj.L), max(obj.L), obj.nVDS, ...
                min(obj.VDS), max(obj.VDS), obj.nGm, obj.gmidRange(1), obj.gmidRange(2));
            for k = 1:n
                if nNan(k) > 0
                    obj.log{end+1} = sprintf('提示：%s 有 %d/%d 个网格点无数据，查询会返回 NaN。', ...
                        obj.METRICKEY{k}, nNan(k), numel(obj.grid.(obj.METRICKEY{k}))); %#ok<AGROW>
                end
            end
        end

        function buildLUT(obj)
            % L/VDS/gm-ID 三个方向都用 'linear'；gm/ID 方向的 pchip 已烘焙进网格。
            for k = 1:numel(obj.METRICKEY)
                obj.refreshInterp(obj.METRICKEY{k});
            end
        end

        function refreshInterp(obj, name)
            arr = obj.grid.(name);
            F = griddedInterpolant({obj.L, obj.VDS, obj.gmGrid}, arr, 'linear');
            try
                F.ExtrapolationMethod = 'none';   % 范围外返回 NaN，禁止外推
            catch
                obj.log{end+1} = '本版本不支持 ExtrapolationMethod=none，改用查询侧范围掩码兜底。';
            end
            obj.F.(name) = F;
        end

        function arr = fillMissingSlices(obj, name, arr)
            %FILLMISSINGSLICES 某个 (L,VDS) 切片整片没有数据时，用邻点线性插值补齐。
            % 你的数据里 L=0.6um / VDS=0.8V 这一角在 5 个文件里都缺失，
            % 不补齐的话 griddedInterpolant 会在该点附近返回 NaN。
            % 规则：优先在“能把目标点夹在中间”的方向插值（避免外推），
            %       两个方向都夹不住（边界洞）时退化为最近切片复制，并在日志里标明。
            for iL = 1:obj.nL
                for iV = 1:obj.nVDS
                    if ~all(isnan(reshape(arr(iL, iV, :), 1, obj.nGm)))
                        continue;
                    end

                    idxV = [];
                    for j = 1:obj.nVDS
                        if ~all(isnan(reshape(arr(iL, j, :), 1, obj.nGm)))
                            idxV(end+1) = j; %#ok<AGROW>
                        end
                    end
                    idxL = [];
                    for j = 1:obj.nL
                        if ~all(isnan(reshape(arr(j, iV, :), 1, obj.nGm)))
                            idxL(end+1) = j; %#ok<AGROW>
                        end
                    end

                    filled = false; how = '';
                    if numel(idxV) >= 2 && obj.VDS(iV) > min(obj.VDS(idxV)) && ...
                            obj.VDS(iV) < max(obj.VDS(idxV))
                        Y = reshape(arr(iL, idxV, :), numel(idxV), obj.nGm);
                        v = interp1(obj.VDS(idxV), Y, obj.VDS(iV), 'linear');
                        if ~any(isnan(v))
                            arr(iL, iV, :) = reshape(v, 1, 1, obj.nGm);
                            filled = true;
                            how = sprintf('沿 VDS 线性插值 (%.2f~%.2f V)', ...
                                min(obj.VDS(idxV)), max(obj.VDS(idxV)));
                        end
                    end
                    if ~filled && numel(idxL) >= 2 && obj.L(iL) > min(obj.L(idxL)) && ...
                            obj.L(iL) < max(obj.L(idxL))
                        Y = reshape(arr(idxL, iV, :), numel(idxL), obj.nGm);
                        v = interp1(obj.L(idxL), Y, obj.L(iL), 'linear');
                        if ~any(isnan(v))
                            arr(iL, iV, :) = reshape(v, 1, 1, obj.nGm);
                            filled = true;
                            how = sprintf('沿 L 线性插值 (%.2f~%.2f um)', ...
                                min(obj.L(idxL))*1e6, max(obj.L(idxL))*1e6);
                        end
                    end
                    if ~filled && ~isempty(idxV)
                        [~, jj] = min(abs(obj.VDS(idxV) - obj.VDS(iV)));
                        arr(iL, iV, :) = arr(iL, idxV(jj), :);
                        filled = true;
                        how = sprintf('用最近切片 VDS=%.2fV 复制（边界洞，非插值）', obj.VDS(idxV(jj)));
                    elseif ~filled && ~isempty(idxL)
                        [~, jj] = min(abs(obj.L(idxL) - obj.L(iL)));
                        arr(iL, iV, :) = arr(idxL(jj), iV, :);
                        filled = true;
                        how = sprintf('用最近切片 L=%.3fum 复制（边界洞，非插值）', ...
                            obj.L(idxL(jj))*1e6);
                    end

                    if filled
                        obj.filledSlices = obj.filledSlices + 1;
                        obj.log{end+1} = sprintf(['%s: 缺失 (L=%.3fum, VDS=%.2fV) 整片数据，' ...
                            '已%s 补齐（该点本来没有仿真数据，只为插值连续性）。'], ...
                            name, obj.L(iL)*1e6, obj.VDS(iV), how);
                    else
                        obj.log{end+1} = sprintf(['%s: 缺失 (L=%.3fum, VDS=%.2fV) 且邻点不足，' ...
                            '无法补齐，该区域查询会返回 NaN。'], name, obj.L(iL)*1e6, obj.VDS(iV));
                    end
                end
            end
        end
    end

    %% ---------------- 查询 ----------------
    methods
        function q = lookup(obj, Lq, VDSq, gmidq)
            %LOOKUP 三维查询。输入可为标量或同尺寸数组。
            % 返回结构体（字段均与输入同尺寸）：
            %   valid     是否落在数据范围内且五个指标都有效
            %   IdW       id/W，A/m（数值上等于 uA/um）
            %   Vgs, Vdsat [V]，fT [Hz]，selfGain [gm/gds]
            if ~obj.isBuilt
                error('GmIdLUT:notBuilt', 'LUT 尚未构建完成。');
            end
            if nargin < 4
                error('GmIdLUT:needArgs', '用法: q = lut.lookup(L, VDS, gmID)');
            end
            sz = size(gmidq);
            if isscalar(Lq),   Lq   = repmat(Lq,   sz); end
            if isscalar(VDSq), VDSq = repmat(VDSq, sz); end
            Lq   = Lq   + zeros(sz);
            VDSq = VDSq + zeros(sz);
            gm   = gmidq + zeros(sz);

            inR = (Lq   >= min(obj.L))       & (Lq   <= max(obj.L))       & ...
                  (VDSq >= min(obj.VDS))     & (VDSq <= max(obj.VDS))     & ...
                  (gm   >= obj.gmidRange(1)) & (gm   <= obj.gmidRange(2));

            q = struct();
            q.valid    = false(sz);
            q.gmID     = gm;
            q.IdW      = nan(sz);
            q.Vgs      = nan(sz);
            q.Vdsat    = nan(sz);
            q.fT       = nan(sz);
            q.selfGain = nan(sz);

            if ~any(inR(:))
                return;
            end

            Li = Lq(inR); Vi = VDSq(inR); Gi = gm(inR);
            v = obj.F.currentDensity(Li, Vi, Gi);
            if obj.METRICLOG(1), v = 10.^v; end
            q.IdW(inR)      = v;
            q.Vgs(inR)      = obj.F.vgs(Li, Vi, Gi);
            q.Vdsat(inR)    = obj.F.vdsat(Li, Vi, Gi);
            q.fT(inR)       = obj.F.fug(Li, Vi, Gi);
            q.selfGain(inR) = obj.F.selfGain(Li, Vi, Gi);

            q.valid = inR & isfinite(q.IdW) & q.IdW > 0 & ...
                      isfinite(q.Vgs) & isfinite(q.Vdsat) & ...
                      isfinite(q.fT)  & isfinite(q.selfGain);
        end

        function w = widthFor(obj, Id, L, VDS, gmID)
            %WIDTHFOR 由目标电流求器件宽度（m）。超出数据范围返回 NaN。
            q = obj.lookup(L, VDS, gmID);
            w = nan(size(q.IdW));
            ok = q.valid & (q.IdW > 0);
            w(ok) = Id(ok) ./ q.IdW(ok);
        end

        function out = scan(obj, gmID, varargin)
            %SCAN 在整个 (L, VDS) 网格上扫描某个 gm/ID，返回展平后的候选表。
            opt.ValidOnly = true;
            opt = GmIdLUT.parseOpt(opt, varargin{:});
            [LL, VV] = meshgrid(obj.L, obj.VDS);          % nV x nL
            n = numel(LL);
            q = obj.lookup(LL(:), VV(:), gmID*ones(n,1));
            out = struct();
            out.L        = LL(:);
            out.VDS      = VV(:);
            out.gmID     = gmID*ones(n,1);
            out.valid    = q.valid;
            out.IdW      = q.IdW;
            out.Vgs      = q.Vgs;
            out.Vdsat    = q.Vdsat;
            out.fT       = q.fT;
            out.selfGain = q.selfGain;
            if opt.ValidOnly
                keep = out.valid;
                fn = fieldnames(out);
                for k = 1:numel(fn)
                    f = out.(fn{k});
                    if isnumeric(f) || islogical(f)
                        out.(fn{k}) = f(keep);
                    end
                end
            end
        end

        function mu = muCoxEstimate(obj, Lq, VDSq, gmidq)
            %MUCOXESTIMATE 方波近似反推隐含 µCox [A/V^2]（用来交叉验证数据解读）。
            %   Id/W = (µCox/2) * Vov^2 / L,  Vov ≈ 2/(gm/ID)
            if nargin < 2 || isempty(Lq),   Lq   = min(obj.L);   end
            if nargin < 3 || isempty(VDSq), VDSq = min(obj.VDS); end
            if nargin < 4 || isempty(gmidq), gmidq = 5;          end
            q = obj.lookup(Lq, VDSq, gmidq);
            Vov = 2 ./ q.gmID;
            mu = 2 .* q.IdW .* Lq ./ (Vov.^2);
            mu(~q.valid) = NaN;
        end

        function s = sanityMuCox(obj)
            %SANITYMUCOX 在若干 (L, VDS, gm/ID) 点上反推 µCox 并打印。
            s = '';
            Ls = unique([min(obj.L), 0.5e-6, 1e-6, min(max(obj.L), 2e-6)]);
            Ls = Ls(Ls >= min(obj.L) & Ls <= max(obj.L));
            Vs = unique([min(obj.VDS), 0.5, max(obj.VDS)]);
            Vs = Vs(Vs >= min(obj.VDS) & Vs <= max(obj.VDS));
            gs = [2 5 10];
            for a = 1:numel(Ls)
                for b = 1:numel(Vs)
                    for c = 1:numel(gs)
                        q = obj.lookup(Ls(a), Vs(b), gs(c));
                        if ~q.valid, continue; end
                        mu = obj.muCoxEstimate(Ls(a), Vs(b), gs(c));
                        s = sprintf(['%s  L=%.2fum VDS=%.2fV gm/ID=%.1f  ->  ' ...
                            'Id/W=%.4g A/m, Vdsat=%.3fV, Vgs=%.3fV, gm/gds=%.2f, µCox≈%.1f uA/V^2\n'], ...
                            s, Ls(a)*1e6, Vs(b), gs(c), q.IdW, q.Vdsat, q.Vgs, ...
                            q.selfGain, mu*1e6);
                    end
                end
            end
            if nargout == 0
                fprintf('%s', s);
            end
        end

        function s = summary(obj)
            s = sprintf(['GmIdLUT: %s\n' ...
                '  数据目录 : %s\n' ...
                '  L        : %d 点, %.4g ~ %.4g m\n' ...
                '  VDS      : %d 点, %.4g ~ %.4g V\n' ...
                '  gm/ID    : %d 点公共网格, %.3f ~ %.3f 1/V\n' ...
                '  数据块   : %d 个, 构建耗时 %.2f s\n'], ...
                obj.prefix, obj.dataDir, obj.nL, min(obj.L), max(obj.L), ...
                obj.nVDS, min(obj.VDS), max(obj.VDS), obj.nGm, ...
                obj.gmidRange(1), obj.gmidRange(2), obj.blockCount, obj.buildSeconds);
        end

        function saveCache(obj, matPath)
            %SAVECACHE 存成 mat，避免每次重新解析 ~2.6 万行文本。
            lut = obj; %#ok<NASGU>
            save(matPath, 'lut', '-v7');
        end
    end

    methods (Static)
        function obj = loadCache(matPath)
            %LOADCACHE 从 saveCache 生成的 mat 恢复。
            S = load(matPath, 'lut');
            obj = S.lut;
        end
    end

    %% ---------------- 静态工具 ----------------
    methods (Static, Access = private)
        function blocks = parseBlocks(filePath)
            fid = fopen(filePath, 'r');
            if fid < 0
                error('GmIdLUT:openFailed', '无法打开文件: %s', filePath);
            end
            cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>

            blocks = struct('L', {}, 'VDS', {}, 'g', {}, 'y', {});
            curL = NaN; curV = NaN; curG = []; curY = [];
            have = false;

            while true
                line = fgetl(fid);
                if ~ischar(line), break; end
                if isempty(strtrim(line)), continue; end

                % --- 新 block：LEN = <单值> ---
                tokL = regexp(line, '^\s*LEN\s*=\s*([+\-\d\.eE]+)', 'tokens', 'once');
                if ~isempty(tokL)
                    if have
                        blocks(end+1) = struct('L', curL, 'VDS', curV, ...
                            'g', curG, 'y', curY); %#ok<AGROW>
                    end
                    curL = str2double(tokL{1}); curV = NaN; curG = []; curY = [];
                    have = true;
                    continue;
                end

                % --- 格式 A 的 LEN 行（一个 LEN 后跟多个 L，无 '='）给出明确错误 ---
                tokA = regexp(line, '^\s*LEN\s+([+\-\d\.eE\s]+)$', 'tokens', 'once');
                if ~isempty(tokA) && numel(sscanf(tokA{1}, '%f')) > 1
                    error('GmIdLUT:formatA', ...
                        ['这是另一种导出格式（单个 LEN 行带多个 L、无 VDS 块）：\n  %s\n' ...
                         '本工具当前只支持 "LEN = <单值>" + "VDS = <单值>" 的分块格式。'], ...
                        filePath);
                end

                % --- VDS = <单值> ---
                tokV = regexp(line, '^\s*VDS\s*=\s*([+\-\d\.eE]+)', 'tokens', 'once');
                if ~isempty(tokV)
                    curV = str2double(tokV{1});
                    continue;
                end

                % --- 数据行 ---
                if have && ~isnan(curL) && ~isnan(curV)
                    nums = sscanf(strtrim(line), '%f');
                    if numel(nums) >= 2
                        curG(end+1,1) = nums(1); %#ok<AGROW>
                        curY(end+1,1) = nums(2); %#ok<AGROW>
                    end
                end
            end

            if have
                blocks(end+1) = struct('L', curL, 'VDS', curV, 'g', curG, 'y', curY);
            end
        end

        function i = matchIndex(vec, val)
            i = find(abs(vec - val) < max(1e-15, abs(val)*1e-9), 1);
        end

        function opt = parseOpt(opt, varargin)
            %PARSEOPT 极简名字值对解析。
            if mod(numel(varargin), 2) ~= 0
                error('GmIdLUT:badArgs', '名字值参数必须成对出现。');
            end
            for k = 1:2:numel(varargin)
                name = varargin{k};
                if ~ischar(name) || ~isfield(opt, name)
                    error('GmIdLUT:badOpt', '未知选项: %s', num2str(name));
                end
                opt.(name) = varargin{k+1};
            end
        end
    end
end
