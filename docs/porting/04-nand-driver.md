# NAND 驱动方案（芯片口径、平台控制器、DMA 搬运、MTD 分层）

> **文档定位**：RV32-GC 项目的 NAND 驱动**方案文档**（**不写实现代码**）。覆盖芯片口径、平台控制器寄存器与寻址、数据搬运、MTD 分层、坏块与 ECC 策略、U-Boot/Linux 共用口径。
> **平台源码（只读分析）**：
> - `chiplab/IP/APB_DEV/NAND/nand.v`（模块 `NAND_top`，1430 行）
> - `chiplab/IP/APB_DEV/apb_dev_top_with_nand.v`（416 行）
> **纪律**：`chiplab/` 全树**只读**。

---

## 1. NAND 芯片口径

### 1.1 型号与几何

> ⚠️ **强度声明：**[旧项目转述，未独立核实]
>
> 下表芯片参数**均来自旧项目口径转述**（旧项目 `PROMPT.md` 转述"原理图 `实验箱A7-原理图.pdf`，位号 U8"），**本次未独立核实**（未查数据手册、未实测芯片 ID）。

| 参数 | 值 | 强度 |
|---|---|---|
| 型号 | **K9F1G08U0C-PCB0**（Samsung，1 Gbit SLC，3.3 V） | **[旧项目转述]** |
| 总容量 | **128 MiB** | **[旧项目转述]** |
| 页大小 | **2048 + 64 B**（主区 + 备用区/spare） | **[旧项目转述]** |
| 块大小 | **128 KiB** | **[旧项目转述]** |
| 块数 | **1024** | **[旧项目转述]** |
| ECC 要求 | **1 bit / 512 B** | **[旧项目转述]** |
| 器件 ID | **`EC F1`** | **[旧项目转述]** |
| 时序 | tR 25 µs、tPROG 200 µs、tBERS 1.5 ms | **[旧项目转述]** |

### 1.2 平台侧佐证与自洽性检查

| 检查 | 结果 |
|---|---|
| 容量自洽 | 1024 块 × 128 KiB = 128 MiB ✅（核算见 `docs/porting/01-overview.md` §3.2） |
| 页几何自洽 | 128 KiB / (2048+64) B = 62.06… ⚠️ **非整数** |
| 平台 RTL | `soc_top.v` 传入 **`nand_type = 2'h2`**，注释 `//1Gbit`。[RTL 实测] `docs/kb/platform-facts.md` §3 |

**⚠️ 发现的口径矛盾（必须关闭）**：

- 若"每页 2048+64 B"且"每块 128 KiB"，则每块页数应为 `131072 / 2112 = 62.06`，**不是整数**。
- 正确的 1 Gbit SLC 组织通常为：**64 页/块 × (2048+64) B = 135168 B = 132 KiB**，或 **块 = 128 KiB = 64 页 × 2048 B**（备用区不计入块大小）。
- **结论**：`块 = 128 KiB` 与 `页 = 2048+64 B` 两条并不同时成立，除非"块大小"指**主区容量**（`64 × 2048 = 131072 = 128 KiB`），备用区**另行附加**。
- **裁决口径（用户已定，2026-09-14）**：以 chiplab RTL（`IP/APB_DEV/NAND/nand.v`、`apb_dev_top_with_nand.v`）与 la32r-Linux 驱动（`ls1a_nand.c`）的**实际实现为准**；工作口径 "块 128 KiB = 主区 64 页 × 2048 B，备用区 64 × 64 B 另行"；**不修改 chiplab NAND 模块**。
- **处置**：本方案按 **"块 128 KiB = 主区 64 页 × 2048 B，备用区 64 × 64 B 附加"** 理解（这是与两条口径同时自洽的唯一解释）。
- **关闭方式**：读器件数据手册确认，或**上电实读器件 ID 与 `nand_parameter` 寄存器**（见 §3.2）核对几何。**用户已定（2026-09-14）**：以 chiplab RTL 与 la32r-Linux 驱动（`ls1a_nand.c`）的实际实现为准，按上述工作口径关闭；**不修改 chiplab NAND 模块**。

