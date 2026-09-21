# R2 修复交付报告 —— M5 上板 uncached 数据读"晚拍采样"缺陷（2026-09-21）

> 任务：修复 M5 上板发现的缺陷（核在 AXI R 握手后第 2 拍才采样读数据 ⇒ 真实 MIG 下
> uncached 数据读全部读到垃圾 ⇒ `.data/.bss`（DDR3）常量/变量损坏、十进制打印全乱）。
> 交付：① 根因证明 ② 最小修 RTL ③ 重建 bitstream 与上板程序 ④ 全量回归。

---

## 0. 结论（一句话）

根因成立且已修复：核内唯一总线主端口在 **R 握手拍**才拿得到 `m_rdata`，而 M 级 uncached
数据读（MDTA）的完成判定在 **握手后第 2 拍**（`axi_master_ctrl` 的 `done` →
`core_top` 的 `axi_done_q`），原实现取的是**实时总线** ⇒ 从设备一旦不保持 RDATA
（上板 MIG / 流水化互连 / 严格 AXI4），读回的就是别的事务的数据。
修复 = 在 `axi_master_ctrl` **新增 `rdata_hold`（`r_fire` 拍锁存）**，并把
`core_top` 里**所有"完成晚于握手拍"的消费者**（M 级数据读 + AXI 通路 AMO/LR/SC 读相）
改取锁存值，同时**删除**"实时直通"线（结构上杜绝再次误用）。

---

## 1. 根因链（行号级，修复前 = commit `68ff5fd`）

```
rtl/axi/axi_master_ctrl.v:218   r_fire  = r_go & m_rvalid & m_rready     （唯一 R 握手点）
rtl/axi/axi_master_ctrl.v:257   rdata_valid = r_fire                     （握手拍脉冲）
rtl/axi/axi_master_ctrl.v:258   rdata_data  = m_rdata                    （★ 组合直通，未锁存）
rtl/axi/axi_master_ctrl.v:385   if (r_fire) if (r_last_beat) state_q <= ST_DONE
rtl/axi/axi_master_ctrl.v:296   done = (state_q == ST_DONE) & ~split_pending_q   （握手后第 1 拍）
rtl/top/core_top.v:2986         if (axi_ctrl_done) axi_done_q <= 1'b1     （再打一拍 = 第 2 拍）
rtl/top/core_top.v:949          assign axi_rdata_q = rdata;              （★ 实时总线）
rtl/top/core_top.v:2221         m_axi_ld_data_ext = ld_extract(axi_rdata_q, …)
rtl/top/core_top.v:4129         if (~axi_done_wr_q) m_rd_data_q <= m_axi_ld_data  （★ 第 2 拍才采样）
```

对照（本来就正确、**未改动**）：

| 通路 | 采样点 | 位置 |
|---|---|---|
| L1I/L1D cache 行填充 | **握手拍** | `core_top.v:2940 ax_fill_valid = axi_rdata_valid` |
| XIP 直连取指字捕获 | **握手拍** | `core_top.v:3728` |
| AXI AMO/LR 读相数据源（修复前） | 实时总线（消费在第 2 拍 ⇒ **也是缺陷**） | `core_top.v:2035` |

**上板现象为什么"只坏十进制"**：
* 串口字符串走 XIP（`ROUTE_XIP` ⇒ L1D 服务）与取指通路 ⇒ 正确；
* `confreg_syn` 的读数据是**寄存器保持型**（`confreg_syn.v:289-296`）⇒ FREQ 十六进制正确；
* 十进制打印要先把数字写进**栈缓冲**（`sp = 0x07FF_FFF0`，在 DDR3）再用 `lbu` 读回来；
  `puts_str`/`puts_hex8` 的 `ra` 也存栈 —— 而 **DDR3 数据访问全部走 MDTA**
  （`mmio_route` 把除 CLINT/PLIC/XIP 外的 PA 判为 `ROUTE_AXI`；2A 里 L1D 只服务 XIP/PTE）
  ⇒ 读到的是总线上的"别的东西"（MIG 下即垃圾）⇒ 数字全乱、判定 `RESULT: …-BAD`。

