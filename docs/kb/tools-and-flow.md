# 工具链与流程口径（RV32-GC 项目）

> **本文性质**：本项目**唯一**的工具链版本、环境坑、构建流程与验收纪律台账。
> **强度约定**：**[环境实测]** = 本次会话命令直接观测；**[旧项目转述]** = 来自旧项目 `AGENT.md` 口径、行为级未复现；**[工程约定]** = 本项目自定纪律。

---

## 1. 工具链版本台账

| 工具 | 版本 | 路径 | 强度 |
|---|---|---|---|
| RISC-V GCC | **16.1.0**（`riscv32-unknown-linux-gnu-gcc (g6afcc4f6d) 16.1.0`） | `/opt/riscv/bin/riscv32-unknown-linux-gnu-` | [环境实测] |
| Verilator | **5.020**（`2024-01-01 rev (Debian 5.020-1)`） | 系统包 | [环境实测] |
| Icarus Verilog | **12.0 (stable)** | 系统包 | [环境实测] |
| Vivado | **2023.2** | `/home/shorthair/fpga/Vivado/2023.2` | [环境实测] |
| 参考模型 Spike | **缺失**（需重取编译） | — | [环境实测] |

- 复现命令：
  ```sh
  iverilog -V | head -2
  verilator --version
  /opt/riscv/bin/riscv32-unknown-linux-gnu-gcc --version | head -1
  ```
- **Spike 现状**：工作区内无 Spike 源码。旧编译产物在旧项目内，**不复制**。[旧项目转述]
  → **待办**：重新取上游源码并编译到本项目（见 §6）。

---

## 2. iverilog 宏值陷阱（**高优先级**）

- **规则**：`iverilog -D` 的**宏值必须写成 Verilog 字面量**，如 `-DRESET_PC=32'h1C000000`、`-DFREQ=32'd33000000`。
- **反例**：写成 `-DRESET_PC=0x1C000000` 会**炸编译**（`0x…` 不是合法 Verilog 字面量）。[旧项目转述]
- **影响面**：所有带 `-D` 的 TB 构建脚本、回归脚本。
- **[工程约定]** 在回归脚本里**禁止**用 `0x` 形式传宏值；建议封装成函数收口，避免各脚本各自为政。

### 2.1 iverilog 表征缺陷规约（2026-09-14 实测）

- **现象（缺陷）** [环境实测]：**连续赋值（`assign`）里调用 `function`，且该 `function` 内部读模块级信号**时，**iverilog 12.0 不会在该模块级信号变化时重求值**这条连续赋值——首次求值的结果被"记住"。同一写法在 **Vivado（综合与仿真）与 Verilator 上结果正确** ⇒ 这是 iverilog 的**表征缺陷**（精化/敏感表推导问题），**不是 RTL 语义问题**；但其后果是回归**静默用错值**，落在 §5「未捕获即失败」要防的"假 PASS"风险面上。
- **规约（三条，硬性）**：
  1. **被 `function` 读取的信号必须显式作为 `function` 的 `input` 传入**（`function f(input a, input b);`），不得让 `function` 直接引用模块级 `reg`/`wire`；
  2. **CSR 读端口用「单 reg 单赋值」的 `always @(*)` case 实现**（一个 `always @(*)` 只给一个 `reg` 赋值；与 `docs/design/08-baseline-5stage.md` §7.4 红线 3 **不冲突**——红线禁止的是**多 reg** 赋值块）；
  3. **sfence / 中断类组合判据不得藏进「读模块级信号的 `function`」**，一律写成显式信号 + `assign` 直连，或按第 2 条的单 reg case 形式。
- **定位手段** [工程约定]：同一份 RTL 分别跑 iverilog 与 Verilator（或 Vivado 仿真）；若 iverilog 结果与后两者不一致，**先按本规约改写再复跑**，不要把差异当成"仿真器口味不同"放过。

---

