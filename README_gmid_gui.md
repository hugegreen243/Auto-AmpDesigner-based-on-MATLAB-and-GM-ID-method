# gm/ID 交互设计器（MATLAB）

用你自己的 Spectre/Cadence gm/ID 数据，在一个图形窗口里做**手把手、可点选、实时反馈**的
gm/ID 设计：点原理图里的任意管子 → 在下方属性栏改参数 → 图上立刻显示新的 W / Id / 各节点电压 /
饱和裕量，同时算出增益。

```matlab
cd('D:\myprj\prj_data')
ui = AmpDesigner();          % 打开窗口（自动探测并加载 NMOS/PMOS 数据路径）
```

---

## 1. 界面结构

```
┌──────────────────────── (1) 设计指标：GBW / SR / ISS / CL / VDD（无 Av）────────────────────────┐
├───────────────┬──────────────────────────────────────────────────────────────────────────────┤
│ (2) 数据源     │  原理图页签（点器件选中） │ gm/ID 曲线 │ gm/ID 曲面 │ 设计结果      │
│ (3) 拓扑与形式 │  ┌──────────────────────────────────────────────────────────────────────┐  │
│ (4) 状态与告警 │  │  拓扑原理图：每管标 gm/ID、W、Id；每个 net 标电压；选中管=重色管名+高亮框 │  │
│               │  └──────────────────────────────────────────────────────────────────────┘  │
│               │  选中器件的参数 / Device：L ▾  VDS  gm/ID  gm(µS)（全部查 LUT，无手填模型）      │
│               │  读数：Id  W  Vgs  Vdsat  gm/gds  fT | |VDS|act 裕量 饱和判定 gm          │
├───────────────┴──────────────────────────────────────────────────────────────────────────────┤
│              初始化 / Init     计算 / Compute     导出 / Export     清空 / Clear │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 三种核心交互

1. **图上点选**：鼠标点原理图里的任何一个 MOS（点空白处取消选中），选中的管子画高亮框，
   下方属性栏立刻回填它的 `L / VDS / gm-ID / gm` 与全部读数（`Id, W, Vgs, Vdsat, gm/gds, fT`、
   `|VDS|act`、饱和裕量、来源）。
2. **实时改参数**：改 `L`（下拉，来自数据里的 L 点）、`VDS`、`gm/ID` 中任意一个并回车 →
   电路层立刻重解 → 图上标注、属性栏读数、曲线工作点、结果表同步更新。
   改 **`gm`** 会把总电流锚 `Iss` 反推过来（`Iss = gm / (gmID · idFactor)`），因为
   **每条支路的电流是由拓扑自动分配的**，`gm` 不能独立给。
3. **锚 + 初始化**：顶部 `ISS` 是唯一的电流锚；点「初始化」按钮会按指标
   （`GBW/CL → gm1`、`ISS → Id1`、`gm/ID = gm1/Id1`）给每管选一个起点，并给每管一个
   **默认 VDS**（互相独立、可逐管自定义）。初始化**不再**按层均分节点电压，也**不保证**
   自洽或全饱和——节点电压由 GND=0 V 逐管推出，超 VDD 的 net 会标红提示。
   `Av` 不是指标，它是**计算结果**。

### 三个图形页签

| 页签 | 内容 | 交互 |
|---|---|---|
| **原理图** | 4 种拓扑的器件图，每管标 gm/ID·W·Id，每 net 标电压 | 点器件选中 → 属性栏改参数 |
| **gm/ID 曲线** | 某指标 vs gm/ID 的 L 曲线族（VDS 由下拉独立选，不绑定管子） | 点图吸附到最近 (gm/ID, L)，回填选中管；未选中则标探查点 |
| **gm/ID 曲面** | 3D：Z=指标、X=gm/ID、Y=L（VDS 由下拉独立选，不绑定管子） | 点曲面吸附到最近 (gm/ID, L)，回填选中管；未选中则标探查点 |

曲线/曲面页签的坐标轴**固定到数据范围**（X=gm/ID 公共网格、Y=指标 valRange / L 范围），
缩放/平移后不会「找不到线或面」。两个页签顶部各有一个 **VDS 下拉**，独立决定切片，不再跟随
选中管——没选中任何管子也能自由看曲线/曲面。点图吸附到最近的 `(gm/ID, L)`：选中了管子就写回该管
并重解；没选中就更新**探查点**（红星），在说明栏显示该点 `Id/W、Vgs、Vdsat、fT、gm/gds` 完整读数，
不改任何器件。

---

## 2. 分层结构（一层一个小顶层，最后被大顶层调用）

| 层 | 文件 | 职责（小顶层接口） |
|---|---|---|
| 大顶层 | `AmpDesigner.m` | 装配各层、绑定全部回调、调度（唯一入口 `ui = AmpDesigner()`） |
| 字体探测 | `pickCjkFont.m` / `pickLatinFont.m` / `pickMonoFont.m` / `pickFont.m` | 纯函数：从 `listfonts()` 里挑本机真实存在的 CJK / 拉丁 / 「等宽+CJK」字体（跨 Windows/CentOS7），保证中文不出方块 |
| 面板层 | `GmIdPanel.m` | 所有控件与布局（像素重排，原生 `uicontrol`）；`readSpecs / refreshProp / refreshTable / log / showTab` |
| 图层 | `GmIdSchematic.m` | 画 4 个拓扑（N/P 输入、单端/全差分）、注册器件热区与 net 位置、图上标注、命中测试 |
| 面板层(图表) | `GmIdPanel.m` + `AmpDesigner.m` | 曲线页签（`onMetric`）与曲面页签（`onSurf`）的绘制与点选在 `AmpDesigner.m` 里 |
| 电路层 | `GmIdCircuit.m` | 电路状态 + 求解器：电流分配、KCL 审计、节点电压（GND 锚点逐管推）、饱和判定、增益、超压检测 |
| 初始化层 | `GmIdInit.m` | 由指标给每管选点（L / VDS / gmID），不含增益计算 |
| 拓扑层 | `GmIdTopology.m` | 4 个拓扑的器件表（端子 D/S/G、电流比例 idFactor、选点策略；`vdsDrivers/vdsFollower` 已停用、仅留作历史标注） |
| 数据层 | `GmIdData.m` | N/P 双数据源：按路径加载 LUT、查询（内部用 `GmIdLUT.m` + `gmidDataSources.m`） |
| 结果输出 | `ampDesignTable.m` / `ampDesignReport.m` | 16 列结果表（含饱和判定）与文本报告 |

依赖方向是单向的：`大顶层 → 面板/图层 → 电路层 → 拓扑层/数据层`，下层不反过来调上层。
状态放在各层的 handle 对象里（`ui.P.circ` / `ui.P.res`），不靠 struct 传递。

---

## 3. 求解口径（`GmIdCircuit.solve`）

设总电流锚为 `Iss`，拓扑给每管的电流系数 `idFactor`：

| 量 | 算法 |
|---|---|
| 支路电流 | `Id(i) = idFactor(i) * Iss`（**由拓扑自动分配**，KCL 恒成立） |
| 跨导 | `gm(i) = gmID(i) * Id(i)` |
| Id/W, Vgs, Vdsat, fT, selfGain | 有数据的管子查 LUT（`(L, VDS, gmID)` 三维插值）；没数据的管子（对应 N/P 路径未填）标「无数据」，W/Vgs/Vdsat/selfGain 为 NaN |
| 宽度 | `W(i) = Id(i) / (Id/W)` |
| 节点电压 | **唯一锚点 GND = 0 V**。每条边满足 `V(高) - V(低) = |VDS|`（NMOS 高=漏、PMOS 高=源），从 GND 出发 BFS 双向传播，把每个 net 推出来。**没有权威链、没有 VDS 自洽**：每管 VDS 都是用户自由输入，工具不自动分配/回填任何 VDS。某条边 VDS 未填（NaN）→ 该方向传不过去、下游 net 显示「—」；栅极 net 由 `Vg = Vs ± Vgs` 反推（源极已定时） |
| 超压 / 负压 | net 电压 `> specs.VDD` 或 `< 0` → 该 net **标红**并写入告警（照常显示，不阻断）；多条边推出同一 net 的不同值也标红（不一致） |
| 饱和判定 | `裕量 = 工作点 VDS - Vdsat`（**用查表实际用的 VDS，即用户输入**）：`≥0.05 V` 记**饱和**，`0~0.05` 记**临界**，`<0` 记**不饱和**（VDS 超出数据范围时，Vdsat 取最近 VDS 点的值并提示） |
| 增益 | `Av = gm_in · (Rout_N ∥ Rout_P)`；有 cascode 时 `R = ro_cas(1+gm_cas·ro_base)+ro_base`，`ro = selfGain/gm`；`gm_in` 是输入对（或共源级）的跨导 |
| 摆幅/共模 | 下限/上限 = 各叠管 `Vdsat` 之和；`Vcm` 下限 = `Vgs(in)+Vdsat(tail)`，上限 ≈ `VDD - |Vgs|`(上侧电流源) |
| 供电电流/功耗 | `Iss_total = Σ(源端接 VDD 的管子电流)`，`P = VDD·Iss_total` |

> 注意：`Id/W` 来自数据里的 `currentDensity`（ADE 变量 WID 单位是米，所以这个值本身就是 A/m）。
> 因此 **WID 不需要知道**，`W = Id / (Id/W)` 直接成立（实测隐含 µCox ≈ 200 µA/V²，合理）。

---

## 4. 数据要求

- 支持**格式 B**：每个文件里 `LEN = <单个 L>` + `VDS = <单个 VDS>` + 两列数据
  `gm/ID <TAB> 指标`（对应 5 个指标文件：`currentDensity / vgs / vdsat / transientFreq / selfGain`）。
- **不支持格式 A**：一行 `LEN` 里含多个 L、且没有 `VDS` 块的 tsmc `waveVsWave` 家族表
  （`GmIdData.printList` 会标 `fmt=A ok=0`，界面会提示，不会静默出错）。
- 数据源区有 **NMOS / PMOS 两个路径框**：各自填入对应类型的 gm/ID 数据目录（格式 B），点
  「加载 N/P」分别加载。点「自动探测」会扫描工作目录，把可加载的 NMOS/PMOS 目录自动填进去。
- 当前工作区可用数据：`smic18bcd_gmIdData_nmos2v`（NMOS）—— L = 16 点（0.5~2.0 µm）、
  VDS = 6 点（0.3~0.8 V）、gm/ID 公共网格 400 点（0.788~30.758 1/V），共 475 个数据块。
- **PMOS 数据路径目前为空**：PMOS 器件（以及 PMOS 输入的输入对/尾管）会标「无数据」，
  结果表 `来源` 列显示 `无数据`，`W/Vgs/Vdsat/selfGain` 留空。填入 PMOS 格式 B 数据后即自动查表。

---

## 5. 文件清单

> **运行时最小集 = 下面前 6 行，共 15 个 `.m`**。测试与出图脚本、设计稿已挪到 `backup/`
> 的子目录里（`tests_and_renders/`、`design_artifacts/`），上传时不必带；想验证就拷回根目录。

| 文件 | 说明 |
|---|---|
| `AmpDesigner.m` | 大顶层（入口），跑这个启动界面 |
| `pickFont.m` / `pickCjkFont.m` / `pickLatinFont.m` / `pickMonoFont.m` | 字体探测纯函数（跨平台，防中文方块） |
| `GmIdPanel.m` / `GmIdSchematic.m` / `GmIdCircuit.m` / `GmIdInit.m` / `GmIdTopology.m` / `GmIdData.m` | 各自一层 |
| `GmIdLUT.m` / `gmidDataSources.m` | 数据层内部实现（解析 txt、建三维插值、扫描数据源） |
| `ampDesignTable.m` / `ampDesignReport.m` | 结果表（16 列）与文本报告 |
| `README_gmid_gui.md` | 本文件 |
| `smic18bcd_gmIdData_nmos2v/`、`smic18bcd_gmIdData_pmos2v/` | 当前可加载的两套 gm/ID 数据（格式 B），工具运行时读它们 |
| `tsmc18rf_gmIdData_nmos2v/`、`tsmc18rf_gmIdData_pmos2v/` | TSMC 数据（格式 A，暂不支持加载；扫描时会列出但标「不可加载」） |
| `out/` | 测试日志 / LUT 缓存 / 导出截图（运行不需要） |
| `backup/` | 被替代的旧脚本 + `tests_and_renders/` + `design_artifacts/`（含 `README_backup.md`），**不要加回 path** |

（下表为已挪到 `backup/tests_and_renders/` 的自检脚本，仅供回归时参考）

| 文件 | 说明 |
|---|---|
| `test_gmid_core.m` | 核心层自检 86 项（数据/拓扑/求解器/初始化/饱和/**GND 唯一锚点逐管推电压**/**超压标红**/**自由管 VDS 各自独立**/两种输入对/**拓扑镜像一致性**） |
| `test_gmid_draw.m` | 图层自检 89 项（4 拓扑 × N/P，器件点选命中、**符号类型与拓扑一致**、net 标注、选中高亮、图元不越界、**标注不叠字**、选中不增文字） |
| `test_gmid_ui.m` | 界面自检 59 项（装配、自动探测加载、点选、改参数、按钮、切拓扑、四页签、字体防方块、三种窗口尺寸） |
| `test_gmid_surf.m` | 曲面页签自检 27 项（页签/曲面对象/工作点标记/独立 VDS 切片/换指标重画/点击吸附/无选中探查/换拓扑/布局） |
| `render_core_schematics.m` | 导出 9 张带标注的原理图（4 拓扑 × N/P + 1 张选中样式）→ `out\core_schematics\` |
| `render_ui.m` | 导出一整套界面截图 → `out\ui\`（含曲面页签） |

### 兼容性（R2018b / CentOS 7）

本版本**只用传统图形句柄**（`figure` / `axes` / `uicontrol` / `uipanel` / `uitable` / `line` / `text` / `patch`），
**完全不使用 App Building 组件**，因此可跑在 MATLAB R2018b（CentOS 7）上：

- `uifigure` / `uigridlayout` / `uibutton` / `uidropdown` / `uieditfield` / `uitextarea` / `uitabgroup` /
  `uiaxes` / `uilabel` 一律不用。其中 **`uigridlayout` 是 R2019a 才引入**，R2018b 根本没有。
- **Windows 上 `uiaxes` 的图形栈堆管理不稳，实测会触发 `0xc0000374`（Heap corruption）让 MATLAB 整体闪退**；
  改回传统 `axes` 后该风险消除（`-softwareopengl` 也无法规避，说明不是纯驱动问题）。
- 原理图图元（`text`/`line`/`patch`）走**对象池复用**：刷新只 `set` 属性、多余的置 `Visible='off'`，
  不做高频 `delete` + 重建 —— 这是另一个堆损坏诱因，已消除。
- 导出用 `print('-dpng')`（`exportgraphics` 是 R2020a+，不可用）。
- 字体按 `listfonts()` 实际存在的名字解析（中文版 Windows 返回的是本地化名 `微软雅黑`，
  而非 `Microsoft YaHei`；CentOS 上通常是 `文泉驿/Noto Sans CJK`），候选表覆盖中英文名。

### 跑测试

```matlab
cd('D:\myprj\prj_data')
test_gmid_core      % 看 out\test_core_log.txt  末行 TEST_RESULT: PASS
test_gmid_draw      % 看 out\test_draw_log.txt
test_gmid_ui        % 看 out\test_ui_log.txt
test_gmid_surf      % 看 out\test_surf_log.txt
render_core_schematics; render_ui
```

命令行：`matlab -batch "test_gmid_core; test_gmid_draw; test_gmid_ui; test_gmid_surf"`。
四个测试都带「中断保护」：运行中断不会被误报成 PASS。

### 脚本化入口（不点鼠标也能选点）

`AmpDesigner()` 返回的 `ui` 上挂了几个句柄，方便命令行/自动化驱动：

```matlab
ui = AmpDesigner();
ui.pickSurf(8, 2.0)     % 把【选中管】吸附到最近的 (gm/ID=8, L=2.0um) 数据点并重解
ui.pickCurve(8, 0.5)    % 曲线页吸附（第二个参数是当前指标的 y 值）
ui.redrawSurf();        % 只重画曲面
```

---

## 6. 单位与约定

- 数据里 `gm/ID` 单位 1/V，`VDS/Vgs/Vdsat` 单位 V，`Id/W` 单位 A/m（= µA/µm）。
- 界面输入：`GBW` MHz、`SR` V/µs、`ISS` µA、`CL` pF、`VDD` V；`gm` µS。无任何手填模型参数。
- MOS 符号：NMOS 箭头**朝外**、PMOS 箭头**朝里**，颜色分蓝/橙（与器件标号一致）。
- **PMOS 输入的原理图布局**：VDD 恒在上、GND 恒在下；**行结构整体上下颠倒**（不做整体翻转，
  否则 VDD/GND 会反）。5T / 共源级 / 套筒式 / 折叠共栅都各有独立的 N、PMOS 几何函数
  （`geom5T_*` / `csArm` / `geomTelescopic_*` / `geomFolded_*`），**PMOS 版把每只管画成与
  拓扑表 `type` 一致的类型**（NMOS 蓝箭头朝外、PMOS 橙箭头朝里）。
  ⚠️ 历史教训：折叠共栅一度只有单一布局、只翻输入对/尾管，导致「图纸没镜像、电学镜像了」，
  表现为 PMOS 版里 M5/M6、M10/M11 的位置与类型全反。现已拆成两套几何，并用
  `test_gmid_draw` 的「符号类型与拓扑一致」断言永久守住。
- **VDS 与节点电压（已取消权威链 / VDS 自洽）**：每管 VDS 都是**用户自由输入**，改了就生效，
  工具**不自动分配、不回填**任何 VDS。节点电压只认一个锚点 **GND = 0 V**，其余 net 从 0 V
  沿各管 VDS 双向传播推出来；**VDD 不再预设**，它也是推出来的，与 `specs.VDD` 比较即可看出裕量。
  · 某条边 VDS 未填（NaN）→ 下游 net 显示「—」，不报错；
  · net `> VDD` 或 `< 0`，或同一 net 被多条边推出不同值 → 标红 + 告警（照常显示）。
  **饱和判据用「查表实际用的工作点 VDS」（= 用户输入）**，不再用节点反推值，避免用一个
  该管并未工作在其上的 VDS 去判饱和而误报。
  ⚠️ 历史教训（已连根拔掉）：FC 的 M5/M6 曾被 `vdsDrivers/vdsFollower` 权威链硬拉回节点推导值，
  表现为「改了没反应 / 爆不饱和错」。现在 `vdsDrivers` / `vdsFollower` / `GmIdCircuit.syncVDS` /
  `allocateBias` / `authFlags` **全部停用**（`vdsDrivers/vdsFollower` 字段保留但不再被求解器读取）。
- **全差分（fd）**：5T 的负载管 M3/M4 栅极接外部偏置 `VB`（不做二极管电流镜，VB 由 Vgs 反推），
  输出两路 Vout+/Vout-（net 为 X / OUT）。套筒式/折叠共栅的 cascode/电流源栅本来就走 VB。
- 节点命名：`X/Y` 折叠或镜像内部节点、`P` 输入对源极、`OUTm/OUTp` 输出、
  `Q/R` 折叠支路内部节点、`VB0~VB4` 偏置、`VIN±` 输入、`VDD/GND` 电源轨。

### 6.1 图上文字排版（GmIdSchematic）

原理图上的标注按「离画布中缝越远越安全」排布，字号与偏移集中在类属性里，改一处即可整体缩放：

| 属性 | 含义 | 当前值 |
|------|------|--------|
| `FS_DEV` | 器件标注（管名 gm/ID、W/Id…） | 12.5 |
| `FS_SEL` | 选中管管名行（加粗高亮） | 13.5 |
| `FS_NET` | net 节点电压标注 | 14 |
| `FS_RAIL`/`FS_OUT` | VDD/GND 轨标签 / Vout 标签 | 15 / 14 |
| `DX` / `DY` | 标注水平偏移 / 行距 | 2.5 / 3.15 |
| `FS_NET2` | 节点标注撞车时的降级字号 | 12 |

**选中管的显示口径**：选中后图上**只**把管名行改成强调色加粗 + 画一个器件高亮框，
**不再**在管旁展开 5 行参数（L/Vgs、Vdsat/gm-gds、|VDS| 饱和判定等）。
那些详情一律只在下方「选中器件参数」面板里看——避免原理图被一大坨文字盖住。
高亮框半宽取 `0.70*H`：刚好包住 MOS 符号（栅极引线最远 0.68*H），
又不会越过标注锚点 `0.55*H + DX`，防止蓝框竖切过管名文字。

两条硬约束（改动后必须重测）：

1. **凡可能显示中文的控件，字体必须含 CJK 字形**。
   - 图上标注（`（无数据）`、`饱和`、`临界`）、面板静态文字、页签、**结果表 `uitable`**、
     含中文的读数行 → 一律用 `pickCjkFont()`（`P.FCN`）。
   - **纯拉丁等宽字体（Consolas / Courier）绝对不能套到含中文的字符串上**，
     否则中文会显示成方块 □（这是本项目曾踩过的坑）。数值框/读数若想要等宽，
     用 `pickMonoFont()`：它优先挑「等宽 + 带 CJK」的字体，找不到就退回 CJK 字体
     （宁可不等宽，也绝不出方块）。
   - 结果表 `uitable` 必须用 CJK 字体：MATLAB 的 Java 表格渲染不对中文做 font-linking，
     用 Segoe UI 会导致**表头正常、单元格却全是方块**。
2. **文字必须走 `Interpreter='none'`**（`txt()` 的默认值）。器件参数含 `u`（微米）与 `--`，
   若走 TeX 解释器，`u` 会被吃成 `\mu`、`--` 会变连字符。只有带下标的花体标签
   （`V_{out}`、`V_{DD}`）才显式传 `'tex'`。

标注左右方向由**器件 x 坐标**决定（`x<50` 标左侧、`x>=50` 标右侧），
不使用 `idx.dev.side` —— 该字段描述栅极朝向（如 M4 在 x=68 却记为 `'l'`），与本处排布方向无关。
选中管与常驻标注**共用同一套几何与避让**（都 2 行），不再单独外推。

**接地符号（GND）**：先从接线端起**向下拉一段竖线（lead）**，再在最下端画三条依次减短的横线
（半宽 3.5 → 2.5 → 1.5，行距 1.5），这是教科书标准画法。
本工程 VDD 恒在上、GND 恒在下（`mirror` 永远为 false），所以接地符号一律朝下，不用 `sgn` 翻转。
套筒式 PMOS 的底部两条支路（M8/M9）先各自下探到同一 `yGNDBus`，
再用一条**横向 GND 母线**连通、接地符号落在母线中心——否则接地符号会悬空连不上。

---

## 7. 已知限制

1. 只有 NMOS 数据 → PMOS 器件标「无数据」，其 W/Vgs/Vdsat/selfGain 为 NaN，增益只用有数据的一侧
   输出电阻估算（结果表 `来源` 会标 `无数据`）。填入 PMOS 格式 B 数据后即恢复正常。
2. 数据没有 `Vth`，所以 `Vcm` 上限只是粗略估算（且 PMOS 无数据时该估算为 NaN）。
3. 三维曲面页签提供「某指标 Z vs gm/ID(X) vs L(Y)」的 VDS 切片（VDS 由下拉独立选，不绑定管子），
   坐标轴固定到数据范围；曲面上标出各数据管工作点，点曲面可吸附选点；曲线页签同理提供
   「某指标 vs gm/ID」的 L 曲线族 + 各管工作点标注。
4. 单级结构在 `GBW=10 MHz / CL=2 pF / ISS=20 µA` 下 Av ≈ 24.6 dB（5T）~ 49.9 dB（套筒式），
   60 dB 需要多级或加增益提升（工具会把不合理的期望反映成数字，不硬凑）。
5. 套筒式/折叠共栅的堆叠层数多，`VDS` 均分后每管 ~0.36 V；如果自己把某管 VDS 改大，
   工具会直接报「不饱和/冲突」，这正是想要的行为。

---

## 8. 想扩展时改哪里

- **加拓扑**：在 `GmIdTopology.m` 里加一个 `case`，给出器件表（含 `D/S/G` 端子与 `idFactor`）、
  `vdsDrivers`/`vdsFollower`、以及增益/摆幅用的角色名；再在 `GmIdSchematic` 里加一个
  `geomXXX()` 几何（注册器件与 net 位置），其余全部自动生效（求解、饱和、标注、点选、结果表）。
  ⚠️ **角色名（`role`）禁止内嵌 N/P 前缀**（不要写 `'PMOS cascode'` / `'NMOS 电流源'`）：
  应统一成类型无关的 `'cascode'` / `'电流源'` / `'电流沉'`，N/P 侧由 `dev.type` 区分。
  因为 PMOS 输入版是**电学镜像**（`type` 整体互换），若角色名带 N/P，
  镜像后 `GmIdCircuit` 按 `role` 字符串匹配（`roOf`/`branchR`/`roleVdsat`/`solveHeadroom`）
  会匹到反侧器件，导致「图纸变了、但管子功能/ID 全乱」。同理
  `voutMinStack`/`voutMaxStack` 也只能引用类型无关的角色名。
- **加数据源**：把格式 B 的 5 个指标文件放进 `*_gmIdData_<类型>*` 目录即可，「自动探测」会发现并
  填入对应 N/P 路径框；也可以直接在路径框里手动填任意目录路径。
- **无解析模型**：所有器件参数一律查 LUT，没有 `source='model'` 分支。想给没有数据的类型兜底，
  在 `GmIdCircuit.deviceSolution()` 的 `nodata` 分支里加你自己的算法即可。
