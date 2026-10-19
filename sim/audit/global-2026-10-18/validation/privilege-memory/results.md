# privilege-memory 定向验证报告（2026-10-18）

> 目标：为静态审计 01（P0-01、P1-09）、03（LSQ 释放窗口）补**最小可复现证据**；不改 RTL。
> 范围：本目录 `sim/audit/global-2026-10-18/validation/privilege-memory/` 为唯一新增写入；
> 原 RTL/测试/配置/文档只读。DUT：HEAD `b284df7`；源码基线 245 文件 SHA-256 已由母 Agent 核对一致。
> 工具：Icarus Verilog 12.0；独立参考计算 `ref_calc.py`（rc + 精确锚点）。
> 墙钟：全 11 例 `run_all.sh` 实测约 8 s；单例 << 180 s。

## 【结论】

**11/11 用例脚本通过（exit 0）**：5 个缺陷例全部“缺陷已复现”、6 个控制例全部 `CONTROL_OK`；
反证 4/4。缺陷例的 DUT 语义是 **FAIL**，脚本 PASS 只代表“验证成功（缺陷按预测机理复现）”，
**不是 RTL 通过**。三组均在模块级完成，未做整核移植：

| 组 | 缺陷例（复现） | 控制例（DUT==规范） |
|---|---|---|
| A 特权/CSR/xRET（backend 模块级） | p1、p2、p4 | p0（cause2 通道正控）、p3、p5 |
| B CLINT MTIP 相等边界（clint 模块级） | b2 | b1(T-1)、b3(T+1) |
| C LSQ LQ 释放回绕（lsq 模块级） | l1 | l2 |

## 【变更】

无 RTL/源 TB/golden/断言改动。仅新建本目录：3 个 TB（`tb_priv_backend.sv`、`tb_clint_edge.sv`、
`tb_lsq_release.sv`）、`ref_calc.py`、`run_one.sh`、`run_all.sh`、`run_{p0..p5,b1..b3,l1..l2}.sh`、
`negative/`（反证夹具 + `run_negative.sh`）、`log_*.log`、`ref_*.log`、`all_*.out`、本报告。

## 【证据】

### 0. 复现命令

```sh
cd sim/audit/global-2026-10-18/validation/privilege-memory
./run_all.sh              # VALIDATION: 11/11, exit 0（全 11 例）
./negative/run_negative.sh# FIXTURE runner sync: OK + NEGATIVE: 4/4, exit 0
./run_p1.sh               # 单例：exit 0 = 缺陷已复现；log_p1.log
./run_b2.sh
./run_l1.sh
```
清单由 `run_all.sh` 硬编码（p0..p5、b1..b3、l1..l2，长度断言 ==11），执行前逐文件存在性预检，
缺失即 `VALIDATION: 0/11 (manifest preflight failed)` + exit 1；汇总恒为 `<pass>/11`。
`run_one.sh` 校验 kind/case/mode 白名单、`ref_calc.py` 的 **rc==0** 与精确锚点
`REF_CHECK <tag>: OK value=0x........`（只允许 `REF_*` 行）、唯一 `RESULT=` 行；
删除 vvp 前用 `readlink -m` 校验只删本例。

### 1. A) backend 以 M 权限译码：U/S 的 M CSR 写与 U 的 mret 不被拒（P0-01，模块级复现）

做法：用**真实指令位**经 `backend_top` 派发口 `lane_insn_i` 注入，模块端口 `priv_i` 分别给
U(00)/S(01)/M(11)；观测 D1 uop 的 `illegal`（`BACK2_FL_IS_ILLEGAL`）、提交、`trap_valid_o/
trap_cause_o==2`、`csr_we_o`、`xret_cmt_o`。

