# 02 后端集成审计

## 【结论】
基线 HEAD `b284df7`，源码树摘要 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`；未把未提交 Markdown 当代码。实质问题 **P0×4、P1×2**，均为当前存量、未修；“新发现”指本次独立定位，不声称历史首报。本域未运行仿真/构建；f0 另有外部定向证据。

## 【变更】
仅新建本报告；产品、测试、golden 均未改。

## 【证据】
### 02-1 P0：f0 目的写被抑制（已确认静态，另域已复现）
[backend_top:780](<../../../rtl/back2/backend_top.v#L780>) 把 `fp_we` 也与 `drd!=0` 相与；随后 rename 请求、PRF 写和提交使能均沿用该位（925–926、1687、1937–1941）。`flw/fmv.w.x/fadd.s f0,…` 不分配、不更新 f0，后续消费者读旧值。FP 的 f0 不是 x0。
测试漏测：[p4:40–77](<../../../sim/unit/prog/back2_p4_fpu.S#L40-L77>) 目的避开 f0；锁步虽已能记录 f0（[TB:538](<../../../sim/unit/tb_back2_lockstep.sv#L538>)），无激励仍无效。最小验证：写 f0 后 `fmv.x.w`；同指令改 f1 为反向控制。独立结果见[定向证据](<validation/decode-fp0/results.md#L12-L23>)；本域未重跑。

### 02-2 P0：回滚后同组 dst mask 残留（已确认静态，新定位）
[rename:495–520](<../../../rtl/back2/rename.v#L495-L520>) 仅在组基进入时清 mask，否则旧 mask OR 新目的位；[restore:945–965](<../../../rtl/back2/rename.v#L945-L965>) 不清被杀年轻位。
触发：idx0 分支后，错路 idx1 写目的；回滚 idx0；正确路径 idx1 为 nop、idx2 为第二分支。复用 idx1 不触发组初始化，旧 mask[1]=1 留存，但增量 bank 被 nop 的 arn/pd 覆写（995–1010）。再次回滚 idx2，703–714 多计一次 free-head，739–744 错应用 nop 增量，甚至把 x0 映射成空闲物理号；造成错值/泄漏/重复分配。
最小验证：上述两次 squash，逐步核对 RAT 与 free-list 集合；控制组令两代 idx1 都写目的。现有四份主测无该序列的逐项 oracle；IPC 不含分支，IQ 单测不含 rename。

### 02-3 P0：环绕后组快照覆盖仍存活老分支（已确认静态，新定位）
同样的[组初始化](<../../../rtl/back2/rename.v#L495-L520>)及[写入:981–984](<../../../rtl/back2/rename.v#L981-L984>)以组号寻址，无代际副本。
触发：head=1，老分支 idx3 等待；年轻项已执行但未提交，tail 绕回0。仅分配新 idx0 即重写 group0 的 mask/free-head/RAT 组基；老 idx3 尚合法，却失去其快照。其误判恢复读到新世代状态（701–744），保留错路映射/free-head。可用无目的 nop 填满 ROB，避免 PRF32 空闲数先限流。
最小验证：延迟老分支操作数，跨63→0分配后再解析，比较恢复映射；控制组禁止跨组复用。一般锁步无“组首可复用、组尾仍活”的覆盖计数；未动态证实。

### 02-4 P0：译码权限硬接 M（已确认静态，新定位；跨域后果待验证）
[backend_top:698–701](<../../../rtl/back2/backend_top.v#L698-L701>) 给 decoder 的 priv 恒 M，虽实际 `priv_i` 已用于 ecall（679–681），却未用于权限译码。S/U 下机器 CSR 或 xRET 等可绕过 decoder 权限检查，754–807 无当前特权级补判；执行/提交可继续走 CSR/特权路径。
最小验证：U 下 `csrrw x1,mstatus,x0` 必须 cause2且无CSR副作用，M下同编码为控制；还需跨域核对顶层有无独立补判。锁步主测仅五程序（[TB:126](<../../../sim/unit/tb_back2_lockstep.sv#L126>)），且异常一律失败（801–805），不是权限矩阵测试。

### 02-5 P1：多 CSR 同块时 pending 过早清除（已确认静态，新定位）
[backend_top:2066–2073](<../../../rtl/back2/backend_top.v#L2066-L2073>)实际登记最老 CSR；2043–2049 任意 CSR 提交即清 pending，均与邻近“最年轻/仅匹配idx清除”注释相反。
触发：同块两条 CSR，第一条提交、第二条尚未执行；年轻 load 可绕过[1241–1245](<../../../rtl/back2/backend_top.v#L1241-L1245>)，按第二条更新前的翻译上下文执行。DYN FP 有独立 head 门（1265–1267），故撤回“所有FP必用旧frm”的泛化。最小验证：同块 `{无关CSR, mstatus.MPRV写}` 后 load，延迟第二条，核对请求上下文；单CSR为控制。锁步 p4 明确不读写浮点CSR，主测也不检查译址上下文；实际访存影响待跨域验证。

### 02-6 P1：CSR 桩写 frm 取错位（已确认静态，新定位）
[b2_csr:162](<../../../rtl/back2/b2_csr.v#L162>)对地址002取 `wdata[7:5]`，应取独立 frm CSR 的低3位；写1会得到0。读口111却正确零扩展低3位。该模块目前为后端直驱测试桩，不能外推现役 core 的 csr_file 同样有错。最小验证：分别写002=1、003=0x20，应读 frm=1；写002=0为控制。IPC只跑整数，锁步 p4:13–15明确不写frm，故漏测。

## 【遗留/风险】
实际阅读覆盖（非仿真覆盖）：

|主责文件|深度|
|---|---|
|[backend_top](<../../../rtl/back2/backend_top.v>)|读全1–2818|
|[b2_csr](<../../../rtl/back2/b2_csr.v>)|读全1–177|
|[iq](<../../../rtl/back2/iq.v>)|读全1–516|
|[prf](<../../../rtl/back2/prf.v>)|读全1–99|
|[rename](<../../../rtl/back2/rename.v>)|读全1–1029|
|[rob](<../../../rtl/back2/rob.v>)|读全1–918|
|[rob_wide_mem](<../../../rtl/back2/rob_wide_mem.v>)|读全1–162|
|[params](<../../../rtl/back2/back2_params.vh>)|读全1–627|

测试：[IQ](<../../../sim/unit/tb_back2_iq.sv>)、[宽RAM](<../../../sim/unit/tb_back2_rob_wide_mem.sv>)、[IPC](<../../../sim/unit/tb_back2_ipc.sv>)读全；[锁步](<../../../sim/unit/tb_back2_lockstep.sv>)抽查1–138、490–659、740–939，其余未读。

核对：4分配/2提交、ROB64/双PRF64参数及回收口一致；同块WAW最近前驱、仅用现有free额度、flush恢复 arat_next 均已修，未列现存缺陷。IQ上层983–988已统一用wr_cap，不再以free_cnt许可；但IQ单测仅单写且强制128项窗口，不能证明当前64项/4写不丢项。宽RAM测试39–50等第二次读后才比较，未真正断言碰撞首拍read_first或严格1拍延迟。

PRF deferred的单在飞、首次锁存、done/唤醒同步仲裁静态可闭合，未测并发/冲刷反证。ROB精确异常不走正常回收，flush后重建；未声称异常全覆盖。win_idx仅索引无epoch（rob:380），已知3次影子不匹配本域未复现、未独立定根；不将其写成新动态结论。typed更新口无响应epoch、两位epoch回卷、checkpoint共享释放及rename的clr_pd组合暂存未完成可达性反证，保留待验证，不计实质问题。p_*层次签名耦合确在backend_top:277–278，非独立功能缺陷。

KB skill首轮不可用时已用同库CLI检索F寄存器/frm规范，续轮已成功加载；未重建索引。
