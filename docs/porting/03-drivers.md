# 驱动移植方案（串口 / 定时器 / 中断 / 复位 / CONFREG / DMA）

> 上游文档：`00-overview.md`、`02-linux.md`、`01-uboot.md`。本文档只列**需要做的工作**与**需要注意的点**。

---

## 1. 总表

| 设备 | 平台实现 | Linux 侧 | U-Boot 侧 | 工作量 |
|---|---|---|---|---|
| UART 16550 | `IP/APB_DEV/URT`，`0x1FE0_01E0`，33 MHz，中断线 UART | `8250_of`（标准驱动）+ DTS 节点 | `CONFIG_SYS_NS16550`（标准驱动） | **零代码**（仅 DTS/配置） |
| CLINT（mtime/mtimecmp/msip） | **核内实现**（`0x1F00_0000`） | `riscv,timer` / `CLINT_TIMER`（标准） | `CONFIG_RISCV_TIMER`（标准，SBI `TIME` 调用） | **零代码**（仅 DTS/配置） |
| PLIC（外部中断） | **核内实现**（`0x1F10_0000`），源 = `intrpt[7:0]` | `sifive,plic-1.0.0`（标准 `irq-sifive-plic`） | 不需要（U-Boot 轮询） | **零代码**（仅 DTS） |
| NAND 控制器 + DMA | `IP/APB_DEV/NAND` + `IP/DMA`，`0x1FE7_8000` / 门铃 `0x1FD0_1160` | 新驱动 `chiplab_nand.c` | 新驱动 `chiplab_nand.c` | **主要工作量** → 见 `04-nand.md` |
| CONFREG | `IP/CONFREG/confreg_syn.v` @ `0x1FD0_0000`（仿真 `confreg_sim.v` @ `0x1FAF_0000`） | 可选：reboot/poweroff、LED | 可选：启动指示 | 小（约 100 行） |
| 网络 MAC (dmfe) | `IP/MAC`，`0x1FF0_0000` | 第二阶段：可参考 `dmfe` 驱动（LA32R 树中有） | 可选 | 中（可延后） |
| SPI Flash | `IP/SPI/godson_sbridge_spi.v`，`0x1FE8_0000` + XIP `0x1C00_0000` | 可作为 MTD SPI-NOR（可选） | 已有 SPI flash 框架 | 可延后 |

**结论**：真正要写的驱动只有 **NAND**（内核 + U-Boot 两份）与**可选的 CONFREG/复位**驱动；串口、定时器、中断控制器都使用 RISC-V 生态的**标准绑定与标准驱动**，只要 CPU 与设备树正确即可零代码工作。

---

## 2. 串口（8250）

- **DTS**：`compatible = "ns16550a"`、`reg = <0x1fe001e0 0x10>`、`clock-frequency = <33000000>`（**注意**：这是 UART 时钟，与 CPU 时钟无关）、`interrupts = <2>`（PLIC 源 2 = `intrpt[1]`）。
- **注意**：平台 UART 是 16550 兼容核（`raminfr.v` + `uart_defines.h`），寄存器间距 1 字节（`reg-shift = <0>`，`reg-io-width = <1>`）；若出现乱码优先检查 `clock-frequency` 与 `reg-shift`。
- **不要移植** LA32R 的 `arch/loongarch/loongson32/serial.c`（存在 `memset` 清零 port 的 bug）。

## 3. 定时器 / 时钟源

- 核内 CLINT 提供 `mtime`（频率 = CPU 时钟）与 `mtimecmp`；Linux 使用 `riscv,timer`（`CONFIG_CLINT_TIMER`/`RISCV_TIMER`）作为 clocksource + clockevent。
- **DTS**：`clint@1f000000`，`interrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>`（MSIP/MTIP），`timebase-frequency` 在 `/cpus` 节点中给出。
- **注意**：`timebase-frequency` 必须与 CPU 实际频率一致（本项目 100 MHz 目标；若综合降频到 60/75 MHz，必须同步修改，否则定时中断频率错误约 1.6 倍）。
- U-Boot（S 模式）使用 SBI 的 `TIME` 扩展读取 `mtime`，无需驱动。

## 4. 中断控制器（PLIC）