### 1.3 与平台 RTL 的对应

- `NAND_top` 的 `nand_type[1:0]` 输入由 `soc_top.v` 传入 `2'h2`（`//1Gbit`）。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:1873`
- `nand.v` 内部有 **4 位 `nand_size`** 信号（`nand.v:106`）与 **3 位 `nand_id_num`**（`nand.v:105`），其取值链**未逆向完成**。[不确定项] `docs/kb/platform-facts.md` §9 U2
  → **含义**：`nand_type` → `nand_size` 的映射表决定了控制器发送的地址周期数（`nand.v:671-688` 的 `NAND_ADDR_COUNT` 分支按 `nand_size` 区分）。**用户已定（2026-09-14）：D2 在实现时按 RTL 逆向（不改 RTL）。**

---

## 2. 地址与拓扑

### 2.1 地址口径

| 项 | 值 | 出处 |
|---|---|---|
| NAND 控制器基址 | `0x1FE7_8000` | 软件侧 [RTL 实测] `la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c:86`（`#define _NAND_BASE 0x9fe78000`） |
| **DMA 门铃 / DMA 访问寄存器** | **`0x1FE7_8040`**（基址 + `0x40`） | [RTL 实测] `nand.v:128-129`（`ADDR[10:0]==11'h40`）+ `ls1a_nand.c:18`（`DMA_ACCESS_ADDR 0x1fe78040`） |
| APB 地址宽度 | 20 位 | [RTL 实测] `apb_dev_top_with_nand.v:119`（`parameter ADDR_APB = 20`） |

- **门铃地址两侧完全吻合**：RTL 的 `+0x40` 偏移与软件的 `0x1fe78040` 逐字一致 —— 这是**本方案中最强的一条硬件/软件交叉验证**。
- **不确定项**：`0x1FE7_8000` 的**窗口内基址偏移**在平台 RTL 中**无显式常量**（AXI mux 只译到高 16 位 `0x1FE7`，`nand.v` 只看 `ADDR[10:0]`）。[不确定项] `docs/kb/platform-facts.md` §9 U4

### 2.2 APB 拓扑

`apb_dev_top_with_nand.v` 汇聚 UART0/UART1/NAND 三个 APB 从口；NAND 走 `apb1_*` 一组信号：[RTL 实测] `apb_dev_top_with_nand.v:242-249`（信号声明）、`:344-351`（内部连接）、`:383-397`（NAND 实例化）

```
apb1_req/ack/rw/enab/psel/addr/datai/datao  →  NAND_top
```

- **含义**：NAND 是 APB 从设备，**CPU 侧通过 AXI→APB 桥**访问；驱动的读写是按 APB 周期的**寄存器访问**，不是内存映射 FIFO（数据搬运另走 DMA，见 §5）。

---

## 3. 控制器寄存器映射

### 3.1 寄存器表（`ADDR[10:0]` 逐 4 字节译码）

[工程约定] 下表由 RTL 读写两侧交叉整理而成，**写驱动前必须逐条复核**。

