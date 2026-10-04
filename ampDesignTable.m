function [cols, data] = ampDesignTable(res)
%AMPDESIGNTABLE  把求解结果整理成 uitable / csv 可直接用的表。
%
%   [cols, data] = ampDesignTable(res)
%
% cols : 1 x 16 cellstr 列名
% data : nDev x 16 cell，全部是字符串
%   器件 类型 角色 Id(uA) gm/ID L(um) VDS(V) Vgs(V) Vdsat(V) |VDS|act(V) 裕量(V)
%   fT(GHz) gm/gds W(um) 饱和 来源
%
% 兼容 MATLAB R2018b。

dev  = res.devices;
cols = {'器件','类型','角色','Id (uA)','gm/ID (1/V)','L (um)','VDS (V)','Vgs (V)', ...
        'Vdsat (V)','|VDS|act (V)','裕量 (V)','fT (GHz)','gm/gds','W (um)','饱和','来源'};
n = numel(dev);
data = cell(n, numel(cols));
for k = 1:n
    d = dev(k);
    if strcmp(d.source, 'data'), src = '数据';
    elseif strcmp(d.source, 'nodata'), src = '无数据';
    else, src = d.source; end
    if isfinite(d.fT), fTs = sprintf('%.4g', d.fT/1e9); else, fTs = '--'; end
    if isfinite(d.VDSact), va = sprintf('%.3f', d.VDSact); else, va = '--'; end
    if isfinite(d.margin), mg = sprintf('%+.3f', d.margin); else, mg = '--'; end
    data(k,:) = { d.name, d.type, d.role, ...
        sprintf('%.4g', d.Id*1e6), ...
        sprintf('%.3f', d.gmid), ...
        sprintf('%.3f', d.L*1e6), ...
        sprintf('%.3f', d.VDS), ...
        sprintf('%.3f', d.Vgs), ...
        sprintf('%.4f', d.Vdsat), ...
        va, mg, fTs, ...
        sprintf('%.2f', d.selfGain), ...
        sprintf('%.3f', d.W*1e6), ...
        d.sat, src };
end
end
