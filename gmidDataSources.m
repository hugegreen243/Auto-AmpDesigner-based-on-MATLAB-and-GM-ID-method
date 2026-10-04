function src = gmidDataSources(rootDir)
%GMIDDATASOURCES  扫描工作目录下可用的 gm/ID 数据源（工艺 / NMOS / PMOS）。
%
%   src = gmidDataSources()              % 默认扫描本文件所在目录
%   src = gmidDataSources(rootDir)
%
% 约定：一个数据源 = 一个名为 <prefix> 的目录，里面有 5 个文件
%       <prefix>_currentDensity.txt / _vgs.txt / _overdrive.txt /
%       _transientFreq.txt / _selfGain.txt
%   （就是 Spectre 导出的那 5 个 txt）。
%
% 返回结构体数组，字段：
%   label    下拉框显示名，例如 'smic18bcd_gmIdData_nmos2v  [NMOS, 可加载]'
%   dataDir  数据目录全路径
%   prefix   文件前缀（= 目录名）
%   type     'nmos' | 'pmos' | 'unknown'
%   fmt      'B' = "LEN = <单值>" + "VDS = <单值>" 分块格式（本工具支持）
%            'A' = 一个 LEN 行带多个 L 的 waveVsWave 族表（暂不支持）
%            '?' = 认不出来
%   ok       逻辑，是否可直接加载
%
% 兼容 MATLAB R2018b。

if nargin < 1 || isempty(rootDir) || exist(rootDir, 'dir') ~= 7
    rootDir = fileparts(mfilename('fullpath'));
    if isempty(rootDir), rootDir = pwd; end
end

src = struct('label', {}, 'dataDir', {}, 'prefix', {}, 'type', {}, 'fmt', {}, 'ok', {});

d = dir(fullfile(rootDir, '*_gmIdData_*'));
for k = 1:numel(d)
    if ~d(k).isdir
        continue;
    end
    folder = d(k).name;
    fpath  = fullfile(rootDir, folder, [folder '_currentDensity.txt']);
    if exist(fpath, 'file') ~= 2
        continue;                        % 不是完整的一套，跳过
    end
    fmt = detectFormat(fpath);
    low = lower(folder);
    if ~isempty(strfind(low, 'pmos'))       %#ok<STREMP>
        ty = 'pmos';
    elseif ~isempty(strfind(low, 'nmos'))   %#ok<STREMP>
        ty = 'nmos';
    else
        ty = 'unknown';
    end
    switch fmt
        case 'B', tick = '可加载';
        case 'A', tick = '格式A，暂不支持';
        otherwise, tick = '格式未知';
    end
    src(end+1) = struct( ...                                  %#ok<AGROW>
        'label',   sprintf('%s  [%s, %s]', folder, upper(ty), tick), ...
        'dataDir', fullfile(rootDir, folder), ...
        'prefix',  folder, ...
        'type',    ty, ...
        'fmt',     fmt, ...
        'ok',      strcmp(fmt, 'B'));
end

% 可加载的排前面
if ~isempty(src)
    [~, idx] = sort(~[src.ok]);
    src = src(idx);
end
end

% ---------------------------------------------------------------- 辅助
function fmt = detectFormat(fpath)
% 看开头若干行判断是哪种导出格式：
%   格式 B:  "LEN = 5.00000e-07"      + "VDS = 3.00000e-01" 之后跟两列数据
%   格式 A:  "LEN  5e-7  7e-7  ..."   （一个 LEN 带多个 L，没有 VDS）
fmt = '?';
fid = fopen(fpath, 'r');
if fid < 0, return; end
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
n = 0;
while ~feof(fid) && n < 40
    line = fgetl(fid);
    if ~ischar(line), break; end
    n = n + 1;
    if ~isempty(regexp(line, '^\s*LEN\s*=', 'once'))
        fmt = 'B';
        return;
    end
    tok = regexp(line, '^\s*LEN\s+([+\-\d\.eE\s]+)$', 'tokens', 'once');
    if ~isempty(tok) && numel(sscanf(tok{1}, '%f')) > 1
        fmt = 'A';
        return;
    end
end
end