**仿真为什么全绿**：`sim_mem_model`（与 TB 过滤层默认口径）在 R 握手后**继续把 RDATA 留在
总线上**，晚 2 拍采样仍读到同一值 ⇒ 掩盖了缺陷。

---

## 2. 复现证据（修复前）

### 2.1 arch-test（非保持型 R 通道模型；`sim/tb/tb_arch_test.sv` 新增 `R_HOLD_IDLE`）

```bash
# 保持型（TB 历史口径）—— 修复前：PASS
bash fpga/scratch/r2_repro_arch_test.sh I-add-00 1 pre_fix_hold1
#   R2_REPRO(pre_fix_hold1): 签名与 Spike 参考完全一致（R_HOLD_IDLE=1；rc=0）  分歧=0
# 非保持型（严格 AXI4：RDATA 只在 rvalid&rready 拍有效，其余拍 = 0）—— 修复前：FAIL
bash fpga/scratch/r2_repro_arch_test.sh I-add-00 0 pre_fix_nonhold
#   R2_REPRO(pre_fix_nonhold): FAIL …（vvp_rc=1 分歧=394/15412）
#   首个分歧 #2 addr=0x80016dd4 dut=deadbeef spike=3d120729
#   例：dut=deadbeef（测试预填标记，说明"读-改-写"没写回正确值）vs spike=3d120729
#   ⇒ 未到 HTIF 终止点（300000 拍超时）
```
日志：`fpga/scratch/out/pre_fix_hold1.log` / `pre_fix_nonhold.log`。

### 2.2 M5 上板程序级（`sw/m5_board/tb` + `DDR_R_NONHOLD=1`）

* 修复前 + `DDR_R_NONHOLD=0`：`ctl_b_final2`（冻结版缩放副本）**PASS** ← 缺陷被模型掩盖。
* 修复前 + `DDR_R_NONHOLD=1`（反证脚本内）：**FAIL** —— 程序只提交 26 条指令、只出 1 个 UART
  字节就"跑飞"（第一次子程序返回要 `lw ra, 12(sp)`，读到 0 ⇒ `ret` 跳到 0 ⇒ 非法指令陷阱
  自环）。日志：`sw/m5_board/tb/out/r2_cp_B_oldrtl_nonhold.log`（RTL 指纹 `ef20b2c0…` = 修复前）。

### 2.3 逐拍铁证（同一实验，修复前 vs 修复后）

控制实验 A（`ct_selftest.hex`）+ `R_STICKY=0`（CONFREG 侧也不保持 ⇒ 总线上是"别的事务的字"），
`RD_TRACE_WINDOW=14` 探针给出同一拍序：

| 拍 | 修复前 | 修复后 |
|---|---|---|
| +1 | `axi_done_q=0  m_rd_data_q=0x1c000040` | 同左 |
| +2 | `axi_done_q=1  m_rd_data_q=0x1c000040` | 同左 |
| **+3（采样拍）** | `axi_done_q=0  m_rd_data_q=0x1fd0ffb7` ← **读到的是 XIP 取指指令字（垃圾）** | `axi_done_q=0  m_rd_data_q=0x00001234` ← **CONFREG 正确值** |

（该拍 `rdata=0x1fd0ffb7` —— 实时总线确实在驱动"别的事务的数据"；修复后核取的是握手拍锁存值。）
日志：`sw/m5_board/tb/out/ctl_a_nosticky.log`（修复前，2026-09-20）与
`sw/m5_board/tb/out/r2_ctl_a_nosticky.log`（修复后，PASS）。

---

## 3. 修复 diff（唯一真源 + 结构约束）

