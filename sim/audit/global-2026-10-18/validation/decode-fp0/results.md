# decode-fp0 定向验证报告（2026-10-18）

> 目标：只做**可复现证据**，不改 RTL/源 TB/golden/断言。所有产物在本目录。
> DUT：`HEAD b284df704e4b0984cef8fa8062ada01656eca287`（"HEADb284df7"）。
> 源码基线：按母 Agent 实测，BASELINE.json 所列 **245 个源/支持文件 SHA-256 全部一致**；
> 本任务只在本目录新增 TB/脚本/日志，未改任何源文件（不引用 tree hash 差异作为源码变化依据）。
> 工具：Icarus Verilog 12.0；独立 oracle：`/opt/riscv/bin/riscv32-unknown-linux-gnu-{as,objdump}`。
> 墙钟：全 24 例 `run_all.sh` 实测约 **7 s**（每例 vvp 独立进程 + 60/170 s 超时兜底）。

## 【结论】

**24/24 用例脚本通过（exit 0）**，其中 **12 个缺陷例全部"缺陷已复现"**、
12 个反向控制例全部 `CONTROL_OK`。注意判定口径：缺陷例的 DUT 语义是 **FAIL**，
脚本的 PASS 只表示"验证成功（缺陷按预测机理复现）"，不等于 DUT 正常。

| 组 | 缺陷例（复现） | 控制例（DUT==规范） |
|---|---|---|
| ① compressed MISC-ALU rd' | c1 c3 c4 | c0 c2 c7 c8 |
| ② c.ebreak / c.jr x0 | c5 c6 | c0 c2 c7 c8 |
| ③ OP-FP 保留字段 | f1 f2 f3 f4 f5 | f0 f6 f7 f8 f9 f10 |
| ④ backend f0 抑制 | b1 b3 | b2 b4 |

## 【变更】

无 RTL/源 TB/golden/断言改动。仅**新建**本目录：
`ref_calc.py`、`tb_compressed_audit.sv`、`tb_decoder_fp_audit.sv`、`tb_backend_f0.sv`、
`run_one.sh`、`run_all.sh`、`run_{c0..c8,f0..f10,b1..b4}.sh`、
`log_*.log`（判定日志）、`ref_*.log`、`all_*.out`、`oracle_objdump.log`、`oracle_assembler.log`、
`negative/`（反证夹具与 `run_negative.sh`）、`results.md`、`README.md`。
所有 vvp 产物也落在本目录（运行后只删除本例 vvp，可重编）。

窄验收加固（DUT 缺陷结论不变）：
- `run_all.sh` 改为**硬编码 24 例清单**（c0..c8、f0..f10、b1..b4，断言长度==24），
  执行前逐文件存在性预检；缺任一例即 `VALIDATION: 0/24 (manifest preflight failed)` + exit 1，
  不再依赖 `ls`/通配发现（旧版空目录会 `0/0` 成功、缺一例会 `23/23` 成功）。
- `run_one.sh` 增加 kind/case/mode 白名单（c:0..8、f:0..10、b:1..4，case 必须规范十进制写法），
  参考计算同时校验 **python 退出码**与**精确锚点** `REF_CHECK <tag>: OK value=0x........`
  （kind=c 另需 `REF_CIN <tag>: OK cin=0x....`），只允许 `REF_*` 行，不再认任意 `OK` 子串。
- 删除 vvp 前后用 `readlink -m` 解析绝对路径，校验父目录 == 本目录且文件名 == 本例 `<kind><case>.vvp`，
  只删本例 vvp。
- 加固后反证暴露并修正了参考模型自身的 `c.nop` 重建常量笔误（`0x2001`→`0x0001`，
  旧 runner 因不看 rc 漏过）；仅影响夹具，不影响 DUT 观测量与任何缺陷结论。

## 【证据】

### 0. 一键复现与逐例复现

```sh
cd sim/audit/global-2026-10-18/validation/decode-fp0
./run_all.sh            # 期望最后一行 VALIDATION: 24/24，exit 0（all_run_all.out）
./run_c1.sh             # 单例：exit 0 = 缺陷已复现；日志 log_c1.log
./run_f1.sh             # 单例：exit 0 = 缺陷已复现；日志 log_f1.log
./run_b1.sh             # 单例：exit 0 = 缺陷已复现；日志 log_b1.log
```
判定由 `run_one.sh` 用**退出码 + 唯一 RESULT 行**给出：RESULT 行缺失/不唯一、
控制例非 `CONTROL_OK`、缺陷例非 `DEFECT_REPRODUCED`，一律 exit 1。
另有 `python3 ref_calc.py <tag>` 独立重算 32 位编码并与 TB 常量对拍（`ref_*.log`）：
runner 同时要求 **python rc==0** 且输出只含精确锚点
`REF_CHECK <tag>: OK value=0x........`（kind=c 另需 `REF_CIN <tag>: OK cin=0x....`）。

