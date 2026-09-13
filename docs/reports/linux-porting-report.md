# Porting survey: `la32r-Linux` (LA32R / chiplab) → RV32-GC on chiplab

**Subject tree:** `/home/shorthair/dsh/rv32-cpu/la32r-Linux`
**Sibling trees consulted:** `la32r-uboot` (U-Boot 2019.07 fork), `chiplab` (RTL + docs)
**Survey date / mode:** read-only survey; the only file written is this report.

---

## 0. Executive summary — read this first

Five findings dominate the porting plan:

1. **The kernel is Linux 5.14.0-rc2 with a *custom* `arch/loongarch`** — not `arch/riscv`. The
   LA32R/chiplab board is built from `arch/loongarch` with `ARCH=loongarch`,
   `make la32_defconfig`, and the chip is a **LoongArch** core, not RISC-V.
2. **A complete, essentially-upstream `arch/riscv` is present in the same tree and already
   supports RV32** (`CONFIG_ARCH_RV32I`, Sv32 MMU, `-mabi=ilp32`, `UTS_MACHINE=riscv32`,
   `arch/riscv/configs/rv32_defconfig`). This is a *huge* gift: the RV32-GC port should
   start from `arch/riscv` (which is already RV32-capable) and add a chiplab SoC + driver
   set, rather than converting `arch/loongarch`.
3. **The NAND driver is `drivers/mtd/nand/raw/ls1a_nand.c` (1173 lines), `CONFIG_MTD_NAND_LS1A`,
   compatible `"ls1a-nand"`.** It is a raw-NAND *legacy* driver for the Loongson LS1A/LS232
   NAND controller with an external descriptor-based DMA engine. Controller base
   **`0x1fe78000`** (accessed as `0x9fe78000`), DMA doorbell **`0x9fd01160`**, DMA data port
   **`0x1fe78040`**. Crucial caveats: it **runs with hardware ECC disabled**, it **hardcodes
   uncached `0x9f…`/`0xa0…` Loongson KSEG addresses** (which do not exist on RISC-V), and its
   **device-tree node is `#if 0`-disabled in both board DTS files**, so it cannot bind as shipped.
4. **The DTS's NAND partitions are dead code.** The driver never parses `partition@…` children;
   it registers a hardcoded `lart_partitions[]` (kernel 21 MiB @0, "file system" 35 MiB @21 MiB).
   The documentation and the bootloader use a *different* layout (`50M@0(kernel)ro,-(rootfs)`).
   This mismatch must be resolved deliberately.
5. **Rootfs is a built-in initramfs** (`CONFIG_INITRAMFS_SOURCE`, empty by default), not UBI/UBIFS
   on NAND. The NAND is used as a "hard disk" alternative boot media, and the shipped
   configuration comments out both the DT node and the rootfs source — so the NAND path is a
   *latent, untested-in-tree* feature that must be brought up deliberately.

---

## 1. Kernel version and git state

`Makefile` lines 2–6:

```
VERSION = 5
PATCHLEVEL = 14
SUBLEVEL = 0
EXTRAVERSION = -rc2
NAME = Opossums on Parade
```

→ **Linux 5.14.0-rc2** ("Opossums on Parade").

Git state (the clone is a shallow/squashed import, so history is essentially absent):

```
$ git log --oneline -15
4ed7b98e08e8 !4 更新 README，区分 3 个平台的编译步骤 Merge pull request !4 from merge

$ git describe --tags
fatal: No tags can describe '4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e'.

$ git remote -v
origin  https://gitee.com/loongson-edu/la32r-Linux.git (fetch)
origin  https://gitee.com/loongson-edu/la32r-Linux.git (push)
```

* The repository has a **single squashed commit** — there is no usable upstream history, no tags,
  and therefore no way to diff against vanilla 5.14-rc2 from within the tree.
* **Consequence for the port:** you cannot rebase this work onto `arch/riscv`. Treat
  `arch/loongarch` as *reference material* and `arch/riscv` as *upstream 5.14-rc2 code* to
  extend.

`README.md` (58 lines) is the authoritative project document and confirms the baseline:

> `README.md:3` — 此内核基于 Linux 5.14.0-rc2 移植而来，支持 LoongArch 32 Reduced（la32r）指令集架构。
> 目前，该内核支持在 la32r 的 3 个不同平台上运行：la32r-QEMU，chiplab/loongson-soc 和全流程平台参考 SOC。

---

## 2. Architecture directory and machine support

### 2.1 `arch/` contents

```
$ ls arch/
Kconfig  alpha  arc  arm  arm64  csky  h8300  hexagon  ia64
loongarch  m68k  microblaze  mips  nds32  nios2  openrisc
parisc  powerpc  riscv  s390  sh  sparc  um  x86  xtensa
```

