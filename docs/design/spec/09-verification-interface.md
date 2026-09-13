# SPEC-09 验证接口与测试规格书

> 上游：`../../design/08-verification.md`（四级验证方案）、`00-conventions.md` §7（调试与可观测性接口）、`03-pipeline-regs.md`（写回 bundle / ROB 表项 / `core_top` 端口）、`../../reports/arch-test-report.md`（ACT4 契约与缺项）、`../../design/07-fpga-timing.md`（B0~B8 上板）、`../../kb/07-sim-debug.md`（仿真退出机制）。
> 本文件是 **RTL 开发与验证之间的接口契约**：信号名、位宽、地址一律以 00/03 号文档为准；本文新增的仅是**验证侧**的名字与格式，RTL 若与本文冲突，以 00/03 为准并提 issue 修订本文。
> 所有条目均可执行：每条断言有编号，每个测试有通过判据，每个覆盖点有统计来源。

---

## 1. 仿真环境结构

### 1.1 `sim/tb/` 文件职责（与 `08-verification.md` §1.1 一致，不得改名）

| 文件 | 职责 | 关键接口 / 行为 |
|---|---|---|
| `soc_sim_top.v` | SoC 仿真顶层：例化 `core_top` + AXI 互连 + 内存模型 + CONFREG + UART + NAND + CLINT/PLIC 地址译码旁路 | 例化名固定 `u_core`；对外暴露 `dbg_*` 观测口供 TB 采样 |
| `axi_mem_model.v` | 行为级 DDR/SRAM/arch-test RAM（INCR 突发、`rlast`、可 `load/dump` hex） | 参数 `BASE/SIZE/READ_LATENCY/WRITE_LATENCY`；支持 `$readmemh` 预载 |
| `uart_model.v` | 16550 寄存器子集，把写入字节同时送 stdout 与 `sim.log` | 基址 `0x1FE0_01E0`，`THR=+0x00`、`LSR=+0x14` |
| `confreg_sim.v` | 复用 `chiplab/IP/CONFREG/confreg_sim.v`（模块名 `confreg`） | 基址 `0x1FAF_0000`；退出/打印见 §1.3 |
| `nand_model.v` | 行为级 NAND：页 2048+64 B、块 128 KiB、1024 块，含 DMA 引擎模型 | 控制器 `0x1FE7_8000`，门铃 `0x1FD0_1160` |
| `tb_iverilog.v` | iverilog 顶层：`$readmemh` 载入镜像、超时退出、VCD dump | 退出码见 §7.2；`+hex=<f>`、`+timeout=<n>` |
| `tb_verilator.cpp` | Verilator C++ 顶层：ELF32 载入、`tohost` 监视、提交轨迹输出、FST 窗口 dump | 退出码见 §7.2；`+elf=<f>`、`+trace=<f>`、`+seed=<n>` |
| `dbg_trace.v` | **新增**：把 RT 级提交事件按 §2.3 格式写成 `rtl_trace.log` 的行 | 输入 `dbg_commit_*` + `dbg_state`；纯仿真，`ifdef SIM_TRACE` 包裹 |

### 1.2 端口级连接图

```
                    +-------------------------------------------------+
   aclk/aresetn --->|  u_core : core_top  (03-pipeline-regs.md §7.1)  |
   intrpt[7:0] <----|  AXI4 主设备 (arid/araddr/arlen/arsize/.../rdata)|
                    |  debug0_wb_pc/rf_wen/rf_wnum/rf_wdata, ws_valid  |
                    |  break_point/infor_flag/reg_num/rf_rdata        |
                    |  dbg_commit_valid/pc/rd/wdata/wen, dbg_state    |  <== 核内新增(§2.2)
                    +---+----------------------------+----------------+
                        | AXI4 (CPU 侧, cpu_clk)     | dbg_commit_* / dbg_state
                        v                            v
              +-------------------+          +---------------------+
              | axi_interconnect  |          | dbg_trace.v         |--> sim/log/<t>/rtl_trace.log
              | (1x4 地址译码)     |          | + 断言监视器        |--> sim/log/<t>/assert.log
              +-+------+-------+--+          +---------------------+
                |      |       |
    +-----------+  +---+----+  +-----------+
    |              |        |              |
    v              v        v              v
 axi_mem_model  confreg_  uart_      apb/nand_model + dma_model
 (DDR 0x0-0x7FF_FFFF, sim.v  model     (0x1FE7_8000 / 门铃 0x1FD0_1160)
  SRAM 0x1C00_0000, (0x1FAF_ (0x1FE0_
  TEST 0x8000_0000)  0000)    01E0)
```

CLINT（`0x1F00_0000`）与 PLIC（`0x1F10_0000`）在**核内截获**，不产生 AXI 访问（`06-bus-axi.md` §3），因此 `soc_sim_top.v` 中**不得**为这两个窗口再挂从设备；若挂上即为连接错误（断言 AXI-14 覆盖）。

### 1.3 地址映射（与 FPGA 一致的部分 + 仿真专用部分）

| 区间 / 地址 | 大小 | 属性 | 与 FPGA 是否一致 | 说明 |
|---|---|---|---|---|
| `0x0000_0000`–`0x07FF_FFFF` | 128 MiB | 可缓存 | 一致 | DDR3（行为模型，`READ_LATENCY=20`） |
| `0x1C00_0000`–`0x1C0F_FFFF` | 1 MiB | 可缓存 | 一致 | FPGA 为 SPI XIP，仿真为 SRAM 模型 |
| `0x1FAF_0000` | 64 KiB | 非缓存 | 一致（仿真变体） | CONFREG（`confreg_sim.v`） |
| `0x1FD0_0000` | 64 KiB | 非缓存 | 一致（FPGA 变体） | CONFREG（`confreg_syn.v`）；仿真中**可只读返回 0**，用于验证译码 |
| `0x1FE0_0000`–`0x1FE0_3FFF` | 16 KiB | 非缓存 | 一致 | UART0，寄存器 `0x1FE0_01E0` |
| `0x1FE7_8000` + `+0x40` | 16 KiB | 非缓存 | 一致 | NAND 控制器 / DMA 数据口 |
| `0x1FE8_0000` / `0x1FF0_0000` | — | 非缓存 | 一致 | SPI / MAC（仿真不建模，读返回 0） |
| `0x1F00_0000`–`0x1F00_FFFF` | 64 KiB | 核内截获 | 一致 | CLINT：`msip+0x0000`、`mtimecmp+0x4000/+0x4004`、`mtime+0xBFF8` |
| `0x1F10_0000`–`0x1F1F_FFFF` | 1 MiB | 核内截获 | 一致 | PLIC（SiFive 布局，`NDEV=8`） |
| **`0x8000_0000`–`0x80FF_FFFF`** | **16 MiB** | 可缓存 | **仿真专用** | arch-test `TEST_BASE`，`link.ld` 的 RAM 区 |
| **`0x1FAF_E000`** | 4 B | 非缓存 | 平台已有 | CONFREG 自由运行 TIMER（裸机计时用） |

> CONFREG 偏移以 chiplab RTL 为准（`confreg_sim.v` 生效映射）：`LED +0xF020`、`LED_RG0 +0xF030`、`LED_RG1 +0xF040`、`NUM +0xF050`、`TIMER +0xE000`、`IO_SIMU +0xFF00`、`VIRTUAL_UART +0xFF10`、`SIMU_FLAG +0xFF20`(RO)、`NUM_MONITOR +0xFF40`。`07-sim-debug.md` 与 `kb/01` 对本组偏移的记载若不一致，**一律以 chiplab RTL 为准**并在 `scripts/check_addrmap.sh` 中做正则比对（`+0xF0xx/+0xFFxx` 逐条），不一致即回归失败。

### 1.4 `tohost`、CONFREG 退出/打印约定

| 通道 | 地址 | 写值 | 语义 | 谁使用 |
|---|---|---|---|---|
| `tohost` | `0x8000_1000`（`.tohost` 段） | 1 | 通过 → TB 立即 `$finish`，退出码 0 | ACT4 自校验 ELF（`RVMODEL_HALT_PASS`） |
| `tohost` | 同上 | 3 | 失败 → 立即结束，退出码 1 | `RVMODEL_HALT_FAIL` |
| `tohost` | 同上 | 其它非 0 | 记录 `tohost=0x<v>` 后按失败处理（退出码 1） | 调试期异常值 |
| CONFREG `IO_SIMU` | `0x1FAF_FF00` | `sw` 写入值 | **注意 RTL 做 16 位字节交换**：`io_simu <= {wdata[15:0],wdata[31:16]}`；TB 按交换后的值取低 8 位作退出码 | 自研裸机用例（`sw/tests/`） |
| CONFREG `VIRTUAL_UART` | `0x1FAF_FF10` | 字节 | 打印一个字符到 `sim.log` | 无 UART 依赖的最小打印 |
| CONFREG `LED_RG0/RG1` | `0x1FAF_F030/F040` | 1 / 2 | 1=绿=通过，2=红=失败（仅置标志，不结束仿真） | 与 FPGA B3 共用的判据 |

`IO_SIMU` 退出码约定：`0x00` 通过；`0x01` 断言/校验失败；`0x02` 超时；`0x03` 非法指令陷阱未处理；`0x04` 环境错误（ELF/内存）；其余值原样透传到脚本退出码的低 7 位。

### 1.5 超时机制

| 层级 | 机制 | 上限 | 命中动作 |
|---|---|---|---|
| TB 硬超时 | `+timeout=<cycles>`（默认 2 000 000） | 见 §7.3 每级预算 | dump 波形窗口、写 `timeout` 标记、退出码 2 |
| 测试软超时 | 裸机用例用 `mtime`（CLINT）自查，超时写 `IO_SIMU=0x02` | 用例自带 | 退出码 2 |
| 无进展检测 | 连续 100 000 周期无 `dbg_commit_valid` 且无 LSU/AXI 事务 | — | 判死锁，退出码 5，dump 波形 |
| NAND 用例 | 单独上限 `+timeout=20000000` | 20 M 周期 | 同上 |