反证（夹具不删/不移正式用例，见 `negative/`）：
```sh
cd sim/audit/global-2026-10-18/validation/decode-fp0
./negative/run_negative.sh   # 期望 NEGATIVE: 5/5，exit 0
```
覆盖：空目录缺全部 24 例、缺 `run_f10.sh`（其余 23 个占位）、参考输出锚点错位（rc=0）、
参考输出锚点正确但 rc=1、kind/case/mode 白名单坏入口；每一项都要求被 runner **拒绝**
（日志在 `negative/log_*.log`），任何一项意外 rc=0 即反证失败。
两个坏 reference 夹具内的 `run_one.sh` 与正式 `run_one.sh` **字节相同**（sha256 一致），
`run_negative.sh` 开头用 `cmp` 做前置检查，不一致即 `FIXTURE DRIFT` + exit 1，
确保反证实际跑的是当前 runner 而不是旧副本。

### 1. ① compressed_expand MISC-ALU rd' 取错字段（已复现）

| 例 | 输入（16 位） | DUT 展开 | 规范期望展开 | 结论 |
|---|---|---|---|---|
| c1 `C1_C_SUB_X8_X9` | `0x8c05` = c.sub x8,x9 | `0x409484b3` = sub x9,x9,x9 | `0x40940433` = sub x8,x8,x9 | 缺陷 |
| c3 `C3_C_SRLI_X8_5` | `0x8015` = c.srli x8,5 | `0x0056d693` = srli x13,x13,5 | `0x00545413` = srli x8,x8,5 | 缺陷 |
| c4 `C4_C_ANDI_X8_5` | `0x8815` = c.andi x8,5 | `0x0056f693` = andi x13,x13,5 | `0x00547413` = andi x8,x8,5 | 缺陷 |
| c2 `C2_CTL_SUB_RD_EQ_RS2`（控制） | `0x8c01` = c.sub x8,x8 | `0x40840433` | `0x40840433` | CONTROL_OK |
| c0 `C0_CTL_C_NOP`（控制） | `0x0001` = c.nop | `0x00000013` | `0x00000013` | CONTROL_OK |
| c7 `C7_CTL_C_JR_X5`（控制） | `0x8282` = c.jr x5 | `0x00028067` | `0x00028067` | CONTROL_OK |
| c8 `C8_CTL_C_JALR_X5`（控制） | `0x9282` = c.jalr x5 | `0x000280e7` | `0x000280e7` | CONTROL_OK |

- 机理（只读定位）：`rtl/decode/compressed_expand.v:70-76` 把 3 位寄存器域统一定义为
  `rs1_3=c[9:7]`、`rd_3=c[4:2]`、`rs2_3=c[4:2]`，`rd_p={2'b01,rd_3}=8+rd_3`；
  但 CA/CB 格式的 rd' 在 `c[9:7]`（`c[4:2]` 是 rs2'）。MISC-ALU 展开
  `q1_srli/q1_srai/q1_andi/q1_sub/q1_xor/q1_or/q1_and` 全部把 **rd_p 同时当 rd 和 rs1**
  （`compressed_expand.v:294-314`，选择器 `:318-326`）。
- 独立确认（非 RTL）：`objdump -D -b binary -m riscv:rv32 -M no-aliases` 对 `0x8c05`
  输出 `c.sub s0,s1`（oracle_objdump.log:8）；`as -march=rv32imafdc` 把 `c.sub s0,s1`
  编成 `8c05`、反汇编为 `sub s0,s0,s1`（oracle_assembler.log 的 c_sub 段）⇒ 正确展开确为
  **sub x8,x8,x9 = 0x40940433**（`ref_calc.py` 按 R/I 字段序独立重算亦为 0x40940433）。
- 反向控制 c2：rd'=rs2'=x8 时两种取法同值 ⇒ DUT 正确，排除"夹具/期望常量错"。
- 日志：`log_c1.log:1-3`、`log_c3.log`、`log_c4.log`、`log_c2.log`。

### 2. ② c.ebreak 误判非法 / c.jr x0 误判合法（已复现）

