function c = pickMonoFont(cjkFallback)
%PICKMONOFONT  挑一个本机存在、且「带 CJK 字形」的等宽字体（数值框/读数用）。
%
%   c = pickMonoFont()            % 找不到等宽时退回 'Consolas'
%   c = pickMonoFont(cjkFont)     % 找不到等宽时退回给定的 CJK 字体
%
%   为什么要这个函数：
%     Consolas / Courier New 这类「纯拉丁等宽」字体**没有中日韩字形**。
%     一旦把含中文的字符串（如 '裕量=+0.1V 饱和'）套到 Consolas 上，
%     MATLAB 只能用缺字方块 □ 顶上 —— 这就是界面上出现方块乱码的根因。
%     所以含中文的读数一律走本函数返回的「等宽 + 带 CJK」字体；
%     只有在确实全是数字/拉丁时才允许退到 Consolas。
%
%   ★ 但即便本机没有任何「等宽 + CJK」字体，也绝不能用 Consolas 去渲染中文。
%     所以这里分两步：
%       1) 先找「等宽 + CJK」；找到就用；
%       2) 找不到 → 退回 cjkFallback（CJK 字体，牺牲等宽换「不出方块」）。
%
%   Windows 中文版常见等宽 CJK：等距更纱黑体 / Sarasa Mono SC / Cascadia Mono(部分无 CJK)。
%   CentOS 7：文泉驿等宽正黑 / WenQuanYi Zen Hei Mono。
%
%   纯函数，R2018b 兼容，不依赖任何类/Java。

if nargin < 1, cjkFallback = 'Microsoft YaHei'; end

% ① 明确「等宽 + 带 CJK」的字体（存在即最佳）。注意别把 Consolas 放进来抢位。
mono = pickFont({ ...
    'Sarasa Mono SC', '更纱黑体 Mono SC', 'Sarasa Term SC', ...
    'Noto Sans Mono CJK SC', 'Noto Sans Mono SC', ...
    'WenQuanYi Zen Hei Mono', '文泉驿等宽正黑', ...
    'Microsoft YaHei Mono'});

% pickFont 找不到会把「第一个候选」原样返回 —— 用它做存在性判定：
%   若返回值仍等于第一个候选，说明本机没有这个字体（listfonts 里没匹配到）。
probe = pickFont({'Sarasa Mono SC'});
if ~strcmpi(mono, probe)
    c = mono;                      % 命中真正的等宽 CJK
    return;
end

% ② 没有任何等宽 CJK → 用 CJK 字体兜底（会不耐看，但保证不出方块）
if ~isempty(cjkFallback) && ischar(cjkFallback)
    c = cjkFallback;
else
    c = 'Consolas';
end
end