### 1.6 波形与日志文件命名规范

```
sim/log/<test>/                     # <test> = ELF 基名（无扩展名）
├── sim.log          # stdout：UART/VIRTUAL_UART 打印 + TEST 行（§8.2 格式）
├── rtl_trace.log    # 提交级轨迹（§2.3 格式，RTL 侧）
├── spike.log        # 参考轨迹（spike --log-commits 原始输出）
├── diff.log         # 归一化后的 diff（§2.7 格式，含首个不一致点）
├── cov.log          # RTL 覆盖点计数器 dump（§6.4 格式）
├── assert.log       # 断言违例记录（编号/周期/波形偏移）
└── wave.fst         # 仅在失败时保留（+dump=1 或 DUMP=1）
```

| 变量 | 取值 | 说明 |
|---|---|---|
| `DUMP` | `0`(默认)/`1` | 1 = 全波形；0 = 仅在失败时 dump |
| `DUMP_FMT` | `fst`(verilator 默认)/`vcd`(iverilog 默认) | iverilog 用 `$dumpfile("...vcd")` |
| `DUMP_FROM` / `DUMP_TO` | 周期号 | 失败时窗口 = `[失败周期-200, 失败周期+20]`；`DUMP_FROM` 优先级更高 |
| `SEED` | 整数 | 随机测试种子；写入 `sim.log` 首行 `SEED=<n>`，并与 `rtl_trace.log` 首行一致 |
| `TRACE_DEPTH` | 指令条数 | `rtl_trace.log` 写满即停止记录（默认 0 = 不限）；**比对器必须记录截断点**，否则会把"轨迹被截断"误判为"指令缺失"（见 §2.6 例外 c5） |

---

## 2. 提交级轨迹（trace）格式规范

### 2.1 两层轨迹

| 层 | 文件名 | 用途 | 是否逐行比对 |
|---|---|---|---|
| L1 架构层 | `rtl_trace.log` | 每条提交指令一行，字段与 Spike 可对齐 | 是（§2.5） |
| L2 微架构层 | `sim/log/<test>/arch_trace.log`（可选，`+arch_trace=1`） | 追加 store 地址/数据、CSR 写、TLB/PTW 事件，用于定位不一致的**根因** | 否（仅在 L1 失败后人工查看） |

### 2.2 轨迹来源信号（核内新增，与 03 §7 不冲突）

| 信号 | 宽度 | 说明 |
|---|---|---|
| `dbg_commit_valid[3:0]` | 4 | 本周期各提交槽有效位（4 发射 → 最多 4 条/周期） |
| `dbg_commit_pc[3:0][31:0]` | 32×4 | 提交指令 PC |
| `dbg_commit_instr[3:0][31:0]` | 32×4 | **RVC 展开后**的 32 位指令 |
| `dbg_commit_rd[3:0][4:0]` | 5×4 | 架构目标寄存器号 |
| `dbg_commit_wen[3:0]` | 4 | 写寄存器有效（`rd=x0` 或 store 时为 0） |
| `dbg_commit_wdata[3:0][63:0]` | 64×4 | 写数据；整数写只用 `[31:0]`，浮点写用 `[63:0]` |
| `dbg_commit_is_fp[3:0]` | 4 | 目标是浮点寄存器 |
| `dbg_commit_excp_valid[3:0]` / `dbg_commit_excp_cause[3:0][3:0]` | 1+4 | 提交点异常（中断另见 §2.4） |
| `dbg_state[7:0]` | 8 | `{is_trap, flush_all, priv[1:0], rob_empty, rob_full, iq_full, lsq_full}` |

> 平台兼容端口 `debug0_wb_pc/rf_wen/rf_wnum/rf_wdata`（`core_top`，32 位）**保持不变**；`dbg_commit_*` 是核内信号，只在 `SIM_TRACE` 下接到 `dbg_trace.v`，不影响上板综合。浮点 64 位写宽由 `dbg_commit_wdata[63:0]` 承担——这是 03 §7 的 `debug0_wb_rf_wdata[31:0]` 无法表达的部分，**不得**用平台端口承载 F/D 值。

### 2.3 L1 行格式（唯一合法格式，分隔符 `|`，固定 11 列）

```
<seq>|<slot>|<cycle>|<priv>|<pc>|<instr>|<rd>|<wd>|<mem>|<excp>|<note>
```

| 列 | 字段 | 宽度/进制 | 空值表示 | 取值与规则 |
|---|---|---|---|---|
| 1 | `seq` | `%010d` 十进制 | 不适用 | **全局提交序号，从 1 单调 +1，每提交一条指令 +1**；RTL 与 Spike 两侧都由归一化脚本按同规则重排后比对 |
| 2 | `slot` | `0`–`3` | 不适用 | 同 `cycle` 内的槽位号；`slot` 升序 = 程序序（同周期 4 条必须按程序序输出） |
| 3 | `cycle` | `%012d` 十进制 | 不适用 | `mcycle` 计数值（TB 自有时钟计数器，复位释放后从 0 计）；**仅用于定位波形，不参与比对** |
| 4 | `priv` | `M`/`S`/`U` | 不适用 | 该指令**执行时**的特权级（不是提交时的） |
| 5 | `pc` | `0x%08x` | 不适用 | 提交指令 PC；RVC 记其自身的 2 字节对齐 PC |
| 6 | `instr` | `0x%08x` | 不适用 | RVC **展开后**的 32 位指令字（与 02 §4.6 一致，保证两侧反汇编一致） |
| 7 | `rd` | `0x%02x` | `--` | 目标架构寄存器号；`wen=0` 时写 `--` |
| 8 | `wd` | `0x%016x` / `0x%08x` | `--` | 整数写 `0x%08x`（低位有效）；浮点写 `0x%016x`（F 值必须 NaN-box 后的 64 位） |
| 9 | `mem` | 紧凑串 | `--` | `LD`/`ST`/`LR`/`SC`/`AMO` + 宽 + 虚拟地址，如 `LD.W:0x80001234`、`ST.B:0x1fafff10`、`AMO.ADD.W:0x80002000` |
| 10 | `excp` | 紧凑串 | `--` | `exc:<cause>` 或 `int:<code>`；`cause` 用 `04-csr-mmu.md` §4.1 的 4 bit 码（异常直接给码，中断给 `1:<码>` 形式如 `int:7`），并附 `tval`：`exc:5@0xdeadbeef` |
| 11 | `note` | 串 | `-` | 可选注记：`fence.i`、`sfence.vma`、`mret`、`csr:0x300`、`wb64`（F/D 写）、`resv:set`/`resv:clr`；**不参与比对，仅用于诊断** |

示例（可粘贴进 `grep`/`awk` 直接验证）：

```
0000000001|0|000000000120|M|0x80000000|0x00000297|0x02|0x80000000|--|--|-
0000000002|0|000000000124|M|0x80000004|0x00000317|0x03|0x80001000|--|--|-
0000000003|1|000000000124|M|0x80000008|0x00000393|--|--|ST.W:0x1fafff10|--|-
0000000004|0|000000000131|M|0x8000000c|0x0000a023|--|--|--|exc:2@0x0000a023|-
```

### 2.4 RTL 侧生成规则

| 场景 | 规则 |
|---|---|
| 同周期多提交 | 按 ROB 顺序输出 `slot=0..3`；**同一 `flush` 周期内被清空的槽不得输出** |
| 未提交指令 | 一律**不出现**在轨迹中（`flush` 掉的推测指令、被 `replay` 的 load 均不输出）；比对器据此判定"RTL 少一条"是 bug |
| `x0` 写 | `rd=x0` 时 RTL `wen=0` → `rd`/`wd` 均 `--`，与 Spike 一致 |
| 浮点写（F 值） | 必须输出 NaN-box 后的 64 位（低 32 位为单精度值，高 32 位全 1）；未做 boxing 即失败 |
| 浮点写（D 值） | 输出 64 位原值 |
| `fcvt.w.s` 等 FP→整数 | `is_fp=0`，按整数写输出 `0x%08x` |
| 异常提交 | 该指令输出 `excp=exc:<cause>@tval`；**不输出任何 rd/wd/store 效果**（异常指令无架构副作用） |
| 中断提交 | 输出一条 `pc` = 被中断指令 PC（= `mepc`）、`excp=int:<code>`（`code` ∈ {3,7,11,1,5,9}）、`rd/wd = --` 的行；后续行从 `mtvec`/`stvec` 入口开始 |
| CSR 串行指令 | `is_serial` 指令**单独占一个提交周期**（03 §4），因此轨迹中它必然独占一行；`is_csr` 行 `note` 必须带 `csr:0x<addr>` |
| 轨迹截断 | 达到 `TRACE_DEPTH` 或仿真结束时写一行 `#TRUNCATED seq=<n>`；比对器必须读到该行才允许"RTL 提前结束" |

### 2.5 与 Spike `--log-commits` 的对齐规则

**归一化管线**（`scripts/trace_norm.py`，两侧共用同一份正则，禁止手工改日志）：

| 步 | Spike 侧（`spike.log`） | RTL 侧（`rtl_trace.log`） |
|---|---|---|
| N1 前缀剥离 | 去掉 `core\s+0:\s+` 前缀（Spike 每行以 `core   0: ` 开头） | 无前缀，直接解析 |
| N2 token 规范化 | 折叠连续空白为单空格；十六进制统一小写、定宽（`0x` + 8/16 位十六进制补零） | 已定宽，仅校验列数 = 11 |
| N3 指令字还原 | 取反汇编列，用 `llvm-objdump`/`objdump` 结果或内部反汇编表还原为 32 位机器码；RVC 行还原为**展开后**的 32 位编码（与 N3-R 相同表） | 直接取第 6 列（已是展开后编码） |
| N4 提交效果抽取 | 尾部按 `(x\|f)\d+\s+0x[0-9a-f]+` 抽 rd/wd；`mem_write` 标记 → `mem` 列；异常/中断行单独识别 | 直接取第 7/8/9/10 列 |
| N5 序号重排 | 丢弃无法解释的行（如 `x0` 写、`mem_read`），按剩余顺序从 1 重新编号为 `seq` | 同规则重排（RTL 的 `seq` 仅用于报告，比对用重排后的值） |
| N6 归一路径 | 只保留 `[seq, pc, instr, rd, wd, mem_va, excp]` 六元组 | 同 |
| N7 浮点归一 | `wd` 为 `f` 类时按 §2.6 规则比较 | 同 |