| 偏移 | 命中信号 | 写侧（RTL 行） | 读侧内容（RTL 行） | 推测语义 |
|---|---|---|---|---|
| `0x00` | `HIT0` | `nand.v:171` | `nand_command`（`nand.v:337`） | 命令寄存器 |
| `0x04` | `HIT1` | `nand_addr_c <= DAT_I[13:0]`（`nand.v:184`） | `{20'b0, nand_addr_c}`（`nand.v:339`） | 列地址（低 14 位） |
| `0x08` | `HIT2` | `nand_addr_r <= DAT_I[24:0]`（`nand.v:185`） | `{7'b0, nand_addr_r}`（`nand.v:341`） | 行地址（低 25 位） |
| `0x0C` | `HIT3` | `nand.v:186-189` | `nand_timing`（`nand.v:343`） | 时序参数 |
| `0x10` | `HIT4` | — | `ID_INFORM[31:0]`（`nand.v:345`） | 器件 ID 低 32 位 |
| `0x14` | `HIT5` | — | `{status, ID_INFORM[47:32]}`（`nand.v:347`） | 状态 + ID 高位 |
| `0x18` | `HIT6` | `nand_parameter <= DAT_I`（`nand.v:190`） | `nand_parameter`（`nand.v:349`） | 参数寄存器 |
| `0x1C` | `HIT7` | `nand_op_num <= DAT_I`（`nand.v:191`） | `nand_op_num`（`nand.v:351`） | 操作数 / 操作码 |
| `0x20` | `HIT8` | `nand_ce_map0`（`nand.v:192`） | — | CE 映射 0 |
| `0x24` | `HIT9` | `nand_ce_map1`（`nand.v:193`） | — | CE 映射 1 |
| `0x28` | `HIT10` | `nand_rdy_map0`（`nand.v:195`） | — | RDY 映射 0 |
| `0x2C` | `HIT11` | `nand_rdy_map1`（`nand.v:196`） | — | RDY 映射 1 |
| **`0x40`** | **`NAND_HIT`** | **`assign nand_dma_ack_i = psel & ADDR==11'h40`**（`nand.v:129`） | — | **DMA 门铃** |

- 读数据统一经 `REG_DAT_T` 多路选择后由 `assign DAT_O = REG_DAT_T;` 输出（`nand.v:131`）。[RTL 实测]
- 读侧选择逻辑位于 `nand.v:336-359`（`if(~pwrite & HIT0 & penable) … else if(…)` 链）。
- 写侧选择逻辑位于 `nand.v:171-196`。

### 3.2 器件探测与几何确认（**驱动的第一步**）

- 通过 `ID_INFORM`（`HIT4` 读 `ID_INFORM[31:0]`、`HIT5` 读 `ID_INFORM[47:32]`）**实读器件 ID**。[RTL 实测] `nand.v:345, 347`
- **这是关闭 §1.2 口径矛盾的唯一可靠途径**：实读 ID 若为 `EC F1`，则 [旧项目转述] 的 ID 得到证实；再读 `nand_parameter`（`HIT6`）核对几何编码。
- **验收**：驱动启动日志必须打印实读到的 ID 与 `nand_parameter` 原始值。

### 3.3 控制状态机关键信号

| 信号 | 位宽 | 行号 | 语义 |
|---|---|---|---|
| `ADDR_pointer` | `[1:0]` | `nand.v:365` | 地址指针 |
| `NAND_ADDR_COUNT` | `[2:0]` | `nand.v:367` | 地址周期计数（决定发几个地址字节） |
| `NAND_ADDR` | `[37:0]` | `nand.v:374` | 完整地址寄存器 |
| `NAND_DONE` | 1 | `nand.v:103` | 操作完成标志 |
| `NAND_GO` | — | 多处（`:470, 478, 494…`） | 启动一次操作 |
| `op_scope` | `[13:0]` | `nand.v:104` | 操作范围 |
| `nand_size` | `[3:0]` | `nand.v:106` | 几何编码（见 §1.3） |
| `main_op`/`spare_op`/`now_up_half` | 1 | — | 主区/备用区/上半个半页门控（`nand.v:467-508`） |

- 关键状态常量：`ADDR_4_RD_WR = 5'b00010`、`ADDR_4_ERASE_ID = 5'b01010`。[RTL 实测] `nand.v:395-396`
- **地址周期数由 `nand_size` 决定**：例如 `nand.v:671-688` 按 `nand_size == 4'h9/4'ha/4'hb/4'hc/4'hd/4'h0` 等分支选择 `NAND_ADDR` 的不同位段作为地址字节。
  → **驱动的地址构造必须与该分支表一致**，否则行/列地址会错位。

