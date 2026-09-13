# 特权级、CSR、异常与 MMU 设计

> 上游文档：`00-overview.md`。规范依据：RISC-V Privileged Architecture v1.12（工作区 `riscv-isa-manual/src/priv/machine.adoc`、`supervisor.adoc`，可通过常驻知识库 `kb_search` 检索原文）。
> 目标：支持 OpenSBI（M 模式固件）+ S 模式 Linux（Sv32），并满足 xv6/裸机测试等场景。

![特权级、CSR 与地址转换](diagrams/priv-csr.svg)

---

## 1. 特权模式与 `misa`

- 实现 **M / S / U** 三种模式；`misa.MXL = 1`（32 位），扩展位：`I M A F D C S U`。
- `misa` 的写操作仅允许改变 `C` 位（压缩指令可通过写 `misa` 关闭，其它位只读）。
- 复位后进入 M 模式，`mstatus.MIE=0`，`mstatus.MPRV=0`。

## 2. CSR 清单

### 2.1 机器级 CSR（M 模式）

| 地址 | 名称 | 读写 | 实现说明 |
|---|---|---|---|
| `0xF11` | `mvendorid` | RO | 0（非商业实现） |
| `0xF12` | `marchid` | RO | 自定义 ID（本项目编号） |
| `0xF13` | `mimpid` | RO | RTL 版本号 |
| `0xF14` | `mhartid` | RO | 0（单核） |
| `0xF15` | `mconfigptr` | RO | 0 |
| `0x300` | `mstatus` | RW | 见 §2.3 |
| `0x301` | `misa` | RW | 见 §1 |
| `0x302` | `medeleg` | RW | 支持委托的异常位（见 §4.2） |
| `0x303` | `mideleg` | RW | 支持委托的中断位（S 模式软件/定时器/外部） |
| `0x304` | `mie` | RW | `MSIE/MTIE/MEIE` + `SSIE/STIE/SEIE` |
| `0x305` | `mtvec` | RW | MODE 支持 0（Direct）与 1（Vectored），BASE 4 字节对齐 |
| `0x306` | `mcounteren` | RW | `CY/TM/IR`（控制 S/U 模式读取计数器） |
| `0x310` | `mstatush` | RW | RV32 专用；仅 `MBE/SBE`（本设计不支持大端，读 0、写忽略） |
| `0x30A` | `menvcfg` | RW | WARL：`CBZE/CBCFE/CBIE`（Zicbom 使能）、`FIOM`；其余位 0 |
| `0x31A` | `menvcfgh` | RW | RV32 高 32 位（本设计返回 0/WARL） |
| `0x320` | `mcountinhibit` | RW | `CY/IR`（停止 mcycle/minstret 计数） |
| `0x340` | `mscratch` | RW | — |
| `0x341` | `mepc` | RW | bit0 恒 0（IALIGN=16 时 bit1 也恒 0） |
| `0x342` | `mcause` | RW | 见 §4.1 |
| `0x343` | `mtval` | RW | 见 §4.1 |
| `0x344` | `mip` | RW | `MSIP/MTIP/MEIP` + `SSIP/STIP/SEIP`；S 级位是 M 级位的只读影子 |
| `0x3A0`–`0x3AF` | `pmpcfg0`–`pmpcfg15` | RW | 本设计实现 16 项 → `pmpcfg0`–`pmpcfg3`（RV32 下每 32 位 4 项） |
| `0x3B0`–`0x3BF` | `pmpaddr0`–`pmpaddr15` | RW | 16 项 |
| `0xB00`/`0xB02` | `mcycle`/`minstret` | RW | 真实计数（64 位，RV32 分高低） |
| `0xB80`/`0xB82` | `mcycleh`/`minstreth` | RW | RV32 高 32 位 |
| `0x320`+ | `mhpmcounter3..31` | RO 0 | 未实现的性能计数器读 0，写忽略（合法） |
| `0xF11`… | — | — | — |

### 2.2 监管级与用户级 CSR

