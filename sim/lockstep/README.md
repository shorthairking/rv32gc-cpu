# sim/lockstep/ —— Spike 锁步底座（阶段二 2A，`08-baseline-5stage.md §8.3`）

> 一句话：**同一条 ELF** 同时喂给 DUT（iverilog 跑 `core_top`）与本机 Spike，
> 以"指令提交"为单位**逐条比对 PC 与 rd 写值**，首个分歧点定位并打印上下文；
> 全部一致 ⇒ 唯一一行 `LOCKSTEP: N/N PASS`，否则非零退出且**无 PASS 兜底**。

---

## 1. 文件清单

| 文件 | 作用 |
|---|---|
| `run.sh` | 端到端入口：as/ld/objcopy → iverilog+vvp（DUT）→ spike（REF）→ cmp_commit.py |
| `cmp_commit.py` | 逐条比对器：解析 DUT 提交 trace 与本机 Spike commit log，首个分歧点定位 + 非零退出 |
| `tb_lockstep.sv` | DUT 侧 TB：例化 `rtl/top/core_top.v` + `sim/tb/sim_mem_model.sv`（**只读复用**）+ 地址翻译层；落 `dut.trace`；判据六项 fail-closed |
| `prog/lock_hello.S` | 默认测试程序（≥60 条：整数算术/分支/访存/M/CSR 混合），链接 `0x80000000` |
| `prog/csr_hazard.S` | **缺陷复现程序**：CSR 写→紧邻读（k=0）用例，跑它应 **FAIL**（见 §6） |
| `prog/link.ld` | 链接脚本：`.boot@0x1C00_0000`（2 条复位跳转桩）+ `.text@0x8000_0000` |
| `build/` | 中间产物（`*.elf/.hex/.o/.vvp/*.log/dut.trace/spike.trace`），`.gitignore` 已忽略 |

## 2. 用法与判据

```sh
cd rv32gc-cpu
./sim/lockstep/run.sh                 # 默认 lock_hello：rc=0 且唯一一行 LOCKSTEP: N/N PASS（N=108）
./sim/lockstep/run.sh --self-test     # 反证自测：故意篡改 dut.trace 一条 rd 写值 ⇒ 必须报分歧（副本，不影响正式产物）
./sim/lockstep/run.sh --prog csr_hazard   # 缺陷复现：期望 rc≠0 + CMP_DIVERGENCE（见 §6）
```

- `--min-commits N`：比对条数下限（默认 60；`csr_hazard` 自动降到 10）。
- 失败路径：`LOCKSTEP_RUN: FAIL …` / `CMP_DIVERGENCE: 第 N 条：…` / `CMP_ERROR: …`，
  一律非零退出，**且输出里不含 `PASS` 字样**（避免 `AGENT.md §0.6` 点名的"假 PASS"）。

## 3. 结构：DUT 侧怎么跑起来

```
tb_lockstep
  ├── core_top            48 端口逐字契约（rtl 只读；与 sim/tb/tb_core_top.sv 同一接法）
  ├── lockstep_addr_map   纯组合地址翻译（见下）
  ├── sim_mem_model       AXI4 从设备（**默认参数原样复用**：XIP 0x1C00_0000 / DDR3 0x0 / UART 0x1FE0_01E0）
  └── 预载                load_prog()：解析 objcopy -O verilog 的 hex（两个 `@` 段）→ 层次写入模型数组
```

**为什么要有 `lockstep_addr_map`（关键设计点）**