### 3.1 `rtl/axi/axi_master_ctrl.v`
* 新增输出端口 **`rdata_hold`**（`DATA_W` 宽）；
* 新增寄存器 `rdata_hold_q`：**唯一赋值点 = `if (r_fire) rdata_hold_q <= m_rdata;`**（复位清 0）；
* `rdata_valid`/`rdata_data` **语义不变**（仍是"握手拍脉冲 + 组合直通"），握手套消费者
  （cache 填充 / XIP 取指 / 填充对 MSHR）逐拍等价；
* 头注 + §4/§5 增加"R 数据锁存"与**逐拍时序论证**（为什么第 N+2 拍读到的仍是本笔数据：
  下一次 `r_fire` 最早在第 N+4 拍）。

### 3.2 `rtl/top/core_top.v`
* **删除** `assign axi_rdata_q = rdata;`（实时直通）与 `axi_rdata_q` 线网；
* 新增 `wire [31:0] axi_rdata_hold;` 并接到控制器的 `.rdata_hold()`；
* `m_axi_ld_data`（`core_top.v:2245/2248`，M 级 MDTA 读结果 = `m_rd_data_q`/`m_rd_hi_q` 的源）
  改取 `axi_rdata_hold`；
* `lsu_amo_rdata_src`（`core_top.v:2052`，AXI 通路 AMO/LR/SC 读相）改取 `axi_rdata_hold`；
* 相关注释同步（含"核内不允许在 R 握手拍之外取实时 `rdata`"的结构性口径）。

**改动范围**：`git status --porcelain rtl/` = 恰好上述两个文件；其余 36 个 `.v` 与 `pkg/*.vh`
一字未动（`verify_m5.sh` V5a 已把"允许改动的白名单"写死）。

### 3.3 逐拍等价性论证（保持型从设备）
修复前：第 N+2 拍写 `m_rd_data_q <= m_rdata(N+2 拍的总线值)`；
修复后：第 N+2 拍写 `m_rd_data_q <= rdata_hold_q = m_rdata(第 N 拍握手值)`。
保持型从设备在"第 N 拍握手到第 N+2 拍"之间**不改动 RDATA**（下一次 AR 最早第 N+2 拍，
R 数据更晚）⇒ 两式**写到同一个值**，核内后续状态逐拍相同。
机器证据：`fpga/scratch/r2_equiv_check.sh` —— 回归重跑的 **317 例** arch-test 签名与
"修复前快照"逐字节比对：**317 一致 / 0 分歧**（快照共 441 例，其余 124 例本次未重跑，不计入）。

---

## 4. 修复后验证

### 4.1 arch-test（非保持型模型，修复后全过）

| 用例 | 结果 |
|---|---|
| `I-add-00` | 0 分歧 + 唯一 PASS 锚点 |
| `Zaamo-amoadd.w-00`（AMO 读/写相） | 0 分歧 |
| `Zalrsc-lr.w-00`（LR/SC） | 0 分歧 |
| `PMPZaamo_cfg_wr-00` | 0 分歧 |
| `M-mul-00` | 0 分歧 |
| `D-fadd.d-00`（36032 字签名） | 0 分歧 |

命令：`bash fpga/scratch/r2_repro_arch_test.sh <用例> 0 post_nonhold_<用例>`；日志同目录。

### 4.2 M5 上板程序核级仿真（双模型）

```
ctl_b_v7_hold   （DDR_R_NONHOLD=0）: TB_M5_BOARD: PASS   cycles=2920848 uart_bytes=626
ctl_b_v7_nonhold（DDR_R_NONHOLD=1）: TB_M5_BOARD: PASS   cycles=2920848 uart_bytes=626
                                    ⇒ UART 字节流 cmp 为空（两个模型逐字节相同）
```
五步输出（两模型完全相同，十进制全部正常）：