| 地址 | 名称 | 说明 |
|---|---|---|
| `0x100` | `sstatus` | `mstatus` 的受限视图（`SIE/SPIE/SPP/SUM/MXR/UXL/SXL/FS/VS/XS/SD`） |
| `0x104` | `sie` | `mideleg` 允许委托的位可写，其余只读 0 |
| `0x105` | `stvec` | MODE 0/1 |
| `0x106` | `scounteren` | `CY/TM/IR` |
| `0x10A` | `senvcfg` | WARL，`CBZE/CBCFE/CBIE` 可从 M 模式透传 |
| `0x140` | `sscratch` | — |
| `0x141` | `sepc` | — |
| `0x142` | `scause` | — |
| `0x143` | `stval` | — |
| `0x144` | `sip` | `SSIP/STIP/SEIP` 的受限视图 |
| `0x180` | `satp` | MODE（0=Bare、1=Sv32）+ ASID(9 bit) + PPN(22 bit) |
| `0xC00`/`0xC01`/`0xC02` | `cycle`/`time`/`instret` | 受 `mcounteren`/`scounteren` 控制；`time` 读自 CLINT `mtime` |
| `0xC80`/`0xC81`/`0xC82` | `cycleh`/`timeh`/`instreth` | RV32 高 32 位 |

### 2.3 `mstatus`/`mstatush` 字段（RV32）

| 字段 | 位 | 实现 |
|---|---|---|
| `SIE`/`MIE` | 1/3 | RW |
| `SPIE`/`MPIE` | 5/7 | RW |
| `SPP`/`MPP` | 8/12:11 | RW（MPP 支持 00/01/11，写 10 保留 → 归一到 11） |
| `MPRV` | 17 | RW（影响 load/store 的权限检查与地址转换，见规范 `machine.adoc` §"Memory Privilege in mstatus Register"） |
| `SUM` | 18 | RW（S 模式访问 U 页面） |
| `MXR` | 19 | RW（可执行页可读） |
| `FS` | 14:13 | RW（Off/Initial/Clean/Dirty；`mstatus.FS` 为 Off 时执行浮点指令触发非法指令异常） |
| `SD` | 31 | 由 `FS`/`XS` 推导 |
| `UXL`/`SXL` | 33/35（在 `mstatush`？） | RV32 下 `mstatush` 只有 `MBE/SBE`，UXL/SXL 在 `mstatus` 高位不可用；读 0 |

> 说明：RV32 的 `mstatus` 为 32 位，`UXL/SXL` 等字段只存在于 RV64，故本设计在 `mstatus` 中不实现它们；`mstatush` 仅实现 `MBE/SBE`（恒 0）。

## 3. 计数器与定时器

- `mcycle`（周期数）与 `minstret`（提交指令数）由核内 64 位计数器实现，`mcountinhibit` 可停止；RV32 通过高半寄存器读写。
- `time` CSR 读内部 CLINT 的 `mtime`（64 位，RV32 下 `timeh` 读高 32 位）。
- **CLINT（核内，`0x1F00_0000`）**：

| 偏移 | 寄存器 | 说明 |
|---|---|---|
| `0x0000` | `msip`（hart0） | 软件中断挂起（写 1 置位、写 0 清除），仅 hart0 |
| `0x4000` | `mtimecmp`（hart0，64 位） | 低 32 位 `0x4000`，高 32 位 `0x4004` |
| `0xBFF8` | `mtime`（64 位） | 自由运行计数器，频率 = CPU 时钟频率 |

`mtime >= mtimecmp` 时置 `mip.MTIP`；`mtimecmp` 写 64 位需按 `mtimecmp_hi/lo` 顺序写（核内实现"写高半时若新值 < mtime 则抑制一次中断"的标准行为，避免比较器毛刺）。

- **定时器频率**：等于 `cpu_clk`（100 MHz 设计目标；50 MHz 兼容配置）。内核通过设备树 `riscv,clint0` 节点或 `riscv,timer` 获取频率，无需硬编码（区别于 LA32R 移植中硬编码 200 MHz 的问题）。

## 4. 异常与中断

### 4.1 异常码（`mcause`/`scause`）

| 码 | 异常 | `mtval`/`stval` 写入内容 |
|---|---|---|
| 0 | 指令地址非对齐 | 出错地址 |
| 1 | 指令访问错误 | 出错地址 |
| 2 | 非法指令 | 指令编码（RVC 展开后为 32 位） |
| 3 | 断点（`ebreak`） | PC |
| 4 | 载入地址非对齐 | 出错地址 |
| 5 | 载入访问错误 | 出错地址 |
| 6 | 存储/AMO 地址非对齐 | 出错地址 |
| 7 | 存储/AMO 访问错误 | 出错地址 |
| 8/9/11 | `ecall` from U/S/M | 0 |
| 12/13/15 | 指令/载入/存储页错误 | 出错地址 |
| 中断位 | `mcause[31]=1`，码 3（MSI）/7（MTI）/11（MEI）/1（SSI）/5（STI）/9（SEI） | 0 |