The two that matter are `arch/loongarch` (the fork's own arch) and `arch/riscv` (upstream).

### 2.2 `arch/loongarch` layout

```
arch/loongarch/
├── Kbuild, Kbuild.platforms, Kconfig, Kconfig.debug, Makefile
├── boot/dts/loongson/{Makefile, loongson32_bx.dts, loongson32_ls.dts}
├── configs/{la32_bx_defconfig, la32_defconfig, loongson3_defconfig}
├── include/
├── kernel/            (head.S, entry.S, genex.S, traps.c, time.c, reset.c, …)
├── lib/, mm/, pci/, vdso/
├── loongson32/        <-- the chiplab / loongson-soc machine directory
└── loongson64/
```

Note there is **no `arch/loongarch/mach-*`**: unlike `arch/arm`, this tree uses
`arch/loongarch/loongson32/` + `arch/loongarch/loongson64/` as platform subdirectories,
selected via `arch/loongarch/Kbuild.platforms`:

```
# arch/loongarch/Kbuild.platforms:1-7
platforms += loongson64
platforms += loongson32
include $(patsubst %, $(srctree)/arch/loongarch/%/Platform, $(platforms))
```

### 2.3 The chiplab machine directory: `arch/loongarch/loongson32/`

| File | Purpose |
|---|---|
| `Platform` | platform build/cflag/load rules; `platform-$(CONFIG_MACH_LOONGSON32) += loongson32/`, `load-$(CONFIG_MACH_LOONGSON32) += 0xa0300000` |
| `Kconfig` | `MACH_LOONGSON_32` (+ machine choice `LOONGSON_MACH3X` / `MACH_LOONGSON_32`, SoC choice `BX_SOC` / `LS_SOC`) |
| `Makefile` | `obj-y += prom.o setup.o env.o reset.o irq.o mem.o serial.o uart_base.o`, `smp.o`, `early_printk.o`, `dma-noncoherent.o` |
| `setup.c` | board init; **built-in DTB selection** (`__dtb_loongson32_ls_begin` vs `__dtb_loongson32_bx_begin`), memory map parse, EFI/DMI/SMBIOS |
| `prom.c` | firmware/prom entry (fw_arg parsing, `prom_init_loongson_uart_base`) |
| `env.c` | environment variables |
| `serial.c` | registers the legacy `"serial8250"` platform device (see §6.1 — largely non-functional) |
| `uart_base.c` | `loongson_uart_base[0]`: **LS_SOC → `0x9fe001e0`**, BX_SOC → `0x9fe40000` |
| `early_printk.c` | `prom_putchar()` on the raw 8250 registers at the same two addresses |
| `irq.c` | `mach_irq_dispatch()`, `arch_init_irq()`, ECFG/ESTAT CSR handling |
| `reset.c` | `pm_restart` / `pm_power_off` → idle loop (no real reboot/poweroff device) |
| `mem.c` | `early_memblock_init()`, `fw_init_memory()`; reserves first 2 MiB |
| `smp.c` | SMP bring-up (`CONFIG_SMP`) |
| `dma-noncoherent.c` | non-coherent DMA helpers (`CONFIG_DMA_NONCOHERENT`) |

**SMP is impossible on this port.** `arch/loongarch/Kconfig:128-140` shows `MACH_LOONGSON32`
selects `NR_CPUS_DEFAULT_1` and **does not select `SYS_SUPPORTS_SMP`**, and
`arch/loongarch/Kconfig:396-398` gates `config SMP` on `SYS_SUPPORTS_SMP`. Consequently
`la32_defconfig:25` has `CONFIG_BROKEN_ON_SMP=y` and no `CONFIG_SMP`;
`arch/loongarch/loongson32/smp.c` (20 lines) contains **no functions at all** — only per-CPU
variable definitions and `loongson3_smp_ops` is declared in
`mach-loongson32/loongson.h:18` but never defined. (The `smp_group` base at `0x1fe01000` sits in
`env.c:131` inside `#ifdef CONFIG_SMP`, i.e. dead.) **The LA32R kernel is uniprocessor-only.**

**Cache-flush functions are compiled out by a bug.** `arch/loongarch/loongson32/setup.c:368`,
`arch/loongarch/mm/cache.c:27,46` and `arch/loongarch/include/asm/cacheflush.h:40` all test
**`#ifdef BX_SOC`** — without the `CONFIG_` prefix — which is never defined anywhere in the tree.
Effects: the `c67x00` USB device is never registered, `local_flush_cache_all()` is never compiled,
`local_flush_icache_range()` degenerates to a bare `ibar 0` (`mm/cache.c:43-49`), and **all
`flush_cache_*`/`flush_dcache_*` become no-ops** (`cacheflush.h:55-68`). This is directly relevant
to the NAND DMA path (§11): the driver's `dma_cache_*()` calls come from
`arch/loongarch/loongson32/dma-noncoherent.c`, but the surrounding cache-flush architecture is
partly neutered. **Do not assume LA32R's working NAND behaviour implies a coherent cache — verify
cache maintenance explicitly on RV32-GC.**

`arch/loongarch/loongson32/Platform` (verbatim, relevant part):

```
platform-$(CONFIG_MACH_LOONGSON32) += loongson32/
cflags-$(CONFIG_MACH_LOONGSON32)   += -I$(srctree)/arch/loongarch/include/asm/mach-loongson32
load-$(CONFIG_MACH_LOONGSON32)     += 0xa0300000
```

`load-…0xa0300000` becomes `VMLINUX_LOAD_ADDRESS` (`arch/loongarch/Makefile:88-96`; note
`CONFIG_PHYSICAL_START` is **not defined anywhere** in `arch/loongarch`, so the `Platform` value
wins):

```
# arch/loongarch/Makefile:88-97
ifdef CONFIG_PHYSICAL_START
load-y				= $(CONFIG_PHYSICAL_START)
endif
...
KBUILD_CPPFLAGS += -DVMLINUX_LOAD_ADDRESS=$(load-y)
```

and is consumed by the linker script: `arch/loongarch/kernel/vmlinux.lds.S:26` → `. = VMLINUX_LOAD_ADDRESS;`
with `ENTRY(kernel_entry)` (`vmlinux.lds.S:16`).

### 2.4 Which configuration is "chiplab"?

`README.md:29-33` answers this unambiguously:

| Platform | Default config | Config file |
|---|---|---|
| la32r-QEMU | `make la32_defconfig` | `arch/loongarch/configs/la32_defconfig` |
| **chiplab/loongson-soc** | **`make la32_defconfig`** | **`arch/loongarch/configs/la32_defconfig`** |
| 全流程平台参考 SOC (full-flow reference SoC) | `make la32_bx_defconfig` | `arch/loongarch/configs/la32_bx_defconfig` |

**chiplab shares `la32_defconfig` with QEMU.** That config selects `CONFIG_LS_SOC=y`
(`la32_defconfig:236`), i.e. the "Loongson SoC" variant, UART at **`0x1fe001e0`**.

Corroborating evidence that chiplab = LS_SOC:
* `arch/loongarch/loongson32/uart_base.c:27` — `CONFIG_LS_SOC` → `0x9fe001e0`.
* `chiplab/software/examples/linux/start.S:5` — `li.w t1, 0x1fe001e0`.
* U-Boot for the same board uses the same address:
  `la32r-uboot/configs/la32rsoc_defconfig:28` — `CONFIG_DEBUG_UART_BASE=0x9fe001e0`;
  `:37` — `CONFIG_TARGET_LA32R_LOONGSONSOC_DEMO=y`.

The two defconfigs differ exactly where you would expect:

```
arch/loongarch/configs/la32_defconfig        arch/loongarch/configs/la32_bx_defconfig
────────────────────────────────────────     ────────────────────────────────────────
:235 # CONFIG_BX_SOC is not set               :224 CONFIG_BX_SOC=y
:236 CONFIG_LS_SOC=y                          :225 # CONFIG_LS_SOC is not set
:262 CONFIG_32BIT=y                           :251 CONFIG_32BIT=y
:232 CONFIG_MACH_LOONGSON32=y                 :221 CONFIG_MACH_LOONGSON32=y
:234 CONFIG_MACH_LOONGSON_32=y                :223 CONFIG_MACH_LOONGSON_32=y
:252 CONFIG_CPU_LOONGSON32=y                  :241 CONFIG_CPU_LOONGSON32=y
:281 CONFIG_BUILTIN_DTB=y                     :270 CONFIG_BUILTIN_DTB=y
:282 CONFIG_BUILTIN_DTB_NAME="loongson32_ls"  :271 CONFIG_BUILTIN_DTB_NAME="loongson32_ls"   <-- BUG
:907 CONFIG_MTD_NAND_LS1A=y                   :661 CONFIG_MTD_NAND_LS1A=y
```

> ⚠ **Latent bug worth knowing:** `la32_bx_defconfig:271` sets
> `CONFIG_BUILTIN_DTB_NAME="loongson32_ls"` even though it selects `BX_SOC`. However
> `arch/loongarch/loongson32/setup.c:46-51` *ignores* `BUILTIN_DTB_NAME` and hardcodes the
> symbol per SoC (`__dtb_loongson32_ls_begin` vs `__dtb_loongson32_bx_begin`), so the string is
> cosmetic. Do not copy this pattern into the RISC-V port.

### 2.5 Defconfig and DTS paths for the chiplab board (the exact deliverables)

| Artifact | Exact path |
|---|---|
| **Kernel defconfig (chiplab)** | `arch/loongarch/configs/la32_defconfig` |
| **Device tree source (chiplab)** | `arch/loongarch/boot/dts/loongson/loongson32_ls.dts` |
| Compiled DTB | `arch/loongarch/boot/dts/loongson/loongson32_ls.dtb` |
| DTS build rule | `arch/loongarch/boot/dts/loongson/Makefile:2` — `dtb-$(CONFIG_LS_SOC) += loongson32_ls.dtb` |
| Alternate (BX / full-flow SoC) | `arch/loongarch/boot/dts/loongson/loongson32_bx.dts`, `arch/loongarch/configs/la32_bx_defconfig` |

`la32_defconfig` is a full 32-bit defconfig (`CONFIG_32BIT=y`, `CONFIG_HZ_250=y`,
`CONFIG_BUILTIN_DTB=y`, `CONFIG_SERIAL_OF_PLATFORM=y`, `CONFIG_MTD_NAND_LS1A=y`,
`CONFIG_LS1X_IRQ=y`, `CONFIG_EARLY_PRINTK=y`).

---

## 3. Does the tree already have RISC-V support? — **YES, and it already supports RV32**

This is the single most important structural finding for your project.

### 3.1 Provenance and state

`arch/riscv/` is **essentially upstream Linux 5.14-rc2** — the file set matches upstream exactly:

```
arch/riscv/
├── Kbuild  Kconfig  Kconfig.debug  Kconfig.erratas  Kconfig.socs  Makefile
├── boot/{Makefile, install.sh, loader.S, loader.lds.S, dts/}
├── configs/{defconfig, nommu_k210_defconfig, nommu_k210_sdcard_defconfig,
│            nommu_virt_defconfig, rv32_defconfig}
├── errata/, include/, kernel/, lib/, mm/, net/
```

There is **no chiplab/loongson SoC in `arch/riscv` and no chiplab driver** — it is
vendor-neutral upstream code. Nothing in the fork appears to have modified it for LA32R.

### 3.2 RV32 is supported (`CONFIG_32BIT` / `CONFIG_ARCH_RV32I`)

`arch/riscv/Kconfig:7-11` defines both width symbols, and the base-ISA choice is at
`arch/riscv/Kconfig:218-244`:

```kconfig
config 64BIT
	bool

config 32BIT
	bool
...
choice
	prompt "Base ISA"
	default ARCH_RV64I
...
config ARCH_RV32I
	bool "RV32I"
	select 32BIT
	select GENERIC_LIB_ASHLDI3
	select GENERIC_LIB_ASHRDI3
	select GENERIC_LIB_LSHRDI3
	select GENERIC_LIB_UCMPDI2
	select MMU

config ARCH_RV64I
	bool "RV64I"
	select 64BIT
	...
endchoice
```

Note **`ARCH_RV32I` selects `MMU` unconditionally** — RV32 here means **Sv32 paged MMU**, which
is exactly what you want (no MMU-less RV32 path is offered by this choice).

Width-dependent knobs (`arch/riscv/Kconfig:113-167, 251-277`):

```
select ZONE_DMA32 if 64BIT
default 32 if 32BIT            # VA_BITS
default 34 if 32BIT            # PA_BITS
default 0xC0000000 if 32BIT && MAXPHYSMEM_1GB
default CMODEL_MEDLOW if 32BIT
select SPARSEMEM_STATIC if 32BIT && SPARSEMEM
```

`arch/riscv/Makefile:23-40` wires the toolchain for RV32:

```make
export BITS
ifeq ($(CONFIG_ARCH_RV64I),y)
	BITS := 64
	UTS_MACHINE := riscv64
	KBUILD_CFLAGS += -mabi=lp64
	KBUILD_AFLAGS += -mabi=lp64
	KBUILD_LDFLAGS += -melf64lriscv
else
	BITS := 32
	UTS_MACHINE := riscv32
	KBUILD_CFLAGS += -mabi=ilp32
	KBUILD_AFLAGS += -mabi=ilp32
	KBUILD_LDFLAGS += -melf32lriscv
endif
```

`arch/riscv/boot/Makefile` builds `Image` (objcopy `-O binary`) plus `Image.gz`, `xipImage`
and a `loader`/`loader.bin` pair.

### 3.3 A ready-made RV32 defconfig exists

`arch/riscv/configs/rv32_defconfig` (134 lines) is a **working RV32 reference config**:

```
CONFIG_BLK_DEV_INITRD=y
CONFIG_SOC_SIFIVE=y
CONFIG_SOC_VIRT=y
CONFIG_ARCH_RV32I=y
CONFIG_SMP=y
CONFIG_HOTPLUG_CPU=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_OF_PLATFORM=y
CONFIG_SERIAL_EARLYCON_RISCV_SBI=y
CONFIG_PCI=y
CONFIG_PCI_HOST_GENERIC=y
CONFIG_POWER_RESET=y
CONFIG_TMPFS=y
CONFIG_EXT4_FS=y
CONFIG_ROOT_NFS=y
CONFIG_9P_FS=y
```

**Use this as the seed for `arch/riscv/configs/rv32_chiplab_defconfig`.**

### 3.4 SoCs supported by `arch/riscv` (none is chiplab)

`arch/riscv/Kconfig.socs`:

| Symbol | SoC | Key selects |
|---|---|---|
| `SOC_MICROCHIP_POLARFIRE` | Microchip PolarFire | `MCHP_CLK_MPFS`, `SIFIVE_PLIC` |
| `SOC_SIFIVE` | SiFive (HiFive Unleashed etc.) | `SERIAL_SIFIVE`, `CLK_SIFIVE`, `SIFIVE_PLIC`, `RISCV_ERRATA_ALTERNATIVE` |
| `SOC_VIRT` | QEMU `virt` machine | `CLINT_TIMER if RISCV_M_MODE`, `POWER_RESET_SYSCON`, `GOLDFISH`, `SIFIVE_PLIC` |
| `SOC_CANAAN` | Canaan Kendryte K210 (`depends on !MMU`) | `CLINT_TIMER`, `SERIAL_SIFIVE`, `SIFIVE_PLIC`, `BUILTIN_DTB` |

→ You must **add a new `SOC_CHIPLAB` (or similar) Kconfig entry + `mach`-style platform file**.
`SOC_CANAAN` is the closest template for the *builtin-DTB* half of the job; `SOC_VIRT` is the
closest template for the *interrupt/timer/reset* half.

### 3.5 MMU / head.S / MMU init

* `arch/riscv/mm/` is complete: `init.c, fault.c, tlbflush.c, cacheflush.c, context.c,
  extable.c, hugetlbpage.c, kasan_init.c, pageattr.c, physaddr.c, ptdump.c`.
* `arch/riscv/include/asm/pgtable-32.h` exists (Sv32), alongside `pgtable-64.h`; the width is
  chosen in `pgtable.h`.
* `arch/riscv/kernel/head.S` is width-agnostic where it counts: it sets up page tables and writes
  `csrw CSR_SATP, a0` with `li a1, SATP_MODE` (`head.S:98-112, 131`), where `SATP_MODE` resolves
  to `SATP_MODE_32`/`SATP_MODE_39` from `asm/csr.h`. The only explicit xlen branch is the image
  header load offset (`head.S:54-72`):

```asm
#ifdef CONFIG_RISCV_M_MODE
	/* Image load offset (0MB) from start of RAM for M-mode */
	.dword 0
#else
#if __riscv_xlen == 64
	/* Image load offset(2MB) from start of RAM */
	.dword 0x200000
#else
	/* Image load offset(4MB) from start of RAM */
	.dword 0x400000
#endif
#endif
```

  ⚠ For RV32 the image header advertises a **4 MiB** load offset from start of RAM.
* `arch/riscv/kernel/` contains the full S-mode/SBI infrastructure (`entry.S, traps.c, sbi.c,
  cpu_ops*.c, smp.c, time.c, irq.c, reset.c, soc.c, vdso/`), so the privileged port is present.
* **FPU/F/D:** `arch/riscv/Kconfig:374-379` —

```kconfig
config FPU
	bool "FPU support"
	default y
```

  There is **no `depends on 64BIT`**, so `CONFIG_FPU` (F/D save-restore, `kernel/fpu.S`) is
  available on RV32 in this tree. Whether the *context switch* code is fully RV32-correct for
  `f`/`d` registers is something to verify on silicon (see §13).
* `arch/riscv/Kconfig:544-547` — `config BUILTIN_DTB` exists (`bool`, `depends on OF`,
  `default y if XIP_KERNEL`), so the builtin-DTB trick used by `arch/loongarch` is available to
  your new SoC via `select BUILTIN_DTB`.

**Bottom line for §3:** the tree already contains a buildable RV32 (Sv32) RISC-V kernel. Your work
is to add a chiplab SoC, a chiplab DTS, and the platform drivers — *not* to create RV32 support.

---

## 4. The NAND / flash driver — location and identification

### 4.1 Search results

```
$ ls drivers/mtd/nand/
Kconfig  Makefile  bbt.c  core.c  ecc-sw-bch.c  ecc-sw-hamming.c  ecc.c
onenand/  raw/  spi/

$ ls drivers/mtd/nand/raw/ | wc -l
68          # stock 5.14-rc2 raw-NAND drivers, incl. nand_base.c, nand_bbt.c, nand_ids.c ...

$ grep -rln "loongson\|chiplab\|LA32\|la32" drivers/mtd/
drivers/mtd/nand/raw/ls1a_nand.c          <-- THE driver. Only hit.
```

The driver is wired in as:

```
drivers/mtd/nand/raw/Makefile:5:  obj-$(CONFIG_MTD_NAND_LS1A)  += ls1a_nand.o
drivers/mtd/nand/raw/Kconfig:49-52:
    config MTD_NAND_LS1A
         tristate "Support for NAND on LS1A SOC"
         help
           This enables the NAND flash controller on the LS1A SoC.
```

Enabled in both board configs: `arch/loongarch/configs/la32_defconfig:907` and
`arch/loongarch/configs/la32_bx_defconfig:661` → `CONFIG_MTD_NAND_LS1A=y`.

MTD/raw-NAND infrastructure selected by `la32_defconfig`:

```
:826 CONFIG_MTD=y
:833 CONFIG_MTD_CMDLINE_PARTS=y
:834 CONFIG_MTD_OF_PARTS=y
:851 CONFIG_MTD_PARTITIONED_MASTER=y
:899 CONFIG_MTD_NAND_CORE=y
:901 CONFIG_MTD_RAW_NAND=y
:907 CONFIG_MTD_NAND_LS1A=y
:924 CONFIG_MTD_NAND_ECC=y
:926 CONFIG_MTD_NAND_ECC_SW_BCH=y
```

> Note: `CONFIG_MTD_CMDLINE_PARTS=y` is set, **but `CONFIG_MTD_PARTITIONS` does not exist in
> Linux 5.14** (`grep -rn "config MTD_PARTITIONS" drivers/mtd/` → no match). This matters — see §4.6.

### 4.2 Driver identity and magic constants

`drivers/mtd/nand/raw/ls1a_nand.c`, lines 1–92 (abridged, comments preserved):

```c
14: //#define CONFIG_MACH_LS1A 0
15: //#define CONFIG_MACH_LS1B 0
16: #define CONFIG_MACH_LS232 1            /* <-- hardcoded variant select */

18: #define DMA_ACCESS_ADDR     0x1fe78040 /* DMA data port (physical)          */
19: #define ORDER_REG_ADDR      ((0x9fd01160)) /* DMA doorbell (uncached alias) */
20: #define MAX_BUFF_SIZE	4096
21: #define PAGE_SHIFT      12

41: #ifdef CONFIG_MACH_LS232
42: #define USE_POLL                        /* <-- IRQ + completions compiled OUT */
43: #endif
44: #ifdef USE_POLL
45: #define complete(...)
46: #define wait_for_completion_timeout(...)
47: #define init_completion(...)
48: #define request_irq(...) (0)
49: #define free_irq(...)
50: #endif

52: #define CHIP_DELAY_TIMEOUT (2*HZ/10)
54: #define STATUS_TIME_LOOP_R  60
55: #define STATUS_TIME_LOOP_WS  400
56: #define STATUS_TIME_LOOP_WM  60
57: #define STATUS_TIME_LOOP_E  100

/* nand_setup()/dma_setup() field-select FLAGS (not register offsets!) */
59: #define NAND_CMD        0x1
60: #define NAND_ADDRL      0x2
61: #define NAND_ADDRH      0x4
62: #define NAND_TIMING     0x8
63: #define NAND_IDL        0x10
64: #define NAND_STATUS_IDL 0x20
65: #define NAND_PARAM      0x40
66: #define NAND_OP_NUM     0X80
67: #define NAND_CS_RDY_MAP 0x100

69: #define DMA_ORDERAD     0x1
70: #define DMA_SADDR       0x2
71: #define DMA_DADDR       0x4
72: #define DMA_LENGTH      0x8
73: #define DMA_STEP_LENGTH 0x10
74: #define DMA_STEP_TIMES  0x20
75: #define DMA_CMD         0x40

78: #define NAND_ECC_OFF	0
79: #define NAND_ECC_ON	1
80: #define RAM_OP_OFF	0
81: #define RAM_OP_ON	1

84: #define  _NAND_IDL      ( *((volatile unsigned int*)(0x9fe78010)))
85: #define  _NAND_IDH       (*((volatile unsigned int*)(0x9fe78014)))
86: #define  _NAND_BASE      0x9fe78000
87: #define  _NAND_SET_REG(x,y)   do{*((volatile unsigned int*)(_NAND_BASE+x)) = (y);}while(0)
88: #define  _NAND_READ_REG(x,y)  do{(y) =  *((volatile unsigned int*)(_NAND_BASE+x));}while(0)

90: #define _NAND_TIMING_TO_READ    _NAND_SET_REG(0xc,0x205)
91: #define _NAND_TIMING_TO_WRITE   _NAND_SET_REG(0xc,0x205)
```

**Three facts to internalize immediately:**

1. **`CONFIG_MACH_LS232` is hardcoded to 1 at line 16**, which switches on `USE_POLL`, which
   `#define`s `complete()`, `wait_for_completion_timeout()`, `init_completion()`,
   `request_irq()` and `free_irq()` **to nothing**. The driver is therefore **fully synchronous
   polling**, not interrupt-driven, despite the IRQ plumbing further down.
   (Note `devm_request_irq()` at line 1028 is *not* caught by the `request_irq` macro, so an IRQ
   is still requested — see §4.7.)
2. Register access is **split**: the memory-mapped `ls1a_nand_desc` struct is reached through
   `info->mmio_base` (an `ioremap()` of the DT resource), while `_NAND_IDL`, `_NAND_IDH`,
   `_NAND_SET_REG`, `ls1a_nand_status()` and `write_z_cmd` **hardcode the un-cached Loongson
   `0x9fe78000` window**. Both must become one `ioremap()`-derived pointer on RISC-V.
3. `0x9fe78000` is `0x80000000 | 0x1fe78000` — the physical base with the Loongson KSEG0
   (cached direct-map) window OR'd in. `0x1fe78040 = 0x1fe78000 + 0x40` is therefore the
   controller's **DMA data port**, and `0x9fd01160` is the external DMA engine's doorbell.

### 4.3 Controller registers it touches

The register *offsets* come from `struct ls1a_nand_desc` (lines 175–185), whose field order is
the hardware layout — confirmed by the hardcoded `_NAND_*` macros:

```c
175: struct ls1a_nand_desc{
176:         uint32_t    cmd;          /* +0x00 */
177:         uint32_t    addrl;        /* +0x04 */
178:         uint32_t    addrh;        /* +0x08 */
179:         uint32_t    timing;       /* +0x0c */
180:         uint32_t    idl;          /* +0x10  readonly */
181:         uint32_t    status_idh;   /* +0x14  readonly */
182:         uint32_t    param;        /* +0x18 */
183:         uint32_t    op_num;       /* +0x1c */
184:         uint32_t    cs_rdy_map;   /* +0x20 */
185: };
```

| Offset | Name | R/W | Notes |
|---|---|---|---|
| `0x00` | `CMD` | RW + RO status bits | see bitfield in §11.1; bit 10 = DONE (polled) |
| `0x04` | `ADDRL` | RW | column / low address; `+ writesize` selects the spare area |
| `0x08` | `ADDRH` | RW | page / high address |
| `0x0c` | `TIMING` | RW | `0x205` read/write, `0x412` default (`info->nand_timing`) |
| `0x10` | `IDL` | RO | NAND ID low word (`_NAND_IDL`) |
| `0x14` | `IDH` | RO | NAND ID high word (`_NAND_IDH`); also status source (`>>16`) |
| `0x18` | `PARAM` | RW | written raw as `0x08005300`; `op_num` folded into bits `[21:16]` |
| `0x1c` | `OP_NUM` | RW | transfer byte count |
| `0x20` | `CS_RDY_MAP` | RW | `0x88442200` |
| `0x40` | *(DMA data port)* | RW | `DMA_ACCESS_ADDR = 0x1fe78040` — DMA target |

`0x9fe78018` (i.e. `PARAM`) is written directly twice:

```c
910:    *((volatile unsigned int *)0x9fe78018) = 0x08005300;   /* ls1a_nand_init_info() */
...
1123:    *((volatile unsigned int *)0x9fe78018) = 0x400;        /* ls1a_nand_resume() */
```

**Address map of the whole NAND subsystem (chiplab/LS view):**

| Address | Meaning | Source |
|---|---|---|
| `0x1fe78000` | NAND controller base (physical) | DT `reg`, `_NAND_BASE & 0x7fffffff` |
| `0x9fe78000` | same, KSEG0 uncached/cached alias used by the code | `ls1a_nand.c:86` |
| `0x1fe78040` | controller DMA data port (physical) | `ls1a_nand.c:18` |
| `0x9fd01160` | external DMA engine "order" doorbell (virtual alias) | `ls1a_nand.c:19` |
| `0x1fd01160` | same, physical — appears as DT resource #1 | `loongson32_ls.dts:84` |
| `0xa0000000 \| phys` | descriptor buffer uncached alias | `ls1a_nand.c:988` |

### 4.4 How it moves data — DMA, not PIO

There is **no CPU PIO path to the flash**. All transfers go through an **external
descriptor-based DMA engine** whose doorbell is `0x9fd01160`, and whose destination/source is the
controller's data port at `0x1fe78040`.

DMA descriptor layout (`struct ls1a_nand_dma_desc`, lines 155–163), allocated with
`dma_alloc_coherent()` and placed at the *start* of a 4096-byte coherent buffer:

```c
155: struct ls1a_nand_dma_desc{
156:         uint32_t    orderad;      /* +0x00 */
157:         uint32_t    saddr;        /* +0x04 */
158:         uint32_t    daddr;        /* +0x08 */
159:         uint32_t    length;       /* +0x0c */
160:         uint32_t    step_length;  /* +0x10 */
161:         uint32_t    step_times;   /* +0x14 */
162:         uint32_t    cmd;          /* +0x18 */
163: };
```

DMA command word layout (`struct ls1a_nand_dma_cmd`, lines 164–174):

```c
164: struct ls1a_nand_dma_cmd{
165:         uint32_t    dma_int_mask:1;    /* bit 0  */
166:         uint32_t    dma_int:1;         /* bit 1  */
167:         uint32_t    dma_sl_tran_over:1;/* bit 2  */
168:         uint32_t    dma_tran_over:1;   /* bit 3  */
169:         uint32_t    dma_r_state:4;     /* bits 4-7  */
170:         uint32_t    dma_w_state:4;     /* bits 8-11 */
171:         uint32_t    dma_r_w:1;         /* bit 12 : 1 = memory -> NAND */
172:         uint32_t    dma_cmd:2;         /* bits 13-14 */
173:         uint32_t    revl:17;           /* bits 15-31 */
174: };
```

The kick-off routine, `dma_setup()` (lines 550–579) — this is the heart of every transfer:

```c
550: static void dma_setup(unsigned int flags,struct ls1a_nand_info *info)
551: {
552:     struct ls1a_nand_dma_desc *dma_base = (volatile struct ls1a_nand_dma_desc *)(info->drcmr_dat);
553: int status_time;
554:     dma_base->orderad = (flags & DMA_ORDERAD)== DMA_ORDERAD ? info->dma_regs.orderad : info->dma_orderad;
555:     dma_base->saddr = (flags & DMA_SADDR)== DMA_SADDR ? info->dma_regs.saddr : info->dma_saddr;
556:     dma_base->daddr = (flags & DMA_DADDR)== DMA_DADDR ? info->dma_regs.daddr : info->dma_daddr;
557:     dma_base->length = (flags & DMA_LENGTH)== DMA_LENGTH ? info->dma_regs.length: info->dma_length;
558:     dma_base->step_length = (flags & DMA_STEP_LENGTH)== DMA_STEP_LENGTH ? info->dma_regs.step_length: info->dma_step_length;
559:     dma_base->step_times = (flags & DMA_STEP_TIMES)== DMA_STEP_TIMES ? info->dma_regs.step_times: info->dma_step_times;
560:     dma_base->cmd = (flags & DMA_CMD)== DMA_CMD ? info->dma_regs.cmd: info->dma_cmd;
561:
562:     if((dma_base->cmd)&(0x1 << 12)){                       /* dma_r_w: memory->device */
563:         dma_cache_wback((unsigned long)(info->data_buff),info->cac_size);
564:     }
565:     dma_cache_wback((unsigned long)(info->drcmr_dat),0x20); /* flush descriptor (32 B) */
566:
567:     {
568:     long flags;
569:     local_irq_save(flags);
570:     *(volatile unsigned int *)info->order_reg_addr = ((unsigned int )info->drcmr_dat_phys) | 0x1<<3;
571:     while (*(volatile unsigned int *)info->order_reg_addr & 0x8 );
572:
573: #ifdef USE_POLL
574:     while(!(ls1a_nand_status(info)));
575:     info->state = STATE_READY;
576: #endif
577:     local_irq_restore(flags);
578:     }
579: }
```

Reading the doorbell protocol:
* **Line 570** writes the **physical address of the descriptor with bit 3 set** to `0x9fd01160`
  — that is the "start DMA" command.
* **Line 571** polls **bit 3** of the same register until it clears — the DMA engine's
  "accepted/busy" handshake.
* **Line 574** (the compiled path, because `USE_POLL` is on) then spins on the *controller's*
  DONE bit (`CMD[10]`) until the NAND operation itself completes.
* **Line 563** flushes the CPU cache for the data buffer only when `dma_r_w` (bit 12) is set,
  i.e. only for the memory→NAND (program) direction. Reads instead invalidate after the fact,
  in `cmdfunc()`: `dma_cache_inv(...)` at lines 881–882.

Cache maintenance uses the Loongson-specific primitives `dma_cache_wback()`,
`dma_cache_wback_inv()` and `dma_cache_inv()` (from `<asm/dma.h>`/`dma-noncoherent.c`), driven
by `info->cac_size` (set to the transfer byte count, e.g. `oobsize + writesize`).

`ls1a_nand_init_info()` (lines 906–946) establishes the DMA defaults:

```c
910:    *((volatile unsigned int *)0x9fe78018) = 0x08005300;
...
919:    info->nand_addrl = 0x0;
920:    info->nand_addrh = 0x0;
921:    info->nand_timing =0x412;// 0x4<<8 | 0x12;
923:    info->nand_op_num = 0x0;
925:    info->nand_cs_rdy_map = 0x88442200;
926:    info->nand_cmd = 0;
927:
928:    info->dma_orderad = 0x0;
929:    info->dma_saddr = info->data_buff_phys;
930:    info->dma_daddr = DMA_ACCESS_ADDR;      /* 0x1fe78040 */
931:    info->dma_length = 0x0;
932:    info->dma_step_length = 0x0;
933:    info->dma_step_times = 0x1;
934:    info->dma_cmd = 0x0;
...
945:    info->order_reg_addr = ORDER_REG_ADDR;  /* 0x9fd01160 */
```

so every transfer is `data_buff_phys -> 0x1fe78040` (a *single* DMA step of `step_times = 1`).

The 32-byte descriptor buffer is allocated and then **aliased into the uncached window** at
probe time (lines 986–990):

```c
986:        info->drcmr_dat =(unsigned int ) dma_alloc_coherent(&pdev->dev, MAX_BUFF_SIZE,
987: 				&info->drcmr_dat_phys, GFP_KERNEL);
988:        info->drcmr_dat = 0xa0000000 | (info->drcmr_dat);
989:        info->dma_ask =(unsigned int ) dma_alloc_coherent(&pdev->dev, MAX_BUFF_SIZE,
990: 				&info->dma_ask_phy, GFP_KERNEL);
```

> ⚠ **Line 988 is the single most dangerous line in the file for a port.** `0xa0000000 |` is a
> Loongson KSEG1 (uncached) direct-map alias. On RISC-V there is no such window; the whole
> `drcmr_dat`/`order_reg_addr`/`dma_ask` scheme must be re-expressed with real physical
> addresses plus explicit cache maintenance, or with a non-cacheable mapping.

### 4.5 Read / program / erase paths

`ls1a_nand_cmdfunc()` (lines 618–885) is the legacy `->legacy.cmdfunc` hook and implements
everything. Entry point binding (`ls1a_nand_init_mtd`, lines 425–454):

```c
430: 	this->options = NAND_CACHEPRG;
432: 	this->legacy.waitfunc		= ls1a_nand_waitfunc;
433: 	this->legacy.select_chip	= ls1a_nand_select_chip;
434: 	this->legacy.dev_ready		= ls1a_nand_dev_ready;
435: 	this->legacy.cmdfunc		= ls1a_nand_cmdfunc;
437: 	this->legacy.read_byte		= ls1a_nand_read_byte;
438: 	this->legacy.read_buf		= ls1a_nand_read_buf;
439: 	this->legacy.write_buf		= ls1a_nand_write_buf;
```

Note the **buffer-shim model**: `cmdfunc()` triggers a DMA into `info->data_buff` and resets
`info->buf_start`; the `read_buf`/`write_buf`/`read_byte` callbacks then simply `memcpy`
to/from that RAM buffer (lines 331–408). There is no FIFO access from the CPU.

#### READ0 — read a main page plus its spare area (lines 670–703)

```c
670:            case NAND_CMD_READ0:
671:                if(info->state == STATE_BUSY){ printk("nandflash chip if busy...\n"); return; }
675:                info->state = STATE_BUSY;
676:                info->buf_count = mtd->oobsize + mtd->writesize ;   /* 64 + 2048 = 2112 */
677:                info->buf_start =  0 ;
678:                info->cac_size = info->buf_count;
681: 				dma_cache_wback_inv((unsigned long)(info->data_buff),info->cac_size);
682:                info->nand_regs.addrh = SPARE_ADDRH(page_addr);     /* == page_addr */
683:                info->nand_regs.addrl = SPARE_ADDRL(page_addr);     /* == 0 */
684:                info->nand_regs.op_num = info->buf_count;
686:                info->nand_regs.cmd = 0;
687:                info->dma_regs.cmd = 0;
689: 				((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->int_en = 1;
690:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->ram_op = RAM_OP_OFF;
691:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->ecc_rd = NAND_ECC_OFF;
692:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->ecc_wr = NAND_ECC_OFF;
694:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->read = 1;
695:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->op_spare = 1;
696:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->op_main = 1;
697:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->cmd_valid = 1;
699:                info->dma_regs.length = ALIGN_DMA(info->buf_count);  /* /4 -> 528 words */
700:                ((struct ls1a_nand_dma_cmd *)&(info->dma_regs.cmd))->dma_int_mask = 1;
701:                nand_setup(NAND_ADDRL|NAND_ADDRH|NAND_OP_NUM|NAND_CMD,info);
702:                dma_setup(DMA_LENGTH|DMA_CMD,info);
703:                break;
```

`NAND_CMD_READOOB` (lines 634–669) is the same but `buf_count = mtd->oobsize` and
`addrl = SPARE_ADDRL(page_addr) + mtd->writesize` — i.e. it starts the controller's internal
address at the spare area (`0x800` into a 2112-byte page) and reads only 64 bytes.

#### SEQIN + PAGEPROG — program a page (lines 704–755)

`NAND_CMD_SEQIN` only latches state — it does **not** touch hardware:

```c
704:            case NAND_CMD_SEQIN:
709:                info->state = STATE_BUSY;
710:                info->buf_count = mtd->oobsize + mtd->writesize - column;
711:                info->buf_start = 0;
712:                info->seqin_column = column;
713:                info->seqin_page_addr = page_addr;
714:                complete(&info->cmd_complete);       /* no-op under USE_POLL */
715:                break;
```

The subsequent `write_buf()` calls fill `data_buff`, and `NAND_CMD_PAGEPROG` fires the DMA:

```c
716:            case NAND_CMD_PAGEPROG:
723:                if(cmd_prev != NAND_CMD_SEQIN){ printk("Prev cmd don't complete...\n"); break; }
727:                if(info->buf_count <= 0 ) break;
729: 				info->cac_size = info->buf_count;
731:                info->nand_regs.addrh =  SPARE_ADDRH(info->seqin_page_addr);
732:                info->nand_regs.addrl =  SPARE_ADDRL(info->seqin_page_addr) + info->seqin_column;
733:                info->nand_regs.op_num = info->buf_start;      /* bytes actually staged */
735:                info->nand_regs.cmd = 0;
736:                info->dma_regs.cmd = 0;
739: 				((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->int_en = 1;
740:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->ram_op = RAM_OP_OFF;
741:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->ecc_rd = NAND_ECC_OFF;
742:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->ecc_wr = NAND_ECC_OFF;
744:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->write = 1;
745:                if(info->seqin_column < mtd->writesize)
746:                    ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->op_main = 1;
747:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->op_spare = 1;
748:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->cmd_valid = 1;
750:                info->dma_regs.length = ALIGN_DMA(info->buf_start);
751:                ((struct ls1a_nand_dma_cmd *)&(info->dma_regs.cmd))->dma_int_mask = 1;
752:                ((struct ls1a_nand_dma_cmd *)&(info->dma_regs.cmd))->dma_r_w = 1;  /* mem->NAND */
753:                nand_setup(NAND_ADDRL|NAND_ADDRH|NAND_OP_NUM|NAND_CMD,info);
754:                dma_setup(DMA_LENGTH|DMA_CMD,info);
755:                break;
```

#### ERASE1 — block erase (lines 780–811)

```c
780:            case NAND_CMD_ERASE1:
785:                info->state = STATE_BUSY;
788:                info->nand_regs.addrh =  NO_SPARE_ADDRH(page_addr);   /* == page_addr */
789:                info->nand_regs.addrl =  NO_SPARE_ADDRL(page_addr) ;  /* == 0 */
791:                info->nand_regs.cmd = 0;
794: 				((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->int_en = 0;
795:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->ram_op = RAM_OP_OFF;
797:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->erase_one = 1;
798:                ((struct ls1a_nand_cmdset*)&(info->nand_regs.cmd))->cmd_valid = 1;
799:                nand_setup(NAND_ADDRL|NAND_ADDRH|NAND_OP_NUM|NAND_CMD,info);
800:                status_time = STATUS_TIME_LOOP_E;
801:                udelay(2000);
802:                while(!ls1a_nand_status(info)){
803:                    if(!(status_time--)){ write_z_cmd; break; }
807:                    udelay(50);
808:                }
809:                complete(&info->cmd_complete);
810:                info->state = STATE_READY;
811:                break;
```

Erase is **pure register-programming with no DMA** — no data buffer is involved. `ERASE2` is a
no-op (lines 866–869).

#### Other commands

* `NAND_CMD_RESET` (756–779): sets `reset = 1`, `int_en = 0`, then polls DONE.
* `NAND_CMD_STATUS` (812–823): **`*(unsigned char *)info->data_buff = ls1a_nand_status(info) | 0x80;`**
* `NAND_CMD_READID` (824–865): writes `0x21` to `CMD` (`_NAND_SET_REG(0x0,0x21)`), `udelay(1)`,
  then reassembles the 5 ID bytes from `IDL`/`IDH`:

```c
851: 		   _NAND_SET_REG(0x0,0x21);
852:                    udelay(1);
853:                    id_val_l = _NAND_IDL;
854:                    id_val_h = _NAND_IDH;
856:                    data[0]  = (id_val_h & 0xff);
857:                    data[1]  = (id_val_l & 0xff000000)>>24;
858:                    data[2]  = (id_val_l & 0x00ff0000)>>16;
859:                    data[3]  = (id_val_l & 0x0000ff00)>>8;
860: 		   data[4]  = (id_val_l & 0x000000ff);
```

* `NAND_CMD_RNDOUT` (870–873): `info->buf_start = column;` (buffer pointer only).
* Anything else (874–877): `printk(KERN_ERR "non-supported command.\n")`.

The status-poll helper and the recovery sequence (lines 493–501):

```c
493: static unsigned ls1a_nand_status(struct ls1a_nand_info *info)
494: {
495:     return(*((volatile unsigned int*)0x9fe78000) & (0x1<<10));
496: }
497: #define write_z_cmd  do{                                    \
498:             *((volatile unsigned int *)(0x9fe78000)) = 0;   \
499:             *((volatile unsigned int *)(0x9fe78000)) = 0;   \
500:             *((volatile unsigned int *)(0x9fe78000)) = 400; \
501:     }while(0)
```

`CMD[10]` (`done`) is the completion flag; `write_z_cmd` is a "poke 0, 0, 400" recovery when a
timeout expires.

### 4.6 ECC scheme — **hardware ECC exists but is switched OFF**

This is the most consequential functional finding for your U-Boot port.

* `ls1a_nand_init_mtd()` disables ECC outright (lines 442–452):

```c
442: #if 0
443:         this->ecc.mode		= NAND_ECC_NONE;
444: #else
445:     //this->ecc.algo      = NAND_ECC_ALGO_BCH;
446: 	this->ecc.engine_type		=   NAND_ECC_ENGINE_TYPE_NONE; //NAND_ECC_ENGINE_TYPE_SOFT;
447: #endif
448: 	this->ecc.hwctl		= ls1a_nand_ecc_hwctl;
449: 	this->ecc.calculate	= ls1a_nand_ecc_calculate;
450: 	this->ecc.correct	= ls1a_nand_ecc_correct;
451:
452: //	this->ecc.layout = &hw_largepage_ecclayout;
```

* All three ECC callbacks are **stubs that return success and do nothing** (lines 285–307):

```c
285: static int ls1a_nand_ecc_calculate(struct nand_chip *chip,
286: 		const uint8_t *dat, uint8_t *ecc_code)
287: {
288: 	return 0;
289: }
290: static int ls1a_nand_ecc_correct(struct nand_chip *chip,
291: 		uint8_t *dat, uint8_t *read_ecc, uint8_t *calc_ecc)
292: {
...
301: 	return 0;
302: }
304: static void ls1a_nand_ecc_hwctl(struct nand_chip *chip, int mode)
305: {
306: 	return;
307: }
```

* Every command explicitly clears the controller ECC bits:
  `ecc_rd = NAND_ECC_OFF` / `ecc_wr = NAND_ECC_OFF` at lines **657–658, 691–692, 741–742**.
* A hardware ECC layout *is* declared but never installed (lines 241–248):

```c
241: static struct nand_ecclayout_user hw_largepage_ecclayout = {
242: 	.eccbytes = 24,
243: 	.eccpos = {
244: 		40, 41, 42, 43, 44, 45, 46, 47,
245: 		48, 49, 50, 51, 52, 53, 54, 55,
246: 		56, 57, 58, 59, 60, 61, 62, 63},
247: 	.oobfree = { {2, 38} }
248: };
```

  Reading this as a specification of the *hardware* scheme: **24 ECC bytes per 2 KiB page, stored
  in spare bytes 40–63, with bytes 2–39 free for the BBT/user**, and bytes 0–1 presumably holding
  the bad-block marker. The controller's `CMD[11]` (`ecc_rd`), `CMD[12]` (`ecc_wr`) and
  `CMD[24]` (`ecc_dma_req`) bits are the enable/handshake for this engine.
* `CONFIG_MTD_NAND_ECC_SW_BCH=y` is enabled in the defconfig, but the driver never requests the
  software engine (`NAND_ECC_ENGINE_TYPE_SOFT` is commented out), so **software BCH is not used
  either**.

**Net effect: this driver reads and writes NAND with no error correction whatsoever**, relying on
`nand_scan_with_ids()` + the on-flash BBT. Under this scheme, bit errors are silently returned as
data. For a production U-Boot/kernel port you should re-enable the controller ECC (`ecc_rd/ecc_wr
= NAND_ECC_ON`, `NAND_ECC_ENGINE_TYPE_NONE` → keep in-hardware, plus restore the ecclayout), and
verify the 24-byte/40–63 layout against the actual LS1A datasheet — the values above are the only
in-tree evidence of it.

### 4.7 Probing, chip requirements, IRQ

Chip-size gate (`ls1a_nand_detect()`, lines 886–890) — **the driver only accepts one geometry**:

```c
886: static int ls1a_nand_detect(struct mtd_info *mtd)
887: {
888:         return (mtd->erasesize != 1<<17 || mtd->writesize != 1<<11 || mtd->oobsize != 1<<6);
889: }
```

→ required geometry: **erase block 128 KiB (`1<<17`), page 2048 B (`1<<11`), OOB 64 B (`1<<6`)** —
a classic 2 KiB-page large-block SLC NAND. Any other chip is rejected at
`ls1a_nand_probe()` lines 1043–1047 ("driver don't support the Flash!").

Binding and resources (lines 997–1038):

```c
997:        r = platform_get_resource(pdev, IORESOURCE_MEM, 0);   /* only resource #0 used */
1004: 	r = request_mem_region(r->start, r->end - r->start + 1, pdev->name);
1011: 	info->mmio_base = ioremap(r->start, r->end - r->start + 1);
1017:        ret = ls1a_nand_init_buff(info);
1021:        irq = platform_get_irq(pdev, 0);
1028:        ret = devm_request_irq(&pdev->dev,irq,ls1a_nand_irq,UMH_DISABLED,pdev->name,info);
1034:    ls1a_nand_init_mtd(mtd, info);
1036:    ls1a_nand_init_info(info);
1037:    platform_set_drvdata(pdev, mtd);
1038:    if (nand_scan_with_ids(this, 1 ,NULL)) {          /* maxchips=1, autodetect via READID */
```

Two anomalies: the IRQ flags argument is **`UMH_DISABLED`** (a UMH flag, not an `IRQF_*` value),
and `nand_scan_with_ids(this, 1, NULL)` passes a NULL ID table so the chip is autodetected from
READID. The handler `ls1a_nand_irq()` (lines 503–540) is effectively dead code under `USE_POLL`.

DT match table and driver registration (lines 1129–1153):

```c
1130: static const struct of_device_id ls_nand_dt_match[] = {
1131:          { .compatible = "ls1a-nand",  },
1132:               {},
1133:
1134: };
...
1140: static struct platform_driver ls1a_nand_driver = {
1141: 	.driver = {
1142: 		.name	= "ls1a-nand",
1143:         .owner	= THIS_MODULE,
1145:         .of_match_table = of_match_ptr(ls_nand_dt_match),
1148: 	},
1149: 	.probe		= ls1a_nand_probe,
1150: 	.remove		= ls1a_nand_remove,
1151: 	.suspend	= ls1a_nand_suspend,
1152: 	.resume		= ls1a_nand_resume,
1153: };
1173: MODULE_DESCRIPTION("Loongson_1a NAND controller driver");
```

### 4.8 MTD partition layout — **three mutually inconsistent definitions**

**(a) Hardcoded in the driver** — `lart_partitions[]`, lines 106–119:

```c
106: static const struct mtd_partition lart_partitions[] = {
107: 	/* kernel */
108: 	{
109: 		.name	= "kernel",
110: 		.offset	= 0x0,	/* MTDPART_OFS_APPEND */
111: 		.size	= 0x01500000,        /* 21 MiB */
112: 	},
113: 	/* initial ramdisk / file system */
114: 	{
115: 		.name	= "file system",
116: 		.offset	= 0x01500000,	/* MTDPART_OFS_APPEND */
117: 		.size	= 0x02300000,	/* MTDPART_SIZ_FULL */   /* 35 MiB */
118: 	}
119: };
```

Total described: `0x03800000` = **56 MiB** — yet the documentation and the defconfig assume a
**128 MiB** part (see (c)). This pair is what actually gets registered:

```c
1053: #ifdef CONFIG_MTD_PARTITIONS
...   (dead: CONFIG_MTD_PARTITIONS does not exist in 5.14)
1065: #else
1066:                  mtd->name = "nand-flash";
...
1073:                  return mtd_device_register(mtd, lart_partitions,
1074:                                 ARRAY_SIZE(lart_partitions));
1076: #endif
```

Because `CONFIG_MTD_PARTITIONS` is **undefined in Linux 5.14**, the `#else` branch compiles and
**the hardcoded `lart_partitions[]` always win**; `CONFIG_MTD_CMDLINE_PARTS=y` and
`CONFIG_MTD_OF_PARTS=y` are set but never consulted, since `parse_mtd_partitions()` sits inside
the dead `#ifdef`. MTD device name: **`"nand-flash"`**.

**(b) Device tree**, inside the `#if 0` blocks (`loongson32_ls.dts:89-98`,
`loongson32_bx.dts:126-135`):

```dts
number-of-parts = <0x2>;
partition@0 {
	label = "kernel_partition";
	reg = <0x0000000 0x01400000>;        /* 20 MiB */
};

partition@0x01400000 {
	label = "os_partition";
	reg = <0x01400000 0x0>;              /* to end */
};
```

The driver **never calls `of_partitions`/`mtd_device_parse_register()` with the DT node**, so
these labels are inert.

**(c) Bootloader / documentation** — `chiplab/docs/FPGA_run_linux/linux_run.md:124-131`:

```
set mtdparts nand-flash:50M@0(kernel)ro,-(rootfs)
...
set al /dev/mtd0
set append "console=ttyS0,115200 rdinit=/sbin/init initcall_debug=1 loglevel=20"
```

and the same document elsewhere (line 99) states the SoC supports a **128 MB NAND flash**
("当前 SoC 支持 128MB的 NandFlash 作为电脑中的硬盘功能"), with the tutorial erasing
`/dev/mtd0r` and `/dev/mtd1r` and copying the kernel to `/dev/mtd0`.

> ⚠ **These three layouts cannot all be true.** (a) puts the rootfs at **21 MiB**; (c) puts it at
> **50 MiB**. (a) describes **56 MiB** total; (c) implies **128 MiB**. Decide this deliberately
> for the port and make the driver use **one** mechanism (recommendation: `MTD_CMDLINE_PARTS` +
> `mtd_device_parse_register()`, or DT partitions, so kernel and bootloader cannot diverge).

### 4.9 Why the driver cannot bind as shipped

The NAND node is **commented out** in *both* device trees, and there is **no board-file
`platform_device` for it**:

* `arch/loongarch/boot/dts/loongson/loongson32_bx.dts:107` / `:137` — `#if 0` … `#endif`
* `arch/loongarch/boot/dts/loongson/loongson32_ls.dts:70` / `:100` — `#if 0` … `#endif`
* `grep -rn "ls1a-nand\|ls1a_nand" --include=*.c` finds **only** the driver itself. The only
  `platform_add_devices()` in `arch/loongarch/loongson32/setup.c:413` registers a `c67x00` USB
  device, not NAND.

`README.md:26` states this is intentional and tells you how to enable it:

> chiplab/loongson-soc 和全流程平台参考 SOC 均支持 nand flash，但是在他们的 dts 文件中，描述 nand
> 的结点均被 `#if 0` 注释掉了，如需启用，将 `#if 0` 和 `#endif` 删除即可。

("Both chiplab/loongson-soc and the full-flow reference SOC support NAND flash, but in their DTS
files the nodes describing NAND are commented out with `#if 0`; to enable, just delete the
`#if 0` and `#endif`.")

**And note the `reg` values differ between the two DTS files — the BX one is broken:**

```dts
/* loongson32_ls.dts:83-84  — CORRECT (chiplab) */
reg = <0x1fe78000 0x4000
       0x1fd01160 0x0>;

/* loongson32_bx.dts:120-121 — BROKEN (all zeros) */
reg = <0x00000000 0x4000
       0x00000000 0x0>;
```

Since chiplab is **LS_SOC**, use the `loongson32_ls.dts` values. Also note the driver only reads
resource #0 (`0x1fe78000`); resource #1 (`0x1fd01160`) is ignored because the driver *hardcodes*
the doorbell as `ORDER_REG_ADDR 0x9fd01160` (the KSEG0 alias of the same physical address).

### 4.10 The NAND in the sibling U-Boot tree — confirming the port target

`la32r-uboot` is **U-Boot 2019.07** for `arch/la32r`, board `nscscc`, config
`configs/la32rsoc_defconfig`. Grepping it for NAND confirms the user's premise:

```
configs/la32rsoc_defconfig:678  CONFIG_MTD_PARTITIONS=y
configs/la32rsoc_defconfig:679  # CONFIG_MTD is not set
configs/la32rsoc_defconfig:680  # CONFIG_MTD_NOR_FLASH is not set
configs/la32rsoc_defconfig:683  # CONFIG_NAND is not set
configs/la32rsoc_defconfig:294  CONFIG_CMD_MTD=y
configs/la32rsoc_defconfig:295  # CONFIG_CMD_NAND is not set
configs/la32rsoc_defconfig:402  # CONFIG_CMD_MTDPARTS is not set
configs/la32rsoc_defconfig:454  # CONFIG_ENV_IS_IN_NAND is not set
configs/la32rsoc_defconfig:695  # CONFIG_MTD_UBI is not set
```

U-Boot's storage today is **MMC/SD (`CONFIG_MMC_LSMMC=y`) with EXT4/FAT**, e.g.
`configs/la32rsoc_defconfig:106`:

```
CONFIG_BOOTCOMMAND="fatload mmc 0:0 0xa0e00000 vm.bx100e;bootelf 0xa0e00000 console=ttyS0,115200"
```

So the U-Boot NAND port means writing a `drivers/mtd/nand/raw/ls1a_nand.c` (DM or legacy)
equivalent plus `CONFIG_NAND`/`CONFIG_CMD_NAND`/`CONFIG_SYS_NAND_SELF_INIT` plumbing, reusing the
register map in §11. The *board* directory to touch is `la32r-uboot/board/nscscc/` plus
`la32r-uboot/arch/la32r/` (note the tree's `board/nscscc/2019/Makefile` hints the board file is
gated on a U-Boot version subdirectory).

---

## 5. The board device tree

**Path:** `arch/loongarch/boot/dts/loongson/loongson32_ls.dts` (103 lines) — this is the chiplab
board. (`loongson32_bx.dts`, 140 lines, is the "full-flow reference SoC".)

Full content of the parts that matter:

```dts
 1: // SPDX-License-Identifier: GPL-2.0
 2: /dts-v1/;
 3:
 4: / {
 5: 	model = "loongson,generic";
 6: 	compatible = "loongson,loongson3";
 7: 	#address-cells = <1>;
 8: 	#size-cells = <1>;
 9:
10: 	aliases {
11: 		serial0 = &cpu_uart0;
12: 	};
13:
14: 	chosen {
15: 		stdout-path = "serial0:115200n8";
16: 		bootargs = "earlycon";
17: 	};
18:
19: 	extioiic: interrupt-controller@0x1fe11600 { ... };   /* unused on chiplab, see below */
30:
31: 	memory {
32: 		name = "memory";
33: 		device_type = "memory";
34: 		reg = <0x00000000  0x08000000>;      /* 128 MiB @ 0x00000000 */
35: 	};
36:
37: 	cpuic: interrupt-controller {
38: 		compatible = "loongson,cpu-interrupt-controller";
39: 		interrupt-controller;
40: 		#interrupt-cells = <1>;
41: 	};
42:
43: 	soc {
44: 		compatible = "simple-bus";
45: 		#address-cells = <1>;
46: 		#size-cells = <1>;
47: 		ranges = <0x10000000 0x10000000 0x10000000>;
48:
49: 		cpu_uart0: serial@0x1fe001e0 {
50: 			compatible = "ns16550a";
51: 			reg = <0x1fe001e0  0x10>;
52: 			clock-frequency = <33000000>;
53: 			interrupt-parent = <&cpuic>;
54: 			interrupts = <3>;
55: 			no-loopback-test;
56: 		};
57:
58: 		gmac0: dmfe@0x1ff00000 {
59: 			compatible = "dmfe";
60: 			reg = <0x1ff00000 0x10000>;
61: 			interrupt-parent = <&cpuic>;
62: 			interrupts = <2>;
63: 			interrupt-names = "macirq";
64: 			mac-address = [ 64 48 48 48 48 60 ];
65: 			phy-mode = "rgmii";
66: 			bus_id = <0x0>;
67: 			phy_addr = <0xffffffff>;
68: 			dma-mask = <0xffffffff 0xffffffff>;
69: 		};
70: #if 0
71: 		ahci@0x1fe30000 { ... };
79: 		nand@0x1fe78000 {                     <-- DISABLED
82: 			compatible = "ls1a-nand";
83: 			reg = <0x1fe78000 0x4000
84: 			       0x1fd01160 0x0>;
85: 			interrupt-parent = <&cpuic>;
86: 			interrupts = <4>;
87: 			interrupt-names = "nand_irq";
89: 			number-of-parts = <0x2>;
90: 			partition@0 { label = "kernel_partition"; reg = <0x0000000 0x01400000>; };
95: 			partition@0x01400000 { label = "os_partition"; reg = <0x01400000 0x0>; };
99: 		};
100: #endif
101: 	};
102: };
```

### 5.1 Key node values, quoted

| Item | Value | Line |
|---|---|---|
| **Memory size** | `<0x00000000 0x08000000>` = **128 MiB at physical 0x0** | `:34` |
| **bootargs** | **`"earlycon"`** | `:16` |
| stdout-path | `"serial0:115200n8"` | `:15` |
| Console UART | `ns16550a` @ **`0x1fe001e0`**, 16 bytes, 33 MHz, IRQ 3 via `cpuic` | `:49-56` |
| Interrupt controller | `loongson,cpu-interrupt-controller` (`cpuic`), 1 cell | `:37-41` |
| extioi (declared, unused) | `loongson,extioi-interrupt-controller` @ `0x1fe11600`, `vec_count=<128>`, `misc_func=<0x100>`, `eio_en_off=<27>`, parent `cpuic` IRQ 3 | `:19-29` |
| Ethernet | `dmfe` (not `snps,dwmac`) @ `0x1ff00000`, IRQ 2 via `cpuic` | `:58-69` |
| NAND | `ls1a-nand` @ `0x1fe78000` (0x4000) + `0x1fd01160`, IRQ 4 — **`#if 0`** | `:79-99` |
| No `timer` node | the timer is the **LoongArch CP0/CSR constant timer**, not a DT device | — |
| No `confreg` node | see §7 | — |

The BX board differs mainly in: memory `<0x200000 0xee00000>` (2 MiB…240 MiB), UART at
`0x1fe40000`, two `ls1x-intc` controllers at `0x1fd01040`/`0x1fd01058`, an
`loongson,loongson2-apbdma` node at `0x1fd01160`, a `syscon` at `0x1fd00100`, and an SDIO node.

### 5.2 The bootargs question — where the real command line comes from

`CONFIG_CMDLINE` is **not set** in `la32_defconfig` (only the unrelated
`# CONFIG_CMDLINE_PARTITION is not set` at `:428`). The kernel command line therefore comes
**entirely from the bootloader**, via the MIPS-style firmware argument convention:

```c
/* arch/loongarch/kernel/cmdline.c:14-28 */
void __init fw_init_cmdline(void)
{
	fw_argc = fw_arg0;
	_fw_argv = (long *)fw_arg1;
	_fw_envp = (long *)fw_arg2;

	arcs_cmdline[0] = '\0';
	for (i = 1; i < fw_argc; i++) {
		strlcat(arcs_cmdline, fw_argv(i), COMMAND_LINE_SIZE);
		if (i < (fw_argc - 1))
			strlcat(arcs_cmdline, " ", COMMAND_LINE_SIZE);
	}
}
```

`arch/loongarch/kernel/head.S:47-59` saves `a0..a3` into `fw_arg0..fw_arg3` and, under
`CONFIG_USE_OF`, interprets **`a0 == -2` as "`a1` is the DTB pointer"**:

```asm
27: #ifdef CONFIG_USE_OF
29: 	li.w		t1, -2
30: 	or		t2, a1, zero
31: 	beq		a0, t1, dtb_found
33: 	li.w		t2, 0
34: dtb_found:
35: #endif
```

**Documented command lines actually used:**

| Boot path | Command line | Source |
|---|---|---|
| PMON `g` | `console=ttyS0,baudrate rdinit=sbin/init` | `linux_run.md:94` |
| PMON autoload from NAND | `console=ttyS0,115200 rdinit=/sbin/init initcall_debug=1 loglevel=20` | `linux_run.md:130` |
| U-Boot | `console=ttyS0,115200 rdinit=/init` | `linux_run.md:160` |
| DTS default | `earlycon` | `loongson32_ls.dts:16` |

---

## 6. Platform devices and drivers a port must provide

### 6.1 Serial console — 8250/ns16550

| Component | Detail |
|---|---|
| DTS node | `loongson32_ls.dts:49-56`, `compatible = "ns16550a"`, `reg = <0x1fe001e0 0x10>`, `clock-frequency = <33000000>`, `interrupts = <3>` |
| Kernel path | `CONFIG_SERIAL_8250=y` + **`CONFIG_SERIAL_OF_PLATFORM=y`** (`la32_defconfig:1396, 1412`) → the port is instantiated **from the DT node** by `8250_of` |
| Console | `CONFIG_SERIAL_8250_CONSOLE=y` (`:1400`), `CONFIG_SERIAL_CORE_CONSOLE=y` (`:1419`); `stdout-path = "serial0:115200n8"` |
| Legacy platform device | `arch/loongarch/loongson32/serial.c` registers a `"serial8250"` device — **but see below** |
| UART base table | `arch/loongarch/loongson32/uart_base.c:26-30` — `LS_SOC` → `0x9fe001e0`, `BX_SOC` → `0x9fe40000` |
| Early console | `arch/loongarch/loongson32/early_printk.c:34-45` — `prom_putchar()` pokes `UART_LSR`/`UART_TX` at `0x9fe001e0` directly; selected by `CONFIG_EARLY_PRINTK=y` (`la32_defconfig:2576`) |

> ⚠ `serial.c:44-60` is **defective**: it fills `uart8250_data[1][0]` (mapbase, membase,
> `uartclk = 0x10000000`) and then immediately `memset(..., 0, sizeof(struct
> plat_serial8250_port))` at line 56 **before** handing it to `platform_device_register()`. The
> registered port is therefore all-zero. The working console is the **DT-driven 8250_of** path.
> Do not port `serial.c`; port the **DTS node** (which is what actually works).

**Port note:** `8250_of` and `ns16550a` are arch-independent — the DTS node transfers to RISC-V
verbatim (modulo the interrupt-parent). For RV32-GC, `CONFIG_SERIAL_OF_PLATFORM=y` and an
`earlycon=uart8250,mmio,0x1fe001e0` (or `earlycon` + `stdout-path`) is all that is needed.

### 6.2 Timer / clocksource / clockevent — **CSR-based, not a DT device**

`arch/loongarch/kernel/time.c` is the whole timer subsystem — there is **no
`drivers/clocksource` driver and no `CONFIG_CLKSRC_*` symbol** for this board:

* `constant_clockevent_init()` (lines 132–171): `cd->name = "Constant"`,
  `features = CLOCK_EVT_FEAT_ONESHOT`, **`irq = LOONGSON_TIMER_IRQ`**, `rating = 320`,
  `clockevents_config_and_register(cd, const_clock_freq, 0x600, (1ULL<<31)-1)`,
  `set_csr_ecfg(0x800)`, `request_irq(irq, constant_timer_interrupt, IRQF_PERCPU|IRQF_TIMER, "timer", NULL)`.
* `read_const_counter()` (173–176) = **`drdtime()`** — the LoongArch *constant timer* CSR.
* `clocksource_const` (178–187): `.name = "Constant"`, `.rating = 320`, `mask = 64-bit`,
  `shift = 10`.
* `time_init()` (212–221): `const_clock_freq = cpu_clock_freq` or `calc_const_freq()` via CPUCFG.
  The DMI/SMBIOS-derived `cpu_clock_freq` (`loongson32/setup.c:150-199`) never fires on this
  board, and `cpu_has_cpucfg` **is** set (`arch/loongarch/kernel/cpu-probe32.c:109-110`), so
  `calc_const_freq()` wins — and for `CONFIG_32BIT` it is a **hardcoded constant**
  (`arch/loongarch/include/asm/time.h:40-49`):

```c
#ifdef CONFIG_32BIT
static inline unsigned int calc_const_freq(void) {
#ifdef CONFIG_LS_SOC
	return 200000000;      /* 200 MHz  -> chiplab / la32r-QEMU */
#elif CONFIG_BX_SOC
	return 33000000;       /* 33 MHz   -> full-flow reference SOC */
#endif
}
#endif
```

  → **the chiplab/LA32R timer frequency is 200 MHz**, with `CONFIG_HZ=250`
  (`la32_defconfig:278`), i.e. 800,000 timer ticks per jiffy. Note this is **not** the UART clock
  (33 MHz, from the DTS `clock-frequency`) — do not conflate the two.
* Timer CSRs (`arch/loongarch/include/asm/loongarchregs.h:662-678`): `TCFG 0x41`
  (`CSR_TCFG_VAL = 0x3fffffffffff<<2`, `CSR_TCFG_PERIOD` = bit 1, `CSR_TCFG_EN` = bit 0),
  `TVAL 0x42`, `CNTC 0x43`, `TINTCLR 0x44` (`CSR_TINTCLR_TI` = bit 0). `drdtime()` on 32-bit is a
  `rdcntvl.w` + `rdcntvh.w` pair (`loongarchregs.h:1318-1332`), reading the 64-bit TVAL twice.

IRQ number (`arch/loongarch/include/asm/mach-loongson32/irq.h:16-20`):

```c
16: #define LOONGSON_CPU_IRQ_BASE		16
17: #define LOONGSON_UART_IRQ		(LOONGSON_CPU_IRQ_BASE + 3) /* IP2 for CPU local interrupt controller */
18: #define LOONGSON_GMAC_IRQ		(LOONGSON_CPU_IRQ_BASE + 2) /* IP3 for bridge */
19: #define LOONGSON_TIMER_IRQ		(LOONGSON_CPU_IRQ_BASE + 11) /* IP11 CPU Timer */
20: #define LOONGSON_CPU_LAST_IRQ		(LOONGSON_CPU_IRQ_BASE + 14)
```

→ **timer IRQ = 27**. Dispatch is via the `TI` bit of `ESTAT`:
`arch/loongarch/loongson32/irq.c:19-36` — `if (pending & 0x800) do_IRQ(LOONGSON_TIMER_IRQ);`
(the LS/non-BX path additionally handles `pending & 0x20 → do_IRQ(4)`, `0x4 → GMAC`,
`0x8 → UART`).

**Port note:** this must be **fully rewritten** for RISC-V. The natural targets are:
`CONFIG_CLINT_TIMER` + `riscv,timer` with `mtime`/`mtimecmp` (as `SOC_VIRT` uses), or a
`drivers/clocksource` driver for a chiplab/confreg timer if the FPGA design has one (see §7 —
`confreg_sim.v` defines a `TIMER_ADDR` at `0x1fafe000`). `CNTFRQ`/33 MHz assumptions must be
replaced by whatever your SoC actually provides.

### 6.3 Interrupt controllers

Two drivers exist, and chiplab uses only the first:

| Driver | Compatible | Registers | Config | Used by |
|---|---|---|---|---|
| `drivers/irqchip/irq-loongarch-cpu.c` (78 lines) | `"loongson,cpu-interrupt-controller"` | LoongArch CSRs: `ECFG`, `ESTAT` | built with the arch | **chiplab (LS)** — the `cpuic` node |
| `drivers/irqchip/irq-ls1x.c` (193 lines) | `"loongson,ls1x-intc"` | `STATUS 0x00, EN 0x04, SET 0x08, CLR 0x0c, POL 0x10, EDGE 0x14` (0x18 bytes) | **`CONFIG_LS1X_IRQ=y`** (`la32_defconfig:1913`) | BX_SOC only (two nodes at `0x1fd01040`, `0x1fd01058`) |

`irq-loongarch-cpu.c` internals:

```c
20: 	set_csr_ecfg(ECFGF(d->hwirq));            /* unmask */
27: 	clear_csr_ecfg(ECFGF(d->hwirq));          /* mask   */
42: 	do_IRQ(irq_linear_revmap(irq_domain, irq));
52: 	set_vi_handler(EXCCODE_INT_START + hwirq, default_handle_irq);
66: 	clear_csr_ecfg(ECFG0_IM);
67: 	clear_csr_estat(ESTATF_IP);
69: 	irq_domain = irq_domain_add_simple(of_node, EXCCODE_INT_NUM,
70: 		     LOONGSON_CPU_IRQ_BASE, &loongarch_cpu_intc_irq_domain_ops, NULL);
78: IRQCHIP_DECLARE(cpu_intc, "loongson,cpu-interrupt-controller", loongarch_cpu_irq_init);
```

So: a **LoongArch `cpuic` is an irq_domain offset by `LOONGSON_CPU_IRQ_BASE = 16`**, hwirq *N*
→ virq `16 + N`. This explains the DTS values: UART `interrupts = <3>` → virq 19
(= `LOONGSON_UART_IRQ`), GMAC `interrupts = <2>` → virq 18 (= `LOONGSON_GMAC_IRQ`). ✔ consistent.

**Is there a Loongson "VInt"/custom IPI?** Not in the sense of the Loongson-3 `VInt`/`extioi`
used on `loongson64`. The LS board uses the arch's `ECFG`/`ESTAT` CSR bits directly
(`ECFGF_IP0…IP3`, `ECFGF_IPI`, `ECFGF_PC` — see `irq.c:58`):

```c
58: 	set_csr_ecfg(ECFGF_IP0 | ECFGF_IP1 |ECFGF_IP2 | ECFGF_IP3| ECFGF_IPI | ECFGF_PC);
```

The `extioiic` node in `loongson32_ls.dts:19-29` declares
`"loongson,extioi-interrupt-controller"` with `vec_count=<128>`, `misc_func=<0x100>`,
`eio_en_off=<27>` — but **no matching `IRQCHIP_DECLARE` exists for that string in
`drivers/irqchip/`**, so on chiplab it is dead DT. (Confirmed: the only
`cpu-interrupt-controller` matches are `irq-loongarch-cpu.c` and `irq-mips-cpu.c`.)

**Port plan:** implement a RISC-V interrupt controller. For a chiplab FPGA the realistic options
are (a) a SiFive-style PLIC if the FPGA design provides one, or (b) a small custom driver that
mirrors `irq-ls1x.c`'s 6-register layout (STATUS/EN/SET/CLR/POL/EDGE) — that register block is
generic and easy to re-expose as `interrupt-controller` in your RV32 DTS. The timer/PI must come
from CLINT (`mtimecmp`/`msip`) or an SBI implementation.

### 6.4 Early console

* `arch/loongarch/loongson32/early_printk.c` — `prom_putchar()` (`:29-46`) and `prom_printf()`
  (`:48+`), `CONFIG_EARLY_PRINTK=y` (`la32_defconfig:2576`), built by
  `arch/loongarch/loongson32/Makefile` (`obj-$(CONFIG_EARLY_PRINTK) += early_printk.o`).
* On RISC-V this becomes `earlycon=uart8250,mmio,0x1fe001e0` plus
  `CONFIG_SERIAL_EARLYCON` — the same physical address, no code to port.

### 6.5 Reboot / poweroff — **there is no working reboot or poweroff**

`arch/loongarch/loongson32/reset.c` (54 lines) is, in full:

```c
20: static void loongson_restart(void)
21: {
22: #ifdef CONFIG_EFI
23: 	if (efi_capsule_pending(NULL))
24: 		efi_reboot(REBOOT_WARM, NULL);
25: 	else
26: 		efi_reboot(REBOOT_COLD, NULL);
27: #endif
28: 	if (!acpi_disabled)
29: 		acpi_reboot();
30:
31: 	while (1) {
32: 		__arch_cpu_idle();
33: 	}
34: }
36: static void loongson_poweroff(void)
37: {
38: #ifdef CONFIG_EFI
39: 	efi.reset_system(EFI_RESET_SHUTDOWN, EFI_SUCCESS, 0, NULL);
40: #endif
41: 	while (1) {
42: 		__arch_cpu_idle();
43: 	}
44: }
46: static int __init loongarch_reboot_setup(void)
47: {
48: 	pm_restart = loongson_restart;
49: 	pm_power_off = loongson_poweroff;
50: 	return 0;
51: }
53: arch_initcall(loongarch_reboot_setup);
```

On the FPGA (no EFI, no ACPI) both paths are an **infinite idle loop**. There is no
`CONFIG_POWER_RESET*`, no `SYSRESET`, and no write to any reset register.

**Port opportunity:** the chiplab `confreg` block is the natural reset/poweroff/exit device
(§7). A small `drivers/power/reset/chiplab-confreg-poweroff.c` (`syscon-poweroff` style) or a
`syscon-reboot` DT node against `0x1faf_0000` would give you working `reboot` and `poweroff`, and
a simulation-exit hook.

### 6.6 Is there a `drivers/platform` or `arch/loongarch/platform` file?

```
$ ls drivers/platform/ 2>/dev/null        # not surveyed as board-specific; nothing chiplab-related
$ ls arch/loongarch/loongson32/Platform   # build rules only (see §2.3)
```

There is **no** `arch/loongarch/platform/` directory and **no** board file registering the
board's devices. Everything is driven by the built-in DTB (`CONFIG_BUILTIN_DTB=y`) plus the two
`IRQCHIP_DECLARE`/`CLK_OF_DECLARE`-style drivers. The only `platform_device` registrations in
`arch/loongarch/loongson32/` are the broken `serial8250` one (§6.1) and a `c67x00` USB device
(`setup.c:413`, under a config that is off).

### 6.7 Built-in DTB plumbing (relevant to §10)

```c
/* arch/loongarch/loongson32/setup.c:45-51 */
extern char __dtb_start[];
#ifdef CONFIG_LS_SOC
extern u32 __dtb_loongson32_ls_begin[];
static u32 *__dtb_begin = __dtb_loongson32_ls_begin;
#elif CONFIG_BX_SOC
extern u32 __dtb_loongson32_bx_begin[];
static u32 *__dtb_begin = __dtb_loongson32_bx_begin;
#endif

/* :335 */
	loongson_fdt_blob = __dtb_begin;
	__dt_setup_arch(loongson_fdt_blob);
```

`arch/loongarch/Makefile:140` — `core-$(CONFIG_BUILTIN_DTB) += arch/loongarch/boot/dts/`;
`arch/loongarch/boot/dts/Makefile:4` — `obj-$(CONFIG_BUILTIN_DTB) := $(addsuffix /, $(subdir-y))`.
`arch/riscv` has the same `CONFIG_BUILTIN_DTB` symbol (`arch/riscv/Kconfig:544-547`), so this
mechanism is available for the RV32 port with a `select BUILTIN_DTB` from your SoC symbol.

---

## 7. chiplab-specific hooks in the kernel — the magic confreg addresses

### 7.1 Result: the kernel contains **no** confreg access at all

```
$ grep -rn "chiplab\|CHIPLAB\|confreg\|CONFREG" --include=*.c --include=*.h --include=*.S \
       --include=*.dts arch/loongarch/ drivers/ | grep -v staging | grep -v amd
(no matches in arch/loongarch/)
```

```
$ grep -rn "0x1faf\|1faf\b" arch/loongarch/ drivers/platform/
(no matches)
```

**There is no simulation-exit device, no LED/switch accessor, and no confreg driver in this
kernel.** This is a genuine gap, not something to port — it is something to *add* if you want
simulation exit or LEDs.

### 7.2 Where the addresses are actually defined — the chiplab RTL

The authoritative definition is in the chiplab reference RTL, not the kernel:

**`chiplab/IP/BRIDGE/bridge_1x2.v:48-49`:**

```verilog
`define CONF_ADDR_BASE 32'h1faf_0000
`define CONF_ADDR_MASK 32'h1fff_0000 //for bfaf or 1faf
```

and it routes there from the AXI mux — `chiplab/IP/AMBA/axi_mux_sim.v:859`:

```verilog
axi_s_awaddr[28:16]==16'h1faf ;  //CONF
```

```verilog
951: assign rd_addr_hit[3] = (axi_s_araddr[28:16]) == 16'h1faf ||
```

**`chiplab/IP/CONFREG/confreg_sim.v`** (the simulation variant) defines the register offsets
*relative to* `0x1faf_0000`. There are **two alternative (commented) address maps** in the file —
the active one is the second block (lines ~77–102):

```verilog
/* ---- first (commented-out) map ---- */
`define CR0_ADDR       16'h8000   //32'hbfaf_8000
`define CR1_ADDR       16'h8004   //32'hbfaf_8004
`define CR2_ADDR       16'h8008   //32'hbfaf_8008
`define CR3_ADDR       16'h800c   //32'hbfaf_800c
`define CR4_ADDR       16'h8010   //32'hbfaf_8010
`define CR5_ADDR       16'h8014   //32'hbfaf_8014
`define CR6_ADDR       16'h8018   //32'hbfaf_8018
`define CR7_ADDR       16'h801c   //32'hbfaf_801c
`define LED_ADDR       16'hf000   //32'hbfaf_f000
`define LED_RG0_ADDR   16'hf004   //32'hbfaf_f004
`define LED_RG1_ADDR   16'hf008   //32'hbfaf_f008
`define NUM_ADDR       16'hf010   //32'hbfaf_f010
`define SWITCH_ADDR    16'hf020   //32'hbfaf_f020
`define BTN_KEY_ADDR   16'hf024   //32'hbfaf_f024
`define BTN_STEP_ADDR  16'hf028   //32'hbfaf_f028
`define SW_INTER_ADDR  16'hf02c   //32'hbfaf_f02c
`define TIMER_ADDR     16'he000   //32'hbfaf_e000
`define IO_SIMU_ADDR      16'hffec  //32'hbfaf_ffec
`define VIRTUAL_UART_ADDR 16'hfff0  //32'hbfaf_fff0
`define SIMU_FLAG_ADDR    16'hfff4  //32'hbfaf_fff4
`define OPEN_TRACE_ADDR   16'hfff8  //32'hbfaf_fff8
`define NUM_MONITOR_ADDR  16'hfffc  //32'hbfaf_fffc
```

**Active map (confreg_sim.v lines 77–102) — these are the offsets that matter:**

| Offset | Absolute address | Register | Access |
|---|---|---|---|
| `0x8000`/`0x8010`/…/`0x8070` | `0x1faf8000` … `0x1faf8070` | `CR0`…`CR7` (8 config registers) | RW |
| `0xf020` | **`0x1faff020`** | `LED_ADDR` | RW |
| `0xf030` | `0x1faff030` | `LED_RG0_ADDR` | RW |
| `0xf040` | `0x1faff040` | `LED_RG1_ADDR` | RW |
| `0xf050` | `0x1faff050` | `NUM_ADDR` (7-seg digits) | RW |
| `0xf060` | `0x1faff060` | `SWITCH_ADDR` | RO |
| `0xf070` | `0x1faff070` | `BTN_KEY_ADDR` | RO |
| `0xf080` | `0x1faff080` | `BTN_STEP_ADDR` | RO |
| `0xf090` | `0x1faff090` | `SW_INTER_ADDR` | RO |
| `0xe000` | `0x1fafe000` | **`TIMER_ADDR`** | RW |
| `0xff00` | `0x1fafff00` | **`IO_SIMU_ADDR`** — simulation "exit"/IO | RW |
| `0xff10` | `0x1fafff10` | `VIRTUAL_UART_ADDR` | RW |
| `0xff20` | `0x1fafff20` | **`SIMU_FLAG_ADDR`** — simulation flag | RO |
| `0xff30` | `0x1fafff30` | `OPEN_TRACE_ADDR` | RW |
| `0xff40` | `0x1fafff40` | **`NUM_MONITOR_ADDR`** — "monitor off" flag | RW |
| — | `0x1fd0f030` | `FREQ_ADDR` (per comment `32'hbfd0_f030`) | — |

RTL behaviour confirming semantics:

```verilog
/* confreg_sim.v:300-308 — simulation flag */
        simu_flag <= {32{SIMULATION}};

/* confreg_sim.v:310-323 — IO simulation (write with byte-swapped data) */
wire write_io_simu = conf_we & (conf_waddr[15:0]==`IO_SIMU_ADDR);
    else if(write_io_simu)
        io_simu <= {conf_wdata[15:0],conf_wdata[31:16]};

/* confreg_sim.v:340-353 — number monitor (write 1 to disable the 7-seg monitor) */
wire write_num_monitor = conf_we & (conf_waddr[15:0]==`NUM_MONITOR_ADDR);
    else if(write_num_monitor)
        num_monitor <= conf_wdata[0];
```

The generic (synthesis) variant `chiplab/IP/CONFREG/confreg_syn.v` has the same `module confreg(`
interface, so the same map applies to the FPGA bitstream.

### 7.3 The one "magic address" the kernel *does* use: `0x9fd01160`

This is **not** confreg — it is the **APB DMA "order" (doorbell) register**, and it is the only
absolute hardware address the NAND driver hardcodes (`ls1a_nand.c:19`,
`ORDER_REG_ADDR = 0x9fd01160`; physical `0x1fd01160`). It appears in the BX DTS as a
`"loongson,loongson2-apbdma"` node (`loongson32_bx.dts:80-88`, with a `syscon` phandle at
`0x1fd00100`). The LS DTS does **not** declare it as a device; the NAND driver just writes it
directly.

### 7.4 Summary for the port

* No kernel-side confreg hook exists → nothing to port; if you want simulation exit or LED
  output you must **write** a small driver against `0x1faf_f020` (LED), `0x1faf_ff00`
  (`io_simu`, the conventional simulation-exit/print channel), and `0x1faf_ff40`
  (`num_monitor`).
* On RV32 make sure the AXI/SoC address map still decodes `0x1faf_0000` (mask `0x1fff_0000`) —
  note this collides with nothing else in the LS map, but the RTL comment says the mask exists
  precisely so that **`0xbfaf_xxxx`** (the KSEG1 alias used by PMON/U-Boot) also hits it. If your
  RV32-GC core does not implement a KSEG1-equivalent alias, use the `0x1faf_xxxx` form.

---

## 8. Build and run

### 8.1 The authoritative build recipe — `README.md:5-58` (verbatim, translated inline)

```
## 内核编译

1. 克隆仓库
    git clone https://gitee.com/loongson-edu/la32r-Linux.git --depth=1
    cd la32r-Linux

2. 配置环境变量（假设交叉工具链安装在了
   /opt/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/ 下）
    export PATH=/opt/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH
    export CROSS_COMPILE=loongarch32r-linux-gnusf-
    export ARCH=loongarch

3. 配置内核编译选项，3 个平台的差异通过此步区分
    la32r-QEMU              -> make la32_defconfig   (arch/loongarch/configs/la32_defconfig)
    chiplab/loongson-soc    -> make la32_defconfig   (arch/loongarch/configs/la32_defconfig)
    全流程平台参考 SOC       -> make la32_bx_defconfig (arch/loongarch/configs/la32_bx_defconfig)

4. 配置根文件系统路径
    la32r-Linux 在 3 个平台中均采用 ramfs，编译好的根文件系统在内核构建过程中直接被链接在内核中，
    因此需要在编译内核前对根文件系统的路径进行配置。
    编译根文件系统可使用 la32r-buildroot
    - 修改 .config 中的 CONFIG_INITRAMFS_SOURCE，例：CONFIG_INITRAMFS_SOURCE="~/linux-5.14-loongarch32/initrd_pck32"
    - 或在 make menuconfig 中 General Setup -> Initramfs source file(s) 修改

5. 编译内核，内核的 ELF 文件为当前目录下的 vmlinux
    make -j`nproc`

6. 裁剪 vmlinux，将其中多余的符号信息去除，以减小内核体积
    loongarch32r-linux-gnusf-strip vmlinux

注：如果想采用自动化编译流程，可参考 la_build.sh，其中需要自行配置 CROSS_COMPILE 变量，
    并在打开 menuconfig 后自行修改根文件系统目录，生成的 ELF 文件为 la_build/vmlinux。
```

**Exact command sequence for the chiplab board:**

```sh
export PATH=/opt/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH
export CROSS_COMPILE=loongarch32r-linux-gnusf-
export ARCH=loongarch

make la32_defconfig
# optionally: edit CONFIG_INITRAMFS_SOURCE to point at your buildroot rootfs
make -j$(nproc)
loongarch32r-linux-gnusf-strip vmlinux
# artefact: ./vmlinux  (a stripped 32-bit ELF, entry = kernel_entry)
```

> **There is no binary/image conversion step, and one cannot be made to work in-tree.**
> `arch/loongarch/Makefile:131` declares `boot-y := vmlinux.bin` and `:135-137` gives it a rule
> that recurses into `arch/loongarch/boot/`, but **`arch/loongarch/boot/Makefile` does not exist**
> (the directory contains only `dts/`). So `make vmlinux.bin` fails, and the `archhelp` text
> (`:147-151`) advertising a "Raw binary boot image" is stale. `KBUILD_IMAGE` is never overridden
> by the arch, so the effective default target is the plain **`vmlinux` ELF** (plus `dtbs`, since
> `CONFIG_OF_EARLY_FLATTREE=y` — see `arch/loongarch/Makefile:132`, top-level `Makefile:685,
> 1403-1405`). **The deliverable is an ELF, by design.** By contrast `arch/riscv/boot/Makefile`
> *does* exist and builds `Image`/`Image.gz` (`OBJCOPYFLAGS_Image := -O binary …`), so the RV32
> port has both options.

Toolchain auto-detection caveat: `arch/loongarch/Makefile:13-33` probes the prefixes
`loongarch32r-linux-`, `loongarch32r-linux-gnu-` and `loongarch32r-unknown-linux-gnu-` and sets
`UTS_MACHINE := loongarch32r`; **the README's `loongarch32r-linux-gnusf-` is not in that list**, so
`CROSS_COMPILE` genuinely must be exported as shown above. Also note the tree is on branch
`la32r-new-world` (single squashed commit `4ed7b98e08e8`), and `arch/loongarch/Makefile:6` sets
`KBUILD_DEFCONFIG := loongson3_defconfig` — the 64-bit Loongson-3 config, which only affects a bare
`make defconfig` and is not what you want.

### 8.2 The helper script `la_build.sh` (repo root, 15 lines)

```bash
 1: #!/bin/bash
 2:
 3: export CROSS_COMPILE=~/install-32-glibc-loongarch-novec-reduce-linux-5-14/bin/loongarch32-linux-gnu-
 4: export ARCH=loongarch
 5: OUT=la_build
 6:
 7: if [ ! -d la_build ] ;then
 8:     mkdir la_build
 9:     make la32_defconfig O=${OUT}
10: fi
11:
12: echo "----------------output ${OUT}----------------"
13:
14: make menuconfig O=${OUT}
15: make vmlinux -j`nproc` O=${OUT} 2>&1 | tee -a build_error.log
```

> ⚠ **The script uses a *different* toolchain than the README.** `la_build.sh:3` sets
> `loongarch32-linux-gnu-` (a glibc, "novec-reduce" toolchain under `~/install-32-glibc-…`),
> while `README.md:18` specifies `loongarch32r-linux-gnusf-` (GCC 8.3, v2.0, `/opt/…`).
> `make la32_defconfig` is also run in-tree *or* with `O=la_build` depending on the path. Pick
> one and record it; the README path is the documented/supported one.

### 8.3 How the image is loaded — **ELF, over TFTP, then `go`/`bootelf`**

There is **no** `vmlinux.bin`/`uImage` step in the documented flow. The artefact is a **stripped
32-bit ELF** (`vmlinux`) whose entry is `kernel_entry`; the bootloader relocates the ELF segments
to their link addresses.

Kernel load address: **`0xa0300000`** (`load-$(CONFIG_MACH_LOONGSON32) += 0xa0300000`,
`arch/loongarch/loongson32/Platform`) → `VMLINUX_LOAD_ADDRESS` → `. = VMLINUX_LOAD_ADDRESS` in
`arch/loongarch/kernel/vmlinux.lds.S:26`, with `ENTRY(kernel_entry)`.

**PMON path** (`chiplab/docs/FPGA_run_linux/linux_run.md:47-97`):

```
ifconfig dmfe0 10.90.50.44          # board IP
ping 10.90.50.43                    # server IP
load tftp://10.90.50.43/vmlinux     # TFTP the ELF
g console=ttyS0,115200 rdinit=sbin/init
```

**U-Boot path** (`linux_run.md:136-177`):

```
setenv ipaddr 10.90.50.44
setenv serverip 10.90.50.43
ping 10.90.50.43
setenv bootcmd console=ttyS0,115200 rdinit=/init
tftpboot 0xa3000000 vmlinux
bootelf 0xa3000000 bootcmd
```

with the doc explicitly noting (`:167`):

> 可以将内核加载到 `0xa300_0000` 开始的地址上，该地址并不是 `readelf` 显示的 `entry` 的入口地址。
> uboot 会先把镜像加载到一段无数据的地址，运行时再根据 elf 段的信息加载到对应的位置上。

("You can load the kernel at `0xa3000000`; this is **not** the entry address shown by `readelf`.
U-Boot first loads the image to a scratch area, then at run time loads it to the proper location
according to the ELF segment information.")

So: `0xa3000000` is a temporary staging address (KSEG1 alias of `0x03000000`, well above the
kernel's `0xa0300000` link address) and `bootelf` performs the real placement. **Note `bootelf`'s
second argument is an environment-variable name holding the kernel command line** — hence
`setenv bootcmd console=ttyS0,115200 rdinit=/init` + `bootelf 0xa3000000 bootcmd`. U-Boot's
built-in default follows the same pattern (`la32rsoc_defconfig:106`):
`CONFIG_BOOTCOMMAND="fatload mmc 0:0 0xa0e00000 vm.bx100e;bootelf 0xa0e00000 console=ttyS0,115200"`.

### 8.4 NAND-based autoboot (PMON)

`linux_run.md:98-133` documents programming the kernel into NAND and autobooting it:

```
mtd_erase /dev/mtd0r
mtd_erase /dev/mtd1r
ifconfig dmfe0 x.x.x.x
devcp tftp://x.x.x.x /vmlinux /dev/mtd0
set mtdparts nand-flash:50M@0(kernel)ro,-(rootfs)
set al /dev/mtd0
set append "console=ttyS0,115200 rdinit=/sbin/init initcall_debug=1 loglevel=20"
# reset -> PMON initialises, then autoloads the kernel from NAND
```

Physical flashing of the SPI flash that holds PMON/U-Boot is done **out of band via a separate
"programmer" bitstream over the serial port with xmodem**
(`chiplab/docs/FPGA_run_linux/flash.md:13-21`, bitstream `programmer_by_uart.bit`, 230400 baud) —
not by the kernel or U-Boot.

### 8.5 FreeBSD/QEMU and other helpers

* `arch/loongarch/boot/dts/` + `make dtbs` (see §10).
* `arch/riscv/boot/install.sh` (RV32 port) — `make install` support.
* No chiplab-specific helper scripts exist under `tools/` or `scripts/` beyond `la_build.sh`
  at the repo root (`find . -maxdepth 2 -name "la_build*"` → `./la_build.sh`).

---

## 9. Root filesystem expectations

**The rootfs is a built-in initramfs (ramfs/ramdisk), not UBI/UBIFS on NAND and not NFS.**

`README.md:35-44`:

> 4. 配置根文件系统路径
> la32r-Linux 在 3 个平台中均采用 **ramfs**，编译好的根文件系统在内核构建过程中直接被链接在内核中，
> 因此需要在编译内核前对根文件系统的路径进行配置。
> > 编译根文件系统可使用 la32r-buildroot
> 配置根文件系统路径的方式有 2 种：
> - 修改 .config 文件中的 `CONFIG_INITRAMFS_SOURCE` 参数，例：
>   `CONFIG_INITRAMFS_SOURCE="~/linux-5.14-loongarch32/initrd_pck32"`
> - 在 `make menuconfig` 中 `General Setup -> Initramfs source file(s)` 修改

("All three platforms use **ramfs**; the compiled root filesystem is linked directly into the
kernel during the build, so you must configure the rootfs path before building. You can build the
rootfs with la32r-buildroot.")

Config state (`arch/loongarch/configs/la32_defconfig`):

```
:157 CONFIG_BLK_DEV_INITRD=y
:158 CONFIG_INITRAMFS_SOURCE=""        <-- EMPTY in the shipped defconfig
:159 CONFIG_RD_GZIP=y
:160 CONFIG_RD_BZIP2=y
:792 CONFIG_DEVTMPFS=y
:793 CONFIG_DEVTMPFS_MOUNT=y
```

So out of the box the kernel has **no rootfs** — `CONFIG_INITRAMFS_SOURCE` must be pointed at a
directory or cpio archive (produced by
[la32r-buildroot](https://gitee.com/loongson-edu/la32r-buildroot)).

Boot/mount expectations:

| Boot path | Command line | Rootfs |
|---|---|---|
| PMON (RAM) | `console=ttyS0,115200 rdinit=sbin/init` | built-in initramfs |
| PMON (NAND autoboot) | `console=ttyS0,115200 rdinit=/sbin/init initcall_debug=1 loglevel=20` | built-in initramfs (kernel still loaded from `/dev/mtd0`) |
| U-Boot | `console=ttyS0,115200 rdinit=/init` | built-in initramfs |

* `rdinit=` is used (not `root=`/`rootfstype=`), confirming an initramfs-based rootfs.
* **The NAND is not the rootfs.** It is described as a "hard disk" holding the kernel image
  (`mtd0` = kernel, `mtd1` = rootfs per the PMON `mtdparts`), but the *documented, working*
  configuration boots a **built-in initramfs**. `UBIFS`, `UBI`, `JFFS2` are all absent from
  `la32_defconfig`.
* `CONFIG_MTD_CMDLINE_PARTS=y` (`:833`) means `mtdparts=nand-flash:50M@0(kernel)ro,-(rootfs)`
  *would* be honoured **if** the driver called `parse_mtd_partitions()` — it does not (§4.8).
* For the RV32 port, `arch/riscv/configs/rv32_defconfig` uses `CONFIG_ROOT_NFS=y` — you can pick
  either initramfs (recommended, matches the LA32R flow) or NFS.

---

## 10. FDT / device-tree compiler usage and the DTB name

### 10.1 How the DTB is built

* `arch/loongarch/boot/dts/Makefile`:

```make
# SPDX-License-Identifier: GPL-2.0
subdir-y	+= loongson

obj-$(CONFIG_BUILTIN_DTB)	:= $(addsuffix /, $(subdir-y))
```

* `arch/loongarch/boot/dts/loongson/Makefile`:

```make
# SPDX-License-Identifier: GPL-2.0
dtb-$(CONFIG_LS_SOC) += loongson32_ls.dtb
dtb-$(CONFIG_BX_SOC) += loongson32_bx.dtb
obj-y				+= $(patsubst %.dtb, %.dtb.o, $(dtb-y))
```

* `arch/loongarch/Makefile:140` — `core-$(CONFIG_BUILTIN_DTB) += arch/loongarch/boot/dts/`

The tree ships the **kernel's own `scripts/dtc`** (standard 5.14-rc2 libfdt/dtc). No external
`dtc` is required: `make dtbs` builds them, and because `obj-y += …dtb.o` they are also
**built into vmlinux** (as `__dtb_loongson32_ls_begin`) by the normal `make` / `make vmlinux`.

### 10.2 The DTB name expected for the chiplab board

| Question | Answer |
|---|---|
| DTS source | `arch/loongarch/boot/dts/loongson/loongson32_ls.dts` |
| **DTB file name** | **`loongson32_ls.dtb`** (rule: `dtb-$(CONFIG_LS_SOC) += loongson32_ls.dtb`) |
| Config symbol | `CONFIG_LS_SOC=y` (from `la32_defconfig:236`) |
| Embedded symbol | `__dtb_loongson32_ls_begin` (referenced at `setup.c:47`) |
| `CONFIG_BUILTIN_DTB` | `=y` (`la32_defconfig:281`) |
| `CONFIG_BUILTIN_DTB_NAME` | `"loongson32_ls"` (`la32_defconfig:282`) |
| Consumed by | `arch/loongarch/loongson32/setup.c:335` — `loongson_fdt_blob = __dtb_begin;` (hardcoded per-SoC, `BUILTIN_DTB_NAME` string is ignored — see the `#ifdef CONFIG_LS_SOC` at `setup.c:46-51`) |

### 10.3 Does U-Boot need to supply a DTB?

**No — and that is deliberate.** Because `CONFIG_BUILTIN_DTB=y` and
`platform_init()` unconditionally sets `loongson_fdt_blob = __dtb_begin` (`setup.c:335`), the
kernel **always uses its own embedded DTB** and ignores whatever the bootloader passes in `a1`.
The `head.S` code that would capture a firmware DTB (`fw_passed_dtb`, `head.S:29-35, 56-59`)
is therefore vestigial for this board.

If you *did* switch to a bootloader-provided DTB, the U-Boot side already has one:
`la32r-uboot/arch/la32r/dts/la32rsoc_demo.dts` with
`configs/la32rsoc_defconfig:441` — `CONFIG_DEFAULT_DEVICE_TREE="la32rsoc_demo"`,
`:438` `CONFIG_OF_EMBED=y`, `:434` `CONFIG_OF_CONTROL=y`, `:44` `CONFIG_LA32R_BOOT_FDT=y`.
So the pair would be **`la32rsoc_demo.dtb` (U-Boot) → `loongson32_ls.dtb` (kernel)**.

**For the RV32-GC port:** put a single `chiplab.dts` under
`arch/riscv/boot/dts/<vendor>/`, add it to a `Makefile` with `dtb-$(CONFIG_SOC_CHIPLAB)`, and
mirror the builtin-DTB mechanism (or rely on a U-Boot-passed FDT). Do **not** carry over the
`BUILTIN_DTB_NAME`-vs-`#ifdef` inconsistency from `arch/loongarch`.

---

## 11. NAND driver deep dive

### 11.1 Register map — NAND controller (`base + offset`, 32-bit registers)

**Base:** `0x1fe78000` physical. Accessed in-tree as `0x9fe78000` (KSEG0 alias) and via
`ioremap()` of the DT resource. **Register offsets are the field offsets of
`struct ls1a_nand_desc`** (`ls1a_nand.c:175-185`), corroborated by the `_NAND_*` macros
(`:84-91`).

| Off | Reg | R/W | Written by | Value / notes |
|---|---|---|---|---|
| `0x00` | `CMD` | RW + RO | `nand_setup():596`, `write_z_cmd:497-501`, `_NAND_SET_REG(0x0,0x21)` (`:842`,`:851`) | control bitfield (§11.2); **bit 10 = DONE**, polled by `ls1a_nand_status()` (`:493-496`) |
| `0x04` | `ADDRL` | RW | `nand_setup():597` | for READ0/SEQIN: `SPARE_ADDRL(page) [+ column]`; for READOOB: `SPARE_ADDRL(page) + writesize`; for ERASE: `NO_SPARE_ADDRL(page) = 0` (LS232) |
| `0x08` | `ADDRH` | RW | `nand_setup():599` | `SPARE_ADDRH(page) = page` (LS232: identity macro, `:35`) |
| `0x0c` | `TIMING` | RW | `nand_setup():601`; `_NAND_TIMING_TO_{READ,WRITE}` = `0x205` (`:90-91`) | default `info->nand_timing = 0x412` (`:921`); LS1B01 path uses `0x30f0` (`:841`) |
| `0x10` | `IDL` | RO | — | `_NAND_IDL`; NAND ID bytes 1–4 (big-endian within the word) |
| `0x14` | `IDH` | RO | — | `_NAND_IDH`; ID byte 0 (maker) in `[7:0]`, **NAND status in `[31:16]`** (`ls1a_nand_waitfunc():317`) |
| `0x18` | `PARAM` | RW | `:910` → `0x08005300`; `:1123` (resume) → `0x400`; RMW in `nand_setup():605` | `param = (param & 0xc000ffff) \| (op_num << 16)` — i.e. `op_num` is mirrored into `[21:16]` |
| `0x1c` | `OP_NUM` | RW | `nand_setup():603` | transfer byte count (2112 for READ0, 64 for READOOB, staged bytes for PAGEPROG) |
| `0x20` | `CS_RDY_MAP` | RW | `nand_setup():604` | `info->nand_cs_rdy_map = 0x88442200` (`:925`) |
| `0x40` | *DMA data port* | RW | DMA engine | `DMA_ACCESS_ADDR = 0x1fe78040` (`:18`) — the DMA descriptor's `daddr` |

**`CMD` (0x00) bitfield — `struct ls1a_nand_cmdset` (`ls1a_nand.c:126-154`):**

```c
126: struct ls1a_nand_cmdset {
127:         uint32_t    cmd_valid:1;	//0     start the operation
128: 	uint32_t    read:1;		//1     read from NAND
129: 	uint32_t    write:1;		//2     write to NAND
130: 	uint32_t    erase_one:1;	//3     erase one block
131: 	uint32_t    erase_con:1;	//4     erase continuous
132: 	uint32_t    read_id:1;		//5     read device ID
133: 	uint32_t    reset:1;		//6     reset the chip
134: 	uint32_t    read_sr:1;		//7     read status register
135: 	uint32_t    op_main:1;		//8     operate main area
136: 	uint32_t    op_spare:1;		//9     operate spare area
137: 	uint32_t    done:1;		//10    RO: operation finished (POLLED)
138: #if defined(CONFIG_MACH_LS1A) || defined(CONFIG_MACH_LS232)
139: 	uint32_t    ecc_rd:1;		//11    enable HW ECC on read
140: 	uint32_t    ecc_wr:1;		//12    enable HW ECC on write
141: 	uint32_t    int_en:1;		//13    interrupt enable
142: 	uint32_t    resv14:1;		//14
143: 	uint32_t    ram_op:1;		//15    internal RAM operation
144: #elif CONFIG_MACH_LS1B
145: 	uint32_t    resv1:5;            //11-15 reserved
146: #endif
147:         uint32_t    nand_rdy:4;         //16-19 NAND ready bits
148:         uint32_t    nand_ce:4;          //20-23 NAND chip-enable
149: #if defined(CONFIG_MACH_LS1A) || defined(CONFIG_MACH_LS232)
150: 	uint32_t    ecc_dma_req:1;         //24
151: 	uint32_t    nul_dma_req:1;         //25
152: #endif
153:         uint32_t    resv26:8;           //26-31 reserved
154: };
```

### 11.2 DMA register map — external engine (`0x1fd01160` physical / `0x9fd01160` in code)

| Address | Meaning |
|---|---|
| `0x1fd01160` | DMA **order/doorbell** register. Write `descriptor_phys \| (1<<3)` to start; poll until **bit 3 clears** (`dma_setup():570-571`) |
| `0x1fe78040` | DMA **data port** — the transfer's device-side terminus (descriptor `daddr`) |

**Descriptor block** (32 bytes, in a `dma_alloc_coherent` buffer, `struct ls1a_nand_dma_desc`):

| Off | Field | Value used |
|---|---|---|
| `0x00` | `orderad` | `0` (`:928`) |
| `0x04` | `saddr` | `data_buff_phys` (`:929`) — the RAM bounce buffer |
| `0x08` | `daddr` | `0x1fe78040` (`:930`) — the controller data port |
| `0x0c` | `length` | `ALIGN_DMA(buf_count)` = bytes/4, i.e. **word count** (`:664`, `:699`, `:750`) — `#define ALIGN_DMA(x) (((x)+3)/4)` (`:39`) |
| `0x10` | `step_length` | `0` (`:932`) |
| `0x14` | `step_times` | `1` (`:933`) |
| `0x18` | `cmd` | §11.3 |

**DMA command word** (`struct ls1a_nand_dma_cmd`, `:164-174`):

| Bit | Field | Set by the driver |
|---|---|---|
| 0 | `dma_int_mask` | **`1`** in every transfer (`:665`, `:700`, `:751`) — interrupts masked |
| 1 | `dma_int` | RO status |
| 2 | `dma_sl_tran_over` | RO status |
| 3 | `dma_tran_over` | RO status |
| 4–7 | `dma_r_state` | RO status |
| 8–11 | `dma_w_state` | RO status |
| **12** | **`dma_r_w`** | **`1` for PAGEPROG only** (`:752`) — "memory → NAND". Also the cache-flush condition at `:562` |
| 13–14 | `dma_cmd` | 0 |
| 15–31 | `revl` | 0 |

### 11.3 Complete command → register/transfer trace

| NAND op | `ADDRL` / `ADDRH` | `OP_NUM` | DMA | `CMD` bits set | Poll |
|---|---|---|---|---|---|
| `READ0` (`:670`) | `0` / `page` | `oobsize+writesize` = 2112 | `length=528`, `dma_r_w=0`, daddr=`0x1fe78040` | `int_en, read, op_spare, op_main, cmd_valid`; ECC off | DONE×60, `udelay(1)`, then `dma_cache_inv` |
| `READOOB` (`:634`) | `writesize` / `page` | `oobsize` = 64 | `length=16`, `dma_r_w=0` | `int_en, read, op_spare, cmd_valid`; ECC off | DONE×60 |
| `SEQIN` (`:704`) | — (deferred) | — | none | none — only latches `seqin_column`/`seqin_page_addr` | completes immediately |
| `PAGEPROG` (`:716`) | `+seqin_column` / `seqin_page_addr` | `buf_start` | `length=buf_start/4`, **`dma_r_w=1`** | `int_en, write, op_spare, (op_main if column < writesize), cmd_valid`; ECC off | DONE×400, `udelay(2)`, flush before |
| `ERASE1` (`:780`) | `0` / `page` | — | **none** | `int_en=0, erase_one, cmd_valid`; `ram_op=off` | `udelay(2000)` then DONE×100, `udelay(50)` |
| `RESET` (`:756`) | — | — | none | `int_en=0, reset, cmd_valid` | DONE×60, `udelay(50)` |
| `STATUS` (`:812`) | — | — | none | none — **synthesised in software** | none |
| `READID` (`:824`) | — | — | none | writes `0x21` to `0x9fe78000` | `udelay(1)` |
| `RNDOUT` (`:870`) | — | — | none | only `info->buf_start = column` | none |

Polling constants: `STATUS_TIME_LOOP_R=60`, `_WS=400`, `_WM=60`, `_E=100`
(`:54-57`); `CHIP_DELAY_TIMEOUT (2*HZ/10)` (`:52`).

### 11.4 `nand_setup()` — how a register write happens

```c
591: static void nand_setup(unsigned int flags ,struct ls1a_nand_info *info)
592: {
593:     int i,val1,val2,val3;
594:     struct ls1a_nand_desc *nand_base = (struct ls1a_nand_desc *)(info->mmio_base);
595:
596:     nand_base->cmd = 0;
597:     nand_base->addrl = (flags & NAND_ADDRL)==NAND_ADDRL ? info->nand_regs.addrl: info->nand_addrl;
599:     nand_base->addrh = (flags & NAND_ADDRH)==NAND_ADDRH ? info->nand_regs.addrh: info->nand_addrh;
601:     nand_base->timing = (flags & NAND_TIMING)==NAND_TIMING ? info->nand_regs.timing: info->nand_timing;
603:     nand_base->op_num = (flags & NAND_OP_NUM)==NAND_OP_NUM ? info->nand_regs.op_num: info->nand_op_num;
604:     nand_base->cs_rdy_map = (flags & NAND_CS_RDY_MAP)==NAND_CS_RDY_MAP ? info->nand_regs.cs_rdy_map: info->nand_cs_rdy_map;
605:     nand_base->param = ((nand_base->param) & 0xc000ffff) | (nand_base->op_num << 16);
609:     if(flags & NAND_CMD){
610:             nand_base->cmd = (info->nand_regs.cmd) & (~0xff);
611:             nand_base->cmd = info->nand_regs.cmd;
612:     }
613:     else
614:         nand_base->cmd = info->nand_cmd;
616:     show_status_regs(nand_base);
617: }
```

Two-phase design: a **shadow** struct (`info->nand_regs`) is filled per command, and `nand_setup()`
copies the fields selected by `flags` into the real MMIO registers. Note the double assignment at
`:610-611` (the `& ~0xff` write is immediately overwritten) and the RMW of `PARAM` at `:605`,
which **clears bits not in `0xc000ffff`** — so the `0x08005300` written at `:910` loses bit 27
(`0x08000000`) on the first command. Worth understanding before you trust the `PARAM` value.

### 11.5 Register-map summary card (for the U-Boot port)

```
NAND controller @ 0x1fe78000  (0x9fe78000 aliased), 0x4000 bytes declared
  0x00 CMD      : [0]=cmd_valid [1]=read [2]=write [3]=erase_one [4]=erase_con
                  [5]=read_id [6]=reset [7]=read_sr [8]=op_main [9]=op_spare
                  [10]=DONE(RO,poll) [11]=ecc_rd [12]=ecc_wr [13]=int_en
                  [15]=ram_op [19:16]=nand_rdy [23:20]=nand_ce
                  [24]=ecc_dma_req [25]=nul_dma_req
  0x04 ADDRL    : column | (spare starts at +writesize)
  0x08 ADDRH    : page / block
  0x0C TIMING   : 0x205 (rw), 0x412 default, 0x30f0 (LS1B01 ID path)
  0x10 IDL      : RO  ID bytes [31:24][23:16][15:8][7:0] = ID1..ID4
  0x14 IDH      : RO  [7:0]=ID0 (maker), [31:16]=NAND status
  0x18 PARAM    : 0x08005300 init; [21:16] mirrors OP_NUM
  0x1C OP_NUM   : byte count of the transfer
  0x20 CS_RDY_MAP: 0x88442200
  0x40          : DMA data port  (DMA_ACCESS_ADDR 0x1fe78040)

DMA engine doorbell @ 0x1fd01160   (code uses 0x9fd01160)
  write  desc_phys | (1<<3);  poll until bit3 == 0

DMA descriptor (32 B, in DRAM; must be 32-byte-aligned-ish and flushed)
  +0x00 orderad (=0)  +0x04 saddr (=buffer phys)  +0x08 daddr (=0x1fe78040)
  +0x0C length (WORDS) +0x10 step_length (=0) +0x14 step_times (=1) +0x18 cmd
  cmd: [0]=int_mask(1) [12]=dir(1=mem->NAND) rest status/reserved
```

---

## 12. Porting surface — file path → what must change for RV32-GC

Legend: **[R]** reuse nearly as-is · **[P]** port/adapt · **[N]** write new · **[X]** do not port

### 12.1 Architecture and boot

| Path | Action | What must change |
|---|---|---|
| `arch/riscv/**` | **[R]** | Base of the port. Already upstream 5.14-rc2 with `ARCH_RV32I`, Sv32, ilp32. |
| `arch/loongarch/**` | **[X]** | Reference only. Do not attempt to convert — the CSR/exception/MMU model is entirely different. |
| `arch/loongarch/kernel/head.S` | **[X]** | Entry sets `DMWIN0=0xa0000011`, `DMWIN1=0x80000001`, `CRMD=0xb0` (LoongArch direct-map windows + paging). RISC-V equivalent is `arch/riscv/kernel/head.S` with `satp`/Sv32 — **no DMW concept**. |
| `arch/loongarch/kernel/{entry.S,genex.S,traps.c}` | **[X]** | LoongArch `ECODE`/`ERA`/`BADV`/`TICLR` exception model. RISC-V uses `scause`/`sepc`/`stval` (`arch/riscv/kernel/{entry.S,traps.c}`). |
| `arch/loongarch/include/asm/loongarchregs.h` | **[X]** | LoongArch CSR numbers/fields (`CRMD`, `ECFG`, `ESTAT`, `TCFG`, `TVAL`, `DMWIN*`). RISC-V uses `arch/riscv/include/asm/csr.h`. |
| `arch/loongarch/kernel/cmdline.c` + `head.S:47-59` | **[P]** | MIPS-style `a0=argc, a1=argv, a2=envp` (with `a0==-2` ⇒ `a1`=DTB). RISC-V convention is `a0=hartid, a1=dtb`; use `arch/riscv/kernel/head.S` + `setup.c` (`boot_command_line` from the DT `/chosen/bootargs`). |
| `arch/loongarch/Kconfig` (`BUILTIN_DTB`, `BUILTIN_DTB_NAME`) | **[P]** | `arch/riscv/Kconfig:544` already has `BUILTIN_DTB`; add `select BUILTIN_DTB` to the new SoC symbol and mirror `arch/loongarch/boot/dts/Makefile`'s pattern. |

### 12.2 Platform / drivers

| Path (LA32R) | Action | RV32-GC work |
|---|---|---|
| `arch/loongarch/loongson32/Platform` | **[N]** | Create `arch/riscv/mach-chiplab/` (or `arch/riscv/platforms/`) + Kconfig `SOC_CHIPLAB`, `select`ing the timer/IRQ/reset drivers; add to `arch/riscv/Makefile` `core-y`. |
| `arch/loongarch/loongson32/irq.c` + `drivers/irqchip/irq-loongarch-cpu.c` | **[N]** | 78-line driver using `ECFG`/`ESTAT` CSRs and `set_vi_handler`. Replace with: (a) a PLIC driver if the FPGA has one (`SIFIVE_PLIC`), or (b) a new `drivers/irqchip/irq-chiplab.c` mirroring the 6-register `irq-ls1x.c` layout. Timer/PI must use CLINT (`mtimecmp`, `msip`) or SBI. |
| `arch/loongarch/kernel/time.c` (`drdtime()`, `LOONGSON_TIMER_IRQ=27`, `TCFG/TVAL/TICLR`) | **[N]** | New clocksource/clockevent. Option A: `CONFIG_CLINT_TIMER` (`riscv,timer`, as `SOC_VIRT` does). Option B: `drivers/clocksource/` driver for the chiplab confreg `TIMER_ADDR` at `0x1fafe000`. Wire IRQ to `riscv,cpu-intc`/PLIC. |
| `arch/loongarch/loongson32/serial.c` | **[X]** | **Broken** (memset after setup, `serial.c:44-60`). Do not port. |
| `arch/loongarch/loongson32/uart_base.c` | **[X]** | Replaced by the DTS `ns16550a` node. |
| *DTS `cpu_uart0` node* | **[R]** | `compatible="ns16550a"`, `reg=<0x1fe001e0 0x10>`, `clock-frequency=<33000000>` transfer verbatim; only `interrupt-parent`/`interrupts` change. |
| `arch/loongarch/loongson32/early_printk.c` | **[P]** | Replace with `earlycon=uart8250,mmio,0x1fe001e0` + `CONFIG_SERIAL_EARLYCON`; delete the custom `prom_putchar()`. |
| `arch/loongarch/loongson32/reset.c` | **[N]** | Currently `while(1) __arch_cpu_idle()` — no real reset. Add `syscon-reboot`/`syscon-poweroff` against `0x1faf_0000` (chiplab confreg), or a small `drivers/power/reset/` driver + `CONFIG_POWER_RESET`. |
| `arch/loongarch/mm/cache.c`, `include/asm/cacheflush.h` | **[X]** | Guarded by `#ifdef BX_SOC` **without** the `CONFIG_` prefix, so `flush_cache_*`/`flush_dcache_*` are no-ops on LA32R. Do not copy this behaviour — on RV32-GC use `Zicbom` (`cbo.clean/inval/flush`) or `fence.i` as appropriate, and verify cache maintenance explicitly. |
| `arch/loongarch/loongson32/{setup.c,prom.c,env.c,mem.c,smp.c,dma-noncoherent.c}` | **[N]/[P]** | Rewrite as an `arch/riscv` SoC: memory map from DT (`/memory`), `mem.c`'s "reserve first 2 MiB" logic re-expressed, **SMP is new work** (the LA32R port has none — but `arch/riscv` already supports SMP, so use `arch/riscv/kernel/{smp.c,smpboot.c,cpu_ops*.c}` + CLINT IPI), DMA coherency via `Zicbom` or a non-cacheable window. |
| `drivers/irqchip/irq-ls1x.c` | **[R]** | Arch-independent (uses `readl`/`writel` + irqchip-generic). Reusable if you instantiate it from an RV32 DTS — only needed if the FPGA exposes this 6-register block. |
| `chiplab/IP/CONFREG/confreg_*.v` | **[N]** | No kernel driver exists. Write one for LED (`0x1faff020`), sim-exit/`io_simu` (`0x1fafff00`), `num_monitor` (`0x1fafff40`), and optionally the `TIMER` at `0x1fafe000`. |

### 12.3 The NAND driver — the main event

| Path / element | Action | What must change |
|---|---|---|
| `drivers/mtd/nand/raw/ls1a_nand.c` | **[P]** | The **algorithm and register map are reusable**; the *address handling, cache ops and DMA plumbing are not*. Keep `ls1a_nand_cmdfunc()`'s command traces (§11.3); rewrite the rest. |
| `:86` `_NAND_BASE 0x9fe78000`, `:84-85` `_NAND_IDL/_NAND_IDH`, `:495`, `:498-501`, `:910`, `:1123`, `:468` | **[P]** | **Replace every hardcoded `0x9fe78xxx` with the `ioremap()`ed base** from `platform_get_resource()`. RISC-V has no KSEG0 alias — `0x9fe78000` is not a valid address. |
| `:988` `info->drcmr_dat = 0xa0000000 \| info->drcmr_dat;` | **[P]** | **Remove.** The `0xa0000000` KSEG1 alias does not exist on RISC-V. Use `dma_alloc_coherent()`/`dma_map_single()` semantics and pass real physical addresses to the DMA engine. |
| `:19` `ORDER_REG_ADDR 0x9fd01160` | **[P]** | Must become an `ioremap()` of the DMA doorbell (physical `0x1fd01160`), ideally taken from DT resource #1 (already present in `loongson32_ls.dts:84`). |
| `:563-565`, `:646`, `:681`, `:881-882` — `dma_cache_wback()`, `dma_cache_wback_inv()`, `dma_cache_inv()` | **[P]** | Loongson-specific cache primitives. On RISC-V use `Zicbom` (`cbo.clean`/`cbo.inval`/`cbo.flush`) via `arch/riscv/mm/cacheflush.c` + `dma_sync_single_for_{device,cpu}()`, or map the buffers non-cacheable. **This is the #1 correctness risk.** |
| `:446` `ecc.engine_type = NAND_ECC_ENGINE_TYPE_NONE`; `:657-658, 691-692, 741-742` `ecc_rd/ecc_wr = OFF`; `:285-307` stub callbacks | **[P]** | Decide the ECC policy. The controller *has* ECC (`CMD[11]`, `CMD[12]`, `CMD[24]`); the layout in `:241-248` (24 bytes at spare 40–63, `oobfree {2,38}`) is the only in-tree spec. Enable it, or enable `NAND_ECC_ENGINE_TYPE_SOFT` + `MTD_NAND_ECC_SW_BCH` (already `=y`), or accept ECC-less operation knowingly. |
| `:430` `this->options = NAND_CACHEPRG` | **[P]** | Verify whether the controller supports `CACHEPRG`/`NAND_CMD_CACHEDPROG`; if not, drop the flag. |
| `:432-439` `->legacy.*` callbacks | **[P]** | Legacy raw-NAND API. Consider migrating to `->exec_op()` (`nand_op_parser`) — the controller's register model maps cleanly onto `NAND_OP_CMD/ADDR/DATA_IN/DATA_OUT` instrs, and `exec_op` is the supported path in 5.14+. |
| `:888` `ls1a_nand_detect()` geometry gate (128 KiB / 2 KiB / 64 B) | **[P]** | Either relax it or guarantee the FPGA-populated NAND matches. Verify against the actual part on the board. |
| `:106-119` `lart_partitions[]` (21 MiB / 35 MiB) | **[P]** | **Resolve the 3-way conflict** (§4.8). Recommended: `mtd_device_parse_register()` with `cmdlinepart` (`CONFIG_MTD_CMDLINE_PARTS=y` is already set) so the bootloader's `mtdparts=` wins; or DT partitions. Delete the hardcoded table. |
| `:1053-1076` `#ifdef CONFIG_MTD_PARTITIONS` | **[P]** | `CONFIG_MTD_PARTITIONS` no longer exists; the whole `#ifdef` is dead code. Replace with `mtd_device_parse_register()`. |
| `:1028` `devm_request_irq(..., UMH_DISABLED, ...)` | **[P]** | `UMH_DISABLED` is not an IRQ flag. Either drop the IRQ (the driver is polled via `USE_POLL`) or use correct `IRQF_*` flags and make the handler real. |
| `:16` `#define CONFIG_MACH_LS232 1` and `:41-50` `USE_POLL` macros | **[P]** | Remove the fake `CONFIG_MACH_*` defines; express variant selection in Kconfig/DT (`compatible = "loongson,ls1a-nand"` vs a new `"chiplab,nand"`). Decide polled vs IRQ-driven explicitly. |
| `:1131` `.compatible = "ls1a-nand"` | **[P]** | Add a proper vendor prefix for the new binding (e.g. `"chiplab,ls1a-nand"`) and a `Documentation/devicetree/bindings/mtd/` YAML. |
| `drivers/mtd/nand/raw/Kconfig:49-52`, `Makefile:5` | **[P]** | Add/adjust the `MTD_NAND_LS1A` symbol (or a new `MTD_NAND_CHIPLAB`) and its `obj-` line. |
| `arch/loongarch/boot/dts/loongson/loongson32_ls.dts:70-100` | **[P]** | Un-`#if 0` and move the node into the new RV32 DTS. **Use the LS `reg` values** (`<0x1fe78000 0x4000 0x1fd01160 0x0>`); the BX values are all zeros. Fix `interrupt-parent`/`interrupts` for the RISC-V interrupt controller. |
| **U-Boot side:** `la32r-uboot/drivers/mtd/nand/raw/` (new file), `board/nscscc/`, `arch/la32r/` | **[N]** | `la32rsoc_defconfig` has `# CONFIG_MTD is not set`, `# CONFIG_NAND is not set`, `# CONFIG_CMD_NAND is not set`. Port §11's register map into a U-Boot raw-NAND driver (`CONFIG_SYS_NAND_SELF_INIT` + `nand_chip`/`mtd`), add `CONFIG_NAND`, `CONFIG_CMD_NAND`, `CONFIG_CMD_MTDPARTS`, `CONFIG_SYS_NAND_BASE`, and a `board_nand_init()` in `board/nscscc/2019/`. The DMA descriptor + `dma_cache_*` work is the same on LA32R and RV32 (see §12.2 caveats). |

### 12.4 Config / DTS artefacts to create

| New artefact (suggested) | Derived from |
|---|---|
| `arch/riscv/configs/rv32_chiplab_defconfig` | `arch/riscv/configs/rv32_defconfig` + `arch/loongarch/configs/la32_defconfig` |
| `arch/riscv/boot/dts/<vendor>/chiplab.dts` (+ `Makefile`) | `arch/loongarch/boot/dts/loongson/loongson32_ls.dts` |
| `arch/riscv/Kconfig.socs` entry `config SOC_CHIPLAB` | `arch/riscv/Kconfig.socs` (`SOC_VIRT`/`SOC_CANAAN` style) |
| `arch/riscv/mach-chiplab/` (or platform dir) | `arch/loongarch/loongson32/{setup,irq,mem}.c` |
| `drivers/irqchip/irq-chiplab.c` (if no PLIC) | `drivers/irqchip/irq-ls1x.c` |
| `drivers/clocksource/timer-chiplab.c` (if no CLINT) | confreg `TIMER_ADDR 0x1fafe000` + `arch/loongarch/kernel/time.c` |
| `drivers/power/reset/chiplab-*.c` | chiplab confreg `0x1faf_0000` (nothing to copy — new) |
| `drivers/mtd/nand/raw/ls1a_nand.c` (RV32 version) | this file, per §12.3 |

### 12.5 Things that **do not** need changing

* The MTD/raw-NAND core (`drivers/mtd/nand/{core.c,bbt.c,ecc*.c}`, `raw/nand_*.c`) — arch-independent.
* `drivers/tty/serial/8250/*` + `8250_of` — arch-independent; DTS-driven.
* `drivers/mtd/mtdpart.c` / `cmdlinepart` / `ofpart` — arch-independent.
* The overall DTS *structure* (memory/soc/uart/nand) — only the interrupt controller, timer and CPU nodes are RISC-V-specific.
* The build/load *workflow* (ELF via TFTP, `bootelf`, builtin DTB) — conceptually identical; only the toolchain prefix (`riscv32-unknown-linux-gnu-` / `riscv64-unknown-elf-` with `-march=rv32gc`) and the image name (`vmlinux` ELF, or `arch/riscv/boot/Image`) differ.

---

## 13. Uncertainties / things to verify

Ordered by how much damage a wrong assumption would do.

1. **ECC register semantics (HIGH).** The controller's ECC bits (`CMD[11] ecc_rd`, `CMD[12] ecc_wr`,
   `CMD[24] ecc_dma_req`) are **never exercised by this driver** (always written 0). The 24-byte /
   spare-40–63 layout in `hw_largepage_ecclayout` (`:241-248`) is declared but never installed
   (`:452`). Whether the hardware ECC is (a) 4-bit or 8-bit BCH, (b) computed over 512-byte or
   2048-byte chunks, (c) auto-written on program or requires a separate step, and (d) how many ECC
   bytes per chunk — **all unknown from this tree**. Get the LS1A/LS232 datasheet or read
   `chiplab/IP/` for the NAND controller RTL before enabling ECC. If you cannot, keep ECC off and
   accept the same behaviour the LA32R kernel has.

2. **`PARAM` (0x18) semantics (HIGH).** Written `0x08005300` at init (`:910`) and `0x400` on resume
   (`:1123`), but the RMW at `:605` (`& 0xc000ffff`) destroys bit 27 on the first command. What
   `PARAM` actually controls (page size? ECC config? timing multiplier? CS count?) is undocumented
   in-tree. Bit 27 may be a real configuration bit that this driver silently clears — a strong
   candidate for a "works on LA32R but not on your port" bug.

3. **DMA coherency on the FPGA (HIGH).** The driver relies on `dma_cache_wback`/`dma_cache_inv`
   with `info->cac_size`, plus the `0xa0000000` alias, plus `dma_alloc_coherent`. Does the chiplab
   FPGA actually have a coherent DMA path, or does it need manual cache maintenance? Is the D-cache
   enabled for the descriptor/bounce buffers? On RV32-GC you must decide between `Zicbom` block
   ops, a non-cacheable mapping, or an uncached buffer alias in your address map. Verify with a
   known-good NAND read of a known pattern before trusting writes.

4. **The three-way partition conflict (§4.8).** 21 MiB vs 50 MiB rootfs offset; 56 MiB vs 128 MiB
   total. Since `CONFIG_MTD_PARTITIONS` is dead, the *kernel* currently uses 21 MiB/35 MiB — but
   the *documented PMON flow* writes the kernel to a 50 MiB `mtd0`. These cannot both be right.
   Determine which layout the shipped flash image actually uses.

5. **NAND part identity and geometry.** `ls1a_nand_detect()` hard-requires 128 KiB erase / 2048 B
   page / 64 B OOB (`:888`). Confirm the actual chip on the board; if it differs, the driver
   hard-fails at probe with "driver don't support the Flash!". Also `nand_scan_with_ids(this, 1,
   NULL)` autodetects via READID — confirm the READID reassembly (`:856-860`, ID0 from `IDH[7:0]`,
   ID1–ID4 big-endian from `IDL`) matches the real part.

6. **RV32 `f`/`d` context-switch correctness (MEDIUM-HIGH, RV32-GC specific).**
   `CONFIG_FPU` has no `64BIT` dependency (`arch/riscv/Kconfig:374-379`), but this is upstream
   5.14-rc2 RV32 code that was primarily exercised on RV64. Verify `fcsr`/`f0-f31` save-restore
   (`arch/riscv/kernel/fpu.S`), `mstatus.FS` handling, and signal-frame layout (`ptrace`,
   `signal.c`, `asm-offsets`) on RV32 with `d` registers. Also check whether your `rv32gc` build
   needs `-mabi=ilp32d` and whether the kernel's own build is `ilp32` (soft-float ABI) — mixing
   them across the kernel/initramfs boundary is a classic failure.

7. **The `arch/riscv` tree's pristine state.** It looks exactly like upstream 5.14-rc2, but the
   repo has only one squashed commit, so I **could not diff it against vanilla 5.14-rc2** to prove
   it is unmodified. Before relying on it, compare a few files against upstream (or just
   `git clone --depth=1 -b v5.14-rc2` and diff `arch/riscv/`).

8. **`READ STATUS` result looks wrong (MEDIUM).** `NAND_CMD_STATUS` returns
   `ls1a_nand_status() | 0x80` (`:820`) — i.e. `0x80` or `0x480`. In Linux's convention
   `NAND_STATUS_READY = 0x40`, so bit 6 is **never** set, which would read as "not ready".
   Real status waits go through `waitfunc` (`:312-322`), which returns `_NAND_IDH >> 16` for
   `CONFIG_MACH_LS232`. Confirm which path `nand_base` uses for this chip and whether the READ
   STATUS emulation matters.

9. **`ls1a_nand_waitfunc` returns `_NAND_IDH>>16` (MEDIUM).** That is `0x9fe78014`'s upper half
   used as the NAND status byte. Verify the bit positions match the chip's status byte
   (bit0 fail, bit6 ready) — a shift mismatch would break all ready-polling on the RV32 port.

10. **IRQ routing on chiplab (MEDIUM).** The DTS NAND node says
    `interrupt-parent = <&cpuic>; interrupts = <4>;` → virq 20, while `irq.c`'s dispatch only
    handles `ESTAT` bits for IP0–IP3/IPI/PC and `irq.c:19-35` never routes a NAND IRQ. With
    `USE_POLL` this is moot, but if you make the port interrupt-driven, the NAND IRQ must be wired
    into the new controller and the handler made real.

11. **`serial.c`'s zeroed port (LOW, but confusing).** `serial.c:56` memsets the port *after*
    populating it, so a bogus all-zero `serial8250` device is registered. The console works via
    `8250_of` + DTS. Confirm no RV32 port inherits this.

12. **Timer frequency for the *new* RV32 timer (MEDIUM) — the LA32R side is now settled.**
    The LA32R value is a **hardcoded 200 MHz for `CONFIG_LS_SOC`** (chiplab) at
    `arch/loongarch/include/asm/time.h:40-49`, with `HZ=250`; the DTS `clock-frequency =
    <33000000>` applies to the **UART only**. What remains open is your **RV32-GC** side: you must
    establish the real timer frequency of the FPGA design — `mtime`/`CNTFRQ` if you instantiate a
    CLINT, or the confreg `TIMER_ADDR` at `0x1fafe000` (§7) — and it must agree with what the
    bootloader assumes. A mismatch here produces a kernel that boots and then runs at the wrong
    wall-clock speed rather than failing loudly.

13. **Which `MAX_BUFF_SIZE` / `cac_size` invariants hold (LOW-MEDIUM).** `MAX_BUFF_SIZE = 4096`
    (`:20`) while a full page+OOB is 2112 bytes and the *descriptor* shares the same allocation
    (`drcmr_dat` is a separate 4096-byte allocation, `data_buff` another). Confirm the DMA engine
    never overruns a step and that `ALIGN_DMA()`'s word-count convention (`:39`) is what the
    hardware expects — a bytes-vs-words mistake here would silently corrupt transfers.

14. **`interrupts = <4>` / `extioi` dead nodes.** `loongson32_ls.dts` declares an
    `extioiic` with `"loongson,extioi-interrupt-controller"` but **no `IRQCHIP_DECLARE` for that
    compatible exists** in `drivers/irqchip/`. It is dead DT — do not treat it as documentation of
    a working controller.

15. **The BX DTS NAND `reg` is all zeros** (`loongson32_bx.dts:120-121`). If you ever build for
    the full-flow SoC, fix it; do not copy it.

16. **Toolchain ambiguity (§8.2).** `README.md` says `loongarch32r-linux-gnusf-` (GCC 8.3 v2.0),
    `la_build.sh` says `loongarch32-linux-gnu-`. Only one produces a kernel that boots the
    documented way; establish which before using the LA32R build as a reference oracle.

---

## Appendix A — one-page fact sheet

```
Kernel ................ Linux 5.14.0-rc2 (single squashed git commit 4ed7b98e08e8; no tags;
                        branch la32r-new-world; shallow --depth=1 clone)
Arch (LA32R) .......... arch/loongarch   ARCH=loongarch
Machine ............... MACH_LOONGSON32 + MACH_LOONGSON_32 + LS_SOC   (chiplab = "loongson-soc")
SMP ................... IMPOSSIBLE on this arch port (no SYS_SUPPORTS_SMP; NR_CPUS=1; smp.c empty)
Defconfig ............. arch/loongarch/configs/la32_defconfig
DTS ................... arch/loongarch/boot/dts/loongson/loongson32_ls.dts
DTB name .............. loongson32_ls.dtb   (CONFIG_LS_SOC; BUILTIN_DTB=y, symbol __dtb_loongson32_ls_begin)
Toolchain ............. loongarch32r-linux-gnusf-     (GCC 8.3, v2.0)
Build ................. make la32_defconfig && make -j$(nproc) && loongarch32r-linux-gnusf-strip vmlinux
Image ................. ./vmlinux — stripped 32-bit ELF, ENTRY(kernel_entry), link addr 0xa0300000
                        (NO vmlinux.bin/Image/uImage: arch/loongarch/boot/Makefile is absent)
Load .................. TFTP + PMON `g`, or U-Boot `bootelf 0xa3000000 <env-var-with-cmdline>`
Memory (chiplab) ...... 128 MiB @ 0x00000000   (DTS /memory; first 2 MiB reserved by mem.c)
UART .................. ns16550a @ 0x1fe001e0, 33 MHz, IRQ 3 (cpuic) | 115200n8
Timer ................. LoongArch constant timer CSR (TCFG/TVAL/TINTCLR, drdtime); IRQ 27;
                        arch/loongarch/kernel/time.c; freq HARDCODED 200 MHz for LS_SOC
                        (arch/loongarch/include/asm/time.h:40-49); HZ=250
INTC .................. "loongson,cpu-interrupt-controller" (ECFG/ESTAT), virq = 16 + hwirq
NAND driver ........... drivers/mtd/nand/raw/ls1a_nand.c  (CONFIG_MTD_NAND_LS1A, "ls1a-nand")
NAND controller ....... 0x1fe78000 (code uses 0x9fe78000): CMD/ADDRL/ADDRH/TIMING/IDL/IDH/
                        PARAM/OP_NUM/CS_RDY_MAP at 0x00..0x20; DMA data port 0x1fe78040
DMA ................... descriptor-based external engine; doorbell 0x1fd01160 (write desc|8, poll bit3)
ECC ................... DISABLED (ecc_rd/ecc_wr = 0; NAND_ECC_ENGINE_TYPE_NONE; stub callbacks)
                        declared-but-unused layout: 24 ECC bytes at spare 40..63, oobfree {2,38}
NAND geometry ......... 128 KiB erase / 2048 B page / 64 B OOB  (hard gate in ls1a_nand_detect)
NAND partitions ....... driver: "kernel" 21 MiB @0, "file system" 35 MiB @21 MiB  (hardcoded)
                        docs:   mtdparts nand-flash:50M@0(kernel)ro,-(rootfs)     <-- CONFLICT
                        DTS:    kernel_partition 20 MiB @0, os_partition rest     <-- unused (#if 0)
DT node state ......... NAND node is #if 0 in BOTH DTS files -> cannot bind as shipped
Rootfs ................ built-in initramfs/ramfs; CONFIG_INITRAMFS_SOURCE="" (must be set)
RISC-V support ........ arch/riscv = upstream 5.14-rc2, ALREADY SUPPORTS RV32:
                        CONFIG_ARCH_RV32I (selects 32BIT + MMU/Sv32), -mabi=ilp32,
                        UTS_MACHINE=riscv32, arch/riscv/configs/rv32_defconfig,
                        CONFIG_FPU available on RV32, CONFIG_BUILTIN_DTB available
chiplab confreg ....... 0x1faf_0000 base (RTL only; NO kernel driver): LED 0x1faff020,
                        NUM 0x1faff050, SWITCH 0x1faff060, TIMER 0x1fafe000,
                        IO_SIMU 0x1fafff00, SIMU_FLAG 0x1fafff20, NUM_MONITOR 0x1fafff40
U-Boot ................ la32r-uboot, U-Boot 2019.07, arch/la32r, board/nscscc,
                        configs/la32rsoc_defconfig, DTS arch/la32r/dts/la32rsoc_demo.dts
                        -> NO NAND (CONFIG_MTD/NAND/CMD_NAND all OFF); MMC+EXT4/FAT only
```