## 3. Vivado 2023.2 三坑（必读）

### 坑① 缺 `libtinfo.so.5` → 必须前置 `LD_LIBRARY_PATH`

- 现象：Ubuntu 24.04 只有 `libtinfo.so.6`，Vivado 2023.2 需要 `libtinfo.so.5`。
- **证据（成立）**：[环境实测] Vivado 自带的 Rhel/9 目录下**存在**库文件：
  ```sh
  ls /home/shorthair/fpga/Vivado/2023.2/lib/lnx64.o/Rhel/9/libtinfo.so.5
  # → 存在
  ```
- **绕过**：
  ```sh
  export LD_LIBRARY_PATH=/home/shorthair/fpga/Vivado/2023.2/lib/lnx64.o/Rhel/9:$LD_LIBRARY_PATH
  ```
- **[环境实测]** `~/.bashrc:149` 已有 `source /home/shorthair/fpga/Vivado/2023.2/settings64.sh`，即 Vivado 已在 PATH 中；但 `settings64.sh` **不解决** `libtinfo.so.5`，仍需上面这行前缀。

### 坑② 工程模式自动层次引擎失效 → `source_mgmt_mode None`

- 现象：Vivado 工程模式下自动层级推断失败，找不到 top。
- **绕过**：`set_property source_mgmt_mode None [current_project]` + **显式指定 top**；或改走**非工程模式**（`read_verilog` + `synth_design`）。
- 强度：**[旧项目转述]**（行为级，未在本会话复现）。

### 坑③ 沙箱 HOME 污染 → `HOME` 指向项目内目录

- 现象：Vivado 会在 `$HOME` 下写 `.Xil`/`.vivado*` 等状态，污染沙箱或权限失败。
- **绕过**：把 `HOME` 指到项目内专用目录，例如：
  ```sh
  export HOME=<工作区>/rv32gc-cpu/.vivado_home
  ```
- 强度：**[旧项目转述]**（行为级）。
- **旁证**：[环境实测] 工作区根目录已存在 `.Xil/`（Vivado 状态目录）——说明历史上确实在默认 HOME 下写过状态。

### 坑④ 非工程模式 `read_verilog` **不接受** `-include_dirs`（M4 实测，2026-09-18）

- 现象：`read_verilog -include_dirs {rtl/pkg rtl .} <files>` 直接报
  `ERROR: [Common 17-170] Unknown option '-include_dirs'`；`-incdir` 同样不认。
  batch/非工程模式下 `read_verilog` 只支持 `[-library] [-sv] [-quiet] [-verbose]`
  （`read_verilog -help` 实测输出）。
- **后果**：RTL 内混用两种 `` `include `` 写法（裸名 `"rv32_defs.vh"` 与仓库根相对
  `"rtl/pkg/rv32_defs.vh"`）时，include 搜索路径无处可传 ⇒ 综合在编译期失败。
- **绕过**：把搜索目录交给 **`synth_design -include_dirs`**：
  ```tcl
  set ::RV32_INC_DIRS [list $PKG_DIR $RTL_DIR $PROJ_ROOT]
  read_verilog $pkg_files       ;# *.vh 先读（宏真源进定义表；.vh 有 ifndef 守卫，重复读安全）
  read_verilog $rtl_files
  synth_design -top core_top -part $xc7a200tfbg676-2 \
               -verilog_define RV32GC_USE_VIVADO_IP -include_dirs $::RV32_INC_DIRS
  ```
- 强度：**[环境实测]**（命令 + 报错原文 + 修复后 rc=0，见 `fpga/tcl/synth.tcl` §2.3 注释）。

### 坑⑤ RTL 里的 SystemVerilog 定宽转换 `N'(expr)` 会让 Vivado 编译失败

