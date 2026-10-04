# Auto-AmpDesigner-based-on-MATLAB-and-GM-ID-method
这是什么
gm/ID 交互设计器是一套纯 MATLAB 实现的运放设计工具。它不依赖任何 App Building 组件，
直接用你自己从 Spectre/Cadence 导出的 gm/ID 查表数据，在一个图形窗口里做可点选、实时反馈的
手把手设计：点原理图里的任意一个管子 → 在属性栏改它的 L / VDS / gm/ID → 图上立刻刷新 W、电流、
各节点电压与饱和裕量，并同步算出增益、输出摆幅和共模范围。
一句话概括它的定位：把"选工作点"和"算电路"这两件事分开——电流由拓扑自动分配，每管的 L / VDS /
gm/ID 由你自由指定，求解器负责把节点电压、饱和判定、增益、KCL 审计全部算出来。所有器件参数
（W / Vgs / Vdsat / fT / gm-gds）一律查 LUT，不用 µCox / Vth / gm-gds 解析模型糊弄。

What this is
The gm/ID Interactive Designer is a pure-MATLAB op-amp design tool. It uses your own
gm/ID lookup tables exported from Spectre/Cadence and gives you a clickable, real-time
hands-on design flow in a single figure window: click any transistor in the schematic,
edit its L / VDS / gm/ID in the property bar, and the drawing instantly refreshes the
width, current, every node voltage and saturation margin — while the gain, output swing
and input common-mode range are recomputed on the fly.
In one sentence: it separates "choosing an operating point" from "solving the circuit."
Branch currents are allocated automatically by the topology; each device's L / VDS / gm/ID
is yours to set freely; the solver derives node voltages, saturation, gain and a KCL audit.
Every device parameter (W / Vgs / Vdsat / fT / gm-gds) is looked up from the LUT — no
µCox / Vth / gm-gds analytical fudge.