| 例 | priv | 指令 | DUT 观测 | 规范期望 | 结论 |
|---|---|---|---|---|---|
| p0 `P0_CTL_ILLEGAL_INSN` | M | `0x00000000` | illegal=1，trap2=1，csr_we=0 | 非法、cause 2 | CONTROL_OK（正控：证明 cause2 观测通道有效） |
| p1 `P1_U_CSRRW_MSTATUS` | U | `csrrw x1,mstatus,x0` 0x300010f3 | **illegal=0，commit=1，csr_we=1，commit_we=1，trap2=0** | illegal=1、cause 2、无 CSR 写 | 缺陷 |
| p2 `P2_S_CSRRW_MSTATUS` | S | 同上 | 同上（S 同样被放行） | illegal=1、cause 2 | 缺陷 |
| p3 `P3_CTL_M_CSRRW_MSTATUS` | M | 同上 | illegal=0，commit=1，csr_we=1，trap2=0 | 合法 | CONTROL_OK |
| p4 `P4_U_MRET` | U | `mret` 0x30200073 | **illegal=0，commit=1，xret=1，trap2=0** | illegal=1、cause 2 | 缺陷 |
| p5 `P5_CTL_M_MRET` | M | `mret` | illegal=0，commit=1，xret=1，trap2=0 | 合法 | CONTROL_OK |

- 机理（只读定位）：`rtl/back2/backend_top.v:698-699` 把每 lane `decoder.priv_i` 硬接
  `` `RV32GC_PRIV_M ``，与模块端口 `priv_i` 无关；提交级 CSR 写使能 `csr_we_w`
  （`backend_top.v:2079`）只看提交组是否有 CSR，不按实际 priv 复查；mret 被无条件列入
  `is_sys_ok`（`:736-741`）。因此 U/S 下 csrrw mstatus 与 U 下 mret 都按 M 合法译码/提交。
- **证据等级（不夸大）**：backend 模块级（D1 译码 → rename/ROB → 执行 → 提交/trap 口）。
  `csr_we_o=1` 只证明**后端发出了 CSR 写使能**（没有被拒绝）；本夹具**未实例化 csr_file/
  priv_ctrl/trap_ctrl**，故不声称“mstatus 寄存器值已被改写”“mret 已完成特权切换”或
  “整核提权已复现”。整核级（core_top_2b 的 CSR chk 悬空 + 真实 trap/priv 路径）未做。
- 日志：`log_p1.log`（DUT 行 `priv=00 ... csr_we_seen=1`）、`log_p2.log`、`log_p4.log`、
  控制 `log_p0/p3/p5.log`。

### 2. B) CLINT 在 mtime==mtimecmp 时不置 MTIP（P1-09，模块级复现）

做法：经真实 MMIO 写口写 `mtimecmp=T`、并把 `mtime` **连续 16 拍**保持为 T-1 / T / T+1
（每拍软件写 mtime，优先于自由 +1；同时每拍读回 mtime 校验写入生效）。这排除了
“一拍传播延迟”：若只是延迟，保持相等多拍后 MTIP 必然置起。

| 例 | mtime vs cmp | DUT mtip | 规范期望 | 结论 |
|---|---|---|---|---|
| b1 `B1_CTL_MTIME_T_MINUS_1` | T-1 vs T | 0/16 | 0 | CONTROL_OK |
| b2 `B2_MTIME_EQ_MTIMECMP` | T vs T | **0/16**（16 拍持续相等） | 1/16（mtime≥mtimecmp） | 缺陷 |
| b3 `B3_CTL_MTIME_T_PLUS_1` | T+1 vs T | 16/16 | 1 | CONTROL_OK |

- 读回校验：三例 `readback_ok=1`（`hit_cnt=16`，`rb_cmp=T`），证明写口/保持相等确实生效。
- 机理：`rtl/clint/clint.v:123` `assign mtip_o = (mtime_r > mtimecmp_r);` 用严格大于；
  ISA `mtimeintrpending` 要求 mtime ≥ mtimecmp。注释（`:19-23`）把“严格大于”写成
  SiFive/ACLINT 口径，与规范相反。
- **证据等级**：clint 模块级（真实 req/resp 口），不含 mmio_route/top 集成；不声称整核
  定时器中断路径已端到端复现。
- 日志：`log_b1.log`、`log_b2.log`、`log_b3.log`。

### 3. C) LSQ 已提交 LQ 不释放：ROB 深度 64 却用 7 bit 年龄（03 P0，状态转移级复现）

做法：经**真实 D3 分配口**（`lalloc_valid=4'b0011`，`lalloc_rob` = 两条 load 的 ROB 索引）
分配 LQ 槽 0/1；随后把模块输入 `rob_head/cmt_n` 置为提交窗口，观测一个时钟沿后
`ld_v[0]/ld_v[1]` 是否释放。未做内部 `force`；`rob_head/cmt_n` 是 ROB 的正常输入。