1. 本核复位取指地址由 `rtl/pkg/core_params.vh` 的 `` `RV32GC_RESET_PC `` 固定为
   `0x1C00_0000`（`core_top.v:2764` 有编译期自检，禁止改），而 `08 §8.3` 的锁步布局是
   Spike 习惯的 `0x8000_0000`；生产 RTL 又禁止 `0x8000_0000` 别名
   （`07-verification.md §4.3`）。⇒ 程序在 ELF 里放**两份**：`0x1C00_0000` 处 2 条
   复位跳转桩（`lui`+`jalr`）、主体在 `0x8000_0000`。DUT 与 Spike **都从
   `0x1C00_0000` 的第 0 条指令开始**（Spike 用 `--pc=0x1C000000`），两条轨迹
   从第 0 条起 1:1 对齐，PC 逐条严格相等。
2. `sim_mem_model` 的 XIP 窗口判定写死为宏（`0x1C0`/`0x1FE8`，不可参数化），而
   **`ddr3_read()` 以 `ddr3_mem[a[31:2]]` 作绝对下标**（隐含 `DDR3_BASE==0`）——
   把 DDR3 参数改到 `0x8000_0000` 会读到数组越界（返 `x`，被"未写入按 0"逻辑折叠成 0）
   ⇒ 取回全 0 指令 ⇒ 非法指令陷阱。**本会话实测**：AR 已到 `0x80000000`，但核内
   `fetch_pc` 随即变 `0x0`。
   ⇒ 因此**不改模型参数**，在 DUT 与模型之间插一层纯组合地址翻译：
   DUT 侧 `0x8000_0000..0x800F_FFFF` → 模型 DDR3 窗口内的 `0x0010_0000..0x001F_FFFF`，
   其余地址（XIP、UART、DDR3）原样透传。这正是 `07-verification.md §4.3` 的
   "方案 2：为仿真单独准备映射到 `0x8000_0000` 的内存模型"的落地形式。

**结束协议**（两个程序共用，也是比对器的锚点）

| 动作 | 地址 | 证据 |
|---|---|---|
| 写魔数 `0x600D_5EED` | `0x8000_2000` | Spike trace 的 `mem 0x80002000 0x600d5eed`；DUT 侧 AXI AW 观测（诊断） |
| 写结束铃 `0x5A` | `0x1FE0_01E0`（UART） | `sim_mem_model` 捕获（`uart_write_count>=1`，TB 判据 C6）；Spike 侧 `mem 0x1fe001e0 0x0000005a` |
| 进入死循环 | `lockstep_spin` 标签 | TB 以"提交到该 PC"为终止点（不记录该条），因此 `dut.trace` 末条 = 结束铃那条 |

UART 结束铃这一条是**必须**的：它属平台外设窗口（`PA[31:16]==0x1FE0`），
本核按**非缓存**直写 AXI（`rtl/mem/mmio_route.v §2.3/§4`），所以 TB 能在总线上看到它，
从而确定"程序真的跑到了结尾"；而 `0x8000_2000` 的魔数写在当前 PMA 下也走 AXI
（实测），但**只作诊断不加判据**（将来若改成写回缓存，不该因此假失败）。

## 4. Spike 调用口径（**本机 1.1.1-dev 实测**）

```sh
spike --instructions=4096 --pc=0x1C000000 -l --log-commits --log=build/spike.trace \
      --isa=rv32imafdc_zicsr_zifencei_zicntr_zicbom \
      -m0x1C000000:0x1000000,0x80000000:0x10000000,0x1FE00000:0x1000 build/lock_hello.elf
