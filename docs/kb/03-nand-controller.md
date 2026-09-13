# KB-03 NAND 控制器与 DMA 引擎速查

## 0. NAND 芯片身份（由 `实验箱A7-原理图.pdf` 确认，2026-09-13 更新）

**位号 U8，型号 `K9F1G08U0C-PCB0`（Samsung 1 Gbit SLC NAND Flash，3.3 V）**

| 项目 | 参数 | 与平台的一致性 |
|---|---|---|
| 容量 | 1 Gbit = **128 MiB**（Memory Cell Array (128M + 4M) × 8 bit） | 与 RTL `nand_type = 2'h2`（1 Gbit）**完全一致** |
| 页大小 | **2048 + 64 B**（Data Register (2K + 64) × 8） | 与参考驱动几何 gate（2048/64）一致 |
| 块大小 | **128 KiB + 4 KiB**（(128K + 4K) Byte） | 与几何 gate（`1<<17`）一致 |
| 页数/块 | 64 页 | — |
| 总块数 | 1024 块 | — |
| 接口 | x8，命令/地址/数据复用 I/O | — |
| 读 | Random Read 25 µs (max)；Serial Access 25 ns (min) | 决定轮询超时（参考实现 60 × 1 µs 偏紧，建议放宽） |
| 写 | Page Program 200 µs (typ) | 参考实现 400 × 2 µs = 800 µs 上限合理 |
| 擦 | Block Erase 1.5 ms (typ) | 参考实现 `udelay(2000)` + 100 × 50 µs 合理 |
| **ECC 要求** | **1 bit / 512 Byte**（片内 Copy-Back EDC 为 1 bit/528 Byte） | 见 §5 |
| 器件 ID | 厂商 `0xEC`（Samsung）+ 器件 `0xF1` → Linux `nand_ids.c` 中 `EXTENDED_ID_NAND("NAND 128MiB 3,3V 8-bit", 0xF1, 128, LP_OPTIONS)` | 与 128 MiB/2 KB 页/大页选项一致 |
| 电压 | 2.7 ~ 3.6 V（3.3 V 标称） | 与 FPGA bank 电平一致 |
| 连接 | 单 CE#（→ `nand_ce[0]`）、R/B# → `FPGA_NAND_RDY`（RTL 只接 1 位 `nand_rdy[0]`）、WP#、CLE、ALE、RE#、WE#、IO0-7 | 与 `soc_top` 的 `NAND_CE = nand_ce[0]`、`nand_rdy = {3'd0, NAND_RDY}` 一致 |

**来源**：① 原理图 `实验箱A7-原理图.pdf` 第 5 页 NANDFLASH 区块（U8 = K9F1G08U0C-PCB0，引脚表 IO0-IO7/CLE/ALE/WE#/WP#/CE#/RE#/RDY/B）；② Samsung K9F1G08U0C 特性表（3.3 V、2K+64 B 页、128K+4K B 块、tR 25 µs、tPROG 200 µs、tBERS 1.5 ms、1 bit/512 B ECC）；③ Linux `drivers/mtd/nand/raw/nand_ids.c:107`（`0xF1` → 128 MiB 3.3 V 8-bit）。

> **结论**：NAND 几何与参考驱动的 gate **完全吻合**，无需放宽 `ls1a_nand_detect()`；ECC 只需 1 bit/512 B 能力。

## 1. 一句话总结

平台的 NAND 是 **Loongson LS1A 风格的 APB NAND 控制器**（基址 `0x1FE7_8000`），数据搬运**必须**经过平台 **DMA 引擎**（门铃物理地址 `0x1FD0_1160`），而 DMA 不具备 Cache 一致性。

## 2. 寄存器速查（32 位寄存器，基址 `0x1FE7_8000`）`[RTL][LA32R]`

```
0x00 CMD      : [0]cmd_valid [1]read [2]write [3]erase_one [4]erase_con
                [5]read_id [6]reset [7]read_sr [8]op_main [9]op_spare
                [10]DONE(只读,轮询) [11]ecc_rd [12]ecc_wr [13]int_en
                [15]ram_op [19:16]nand_rdy [23:20]nand_ce [24]ecc_dma_req
0x04 ADDRL    : 列地址（spare 从 +writesize 开始）
0x08 ADDRH    : 页号 / 块号
0x0C TIMING   : 初始化 0x412；读写 0x205
0x10 IDL      : ID1..ID4（一个字内大端）
0x14 IDH      : [7:0]=ID0（厂商），[31:16]=NAND 状态
0x18 PARAM    : 初始化 0x0800_5300；[21:16] 镜像 OP_NUM（RMW 会清 bit27）
0x1C OP_NUM   : 传输字节数（2112 / 64）
0x20 CS_RDY_MAP: 0x8844_2200
0x24/0x28/0x2C: ce_map1 / rdy_map0 / rdy_map1（参考驱动未用）
0x40          : DMA 数据口（描述符 daddr = 0x1FE7_8040）
```

## 3. DMA 引擎速查

```
门铃 0x1FD0_1160 : 写 (描述符物理地址 | (1<<3))，轮询直到 bit3 == 0

描述符（32 字节，DRAM，dma_alloc_coherent）
  +0x00 orderad     = 0
  +0x04 saddr       = 数据缓冲区物理地址
  +0x08 daddr       = 0x1FE78040（控制器数据口）
  +0x0C length      = 字数（= 字节数/4 向上取整）
  +0x10 step_length = 0
  +0x14 step_times  = 1
  +0x18 cmd         : [0]int_mask(=1) [12]dma_r_w(1=内存→NAND) [14:13]cmd
```

