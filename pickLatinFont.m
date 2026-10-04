function f = pickLatinFont()
%PICKLATINFONT  拉丁字体（数字 / 英文 UI 用）。纯函数，R2018b 兼容。
%
%   f = pickLatinFont()
%     Windows → Segoe UI
%     CentOS7 → DejaVu Sans

f = pickFont({'Segoe UI', 'DejaVu Sans', 'Liberation Sans', ...
    'Arial', 'Helvetica', 'Tahoma', 'sans-serif'});
end
