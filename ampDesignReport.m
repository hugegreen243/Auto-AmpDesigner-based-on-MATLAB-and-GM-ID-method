function lines = ampDesignReport(res, lutN, lutP, specs)
%AMPDESIGNREPORT  把自动设计结果写成可读文本（也用于 txt 导出）。
%
%   lines = ampDesignReport(res, lutN, lutP, specs)
%
% lines : 1 x N cellstr，每行一条；直接 fprintf('%s\n', lines{:}) 即可。
%
% 兼容 MATLAB R2018b。

if nargin < 2, lutN = []; end
if nargin < 3, lutP = []; end
if nargin < 4, specs = res.specs; end

L = {};
L{end+1} = '============================================================';
L{end+1} = ' 运放 gm/ID 自动设计结果';
L{end+1} = sprintf(' 生成时间 : %s', datestr(now, 'yyyy-mm-dd HH:MM:SS')); %#ok<DATST,TNOW1>
L{end+1} = sprintf(' 拓扑     : %s', res.topo.name);
L{end+1} = sprintf(' 说明     : %s', res.topo.desc);
if ~isempty(lutN)
    L{end+1} = sprintf(' NMOS 数据 : %s', lutN.prefix);
    L{end+1} = sprintf('            L=%.4g~%.4g m, VDS=%.3g~%.3g V, gm/ID 网格 %d 点', ...
        min(lutN.L), max(lutN.L), min(lutN.VDS), max(lutN.VDS), lutN.nGm);
end
if ~isempty(lutP)
    L{end+1} = sprintf(' PMOS 数据 : %s', lutP.prefix);
    L{end+1} = sprintf('            L=%.4g~%.4g m, VDS=%.3g~%.3g V, gm/ID 网格 %d 点', ...
        min(lutP.L), max(lutP.L), min(lutP.VDS), max(lutP.VDS), lutP.nGm);
end
L{end+1} = '============================================================';
L{end+1} = '';
L{end+1} = '--- 1. 设计指标 ---';
L{end+1} = sprintf('  GBW = %.6g Hz (%.6g MHz)', specs.GBW, specs.GBW/1e6);
L{end+1} = sprintf('  SR  = %.6g V/s (%.6g V/us)', specs.SR, specs.SR*1e-6);
L{end+1} = sprintf('  CL  = %.6g F  (%.6g pF)', specs.CL, specs.CL*1e12);
L{end+1} = sprintf('  ISS = %.6g A  (%.6g uA)', specs.ISS, specs.ISS*1e6);
if isfield(specs,'Av') && isfinite(specs.Av)
    L{end+1} = sprintf('  Av  = %.6g dB（指标）', specs.Av);
else
    L{end+1} = '  Av  = （无指标，增益是计算结果）';
end
L{end+1} = sprintf('  VDD = %.6g V', specs.VDD);
L{end+1} = '';
L{end+1} = '--- 2. 由指标推出的基本量 ---';
L{end+1} = sprintf('  gm1 = 2*pi*GBW*CL = %.6g S (%.6g uS)', res.gm1, res.gm1*1e6);
L{end+1} = sprintf('  Id1 = ISS/2      = %.6g A (%.6g uA)', res.idIn, res.idIn*1e6);
if isfinite(res.gmidInReq)
    L{end+1} = sprintf('  需要的 gm/ID    = gm1/Id1 = %.4f 1/V', res.gmidInReq);
else
    L{end+1} = '  需要的 gm/ID    = （无指标约束）';
end
L{end+1} = sprintf('  实际使用的 gm/ID          = %.4f 1/V', res.gmidInUsed);
L{end+1} = sprintf('  SR = ISS/CL      = %.6g V/us (指标 %.6g V/us)', res.sr*1e-6, res.srReq*1e-6);
L{end+1} = sprintf('  静态功耗 VDD*ISS = %.6g W (%.6g uW)', res.power, res.power*1e6);
L{end+1} = sprintf('  输入对择优目标   = %s', res.objectiveUsed);
L{end+1} = sprintf('  输入对选中工作点 = L=%.4g um, VDS=%.3g V, Id/W=%.5g A/m, Vgs=%.4g V, Vdsat=%.4g V, gm/gds=%.3f', ...
    res.inputSel.L*1e6, res.inputSel.VDS, res.inputSel.IdW, res.inputSel.Vgs, res.inputSel.Vdsat, res.inputSel.selfGain);
