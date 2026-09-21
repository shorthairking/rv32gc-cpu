# M5 上板前核级仿真验证件（`rv32gc-cpu/sw/m5_board/tb/`）

在 **rv32gc-cpu 核 RTL** 上对 `sw/m5_board` 的 M5 上板程序做核级仿真，一次跑完给出
**未捕获即失败**的判定（唯一 `TB_M5_BOARD: PASS` 行 / 否则 `FAIL <条目>` + `$fatal`）。
只读 `rtl/**`、`sim/**`、`sw/m5_board/*.S`、`build.sh`；**只写本目录**。

---

## 1. 文件清单

| 文件 | 作用 |
|---|---|
| `confreg_axi_filter.v` | **AXI4 地址过滤层 + 上板 CONFREG 行为模型**。插在 `core_top`（主）与 `sim_mem_model`（从）之间：地址落在 `0x1FD0_0000–0x1FD0_FFFF` 的读/写自答，其余**逐字段透传**。实现 `+0xF000` LED（读写）、`+0xF010` 数码管（读写）、`+0xF020` switch（只读，`SWITCH_VAL=8'hA5`）、`+0xF030` FREQ（只读，`32'd33000000`）、`+0xE000` TIMER（自由运行、写任意值清零）。读数据在 **AR 握手拍寄存并保持**（= 上板 `confreg_syn.v:295` 行为；见 §5.5）。两个**从设备行为模型开关**：`R_STICKY`（CONFREG 侧保持，默认 1 = 上板口径）、`DDR_R_NONHOLD`（DDR3/XIP 侧：1 = **非保持型 R 通道**，RDATA 只在 `m_rvalid & m_rready` 拍有效，其余拍为 0，= 真实 MIG / 流水化互连口径；默认 0 = 原样透传）。输出判据/诊断观测：首笔 AR、五寄存器访问标志、AXI 轨迹、路由一致性计数。 |
| `tb_m5_board.sv` | **顶层 TB**：48 端口逐字例化 `core_top` + 过滤层 + `sim_mem_model`；时钟半周期 15.1515 ns（周期 30.303 ns ≈ 33.0 MHz，上板口径）；复位 20 拍后负沿释放；`intrpt=0`；UART 子串匹配（滚动窗口，逐字节增量，支持"结果行前缀 + 宽限字节"提前收尾）；AXI 区域统计与轨迹直方图；判据 C0–C5（+ **可选 C6**）、PASS/FAIL 输出。 |
| `run_tb.sh` | 编译（`iverilog -g2012 -I rtl/pkg -I <repo>` + RTL 全量）+ 运行（`stdbuf` 行缓冲）+ 三重判定（vvp 退出码 / PASS 锚点恰 1 行 / 无 `FAIL` 字样）；日志落 `tb/out/`；**失败即非零退出**。新增两个环境变量：**`EXPECT_EXTRA`**（可选判据 C6 的子串；默认空 = 不启用 ⇒ C0–C5 语义不变）与 **`RTL_DIR`**（RTL 源目录，默认 `rtl`；旧 RTL 注入反证用 `tb/scratch/oldrtl`）。 |
| `make_oldrtl_overlay.sh` | **旧 RTL 只读拷贝**生成器：`tb/scratch/oldrtl/` = `rtl/**` 逐字节拷贝 + 两个文件换成 **R2 修复前**版本（`git show 68ff5fd:<path>`，只读；**不用** checkout/stash/reset）⇒ 反证实验期间**一行 `rtl/**` 都不改**（脚本前后自证 `rtl/**` md5 汇总一致）。 |
| `run_diag_matrix.sh` | **诊断版三配置仿真矩阵**（本轮主证据入口）：`diag_hold`（修复后+保持型）、`diag_nonhold`（修复后+非保持型）、`diag_old_nonhold`（**修复前**+非保持型）三跑并行，末尾逐条比对期望（前两个 PASS + `R2FIX: yes`；第三个必 FAIL 且 step2.5 回环必红）+ A/B UART 字节流比对 + `rtl/**` 指纹自证。 |
| `ctrl/ct_selftest.S` | **控制实验 A（测试台自检）**：独立编写的最小程序，点亮"CONFREG 五寄存器读写 + UART 捕获 + 复位取指"。预期 **PASS** —— 证明判定链本身有效。 |
| `ctrl/ct_delay_probe.S` | **控制实验 C**：用**与 m5 逐字相同的 `delay_loop`**（7×`nop`+`addi`+`bnez` = 9 条指令）+ CONFREG TIMER 实测 `cycles/iter`，给步④ 标定常量 `XIP_CPI` 一个硬数字。 |
| `ctrl/make_scaled.py` | 生成**控制实验 B**：把冻结程序只做**与判据无关**的挂钟常量缩放（`DELAY_HB_TICKS`、`DELAY_SW_TICKS`），其余逐字不动；每处替换断言"恰好命中 1 次"。 |
| `ctrl/diff_equiv.py` | **等价性机器证据**：冻结 hex 与缩放 hex 逐字比对，列出全部差异字并反汇编，断言差异 ≤ 8 字。 |
| `ctrl/build_ctrl.sh` | 用与 `sw/m5_board/build.sh` 同口径的工具链/链接参数构建三个控制程序。 |
| `ip/tb_ip_div.v` + `ip/run_ip_div_xsim.sh` | ★ **真实 div_gen IP 的时序/字段序探针**（xsim）：直接驱动 `fpga/ip/rv32_div/rv32_div_sim_netlist.v`（Vivado 加密功能模型），实测 59/10 ⇒ `tdata=0x00000005_00000009`、118049/2000 ⇒ `0x0000003b_00000031` ⇒ **字段序 = {商[63:32], 余数[31:0]}**。 |
| `ip/tb_mdu_ip.v` + `ip/run_mdu_ip_xsim.sh` | ★ **mdu 的 IP 分支自检**（xsim）：`-d RV32GC_USE_VIVADO_IP` + 真实 div_gen/mult_gen 网表，25 个向量覆盖 MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU 与 ISA 边界（除零、-2^31/-1、向零取整）。修复前 15 条 FAIL（商余数互换）、修复后 25/25 PASS；`--expect-fail` / `MDU_SRC=<修复前只读副本>` 做**不改 rtl/** 的反证。 |
| `ip/mdu_prefix_ref.v` / `ip/mdu_ipfix.v` | 修复前 / 修复后的 `mdu.v` **只读副本**（前者由 `git show HEAD:rtl/exec/mdu.v` 取出，md5 `d96ed0ce…`；后者 md5 `30a1ab7f…`）—— 供反证与复核用。 |
| `out/` | 全部日志与编译产物。 |

---

## 2. 可复现命令（cwd = `rv32gc-cpu/`）

```bash
bash sw/m5_board/tb/ctrl/build_ctrl.sh
python3 sw/m5_board/tb/ctrl/diff_equiv.py

# ① 控制实验 A（测试台自检）：预期 PASS
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_selftest.hex RUN_TAG=ctl_a TIMEOUT_CYCLES=200000 bash sw/m5_board/tb/run_tb.sh

# ② 控制实验 B（冻结程序的缩放副本）：完整五步 + 判据（约 2.8e6 拍 / 20 分钟）
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_m5_scaled.hex RUN_TAG=ctl_b_v4 TIMEOUT_CYCLES=6000000 bash sw/m5_board/tb/run_tb.sh

# ③ 控制实验 C（delay_loop 每迭代拍数实测）
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_delay_probe.hex RUN_TAG=ctl_c TIMEOUT_CYCLES=150000 bash sw/m5_board/tb/run_tb.sh

# ④ 被测程序（完整版）——预算不足，见 §5.6；正式判定建议用 ②
TIMEOUT_CYCLES=4000000 RUN_TAG=spec4m PROGRESS_EVERY=250000 bash sw/m5_board/tb/run_tb.sh

# ⑤ 结论 3 的 A/B 对照（R 数据保持）
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_selftest.hex RUN_TAG=ctl_a_sticky   RD_TRACE_WINDOW=10 TIMEOUT_CYCLES=100000 bash sw/m5_board/tb/run_tb.sh
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_selftest.hex RUN_TAG=ctl_a_nosticky R_STICKY=0 RD_TRACE_WINDOW=14 TIMEOUT_CYCLES=100000 bash sw/m5_board/tb/run_tb.sh
```

环境变量：`PROG_HEX`、`TIMEOUT_CYCLES`、`TOP`、`RUN_TAG`、`PROGRESS_EVERY`、`TRACE_PRINT_N`、
`UART_PRINT_MAX`、`R_STICKY`（默认 **1**）、`DDR_R_NONHOLD`（默认 **0**）、`RD_TRACE_WINDOW`（默认 0）、
`EXPECT_EXTRA`（默认**空** = 判据 C6 不启用）、`RTL_DIR`（默认 `rtl`）。

**非保持型 R 通道模型（2026-09-21 新增，用于 R2 缺陷复现/反证）**：
```bash
# 修复后两种模型都必须 PASS（判据 C0–C5 一字不动）
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_m5_scaled.hex RUN_TAG=ctl_b_v7_hold    TIMEOUT_CYCLES=6000000 bash sw/m5_board/tb/run_tb.sh
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_m5_scaled.hex RUN_TAG=ctl_b_v7_nonhold DDR_R_NONHOLD=1 TIMEOUT_CYCLES=6000000 bash sw/m5_board/tb/run_tb.sh
```

**★ 诊断版三配置矩阵（2026-09-21 本轮主证据；一条命令跑完 A/B/C）**：
```bash
bash sw/m5_board/tb/run_diag_matrix.sh
#   diag_hold        修复后 RTL + 保持型   ⇒ 期望 PASS（step2.5: word=0x12345678 byte=0x5A R2FIX: yes）
#   diag_nonhold     修复后 RTL + 非保持型 ⇒ 期望 PASS（且 UART 字节流与 hold 逐字节相同）
#   diag_old_nonhold 修复前 RTL + 非保持型 ⇒ 期望 FAIL（step2.5 回环必红）
# 汇总日志：tb/out/diag_matrix.log；三份完整日志：tb/out/diag_{hold,nonhold,old_nonhold}.log
```
其中"修复前 RTL"来自 `tb/scratch/oldrtl/`（由 `make_oldrtl_overlay.sh` 生成：
`rtl/**` 只读拷贝 + `git show 68ff5fd:` 取出的两个旧文件，**全程不改 `rtl/**`**）。

**★ M 扩展 IP 分支验证（2026-09-21 第三轮 · 板上十进制乱码根因；xsim）**：
```bash
# ① 真实 div_gen 的字段序（本轮的根因证据）：59/10 ⇒ 高半=5(商)、低半=9(余数)
bash sw/m5_board/tb/ip/run_ip_div_xsim.sh
# ② mdu 的 IP 分支自检：修复后 25/25 PASS
bash sw/m5_board/tb/ip/run_mdu_ip_xsim.sh
# ③ 反证（**不改 rtl/**）：拿修复前的只读副本 ⇒ 同一 TB 15 条 FAIL（商余数互换）
MDU_SRC=sw/m5_board/tb/ip/mdu_prefix_ref.v bash sw/m5_board/tb/ip/run_mdu_ip_xsim.sh --expect-fail
```
为什么必须用 **xsim**：Vivado 生成的 IP 网表是 `pragma protect` **加密**的，iverilog/Verilator
不能编译 ⇒ 历次回归只覆盖 `mdu.v` 的**行为分支**（板上跑的是 IP 分支！）。xsim 自带解密密钥，
配合预编译 `unisims_ver` 原语库与 `glbl` 即可把 IP 分支拉进仿真闭环。

---

## 3. 判据（fail-closed；全过才打印唯一 `TB_M5_BOARD: PASS`）

| 条目 | 内容 | 观测点 |
|---|---|---|
| C0 | `PROG_HEX` 载入 `load_err=0` 且非零字 ≥8；UART 捕获队列不溢出；过滤层 `xact_collision_count=0` | TB 内部 |
| C1 | 首笔 AXI 读地址 == `0x1C00_0000` | **上游 AR 通道** |
| C2 | UART 捕获序列出现子串 `RV32GC-M5 board test` | `0x1FE0_01E0` 写捕获 |
| C3 | UART 捕获序列出现子串 `RESULT: RV32GC-M5-OK`（结果行出现后宽限 4 字节即判定确定，可提前收尾；不放宽判据） | 同上 |
| C4 | 捕获到 `0x1FD0F000`（LED）写，且 `+0xF020`/`+0xE000`/`+0xF030` 读各 ≥1 | **上游 AR/AW 握手** |
| C5 | `TIMEOUT_CYCLES` 拍内未出现结果行 ⇒ FAIL | TB 主流程 |
| C6 | **可选（默认关闭）**：`EXPECT_EXTRA` 非空时，UART 捕获序列必须出现该子串（诊断版用 `R2FIX: yes`） | TB 内部 |

`sim_mem_model` 的 `UART_QUEUE_DEPTH` 由本 TB 覆盖为 **65536**（默认 64 装不下每轮约 500–700 字节
的输出；溢出会让 C3 永远不可能命中）。

> ★ **C6 为什么默认关闭**：判据 C0–C5 是上一轮冻结的判定语义（老程序、控制实验都按它判）。
> C6 只在显式传 `EXPECT_EXTRA` 时参与 ⇒ 既给诊断版加了机器判据，又不改变任何历史运行的口径。
> `EXPECT_EXTRA` 是**fail-closed** 的：非空而未命中 ⇒ `FAIL C6`（已用 `ct_selftest` + 假子串实测，见 §4）。

---

## 4. 实跑结果（对应程序版本见各行）

| 运行 | 目标程序 | 结果 |
|---|---|---|
| `ctl_a` | 控制实验 A（自检） | **PASS**（C0–C5；回读 LED `0x00001234`、数码管 `0x00001234`、switch `0x000000A5`、TIMER 增量 `0x141D`、FREQ `0x01F78A40`） |
| `ctl_c` | 控制实验 C | `ticks = 0x0001CD21 = 118 049`（2 000 轮）⇒ **59.02 拍/轮**（9 条指令 ⇒ 6.56 拍/指令） |
| `ctl_b_final2` | **冻结版** `m5_board.S` md5 `b824c9f0…` / hex `43758f32…` 的缩放副本 | **PASS**：C0–C5 全过；串口 568 字节，末行 `step4 timer delta ticks = 118043, cycles/iter = 59, expected ticks = 118000` / `step5 FREQ = 0x01F78A40 (div1e6 = 33 MHz)` / `RESULT: RV32GC-M5-OK`；判定于 **2 754 131 拍**完成（结果行前缀 + 4 字节宽限提前收尾），rc=0 |
| `verify_final_b824c9f0` | 同上（父 Agent 用本 TB 独立复跑） | **PASS**（同口径；日志 `out/verify_final_b824c9f0.log`，唯一 PASS 锚点 1 行） |
| `ctl_b_v4` / `ctl_b_v5` / `ctl_b_v6` | 中间版本 | FAIL→PASS 演进，见 §5 缺陷清单（每个缺陷都是一次实测定位） |
| `spec4m` / `frozen3m` | 冻结程序完整版 | **预算不足**（§5.6）：4M 拍只到横幅第 ~24 字节 |
| `ctl_b_v7_hold` | **R2 修复后**缩放五步程序（`DDR_R_NONHOLD=0`，保持型从设备） | **PASS**：C0–C5 全过；2 920 848 拍 / 626 字节；步④ `timer delta = 118055, cycle delta = 118049, cycles/iter = 59`；步⑤ `FREQ = 0x01F78A40 (div1e6 = 33 MHz)`；`RESULT: RV32GC-M5-OK` |
| `ctl_b_v7_nonhold` | **R2 修复后**同程序 + `DDR_R_NONHOLD=1`（非保持型 R 通道 = MIG 口径） | **PASS**：C0–C5 全过；**2 920 848 拍 / 626 字节，且 UART 字节流与 `ctl_b_v7_hold` 逐字节相同**（`cmp` 为空）⇒ 修复后核不再依赖从设备保持 RDATA |
| `r2_cp_B_oldrtl_nonhold` | **反证**：临时还原旧采样 RTL + `DDR_R_NONHOLD=1` | **FAIL**（预期）：程序在第 ~26 条指令就跑飞（只出 1 个 UART 字节、无 CONFREG 访问、超时）|

### 4.1 第三轮（2026-09-21 · 诊断版：stack-free 打印 + 四个探针 + M 扩展根因）

| 运行 | 配置 | 结果 |
|---|---|---|
| `diag_hold` | 修复后 RTL + 保持型 R（`DDR_R_NONHOLD=0`）；`EXPECT_EXTRA="R2FIX: yes"` | **PASS**：C0–C6 全过，4 322 567 拍完成；`step2.5 … word=0x12345678 re-read=0x12345678 byte=0x5A … R2FIX: yes`；`step2.6 MEXT=00000005 00000009 0000003B 00000031 00000000 00000000 0000002A 40000000 FFFFFFFE -> MEXT: OK`；`step2.7 stack[16B]=30 31 … 46 -> STACKBF: OK`；`step4 timer delta = 118055, cycle delta = 118049, cycles/iter = 59`；`RESULT: RV32GC-M5-OK` |
| `diag_nonhold` | 修复后 RTL + **非保持型** R（`DDR_R_NONHOLD=1` = MIG 口径） | **PASS**：同上逐行相同，**且 UART 字节流与 `diag_hold` 逐字节相同（1168 字符，`cmp` 为空）** |
| `diag_old_nonhold` | **修复前** RTL（`tb/scratch/oldrtl` 只读拷贝，R2 缺陷在位）+ 非保持型 R | **FAIL**（预期，反证）：`step2.5 … word=0x00000000 re-read=0x00000000 byte=0x00 -> R2FIX: no`；`step2.7 stack[16B]=00 00 … -> STACKBF: BAD`；`RESULT: RV32GC-M5-BAD` ⇒ **三个探针确实能抓到旧 bitstream** |
| xsim `run_ip_div_xsim.sh` | 真实 `rv32_div` IP（加密网表，xsim 解密） | **PASS**：59/10 ⇒ `tdata=0x00000005_00000009`、118049/2000 ⇒ `0x0000003b_00000031`、`0x19999999_00000005`（max/10）⇒ **字段序 = {商[63:32], 余数[31:0]}**，`start→done` 实测 37 拍 |
| xsim `run_mdu_ip_xsim.sh` | `mdu` **IP 分支**（`-d RV32GC_USE_VIVADO_IP` + 真实 div/mult IP） | **修复前 15/25 FAIL**（商余数互换，日志 `out/xsim_prefix.log`）⇒ **修复后 25/25 PASS**（`out/xsim.log`） |

> ★ `diag_old_nonhold` 里 `MEXT: OK` 是**预期**的：iverilog 跑的是 `mdu.v` 的**行为分支**
> （function 实现，商余数本来正确）——M 扩展那个缺陷只存在于 **IP 分支**，只能用 xsim 复现
> （见 §4.1 末两行）。这也正是"板上一眼判据"必须放进程序（步2.6）的原因。

---

## 5. 关键发现（按发现顺序；均已由作者修复，冻结版 `b824c9f0` 全部通过）

> 每条都对应一次**仿真实测**：核级仿真在冻结前共拦截 6 处程序缺陷（其中 3 处是"上板必然
> 打印 BAD / 卡死"的 P0）。这正是"上板前核级仿真"的产出。

### 5.1【P0・程序】`puts_dec` 多位数死循环（`b7e5ee14` 版）
`or t6,t6,t5` 用 OR 累积退出条件 ⇒ 商降为 0 后循环不退出，写指针一路 `+1`。
现象：UART 停在 `step1 LED heartbeat, pattern=`（第 5 次心跳 = 16，第一个两位数），
AXI 上出现连续单字节写 `0x08000850…0x0800085B`（越出 DDR3 上限 `0x0800_0000`）。
→ 改为 `bnez t5` + 16 位上限保护。

### 5.2【P1・程序】步④ 的绝对拍数判据不可移植（`b7e5ee14` 版 → **2026-09-21 已改成一致性判据**）
* 历史：判据曾是 `|ticks − MEAS_ITER×XIP_CPI| ≤ ±40%`，其中 `XIP_CPI=59` 是**核级仿真**
  （零延迟内存模型）的标定值。真机 SPI Flash XIP 每笔读要几十拍 ⇒ 该绝对窗口在板上不可移植。
* 现状（2026-09-21 鲁棒化）：步④ 判据 = **`TIMER` 增量 ≡ `rdcycle` 增量**
  （`|Δtimer − Δcycle| ≤ max(256, Δcycle/128)`，两者都在核时钟域每拍 +1），
  外加**健全性窗口** `cycles/iter ∈ [20, 300]`（实测值打印；只把"计数器异常/时钟域差量级"
  钉成 FAIL，**不是**主频判据 —— 主频由步⑤ `FREQ=0x01F78A40` 锚定）。
  `XIP_CPI=59` 降级为**打印参考**，不参与判定；`build.sh` 判据⑧f1–f5 机器核对
  "真的有 `rdcycle` / 健全性窗口量级合理 / 无绝对拍数常量残留"。
### 5.3【P0・程序】步⑤ `t3` 被 `puts_hex8` 破坏（`ca055abf` 之前）
`mv a0,t3; jal puts_hex8` 之后才用 `t3` 判定，而 `puts_hex8` 把 `t3` 当 nibble 计数器（返回 0）
⇒ 判据算的是 `0>>20`。现象 `(high20 = 0 MHz)` + BAD。→ FREQ 改存 **s9**。

### 5.4【P0・程序】FREQ 判据数学错（同上）
`33_000_000 >> 20 = 0x1F = 31`（33 是 `FREQ/10^6`）。旧判据 `>>20 == 33` 恒假。
→ 改为 `>>20 == 31`；`div1e6` 单独用 `udiv` 打印。

### 5.5【P0・程序】汇总判定极性混用（`ca055abf` 版）
`or s10, s8, t4` 把"步④ 好"（s8=1）与"FREQ 坏"（t4=1）相 OR，再 `xori …1` + `beqz s10, total_bad`
⇒ 两子判据**都通过**时反而判 BAD（实测：ticks 118043 在窗口内、FREQ>>20 = 31，却输出 `-BAD`）。
→ 统一"坏 = 1"：`or s10, s11, t4` + `bnez s10, total_bad`。

### 5.6【P1・程序】判定位 `t2` 被紧随的 `udiv` 覆盖（`3649a0ec` 版）
`udiv` 内部用 `t2` 当商寄存器（`li t2,0` … `mv a0,t2`），而步⑤ 打印 `div1e6` 时又调
`udiv`，汇总随即读 `t2` ⇒ 读到的是商（非 0）⇒ 恒 BAD。→ 步④ 坏标志改存 **s11(x27)**。

### 5.7【P1・程序】`udiv` 商位序镜像（`3649a0ec` / `e0b19690`）
"左移被除数 + `1<<i` 位掩码"把商位放反：实测 `udiv(118043,2000) = 0xDC000000 = 3690987520`
（真值 59 的位序镜像）、`udiv(33000000,1000000) = 0x84000000 = 2214592512`（真值 33 的镜像）。
→ 改为教科书恢复余数法（`q<<=1; q|=1`，无位掩码），作者并用隔离程序在核上实测 59/3/33 全对。

### 5.8【P0・RTL 已修复】M 级 AXI 读在 **R 握手后第 2 拍** 才取 `rdata`（M5 上板实测暴露）
**上板现象（用户实测）**：串口字符串（Flash XIP ⇒ 走 L1D 填充/取指通路）全部正常、
CONFREG 的 FREQ 十六进制正常（`confreg_syn` 寄存器保持型），但 **DDR3 的 `.data/.bss`
十进制打印全乱**（`ticks=000000000000000""`、`cycles/iter=?`、`div1e6=…3`），
最终 `RESULT: RV32GC-M5-BAD` 并循环重跑 —— 因为"十进制打印"要把数字先存进**栈缓冲**
（`sp` 在 DDR3 顶），再用 `lbu` 读回来打印；而 DDR3 数据访问走 **MDTA（uncached 单 beat AXI）**。

* **根因链（行号级，修复前）**：
  `axi_master_ctrl.v:218` `r_fire = r_go & m_rvalid & m_rready`（唯一握手点）
  → `:257` `rdata_valid = r_fire` / `:258` `rdata_data = m_rdata`（**组合直通，未锁存**）
  → `:385` 握手后 `state_q <= ST_DONE` → `:296` `done` = ST_DONE 拍（握手后第 1 拍）
  → `core_top.v:2986` `axi_done_q <= 1'b1`（再打一拍 = **握手后第 2 拍**）
  → `core_top.v:949` `axi_rdata_q = rdata`（**实时总线**）
  → `core_top.v:2221` `m_axi_ld_data = ld_extract(axi_rdata_q, …)`
  → `core_top.v:4129` `m_rd_data_q <= m_axi_ld_data`（就在 `axi_done_q` 那一拍）。
  对照（正确）：cache 填充 `core_top.v:2914 axi_fill_valid = axi_rdata_valid`、
  XIP 取指字捕获 `:3702`、AMO 读相 `:2035` 都在**握手拍**取数。
* **为什么仿真全绿**：`sim_mem_model`（以及本 TB 的过滤层默认口径）在 R 握手之后**继续保持**
  RDATA ⇒ 晚 2 拍采样仍然读到同一值。**上板 MIG 不是这样**：Xilinx MIG 的 `app_rd_data`
  只在 `app_rd_data_valid` 拍有效，握手后总线上会是"别的事务的数据"。
* **修复（2026-09-21）**：
  * `rtl/axi/axi_master_ctrl.v`：新增 **`rdata_hold`**（`r_fire` 拍锁存 `m_rdata`、
    保持到下一次握手）。`rdata_valid`/`rdata_data` 的组合直通语义**保持不变**
    （握手套消费者逐拍等价）。
  * `rtl/top/core_top.v`：`axi_rdata_q = rdata`（实时直通）**删除**；M 级数据读
    （`m_axi_ld_data`，`core_top.v:2238/2247`）与 AXI 通路的 AMO/LR/SC 读相
    （`lsu_amo_rdata_src`，`core_top.v:2052`）一律改取 **`axi_rdata_hold`**。
    逐拍论证见 `axi_master_ctrl.v` §5 的"★★ R 数据时序论证"。
* **证据链（本目录 + `fpga/scratch/`）**：
  1. **复现（非保持型 R 模型）**：`sim/tb/tb_arch_test.sv` 新增 `R_HOLD_IDLE`（0 = RDATA 只在
     `rvalid & rready` 拍有效）。修复前 `R_HOLD_IDLE=0` 跑 `I-add-00` ⇒ **FAIL**：
     签名 394/15412 行与 Spike 分歧（`dut=deadbeef` vs `spike=c70e0523`）、未到 HTIF 终止点；
     同一份代码 `R_HOLD_IDLE=1` ⇒ PASS（0 分歧）。
  2. **修复后**：`R_HOLD_IDLE=0` 跑 `I-add-00`/`Zaamo-amoadd.w-00`/`Zalrsc-lr.w-00`/
     `M-mul-00`/`D-fadd.d-00`/`PMPZaamo_cfg_wr-00` ⇒ **全部 0 分歧 + 唯一 PASS 锚点**。
  3. **反证（cp 备份 → 临时还原旧采样 → 必 FAIL → 恢复 + md5 自证）**：
     `bash fpga/scratch/r2_counterproof.sh`（不使用 git checkout/stash/reset/clean）。
  4. **上板程序级双模型**：本 TB 的 `DDR_R_NONHOLD=1` 下，缩放五步程序
     修复前 ⇒ FAIL（跑飞到 26 条指令就停、只出 1 个 UART 字节），修复后 ⇒ PASS。
* **影响面（上板）**：DDR3 的 `.data/.bss` 读（含栈上的 `ra`/数字缓冲）、平台 MMIO 读
  （本核 2A 的数据侧**全部**经 MDTA：`mmio_route` 把除 CLINT/PLIC/XIP 外的 PA 判为 ROUTE_AXI）。
  CONFREG 侧因 `confreg_syn` 保持而"看起来正常"，是这次缺陷**被误判为"只是打印问题"**的原因。

### 5.6【可行性】完整版端到端判定 = 预算不足（≈7.7×10⁷ 拍 ≈ 9.3 小时）
* 实测吞吐：本核 XIP 直连取指（每 4 B 一次单 beat AXI 读）⇒ 循环里 ≈8.6 拍/指令、
  6.15 拍/次 AXI 读（`out/cal200k.log`：cycles=200 000、提交指令 23 247、AR 32 541）；
  `delay_loop` 实测 59.02 拍/轮（§4 `ctl_c`）。
* 一轮主循环：UART ≈520 字符 ×(LSR 64 轮 ×5 指令 + 开销 ≈332 指令 ≈2.9e3 拍) ≈ 1.5e6
  + `DELAY_HB_TICKS`×8 + `DELAY_SW_TICKS` = **7.4e7** + 步④ 1.18e5 ⇒ **≈7.7e7 拍**。
* `iverilog` 对本核的吞吐 **2.3–2.8e3 拍/秒** ⇒ ≈9.3 小时墙钟（不可承受）。
* 替代方案（本目录已落地，结论可辩护）：**只缩放两个与判据无关的挂钟常量**的副本 +
  机器核对的等价性论证（`ctrl/diff_equiv.py`：差异仅 4 个字，都是 `li` 立即数对）
  ⇒ 一轮 2.79e6 拍（≈20 分钟）跑完，**步④/步⑤ 的判据与冻结程序逐字相同**。

---

## 6. 未覆盖 / 遗留
* 未做：完整版（不缩放）的端到端判定（§5.6，预算不足）。
* 未做：UART 的 LSR/IIR 寄存器建模（本 TB 按任务口径只截 CONFREG；LSR 读回 0 只影响
  `puts_char` 的等待时长，不影响判定语义 —— 作者已把等待上限降到 64）。
* 未做：DDR3 大范围访存 / 中断（M5 程序不使用）。
* 程序版本沿革（本任务期间作者并发修改）：`m5_board.S` md5 依次为
  `b7e5ee14…` → `503dfae4…` → `3c8a3a37…` → `ca055abf…`（TB 每轮结论均标注对应 md5）。

## 7. 红线不变式（逐轮记录）

```bash
find rtl -name '*.v' | sort | xargs md5sum | md5sum          # 仅 *.v
find rtl \( -name '*.v' -o -name '*.vh' \) | sort | xargs md5sum | md5sum   # *.v + *.vh
#   ① R2 修复轮（2026-09-21）：*.v = ef20b2c0… → 0e20b6182e3ad96ae8d70680c2b51aa8（38 个 .v）
#      唯一变化 = `rtl/axi/axi_master_ctrl.v`（新增 rdata_hold 锁存输出）
#                 与 `rtl/top/core_top.v`（数据读/AMO 读相改取锁存值；删除实时直通线）。
#   ② 第三轮（2026-09-21，本轮）：*.v = 0e20b618… → **ce31b3c8c51fd813c6437ba9af29e54a**
#      （*.v + *.vh = 66e3225645b6f29375c786fe166448d6）
#      **唯一变化** = `rtl/exec/mdu.v`（IP 分支 div_gen 输出字段序：{余数,商} → {商,余数}；
#      行为分支一字未动）。两个只在 IP 分支生效的 wire 改写 + 注释同步。
```

* 本轮**故意**改了上述两个 RTL 文件（R2 根因修复，任务授权范围内）；
  `rtl/**` 其余 36 个文件、`sim/arch_test/**`、`scripts/**` 一字未动。
* 本轮新增/修改的 TB 侧：本目录 `confreg_axi_filter.v`（+`DDR_R_NONHOLD` 开关）、
  `tb_m5_board.sv`（参数透传）、`run_tb.sh`（环境变量透传）、本 README；
  `sim/tb/tb_arch_test.sv` 新增 `R_HOLD_IDLE` 开关（默认 1 = 历史保持口径，
  **判据语义不变**，只用于复现/反证）。
* 本轮新增脚本（不改判据）：`fpga/scratch/r2_repro_arch_test.sh`（arch-test 单例复现）、
  `fpga/scratch/r2_counterproof.sh`（cp 备份→临时还原旧采样→必 FAIL→恢复+md5 自证）、
  `fpga/scratch/r2_full_regression.sh`（判据 3 的六项回归入口）。
* 被依赖的共享件 md5（未变，供复核）：

  | 共享件 | md5 |
  |---|---|
  | `sim/tb/sim_mem_model.sv` | `8deed3ad15b2547d5154ad33fc31e06f` |
  | `sim/tb/uart_ser_decoder.sv` | `7330c3ca5912556c2403d56ff4e692a0` |
  | `scripts/regress.sh` | `2137946e676e218849da7ba6d7021529` |