```
RV32GC-M5 board test (chiplab / xc7a200tfbg676-2) @ 33MHz
step1 LED heartbeat, pattern=1 / 2 / 4 / 8 / 16 / 32 / 64 / 128
step2 UART output alive; sequence = LED -> UART -> switch -> timer -> FREQ
step3 switch readback = 165
step4 timer delta = 118055, cycle delta = 118049, cycles/iter = 59, window = 20..300, sim-calib = 59 cycles/iter (informational only)
step5 FREQ = 0x01F78A40 (div1e6 = 33 MHz)
RESULT: RV32GC-M5-OK
```

### 4.3 反证（cp 备份 → 临时还原旧采样 → 必 FAIL → 恢复 + md5 自证）

```bash
bash fpga/scratch/r2_counterproof.sh
#  A) 旧采样 + 非保持型 arch-test ⇒ FAIL（分歧 394/15412）        ✅ 预期
#  B) 旧采样 + M5 TB DDR_R_NONHOLD=1 ⇒ FAIL（rc=1，0 个 PASS 锚点） ✅ 预期
#  C) 恢复自证：axi=1f6d45df253f173d20176dd57d68892e core_top=5ff74ab279de031fb5b7fba7e0b10ee8
#  R2_COUNTERPROOF: OK
```
（全程未用 `git checkout/stash/reset/clean`；旧版本用 `git show HEAD:<path>` 取出。）

### 4.4 功能回归（判据 3）

见 §5 表格（`fpga/scratch/r2_full_regression.sh`）。

### 4.5 step④ 鲁棒化（判据 5）

* 旧口径：`|ΔTIMER − 2000×59| ≤ ±40%`（59 = **零延迟仿真**标定值）⇒ 真机 Flash 时序下不可移植。
* 新口径（**不用任何绝对拍数**）：
  * **判据 A（主）**：`|timer delta − cycle delta| ≤ max(256, cycle delta/128)`，其中
    `cycle delta` 来自 `rdcycle`（`cycle` CSR = `core_top.v:3555 cycle_cnt_r` 每拍 +1）。
    两者都在核时钟域 ⇒ 同窗口增量必须相等；**对 SPI Flash 取指延迟免疫**。
  * **判据 B（健全性）**：`cycles/iter ∈ [20, 300]`（现场实测值打印；只把"计数器异常/时钟域差
    一个量级"钉成 FAIL，**不是**主频判据 —— 主频由步⑤ `FREQ=0x01F78A40` 锚定）。
* 构建侧护栏（`sw/m5_board/build.sh` 判据⑧f1–f5）：源码必须含 `rdcycle`、反汇编必须含
  `csrrs …,cycle,x0`、窗口常量量级合理（`LO ≥ 9`、`HI ≤ 400`）、不得残留 `TGT_TICKS/TGT_TOL`。
* 工具链：`-march=rv32im → rv32im_zicsr`（只读 `cycle`，不写任何 CSR）。

---

## 5. 回归与时序（判据 3 / 6 / 7）

| 项 | 命令 | 结果 |
|---|---|---|
| 单元回归 | `./scripts/regress.sh` | **`REGRESS: 23/23 PASS`** |
| arch I | `./sim/arch_test/run.sh --group rv32i/I --jobs 16` | **39/39** |
| arch F | `--group rv32i/F --jobs 16` | **80/80** |
| arch D | `--group rv32i/D --jobs 16` | **106/106** |
| arch PMP | `--group 'tests/priv/PMP*' --jobs 16` | **63/63** |
| arch Sv | `--group Sv --jobs 16` | **29/29** |
| 核级时序（60 MHz / 16.667 ns） | `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667` + `impl.tcl 16.667` | **综合 WNS +0.556 / 布线 WNS +0.232 ns，TNS 0，失败端点 0**，`All user specified timing constraints are met` |
| 平台 bitstream（33 MHz） | `chiplab/fpga/loongson/2023.2/run_rv32gc_build.sh bit` | **`RESULT_RV32GC_BUILD: OK STAGE=bit`**；WNS **+0.978 ns** / TNS 0 / 失败端点 0 / WHS +0.054 / 失败端点 0 |