### 4.2 委托（`medeleg`/`mideleg`）

- `medeleg` 可写位：0,1,2,3,4,5,6,7,8,9,12,13,15（即除 M 模式 `ecall`(11) 外的全部）。
- `mideleg` 可写位：1（SSI）、5（STI）、9（SEI）；M 级中断（3/7/11）不可委托。
- 委托后：`scause/sepc/stval/sstatus.SPP/SPIE/SIE` 写入，跳转 `stvec`；否则写 M 级对应寄存器并跳 `mtvec`。

### 4.3 中断源与 PLIC

- **核内中断源**：`MSIP`（CLINT）、`MTIP`（CLINT 比较器）、`MEIP/SEIP`（PLIC）。
- **PLIC（核内，`0x1F10_0000`）**：兼容 SiFive PLIC 寄存器布局，便于直接使用内核 `sifive,plic-1.0.0` 驱动。

| 偏移 | 寄存器 | 说明 |
|---|---|---|
| `0x0000_0000` + 4×N | 优先级（N=1..NDEV） | 每源 32 位优先级 |
| `0x0000_1000` + 4×(N/32) | `pending` | 只读挂起位 |
| `0x0000_2000` + 4×(N/32) | `enable`（hart0 M 上下文） | 使能位 |
| `0x0000_2080` + 4×(N/32) | `enable`（hart0 S 上下文） | 使能位 |
| `0x0010_0000` + 4×ctx | `threshold` | 阈值 |
| `0x0020_0000` + 4×ctx | `claim/complete` | 认领/完成 |

- **中断源映射**（外部源 = 平台 `intrpt[7:0]`）：

| 源号 | 平台信号 | 设备 | 设备树用 |
|---|---|---|---|
| 1 | `intrpt[0]` | MAC (dmfe) | `interrupts = <1>` |
| 2 | `intrpt[1]` | UART0 | `interrupts = <2>` |
| 3 | `intrpt[2]` | SPI | `interrupts = <3>` |
| 4 | `intrpt[3]` | NAND | `interrupts = <4>` |
| 5 | `intrpt[4]` | DMA | `interrupts = <5>` |

  （源 0 保留；PLIC `NDEV = 8`，其余源为 0。）

### 4.4 `WFI`、`MRET/SRET`、`SFENCE.VMA`

- `wfi`：暂停取指，直到任一"使能且挂起"的中断出现（TW=1 时在 S 模式执行 `wfi` 触发非法指令异常）。
- `mret/sret`：按规范恢复 `xIE←xPIE`、`xPIE←1`、特权级 ← `xPP`、`MPRV←0`（`mret`），跳到 `xepc`。
- `sfence.vma`：按 `rs1`（vaddr）/`rs2`（ASID）失效 ITLB/DTLB/L2TLB；`rs2=0` 时失效所有 ASID，`rs1=0` 时失效所有地址。TVM=1 时 S 模式执行触发非法指令异常。

## 5. MMU（Sv32）

### 5.1 地址转换

- 两级页表，PTE 4 字节，`Sv32` 虚拟地址 32 位 → 物理地址 34 位（本设计物理地址实际使用 32 位，PPN 高位返回 0）。
- 规范流程见 `riscv-isa-manual/src/priv/supervisor.adoc`（Sv32 地址与保护、虚拟地址转换流程两节）。
- **硬件页表遍历器（PTW）**：一次只服务一个缺失（可配置 2 个并行以提升性能），逐级读 PTE；读到非法 PTE（V=0 或保留位非零）按规范触发页错误；非叶节点遇到 `A/D/U` 位异常组合同样报错。

### 5.2 TLB 结构

| TLB | 容量 | 相联度 | 说明 |
|---|---|---|---|
| ITLB | 32 项 | 全相联 | 取指路径，与 I-Cache 并行查询，命中判定在 IF2 |
| DTLB | 64 项 | 全相联 | 访存路径，与 D-Cache 并行查询 |
| L2TLB | 256 项 | 4 路 | ITLB/DTLB 共享，含 ASID 与 G 位 |
| PTW | 1~2 个 | — | 缺失时填充 L2TLB |

