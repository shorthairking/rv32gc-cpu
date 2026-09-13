# NAND 驱动移植方案（内核 + U-Boot）

> 这是本项目**唯一必须新写**的驱动，也是任务中"u-boot 支持从 NAND 启动并写入 NAND"的关键路径。
> 参考实现：`la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c`（1173 行）；RTL：`chiplab/IP/APB_DEV/NAND/nand.v`（1430 行）+ `nand_module.v` + `apb_dev_top_with_nand.v`；DMA：`chiplab/IP/DMA`。
> 详查：`../../../../linux-porting-report.md` §4、§11。

---

## 1. 硬件结构

```
   CPU ──AXI──► axi_slave_mux ──APB──► apb_dev_top_with_nand
                                          ├── UART  (apb_addr[19:14]==0)
                                          └── NAND 控制器 (其余地址)
                                                ├── 寄存器口（CPU 访问，32 位寄存器）
                                                └── 数据口 0x40（DMA 引擎访问）
   DMA 引擎（门铃 0x1FD0_1160）──APB master──► NAND 数据口
                                     │
                                     └── 读/写 DDR（不具一致性！）
```

**关键结论**：NAND 的数据搬运**必须**经过平台 DMA 引擎（描述符 + 门铃），因此驱动必须同时处理 DMA 描述符与 Cache 一致性。

## 2. 寄存器映射（基址 `0x1FE7_8000`，32 位寄存器）

| 偏移 | 名称 | 读写 | 含义 |
|---|---|---|---|
| `0x00` | `CMD` | RW | 命令位域（见下）；**bit10 = DONE（只读，轮询）** |
| `0x04` | `ADDRL` | RW | 列地址（`READ0/SEQIN`：spare 起始 + 列；`READOOB`：`writesize + 列`；ERASE：0） |
| `0x08` | `ADDRH` | RW | 行地址（页号 / 块号） |
| `0x0C` | `TIMING` | RW | 时序；初始化 `0x412`，读写用 `0x205` |
| `0x10` | `IDL` | RO | ID 字节 1–4（大端排列在一个字内） |
| `0x14` | `IDH` | RO | `[7:0]`=ID 字节 0（厂商）；`[31:16]`=NAND 状态 |
| `0x18` | `PARAM` | RW | 参数；初始化 `0x0800_5300`；`[21:16]` 镜像 `OP_NUM`（写时 RMW，会清除 bit27，需注意） |
| `0x1C` | `OP_NUM` | RW | 传输字节数（如 2112、64） |
| `0x20` | `CS_RDY_MAP` | RW | CE/RDY 映射；初始化 `0x8844_2200` |
| `0x24` | `CS_MAP1` | RW | （RTL 中 `nand_ce_map1`，参考驱动未使用） |
| `0x28` | `RDY_MAP0` | RW | （RTL 中 `nand_rdy_map0`） |
| `0x2C` | `RDY_MAP1` | RW | （RTL 中 `nand_rdy_map1`） |
| `0x40` | 数据口 | RW | DMA 引擎的数据端口（描述符 `daddr`） |

**`CMD`（`0x00`）位域**（与参考驱动 `struct ls1a_nand_cmdset` 一致）：

| 位 | 名称 | 说明 |
|---|---|---|
| 0 | `cmd_valid` | 启动一次操作 |
| 1 | `read` | 读 |
| 2 | `write` | 写 |
| 3 | `erase_one` | 擦除一块 |
| 4 | `erase_con` | 连续擦除 |
| 5 | `read_id` | 读 ID |
| 6 | `reset` | 复位芯片 |
| 7 | `read_sr` | 读状态寄存器 |
| 8 | `op_main` | 操作主区 |
| 9 | `op_spare` | 操作 spare 区 |
| 10 | `done` | **只读，操作完成** |
| 11 | `ecc_rd` | 读使能硬件 ECC |
| 12 | `ecc_wr` | 写使能硬件 ECC |
| 13 | `int_en` | 中断使能 |
| 15 | `ram_op` | 内部 RAM 操作 |
| 19:16 | `nand_rdy` | NAND 就绪位（只读） |
| 23:20 | `nand_ce` | 片选 |

## 3. DMA 引擎接口

| 项目 | 值 |
|---|---|
| 门铃寄存器 | 物理 `0x1FD0_1160`（写 `描述符物理地址 \| (1<<3)`；轮询直到 bit3 清零） |
| 数据端口 | `0x1FE7_8040`（描述符 `daddr`） |
| 描述符（32 字节，DRAM 中，`dma_alloc_coherent`） | `+0x00 orderad=0`、`+0x04 saddr=缓冲区物理地址`、`+0x08 daddr=0x1FE78040`、`+0x0C length=**字数**（字节/4 向上取整）`、`+0x10 step_length=0`、`+0x14 step_times=1`、`+0x18 cmd` |
| `cmd` 位 | `[0]=dma_int_mask(=1)`、`[12]=dma_r_w`（1 = 内存→NAND，即写方向）、其余为状态位 |