- 核内 PLIC 兼容 `sifive,plic-1.0.0`，内核直接使用 `drivers/irqchip/irq-sifive-plic.c`。
- **DTS**：`riscv,ndev = <8>`，`interrupts-extended = <&cpu0_intc 11 &cpu0_intc 9>`（M/SEIP）。
- **源号映射**（与 CPU 设计一致）：1=MAC、2=UART、3=SPI、4=NAND、5=DMA（源 0 保留）。
- U-Boot 阶段不需要中断（轮询模式），故不配置。

## 5. CONFREG 与复位/电源

- **地址差异**（必须区分）：
  - **FPGA**（`confreg_syn.v`）：基址 `0x1FD0_0000`；LED `+0xF000`、`LED_RG0 +0xF004`、`LED_RG1 +0xF008`、NUM `+0xF010`、SWITCH `+0xF020`、`FREQ +0xF030`、TIMER `+0xE000`、**DMA 门铃 `+0x1160`**。
  - **仿真**（`confreg_sim.v`）：基址 `0x1FAF_0000`；LED `+0xF020`、NUM `+0xF050`、SWITCH `+0xF060`、TIMER `+0xE000`、**IO_SIMU `+0xFF00`（仿真退出）**、VIRTUAL_UART `+0xFF10`、SIMU_FLAG `+0xFF20`（只读）、NUM_MONITOR `+0xFF40`。
- **用途**：① 上板调试（LED/数码管显示启动阶段号）；② `reboot`/`poweroff`（LA32R 树中复位是死循环，本项目可用 CONFREG 的一个寄存器或 `syscon` 实现）；③ 仿真退出。
- **实现建议**：写一个小的 `drivers/power/reset/chiplab-reboot.c` + `syscon-reboot`（`compatible = "syscon-reboot"` 绑到 CONFREG 的一个寄存器），或直接把 `syscon` 节点指向 `0x1FD0_0000`；不要实现成"写寄存器直接复位 FPGA"（平台未提供该功能），可先实现为"回到 OpenSBI 的 warm reset"或提示不支持。

## 6. DMA 一致性（跨驱动的横切问题）

- 平台的 NAND/MAC 数据通路走**外部 DMA 引擎**（描述符 + 门铃 `0x1FD0_1160`），CPU 侧有 L1/L2 Cache 且**硬件不提供一致性**。
- **方案**：
  1. CPU 实现 `Zicbom`（`cbo.clean/flush/inval`），DTS 中给 DMA 相关节点加 `dma-noncoherent;`；
  2. 内核：依赖 `dma-direct` 的非一致性路径（`arch_sync_dma_for_device/cpu` → `cbo.*`）；若 5.14 的 RISC-V 尚无该框架，则在驱动里用 `dma_sync_single_for_{device,cpu}()` + 自定义 `riscv_dma_cache_*` 实现；
  3. U-Boot：实现 `flush_dcache_range()`/`invalidate_dcache_range()`，在 DMA 前后显式调用；
  4. 兜底：把 bounch buffer 放在**非缓存窗口**（由 CPU 固定把某段物理区间配置为非缓存）。
- **验证**：`nand write` → `nand read` → `cmp`；内核侧 `nandtest`/`flash_erase` + `md5sum`。

## 7. 驱动移植的通用注意事项（来自详查报告）

1. **删除一切 KSEG 别名**：`0x9fe78xxx`、`0x9fd01160`、`0xa0000000 |` 在 RISC-V 上无效；统一 `ioremap()` 平台资源（`platform_get_resource`）。
2. **不要使用 `dma_cache_wback/inv`**（Loongson 专用）。
3. **不要使用 `UMH_DISABLED` 作为 IRQ 标志**（LA32R 驱动中的误用）。
4. 参考驱动的 `#define CONFIG_MACH_LS232 1`、`USE_POLL` 宏等"编译期伪装"要清理掉，改为 Kconfig/DT 区分。
5. 分区定义统一走 `mtd_device_parse_register()` + `mtdparts=`/DT（LA32R 驱动的硬编码分区表与文档冲突）。
6. 中断号在 LA32R 树中是 `16 + hwirq` 的 LoongArch cpuic 约定；RISC-V 下由 PLIC 提供标准线性映射，DTS 中直接写 PLIC 源号。