**逐类指令的比对字段**（`C` = 严格比对，`≈` = 容差比对，`—` = 不比）：

| 指令类别 | 代表 | PC | instr | rd | wd | mem.va | excp | 备注 |
|---|---|---|---|---|---|---|---|---|
| 整数写 | `add/addi/lui/auipc/jal/jalr/load/csr 读` | C | C | C | C(32) | — | C | 主判据 |
| 浮点写 | `fadd.s/fmul.d/fcvt/fmv` | C | C | C | C(64) 或 ≈ | — | C | NaN 见 §2.6 c6 |
| 不写 | `beq/sw/fence/sfence.vma` | C | C | — | — | C（含 `LD/ST` 类别与宽） | C | store 的**数据**不在 L1 比对（在 L2/签名区） |
| AMO / LR / SC | `amoadd.w/lr.w/sc.w` | C | C | C | C | C | C | SC 失败时 `rd=1` 且无写内存，两侧必须一致 |
| CSR 读写 | `csrrw/csrrs/csrrwi` | C | C | C | C(32) | — | C | 第 11 列 `note` 的 `csr:addr` 仅诊断；非确定性 CSR 见 c3 |
| 异常 | `ecall/ebreak/illegal/misaligned/access-fault/page-fault` | C | C | — | — | — | C（cause + tval） | `mtval` 内容规则见 c4 |
| 中断 | `int:3/7/11/1/5/9` | C | — | — | — | — | C（code） | 顺序容差见 c2 |

### 2.6 容差与例外（每条都要在 `diff.log` 中显式声明命中，禁止静默放过）

| 编号 | 情形 | 容差 | 上限 |
|---|---|---|---|
| c1 | 复位后起点对齐 | 允许跳过两侧前 ≤ 8 行（`.tohost` 初始化、canary 自检） | 一次 |
| c2 | 中断提交点顺序 | 允许**滑动重同步**：取 RTL 侧 `int:` 行的 `pc`，在 Spike 侧 ±64 行窗口内搜索同一 `pc` 的 `int:` 行；两侧中断行数必须相等 | 每用例 ≤ 32 次 |
| c3 | 非确定性 CSR 读 | `cycle/cycleh/time/timeh/instret/instreth/mhpmcounter*`：只比对 PC 与 rd，`wd` 不比；`mtime` 差值允许 ≤ 5 % | 每用例 ≤ 16 条 |
| c4 | `mtval`/`stval` 写入值 | cause=2（非法指令）时比 `instr`；cause=4/6（非对齐）比出错地址；cause=12/13/15（页错误）比出错 VA；其余（0/1/3/5/7/8/9/11）不比对 tval 内容，只要求两侧"是否为零"一致 | — |
| c5 | 轨迹截断 | `TRACE_DEPTH` 截断点之后不比对；两侧都必须在同一 `seq` 处声明截断，否则算不一致 | 一次 |
| c6 | 生成型 NaN | 若 ISA 规定"结果若为 NaN 则为规范 NaN"（`f-st-ext`/`d-st-ext`），则**严格按位比对**；仅当实现明确采用"保留输入 NaN 载荷"策略时，允许"同为 NaN 且同为 quiet/ signaling 类别"放宽，并在报告 `WARN:NaN_PAYLOAD` | 每用例 ≤ 64 条 |
| c7 | `fflags` 副作用 | 不逐条比对 `fflags`；改为在测试末尾 `csrr fcsr` 后人工核对（或用签名区比对） | — |
| c8 | 长延迟指令交错 | 除法/缺失 load 之后的写回顺序允许不同，但**提交顺序**必须严格一致（本比对天然覆盖，因为轨迹按提交序） | — |
| c9 | 平台差异 | UART/CONFREG/NAND 访问的 `mem.va` 必须一致；这些访问可能触发**不可重放**的设备副作用，随机测试中禁止访问（生成器 blacklist） | — |

### 2.7 失败报告格式

`diff.log`（同时打印到 stdout，脚本按 `DIFF` 行计数）：

```
DIFF at seq=832
  RTL   : 0000000832|0|000000014020|S|0x80001234|0x00b50533|0x0a|0x00000007|--|--|-
  SPIKE : core   0: 0x80001234 (0x00b50533) x10 0x00000008
  field : wd
  expect=0x00000008 actual=0x00000007
  window: wave.fst [cycle 13980, 14200]  seed=20260913  elf=rand_alu_0007.elf
  first_divergence_pc=0x80001234  instr=0x00b50533  rd=x10  prev_ok_seq=831
```

| 字段 | 强制 | 说明 |
|---|---|---|
| `DIFF at seq=<n>` | 是 | 归一化后的首个不一致序号 |
| `RTL` / `SPIKE` 原文行 | 是 | 便于人工核对 |
| `field` | 是 | 不一致字段名（`pc`/`instr`/`rd`/`wd`/`mem_va`/`excp`），以及 `missing_rtl`/`missing_spike` |
| `expect` / `actual` | 是 | 以 **Spike 为期望**（`expect`），RTL 为实际 |
| `window` | 是 | 波形文件 + 周期窗口 + 随机种子 + ELF 名（最小复现三要素） |
| `prev_ok_seq` | 是 | 最后一个一致的序号，用于定位"从哪条指令开始错" |

**比对器固有检查**（不依赖 Spike）：`seq` 连续无跳号；`slot` 升序；`cycle` 单调不减；同一 `cycle` 内 `slot` 不重复；`instr` 非 0 且非全 1。

---

## 3. 断言清单

> 位置列给模块/文件与流水级；触发条件为"当 X 成立时"；严重级别：**F** = 阻塞合并，**E** = 必须修复后方可进入下一验证级，**W** = 记录并计入覆盖率缺口。
> 全部用 `` `ifdef SIM_ASSERT `` 包裹（00 §1），iverilog 用 `assert` 子集，verilator 加 `--assert`。断言违例统一写 `assert.log`：`ASSERT <编号> cycle=<n> pc=<pc> detail=<...>`。

### 3.1 AXI 协议（`rtl/bus/axi_master.v`，监视器在 `soc_sim_top.v`）

| 编号 | 位置 | 触发条件 | 期望 | 级别 |
|---|---|---|---|---|
| AXI-01 | AR/AW/W/R/B 通道 | `valid` 拉高后 | 保持有效直到对应 `ready` 拉高；期间 payload 不变 | F |
| AXI-02 | 五通道 | 任一 `valid` 时 | 不得出现 `x`/`z`（`$isunknown` 检查） | F |
| AXI-03 | AR/AW | `valid && ready` | `arlen/awlen ≤ 15`（4 bit 上限） | F |
| AXI-04 | AR/AW | `valid` | `arburst=INCR`（`2'b01`）且 `arsize` ∈ {0,1,2} | F |
| AXI-05 | AR/AW | 地址 + `len`/`size` 推导 | 突发不跨 4 KB 边界：`(addr[11:0] + (len+1)<<size) ≤ 4096` | F |
| AXI-06 | R 通道 | `rvalid && !rready` | RTL 不撤销 `rvalid`；数据保持 | F |
| AXI-07 | R 通道 | 每个突发 | `rlast` 恰好在第 `arlen+1` 拍拉高，不早不晚 | F |
| AXI-08 | R 通道 | `rlast && rvalid` | `rid` 与对应 AR 的 `arid` 一致，且每 ID 内返回顺序与请求顺序一致 | E |
| AXI-09 | W 通道 | 每个突发 | `wlast` 在第 `awlen+1` 拍；`wstrb` 与 `awsize` 一致（非缓存访问 `wstrb` 只置有效字节） | F |
| AXI-10 | B 通道 | `bvalid` | 每个 AW 突发恰好一个 B；`bready` 不依赖 `bvalid`（无组合环） | E |
| AXI-11 | AR/AW | 同时刻 | 未完成读 ≤ 8、未完成写 ≤ 4（`03-cache.md` §7） | E |
| AXI-12 | `rresp`/`bresp` | 任一 `resp != 2'b00` | 记录并触发访问错误路径（不得静默丢弃） | E |
| AXI-13 | 非缓存通道 | 同一地址连续访问 | 强序：读/写不合并、不重排；`cache=4'b0010`、`prot` 按特权级 | E |
| AXI-14 | `soc_sim_top.v` 译码 | 地址 ∈ `0x1F00_0000`/`0x1F10_0000` | **不出现 AXI 事务**；CLINT/PLIC 必须核内截获 | E |
| AXI-15 | AXI 主设备 | `arvalid` 拉高 | 该请求的地址已完成 MMU 翻译与 PMP 检查（不得发出未检查地址） | F |

### 3.2 流水线（后端）