| 例 | 输入 | DUT | 规范期望 | 结论 |
|---|---|---|---|---|
| c5 `C5_C_EBREAK` | `0x9002` | `insn32=0x00100073` 但 **ill16=1** | ill16=0，insn32=`0x00100073` | 缺陷 |
| c6 `C6_C_JR_X0_RESERVED` | `0x8002` | **ill16=0**，`insn32=0x00000067`（jalr x0,0(x0)） | ill16=1（保留） | 缺陷 |
| c7/c8（控制） | `0x8282`/`0x9282` | 合法且展开正确 | 合法 | CONTROL_OK |

- 机理：`compressed_expand.v:418-422` 的 `q2_special_ok` 对 `f3==100` 只在
  `c[12] && rs2==0` 时套 `c_jr_ok=(rs1_5!=0)`，而该集合**同时包含 c.ebreak**
  （`c[12]=1,rs2=0,rd=0`，`:396-401` 才把它选成 ebreak）⇒ ebreak 被 `c_jr_ok=0` 判非法；
  反之 `c[12]=0` 的 c.jr 走 `1'b1`，完全绕开 `rs1!=0` 检查 ⇒ `c.jr x0` 被放行。
- 独立确认：`objdump` 对 `0x9002` 输出 `c.ebreak`、对 `0x8002` 输出 `.insn 2, 0x8002`
  （保留），`as` 对 `c.jr zero` 报 `illegal operands`（oracle_assembler.log）。
- 日志：`log_c5.log:1-3`、`log_c6.log:1-3`。

### 3. ③ decoder OP-FP 保留字段未判非法（已复现）

| 例 | 输入 | DUT ill_instr | 规范期望 | 结论 |
|---|---|---|---|---|
| f1 `F1_FSQRT_RS2_NZ` | `0x58100053`（fsqrt.s rs2=1） | 0 | 1（rs2≠0 保留） | 缺陷 |
| f2 `F2_FCVT_L_S_RV32` | `0xc0200053`（fcvt.l.s） | 0 | 1（RV32 保留） | 缺陷 |
| f3 `F3_FCVT_S_L_RV32` | `0xd0200053`（fcvt.s.l） | 0 | 1（RV32 保留） | 缺陷 |
| f4 `F4_FMV_X_W_RS2_NZ` | `0xe0100053`（fmv.x.w rs2=1） | 0 | 1（rs2≠0 保留） | 缺陷 |
| f5 `F5_FMV_W_X_RS2_NZ` | `0xf0100053`（fmv.w.x rs2=1） | 0 | 1（rs2≠0 保留） | 缺陷 |
| f0,f6–f10（控制） | rs2=0 的 fsqrt/fcvt/fmv + fadd.s | 0 | 0 | CONTROL_OK |

- 机理：`rtl/decode/decoder.v:431-435` 的 `fp_arith5_ok` 只按 funct5 认 FSQRT，**不查 rs2=0**；
  `:461-466` 的 `fp_cvt_rs2_ok` 只要求 `rs2[4:2]==0`，于是 RV32 非法的
  `fcvt.l/lu.s`、`fcvt.s.l/lu`（rs2=00010/00011，`rs2[4:2]` 仍为 000）被放行；
  `:470-472`/`:480-490` 的 fmv.x.w/fclass、fmv.w.x 也只查 funct5+f3，不查 rs2=0。
- 独立确认：
  - `fcvt.l.s`/`fcvt.s.l` 被 `as -march=rv32imafdc_zicsr` 直接拒绝（unrecognized opcode），
    与 ISA 手册 `[#norm:fcvtlongfloatrv64only]`（`riscv-isa-manual/src/unpriv/f-st-ext.adoc:320-431`，
    "fcvt.l.s, fcvt.lu.s, fcvt.s.l, fcvt.s.lu are RV64-only"）一致；注意 **objdump 会把
    `0xc0200053` 反汇编成 fcvt.l.s（其反汇编器不按 XLEN 过滤），故该条不能拿 objdump 当 oracle**。
  - `0x58100053`、`0xe0100053`、`0xf0100053` 被 objdump 输出 `.insn`（保留），
    合法对照 `0x58000053` → `fsqrt.s ft0,ft0,rne`（oracle_objdump.log:26-31）。
- 日志：`log_f1.log:1-3` … `log_f5.log`、`log_f0.log`、`log_f6.log`。

### 4. ④ backend_top dst_fp 抑制 f0 目的寄存器（已复现，含端到端写口观测）

