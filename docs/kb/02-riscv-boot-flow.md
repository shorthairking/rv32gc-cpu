# KB-02 RISC-V 启动链知识

## 1. 三段式启动（RV32 + MMU 场景）

```
M 模式：OpenSBI（fw_dynamic / fw_payload）
   │  · 提供 SBI：console / timer / IPI / RFENCE / HSM / (SRST, 可选)
   │  · 用 PMP 保护自己的内存；设置 mstatus.MPP=S 后 mret
   ▼
S 模式：U-Boot（S 模式，通过 SBI 使用串口与定时器）
   │  · 初始化 DDR/UART/PLIC/NAND，从 NAND 读内核
   │  · booti <kernel> <ramdisk|-> <dtb>
   ▼
S 模式：Linux（Sv32），用户态 U 模式
```

**为什么必须 S 模式**：`la32r-Linux` 的 `arch/riscv/Kconfig` 中 `config RISCV_M_MODE` 是隐藏符号（`bool` + `default !MMU`），而 `ARCH_RV32I` 无条件 `select MMU`，因此在 RV32 下 `RISCV_M_MODE=n`，内核必须通过 SBI 获取 console/timer/IPI。`[源码]`

## 2. 各级要求（对 CPU 的硬性要求）

| 阶段 | 需要 CPU 支持 |
|---|---|
| OpenSBI | M 模式、PMP（≥8 项，16 项推荐）、CLINT（mtime/mtimecmp/msip）、UART（8250）、`misa` 报告 IMAFDC/SU、`fence.i`、`Zicsr` |
| U-Boot（S 模式） | S 模式 CSR、SBI 调用、Sv32（可选）、`sfence.vma`、`Zicbom` 或自定义 cache 维护（NAND DMA 需要） |
| Linux（S 模式） | Sv32 MMU、ASID、S 模式陷阱/委托、CLINT 时钟源、PLIC 外部中断、`Zicn tr`、`Zicbom`、原子指令 A、`mstatus.SUM/MXR/MPRV` |

## 3. 内核镜像与加载

| 项目 | 约定 |
|---|---|
| 镜像格式 | `arch/riscv/boot/Image`（`objcopy -O binary vmlinux`）；也支持 `Image.gz` |
| 加载地址 | 2 MiB 对齐；RV32 的 `head.S` 声明支持的加载偏移上限 4 MiB（超过则需重定位检查） |
| 参数 | `a0 = hartid`，`a1 = DTB 物理地址` |
| 启动命令 | U-Boot：`booti ${kernel_addr_r} - ${fdt_addr_r}`；`bootm` + uImage 亦可 |
| DTB | 可内建（`CONFIG_BUILTIN_DTB=y`，推荐先用）或由 U-Boot 传入 |
| 命令行 | 设备树 `/chosen/bootargs` 或 U-Boot `bootargs` 环境变量（后者优先） |

## 4. 设备树必备节点（RISC-V 平台）

```dts
cpus { timebase-frequency = <CPU时钟>; cpu@0 {
    compatible="riscv"; riscv,isa="rv32imafdc_zicsr_zifencei_zicntr_zicbom";
    mmu-type="riscv,sv32";
    interrupt-controller { compatible="riscv,cpu-intc"; #interrupt-cells=<1>; interrupt-controller; }; }; }
clint@...   { compatible="riscv,clint0";    interrupts-extended=<&cpu0_intc 3 &cpu0_intc 7>; };
plic@...    { compatible="sifive,plic-1.0.0"; riscv,ndev=<N>; interrupts-extended=<&cpu0_intc 11 &cpu0_intc 9>; };
```

**注意**：
- `timebase-frequency` 必须等于 CPU 实际时钟（否则时钟中断频率错误）；
- `riscv,isa` 字符串中的扩展名要用内核认识的写法（`rv32imafdc_zicsr_zifencei...`）；
- PLIC 的 `riscv,ndev` 必须 ≥ 最大源号。

## 5. SBI 与 U-Boot 的配合

- OpenSBI 交付形式：
  - `FW_PAYLOAD`：把 U-Boot 作为 payload 一起打包（简单，但每次改 U-Boot 都要重编 OpenSBI）；
  - **`FW_DYNAMIC`（推荐）**：OpenSBI 只提供 SBI，U-Boot 作为下一个阶段由前一阶段（SPI flash 中的 OpenSBI）加载，并在 `a2` 传入 `struct fw_dynamic_info`；
- U-Boot 需要 `CONFIG_RISCV_SMODE=y`、SBI 支持（`CONFIG_SBI`/`RISCV_SBI`），其串口/定时器/IPI 通过 SBI 调用；
- 调试技巧：先让 OpenSBI 的 `fw_payload` 直接打印 banner，确认 M 模式 CSR/CLINT/PLIC 正常，再引入 U-Boot。

## 6. 常见启动问题定位表

| 现象 | 可能原因 |
|---|---|
| OpenSBI 无输出 | UART 时钟/偏移错；PMP 配置错误拒绝访问；CLINT 缺失 |
| OpenSBI 打印后无 U-Boot | S 模式 CSR 或 `mret` 语义错；Sv32 页表问题；DTB 未正确传递 |
| 内核 earlycon 无输出 | `earlycon=uart8250,mmio,0x1fe001e0` 参数错；UART 时钟 `clock-frequency` 不对 |
| 内核挂在 "Booting Linux" | Sv32 页表/权限位；`sfence.vma` 实现问题；原子指令（lr/sc/amo）实现错误 |
| 定时中断不来 | CLINT `mtimecmp` 语义（写高半抑制中断）；`timebase-frequency` 不符 |
| 外设中断不来 | PLIC 优先级/阈值/claim-complete 流程；委托位 `mideleg` 未设置 |
| 随机崩溃（跑一段时间后） | Cache 与 DMA 一致性；非对齐访问；VIPT 别名 |