| 编号 | 位置 | 触发条件 | 期望 | 级别 |
|---|---|---|---|---|
| PIPE-01 | `rob.v` RT | 每周期提交序列 | 提交的 `rob_idx` 序列严格按环形顺序递增，环回时恰好跨过 128 | F |
| PIPE-02 | `rob.v` RT | 存在 `excp_valid` 的最老项 | 该周期不提交它之后的任何项（精确异常） | F |
| PIPE-03 | `rob.v` RT | 提交一条 `is_serial` 项 | 该周期不提交其它项（03 §4） | F |
| PIPE-04 | `rob.v` | `valid=0` 的项 | 永远不被提交 | F |
| PIPE-05 | `flush` 广播 | `flush_valid` 携 `flush_rob_idx=b` | 每个 `rob_idx` 满足 `is_younger(idx,b)` 的项、IQ 项、LSQ 项置无效；**更老项不受影响**（用 00 §3 的环形年龄函数） | F |
| PIPE-06 | `flush_all` | 拉高 | 1~2 周期内 ROB/IQ/LSQ/取指队列 `valid` 全零且 `dbg_state.rob_empty=1` | F |
| PIPE-07 | `checkpoint.v` | 分支恢复 | 恢复后 RAT/空闲表 = checkpoint 快照逐位相等；恢复后新分配的 `pd` 不与快照冲突 | F |
| PIPE-08 | `freelist.v` | 每周期 | 空闲向量与"已分配未回收"计数之和 = 128；P0 永不在空闲向量中被分配 | E |
| PIPE-09 | `freelist.v` | `rd=x0` 的 uop | 不分配新 `pd`；提交时不回收 P0 | E |
| PIPE-10 | `iq_*.v` | 写回总线 `wb_valid[i] && wb_pd[i]==ps1` | 下一周期对应项 `ready1=1`（唤醒不丢失） | F |
| PIPE-11 | `iq_*.v` | 项 `valid && ready1 && ready2` 连续 ≥ 200 周期 | 必须被发射（无饿死）；记入覆盖率欠账 | E |
| PIPE-12 | `iq_*.v` | `issued` 置位 | 同一项在写回/清空前不得再次发射 | F |
| PIPE-13 | `wakeup_select` | 发射选择 | 同一物理寄存器在同一周期不被两个执行口同时选中（同类型队列内） | F |
| PIPE-14 | `prf.v` | 同周期读同一 `pd` 的两个源 | 返回相同值 | E |
| PIPE-15 | 全核 | 100 000 周期无提交且无 AXI 事务 | 判死锁（外部监视器，非 RTL 断言） | F |
| PIPE-16 | `bru.v` | 分支解析 | `actual_target` 是 EX 级唯一决定的；前端重定向 PC 与之一致 | F |
| PIPE-17 | `ras`/`ghr` | 分支提交 | 提交时更新值与 checkpoint 恢复值一致（同一分支二次执行结果相同） | E |

### 3.3 Cache

| 编号 | 位置 | 触发条件 | 期望 | 级别 |
|---|---|---|---|---|
| CACHE-01 | `mshr.v` | 任意时刻 | 同一 `{物理行地址}` 至多一个 MSHR 表项（缺失合并，不重复发起） | F |
| CACHE-02 | `mshr.v` | 表项分配/释放 | 表项数 ≤ 8（L1D）/ ≤ 2（L1I）/ ≤ 4+4（L2 refill/victim）；计数器不回绕 | F |
| CACHE-03 | `dcache.v` | 行填充完成 | 被填充行的 tag 与该 MSHR 的地址匹配；`way` 来自替换逻辑且该 way 已被置为占用 | F |
| CACHE-04 | `dcache.v` | load 转发 | store→load 转发只在"地址按字节重叠且更老"时发生；转发值 = 逐字节合并结果（部分重叠用 store 字节 + 原行字节） | F |
| CACHE-05 | `lsq.v` | load 已发射后更老 store 地址变有效且重叠 | 置 `replay` 并使该 load 及其更年轻指令重放（05 §6） | F |
| CACHE-06 | `dcache.v` | 脏行被替换 | 脏行必进 Victim Buffer 并最终写回内存（不丢数据） | F |
| CACHE-07 | `icache.v` | `fence.i` 提交 | L1I 全无效 + 取指队列清空；此后取指必须从内存重新填充（自修改代码） | F |
| CACHE-08 | `dcache.v`/`l2_cache.v` | `cbo.inval/clean/flush` | inval 后该行 `valid=0` 且不写回；clean 后 `dirty=0`；flush 后 `valid=0` 且脏数据已写回 | F |
| CACHE-09 | `l2_cache.v` | 同一行的 L1I refill 与 L1D 写回并发 | 二者串行化，不出现同拍写同一 BRAM 端口 | E |
| CACHE-10 | `stld_predictor` | 预测"无冲突"但实际违例 | 必须触发 replay 且重放后结果与顺序模型一致（覆盖率里程碑，非错误） | E |
| CACHE-11 | `dcache.v` | AMO/LR/SC 访问 | AMO 在该行命中且独占期间完成读-改-写；期间该行不得被替换 | F |

### 3.4 TLB / PTW / PMP

| 编号 | 位置 | 触发条件 | 期望 | 级别 |
|---|---|---|---|---|
| MMU-01 | `tlb.v` | 提交级 `sfence.vma`（`rs1=0,rs2=0`） | 1~4 周期内 ITLB/DTLB/L2TLB 全部 `valid=0` | F |
| MMU-02 | `tlb.v` | `sfence.vma rs1≠0,rs2=0` | 仅失效 VA 匹配项（按页，含 4 MB 大页的 VA 覆盖） | F |
| MMU-03 | `tlb.v` | `sfence.vma rs2≠0` | 仅失效该 ASID 项；`G=1` 项**不被** ASID 失效清除，但被"全失效"清除 | F |
| MMU-04 | `tlb.v` | 特权级/`satp` 写 | `satp` 写后必须 `sfence.vma` 才生效；实现可选择写 `satp` 时自动全失效（需在 RTL 注释与本文登记） | E |
| MMU-05 | `tlb.v`+`ptw.v` | 命中且 `A=0` 或（store 且 `D=0`） | 触发 A/D 更新：**先写回 PTE 成功，再完成访问**；PTE 写回失败/异常时按规范报页错误且不完成访问 | F |
| MMU-06 | `tlb.v` | A/D 更新写回 | 写回**不得**改变 PTE 其它位；写回是原子的（读-改-写，且期间该 PTE 不被其它请求观察为中间态） | F |
| MMU-07 | `ptw.v` | 一次遍历 | 同一缺失恰好填一个 TLB 项；非叶 PTE 的 `A/D/U` 合法性按规范检查（叶子/非叶规则不同） | F |
| MMU-08 | `ptw.v` | 非法 PTE（`V=0` 或保留位非零） | 报页错误（12/13/15）且**不填充 TLB** | F |
| MMU-09 | `tlb.v` | 权限判定 | U 页在 S 模式访问且 `SUM=0` → 页错误；`MXR=1` 时 `X` 页可读；`MPRV=1` 时用 `MPP` 权限与特权级 | F |
| MMU-10 | `pmp.v` | 任一 S/U 模式访问且无匹配项 | 拒绝（访问错误） | F |
| MMU-11 | `pmp.v` | 匹配 `A=TOR` | 用 `pmpaddr[i-1]` 作下界；项 0 的 TOR 下界为 0；上下界相等 → 空区间 | F |
| MMU-12 | `pmp.v` | `L=1` 被锁定的项 | 后续写 `pmpcfg/pmpaddr` 被忽略（含 M 模式），直到复位；`L` 置位本身不可逆 | F |
| MMU-13 | `pmp.v` | 所有 PMP 项 | `pmpaddr` 低 2 位恒 0（G=0 时粒度 4 B）；NAPOT 尾部必须全 1，否则为合法但应记录的实现行为 | E |
| MMU-14 | `pmp.v`+`tlb.v` | PMP 配置被写入 | 全部 TLB 失效（TLB 项携带 PMP 通过标记，04 §5.3） | F |
| MMU-15 | `ptw.v` | PTE 取指本身 | 也受 PMP 检查（物理地址访问） | F |

### 3.5 CSR

| 编号 | 位置 | 触发条件 | 期望 | 级别 |
|---|---|---|---|---|
| CSR-01 | `csr_file.v` | `csr_wen` 在 EX/MEM/WB 级拉高 | **不生效**；只有 RT 级（`03-pipeline-regs.md` §2.7）写的 `csr_wen` 才改变状态 | F |
| CSR-02 | `csr_file.v` | RT 级一次写 | 同一 CSR 同周期至多一次写；`is_serial` 保证不与其它 CSR 写同拍 | F |
| CSR-03 | `csr_file.v` | 写只读 CSR（`mvendorid`/`marchid`/`mimpid`/`mhartid`/`mconfigptr`/计数器的只读视图） | 触发非法指令（cause=2），CSR 值不变 | F |
| CSR-04 | `csr_file.v` | U/S 模式访问 M 级 CSR（地址 `[11:8]>=0b11`） | 非法指令（cause=2），`tval` 按 c4 规则 | F |
| CSR-05 | `csr_file.v` | 不存在的 CSR 地址 | 非法指令；不得返回 0 后继续执行 | F |
| CSR-06 | `csr_file.v` | `misa` 写 | 仅 `C` 位可改；`MXL[31:30]=01`、`I M A F D C S U` 位恒 1 | F |
| CSR-07 | `csr_file.v` | `mstatus.MPP` 写 `2'b10` | 归一到 `2'b11`（WARL，04 §2.3） | E |
| CSR-08 | `csr_file.v` | `mepc` 写 | `bit0=0`（IALIGN=16 时 `bit1=0`）；`sepc` 同理 | F |
| CSR-09 | `csr_file.v` | 写 `satp` | `MODE` 只接受 0/1；写 2/3 保留值不得生效（WARL） | E |
| CSR-10 | `trap_ctrl.v` | 陷阱 | `xepc=被中断指令 PC`、`xcause` 按 §4.1 码、`xstatus.xPP/xPIE/xIE` 正确；委托位决定写 M 还是 S 组 | F |
| CSR-11 | `trap_ctrl.v` | `mtvec.MODE=1`（Vectored） | 中断入口 = `BASE + 4*code`；异常入口仍为 `BASE`；`BASE` 低 2 位为 MODE 域 | F |
| CSR-12 | `trap_ctrl.v` | `mret/sret` | `xIE←xPIE`、`xPIE←1`、特权级←`xPP`、`mret` 清 `MPRV`、PC←`xepc` | F |
| CSR-13 | `csr_file.v` | S 模式读 `cycle/time/instret` | 受 `mcounteren` 控制；`scounteren` 再控制 U 模式；被禁则非法指令 | F |
| CSR-14 | `csr_file.v` | `mcountinhibit.CY/IR=1` | `mcycle/minstret` 停止计数；`minstret` 只统计**提交**指令数 | E |
| CSR-15 | `csr_file.v` | RT 级 CSR 写与同周期陷阱 | 同一条指令不得既写 CSR 又提交异常副作用（异常指令的 CSR 写必须被抑制） | F |