做法：**真实指令位**经 `backend_top` 的派发口 `lane_insn_i` 注入（后台组合译码 →
D1 uop 打包 → rename → ROB → 执行 → 提交），读 D1 uop 的 `dst_fp` 位，并观测
**真实 FP PRF 写口 `u_dut.u_prf_f.we`**、`commit_arch_we_o`：

| 例 | 指令 | D1 dst_fp | 提交 | commit_arch_we | FP PRF 写口 | 结论 |
|---|---|---|---|---|---|---|
| b1 `B1_FADD_S_F0` | `0x00208053` fadd.s f0,f1,f2 | **0**（is_fp=1, illegal=0） | 是 | **0** | **0 次** | 缺陷 |
| b2 `B2_CTL_FADD_S_F1`（控制） | `0x002080d3` fadd.s f1,f1,f2 | 1 | 是 | 1 | 1 次 | CONTROL_OK |
| b3 `B3_FLW_F0` | `0x00002007` flw f0,0(ra) | **0**（is_fpls=1, illegal=0） | 是 | **0** | **0 次** | 缺陷 |
| b4 `B4_CTL_FLW_F1`（控制） | `0x00002087` flw f1,0(ra) | 1 | 是 | 1 | 1 次 | CONTROL_OK |

- 机理：`rtl/back2/backend_top.v:780` `wire dst_fp = fp_we & (drd != 5'd0) & ~kill;`
  把整数 x0 的"硬连零"规则误用到浮点目的号；该位在 `:850` 打包进 uop flags
  （`BACK2_FL_RD_F_WEN`），`rename` 用 `rn_ndst_f[g]=u[RD_F_WEN]`（`:926`）决定是否分配
  FP 物理目的，提交侧 `cmt_f_we`（`:1937`）与 `u_prf_f`（`:2279`）均随之为 0
  ⇒ **fadd.s/flw 目的 f0 既不分配物理寄存器、不写 PRF、提交时 arch_we=0**。
- 规范侧无"f0 抑制"：`fadd.s f0,f1,f2`、`flw f0,0(a1)` 均被 `as` 正常汇编
  （oracle_assembler.log），F 寄存器 f0–f31 均为普通可写寄存器。
- **证据等级（不夸大）**：本条已不只是静态/组合推断——注入点在 backend 派发口，
  观测点已越过 rename/ROB/执行/写回，落在**真实 FP PRF 写口与提交 arch_we**；
  但**不是从 core_top 取指、前端预测开始的整核级**验证（单条指令、TB 自建简易
  mem 从设备），也未跑 arch-test。反向控制 b2/b4 同指令 rd=f1 时全链路写 1 次，
  排除"PRF 写口探针恒 0/夹具坏"。
- 日志：`log_b1.log:1-4`（第 3 行 `E2E commit_seen=1 commit_arch_we=0 commit_rd=0 fp_prf_we_seen=0`）、
  `log_b2.log`、`log_b3.log`、`log_b4.log`。

### 5. 判定锚点示例（log_c1.log，3 行判定）

```
CASE 1 C1_C_SUB_X8_X9 DUT insn32=0x409484b3 ill16=0 hint=0 ctl=0
CASE 1 C1_C_SUB_X8_X9 EXPECT insn32=0x40940433 ill16=0
CASE 1 C1_C_SUB_X8_X9 RESULT=DEFECT_REPRODUCED
```

## 【遗留/风险】

1. ④ **未做整核（core_top 取指→前端→后端）复现**：注入点在 backend 派发口；
   若要"整核级"，需 AXI mem 模型 + FPU 程序镜像，本轮按墙钟预算未做（不算已验证）。
2. ③ 的 RV32-only 判据依赖 ISA 手册 `norm:fcvtlongfloatrv64only` 与 RV32 assembler 拒绝；
   binutils **反汇编器不按 XLEN 过滤**，不能拿 objdump 输出当该条 oracle（已在 §3 注明）。
3. 静态审计来源 05/02/06 文件在本轮开始时尚未生成（`global-2026-10-18/` 下只有
   `BASELINE.json`），本报告未引用、未依赖它们；结论全部来自 RTL 直读 + 独立 oracle + 仿真。
4. 未跑全量回归/arch-test/锁步，未调用 Vivado；缺陷例判定为"验证成功（缺陷已复现）"，
   不是"DUT 正常 PASS"。
5. 本目录只新增文件、未提交 git；源/支持文件基线按 BASELINE.json **245 项 SHA-256
   核对一致**（母 Agent 实测），本轮未做任何源码改动。