| 例 | head | 分配 (rob0,rob1) | 规范年龄 | DUT 结果 | 结论 |
|---|---|---|---|---|---|
| l1 `L1_ROB_WRAP_HEAD63_CMT2` | 63 | (63, 0) | 0, 1（均 <2，均应释放） | **v0=0，v1=1（泄漏）** | 缺陷 |
| l2 `L2_CTL_HEAD0_CMT2` | 0 | (0, 1) | 0, 1 | v0=0，v1=0 | CONTROL_OK |

- 分配与索引读回：两例 `pre_alloc v0=1 rob0=<期望> v1=1 rob1=<期望>`，排除夹具未真正分配。
- 机理：`rtl/back2/lsq_simple.v:1348`
  `if (ld_v[si] & (((ld_rob[si] - rob_head) & 7'h7F) < {5'b0,cmt_n}))`
  用 7 bit 模 128 的年龄；ROB 深度为 64（`back2_params.vh:29-30`）。`head=63, ld_rob=0`
  时年龄算成 65（规范应为 1）⇒ 该已提交 LQ 项不在本提交窗口内、永不按此窗口释放（槽泄漏）。
- **证据等级**：真实分配 + 真实 LQ 阵列 + 受控提交窗口输入（`rob_head/cmt_n` 由 TB 给值），
  只证明**该状态转移**；未构造出“ROB 末尾/回绕处恰好有两条 load 且同拍提交”的整核程序，
  故不声称整核可达。分支年轻判定使用同一 7 bit 年龄（`:1467`）为同源风险，本批未单独测。
- 日志：`log_l1.log`（`AFTER v0=0 v1=1`）、`log_l2.log`。

### 4. 反证（`negative/`，不删/不移正式用例）

```sh
./negative/run_negative.sh   # FIXTURE runner sync: OK (2/2 byte-identical) + NEGATIVE: 4/4
```
- 空清单：0 个脚本 ⇒ `VALIDATION: 0/11 (manifest preflight failed)` + exit 1，不执行用例；
- 坏 reference：夹具 `ref_calc.py` 输出锚点 tag 错位（rc=0）⇒ run_one 以 `REF_CHECK anchor` 拒绝；
- 坏 reference：锚点正确但 rc=1 ⇒ run_one 以 `ref_calc.py rc=1` 拒绝；
- 坏入口：坏 kind / 越界 case / `01` / 坏 mode 全部在白名单阶段拒绝。
两个坏 reference 夹具内的 `run_one.sh` 与正式 runner **字节相同**（sha256 `d1acd207…`），
`run_negative.sh` 开头 `cmp` 前置检查，漂移即 `FIXTURE DRIFT` + exit 1。
日志：`negative/log_*.log`。

## 【遗留/风险】

1. 三组均为**模块级**：A 未实例化 csr_file/priv_ctrl/trap_ctrl（不声称 CSR 内容改写/特权切换/
   整核提权）；B 未接 mmio_route/top；C 的 `rob_head/cmt_n` 为受控输入（不声称整核可达）。
2. 可选 STQ 32 槽候选被 8 槽 `pri_enc` 截断（03 报告 §P1）**本轮未做**：按预算优先保证 A/B/C
   三组，不扩成整核移植任务。
3. 未跑原 regress/arch-test/锁步/Vivado；未提交 git。缺陷例判定为“验证成功（缺陷已复现）”，
   不是“RTL 通过”。
4. 产物全部在本目录；原 RTL/测试/配置/文档未改。