## 4. 命令时序速查

| 操作 | 关键寄存器 | CMD 位 | 完成后 |
|---|---|---|---|
| READ0 | ADDRL=0, ADDRH=页, OP_NUM=2048+64 | `int_en,read,op_spare,op_main,cmd_valid` | 轮询 DONE → DMA 完成 → `invalidate_dcache` |
| READOOB | ADDRL=2048, ADDRH=页, OP_NUM=64 | `int_en,read,op_spare,cmd_valid` | 同上 |
| SEQIN | 仅记录列/页 | — | 立即 |
| PAGEPROG | ADDRL=+列, ADDRH=页, OP_NUM=已写字节 | `int_en,write,op_spare(,op_main),cmd_valid` | 先 `flush_dcache`，DMA 方向=写 |
| ERASE1 | ADDRL=0, ADDRH=块首页 | `erase_one,cmd_valid`（**无 DMA**） | `udelay(2000)` + DONE |
| RESET | — | `reset,cmd_valid` | DONE |
| READID | — | 向 0x00 写 `0x21` | `udelay(1)` 后读 IDH/IDL |

轮询上限参考：读 60 次×1 µs、写 400 次×2 µs、擦 100 次×50 µs。

## 5. ECC

- 参考驱动**完全关闭硬件 ECC**（`NAND_ECC_ENGINE_TYPE_NONE`）；控制器有 `ecc_rd/ecc_wr` 位但**寄存器语义仍无文档**（唯一的布局线索是**未启用**的 24 字节 ECC 位于 spare 偏移 40..63、`oobfree = {2, 38}`）。`[LA32R]`
- **芯片要求已知**：K9F1G08U0C 只需 **1 bit / 512 Byte** 纠错能力（片内 Copy-Back EDC 为 1 bit/528 B）。
- **本项目策略**：
  1. **第一阶段用软件 ECC**：内核 `CONFIG_MTD_NAND_ECC_SW_HAMMING`（3 B/512 B，恰好满足 1 bit/512 B）或 `CONFIG_MTD_NAND_ECC_SW_BCH`（BCH-4，7 B/512 B，留有余量）；U-Boot 侧用 `CONFIG_NAND_ECC_SOFT`/`SOFT_BCH`。**推荐 BCH-4**：2048 B 页 = 4 个 512 B 扇区 → 28 B ECC，64 B spare 足够。
  2. ECC 布局由**我们自己的两份驱动共同定义**（内核与 U-Boot 必须一致），不依赖控制器硬件 ECC 的未知语义；
  3. **第二阶段（可选）**：实测控制器硬件 ECC（置 `CMD[11]` 写/`CMD[12]` 读，观察 spare 中 ECC 字节的位置与纠错行为），若与 24 B@40..63 布局一致则可启用硬件 ECC 提速。
- **一致性要求**：U-Boot 写入 NAND 的 ECC 布局必须与内核读取时完全一致，否则镜像互不可读——把布局参数（ECC 算法、strength、step size、oobfree）写在共享的头文件/设备树中并保持同步。

## 5.1 坏块标记（依据 K9F1G08U0C 器件规范）

- Samsung 大页 SLC 的坏块信息写在**每个块第 1 页 spare 区的第 1 个字节**（列地址 2048，值为非 `0xFF` 即坏块）；部分器件同时在**第 2 个字节**标记（MTD 的 `badblockpos` 对大页默认为 0，与之一致）。
- 参考驱动未显式设置 `badblockpos`，走的即是默认值；本项目在实测时用"擦除后读 spare 首字节"确认。`[TODO：上板实测确认]`

## 6. 分区（本项目统一）

```
mtdparts=nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)
   env    @0x0000_0000  256 KiB   U-Boot 环境变量
   kernel @0x0004_0000  50 MiB    内核 Image
   dtb    @0x0324_0000  1 MiB     设备树
   rootfs @0x0334_0000  ≈76.75 MiB UBIFS
```

## 7. NAND 几何（已确认）

- `nand_type = 2'h2` → **1 Gbit（128 MiB）**，与实际芯片 K9F1G08U0C（1 Gbit）**一致**。
- 实际几何：**页 2048 + 64 B / 块 128 KiB / 1024 块 / 64 页每块** —— 与参考驱动 `ls1a_nand_detect()` 的 gate（128 KiB、2048、64）**完全吻合，无需放宽**。
- 坏块标记位置：见 §5.1（Samsung 大页 SLC 惯例为块内第 1 页 spare 首字节；上板实测确认）。`[TODO：实测]`
- 时序寄存器：读/写用 `TIMING = 0x205`（参考实现的 `_NAND_TIMING_TO_*`）、初始化 `0x412`；需按 33 MHz APB 时钟与器件 25 ns 串行访问时间核对，实测波形确认。`[TODO：实测]`

## 8. 与 Cache 一致性的关系（最重要）

- DMA 直接读写 DDR，CPU 有 L1/L2 Cache 且**硬件无一致性**；
- LA32R 内核的 `dma_cache_*` 在 FPGA 上**实际是空操作**（`#ifdef BX_SOC` 拼写错误导致），所以"LA32R 能跑"**不能**证明无需 cache 维护。`[LA32R]`
- RV32 侧做法：CPU 实现 `Zicbom` → 内核 `dma-noncoherent` + `dma_sync_*`；U-Boot 实现 `flush_dcache_range`/`invalidate_dcache_range` 并显式调用。
