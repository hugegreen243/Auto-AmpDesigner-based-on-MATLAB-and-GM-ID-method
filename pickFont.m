function f = pickFont(cands)
%PICKFONT  从候选字体里挑第一个本机确实存在的；都没有就返回第一个（总比空好）。
%
%   f = pickFont({'微软雅黑','Microsoft YaHei','DejaVu Sans'})
%
%   跨平台 + 跨语言：中文版 Windows 的 listfonts 返回「微软雅黑」而不是
%   "Microsoft YaHei"，所以候选里必须同时给中英文名，否则永远匹配不上。
%
%   注意：listfonts 返回的是 N×1 列 cell，候选是 1×M 行 cell，
%   直接 strcmpi 会因维度不一致报 catenate:dimensionMismatch，这里一律拉成行向量再比。
%
%   这是纯函数：无类、无 Java、无全局状态，R2018b 完全兼容。

if ischar(cands) || isstring(cands)
    cands = cellstr(cands);
end
cands = cands(:)';
f = cands{1};

avail = localFontList();
if isempty(avail), return; end
avail = avail(:)';
for k = 1:numel(cands)
    if isempty(cands{k}) || ~ischar(cands{k}), continue; end
    if any(strcmpi(avail, cands{k}))
        f = cands{k};
        return;
    end
end
end

%% ---------------------------------------------------------------
function list = localFontList()
%LOCALFONTLIST  本机可用字体族名（行向量 cellstr；失败则空）。带缓存。
persistent CACHE
if ~isempty(CACHE)
    list = CACHE;
    return;
end
list = {};
try
    raw = listfonts();
    if ischar(raw)
        list = {raw};
    elseif isstring(raw)
        list = cellstr(raw);
    elseif iscell(raw)
        list = raw(:)';
    end
catch
    list = {};
end
CACHE = list;
end