汇总日志：`fpga/scratch/out/regression_r2.log`（逐项）、`fpga/scratch/out/timing_r2.log`、
`fpga/scratch/out/bitstream_r2.log`。

---

## 6. 产物与 md5（判据 7/8）

| 产物 | 路径 | md5 |
|---|---|---|
| RTL `axi_master_ctrl.v` | `rv32gc-cpu/rtl/axi/axi_master_ctrl.v` | `1f6d45df253f173d20176dd57d68892e` |
| RTL `core_top.v` | `rv32gc-cpu/rtl/top/core_top.v` | `5ff74ab279de031fb5b7fba7e0b10ee8` |
| 全树 RTL 指纹（`*.v`） | — | `0e20b6182e3ad96ae8d70680c2b51aa8`（修复前 `ef20b2c0…`） |
| Flash 镜像 | `rv32gc-cpu/sw/m5_board/out/m5_board.bin` | `b82be1fc4f67d029232a6409f6941b33` |
| 仿真 hex | `rv32gc-cpu/sw/m5_board/out/m5_board.hex` | `fe6caa3d63b0a75a8783d2f849cd5715` |
| 上板程序源码 | `rv32gc-cpu/sw/m5_board/m5_board.S` | `835a486e59791a9cca043d51a3b10a61` |
| M5 交付自检 | `bash sw/m5_board/verify_m5.sh` | **`V5: ALL CHECKS PASS`**（含 V5a 白名单：rtl/ 改动恰好是两个 R2 文件）|
| bitstream | `chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit` | `f375baa04d8e495cfbb8c5df2042adf4`（9 730 756 B） |
| FPGA 配置 bin | 同目录 `soc_top.bin` | `c448dfdc982608344dee5c6bd8e4ea7c`（9 730 652 B） |

---

## 7. 用户重烧步骤

（同 `sw/M5-board-runbook.md` §3；本轮只需换两个文件）

1. **bitstream（JTAG 直下，验证用）**：Windows 侧 Vivado Hardware Manager → Open Target →
   Program Device → 选 `chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit`。
2. **程序镜像（固化到 SPI Flash）**：先用官方 `programmer_by_uart.bit` 按 runbook §3 方式 B
   把 **新的** `sw/m5_board/out/m5_board.bin` 写入 Flash 地址 0（= 核的 `0x1C00_0000`），
   再回到第 1 步下载新 bitstream（或断电重上电）。
3. 串口 115200 8N1 观察五步；本轮**新增可见变化**：步④ 打印格式改为
   `step4 timer delta = …, cycle delta = …, cycles/iter = …, window = 20..300, sim-calib = 59 cycles/iter (informational only)`。

---

## 8. 遗留 / 风险

1. **本轮只修了"采样点"**：AXI 主端口仍不实现 R 通道背压（`rdata_ready` 输入未被消费，
   `m_rready = r_go`）。若将来接上多拍读/慢从设备，需要单独设计 skid/背压（已登记）。
2. `rdcycle` 判据依赖"CONFREG TIMER 与核同域"这一平台事实（`confreg_syn.v:346` 每 clk +1、
   runbook §3 的 33 MHz 同域接线）。若平台改成 CPU/uncore 分域，步④ 会立刻判 BAD —— 这是
   **有意**的行为（它正是用来钉住这个前提的）。
3. 完整版（不缩放）程序端到端判定仍未做（≈7.7e7 拍 ≈ 9 小时，预算不足）——沿用既有口径：
   缩放副本 + `diff_equiv.py` 机器等价（本轮 4 个差异字，全是 `li` 立即数对）。
4. Vivado 综合报告里仍可见既有告警（`csr_sum_raw` 无驱动等），均非本轮引入。
