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

### 三坑统一入口（**待建**）

- **目标**：`fpga/run_vivado_batch.sh <tcl>`，在脚本内一次性设置 坑① 的 `LD_LIBRARY_PATH`、坑③ 的 `HOME`、并以非交互批处理方式跑 Tcl。
- **现状**：**`rv32gc-cpu/fpga/` 目录尚不存在**，脚本**未创建**。[环境实测] `ls rv32gc-cpu/fpga` → `No such file or directory`
- **[工程约定]** 在 `run_vivado_batch.sh` 落地前，**不允许**任何人手工散落 `vivado -mode batch` 调用——否则三坑会被逐个重新踩一遍。

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