### 3.6 原子与串行化

| 编号 | 位置 | 触发条件 | 期望 | 级别 |
|---|---|---|---|---|
| ATOM-01 | `lsu.v`/`dcache.v` | `lr.w` 提交 | 保留集置位，记录物理地址；**同周期该行的独占权保持** | F |
| ATOM-02 | 保留集 | 任一条件成立 | 必须清空保留集：① `sc.w` 提交（成功或失败）；② 该地址被更老 store 写入；③ 执行 `sfence.vma`；④ 陷阱/中断提交（进入 trap handler）；⑤ `mret/sret`（上下文切换）；⑥ 该地址的 cache 行被替换/失效（含 `cbo.inval`）；⑦ 其它 hart 写入（单核不涉及，登记为不适用） | F |
| ATOM-03 | `lsu.v` | `sc.w` 执行 | 保留集有效则写入并 `rd=0`；无效则**不写内存**且 `rd=1`；两种情况都必须与后续 load 的观察一致 | F |
| ATOM-04 | `lsu.v` | `sc.w` 因任何原因失败 | 不得产生部分写入（按字节原子） | F |
| ATOM-05 | `lsu.v` | AMO 地址非对齐 | 报非对齐异常（cause=6），不执行读-改-写 | F |
| ATOM-06 | `lsu.v` | AMO 跨 cache 行 | 报非对齐（ACAMO 未实现，登记为不支持）；不得拆成两次非原子访问 | F |
| ATOM-07 | 保留集 | 中断/异常提交 | 保留集清空（与 ATOM-02④ 同一断言，单列以覆盖中断路径） | F |
| ATOM-08 | `lsu.v` | `lr.w` 后的依赖链 | `lr.w` 写回不丢失唤醒（与 PIPE-10 交叉覆盖） | E |

---

## 4. 单元测试清单

> 每项：测试名 → `sim/unit/<module>/<test>.v`；激励类型；期望值来源；通过判据（P 判据全绿才算通过）。
> 单元测试**不加载 ELF**，直接驱动 module 端口；参考值来源列 `REF-C` = GCC 编译的 C 生成器输出向量文件（`.hex`），`REF-T` = 表格硬编码，`REF-B` = 行为模型在线比对，`REF-A` = 汇编器生成机器码后人工核算。

| 模块 | 测试名 | 激励类型 | 期望值来源 | 通过判据 |
|---|---|---|---|---|
| `alu` | `alu_rand_1e6` | 1e6 组随机 `{op_a,op_b,alu_op}`，覆盖 10 种 `alu_op` | REF-C | 逐组 `result` 与期望位等；`zero` 标志一致 |
| `alu` | `alu_edge` | 边界：`INT_MIN`、`0xFFFF_FFFF`、移位量 0/31/32/33、`SLT` 符号边界 | REF-T | 全组一致；移位量 ≥32 时按 RV32 取模 5 位语义 |
| `mdu` | `mdu_mul_rand` | 1e5 组 `MUL/MULH/MULHSU/MULHU` 随机 | REF-C（64 位参考） | 高低半字都一致 |
| `mdu` | `mdu_div_edge` | 除零（商 `-1`/余被除数）、`INT_MIN/-1`、`INT_MIN/1`、全 1、符号组合 | REF-T | 商/余按规定值；无死锁（`busy` 在 ≤ 40 周期内降） |
| `mdu` | `mdu_div_rand` | 1e4 组随机除法（含负数） | REF-C | 商余同时一致；`div` 与 `rem` 的符号规则分别校验 |
| `fpu` | `fpu_arith_sd` | `FADD/FSUB/FMUL/FDIV/FSQRT/FMA` × {S,D} × 5 种舍入模式 × 随机 + 特殊值（±0、±Inf、qNaN、sNaN、次正规、最大有限） | REF-C（宿主 `long double` 参考程序，向量文件） | 位精确（除 c6 允许的 NaN 载荷）；`fflags` 的 NV/DZ/OF/UF/NX 五位逐一比对 |
| `fpu` | `fpu_cvt` | 全部转换对（`fcvt.s.d`/`fcvt.d.s`/`fcvt.w[u].s/d`/`fcvt.s/d.w[u]`）× 边界值 | REF-C | 位精确；越界值的饱和/`NV` 行为按规定 |
| `fpu` | `fpu_cmp_class` | `FEQ/FLT/FLE`（含 NaN、±0）与 `FCLASS` 全 10 位 | REF-T | 比较结果与分类掩码逐位一致 |
| `fpu` | `fpu_box` | F 值写回后读 64 位 | REF-T | 高 32 位全 1（NaN boxing）；输入非 boxed 时按规范当规范 NaN |
| `decoder` | `dec_table` | 全部 RV32IMAFDC + Zicsr/Zifencei/Zicbom 编码（含 RVC 展开）逐条 | REF-T（02 §4 表） | `uop_ctrl_t` 72 位逐位一致 |
| `decoder` | `dec_illegal` | 每个未定义编码 + RVC 保留编码（`c.addi4spn nzuimm=0`、`c.lwsp rd=0` 等） | REF-T | `excp_valid=1 && excp_cause=2 && tval=instr` |
| `decoder` | `rvc_equiv` | 每条 Zca/Zcd/Zcf 指令与其 32 位等价 | REF-B（同一 testbench 内双译码比对） | 两条路径产生的 uop 逐位相同 |
| `bpu` | `bpu_dir` | 定向序列：固定循环 1000 次、交替 T/NT、相关分支（`if(a&&b)`）、递归/返回 | 逻辑断言 | 预测方向收敛：循环 ≥ 900/1000 正确；RAS 返回地址 100% 正确 |
| `bpu` | `bpu_alias` | 构造 BTB/Gshare/PHT 别名与冲突序列 | 逻辑断言 | 别名不导致功能错误（只影响准确率）；计数器不越界 |
| `icache` | `ic_rand` | 随机取指流 × 跨行/跨页 + `fence.i` 插入 | REF-B | 取出的 16 B 与理想内存一致 |
| `dcache` | `dc_rand` | 1e5 随机 load/store，含字节/半字/非对齐/跨行 | REF-B（理想内存模型） | 每次 load 数据一致；结束时内存内容与模型一致 |
| `dcache` | `dc_fwd` | store→load 全重叠/部分重叠/不重叠 × 立即/延迟提交 | REF-B | 转发值按字节正确；不重叠不误转发 |
| `dcache` | `dc_evict` | 强制 8 路全满后替换脏行 | REF-B | Victim 写回后内存一致；无数据丢失 |
| `mshr` | `mshr_merge` | 4 个同地址缺失并发 | 逻辑断言 | 只发起 1 次 AXI 读，4 个请求都收到数据 |
| `mshr` | `mshr_ooo` | 8 个缺失乱序返回（不同 RID） | REF-B | 按地址匹配回填，无错行 |
| `store_buffer` | `sb_full_bubble` | 16 项写满 + 提交风暴 + 清空 | 逻辑断言 | 满时不丢 store；清空后与提交序列一致 |
| `l2_cache` | `l2_rand` | L1I/L1D/写回/非缓存 4 源并发随机 | REF-B | 4 源都不丢事务；PIPT 无别名问题 |
| `tlb` | `tlb_sv32_basic` | 4 KB/4 MB 页手工页表，全部权限组合 | 手工构造页表 + REF-T | 命中/缺失/权限结果逐项符合预期 |
| `tlb` | `tlb_sfence` | `sfence.vma` 8 种变体（`rs1`/`rs2` 零与非零 × ASID 匹配与否） | 逻辑断言 | 仅预期项被失效（MMU-01~04） |
| `tlb` | `tlb_ad` | A=0/D=0 组合 × load/store × 命中 | REF-B（页表内存模型） | PTE 被正确置位写回；访问在置位后完成 |
| `ptw` | `ptw_illegal_pte` | 12 种非法 PTE（`V=0`、非叶带 `A/D/U` 越权、保留位非零） | REF-T | 报正确 cause，且 TLB 未被污染 |
| `ptw` | `ptw_walk2` | 两级遍历 × 中途 PMP 拒绝 | REF-B | 中间级失败即报错，不继续遍历 |
| `pmp` | `pmp_match` | 16 项 × A={OFF,TOR,NA4,NAPOT} × XWR 组合 | REF-T | 匹配结果逐项一致；无匹配时 M 放行、S/U 拒绝 |
| `pmp` | `pmp_lock` | `L=1` 后尝试改 cfg/addr | REF-T | 写入被忽略且不产生异常 |
| `pmp` | `pmp_grain` | `pmpaddr` 低位、NAPOT 尾部全 1、TOR 边界相邻/相等 | REF-T | 区间计算逐项一致 |
| `csr_file` | `csr_rw_all` | 每个 CSR 的 `csrrw/s/c` + 立即数变体 | REF-T（04 §2 清单） | 读回值、只读位、WARL 归一化全部一致 |
| `csr_file` | `csr_priv_illegal` | U/S 模式访问每个 M 级 CSR；每个只读 CSR 的写 | REF-T | 全部报 cause=2 且状态不变 |
| `csr_file` | `csr_counter` | `mcountinhibit`、`mcounteren`、`scounteren` 组合 | REF-T | 读权限与计数停止行为一致 |
| `clint` | `clint_cmp` | `mtimecmp` 高/低半字写入顺序 × `mtime` 跨越 | 逻辑断言 | 不产生毛刺中断（写高半抑制一次）；`MTIP` 与比较结果一致 |
| `plic` | `plic_flow` | 优先级/阈值/使能/claim-complete 全流程 + 并发源 | REF-T | claim 返回值 = 最高优先级挂起源；complete 后允许再次中断 |
| `axi_master` | `axi_proto` | 定向违例注入（提前撤 `valid`、`rlast` 错位、跨 4 KB、`len=16`） | 逻辑断言（§3.1 全套） | 所有 AXI-* 断言按预期触发（自检注入的负例必须报错） |
| `axi_master` | `axi_ooo` | 8 读 4 写并发，返回乱序 | REF-B | 按 RID 分发无误配；无事务丢失 |
| `uncached_unit` | `unc_strong_order` | 同地址读写交替、非对齐设备访问拆分 | REF-B | 强序保持；拆分次数与地址一致 |
| `rename` | `rename_rand` | 1e5 随机 uop 流（含 WAW/WAR/RAW、`x0`、跨类型 `fmv`） | REF-B（顺序重命名模型） | 每个 `pd`/`ps1`/`ps2` 与模型一致；空闲表不泄漏 |
| `freelist` | `free_recycle` | 分配/回收随机 + checkpoint 恢复 + 清空 | REF-B | 循环 1e5 次后空闲表回到初值（无泄漏） |
| `rob` | `rob_order` | 随机完成乱序 + 提交 | REF-B | 提交序列 = 程序序；`pd_old` 回收正确 |
| `lsq` | `lsq_alias` | 随机别名 load/store 序列 | REF-B | 转发/重放判定与顺序模型一致 |
| `trap_ctrl` | `trap_all` | 每个异常码与 6 种中断 × 委托开/关 | REF-T | 入口 PC、`xepc/xcause/xtval/xstatus` 逐项一致 |
| `soc_sim_top` | `tbtop_smoke` | 空程序 + 一次 `tohost` 写 | 逻辑断言 | `tohost` 被正确捕获并结束仿真（退出码 0） |