---

## 4. ECC 策略

### 4.1 要求

- 芯片口径要求 **1 bit / 512 B** 可纠正。[旧项目转述]
- 2048 B 主区 ⇒ 需 **4 个 ECC 段**（每段 512 B）。

### 4.2 方案选择 [工程约定]

| 方案 | 能力 | 建议 |
|---|---|---|
| **BCH-4** | 可纠 4 bit、可检更多 | **推荐**（余量足，代价可接受） |
| Hamming | 纠 1 bit / 检 2 bit | 满足最低要求，实现简单 |

- **首选软件 BCH-4（或 Hamming）**，由驱动在读写路径上计算/校验；`nand.v` 中**未观察到硬件 ECC 引擎**（本次只读分析未发现 ECC 相关信号）。[不确定项]

### 4.3 ECC 布局（**U-Boot 与 Linux 必须共用**）

- **硬性要求**：**U-Boot 与 Linux 必须使用相同的 ECC 布局**，否则一侧写入的数据另一侧读不出来（会表现为"U-Boot 能读、内核读失败"这类极难定位的问题）。
- [工程约定] ECC 布局口径：

  | 项 | 口径 |
  |---|---|
  | ECC 段大小 | **512 B** |
  | 每页段数 | **4**（2048 / 512） |
  | 每段 ECC 字节数 | 由算法定（BCH-4 通常十余字节），**必须固定并写入两侧公共头文件** |
  | ECC 存放位置 | **备用区（spare）**，固定偏移，**不随页变化** |
  | 坏块标记位置 | 备用区固定偏移（见 §6） |

- **落地方式**：ECC 布局常量必须在**两侧共用的单一头文件**（如 `include/linux/mtd/nand_ecc_layout.h` 风格）中定义，U-Boot 通过**软链接或补丁同步**引用同一份。
- **验收**：U-Boot 写一页 → Linux 读同一页 → 数据逐字节一致，且**人为注入 1 bit 错误后能被纠正**。

---

## 5. 数据搬运：走平台 DMA 引擎

### 5.1 为什么必须走 DMA

- NAND 是 **APB 从设备**（§2.2），CPU 只能逐寄存器访问；2048 B/页的**逐字 PIO 搬运代价过高**，且会与其他 APB 访问争用。
- 平台提供 **DMA 引擎**，门铃寄存器 `0x1FE7_8040`（§3.1）。

### 5.2 软件侧参考（只读）

- `la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c`：[旧项目转述] **命令序列可用**，但**地址/cache/DMA 部分必须重写**。
- 该文件中的关键常量（**仅作命名参考**）：`ls1a_nand.c:18` `DMA_ACCESS_ADDR 0x1fe78040`；`:60-61` `NAND_ADDRL 0x2` / `NAND_ADDRH 0x4`（**与 §3.1 表中 `0x04`/`0x08` 偏移吻合**，可交叉印证）。
- `ls1a_nand.c:597-599` 显示 `addrl`/`addrh` 的软件选择逻辑 —— 对应 §3.1 的 `HIT1`/`HIT2`。

### 5.3 DMA 搬运设计要点 [工程约定]

1. **门铃写 `0x1FE7_8040` 触发** DMA；RTL 侧由 `nand_dma_ack_i` 应答（`nand.v:129`）。
2. **cache 一致性**：DMA 直接写 DDR，而 CPU 可能持有该缓冲区的 cache 行 ⇒ **必须做 cache 管理**：
   - **U-Boot（S 模式，不开 MMU、通常也不开 D-cache）**：相对简单，但仍需确认 cache 状态；
   - **Linux（S 模式，开 Sv32，开 D-cache）**：DMA 缓冲区必须是**一致性内存**，在 DMA 前后做 `dma_sync_single_for_device` / `for_cpu`（或等价的 invalidate/flush），或使用非缓存映射。