**DMA 步骤（读方向）**：flush 描述符 → 写门铃 → 轮询门铃 bit3 → 轮询控制器 DONE → invalidate 数据缓冲区 Cache。
**DMA 步骤（写方向）**：flush 数据缓冲区 → flush 描述符 → 写门铃 → 轮询 → 控制器 DONE。

## 4. 命令序列（必须与参考实现一致）

| 操作 | `ADDRL`/`ADDRH` | `OP_NUM` | DMA | `CMD` 位 | 轮询 |
|---|---|---|---|---|---|
| `READ0` | `0` / 页号 | 2112（2048+64） | `length=528` 字，方向=读，`daddr=0x40` | `int_en,read,op_spare,op_main,cmd_valid` | DONE（上限 60 次 × 1 µs）→ cache inval |
| `READOOB` | `writesize` / 页号 | 64 | `length=16` 字 | `int_en,read,op_spare,cmd_valid` | 同上 |
| `SEQIN` | 延迟 | — | 无 | 无（仅记录列/页） | 立即完成 |
| `PAGEPROG` | `+seqin_column` / 页号 | 已写入字节数 | `length=字节/4`，方向=**写** | `int_en,write,op_spare(,op_main)`, `cmd_valid` | DONE（上限 400 次 × 2 µs） |
| `ERASE1` | `0` / 块内首页 | — | **无 DMA** | `erase_one,cmd_valid` | `udelay(2000)` + DONE（100 次 × 50 µs） |
| `RESET` | — | — | 无 | `reset,cmd_valid` | DONE |
| `READID` | — | — | 无 | 向 `0x00` 写 `0x21` | `udelay(1)` 后读 `IDH/IDL` |
| `STATUS` | — | — | 无 | 软件合成（`status \| 0x80`） | — |

## 5. ECC 策略（必须显式决定）

- 现状：参考驱动把 ECC **完全关闭**（`NAND_ECC_ENGINE_TYPE_NONE`，`ecc_rd/ecc_wr=0`），仅有的线索是未启用的布局：**24 字节 ECC 位于 spare 偏移 40..63，`oobfree = {2, 38}`**。
- 控制器**支持**硬件 ECC（`CMD[11]/[12]/[24]`），但语义无文档。
- **本项目策略**（分两步）：
  1. **第一阶段：软件 BCH ECC**（内核 `CONFIG_MTD_NAND_ECC_SW_BCH=y`，U-Boot `CONFIG_NAND_ECC_SOFT_BCH`），保证数据可靠；代价是 CPU 开销（NAND 写入慢，但内核/uboot 场景可接受）；
  2. **第二阶段（可选）**：实测硬件 ECC：写入已知数据 → 读回并对比 `CMD[11]` 置位时的 ECC 字节位置与纠错行为 → 若与 24B@40..63 布局一致则启用硬件 ECC 提升性能，并把 ECC 布局写入设备树（`nand-ecc-*` 属性）。
- **注意**：ECC 布局必须与 U-Boot 一致（否则 U-Boot 写的镜像内核读不出来）。两处共用同一个 `#define`（例如放在 `include/linux/mtd/nand-ecc-layout.h` 与 U-Boot 的对应头文件中，或都从设备树读取）。

## 6. 分区（统一定义）

| 分区 | 偏移 | 大小 | 用途 |
|---|---|---|---|
| `env` | `0x0000_0000` | 256 KiB | U-Boot 环境变量 |
| `kernel` | `0x0004_0000` | 50 MiB | 内核 Image（只读） |
| `dtb` | `0x0324_0000` | 1 MiB | 设备树 |
| `rootfs` | `0x0334_0000` | 剩余（≈76.75 MiB） | UBIFS（第二阶段） |

- 内核侧：**删除**参考驱动的硬编码 `lart_partitions[]`（21M/35M），改用 `mtd_device_parse_register(mtd, NULL, NULL, NULL, 0)`，让 `mtdparts=` 或设备树分区生效；
- U-Boot 侧：`CONFIG_MTDPARTS_DEFAULT` 使用同一字符串，保证两侧一致；
- 与 chiplab 文档（`nand-flash:50M@0(kernel)ro,-(rootfs)`）的差异在于显式增加 `env` 与 `dtb` 分区，避免环境变量与内核镜像冲突。

## 7. 内核驱动实现要点（`chiplab_nand.c`）