**单元测试总数：41 项**（覆盖 20 个模块/结构）。

---

## 5. 系统测试清单

### 5.1 arch-test（ACT4）

| 项 | 内容 |
|---|---|
| 测试组 | `I`(39) `M`(8) `F`(78) `D`(104) `Zaamo`(9) `Zalrsc`(2) `Zca`(26) `Zcd`(4) `Zcf`(4) `Zicsr`(6) `Zifencei`(1) `Misalign`(5) `MisalignF`(2) `MisalignD`(2) `MisalignZca`(4) → **294** 个非特权用例；`priv/Sv*`（含 31 个 `sv32*`）、`PMPSm`(38)、`SvPMP`(16) 等 → **153** 个特权用例；**合计 ≈447** |
| 构建要点 | ACT4 需 `uv`/`mise` + Ruby/Bundler + `sail_riscv_sim 0.13.1`；本沙箱不具备，改用 `arch-test-report.md` §9 的手工两遍编译（`-DSIGNATURE` → 参考签名 → `-DRVTEST_SELFCHECK -DSIGNATURE_FILE=...`）；`-Xassembler -march=rv32i_zicsr_zifencei...` 必须带 `_zicsr_zifencei`；`'-DTEST_FILE="X.S"'` 必须带引号；`rvtest_config.h` 必须定义 `F/D/ZCA/SV32/..._SUPPORTED` |
| **阻塞项** | 参考签名**必须**来自真实参考模型（Sail 或 `spike +signature=`）；用"ELF 自身初值"代替会产生假失败（arch-test-report §9.6）。无参考模型时本组只跑 `tohost` 通过性冒烟，**不得**作为 ISA 合规结论 |
| 通过判据 | 每个 ELF：串口出现 `RVCP-SUMMARY: TEST PASSED - Test File "<name>.S"`，且 `tohost=1`；出现 `TEST FAILED`/`SIGRUN` 或超时即失败；**统计口径**：通过数/总数，允许的已知失败必须在 `sim/known_fail.txt` 中逐条列名并注明原因 |

### 5.2 自研特权级测试（补 ACT4 缺失的 Sm/中断/委托）

| 用例组 | 数量 | 内容 | 通过判据 |
|---|---|---|---|
| `sw/tests/csr_sm/` | 24 | 每个 M 级 CSR 的读/写/WARL + 只读位 + 非法访问 | 全部 `PASS`；每个 CSR 至少 1 读 1 写 1 非法例 |
| `sw/tests/trap/` | 18 | 异常码 0~9/11/12/13/15 的正反例（每个码 1 正例 + 至少 1 反例） | `mcause/mepc/mtval` 精确；异常指令无副作用 |
| `sw/tests/intr/` | 14 | `MSI/MTI/MEI/SSI/STI/SEI` 六种中断 × 委托开/关 + 嵌套 + `wfi` 唤醒 | 每个中断都能进入正确入口；`mideleg/medeleg` 决定 M/S 归属；`wfi` 被使能中断唤醒 |
| `sw/tests/priv/` | 16 | `mret/sret/wfi/sfence.vma` × 特权级 × `TVM/TW/TSR`=1 的非法例 | 状态转移符合 04 §4.4；非法例报 cause=2 |
| `sw/tests/mmu/` | 22 | `MPRV/SUM/MXR` 全组合 × load/store/取指 × U/S/M | 权限判定逐项一致；16 个方向全覆盖 |
| `sw/tests/pmp/` | 12 | PMP 锁定、TOR 边界、与 Sv32 组合（PTE 取指也受检） | 锁定后不可改；越权访问报访问错误而非页错误 |
| `sw/tests/clint_plic/` | 10 | `mtimecmp` 边界写入、PLIC 优先级/阈值/claim-complete、多源并发 | 无丢中断/重复中断；`/proc` 无关，纯裸机自校验 |

**合计 116 个自研用例**，每例结尾必须写 `tohost`（1/3）**并**打印 `TEST <name> PASS|FAIL`（§8.2 格式），二者不一致（如打印 PASS 但 `tohost=3`）判失败。

### 5.3 随机指令测试

| 项 | 规格 |
|---|---|
| 生成策略 | 受限随机：① 指令池按类型分组（整数/分支/访存/FP/M/A/CSR），每基本块从 1~3 组中抽；② 每 8~32 条插入 1 条控制流（`jal`/`jalr`/分支）形成有界循环；③ 寄存器分配避开 `x2`(sp)/`x3`(gp)（除专门测试）；④ 地址限定在 `[0x8000_0000, 0x8000_FFFF]` 与 `0x8001_0000` 的受限数据区；⑤ **禁止**访问 UART/CONFREG/NAND（不可重放的设备副作用，见 §2.6 c9）；⑥ 每 256 条插入一次 `fence.i` + `sfence.vma`（低概率，10%）与一次 `mret` 往返（10%）；⑦ 浮点开启 `mstatus.FS`，每 64 条随机改一次舍入模式 |
| 规模 | 每种子 20 000 条指令，2 000 条指令为一段、段尾写出 `tohost=1`（可分段定位） |
| 与 Spike 锁步 | 同一 ELF 两侧运行，按 §2 归一化逐条比对；**首差异即失败**并产出 §2.7 报告 |
| 种子 | `SEED` 显式传入并记录；回归固定种子集合 `{1..64}`，每晚再跑 64 个随机种子（`sim/rand_seeds.txt` 记录已跑种子） |
| 覆盖率收集 | RTL 内计数器（§6.4）每次运行导出 `cov.log`，由 `scripts/cov_merge.py` 合并到 `work/cov_total.log` |
| 通过判据 | ① 无 `DIFF`；② 无断言违例；③ `tohost=1`；④ `cov.log` 中"指令类型 × 特权级 × 异常"覆盖点无新增空缺（与基线对比只增不减） |

### 5.4 压力测试

| 用例 | 激励 | 通过判据 |
|---|---|---|
| `stress_rob_full` | 连续 4 发射、每 8 条插入一次远距离 `jal`（必然误预测）+ 长延迟除法，使 ROB 常满 | ROB 满周期占比 > 30%；无死锁；提交轨迹与 Spike 一致；无断言违例 |
| `stress_iq_full` | 单类型指令流（纯 ALU / 纯 load / 纯 FMA）打满 IQ_INT/IQ_MEM/IQ_FP | 三个队列各自 `full` 计数 > 1000；期间无反压丢失（`valid` 被 `ready=0` 时不得丢） |
| `stress_flush_burst` | 每 20 条一次误预测，连续 200 次；混入 10% 异常 | 每次清空后 `dbg_state.rob_empty` 在 ≤ 8 周期内为 1；结果与 Spike 一致 |
| `stress_intr_storm` | `mtimecmp` 设为当前 +100 周期循环触发（每秒上千次），同时跑访存密集循环 | 中断不丢、不重复；`mepc` 精确；轨迹按 c2 重同步后一致 |
| `stress_atomic` | 多对 `lr.w/sc.w` + AMO 交织，含失败 SC、异常打断 | 保留集清空条件（ATOM-02）逐条被覆盖；SC 结果与顺序模型一致 |
| `stress_alias` | 大量 load/store 别名（同址、部分重叠、跨行） | 转发/重放全部正确（与顺序模型比对），无静默错值 |
| `stress_dma_coherency` | CPU 写缓冲 → DMA 读 → DMA 写 → CPU 读；`cbo.clean/inval/flush` 三种路径 | 三种维护指令路径下数据都一致；漏掉维护操作**必须**观察到不一致（负例也必须能复现，否则说明测试无效） |

### 5.5 自修改代码

| 项 | 内容 |
|---|---|
| 用例 | `sw/tests/smc/` 4 例：① 写 1 条指令 → `fence.i` → 执行；② 写整行 32 B → `fence.i` → 执行；③ 写跨行指令 → `fence.i`；④ **反例**：写指令后**不**执行 `fence.i` 直接执行（结果允许为旧指令，但不得崩溃/死锁） |
| 通过判据 | ①②③ 新指令必被执行且结果正确；④ 无死锁、无断言违例，且 `dbg_state` 正常前进（旧代码执行可接受，登记为"允许的实现行为"） |

### 5.6 DMA 一致性

