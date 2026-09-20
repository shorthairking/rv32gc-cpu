# M5 上板前核级仿真验证件（`rv32gc-cpu/sw/m5_board/tb/`）

在 **rv32gc-cpu 核 RTL** 上对 `sw/m5_board` 的 M5 上板程序做核级仿真，一次跑完给出
**未捕获即失败**的判定（唯一 `TB_M5_BOARD: PASS` 行 / 否则 `FAIL <条目>` + `$fatal`）。
只读 `rtl/**`、`sim/**`、`sw/m5_board/*.S`、`build.sh`；**只写本目录**。

---

## 1. 文件清单

| 文件 | 作用 |
|---|---|
| `confreg_axi_filter.v` | **AXI4 地址过滤层 + 上板 CONFREG 行为模型**。插在 `core_top`（主）与 `sim_mem_model`（从）之间：地址落在 `0x1FD0_0000–0x1FD0_FFFF` 的读/写自答，其余**逐字段透传**。实现 `+0xF000` LED（读写）、`+0xF010` 数码管（读写）、`+0xF020` switch（只读，`SWITCH_VAL=8'hA5`）、`+0xF030` FREQ（只读，`32'd33000000`）、`+0xE000` TIMER（自由运行、写任意值清零）。读数据在 **AR 握手拍寄存并保持**（= 上板 `confreg_syn.v:295` 行为；见 §5.5）。输出判据/诊断观测：首笔 AR、五寄存器访问标志、AXI 轨迹、路由一致性计数。 |
| `tb_m5_board.sv` | **顶层 TB**：48 端口逐字例化 `core_top` + 过滤层 + `sim_mem_model`；时钟半周期 15.1515 ns（周期 30.303 ns ≈ 33.0 MHz，上板口径）；复位 20 拍后负沿释放；`intrpt=0`；UART 子串匹配（滚动窗口，逐字节增量，支持"结果行前缀 + 宽限字节"提前收尾）；AXI 区域统计与轨迹直方图；判据 C0–C5、PASS/FAIL 输出。 |
| `run_tb.sh` | 编译（`iverilog -g2012 -I rtl/pkg -I <repo>` + `rtl/**/*.v` 全量）+ 运行（`stdbuf` 行缓冲）+ 三重判定（vvp 退出码 / PASS 锚点恰 1 行 / 无 `FAIL` 字样）；日志落 `tb/out/`；**失败即非零退出**。 |
| `ctrl/ct_selftest.S` | **控制实验 A（测试台自检）**：独立编写的最小程序，点亮"CONFREG 五寄存器读写 + UART 捕获 + 复位取指"。预期 **PASS** —— 证明判定链本身有效。 |
| `ctrl/ct_delay_probe.S` | **控制实验 C**：用**与 m5 逐字相同的 `delay_loop`**（7×`nop`+`addi`+`bnez` = 9 条指令）+ CONFREG TIMER 实测 `cycles/iter`，给步④ 标定常量 `XIP_CPI` 一个硬数字。 |
| `ctrl/make_scaled.py` | 生成**控制实验 B**：把冻结程序只做**与判据无关**的挂钟常量缩放（`DELAY_HB_TICKS`、`DELAY_SW_TICKS`），其余逐字不动；每处替换断言"恰好命中 1 次"。 |
| `ctrl/diff_equiv.py` | **等价性机器证据**：冻结 hex 与缩放 hex 逐字比对，列出全部差异字并反汇编，断言差异 ≤ 8 字。 |
| `ctrl/build_ctrl.sh` | 用与 `sw/m5_board/build.sh` 同口径的工具链/链接参数构建三个控制程序。 |
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
`UART_PRINT_MAX`、`R_STICKY`（默认 **1**）、`RD_TRACE_WINDOW`（默认 0）。

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

`sim_mem_model` 的 `UART_QUEUE_DEPTH` 由本 TB 覆盖为 **65536**（默认 64 装不下每轮约 500–700 字节
的输出；溢出会让 C3 永远不可能命中）。

---

## 4. 实跑结果（对应程序版本见各行）

| 运行 | 目标程序 | 结果 |
|---|---|---|
| `ctl_a` | 控制实验 A（自检） | **PASS**（C0–C5；回读 LED `0x00001234`、数码管 `0x00001234`、switch `0x000000A5`、TIMER 增量 `0x141D`、FREQ `0x01F78A40`） |
| `ctl_c` | 控制实验 C | `ticks = 0x0001CD21 = 118 049`（2 000 轮）⇒ **59.02 拍/轮**（9 条指令 ⇒ 6.56 拍/指令） |
| `ctl_b_final2` | **冻结版** `m5_board.S` md5 `b824c9f0…` / hex `43758f32…` 的缩放副本 | **PASS**：C0–C5 全过；串口末行 `step4 timer delta ticks = 118043, cycles/iter = 59, expected ticks = 118000` / `step5 FREQ = 0x01F78A40 (div1e6 = 33 MHz)` / `RESULT: RV32GC-M5-OK`；判定于 **≈2.0–2.8e6 拍**完成（结果行前缀 + 4 字节宽限提前收尾） |
| `verify_final_b824c9f0` | 同上（父 Agent 用本 TB 独立复跑） | **PASS**（同口径；日志 `out/verify_final_b824c9f0.log`） |
| `ctl_b_v4` / `ctl_b_v5` / `ctl_b_v6` | 中间版本 | FAIL→PASS 演进，见 §5 缺陷清单（每个缺陷都是一次实测定位） |
| `spec4m` / `frozen3m` | 冻结程序完整版 | **预算不足**（§5.6）：4M 拍只到横幅第 ~24 字节 |

