classdef GmIdData < handle
%GMIDDATA  数据层小顶层：扫描数据源、加载 LUT、查询工作点。
%
% 上层（电路层 / 界面层）只调用这个类，不直接用 GmIdLUT / gmidDataSources。
%
%   D = GmIdData();            % 扫描
%   D.list()                   % 打印可用数据源
%   ok = D.load(1);            % 按索引加载（ok=false = 格式不支持）
%   q  = D.query(L, VDS, gmID) % IdW/Vgs/Vdsat/fT/selfGain
%   [L, V, g] = D.axesInfo()   % 数据点与 gm/ID 范围（给下拉/滑块用）
%
% 兼容 MATLAB R2018b。

    properties (SetAccess = private)
        src  = [];      % gmidDataSources 结果
        lut  = [];      % GmIdLUT
        idx  = 0;       % 当前数据源索引
    end

    methods
        function obj = GmIdData(rootDir)
            if nargin < 1, rootDir = ''; end
            obj.scan(rootDir);
        end

        function n = scan(obj, rootDir)
            if nargin < 2 || isempty(rootDir)
                rootDir = fileparts(mfilename('fullpath'));
                if isempty(rootDir), rootDir = pwd; end
            end
            obj.src = gmidDataSources(rootDir);
            obj.idx = 0;
            obj.lut = [];
            n = numel(obj.src);
        end

        function printList(obj)
            fprintf('[数据源] 共 %d 个\n', numel(obj.src));
            for k = 1:numel(obj.src)
                fprintf('  %d) %-52s fmt=%s ok=%d\n', k, obj.src(k).label, obj.src(k).fmt, obj.src(k).ok);
            end
        end

        function labels = sourceLabels(obj)
            labels = cell(1, numel(obj.src));
            for k = 1:numel(obj.src), labels{k} = obj.src(k).label; end
        end

        function ok = load(obj, idx)
            %LOAD 加载第 idx 个数据源。返回 false 表示格式不支持或没有该索引。
            ok = false;
            if numel(idx) ~= 1 || idx < 1 || idx > numel(obj.src), return; end
            s = obj.src(idx);
            if ~s.ok, return; end
            obj.lut = GmIdLUT(s.dataDir, s.prefix);
            obj.idx = idx;
            ok = true;
        end

        function ok = loadDir(obj, dataDir, prefix)
            %LOADDIR 直接按给定目录 + 前缀加载 LUT（供顶层 N/P 双路径使用，不走扫描）。
            %   prefix 省略时取目录名作为前缀（约定目录名 == 文件前缀）。
            %   返回 false 表示目录里没有完整的 5 个指标文件，或格式不支持。
            ok = false;
            if nargin < 2 || isempty(dataDir), return; end
            if exist(dataDir, 'dir') ~= 7, return; end
            if nargin < 3 || isempty(prefix)
                [~, prefix] = fileparts(dataDir);
            end
            if exist(fullfile(dataDir, [prefix '_currentDensity.txt']), 'file') ~= 2
                return;
            end
            try
                obj.lut = GmIdLUT(dataDir, prefix);
            catch ME %#ok<NASGU>
                obj.lut = [];
                return;
            end
            obj.idx = 0;
            ok = true;
        end

        function s = source(obj, idx)
            if nargin < 2, idx = obj.idx; end
            s = [];
            if idx >= 1 && idx <= numel(obj.src), s = obj.src(idx); end
        end

        function tf = isLoaded(obj), tf = ~isempty(obj.lut); end

        function [L, VDS, gmidRange] = axesInfo(obj)
            if isempty(obj.lut), L = []; VDS = []; gmidRange = [NaN NaN]; return; end
            L = obj.lut.L;  VDS = obj.lut.VDS;  gmidRange = obj.lut.gmidRange;
        end

        function q = query(obj, L, VDS, gmID)
            if isempty(obj.lut)
                error('GmIdData:notLoaded', '还没有加载数据源。');
            end
            q = obj.lut.lookup(L, VDS, gmID);
        end

        function [v, unit] = metric(obj, name, L, VDS, gmID)
            %METRIC 单指标查询（name 见 GmIdLUT.METRICKEY）
            q = obj.query(L, VDS, gmID);
            switch name
                case 'currentDensity', v = q.IdW;
                case 'vgs',            v = q.Vgs;
                case 'vdsat',          v = q.Vdsat;
                case 'fug',            v = q.fT;
                case 'selfGain',       v = q.selfGain;
                otherwise, error('GmIdData:badMetric', '未知指标 %s', name);
            end
            unit = obj.lut.metricUnit(name);
        end

        function w = width(obj, Id, L, VDS, gmID)
            %WIDTH 由目标电流求宽度 [m]
            q = obj.query(L, VDS, gmID);
            w = nan(size(q.IdW));
            ok = q.valid & q.IdW > 0;
            w(ok) = Id(ok) ./ q.IdW(ok);
        end

        function mu = muCox(obj, L, VDS, gmID)
            mu = obj.lut.muCoxEstimate(L, VDS, gmID);
        end

        function r = range(obj, field)
            %RANGE 数据范围：'L' | 'VDS' | 'gmid'
            switch lower(field)
                case 'l',    r = [min(obj.lut.L), max(obj.lut.L)];
                case 'vds',  r = [min(obj.lut.VDS), max(obj.lut.VDS)];
                case 'gmid', r = obj.lut.gmidRange;
                otherwise, error('GmIdData:badRange', '未知范围 %s', field);
            end
        end

        function nm = sourceName(obj)
            s = obj.source();
            if isempty(s), nm = '(未加载)'; else, nm = s.prefix; end
        end

        function s = summary(obj)
            if isempty(obj.lut), s = 'GmIdData: 未加载数据源'; return; end
            s = obj.lut.summary();
        end
    end
end