- 现象：`rtl/plic/plic.v` 原写 `5'(SOURCE_MIN)`（定宽转换，SystemVerilog 语法），
  Vivado 的 Verilog（非 `-sv`）模式报
  `ERROR: [Synth 8-2716] syntax error near '''`，**整核无法综合**（9 个 error）。
  iverilog（`-g2012`）能编过 ⇒ 该缺陷只在综合侧暴露，回归发现不了。
- **口径**：本项目 RTL 是 **Verilog-2001**（综合侧不启用 `-sv`：全量文件按 SV 编译会
  引入标识符与保留字冲突风险）。RTL 内禁止使用 `N'(expr)`、`always_ff`、`logic` 等
  SV-only 构造；定宽比较直接写 `(a >= CONST)`（常量 ≤ 位宽时逐位等价）。
- 强度：**[环境实测]**（M4：修复前 9 error / 修复后 0 error；`./scripts/regress.sh`
  23/23 不变 ⇒ 语义等价）。

### 坑⑥ `read_ip` 之后必须 `generate_target {synthesis}` + `synth_ip`

- 现象（非工程模式，M4 实测 2026-09-18）：只 `read_ip <xci>` 就 `synth_design`，
  报 `ERROR: [Synth 8-439] module 'blk_mem_gen_cache_data' not found`；
  只补 `generate_target {synthesis} [get_ips]` **仍然报同样的错**（它只把 IP 综合源码
  写到 `<ip>/synth/`，本项目 5 个 IP 产出的都是 **VHDL 参考源**，并未挂进内存工程的编译序）。
- **正解**（顺序不能少）：
  ```tcl
  create_project -in_memory -part xc7a200tfbg676-2   ;# 见坑⑧
  read_ip $xci_files
  generate_target {synthesis} [get_ips]
  synth_ip [get_ips]                                  ;# ★ 关键：OOC 综合出 DCP 并挂进工程
  synth_design -top core_top -part ... -verilog_define RV32GC_USE_VIVADO_IP
  ```
- 强度：**[环境实测]** 对照实验 `fpga/scratch/ip_flow2.tcl`：模式 D（含 `synth_ip`）
  `RESULT_D: SYNTH_OK`；不含 `synth_ip` 时 9 个 error（module not found）。
- 代价：`synth_ip` 会对每个 IP 跑一次 OOC 综合（本项目 5 个 IP 约 2–4 min，其后
  顶层综合以黑盒链接 DCP）。

### 坑⑦ 非工程模式的时钟约束必须**早于** `synth_design`（否则综合不是时序驱动）

- 现象：把 `create_clock` 放在 `synth_design` **之后**，综合阶段"无时钟"⇒ Vivado
  不做时序驱动优化（不按路径延时重构/复制/平衡），WNS 与最终可实现频率都明显偏差。
- **正解**：把约束写进 XDC，在 `synth_design` **之前** `read_xdc`（Vivado 在细化后、
  综合优化前施加约束；引脚级约束可留给实现阶段）。
  本项目：`fpga/soc_up.xdc`（平台时钟口径的本地只读拷贝，周期用占位符
  `__CLK_PERIOD_NS__`）由 `synth.tcl` 替换成本次 tclarg 的周期后落到
  `fpga/out/soc_up_<period>ns.xdc`，再 `read_xdc` —— 60 MHz 与 100 MHz 两种跑法
  共用**同一份**约束真源。
- 强度：**[环境实测]**（`fpga/tcl/synth.tcl` §3 的 `rv32_stage_xdc`）。

### 坑⑧ 非工程模式的隐式工程默认 part 是 `xc7k70tfbv676-1`

- 现象：不 `create_project` 直接 `read_ip` + `generate_target`，报
  `CRITICAL WARNING: [filemgmt 20-1365] Unable to generate target(s) ... IP file is locked`
  `Locked reason: Current project part 'xc7k70tfbv676-1' and the part 'xc7a200tfbg676-2'
  used to customize the IP do not match` ⇒ IP 综合产物生成不出来。