3. **对齐**：`ls1a_nand.c` 的 `ALIGN_DMA(x) = ((x)+3)/4` 提示**按 4 字节对齐**。[旧项目转述]
4. **单笔在途**：DMA 引擎的并发度未知 ⇒ 驱动必须保证**同一时刻只有一笔 DMA 在途**（busy 标志 + 完成等待），避免交错。
5. **超时**：所有等待（DMA 完成、NAND_DONE、RDY）**必须有超时**，超时返回错误而非死等。

---

## 6. MTD 分层与坏块管理

### 6.1 三层结构

```
┌─────────────────────────────────────────────┐
│  MTD 层   mtd_info / mtd_device_register    │  读写、擦除、分区表
├─────────────────────────────────────────────┤
│  NAND 层  nand_chip / NAND 通用命令与 ECC    │  命令序列、ECC 框架、坏块表
├─────────────────────────────────────────────┤
│  控制器层 平台 APB NAND 控制器 + DMA 引擎    │  寄存器读写、DMA 触发
└─────────────────────────────────────────────┘
```

- **MTD 层**：向上提供 `mtd_read`/`mtd_write`/`mtd_erase`；持有**分区表**（必须与 `mtdparts`、DTS 同源，见 `docs/porting/01-overview.md` §3.1）。
- **NAND 层**：实现 NAND 命令序列（read/program/erase/read ID/read status），管理 **ECC** 与**坏块表（BBT）**。
- **控制器层**：封装 §3 的寄存器访问与 §5 的 DMA 搬运；**不含** NAND 命令语义。

### 6.2 坏块管理

[工程约定]

| 项 | 口径 |
|---|---|
| 出厂坏块标记 | **备用区固定偏移**（典型为首字节），**非 `0xFF` 即坏块** |
| 运行时坏块标记 | 备用区另一固定偏移；写入须**先擦块** |
| 坏块表（BBT） | **首次全片扫描**建立；存放位置需与分区表协调（通常放在第一个好块的专用区域） |
| 扫描时机 | 驱动 probe 时，或首块坏块表不存在时全扫 |
| **预留块** | 必须预留一定比例的块用于 BBT 更新与磨损替换 |

- **关键依赖**：坏块标记的**备用区偏移**必须与 **ECC 布局（§4.3）协商共存** —— 两者不能占用同一字节。**这必须在实现前定死并写入公共头文件。**
- **风险**：若 ECC 与坏块标记布局冲突，会表现为"某些页读回数据错误"且**毫无规律**，极难定位。

### 6.3 U-Boot / Linux 共用驱动口径

| 方面 | 必须共用 | 说明 |
|---|---|---|
| 寄存器偏移表 | ✅ | §3.1，写成公共头文件 |
| ECC 算法与布局 | ✅ | §4.3 |
| 坏块标记偏移 | ✅ | §6.2 |
| 页/块几何 | ✅ | §1.1（**待 §1.2 关闭后定稿**） |
| 分区表 | ✅ | `mtdparts` 与 DTS 同源 |
| DMA 缓冲区对齐 | ✅ | §5.3 |
| 代码实现 | ❌ | U-Boot 与 Linux 的 API 风格不同，**共用常量、不共用 C 文件** |

- **验收**：**交叉读写测试** —— U-Boot 写 → Linux 读；Linux 写 → U-Boot 读。两侧数据逐字节一致。

---

## 7. 验收判据

| # | 判据 | 判定方式 |
|---|---|---|
| N1 | 实读器件 ID 与 `nand_parameter` | 驱动日志打印原始值；核对 §1.1 口径 |
| N2 | 几何换算自洽 | 页/块/总数核算通过（§1.2 矛盾已关闭） |
| N3 | 单页读 | 读一页已知内容，逐字节比对 |
| N4 | 单页写 + 读回 | 写入后读回一致 |
| N5 | 块擦除 | 擦除后全 `0xFF` |
| N6 | **ECC 纠错能力** | **人为注入 1 bit 错误，必须能纠正** |
| N7 | 坏块识别 | 人为把一块标记为坏块，驱动正确跳过 |
| N8 | DMA 搬运正确性 | 大块传输与 PIO 结果一致 |
| N9 | U-Boot/Linux 交叉读写 | 一侧写、另一侧读一致 |
| N10 | 超时保护 | 拔除/复位器件时驱动超时返回错误，不死锁 |