| 项 | 内容 |
|---|---|
| 用例 | `sw/tests/dma/` 6 例：CPU→DMA 写读、DMA→CPU 写读、双向交叉、`cbo.inval`/`clean`/`flush` 各一 |
| 通过判据 | 维护指令后 CPU/DMA 观察一致（逐字节校验 + CRC）；NAND 数据通路（页 2048+64 B）走 DMA 后 `md5sum` 一致 |

### 5.7 Linux 启动用例

| 阶段 | 通过判据 |
|---|---|
| OpenSBI `fw_jump` | 串口出现 OpenSBI banner；CLINT/PLIC 探测无报错；`mtime` 频率与设备树一致（±1%） |
| U-Boot | 出现提示符；`nand info` 识别 128 MiB；`nand read/write/erase` 校验一致；环境变量保存后重启保留 |
| 内核 + initramfs | 内核解压完成、`init` 进入 shell；`dmesg` 无 oops；`/proc/interrupts` 有定时器与 UART 计数增长 |
| 稳定性 | `md5sum` 校验大文件（≥8 MiB）一致；连续 30 min 无随机崩溃；`make -j4` 类负载下 `cbo.*` 路径被触发（覆盖点计数增长） |

---

## 6. 覆盖率模型

### 6.1 功能覆盖点（指令类型 × 特权级 × 异常类型）

| ID | 覆盖点 | 取值 | 目标 |
|---|---|---|---|
| FC-01 | 指令类别 | RV32I / M / A / F / D / Zicsr / Zifencei / Zicbom 共 8 类，每类 ≥ 1 条指令 | 100% 类别被至少 1 条提交指令覆盖 |
| FC-02 | 指令 × 特权级 | 每个 RV32I 大类（算术/逻辑/移位/分支/跳转/load/store）× {M,S,U} | 6×3 = 18 个 bin 中，S/U 下每类至少 1 例（U 模式只能用非特权指令） |
| FC-03 | 异常码 | cause 0,1,2,3,4,5,6,7,8,9,11,12,13,15 | 15/15 |
| FC-04 | 中断码 | 3,7,11,1,5,9（× 委托开/关） | 12/12 |
| FC-05 | CSR 访问 | 每个实现的 CSR 至少 1 读 + 1 写 + 1 非法访问（适用时） | 100% CSR 清单（04 §2） |
| FC-06 | Sv32 权限矩阵 | {R,W,X,U} × {M,S,U} × {SUM,MXR} 组合 | 覆盖全部"允许/拒绝"分支各至少 1 次 |
| FC-07 | PMP 模式 | A ∈ {OFF,TOR,NA4,NAPOT} × XWR × {M,S,U} × L ∈ {0,1} | 100% |
| FC-08 | 浮点舍入模式 | 5 种（RNE/RTZ/RDN/RUP/RMM）+ DYN | 6/6，且每种至少一次在 S 与 D 各出现 |
| FC-09 | RVC | 每条 Zca/Zcd/Zcf 指令 1 例 + 与 32 位等价的 uop 比对 | 100% |
| FC-10 | `misa`/`mstatus` 字段 | 每个实现字段至少被读 1 次、写 1 次 | 100% |

### 6.2 微架构覆盖点（每个满/空/冲突/清空路径）

| ID | 覆盖点 | 触发条件（RTL 计数器） | 目标 |
|---|---|---|---|
| MC-01 | ROB 满 | `rob_full` 连续 ≥ 1 周期 | ≥ 1 次 |
| MC-02 | IQ 满 | `iq_full[int]/[mem]/[fp]` 各自 ≥ 1 次 | 3/3 |
| MC-03 | LSQ 满 | `lsq_ld_full` / `lsq_st_full` 各 ≥ 1 次 | 2/2 |
| MC-04 | 队列空 | 三个 IQ 与 ROB 各自 `empty` 观察到 ≥ 1 次 | 4/4 |
| MC-05 | checkpoint 耗尽 | `ckpt_free=0` 且发生分支 → 走 ROB 反走恢复 | ≥ 1 次 |
| MC-06 | checkpoint 恢复 | 有 checkpoint 的误预测恢复 | ≥ 1 次 |
| MC-07 | `flush_all` | 复位后、`fence.i`、调试断点各 ≥ 1 次 | 3/3 |
| MC-08 | MSHR 满 | L1D MSHR = 8 且新缺失到达（反压） | ≥ 1 次 |
| MC-09 | Victim Buffer 满 | L1D/L2 Victim 满 | 2/2 |
| MC-10 | 写口冲突 | 同一周期 ≥ 2 个执行口竞争同一写端口并仲裁 | ≥ 1 次 |
| MC-11 | 旁路命中 | EX/MEM/WB 三级旁路各 ≥ 1 次（含 load 结果旁路） | 4/4 |
| MC-12 | store→load 转发 | 全重叠、部分重叠各 ≥ 1 次 | 2/2 |
| MC-13 | load 违例 replay | `replay` 由更老 store 地址变有效触发 | ≥ 1 次 |
| MC-14 | `stld_predictor` 误预测 | 预测无冲突但实际违例 | ≥ 1 次 |
| MC-15 | TLB 缺失 → PTW | ITLB/DTLB 各 ≥ 1 次 | 2/2 |
| MC-16 | A/D 硬件更新 | A 置位、D 置位各 ≥ 1 次 | 2/2 |
| MC-17 | `sfence.vma` 全/按 ASID/按 VA | 3 种粒度各 ≥ 1 次 | 3/3 |
| MC-18 | 保留集 | `lr.w` 后 SC 成功、SC 失败各 ≥ 1 次 | 2/2 |
| MC-19 | 非对齐拆分 | 跨行 load、跨行 store 各 ≥ 1 次 | 2/2 |
| MC-20 | 反压 | IQ/LSQ/ROB 满导致的 `ready=0` 与前端停顿各 ≥ 1 次 | 3/3 |
| MC-21 | 中断采样延迟 | 中断从挂起到被提交的最大延迟被记录（期望 ≤ 20 周期） | 记录并设门限 |
| MC-22 | `wfi` | 进入与唤醒各 ≥ 1 次 | 2/2 |

### 6.3 性能覆盖点

| ID | 指标 | 来源 | 目标（CoreMark / Dhrystone） |
|---|---|---|---|
| PC-01 | 分支预测准确率 | `perf_cnt_branch` / `perf_cnt_mispred` | ≥ 93% / ≥ 96% |
| PC-02 | L1I 命中率 | `perf_cnt_icache_miss` / 取指次数 | ≥ 95% |
| PC-03 | L1D 命中率 | `perf_cnt_dcache_miss` / 访存次数 | ≥ 95% |
| PC-04 | L2 命中率 | `perf_cnt_l2_miss` / L2 请求数 | ≥ 80% |
| PC-05 | IPC | `minstret` / `mcycle` | 记录基线；4 发射乱序相对顺序核提升 ≥ 1.3× |
| PC-06 | 发射槽利用率 | `perf_cnt_issue_slot_empty` / 总槽位 | > 80% |
| PC-07 | ROB 满占比 | `perf_cnt_rob_full_cycles` | < 15% |

> PC-01~PC-07 要求与 `08-verification.md` §5 一致；若时序降级（`CORE_WIDTH=2`），PC-05/PC-06 的门限按降级配置重新基线化并在报告中注明。

### 6.4 统计方式