- 表项内容：`{VA 高位, ASID, 权限(R/W/X/U/G), 级别(4K/4M 大页), PPN, 有效位}`；支持 4 MB 大页。
- **A/D 位**：命中且未置位时由硬件置位并写回页表（写回通过 D-Cache 保证原子性；若写回期间发生异常，按规范先置位再报错）。
- **权限检查**：结合当前特权级、`SUM`、`MXR`、`MPRV`、`mstatus.MPP`（MPRV 生效时用 MPP 权限）与页表 `R/W/X/U` 位。

### 5.3 PMP（物理内存保护）

- 16 项，支持 `A=OFF/TOR/NA4/NAPOT`，`L` 位锁定（锁定后忽略写入，直到复位）；匹配与锁定语义遵循规范 `machine.adoc` 的 Physical Memory Protection 一节。
- 无匹配项时：M 模式可访问全部，S/U 模式全部拒绝（规范默认）。
- 用途：OpenSBI 用 PMP 保护自己的 M 模式内存不被 S 模式访问；Linux 也可能用于限制。
- 匹配检查与 TLB 访问并行（TLB 表项携带 PMP 通过标记，PMP 配置写入时失效全部 TLB）。

## 6. 陷阱提交路径（与乱序后端的接口）

```
ROB 头部 uop ──┬─ 无异常 ──► 提交（写 PRF/CSR、store 落盘）
               ├─ 有异常 ──► 1) 冻结前端与分发
               │             2) 清空 ROB 中全部更年轻表项与发射队列/LSQ
               │             3) 写 xepc/xcause/xtval，更新 xstatus（xPP/xPIE/xIE）
               │             4) 重定向 PC 到 xtvec（MODE=1 时按 cause×4 偏移）
               └─ 中断采样 ─► 同上，cause[31]=1，xepc=当前头部指令 PC
```

- 清空粒度：一次 `flush` 广播（带 `rob_idx`），前端按索引丢弃年轻取指，后端按索引置无效；RLB（返回地址栈）/GHR 从 checkpoint 恢复。
- 被异常中断的指令**不产生任何架构副作用**（rd 不写、store 不落盘、CSR 不生效）。

## 7. 与 Linux / OpenSBI 的兼容性清单

| 需求 | 本设计支持情况 |
|---|---|
| S 模式 + Sv32 + ASID | ✅ |
| `sstatus/sie/stvec/sscratch/sepc/scause/stval/sip/satp/scounteren` | ✅ |
| 中断委托（STI/SSI/SEI） | ✅ |
| CLINT（`mtime`/`mtimecmp`/`msip`） | ✅ 核内实现 |
| PLIC（外部中断） | ✅ 核内实现，SiFive 布局 |
| PMP ≥ 8 项（OpenSBI 要求 16 项推荐） | ✅ 16 项 |
| `Zicbom`（非一致性 DMA cache 维护） | ✅ |
| `Zicntr`（`cycle/time/instret` + `mcounteren`） | ✅ |
| `misa` 报告 S/U | ✅ |
| `menvcfg.CBZE` 等（内核按此探测 Zicbom） | ✅ |
| 多核 SMP | ❌ 单核（Linux 配置 `CONFIG_SMP=n`） |
| 大端 | ❌ |
| H 扩展 / V 扩展 | ❌（不在需求范围） |

## 8. 验证要点

1. **CSR 单元测试**：逐条指令（`csrrw/csrrs/csrrc/csrrwi/...`）读写每个 CSR，检查 WARL 行为、只读位、非法 CSR 访问异常（`mcause=2`）。
2. **异常测试**：riscv-arch-test 的 `tests/priv/**`（机器级陷阱、CSR、PMP、Sv32）全部通过；构造每个异常码的正反例。
3. **MMU 测试**：4 KB/4 MB 页、U/S/M 权限组合、`SUM/MXR/MPRV` 组合、ASID 切换、`sfence.vma` 变体、A/D 位硬件更新、非法 PTE 的 12 种组合。
4. **PMP 测试**：NAPOT/TOR/NA4 边界、L 位锁定、M 模式无匹配可访问、S/U 模式无匹配拒绝。
5. **中断测试**：CLINT 定时器中断（`mtimecmp` 边界）、PLIC 优先级/阈值/claim-complete 流程、委托到 S 模式后的 `scause` 正确性。
6. **端到端**：OpenSBI 启动并打印 banner → 跳转 U-Boot → 启动 Linux。