---

## 5. 关键发现（按发现顺序；均已由作者修复，冻结版 `b824c9f0` 全部通过）

> 每条都对应一次**仿真实测**：核级仿真在冻结前共拦截 6 处程序缺陷（其中 3 处是"上板必然
> 打印 BAD / 卡死"的 P0）。这正是"上板前核级仿真"的产出。

### 5.1【P0・程序】`puts_dec` 多位数死循环（`b7e5ee14` 版）
`or t6,t6,t5` 用 OR 累积退出条件 ⇒ 商降为 0 后循环不退出，写指针一路 `+1`。
现象：UART 停在 `step1 LED heartbeat, pattern=`（第 5 次心跳 = 16，第一个两位数），
AXI 上出现连续单字节写 `0x08000850…0x0800085B`（越出 DDR3 上限 `0x0800_0000`）。
→ 改为 `bnez t5` + 16 位上限保护。

### 5.2【P1・程序】步④ 的 `TPI_SIG`/`XIP_CPI` 没有余量（`b7e5ee14` 版）
9 条指令的循环在单发射核上 ≥9 拍，加取分支重定向 ≥10 拍；旧 `TPI_SIG=8.0`（窗口 [6,10]）无余量。
→ 改为 **TIMER 绝对时刻等待 + 实测标定** `XIP_CPI=59`、判据 `|ticks − 118000| ≤ 47200`。
★ 上板提醒：59 是**零延迟仿真内存模型**下的**下界**；真机 SPI XIP 更慢，换算窗口上沿 = CPI 82.6。

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

### 5.8【P1・RTL 已登记风险】M 级 AXI 读在 **R 握手后第 2 拍** 才取 `rdata`
* 代码链（只读引用，未改 RTL）：
  `axi_master_ctrl.v:218` `r_fire = r_go & m_rvalid & m_rready`（**唯一的采样点**）
  → `:257` `rdata_valid = r_fire` → `:385-386` `if (r_fire) if (r_last_beat) state_q <= ST_DONE;`
  → `:296` `done = (state_q == ST_DONE)`（末拍 r_fire 的**下一拍**）
  → `core_top.v:2986` `axi_done_q <= 1'b1`（再打一拍）
  → `core_top.v:949` `axi_rdata_q = rdata`（**实时总线**）
  → `core_top.v:2221` `m_axi_ld_data_ext = ld_extract(axi_rdata_q, …)`
  → `core_top.v:4129` `m_rd_data_q <= m_axi_ld_data`（**在 axi_done_q 那一拍**）。
  对照：cache fill 通路 `core_top.v:2914` `axi_fill_valid = axi_rdata_valid` 在**握手拍**取数（正确）。
* 逐拍实测（`out/ctl_a_sticky.log` + `out/ctl_a_nosticky.log`，`TB_M5_RDTRACE`）：
  ```
  +1 rvalid=0 rready=0 rdata=0x00001234 | axi_done_q=0 axi_owner_q=5 m_state_q=11 m_rd_data_q=0x1c000040
  +2 rvalid=0 rready=0 rdata=0x00001234 | axi_done_q=1 axi_owner_q=0 m_state_q=11 m_rd_data_q=0x1c000040
  +3 rvalid=0 rready=0 rdata=0x00001234 | axi_done_q=0 axi_owner_q=0 m_state_q=0  m_rd_data_q=0x00001234  ← R_STICKY=1 正确
  ```
  `R_STICKY=0`（从设备握手后立刻换数据）同一拍序：`rdata=0x1FD0FFB7`（下游 `sim_mem_model`
  当时正在取指的指令字）⇒ `m_rd_data_q=0x1FD0FFB7`（**错**），控制程序打印的
  LED/SEG/SWITCH/FREQ 全错；`R_STICKY=1` 全部正确。
* 影响：当前上板配置大概率无症状（`confreg_syn.v:289-296` 的 `s_rdata` 是寄存器、下一笔 AR 前一直保持；
  DDR 侧只用 cache fill，采样点正确），但这是**主设备侧 AXI4 协议偏差**：换互连 IP / 流水化桥
  即会让 MMIO load 读到别的事务的数据。建议（RTL 冻结，仅登记）：在 `axi_rdata_valid` 拍把
  `rdata` 锁存进 `axi_rdata_q`，M 级改从该寄存器取数。

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

## 7. 红线不变式（动手前后一致）
```bash
find rtl -name '*.v' | sort | xargs md5sum | md5sum   # 前/后均为 ef20b2c0d17fbd07016b44bdd05dd822（38 个 .v）
find sim scripts -type f | sort | xargs md5sum | md5sum  # 前/后均为 e9c0381b766210c352b3779a92649232
```
本任务只新建/修改 `sw/m5_board/tb/**`；`rtl/**`、`sim/**`、`sw/m5_board/m5_board.S`、
`build.sh` 全程未改。