- **N6 是必须的反证实验**：不注入错误时"读对了"**不能**证明 ECC 在工作。**必须做变异测试**（见 `docs/kb/tools-and-flow.md` §5）。

---

## 8. 不确定项（写实现前的门禁）

| # | 项 | 关闭方式 |
|---|---|---|
| D1 | **§1.2 几何矛盾**（块 128 KiB vs 页 2048+64 B） | **用户已定（2026-09-14）**：以 chiplab RTL（`IP/APB_DEV/NAND/nand.v`、`apb_dev_top_with_nand.v`）与 la32r-Linux 驱动（`ls1a_nand.c`）的**实际实现为准**；工作口径「块 128 KiB = 主区 64 页 × 2048 B，备用区 64 × 64 B 另行」；**不修改 chiplab NAND 模块** |
| D2 | `nand_type=2'h2` → `nand_size[3:0]` 映射表 | **用户已定（2026-09-14）**：实现时按 RTL 逆向（不改 RTL） |
| D3 | §3.1 寄存器表的**逐条语义复核** | 对照 `ls1a_nand.c` 寄存器宏 + 实测 |
| D4 | 控制器**是否有硬件 ECC 引擎** | 已做只读分析未发现；需专项确认 |
| D5 | **DMA 引擎并发度与描述符格式** | **用户已定（2026-09-14）**：实现时分析（不改 RTL） |
| D6 | `0x1FE7_8000` 基址偏移的 RTL 出处 | 查 APB 顶层从口译码 |
| D7 | ECC 布局与坏块标记的字节级共存方案 | §6.2；实现前定死 |
| D8 | 坏块表（BBT）的存放位置约定 | 与分区表协调后定稿 |

> **门禁纪律**：D1、D2、D5 **未关闭前不得开始写驱动实现** —— 它们直接决定地址构造与搬运正确性，猜错会产生静默数据损坏。**用户已定（2026-09-14）**：D1 按上述工作口径关闭（以 chiplab RTL 与 `ls1a_nand.c` 实际实现为准，**不修改 chiplab NAND 模块**）；D2、D5 在实现时分别按 RTL 逆向与 DMA 模块分析关闭。

---

## 9. 交付要求

[工程约定] 本层交付物：

1. **寄存器全表**（含逐条语义与 RTL 行号引用，关闭 D3）；
2. **公共头文件**（寄存器偏移、ECC 布局、坏块偏移、几何常量）—— U-Boot 与 Linux 共用；
3. **驱动实现**（U-Boot 侧 + Linux 侧，**本文不含实现代码**）；
4. **自证报告**：按 §7 表格逐项给出证据，**N6 必须含变异测试记录**；
5. **不确定项登记**：同步至 `docs/kb/platform-facts.md` §9。

---

## 10. 勘误与实施补充（2026-09-21，阶段三 B-3 实测回写）

> **原文一律不改**，本节只做**追加**。每条给出「原文口径 → 实码口径 → 证据」。
> 证据强度沿用 `docs/kb/platform-facts.md` 的标注约定。

### E1. `nand_size` 的几何编码（关闭原文 §1.3 的不确定项）

* **原文口径**（§1.3）：`nand_type=2'h2` → `nand_size[3:0]` 的映射链"未逆向完成"，
  驱动的地址构造"必须与该分支表一致"但分支表未给出。