1. **结构**：以参考驱动的命令序列为蓝本，但改用 **`->exec_op()`（`nand_op_parser`）** 接口（5.14 支持），把 `CMD/ADDR/DATA_IN/DATA_OUT` 映射到寄存器 + DMA；保留 `->legacy.*` 作为后备。
2. **地址**：全部通过 `platform_get_resource(pdev, IORESOURCE_MEM, 0/1)` 获取（控制器 + 门铃），`devm_ioremap_resource`；**杜绝硬编码**。
3. **DMA**：`dma_alloc_coherent()` 分配描述符与数据缓冲；`dma_sync_single_for_cpu/device()` 做 cache 维护；使用 `readl_poll_timeout` 轮询门铃与 DONE（带超时与错误恢复，参考实现的 `write_z_cmd` 恢复路径可借鉴）。
4. **几何校验**：参考驱动要求 128 KiB 块 / 2048 字节页 / 64 字节 OOB，否则 probe 失败；本项目**放宽为警告**，让 `nand_scan` 自行识别（并记录实测几何）。
5. **中断**：先实现**轮询**（参考实现即轮询），DTS 中保留中断属性备用。
6. **`CACHEPRG`**：确认控制器是否支持 `NAND_CMD_CACHEDPROG`，不支持则去掉 `NAND_CACHEPRG` 选项。

## 8. U-Boot 驱动实现要点（`drivers/mtd/nand/raw/chiplab_nand.c`）

1. 实现 `board_nand_init(struct nand_chip *chip)`（`CONFIG_SYS_NAND_SELF_INIT=y`），填 `chip->legacy.cmdfunc/read_buf/write_buf/dev_ready/waitfunc` 或直接实现 `exec_op`；
2. `CONFIG_SYS_NAND_BASE=0x1fe78000`、`CONFIG_SYS_MAX_NAND_DEVICE=1`；
3. DMA 描述符使用 `memalign(32, ...)` 分配在 DDR（非缓存或显式 flush）；
4. `arch/riscv/lib/cache.c` 中实现 `flush_dcache_range`/`invalidate_dcache_range`（Zicbom），U-Boot 的 NAND 读写路径依赖；
5. 使能 `CONFIG_NAND`、`CONFIG_CMD_NAND`、`CONFIG_CMD_MTD`、`CONFIG_CMD_MTDPARTS`、`CONFIG_MTD_DEVICE`、`CONFIG_ENV_IS_IN_NAND`。

## 9. 验证计划（自下而上）

| 步骤 | 内容 | 通过标准 |
|---|---|---|
| N1 | 裸机程序：读 ID（`0x21`） | 读到厂商/设备 ID，与板上芯片一致 |
| N2 | 裸机程序：擦除一块 → 写 2 KiB 模式 → 读回比较（PIO/DMA 通路） | 完全一致（含 OOB） |
| N3 | 裸机程序：连续 100 块读写 + 随机偏移 | 无误码（验证 DMA 与 Cache 维护） |
| N4 | U-Boot：`nand info` / `mtd list` | 识别 128 MiB、4 个分区 |
| N5 | U-Boot：`mtd erase/write/read` + `cmp` | 一致 |
| N6 | U-Boot：`saveenv` + 断电重启 | 环境变量保留 |
| N7 | U-Boot：`bootcmd` 从 NAND 启动内核 | 内核启动日志正常 |
| N8 | Linux：`mtdinfo`/`flash_erase`/`nandwrite` + `md5sum` | 一致；`dmesg` 无 ECC/DMA 错误 |
| N9 | Linux：UBIFS 挂载/读写 + 掉电重启 | 文件系统可恢复（第二阶段） |

## 10. 风险与未决问题

| 风险 | 说明 | 处理 |
|---|---|---|
| 硬件 ECC 语义未知 | 唯一线索是 24B@40..63 布局 | 先软件 ECC；硬件 ECC 作为优化项 |
| `PARAM`（`0x18`）语义未知 | 参考实现 RMW 时会清除 `0x0800_0000` 位 | 实测确定；驱动中固定写入实测可行的值 |
| NAND 芯片型号/几何未知 | probe 的几何 gate 可能不匹配 | 放宽 gate + 实测记录 |
| `IDH[31:16]` 作为状态字节的语义 | 参考实现的 `waitfunc` 依赖它 | 用 `done` 位 + `IDH` 双路判断 |
| DMA 与 Cache 一致性 | 平台无硬件一致性 | CPU 实现 Zicbom；驱动全程 `dma_sync_*` |
| 分区冲突 | 驱动/DTS/文档三处不一致 | 以本文 §6 为准，两侧共用同一 `mtdparts` |