```

与任务书模板的差异及**实测理由**（都是本机真实行为，不是偏好）：

| 差异 | 理由（实测） |
|---|---|
| 加 `--pc=0x1C000000` | 不给 `--pc` 时 Spike 先跑内置 boot ROM（`0x1000` 起 5 条）再跳 ELF 入口，轨迹前 5 条无法与 DUT 对齐 |
| `-m` 三个区域（而非只有 `0x80000000`） | ① `0x1C00_0000`：跳转桩（DUT 复位取指处）；② `0x8000_0000`：任务指定的仿真布局；③ `0x1FE0_0000`：UART 结束铃——**不映射它**时 Spike 在结束铃那条 store 上取 access fault 就停了（实测），双方跑不到同一点 |
| `--log-commits` 配 `--log=<file>` | 本机实测：给了 `--log=` 时 commit 行**落在文件里**（与 `AGENT.md §3.1`"输出在 stderr"的旧口径并存——不给 `--log=` 时确实在 stderr）。`--log` 文件里**反汇编行与 commit 行交错**，比对器按正则挑 commit 行 |
| `--instructions=4096` | 程序末尾是死循环；DUT 侧由 `TERM_PC` 终止，Spike 侧用上限兜底 |
| ELF 里多一个 `0x1C00_0000` 段 | 见 §3.1：`RESET_PC` 固定 + 禁止 RTL 别名 ⇒ 必须用 2 条桩跳进仿真布局 |
| 自写 `link.ld`（不用 `-Ttext=`） | 实测本机 ld 对 `-Ttext=0x80000000` 会把 LOAD 段起点页对齐回退到 `0x7FFF_F000`，Spike 加载报 `Access exception … 0x7ffff000 is invalid` |

### 4.1 Spike commit 行实测样例（比对器解析式的依据）

```
core   0: 3 0x1c000000 (0x800002b7) x5  0x80000000                        # 整数写回
core   0: 3 0x80000020 (0x01de2023) mem 0x80001004 0x00000124             # 存数：mem = 地址 + 数据
core   0: 3 0x80000024 (0x000e2f03) x30 0x00000124 mem 0x80001004         # 取数：mem **只有地址**
core   0: 3 0x800000e4 (0x340b1bf3) x23 0x00000000 c832_mscratch 0xabcde000 # CSR 写：c<十进制号>_<名字>
```

判别式：`^core\s+<hart>:\s+<priv 单个数字>\s+0x<addr>\s+\(0x<insn>\)`；
`--log` 文件里的反汇编行第二字段直接是地址（`core   0: 0x1c000000 (0x…) lui …`），不会误配。
字段解析对未知 token **直接报错**（fail-closed），不"看不懂就当通过"。

## 5. 比对口径与**覆盖范围限制**（务必知情）

比对字段（任务口径）：**PC 必须相等** + **整数 rd 写值必须相等**（`wen=1` 时比对；
`wen=0` 时要求 Spike 侧也没有整数写；`x0` 天然跳过）。

限制（2A 提交探针 `debug0_wb_pc/wb_rf_wen/wb_rf_wnum/wb_rf_wdata` 的观测能力所限）：

- **不比对**访存地址/数据与 CSR 变更（探针无此通路）。访存数据正确性只通过
  "存→取回读再参与运算"间接体现（存错数据 ⇒ 后续 rd 写值分歧）。
- **程序内不得出现 F/D 指令**：探针对 FP 写回也置 `rf_wen[0]`（`core_top.v:2755` 的
  `mw_fp_we`），而 rd 号是浮点寄存器号 ⇒ 会被当整数写比对而假失败。
  （任务口径"浮点先不比对"，因此程序不覆盖浮点；浮点比对留待后续扩展探针。）
- **不得读计数器**（`mcycle`/`minstret`/`mtime`）：DUT 与 Spike 周期数不同 ⇒ 必然伪分歧。

## 6. 缺陷发现记录：CSR 写 → **紧邻**读 读到旧值（2A RTL，待修）

- **现象**（`./sim/lockstep/run.sh --prog csr_hazard`，rc=1）：

  ```
  CMP_DIVERGENCE: 第 5 条：DUT rd=x10 写值=0x00000000  spike 写值=0x11111000
     [   4] DUT   pc=0x80000008 wen=1 rd=x5  wdata=0x00000000
     [   4] SPIKE core   0: 3 0x80000008 (0x340b12f3) x5  0x00000000 c832_mscratch 0x11111000
  >> [   5] DUT   pc=0x8000000c wen=1 rd=x10 wdata=0x00000000     # csrr a0, mscratch
  >> [   5] SPIKE core   0: 3 0x8000000c (0x34002573) x10 0x11111000
  ```

  即 `csrrw t0,mscratch,s6` 之后的**紧邻** `csrr a0,mscratch` 读到旧值 `0`。
- **距离profile**（同一程序内交替写入值区分新旧）：k=0（紧邻）**错**；k=1、k=2 **正确**。
- **根因走查**（只读；不改 rtl）：
  - CSR **读**在 E 阶段组合产生（`core_top.v:1113` `csr_rdata`，用 `de_csr_addr` = D→E 寄存器），
    结果随 `em_csr_rdata` 写回 rd；
  - CSR **写**在 W 阶段落盘（`core_top.v:1613` `csr_wen_w` → 写口 `1623`）；
  - 读旁路只有一级（`core_top.v:1104`）：`(csr_wen_w & (mw_csr_addr==de_csr_addr)) ? csr_rdata_w : csr_rdata_raw`
    —— 覆盖"W 写 → E 读"（k=1），**缺"M 写 → E 读"**（k=0：写指令在 M、读指令在 E）⇒ k=0 读到旧值。
  - 修复方向：在 `csr_base_rd` 优先链补一级 M 阶段旁路
    `(em_csr_we & <em 槽有效且未作废/未冲刷> & (em_csr_addr==de_csr_addr)) ? em_csr_wdata : …`
    （`em_csr_wdata` = `core_top.v:2392` 锁存的 `csr_new_e`）。
  - ISA 依据：CSR 写必须对程序序在后的读可见（Zicsr 顺序语义）。
- **当前处置**（临时、显式）：`prog/lock_hello.S` 的 CSR 段刻意在写与读回之间保留
  ≥2 条无关指令（k>=1），使锁步底座在 RTL 修复前能全绿；k=0 用例由
  `prog/csr_hazard.S` 独立复现。**RTL 修复后应把 k=0 的紧邻读回加回 `lock_hello.S`**
  作为回归保护。

## 7. 其他已知偏差 / 待办

- **`--elf <elf>` 入口（M2 arch-test 用）尚未提供**：`08 §8.3` 的测试入口写的是
  `sim/lockstep/run.sh --elf <elf>`；本期实现的是 `--prog <source.S>`（自带
  汇编→链接→hex 全流程，终止协议由 `lockstep_spin` 标签给出）。要支持**外来 ELF**
  （arch-test 产物没有 `lockstep_spin`、也没有 UART 结束铃），需要另定一套终止协议
  （例如 Spike 侧 `tohost`/signature 区结束、或"提交条数 = Spike 报出的条数"），
  属 M2 的扩展项，不在本期范围。
- 2A 提交探针缺访存地址/数据与 CSR 变更 ⇒ 比对强度低于 `08 §8.3` 的完整清单
  （那里列举了 mem/CSR 字段；`docs/design/07-verification.md §4.2` 的序列图同样写了）。
  待 2B（`03-out-of-order.md` 的提交日志）或专用 difftest 探针补齐。
- DUT 侧魔数写只用 AXI 观测（诊断）验证；若将来 `0x8000_0000` 改为写回缓存，
  该观测会变 0，属预期（不作为判据）。
- 每个新 ELF 都需要满足结束协议（魔数 + UART 结束铃 + `lockstep_spin` 标签），
  `run.sh --prog <path.S>` 可直接跑其它程序。
- 建议接入回归：`scripts/regress.sh` 目前只遍历 `sim/unit/tb_*.sv`；把
  `sim/lockstep/run.sh` 作为一条独立的 L2 入口加进去（由母 Agent 决定，本期未改该脚本）。