* **实码口径**：`nand.v:225-282` 的 case 直接给出列/行位宽—
  `nand_size==4'h0/4'h1` 用 `nand_addr_c[11:0]` + `nand_addr_r[15:0]`/`[16:0]`，
  `4'h2/4'h3` 用 `+[17:0]`/`[18:0]`。配合 `READ_START`/`WRITE_START` 的周期数
  选择（`nand.v:809`、`nand.v:982`）与 `NAND_ADDR_COUNT` 各分支的字节抽取
  （`nand.v:733-757`），1 Gbit（1024 块 × 64 页 ⇒ 16 位行地址、2048 B 页 ⇒
  列地址只需 3 字节周期）对应 **`nand_size == 4'h0`**（3 地址周期）。
  Linux 侧写 `0x9fe78018 = 0x08005300`（`ls1a_nand.c:910`）得
  `nand_size = (0x08005300 >> 8) & 0xf = 3`，与复位默认
  `0x0800_5000`（`nand.v:160`，`nand_size = 0`）分属不同分支，
  **两者都能给出 3 地址周期**（`nand.v:809`/`:982` 对 `4'h0` 与 `4'hc/4'hd`
  都给 `3'b100`，对 `4'h9/4'ha/4'hb` 给 `3'b011`）。
* **本驱动的取值**：显式写 `nand_size = 3`（`CHIPLAB_NAND_SIZE_1GBIT`），
  与 Linux 侧同值；`op_scope = 2048` 与页容量一致。
  强度：[RTL 实测]（`nand.v` 行号如上）。
* **仍未关闭的部分**：`nand_size` 各分支的**字节抽取是否与真实器件地址周期
  完全等价**需要上板用"读一页已知内容"验证（原文 §7 N3/N4）。

### E2. 寄存器逐条语义复核（关闭 D3 / PF §9 U1）

* **原文口径**（§3.1 表）：只给"命中信号 + 写侧行号 + 读侧行号 + 推测语义"。
* **实码口径**：逐寄存器语义已按 `nand.v` 读写两侧实码关闭，
  全表（含命令字位域、`NAND_PARAM` 位域、`0x24`/`0x2C` 的"未写时硬件回填"行为）
  见 U-Boot 侧交付物 `u-boot/board/loongson/chiplab/README` 的
  「控制器寄存器映射表」与 `u-boot/drivers/mtd/nand/raw/chiplab_nand.h` 顶部注释。
* **对原文 §3.1 表的两处修正**：
  1. `0x2C`（原文"`HIT11` → RDY 映射 1"）：写侧确为 `nand_rdy_map1`（`nand.v:196`），
     但**未写时硬件回填 `{WRITE_MAX_COUNT, NAND_OP_NUM[15:0]}`**（`nand.v:197`），
     故它同时是"上一次写入的实际传输量"只读观测口（`0x24` 与之对称，
     `nand.v:194`）。
  2. `0x24`（原文"CE 映射 1"）：同上，写侧是 CE 映射，未写时回填
     `{READ_MAX_COUNT, NAND_OP_NUM[15:0]}`。
* **命令字位域**（原文未列）：`[0]` 有效、`[1]` 读、`[2]` 写、`[3]` 擦除、
  `[4]` 连续擦除、`[5]` 读 ID、`[6]` 复位、`[7]` 读状态、`[8]` 主区、`[9]` 备用区、
  `[10]` DONE（只读）、`[13]` 中断使能；
  **`[11] ECC_RD`、`[12] ECC_WR`、`[15] RAM_OP` 在 `nand.v` 中完全未被引用**
  —— 这是原文 D4「控制器是否有硬件 ECC 引擎」的**直接反证**：
  RTL 保留了软件 ECC 的命令位但无任何实现（`nand.v` 全文无 ECC 计算逻辑）。
  强度：[RTL 实测]。

### E3. DMA 搬运（关闭 D5；更正 §5.3 的部分表述）