- **正解**：读入 IP 之前 `create_project -in_memory -part $PART`（或
  `set_property part $PART [current_project]`），保证工程 part 与 IP 定制 part 一致。
- 强度：**[环境实测]**（M4 首次全核综合失败即此因）。

### 坑⑨ 综合脚本必须**幂等**：`create_ip` 重复运行会新建 `<ip>_1` 目录

- 现象：重复跑 `create_ip.tcl` 后 `fpga/ip/` 下出现 `rv32_div_1/`、`rv32_mult_signed_1/`
  …（每个新 Vivado 会话 `get_ips` 都是空的，"先查 get_ips 再 create"挡不住重复创建）。
  随后 `synth.tcl` 的 `glob fpga/ip/*/*.xci` 会把重复 xci 一起 `read_ip` ⇒
  `CRITICAL WARNING: [IP_Flow 19-3389] Failed to import IP file ... IP name '<ip>' is
  already in use in this project`。
- **正解**：`create_ip.tcl` 里统一走 `ensure_ip`：**磁盘上已有 `<ip>/<ip>.xci` 就
  `read_ip` 复用**，否则才 `create_ip`（`grep -n "^ensure_ip" fpga/tcl/create_ip.tcl`
  仍是"用了哪些 IP"的可审查入口）。
- 强度：**[环境实测]**（M4 实测踩坑 → 修复后重复运行 rc=0 且不再产生 `_1` 目录）。

### 坑⑩ Vivado RAM 推断**只支持单写口**：多写口阵列会退化成"寄存器 + 大 mux"

- 现象（M4 实测，2026-09-18）：`cache_tag_array` 把 `{tag,dirty,valid}` 打包成一个阵列、
  且有**两个写口**（`if (wr_en) mem[a]<=…` 与 `if (dirty_clr_en) mem[b][k]<=0` 并存）
  ⇒ Vivado **完全不推断 RAM**（`LUT as Distributed RAM = 0`），改建成寄存器堆 + 256:1 读 mux：
  6 路 Tag 阵列吃掉 **75 119 LUT + 31 872 FF**（占非 FPU 全核 LUT 的 **64 %**，
  其中 `u_l1d` 一个模块 70 258 LUT）。
- **口径**：一个 `reg [W-1:0] mem [0:D-1]` 只有**一个写口**才能推断 RAM（LUTRAM/BRAM）；
  需要"第二个写口"时，要么把被写字段**拆成独立阵列**（各自单写口），要么让第二路写与
  第一路**互斥**后用 `if / else if` 合并为一路（并在 RTL 加契约自检，违反即 `$fatal`）。
  另外：小容量、随机寻址的阵列建议显式写 `(* ram_style = "distributed" *)`
  （综合**属性**、不是原语，红线 1 允许），让推断结果确定、可复现。
- **收益实测**（同一脚本、同一周期、同一激励）：LUT 116 785 → **37 382（-68 %）**，
  FF 47 190 → 15 412，综合后 WNS -4.329 ns → **-2.783 ns**；
  `REGRESS: 23/23 PASS` + arch-test I/Zicbom/SvZicbo/SvPMPZicbo/Sv 全绿（语义不变）。
- 强度：**[环境实测]**（对照报告 `fpga/out/scratch_nofpu_utilization_hier.rpt` 前后两版 +
  `fpga/M4-report.md` §5 改动 4）。

### 三坑统一入口（**已落地**）

- **目标**：`fpga/run_vivado_batch.sh <tcl>`，在脚本内一次性设置 坑① 的 `LD_LIBRARY_PATH`、坑③ 的 `HOME`、并以非交互批处理方式跑 Tcl。
- **现状（2026-09-18 更新）**：**已落地** `fpga/run_vivado_batch.sh`（三坑封装 +
  `--dry-run` 自检 + 日志落 `fpga/out/<tcl>.vivado.log`）；配套 Tcl 为
  `fpga/tcl/{create_ip,synth,impl}.tcl`（**非工程模式**，坑② 不适用）。
  原先"`fpga/` 目录尚不存在"的记录已过时。
