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

## 5. ECC 策略（已按实际芯片确定）

- **实际芯片**：**K9F1G08U0C-PCB0**（Samsung 1 Gbit SLC，128 MiB，页 2048+64 B，块 128 KiB）——由原理图确认（U8）。
- **芯片的 ECC 要求**：**1 bit / 512 Byte**（片内 Copy-Back EDC 为 1 bit/528 B）。即：一个 2048 B 页 = 4 个 512 B 扇区，每扇区纠正 1 bit 即满足器件规范。
- 现状：参考驱动把 ECC **完全关闭**（`NAND_ECC_ENGINE_TYPE_NONE`，`ecc_rd/ecc_wr=0`），仅有的线索是未启用的布局：**24 字节 ECC 位于 spare 偏移 40..63，`oobfree = {2, 38}`**。
- 控制器**支持**硬件 ECC（`CMD[11]/[12]/[24]`），但寄存器语义无文档。
- **本项目策略**（分两步）：
  1. **第一阶段：软件 ECC**——推荐 **软件 BCH-4**（内核 `CONFIG_MTD_NAND_ECC_SW_BCH`，U-Boot `CONFIG_NAND_ECC_SOFT_BCH`），每 512 B 用 7 B ECC，一页 28 B，64 B spare 足够（满足并超出 1 bit/512 B 的要求）；若想最小开销，软件 Hamming（3 B/512 B，共 12 B）也已满足器件规范。
  2. **第二阶段（可选）**：实测硬件 ECC —— 写入已知数据、置 `CMD[11]`/`CMD[12]` 观察 spare 中 ECC 字节位置与纠错行为；若与 24 B@40..63 布局一致则启用硬件 ECC 提速，并把 ECC 布局写入设备树（`nand-ecc-*` 属性）。
- **布局由我们的两份驱动共同定义**（控制器硬件 ECC 语义未知，不作为依赖）：ECC 算法、strength、step size、`oobfree` 必须在内核与 U-Boot 两侧**完全一致**（建议共享同一组 `#define` 或都由设备树读取），否则镜像互不可读。
- **坏块标记**：Samsung 大页 SLC 惯例为"每个块第 1 页 spare 区首字节非 `0xFF` 即坏块"，MTD 的 `badblockpos` 对大页默认 0，与之一致；上板用"擦除后读 spare 首字节"实测确认。

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
4. **几何校验**：参考驱动要求 128 KiB 块 / 2048 字节页 / 64 字节 OOB —— **与实际芯片 K9F1G08U0C 完全一致，无需放宽**；仍建议在 probe 时打印实测几何与器件 ID（`0xEC`/`0xF1`）以便上板核对。
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
| ~~硬件 ECC 语义未知~~ | 已确认芯片只需 **1 bit/512 B**，软件 BCH-4/Hamming 即满足 | 先软件 ECC；硬件 ECC 仅作为提速优化项 |
| 控制器 `PARAM`（`0x18`）语义未知 | 参考实现 RMW 时会清除 `0x0800_0000` 位 | 实测确定；驱动中固定写入实测可行的值 |
| ~~NAND 芯片型号/几何未知~~ | **已确认**：K9F1G08U0C-PCB0，2048+64 B 页 / 128 KiB 块 / 1024 块，与参考驱动 gate 吻合 | 无需放宽 gate |
| `IDH[31:16]` 作为状态字节的语义 | 参考实现的 `waitfunc` 依赖它 | 用 `done` 位 + `IDH` 双路判断 |
| DMA 与 Cache 一致性 | 平台无硬件一致性 | CPU 实现 Zicbom；驱动全程 `dma_sync_*` |
| 分区冲突 | 驱动/DTS/文档三处不一致 | 以本文 §6 为准，两侧共用同一 `mtdparts` |
| 时序寄存器（`TIMING=0x205`）取值 | 参考实现未给出推导依据，与 APB 33 MHz、器件 25 ns 串行访问时间的匹配需实测 | 上板抓 NAND 时序波形核对，必要时调整 |