* **原文口径**（§5.3）：门铃写 `0x1FE7_8040` 触发 DMA，`nand_dma_ack_i` 应答。
* **实码口径**：`0x1FE7_8040` 上的**普通 load/store 就是搬运本身**
  —— `nand_dma_ack_i = psel & (ADDR == 11'h40)`（`nand.v:129`），
  DMA 引擎对设备侧的每次访问都会在这条地址上产生一个 APB 周期
  （`dma.v:370 assign dma_ack_out = apb_psel`），
  **不需要软件在门铃上写任何数据**。软件的职责是：
  1. 在 confreg 的 order 寄存器 `0x1FD0_1160`（`confreg_syn.v:33`）
     写入 **32 字节对齐**的描述符物理地址并置 `dma_start`（bit3，`dma.v:137`）；
  2. 描述符 = 4×64 位：`{mem_addr, order_addr}` / `{length(4B 字数), dev_addr}` /
     `{step_times, step_length}` / `{状态, cmd}`（`dma.v:559-574`），
     其中 `dev_addr` 必须 = `0x1FE78040`，`cmd[12] = dma_r_w` 决定 **DDR 侧**方向；
  3. 轮询 order 寄存器的 bit3/bit2 清零判定完成（`confreg_syn.v:325-330`）。
* **原文 §5.3 "cache 一致性"补充**：U-Boot（S 模式、无 MMU、无 D-cache 语义）
  只需 `flush_dcache_range`/`invalidate_dcache_range` 包住缓冲区（本驱动已做）；
  Linux 侧仍需按原文做 DMA API 同步。
* 强度：[RTL 实测]（`dma.v`/`confreg_syn.v` 行号如上）。

### E4. ECC 布局：原文 §4.3 的"公共头文件"落到具体位置

* **原文口径**（§4.3）：ECC 布局常量必须放在两侧共用的单一头文件，
  "如 `include/linux/mtd/nand_ecc_layout.h` 风格"。
* **实码口径**：U-Boot 侧唯一定义在
  `u-boot/drivers/mtd/nand/raw/chiplab_nand.h` §3（`CHIPLAB_NAND_ECC_*`），
  且该头**不依赖 U-Boot**，将来 Linux 侧把同一份文件放进内核即可共用。
  位序约定（数据位 `p` ↔ `x^p`、ECC 位 `j` ↔ `x^(8n+j)`）也写在该头，
  并由 U-Boot 侧单元测试 `test_bit_order` 锁死。
* **具体布局**：段 512 B × 4 段，每段 7 B（BCH-4，GF(2^13)），
  ECC 占**备用区 offset 36..63**（尾部 28 B），出厂坏块标记 offset 0、
  运行时标记 offset 1，`oobfree` = offset 2..35。
  该布局与 U-Boot `nand_bch_init()` 的默认布局一致（`nand_bch.c:160-175`），
  因此 Linux 侧可用标准 `nand_ecclayout` 表达。
* 强度：[工程约定] + [RTL 实测]（备用区 64 B 来自 `nand.v` 的 `0x40` 门铃路径与
  原文 §1.2 裁决口径）。

### E5. 实施中发现的两条 U-Boot 2026.10 树内约束（供后续复用）

1. **`nand_release()` 在该树中不存在**：只有 `nand_unregister(mtd)`
   （`drivers/mtd/nand/raw/nand.c:80`）与静态的 `nand_release_device()`
   （`nand_base.c:134`）。用 `mtd_device_unregister()` 会**链接失败**
   —— 该符号在本配置下未编译进 `mtdcore.o`。
2. **软件 BCH 需要 `CONFIG_BCH=y`**：`NAND_ECC_BCH` 只启用 `nand_bch.c`，
   它调用 `lib/bch.c` 的 `init_bch/encode_bch/decode_bch`，
   而 `lib/Makefile:120` 仅在 `CONFIG_BCH` 下编译该文件
   —— 缺它会出现 `undefined reference to 'init_bch'`。
   本驱动在 Kconfig 里 `select BCH`。