- **[工程约定]** 所有 Vivado 调用一律经该入口，**禁止**散落 `vivado -mode batch`——
  否则三坑（及坑④）会被逐个重新踩一遍。

---

## 4. 镜像切分：`objcopy` 按 **LMA** 切镜像

- **规则**：从 ELF 生成上板/烧写镜像时，**按 LMA（Load Memory Address，加载地址）切分**，不是按 VMA。
- **原因**：链接脚本中 `.data` 等段的 VMA（运行地址）与 LMA（加载地址）通常不同；烧写镜像必须携带 LMA 语义，否则 `.data` 初值丢失。
- **典型用法**（示意，具体段名随链接脚本）：
  ```sh
  riscv32-unknown-linux-gnu-objcopy -O binary --only-section=.text <elf> <out>.bin
  ```
- 强度：**[旧项目转述]**（工具口径本身为 objcopy 通用语义）。
- **[工程约定]** 镜像生成脚本必须**打印每段的 LMA/VMA 对照表**（`readelf -l` / `objdump -h`），作为打包日志的一部分——否则无法审查镜像是否切对。

---

## 5. 回归纪律：**"未捕获即失败"**

- **最高纪律**：自测/回归脚本必须做到 **"未捕获即失败"**（fail-closed）——**兜底文案中不得出现 `PASS` 字样**。
- **事故背景**：[旧项目转述] 旧项目曾因**正则不配平** + **兜底文案含 PASS**，导致整批测试**"假 PASS"**。
- **落地要求** [工程约定]：
  1. 脚本出口状态由**显式计数器**决定：必须 `捕获数 > 0` 且 `失败数 == 0` 才返回 0。
  2. **默认分支**输出的是 `FAIL`/`UNKNOWN`，绝不输出 `PASS`。
  3. 正则必须**成对**（先 `grep -c` 计数再断言计数，而不是"匹配到就通过"）。
  4. 脚本**必须能被独立审查**：单个文件、无隐式依赖、无外部状态。
- **测试必须"漏判即失败"** [旧项目转述]：
  - **变异测试 / 反证实验** —— 关掉被测特性后，测试**必须 FAIL**。若关掉特性测试仍 PASS，说明该测试**没在测**它。
  - 这是证明"测试真的在测"的唯一手段。

---

## 6. 参考模型 Spike（**待重取编译**）

- **现状**：工作区**无 Spike 源码**；旧编译产物在旧项目内，**不复制**。[环境实测 + 旧项目转述]
- **必须重新取源码并编译**（步骤口径供参考）：
  1. `git clone` 上游 `riscv-isa-sim`；
  2. `mkdir build && cd build && ../configure --prefix=<项目内 prefix>`；
  3. `make -j$(nproc)`；
  4. **验证可执行且版本正确**（打印 `--help` 或版本）。
- **使用口径** [旧项目转述]：
  - `--log-commits` 的输出走 **stderr**（不是 stdout）——重定向时别只抓 stdout；
  - 内存映射用 `-m0x80000000:0x10000000,...` 形式；
  - **RISC-V 习惯的 `0x8000_0000` 仅用于仿真/arch-test 布局**；上板物理地址以平台为准（DDR3 默认从设备 `0x0–0x07FF_FFFF`，SPI XIP `0x1C00_0000`）——见 `docs/kb/platform-facts.md` §2。
- **门禁** [工程约定]：Spike 编译成功并通过自检前，**锁步验证（difftest）不得开启**——否则"参考模型自身失败"会被误判成被测核的缺陷。

---

## 7. 本项目流程纪律

### 7.1 平台树只读