| 方式 | 实现 | 输出 |
|---|---|---|
| RTL 内计数器 | `rv32gc_defs.vh` 定义 `` `SIM_COV ``；每个覆盖点一个 saturating 计数器（≥ 8 bit），由 `dbg_commit_*`/队列状态/事件脉冲驱动 | 仿真结束（`$finish` 前）由 `dbg_cov_dump` 打印 `sim/log/<test>/cov.log`，格式 `COV <ID> <count>` |
| 仿真侧脚本 | `scripts/cov_merge.py` 汇总 `cov.log` → `work/cov_total.log`；`scripts/cov_report.py` 生成"已覆盖/未覆盖"清单 | `work/cov_report.md`（含未覆盖点列表，作为回归门禁输入） |
| 指令/特权级覆盖 | 从 `rtl_trace.log` 解析（不依赖 RTL 计数器，避免计数器本身出错） | `work/fcov_report.md` |
| 性能计数 | `perf_cnt_*`（00 §7）+ `mhpmcounter` 只读映射 | `work/perf_<benchmark>.md` |
| 门禁 | `scripts/regress.sh --stage 6` 要求：FC-01/03/04/05 与 MC-01~MC-22 全绿；缺一项即非零退出 | — |

---

## 7. 回归脚本与 CI 约定

### 7.1 `scripts/regress.sh` 阶段划分

| 阶段 | 命令 | 内容 | 时间预算（单机 8 核） | 退出码 |
|---|---|---|---|---|
| `1 smoke` | `make -C sim smoke` | RTL 编译（iverilog）+ `tbtop_smoke` + 1 个最小 ELF | ≤ 1 min | 见 §7.2 |
| `2 unit` | `make -C sim unit` | §4 的 41 个单元测试（iverilog，并行 `-j8`） | ≤ 2 min | 见 §7.2 |
| `3 act-unpriv` | `make -C sim act-elfs && ./scripts/run_act.sh unpriv` | 294 个非特权 arch-test（verilator，`run_tests.py`） | ≤ 20 min | 见 §7.2 |
| `4 act-priv` | `./scripts/run_act.sh priv` | 153 个特权/Sv32/PMP 用例 | ≤ 25 min | 见 §7.2 |
| `5 directed` | `make -C sim emu ELF=sw/tests/**` | §5.2 的 116 个自研用例 + §5.4 压力 + §5.5/5.6 | ≤ 15 min | 见 §7.2 |
| `6 lockstep` | `./scripts/run_rand.sh --seeds 1..64` | §5.3 随机锁步 + Spike 比对 | ≤ 30 min | 见 §7.2 |
| `7 cover` | `python3 scripts/cov_merge.py && python3 scripts/cov_report.py` | 覆盖率汇总 + 门禁 | ≤ 1 min | 覆盖面不足 = 6 |

- `--stage <n>` 只跑第 n 级；`--from <n>` 从第 n 级跑到末级；缺省全跑；
- 每级失败默认**继续跑完**（除 `smoke` 外）以给出完整清单，最终退出码取"首个非零阶段"的码；
- 纯仿真阶段总预算 ≈ 95 min；CI 上 `act-priv` 与 `lockstep` 允许并行到两个 runner。

### 7.2 退出码约定

| 码 | 含义 | 典型来源 |
|---|---|---|
| 0 | 全部通过 | — |
| 1 | 测试失败（ELF 自校验/`tohost=3`/golden 不符） | 阶段 2~5 |
| 2 | 超时 | TB 硬超时、软超时 |
| 3 | 轨迹首个差异（`DIFF at seq=`） | 阶段 6 |
| 4 | 编译/环境错误（iverilog/verilator 报错、ELF 缺失、参考模型缺失） | 阶段 1~6 |
| 5 | 死锁/无进展检测触发 | 全部 |
| 6 | 覆盖率门禁未达 | 阶段 7 |
| 7 | 断言违例（`ASSERT <ID>`） | 全部 |
| 8 | 基础设施故障（磁盘满、`spike` 未安装） | 全部 |

### 7.3 失败时的最小复现信息（缺一不可）

| 项 | 内容 | 落盘位置 |
|---|---|---|
| 波形窗口 | `wave.fst` 的 `[失败周期-200, 失败周期+20]`；日志中打印 `wave.fst [cycle A, B]` | `sim/log/<test>/` |
| 轨迹首个差异点 | `DIFF at seq=<n>` + `field` + `prev_ok_seq`（§2.7） | `diff.log` |
| 随机种子 | `seed=<n>`（随机测试必填）；固定种子用例写 `seed=-` | `sim.log` 首行、`diff.log` |
| 断言编号 | `ASSERT <编号> cycle=<n> pc=<pc>` | `assert.log` |
| 复现命令 | 脚本在失败时打印单行可复现命令：`make -C sim emu ELF=<f> TRACE=1 DUMP=1 DUMP_FROM=<c> SEED=<n>` | stdout + `work/fail_repro.txt` |
| ELF/镜像哈希 | `sha1sum <elf>` 与 RTL 版本 `git rev-parse --short HEAD` | `work/fail_repro.txt` |

---

## 8. 上板验证接口

### 8.1 CONFREG 状态编码（数码管 / LED）

**FPGA 基址 `0x1FD0_0000`**：`LED +0xF000`、`LED_RG0/+0xF030`、`LED_RG1 +0xF040`、`NUM +0xF010`、`TIMER +0xE000`、DMA 门铃 `+0x1160`。

| 寄存器 | 位域 | 编码 | 含义 |
|---|---|---|---|
| `NUM[31:0]` | `[31:24]` | `0x01`~`0x0F` | **启动阶段号**：B1=0x01、B2=0x02、B3=0x03、B4=0x04、B5=0x05、B6=0x06、B7=0x07、B8=0x08（与 `07-fpga-timing.md` §5 一一对应） |
| | `[23:16]` | 子步骤号 | 该阶段内第几个子检查（1 起） |
| | `[15:8]` | 状态码 | `0x00` 运行中、`0x01` 通过、`0x02` 失败、`0x03` 超时 |
| | `[7:0]` | 错误码 | `0x01` DDR 校验、`0x02` NAND 读、`0x03` NAND 写、`0x04` Cache 一致性、`0x05` 中断、`0x06` 非法陷阱、`0x07` AXI 超时、`0x08` 其他 |
| `LED_RG0` | `[1:0]` | 1 / 2 | 1 = 绿 = 通过，2 = 红 = 失败（与仿真、平台 golden_trace 约定一致） |
| `LED_RG1` | `[1:0]` | 1 / 2 | 1 = 当前测试仍在运行（心跳，每秒翻转），2 = 已停机 |
| `LED[15:0]` | — | 位图 | 每个已通过的测试组占 1 位（B1~B8 顺序），便于一眼看进度 |

约定：**每次进入新阶段必须先写 NUM 的阶段号与状态"运行中"**，这样挂死时数码管就能指出卡在哪一步（这是上板最有效的定位手段）。仿真与上板共用同一套枚举，代码放在 `sw/tests/rvc_summary.h`，一处修改两处生效。

### 8.2 串口输出格式

```
[  0.000123] INFO  B2  test=ddr_check      PASS  256 MiB, 0 errors
[  0.000456] FAIL  B2  test=ddr_check      FAIL  addr=0x00100000 exp=0xdeadbeef got=0x00000000
[  0.000789] INFO  B3  test=csr_sm_0001    PASS  mstatus=0x00001880
```

| 字段 | 格式 | 说明 |
|---|---|---|
| 时间 | `[%12.6f]` | 秒，来自 CONFREG TIMER（`+0xE000`）或 `mtime` |
| 级别 | `INFO`/`FAIL`/`FATAL` | 仅 `FAIL`/`FATAL` 计入失败 |
| 阶段 | `B1`~`B8` | 与 §8.1 阶段号一致 |
| 测试名 | `test=<name>` | 与仿真侧同名（便于日志对比） |
| 结果 | `PASS`/`FAIL` | — |
| 细节 | 自由文本 | 单行，不得含换行；`exp=`/`got=`/`addr=` 固定顺序便于自动解析 |

- 脚本按 `grep -E '^(FAIL|FATAL)'` 判失败、`PASS` 计数；
- **ACT4 兼容**：`RVMODEL_IO_WRITE_STR` 输出到 UART `0x1FE0_01E0`，必须能让 `RVCP-SUMMARY: TEST (PASSED|FAILED|SIGRUN) - Test File ".*"` 原文通过，`scripts/run_act.sh` 用该正则解析；
- 上板串口参数：U-Boot/Linux 115200 8N1；烧写 bit 时 230400。

### 8.3 ILA 触发条件建议

| 用途 | 探针 | 触发条件 |
|---|---|---|
| 首次失败定位 | `dbg_commit_valid/pc/instr/rd/wdata/wen`、`dbg_state` | `dbg_commit_pc == <失败 PC>`（由串口/数码管给出） |
| 流水线停摆 | `rob_full/iq_full/lsq_full/rob_empty`、AXI `arvalid/awvalid/rvalid/bvalid` | `rob_full && !dbg_commit_valid` 连续 ≥ 16 周期 |
| 误预测风暴 | `redirect_valid/redirect_pc/redirect_rob_idx` | `redirect_valid` 在 64 周期内 ≥ 8 次 |
| AXI 卡死 | `arvalid/arready/rvalid/rready` | `arvalid && !arready` 或 `rvalid && !rready` 连续 ≥ 256 周期 |
| 陷阱循环 | `dbg_commit_excp_valid/excp_cause`、`trap_valid` | 同一 `excp_cause` 在 200 周期内 ≥ 4 次 |
| 采样深度 | — | ≥ 4096 样本，触发位置置中（50% pre-trigger）；信号名与 `dbg_*` 一一对应，便于与仿真波形对照 |

### 8.4 平台 UART 调试单元用法（`IP/DEBUG/debug_top.v`）

| 主机命令 | 作用 | 需要的接口 |
|---|---|---|
| `trace <pc>` / `t` | 跟踪到 PC | `debug_pc` |
| `list` | 列出断点 | — |
| `break <pc>` / `b` | 设置断点 | `break_point` |
| `step [n]` | 单步 n 条 | `break_point` |
| `continue` / `c` | 全速运行 | — |
| `infor <n>\|all` | 读架构寄存器 x0~x31 | `infor_flag`、`reg_num`、`rf_rdata` |
| `infom <addr> [addr2]` | 读内存 | AXI 读通道 |

接口语义（必须严格实现，否则调试器会读到错值）：

| 信号 | 方向 | 语义与判据 |
|---|---|---|
| `break_point` | in | 拉起后核**须在当拍**停止取指/提交（实现为 `flush_all` + 冻结前端）；重新 `continue` 需由调试单元撤下该信号 |
| `infor_flag` | in | 寄存器读请求；与 `reg_num` **同拍**有效 |
| `reg_num[4:0]` | in | 架构寄存器号；读数必须是**提交态**值（不是 PRF 中的推测值） |
| `rf_rdata[31:0]` | out | 必须在 `infor_flag` 有效的**同一拍**给出有效数据（组合读，不得打拍） |
| `ws_valid` | out | 提交一条写寄存器指令时置起；调试器据此前进一步 |

**验证要点**：`infor x0` 必须恒为 0；`infor` 读到的值必须等于同期 `debug0_wb_*` 提交轨迹推出的架构状态（用 `scripts/dbg_reg_check.py` 从 `rtl_trace.log` 重建寄存器文件与 `rf_rdata` 逐条比对）；`break_point` 后的恢复必须无指令重复执行（`mepc` 语义不能被调试断点污染）。

---

## 9. 一致性核对表（RTL/脚本联调前逐项打勾）

- [ ] `dbg_commit_*` 的位宽与 §2.2 一致，且 `debug0_wb_*` 仍为 32 位平台契约（03 §7.1）
- [ ] 轨迹 11 列、分隔符 `|`、定宽十六进制（`scripts/check_trace.sh` 逐行校验）
- [ ] `flush_rob_idx` 年龄比较函数全核唯一（00 §3），断言 PIPE-05 用它
- [ ] CSR 写只在 RT 级生效（CSR-01），执行级读为组合读（03 §8）
- [ ] 地址映射与 §1.3 一致，且 CONFREG 偏移经 `scripts/check_addrmap.sh` 与 chiplab RTL 比对通过
- [ ] 退出码（§7.2）在 `tb_iverilog.v` / `tb_verilator.cpp` / `scripts/regress.sh` 三处一致
- [ ] `tohost` 监视地址 `0x8000_1000` 与 `link.ld` 的 `.tohost` 段实际地址一致（构建后用 `nm` 核对，不一致即为环境错误退出码 4）
- [ ] 覆盖点 ID（FC-*/MC-*/PC-*）在 RTL 计数器与 `cov_report.py` 两处同名
