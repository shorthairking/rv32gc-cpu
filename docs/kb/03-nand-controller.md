# KB-03 NAND 控制器与 DMA 引擎速查

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

- 参考驱动**完全关闭硬件 ECC**（`NAND_ECC_ENGINE_TYPE_NONE`）；控制器有 `ecc_rd/ecc_wr` 位但语义无文档。
- 已知唯一布局线索：**24 字节 ECC 位于 spare 偏移 40..63，`oobfree = {2, 38}`**（参考驱动中未启用）。`[LA32R]`
- **本项目策略**：先用软件 BCH ECC（内核 `CONFIG_MTD_NAND_ECC_SW_BCH`，U-Boot `CONFIG_NAND_ECC_SOFT_BCH`）；U-Boot 与内核必须使用**相同的 ECC 布局**，否则镜像互不可读。

## 6. 分区（本项目统一）

```
mtdparts=nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)
   env    @0x0000_0000  256 KiB   U-Boot 环境变量
   kernel @0x0004_0000  50 MiB    内核 Image
   dtb    @0x0324_0000  1 MiB     设备树
   rootfs @0x0334_0000  ≈76.75 MiB UBIFS
```

## 7. NAND 几何（RTL 默认）

- `nand_type = 2'h2` → **1 Gbit（128 MiB）**
- 参考驱动要求（`ls1a_nand_detect`）：**块 128 KiB / 页 2048 B / OOB 64 B**，否则 probe 失败（本项目放宽为警告）。`[LA32R]`
- 坏块标记位置需实测确认。`[TODO]`

## 8. 与 Cache 一致性的关系（最重要）

- DMA 直接读写 DDR，CPU 有 L1/L2 Cache 且**硬件无一致性**；
- LA32R 内核的 `dma_cache_*` 在 FPGA 上**实际是空操作**（`#ifdef BX_SOC` 拼写错误导致），所以"LA32R 能跑"**不能**证明无需 cache 维护。`[LA32R]`
- RV32 侧做法：CPU 实现 `Zicbom` → 内核 `dma-noncoherent` + `dma_sync_*`；U-Boot 实现 `flush_dcache_range`/`invalidate_dcache_range` 并显式调用。