L{end+1} = '';
L{end+1} = '--- 3. 器件工作点、尺寸与饱和判定 ---';
L{end+1} = sprintf(['  %-5s %-3s %-12s %8s %7s %7s %7s %7s %8s %8s %8s %8s %7s %8s %6s %6s'], ...
    '器件','型','角色','Id(uA)','gm/ID','L(um)','VDS(V)','Vgs(V)','Vdsat(V)','|VDS|','裕量(V)','fT(GHz)','gm/gds','W(um)','饱和','来源');
cols = res.tableCols;                                       %#ok<NASGU>
for k = 1:size(res.tableData,1)
    r = res.tableData(k,:);
    L{end+1} = sprintf(['  %-5s %-3s %-12s %8s %7s %7s %7s %7s %8s %8s %8s %8s %7s %8s %6s %6s'], ...
        r{1}, r{2}, r{3}, r{4}, r{5}, r{6}, r{7}, r{8}, r{9}, r{10}, r{11}, r{12}, r{13}, r{14}, r{15}, r{16});
end
L{end+1} = '';
L{end+1} = '  饱和判据：|VDS|act - Vdsat >= 0.05 V 记“饱和”，0~0.05 V 记“临界”，<0 记“不饱和”。';
L{end+1} = '  节点电压：';
if isfield(res, 'nodes')
    for k = 1:numel(res.nodes)
        n = res.nodes(k);
        if isfinite(n.value)
            L{end+1} = sprintf('    %-6s = %+8.4f V   [%s]%s', n.name, n.value, n.kind, ...
                char(32*ones(1,0)));
        else
            L{end+1} = sprintf('    %-6s = 无法确定', n.name);
        end
        if ~isempty(n.msg)
            L{end+1} = sprintf('        ! %s', n.msg);
        end
    end
end
L{end+1} = '';
L{end+1} = '--- 4. 增益 / 摆幅 / 共模（Vdsat 口径估算）---';
L{end+1} = sprintf('  Rout  = %.6g ohm   (%s)', res.rout, res.gainNote);
if isfinite(res.avReqDb)
    L{end+1} = sprintf('  Av    = %.4g (%.2f dB)，指标 %.2f dB', res.av, res.avDb, res.avReqDb);
else
    L{end+1} = sprintf('  Av    = %.4g (%.2f dB)  ← 计算结果（无 Av 指标约束）', res.av, res.avDb);
end
L{end+1} = '  注：R_out 较小的那一侧主导增益；来源=无数据 的器件不参与该侧增益估算。';
L{end+1} = sprintf('  Vout  : %.4g V ~ %.4g V（摆幅 %.4g V）', res.voutMin, res.voutMax, res.voutSwing);
L{end+1} = sprintf('  Vcm   : >= %.4g V；上限估算 %.4g V（缺 Vth/PMOS 数据，仅供参考）', res.vcmMin, res.vcmMaxEst);
L{end+1} = '';
L{end+1} = '--- 5. 提示 ---';
if isempty(res.warnings)
    L{end+1} = '  （无）';
else
    for k = 1:numel(res.warnings)
        L{end+1} = sprintf('  * %s', res.warnings{k});
    end
end
L{end+1} = '';
L{end+1} = '--- 6. 拓扑备注 ---';
if isempty(res.topo.notes)
    L{end+1} = '  （无）';
else
    for k = 1:numel(res.topo.notes)
        L{end+1} = sprintf('  * %s', res.topo.notes{k});
    end
end
L{end+1} = '';
L{end+1} = '--- 7. Spectre 参数（可直接贴到 ADE / 网表）---';
for k = 1:numel(res.devices)
    d = res.devices(k);
    if isfinite(d.W)
        L{end+1} = sprintf('  parameters W%s=%.5gu L%s=%.5gu', ...
            d.name, d.W*1e6, d.name, d.L*1e6);
    else
        L{end+1} = sprintf('  parameters W%s=-- L%s=%.5gu   （无数据，无法定 W）', ...
            d.name, d.name, d.L*1e6);
    end
end
L{end+1} = '';
L{end+1} = '说明：W/L 以 um 为单位（后缀 u = 1e-6 m），直接对应 Spectre 的 parameters 写法。';
L{end+1} = '来源=无数据 的器件 W 显示为 --，请填入对应 N/P 数据路径后再重算。';
L{end+1} = '';

lines = L;
end