- `chiplab/`、`la32r-uboot/`、`la32r-Linux/`、`opensbi/`、`u-boot/`、`linux/` 一律**只读分析**，**禁止修改**。
- 上游源码树**不复制**进本项目：用"**新增文件 + 补丁序列 + 构建脚本**"管理，版本号记录在 `sw/*/UPSTREAM.md`。[旧项目转述]

### 7.2 位域改动唯一真源

- 平台侧位宽真源：`chiplab/chip/soc_demo/loongson/config.h:46-100`。
- 本项目侧真源：`rtl/pkg/*defs.vh`。
- [工程约定] 改位域**先改真源**，再全量同步所有使用处；改完**必须 grep 核对新端口两侧都接上**。

### 7.3 每阶段收尾

- 总结 → git 提交 → **停下等用户审阅与明确指令**；阶段开始先读台账。[旧项目转述]
- **回归期间不得改 RTL**（否则失败无法归因）。[旧项目转述]

### 7.4 长任务

- 长后台任务用 `nohup` 脱离，**不要在轮内 `sleep` 空等**。[旧项目转述]
- **子 Agent 结论 ≠ 验收**：母 Agent 必须**复跑关键命令**确认。[旧项目转述]

### 7.5 失败定位

- 失败定位**先假设自己的缺陷**（转发/冒险/仲裁），用旧版本 RTL 做对照实验判定；"框架/生成器有缺陷"是**低概率假设**。[旧项目转述]
- 参考模型自身失败，先用证据排除（`grep -l FAILED <日志目录>`）。[旧项目转述]

---

## 8. 知识库（riscv-kb）操作

### 8.1 会话内工具

- `kb_search "<关键词>"` —— 检索（支持 `source:`/`path:`/`kind:` 过滤，引号短语强制相邻）。
- `kb_get chunkIds=[...]` / `kb_get path=... startLine/endLine` —— 展开引用。
- `kb_manage action=stats|sources|documents|reindex` —— 体检/重建。

### 8.2 CLI 等价命令

```sh
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search "mtvec MODE"
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js get 42
node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js build     # 全量重建
```

### 8.3 重建时机与代价

- **重建命令**：`kb_manage action=reindex`（会话内）或上面的 `build`（CLI）。
- **时机**：新增/修改被索引的文档后。
- **代价**：全量重建**需要数分钟**，**建议放后台跑**。
- **[工程约定]** 重建后必须用 `kb_manage action=stats` 确认**文档数与索引时间已更新**，否则视为重建未生效。

### 8.4 检索纪律

- **不要在文档树里 `read`/`grep` 学 ISA 事实**（`riscv-isa-manual`、`riscv-arch-test`、`docs-dev-guide`、`riscv-gnu-toolchain` 是**素材**，不是读物）。
- 检索空手归时，按序：`stats` → 换更短的标识符 → 去掉过滤器 → `documents filter=` 确认文档在库内。
- 引用一律带 `path:line`。

---

## 9. 待办清单（本文相关）

| # | 待办 | 验收 |
|---|---|---|
| B1 | 取 Spike 源码并编译（§6） | 可执行存在 + `--help` 正常 |
| B2 | 建 `fpga/run_vivado_batch.sh`（§3 三坑封装） | 传入任一 Tcl 能批处理跑通 |
| B3 | 回归脚本全量体检"未捕获即失败"（§5） | 逐个脚本确认兜底文案不含 PASS + 正则成对 |
| B4 | 封装配 `-D` 宏值的构建函数（§2） | 全项目无 `-D*=0x` 形式 |
| B5 | 镜像生成脚本打印 LMA/VMA 对照（§4） | 打包日志含 `readelf -l` 输出 |

---

## 10. 本文维护纪律

1. 版本号**只写实测值**；升级后必须重新 `[环境实测]` 并更新本表。
2. 任何"绕过手段"都必须写明**现象 + 证据 + 命令**三件套；行为级未复现的标注 **[旧项目转述]**。
3. 新增工具/坑追加到对应小节，**不新建平行文档**。
