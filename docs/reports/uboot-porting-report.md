# U-Boot porting survey: `la32r-uboot` → RV32-GC on the chiplab FPGA platform

**Tree surveyed:** `/home/shorthair/dsh/rv32-cpu/la32r-uboot` (gitee `loongson-edu/la32r-uboot`)
**Target:** brand-new RV32-GC core (RV32I + M/A/F/D/C + privileged), plugged into the chiplab FPGA SoC over AXI; U-Boot must (a) boot on the core, (b) read a kernel image/config from the platform NAND and autoboot from it, (c) write data back to NAND.
**Method:** read-only survey. Every fact below is cited as `path:line`. No file in the tree was modified. The only write is this report. Where the checked-in defconfig was not trustworthy, the effective configuration was regenerated **out-of-tree** from a copy of the tree (`make O=/tmp/… la32rsoc_defconfig`) so the tree stayed clean; those results are marked *(effective .config)*.

---

## 0. Executive summary

| Question | Answer |
|---|---|
| U-Boot version | Declares **2019.07** (`Makefile:3-4`) but contains later upstream subsystems (~v2020.10) — see §1.4. Tag `baixinsoc-v0.1.0`, HEAD `1b96e814` (2024-04-16). |
| Board | `board/nscscc/` (`SYS_VENDOR=nscscc`, `SYS_BOARD=2019` **Kconfig defaults are inert** — see §2.3), defconfig `configs/la32rsoc_defconfig` = chiplab 龙芯实验箱 ("LOONGSON SOC"), config-name `la32rsoc_demo`. |
| Arch used today | `arch/la32r/**` (LA32R = LoongArch32-Reduced). **There is no `arch/loongarch/`.** `CONFIG_LA32R=y`, `ARCH=la32r`. |
| RISC-V support | **`arch/riscv/**` already exists and is complete for RV32** (RV32I default, M/A/C, M-mode **and** S-mode, CLINT/PLIC/PLMT, SBI IPI, `cpu/generic`, PIE self-relocation). 4 native boards: `qemu-riscv32`, `ae350_rv32`, `sifive_fu540`, `mpfs_icicle`. **The cheapest port is: reuse `arch/riscv`, add a new chiplab board.** |
| NAND | **No NAND support at all in U-Boot today** (`CONFIG_NAND`/`CONFIG_CMD_NAND`/`CONFIG_MTD` all off, no controller driver). The **platform has a NAND controller** (LS1A-style, `chiplab/IP/APB_DEV/NAND/nand.v`) and **a reference Linux driver exists in this workspace**: `la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c`. A U-Boot controller driver + config + boot flow must be written. |
| Boot flow today | Single-stage, `0xa0200000` (DDR cached window), OF_EMBED DTB, relocate to top of RAM, env `NOWHERE`, bootcmd = FAT/MMC + `bootelf` (network TFTP in the docs). No flash boot. |
| Toolchain | `ARCH=la32r`, `CROSS_COMPILE=loongarch32r-linux-gnusf-` (`BUILD_NOTE.md:3-5`). For RV32-GC you need a bare-metal `riscv32-*` toolchain — **not installed here** (`/opt/riscv` only has `riscv32-unknown-linux-gnu-`, gcc 16.1.0/glibc). |

---

## 1. U-Boot version, vendor/board names, fork status

### 1.1 Version string
```
Makefile:3   VERSION = 2019
Makefile:4   PATCHLEVEL = 07
```
No `include/generated/*` exists (tree is unbuilt), so the only version markers are the Makefile and the git tag.

### 1.2 Git identity, tag, log
```
$ git describe --tags      ->  baixinsoc-v0.1.0        (the only tag)
$ git remote -v            ->  origin https://gitee.com/loongson-edu/la32r-uboot.git
$ git branch -a            ->  master, remotes/origin/master
$ git log --oneline -20
1b96e814 !2 合并 Loongson SOC 与 BaiXin SOC的uboot 代码，通过 dts 与编译选项区分   (2024-04-16)
7b9b6ad3 remove do_bootelf printf,which could result in bad_vaddr                    (2024-04-07)
b6869e48 remove u-boot.s                                                             (2024-04-07)
19bfeccb add menuconfig to decide which soc should be compiled                       (2024-04-07)
5f8e0af0 modify bootcmd parameter                                                    (2024-03-29)
8377eae1 fix mac memory incorrect bug                                                (2024-03-29)
03ae5ab9 serial output chaos code                                                    (2024-03-26)
14916d5b support run in qemu-system-loongarch32                                      (2024-03-26)
06e9026a pass start.S , exists bugs in ns16550_serial_probe                          (2024-03-26)
4fa095a3 init commit:                                                                (2023-10-31)
6dfe4c10 Initial commit                                                              (2023-10-31)
```
11 commits total. `6dfe4c10` only added `README.md`/`README.en.md` (both were then deleted in `4fa095a3` and are **absent from the working tree**; `git ls-files | grep -i readme` → only the stock U-Boot `README`).

### 1.3 It is a fork with LoongArch/Loongson additions
The vendor delta relative to the imported tree (`git diff --stat 4fa095a3 HEAD`) is exactly 19 files:

```
.gitignore, BUILD_NOTE.md, build_meta.sh, run-qemu.sh, cmd/elf.c,
arch/la32r/Kconfig, arch/la32r/cpu/start.S, arch/la32r/dts/Makefile,
arch/la32r/dts/la32rsoc_demo.dts, arch/la32r/include/asm/addrspace.h,
arch/la32r/include/asm/ns16550.h, board/nscscc/Kconfig,
configs/la32rmega_defconfig, configs/la32rsoc_defconfig,
include/configs/la32rsoc_demo.h,
tools/binman/test/descriptor.bin, tools/patman/test/*.patch (3 files)
```
Everything else that is Loongson-specific (`arch/la32r/**`, `arch/la32r/dts/*`, the `LA32R` Kconfig entry, `tools/la32r-relocs.c`, `arch/la32r/Makefile.postlink`) arrived with the squashed `4fa095a3` "init commit", i.e. it is a **vendored, squashed snapshot**, not a clean upstream + small patch series.

### 1.4 Version caveat (important for cherry-picking patches)
The declared version 2019.07 is inconsistent with parts of the tree:

| Evidence | Path:line | Implication |
|---|---|---|
| `config BLOBLIST` exists | `common/Kconfig:821` | bloblist is ≥ v2020.10 |
| binman refactored into one class per etype | `tools/binman/etype/*.py` | ≥ v2020.10 |
| `TARGET_MICROCHIP_ICICLE` in the RISC-V target choice | `arch/riscv/Kconfig:14` | PolarFire SoC support ≥ v2020.10 |
| `SBI_IPI` + `arch/riscv/lib/sbi_ipi.c` | `arch/riscv/Kconfig:190`, `arch/riscv/lib/Makefile:19` | SBI v0.2 IPI ≥ v2020.10 |
| `RISCV_SMODE`, `qemu-riscv32_smode_defconfig` | `arch/riscv/Kconfig:109-113`, `configs/` | S-mode U-Boot ≥ v2020.01 |
| `IMAGE_SPARSE`, `DM_DEV_READ_INLINE`, `SPL_DM_SEQ_ALIAS` | `lib/Kconfig:70`, `drivers/core/Kconfig:260` | ≥ v2020.01 |
| dtc version string `DTC 1.4.6-gaadd0b65` | `scripts/dtc/version_gen.h:1` | 2019-era dtc |

**Conclusion:** the tree is a *mixed* snapshot. Treat "2019.07" as a label, not as a base commit. Before backporting any upstream patch (NAND, MTD, RISC-V fixes), diff the target file against the upstream tag you pick.

### 1.5 Vendor / board names present
* `CONFIG_SYS_VENDOR` default `"nscscc"`, `CONFIG_SYS_BOARD` default `"2019"` → `board/nscscc/2019/` (`board/nscscc/Kconfig:3-7, 35-39, 51-55`).
* `CONFIG_SYS_CONFIG_NAME`: `"la32rsoc_demo"` (chiplab/Loongson Soc) or `"la32rmegasoc_demo"` (Baixin BX100E) — `arch/la32r/Kconfig:46-49`.
* Legacy non-LA32R boards share the same board directory: `configs/trivialmips_nscscc_defconfig` (MIPS) and `configs/megasoc_defconfig` (MIPS, `CONFIG_MIPS=y`, `CONFIG_SYS_TEXT_BASE=0x9FC00000`).

---

## 2. Board support for the chiplab platform

### 2.1 Files (complete list of what belongs to *this* board)
| File | Role |
|---|---|
| `arch/la32r/Kconfig` | SoC/target choice (`TARGET_LA32R_LOONGSONSOC_DEMO`, `TARGET_LA32R_BAIXINMEGA_DEMO`), `SYS_CONFIG_NAME`, `SYS_TEXT_BASE` default `0xa0200000`, `LA32R_BOOT_FDT`, `LA32R_RELOCATION_TABLE_SIZE`, cache line sizes |
| `board/nscscc/Kconfig` | `SYS_BOARD="2019"`, `SYS_VENDOR="nscscc"`, `SYS_CONFIG_NAME`, `SYS_TEXT_BASE` default `0xBC000000` (overridden) |
| `board/nscscc/2019/Makefile` | one line: `obj-y := trivialmips_nscscc_2019.o` |
| `board/nscscc/2019/trivialmips_nscscc_2019.c` | legacy MIPS-derived board file: `dram_init()`, `get_ticks/get_timer/timer_get_us/__udelay` using `rdcntvl.w`/`rdcntvh.w` — **not compiled for the LA32R targets** (§2.3) |
| `configs/la32rsoc_defconfig` | the chiplab/龙芯实验箱 defconfig (23 kB full `.config` dump) |
| `configs/la32rmega_defconfig` | Baixin BX100E SoC defconfig |
| `include/configs/la32rsoc_demo.h` | SDRAM/UART/env/boot settings for the chiplab board |
| `include/configs/la32rmegasoc_demo.h` | same for Baixin |
| `arch/la32r/dts/la32rsoc_demo.dts` | built-in device tree (OF_EMBED) |
| `arch/la32r/dts/la32rmega_demo.dts` | built-in DT for Baixin |
| `arch/la32r/**` (55 files) | the whole LA32R architecture port (start.S, lds, timer, traps, cache, reloc, bootm, headers) |

**Generic (unmodified upstream) files everything else depends on:** `common/board_f.c`, `common/board_r.c`, `cmd/*`, `env/*`, `fs/*`, `net/*`, `lib/*`, `drivers/*`, `scripts/*`.

### 2.2 `MAINTAINERS`
There is **no entry** for `la32r`, `loongson`, `nscscc`, `megasoc` or `chiplab` in `MAINTAINERS` (grep for those strings returns nothing). The only relevant entry is:
```
MAINTAINERS:683  RISC-V
MAINTAINERS:684  M: Rick Chen <rick@andestech.com>
MAINTAINERS:687  F: arch/riscv/
```
Adding a new board means adding your own `MAINTAINERS` stanza (pattern: `board/emulation/qemu-riscv/MAINTAINERS`).

### 2.3 Which board directory is actually compiled (verified, not assumed)
The checked-in defconfigs are **full `.config` dumps used as defconfig fragments**; Kconfig ignores their `# CONFIG_X is not set` lines (those are comments) and recomputes defaults. Regenerating out-of-tree:

```
$ make O=/tmp/ubcfg/out3 la32rsoc_defconfig     # from a copy of the tree
$ grep -E 'SYS_BOARD|SYS_VENDOR|SYS_CPU' /tmp/ubcfg/out3/.config
(no output -> all unset)
```
Consequences:
* `BOARDDIR = $(VENDOR)/$(BOARD)` (`config.mk:51-57`) is **empty**, so `Makefile:751 libs-y += $(if $(BOARDDIR),board/$(BOARDDIR)/)` adds nothing → **`board/nscscc/2019/` is not built for `la32rsoc`/`la32rmega`**.
* Therefore the chiplab board has **no board C file at all** in the build; `dram_init` comes from `arch/la32r/cpu/dram.c:10` and the timer from `arch/la32r/cpu/time.c`.
* If you ever set `CONFIG_SYS_BOARD`/`CONFIG_SYS_VENDOR` to `2019`/`nscscc` for a new target, `trivialmips_nscscc_2019.c` gets linked and **collides** with `arch/la32r/cpu/dram.c` (`dram_init`) and `arch/la32r/cpu/time.c` (`get_timer`, `__udelay`) — duplicate strong symbols, because every `built-in.o` is linked directly (`Makefile:1553-1556`, `--start-group`, no `-z muldefs` anywhere). Use a **new** board directory instead.

**Effective settings for `la32rsoc` (verified):** `CONFIG_LA32R=y`, `CONFIG_RISCV` unset, `CONFIG_TARGET_LA32R_LOONGSONSOC_DEMO=y`, `CONFIG_SYS_CONFIG_NAME="la32rsoc_demo"`, `CONFIG_SYS_TEXT_BASE=0xa0200000`, no `CONFIG_SPL`/`CONFIG_TPL`.

---

## 3. Architecture porting surface: `arch/riscv` vs `arch/la32r`

### 3.1 What exists under `arch/`
```
arch/: Kconfig arc arm la32r m68k microblaze mips nds32 nios2 powerpc riscv sandbox sh x86 xtensa
```
* **There is no `arch/loongarch/`.** The LA32 port is a *new arch directory* named `la32r` (`arch/Kconfig:44-47`).
* `arch/la32r/` is the arch the chiplab board uses (`CONFIG_SYS_ARCH="la32r"`, `CONFIG_LA32R=y`).

### 3.2 `arch/la32r/**` (55 files, fork-specific — the thing you are replacing)
```
arch/la32r/Kconfig, Makefile, Makefile.postlink, config.mk
arch/la32r/cpu/: Makefile cpu.c dram.c interrupts.c start.S time.c u-boot.lds
arch/la32r/dts/: Makefile la32rmega_demo.dts la32rsoc_demo.dts
arch/la32r/lib/: Makefile ashldi3.c ashrdi3.c asm-offsets.c bootm.c cache.c libgcc.h lshrdi3.c reloc.c
arch/la32r/include/asm/: addrspace.h asm-offsets.h asm.h bitops.h byteorder.h cache.h cachectl.h
    cacheops.h config.h global_data.h gpio.h io.h la32rregs.h linkage.h mach-generic/{ioremap,mangle-port,spaces}.h
    ns16550.h pgtable-bits.h posix_types.h processor.h ptrace.h reboot.h reg.h regdef.h relocs.h
    sections.h spl.h string.h types.h u-boot.h unaligned.h
```

### 3.3 `arch/riscv/**` — already present, and it is a *complete* RISC-V port
```
arch/riscv/: Kconfig Makefile config.mk
arch/riscv/cpu/: Makefile cpu.c mtrap.S start.S u-boot.lds ax25/{Kconfig,Makefile,cache.c,cpu.c}
                 generic/{Kconfig,Makefile,cpu.c,dram.c}
arch/riscv/lib/: Makefile andes_plic.c andes_plmt.c asm-offsets.c boot.c bootm.c cache.c
                 crt0_riscv_efi.S elf_riscv{32,64}_efi.lds image.c interrupts.c rdtime.c
                 reloc_riscv_efi.c reset.c sbi_ipi.c setjmp.S sifive_clint.c smp.c
arch/riscv/include/asm/: barrier.h bitops.h byteorder.h cache.h config.h csr.h dma-mapping.h encoding.h
                 global_data.h io.h linkage.h posix_types.h processor.h ptrace.h sbi.h sections.h
                 setjmp.h smp.h string.h syscon.h system.h types.h u-boot-riscv.h u-boot.h unaligned.h
arch/riscv/dts/: Makefile ae350_32.dts ae350_64.dts
```
Feature set (`arch/riscv/Kconfig`, `arch/riscv/Makefile`):
* `ARCH_RV32I` **is the default** base ISA (`Kconfig:63-71`), `ARCH_RV64I` optional; `32BIT`/`64BIT` select.
* `RISCV_ISA_A def_bool y` (`Kconfig:124`), `RISCV_ISA_C default y` (`Kconfig:116-122`) → `-march=rv32imac -mabi=ilp32 -mcmodel=medany|medlow` (`Makefile:6-31`).
* Run mode: `RISCV_MMODE` (default) or `RISCV_SMODE` (`Kconfig:100-114`).
* Interrupt/timer blocks: `SIFIVE_CLINT` (`Kconfig:133-140`), `ANDES_PLIC`/`ANDES_PLMT` (`Kconfig:142-158`), `RISCV_RDTIME` (`Kconfig:160-166`), `SBI_IPI` (`Kconfig:190-193`), `SMP`/`NR_CPUS`, `XIP`, `STACK_SIZE_SHIFT`.
* **SBI**: `arch/riscv/include/asm/sbi.h` + `arch/riscv/lib/sbi_ipi.c` (SBI v0.2 style calls and IPI).
* `arch/riscv/cpu/generic/` = the generic core (`GENERIC_RISCV` `select ARCH_EARLY_INIT_R`, `imply CPU`, `imply RISCV_TIMER`, `imply SIFIVE_CLINT if RISCV_MMODE`, `imply CMD_CPU` — `generic/Kconfig:5-12`); `generic/dram.c:12-20` derives RAM from the device tree (`fdtdec_setup_mem_size_base()`), `generic/cpu.c` provides `cleanup_before_linux()` and a `simple-bus` driver.
* Board plumbing pattern (copy this): `board/emulation/qemu-riscv/Kconfig:9-22` sets `SYS_CPU="generic"`, `SYS_BOARD`, `SYS_VENDOR`, `SYS_CONFIG_NAME`, `SYS_TEXT_BASE`, and `select GENERIC_RISCV`. Same in `board/sifive/fu540/Kconfig:9-21`.
* RISC-V link/relocation: `-static -pie` (`arch/riscv/config.mk:31`), `.rela.dyn`/`.dynsym` self-relocation in `arch/riscv/cpu/start.S:209-262`, plus `tools/prelink-riscv` run automatically after the link (`Makefile:1573-1574`, `tools/Makefile:197`).
* Trap handling: `arch/riscv/cpu/mtrap.S` (`trap_entry`, `csrw tvec` in `start.S:51-52`) and `arch/riscv/lib/interrupts.c:15-45` (exception decode/print).
* Kernel hand-off: standard RISC-V Linux protocol `kernel(hartid, dtb)` (`arch/riscv/lib/bootm.c:81-106`), `booti` support via `arch/riscv/lib/image.c:18,33-40` (`CMD_BOOTI`, `cmd/Kconfig:224`) — no LA32R `-2`/`a1` UHI convention (`arch/la32r/lib/bootm.c:263-267`) needed.

### 3.4 Native RISC-V boards / defconfigs in this tree
```
configs/qemu-riscv32_defconfig        board/emulation/qemu-riscv/     (TARGET_QEMU_VIRT, OF_PRIOR_STAGE)
configs/qemu-riscv32_smode_defconfig  board/emulation/qemu-riscv/     (S-mode U-Boot)
configs/qemu-riscv64_defconfig, qemu-riscv64_smode_defconfig
configs/ae350_rv32_defconfig, ae350_rv32_xip_defconfig, ae350_rv64*, board/AndesTech/ax25-ae350
configs/sifive_fu540_defconfig        board/sifive/fu540/
                                      board/microchip/mpfs_icicle/    (TARGET_MICROCHIP_ICICLE)
```
`configs/qemu-riscv32_defconfig` is the smallest useful starting point (10 lines, `OF_PRIOR_STAGE=y`).

### 3.5 Answer
The chiplab board uses **`arch/la32r`**; for RV32-GC you do **not** need to write an arch port — you need a **new board + defconfig + DTS on top of `arch/riscv`**. Keep `arch/la32r/` in the tree (it is harmless; only built when `CONFIG_LA32R=y`) as the reference for the platform memory map and UART/NAND register offsets.

---

## 4. Startup / boot flow for the chiplab board

### 4.1 Address and image basics
| Item | Value | Source |
|---|---|---|
| `CONFIG_SYS_TEXT_BASE` | `0xa0200000` | `configs/la32rsoc_defconfig` (and effective `.config:22`) |
| `CONFIG_SYS_MONITOR_BASE` | `= CONFIG_SYS_TEXT_BASE` | `include/configs/la32rsoc_demo.h:30` |
| `CONFIG_SYS_LOAD_ADDR` | `0x90000000` | `include/configs/la32rsoc_demo.h:31` |
| `CONFIG_SYS_INIT_SP_ADDR` | `0xa0000000 + 0x08000000 - 0x1000` = `0xa7fff000` | `include/configs/la32rsoc_demo.h:21-24` |
| Link script | `arch/la32r/cpu/u-boot.lds` (selected by `Makefile:592-608`: no board lds, no `$(CPUDIR)/u-boot.lds`, falls back to `arch/$(ARCH)/cpu/u-boot.lds`) | |
| `CONFIG_SYS_CUSTOM_LDSCRIPT` | not set | effective `.config` |
| SPL/TPL | **none** (`CONFIG_SPL`/`CONFIG_TPL` unset; only `SPL_*` sub-option defaults exist) | effective `.config` |
| `CONFIG_SKIP_LOWLEVEL_INIT` | defined (BootROM/DDR PHY are expected to be up) | `include/configs/la32rsoc_demo.h:5` |

`arch/la32r/cpu/u-boot.lds`: `. = 0x00000000` (`:11`), so the real link address comes from `-Ttext $(CONFIG_SYS_TEXT_BASE)` (`Makefile:891`); `ENTRY(_start)` (`:8`); sections `.text`/`.rodata`/`.data`/`.sdata`/`.u_boot_list`; `__image_copy_end` (`:41`); `.data.reloc` (`:44-57`) sized by `CONFIG_LA32R_RELOCATION_TABLE_SIZE`; `.bss __rel_start (OVERLAY)` (`:62-69`).

> Quirk: `arch/la32r/config.mk:18 PLATFORM_ELFENTRY = "__start"`, but the actual entry symbol is `_start` (`lds:8`, `start.S:58`). `Makefile:1517-1522` uses it only as `--defsym=__start=…` for the ELF target, so it silently defines a second, unused symbol. `arch/riscv` does not override it and gets `_start` correctly.

### 4.2 `_start` (`arch/la32r/cpu/start.S`)
1. `ENTRY(_start)` `:58` → `bl reset` `:60`; a stub at `.org 0x1000` (`:65-89`) is the *exception* path: it prints the LA32R CSRs (`csrrd` 0x0-0x7, 0x180/0x181) and hangs — i.e. **the fork's only trap handler**.
2. `reset:` `:91` — sets `csr_eentry`/`csr_tlbrentry` to the cached alias of `0x1c001000` (`:95-98`), programs `csr_dmw0 = CACHED_MEMORY_ADDR|0x9` and `csr_dmw1` (Baixin: `UNCACHED_MEMORY_ADDR|0x9`, Loongson: `DIRECT_MAPPED_MEMORY_ADDR|0x9`) (`:100-109`), speeds up SPI on Baixin (`:112-116`), then `bl initserial` (`:118`) — an **open-coded NS16550 init at `COM0_BASE_ADDR` with divisor `0x12` for 115200 @33 MHz** (`:265-301`) — `bl cache_init` (`:120`, `cacop`-based I/D cache flush `:191-204`), enables DATF (`:123-131`), for Baixin writes SDRAM config words (`:133-145`), then **copies the whole image from the SPI/XIP window to its link address**: `la t0,_start; la t2,_end; add.w t1,t0,s0; loop: ld.w/st.w` (`:148-160`), where `s0` is the runtime↔link-address delta computed at `:92-93` from `PHYS_TO_UNCACHED(0x1c000000)`.
3. `c_main:` `:167` re-programs `csr_dmw0` as cached (`:162-163`), sets DMW1 for Loongson (`:168-171`), then `setup_stack_gd` (`:174`; macro at `:21-45`: aligns `CONFIG_SYS_INIT_SP_ADDR`, reserves `GD_SIZE`, clears gd, reserves `CONFIG_VAL(SYS_MALLOC_F_LEN)`), enables address translation (`:176-179`), `a0 = 0` boot_flags, `b board_init_f` (`:181-183`).
4. Notable: LA32R **does not call `board_init_f_alloc_reserve()`** — the stack/gd/malloc reservation is done by hand in assembly. The RISC-V `start.S:77-99,119` *does* call `board_init_f_alloc_reserve()` and `board_init_f_init_reserve()`, which is the flow you will get for free.

### 4.3 `board_init_f` / `dram_init` / relocation
* `board_init_f` is the **generic** `common/board_f.c` (`init_sequence_f` list starts at `:838`). Relevant members:
  * `fdtdec_setup` `:840` (DT is already embedded),
  * `announce_dram_init` `:905`, `dram_init` `:906`, `dram_init_banksize` `:952`,
  * `setup_reloc` `:701-729` with the vendor's unconditional `printf("Relocation Offset is: …")` / `printf("Relocating to …")` at `:723-726` (upstream uses `debug()`),
  * `jump_to_copy` `:742-768` → `relocate_code(gd->start_addr_sp, gd->new_gd, gd->relocaddr)` `:764`.
* `dram_init()` for LA32R is **static**: `arch/la32r/cpu/dram.c:10-14` sets `gd->ram_size = CONFIG_SYS_SDRAM_SIZE` (0x08000000 = 128 MB, `include/configs/la32rsoc_demo.h:22` — the comment there says "256 Mbytes", which is wrong; the megasoc header uses `0x10000000`).
* **Relocation mechanism is LA32R-specific**: `relocate_code()` lives in C, `arch/la32r/lib/reloc.c:195`, and consumes a variable-length encoded table in `.data.reloc` that is produced by the host tool `tools/la32r-relocs` (`arch/la32r/Makefile.postlink:11-17`, `CMD_RELOCS = tools/la32r-relocs`), enabled by `LDFLAGS_FINAL += --emit-relocs` and `OBJCOPYFLAGS += -j .data.reloc -j .dtb.init.rodata` (`arch/la32r/config.mk:38-41`). Relocation offset must be a multiple of 64 KiB (`reloc.c` comment at `:206-212`).
  → **For RV32 this whole mechanism is discarded**: `arch/riscv` links with `-static -pie` (`arch/riscv/config.mk:31`), keeps `.rela.dyn`/`.dynsym` (`arch/riscv/cpu/u-boot.lds:63-76`), self-relocates in `arch/riscv/cpu/start.S:172-262`, and post-processes with `tools/prelink-riscv` (`Makefile:1573-1574`).
* `board_init_r` is the generic `common/board_r.c`; no LA32R overrides.

### 4.4 Device tree
* **Built-in / embedded, not passed by a previous stage**: `CONFIG_OF_CONTROL=y`, `CONFIG_OF_EMBED=y`, `CONFIG_OF_PRIOR_STAGE`/`CONFIG_OF_BOARD`/`CONFIG_OF_SEPARATE` all unset (effective `.config:441` area; `configs/la32rsoc_defconfig`).
* `CONFIG_DEFAULT_DEVICE_TREE="la32rsoc_demo"` → `arch/la32r/dts/la32rsoc_demo.dts`, built by `arch/la32r/dts/Makefile:3`, embedded via the `.dtb.init.rodata` section (`arch/la32r/config.mk:39`).
* The DT is minimal and partly wrong for the hardware: `model = "loongson,generic"`, `compatible = "loongson,loongson3"` (`:5-6`), `memory@0x0 { reg = <0x0 0x08000000> }` (`:30-34`), `serial0` at `0x9fe001e0` with `compatible="ns16550a"` (`:44-52`), `gmac0` at `0x9ff00000` with `compatible="ls,ls-dmfe"` and a typo `evice_type` (`:54-59`), and a **`#if 0`-disabled NAND node** (`:61-91`, see §5.5).
* For RV32 the equivalent is: `CONFIG_OF_EMBED=y` (or `OF_SEPARATE`) + a new DTS in `arch/riscv/dts/` + a `dtb-$(CONFIG_TARGET_…)` line in `arch/riscv/dts/Makefile` (currently only `ae350_32/64.dtb` are built there — `arch/riscv/dts/Makefile:3`), or `OF_PRIOR_STAGE` if a previous stage passes the blob.

---

## 5. Drivers present for the chiplab platform

*(effective `.config` for `la32rsoc` unless noted; "driver file" is what gets compiled)*

| Subsystem | Config | Driver file | Notes for RV32-GC |
|---|---|---|---|
| Serial (console) | `CONFIG_SYS_NS16550=y`, `CONFIG_DM_SERIAL=y`, `CONFIG_BAUDRATE=115200` | `drivers/serial/ns16550.c` — DM half is built because `#ifndef CONFIG_DM_SERIAL` guards the legacy half (`:24`, DM part from `:89`); matches `compatible="ns16550a"` (`:527-532`); clock from DT `clock-frequency`, else `CONFIG_SYS_NS16550_CLK` (`:496-499`) | **Reusable as-is.** Just put `ns16550a` + `clock-frequency` in the new DTS |
| Debug UART | `DEBUG_UART_NS16550=y`, `DEBUG_UART_BASE=0x9fe001e0`, `DEBUG_UART_CLOCK=33000000`, `DEBUG_UART_SHIFT=0`, `DEBUG_UART_ANNOUNCE=y` | `drivers/serial/ns16550.c` debug part | Address is the LA32R *uncached alias*; use the physical `0x1fe001e0` for RV32 |
| Timer | **`CONFIG_TIMER` not set** | `arch/la32r/cpu/time.c` (`rdcntvl.w`/`rdcntvh.w`, `get_tbclk()=CONFIG_SYS_LOONGARCH_TIMER_FREQ=33`, `:17-20,25-26`) | For RV32 use `CONFIG_TIMER=y` + `RISCV_TIMER` (`drivers/timer/riscv_timer.c`, `drivers/timer/Kconfig:136-141`) and/or `SIFIVE_CLINT` (`arch/riscv/lib/sifive_clint.c`). LA32R timer CSRs do not exist on RV32 |
| Clock | `CONFIG_CLK=y` | **no clock driver** | Either drop `CLK` or add a chiplab clock driver |
| GPIO | `CONFIG_DM_GPIO=y` | **no GPIO controller driver** | Drop `DM_GPIO` unless you add one |
| Pinctrl | not set | — | — |
| Watchdog | not set (`WATCHDOG`, `WDT` off) | — | chiplab has no WDT IP |
| MMC | `MMC=y`, `DM_MMC=y`, `MMC_LSMMC=y`, `MMC_WRITE=y` | `drivers/mmc/ls_mmc.c` (`drivers/mmc/Makefile:46`) | chiplab SoC has **no** MMC controller (see RTL address map §8) — the FAT/MMC bootcmd in the defconfig cannot work on this platform |
| SPI (controller) | `SPI=y`, `DM_SPI=y`, `SPI_MEM=y`, `LOONGSON_SPI=y` | `drivers/spi/loongson_spi.c` | The chiplab SPI controller is memory-mapped (`IP/SPI/godson_sbridge_spi.v`) |
| SPI flash (NOR) | **`SPI_FLASH` and `DM_SPI_FLASH` not set** | — | No `sf` command, **no runtime read/erase/write of the boot SPI flash**. Only the XIP window (`0x1c000000`) is readable by the CPU |
| MTD (DM uclass) | **`CONFIG_MTD` not set**; only `CONFIG_MTD_PARTITIONS=y` | `drivers/mtd/mtd-uclass.c` not built | The `mtd` command has no devices (`cmd/mtd.c:24,203` → `mtd_probe_devices()` walks UCLASS_MTD) |
| NAND | **`CONFIG_NAND` not set**, `CONFIG_MTD_DEVICE` not set, `CONFIG_MTD_UBI` not set | — | see §5.5 / §12 |
| Network | `DM_ETH=y`, `ETHOC=y`, `DMFE_MAC=y`, `MII=y`, `NET=y`, `PHYLIB` off | `drivers/net/ethoc.c`, `drivers/net/dmfe.c` | chiplab has one MAC at `0x1ff00000`; the DTS node is `ls,ls-dmfe` (`la32rsoc_demo.dts:54-59`). Keep one driver, drop the other |
| USB | `USB=y`, `DM_USB=y`, `USB_DWC2=y`, `USB_HOST=y`; `USB_STORAGE` off | `drivers/usb/host/dwc2.c` | Not present on the chiplab SoC |
| Block model | `BLK=y`, `BLOCK_CACHE=y`, `PARTITIONS=y`, `DOS_PARTITION=y` | generic | keep |
| Filesystems | `FS_FAT=y` (no FAT write), `FS_EXT4=y` + `EXT4_WRITE=y` | generic | Only useful if a block device exists (MMC is not on this SoC) |
| I2C / RTC / reset / ADC / video | all off | — | — |

### 5.5 NAND/MTD in this tree: framework yes, driver no
* **Framework is present and complete (upstream)**: `drivers/mtd/nand/raw/nand_base.c` (138 kB), `nand_ids.c`, `nand_bbt.c`, `nand_ecc.c`, `nand_util.c`, `nand_timings.c`, `nand.c` (legacy glue), `nand_plat.c` (generic MMIO template with weak `board_nand_init()` — `:48-64`), plus `drivers/mtd/nand/spi/` (SPI-NAND), `drivers/mtd/ubi/`, `env/nand.c`, `cmd/nand.c`.
* **Controller drivers available** (`drivers/mtd/nand/raw/`): atmel, brcmnand, davinci, denali(+dt), fsl_elbc/ifc, fsmc, kb9202, kirkwood, kmeter1, lpc32xx (mlc/slc), mxc, mxs(+dt), pxa3xx, stm32_fmc2, sunxi, tegra, zynq, arasan, vf610. **There is no Loongson/LS1A `ls1a_nand` driver.**
* **The `mtd` command is enabled but useless**: `CONFIG_CMD_MTD=y` with `CONFIG_MTD` off → `cmd/mtd.c` finds zero devices. `cmd/nand.c` is not compiled (`CONFIG_CMD_NAND` off, `cmd/Makefile:99`).
* **Integration points you will use** for a new controller in this U-Boot generation:
  * legacy (simplest): `CONFIG_NAND=y` + `board_nand_init(struct nand_chip *)` in a board/driver file; `nand.c:78-98` calls `board_nand_init()` then `nand_scan()` then `nand_register()`; needs `CONFIG_SYS_NAND_BASE`, `CONFIG_SYS_MAX_NAND_DEVICE`, `CONFIG_SYS_NAND_MAX_CHIPS`.
  * self-init (Linux-like): `CONFIG_SYS_NAND_SELF_INIT` (`drivers/mtd/nand/raw/Kconfig:6-10`) + your own probe calling `nand_scan()`/`nand_register()`.
  * `CONFIG_MTD_DEVICE=y` additionally registers the MTD device for `mtdparts`/UBI (`nand.c:62-68`), and `CONFIG_MTD=y` + a DM MTD wrapper gives you the modern `mtd` command.

---

## 6. Command set and boot command

### 6.1 The options you asked about (effective `.config` for `la32rsoc`)
| Option | Value | Line |
|---|---|---|
| `CONFIG_CMD_NAND` | **not set** | `.config:295` |
| `CONFIG_CMD_MTD` | **y** (but `CONFIG_MTD` is off → zero devices) | `.config:294` |
| `CONFIG_CMD_MTDPARTS` | **not set** | `.config:402` |
| `CONFIG_CMD_UBI` / `CONFIG_CMD_UBIFS` | **not set** | `.config:416` |
| `CONFIG_CMD_NFS` | **not set** | defconfig |
| `CONFIG_CMD_TFTPBOOT` | **y** | defconfig / `.config` |
| `CONFIG_CMD_TFTPSRV`, `CMD_BOOTP`, `CMD_DHCP`, `CMD_PING`, `CMD_NET` | y | defconfig |
| `CONFIG_CMD_MMC`, `CMD_MMC_SWRITE` | y | defconfig |
| `CONFIG_CMD_ELF`, `CMD_BOOTM`, `CMD_BOOTZ`, `CMD_BOOTD`, `CMD_GO`, `CMD_FDT`, `CMD_BOOTMENU`, `CMD_RUN`, `CMD_XIMG` | y | defconfig |
| `CONFIG_CMD_FAT`, `CMD_EXT4`, `CMD_EXT4_WRITE`, `CMD_FS_GENERIC` | y | defconfig |
| `CONFIG_CMD_FLASH` | y (no CFI driver enabled → inert) | defconfig |
| `CONFIG_CMD_SPI` | y (no SPI flash driver → inert) | defconfig |
| `CONFIG_CMD_SAVEENV`, `CMD_EDITENV`, `CMD_ENV_EXISTS` | y | defconfig |
| `CONFIG_CMD_MEMORY`, `CMD_MEMTEST`, `CMD_CRC32`, `CMD_DM`, `CMD_SOURCE`, `CMD_ECHO`, `CMD_ITEST`, `CMD_SETEXPR`, `CMD_LOADS/LOADB`, `CMD_BLOCK_CACHE`, `CMD_GETTIME` | y | defconfig |
| Not enabled at all | `CMD_NAND`, `CMD_UBI`, `CMD_MTDPARTS`, `CMD_NFS`, `CMD_CACHE`, `CMD_GPIO`, `CMD_TIMER`, `CMD_I2C`, `CMD_PART`, `CMD_USB`, `CMD_CPU`, `CMD_BDI`, `CMD_LOG`, `DISPLAY_BOARDINFO/CPUINFO` | defconfig |

### 6.2 Where the boot command comes from — and a real trap
Two definitions exist:

1. `CONFIG_USE_BOOTCOMMAND=y` + `CONFIG_BOOTCOMMAND="fatload mmc 0:0 0xa0e00000 vm.bx100e;bootelf 0xa0e00000 console=ttyS0,115200"` (`configs/la32rsoc_defconfig`, effective `.config:…`).
2. `CONFIG_EXTRA_ENV_SETTINGS` in `include/configs/la32rsoc_demo.h:61-67`:
```c
#define CONFIG_EXTRA_ENV_SETTINGS \
    "autoload=no\0" \
    "serverip=10.170.133.145\0" \
    "ipaddr=10.170.133.10\0" \
    "netmask=255.255.255.0\0" \
    "ethaddr=00:98:76:64:32:19\0"\
    "bootcmd=console=ttyS0,115200 rdinit=/init"
```
In `include/env_default.h` the `"bootcmd=" CONFIG_BOOTCOMMAND` entry is emitted at `:34-35` **before** `CONFIG_EXTRA_ENV_SETTINGS` at `:110-111`, and the default-environment importer overwrites duplicate keys (`himport_r` → `hsearch_r(ENTER)` → `_compare_and_overwrite_entry()` frees and replaces the old value: `lib/hashtable.c:234, 257-263`).

**⇒ The effective `bootcmd` is the header's `console=ttyS0,115200 rdinit=/init`, not the `fatload mmc …` string.** Autoboot therefore tries to execute a kernel command line as a U-Boot command and drops to the prompt. Delete the stray `bootcmd=` from `CONFIG_EXTRA_ENV_SETTINGS` when you write the new board header.

Autoboot: `CONFIG_AUTOBOOT=y`, `CONFIG_BOOTDELAY=3`, `CONFIG_HUSH_PARSER=y`, `CONFIG_CMDLINE_EDITING=y`, `CONFIG_AUTO_COMPLETE=y`, `CONFIG_SYS_PROMPT="u-boot@LoongsonSoC# "`.

---

## 7. Environment storage and the boot targets

* **Environment is volatile**: `CONFIG_ENV_IS_NOWHERE=y` (effective `.config:448`; also `include/configs/la32rsoc_demo.h:57`), `CONFIG_ENV_SIZE=0x4000` (`:60`). Nothing is persisted; `saveenv` has no backing store.
* All other backends exist in the tree and are selectable: `env/Kconfig:204-… ENV_IS_IN_NAND` (with `CONFIG_ENV_OFFSET`, `CONFIG_ENV_SIZE`, optional `CONFIG_ENV_OFFSET_REDUND`/`CONFIG_ENV_RANGE`), plus `ENV_IS_IN_SPI_FLASH` (`env/sf.c`), `ENV_IS_IN_MMC` (`env/mmc.c`), `ENV_IS_IN_FAT`, `ENV_IS_IN_EXT4`, `ENV_IS_IN_EEPROM`, `ENV_IS_IN_UBI` (`env/ubi.c`). Implementation files are all present under `env/`.
* **Boot targets today**: network (`tftpboot`/`bootelf` — documented workflow in the chiplab docs, §10) or MMC/FAT (`bootcmd` above). **No flash-based boot path exists**: no `CONFIG_NAND_BOOT`, no SPL, no `nand read`/`mtd read` usage anywhere in the board code.
* Header env defaults (non-bootcmd): `autoload=no`, `serverip=10.170.133.145`, `ipaddr=10.170.133.10`, `netmask=255.255.255.0`, `ethaddr=00:98:76:64:32:19`.

---

## 8. UART / console and memory map

### 8.1 Addresses as seen by U-Boot (LA32R virtual windows!)
`arch/la32r/include/asm/addrspace.h:11-22` defines the LA32R memory windows: `CACHED_MEMORY_ADDR 0xa0000000`, `UNCACHED_MEMORY_ADDR 0x80000000`, `VA_TO_PHYS(x) = x & 0x1fffffff`. **So every `0x9fe0_xxxx` address in this tree is the *uncached virtual alias* of physical `0x1fe0_xxxx`.** RISC-V has no such windows — for RV32-GC use the **physical** addresses (or whatever your core's non-cacheable mapping is).

| Item | Value in tree | Source | Physical |
|---|---|---|---|
| SDRAM base | `CONFIG_SYS_SDRAM_BASE = 0xa0000000` | `include/configs/la32rsoc_demo.h:21` | `0x00000000` |
| SDRAM size | `CONFIG_SYS_SDRAM_SIZE = 0x08000000` (128 MB; comment wrongly says 256 MB) | `:22` | — |
| `CONFIG_SYS_INIT_SP_ADDR` | `0xa7fff000` | `:23-24` | `0x07fff000` |
| memtest range | `0xa0000000 … 0xb0000000` (256 MB — exceeds the 128 MB size above) | `:26-27` | — |
| malloc | `CONFIG_SYS_MALLOC_LEN = 256 KiB` | `:29` | — |
| U-Boot text | `0xa0200000` | defconfig / `.config:22` | `0x00200000` |
| Console UART | `CONFIG_SYS_NS16550_COM1 = 0x9fe001e0`, `CONFIG_SYS_NS16550_CLK = 33000000`, `CONFIG_SYS_NS16550_IER = 0`, `CONFIG_CONS_INDEX = 1` | `:47-50` | **`0x1fe001e0`** |
| Debug UART | `DEBUG_UART_BASE = 0x9fe001e0`, `DEBUG_UART_CLOCK = 33000000` | defconfig | `0x1fe001e0` |
| Pre-console buffer | `CONFIG_PRE_CON_BUF_ADDR = 0x9fe001e0` (!), `PRE_CON_BUF_SZ = 8192` | defconfig | **overlaps the UART** — see §14 |
| DTS `serial0` | `reg = <0x9fe001e0 0x1000>` | `arch/la32r/dts/la32rsoc_demo.dts:44-52` | `0x1fe001e0` |
| DTS `gmac0` | `reg = <0x9ff00000 0x10000>`, `compatible="ls,ls-dmfe"` | `:54-59` | `0x1ff00000` |
| DTS `memory` | `reg = <0x0 0x08000000>` | `:30-34` | — |
| NAND (disabled stub) | `nand@0x1fe78000`, order/conf reg at `0x1fd01160` | `:70-90` (`#if 0`) | `0x1fe78000` |
| SPI (mega board) | start.S writes `0x1fe80000+4` to speed up SPI | `arch/la32r/cpu/start.S:112-116` | `0x1fe80000` |
| Baixin UART | `0x9fe40000` (mega header) | `include/configs/la32rmegasoc_demo.h:48` | `0x1fe40000` |

### 8.2 The same map from the platform RTL (ground truth for your AXI decode)
`chiplab/IP/AMBA/axi_mux_syn.v` decodes CPU AXI addresses into 5 slaves:
```verilog
:854  wr_addr_hit[1] = awaddr[31:20]==12'h1c0 || awaddr[31:16]==16'h1fe8;  //SPI
:856  wr_addr_hit[2] = awaddr[31:16]==16'h1fe0 || awaddr[31:16]==16'h1fe7;  //APB: uart and nand
:858  wr_addr_hit[3] = awaddr[31:16]==16'h1fd0;                             //CONF
:859  wr_addr_hit[4] = awaddr[31:16]==16'h1ff0;                             //MAC
:860  wr_addr_hit[0] = ~|wr_addr_hit[4:1];                                  //DDR3
```
(`:946-950` is the identical read-side decode.) So, physically:

| Region | Device |
|---|---|
| `0x0000_0000`–`0x0fff_ffff` | DDR3 (default slave) |
| `0x1c00_0000`–`0x1c0f_ffff` | SPI flash **XIP/read window** (this is also where the CPU boots from: `start.S:95,149` uses `PHYS_TO_UNCACHED(0x1c000000)`) |
| `0x1fe0_0000`–`0x1fe0_ffff` | UART0 (NS16550-compatible) |
| `0x1fe7_0000`–`0x1fe7_ffff` | **NAND controller** (`axi2apb_misc` decodes uart vs nand internally) |
| `0x1fe8_0000` | SPI controller registers |
| `0x1fd0_0000` | CONFREG (switches/LEDs/timer-irq, NAND "order" reg at `+0x1160`) |
| `0x1ff0_0000` | MAC |

---

## 9. Build instructions, toolchain, helpers

### 9.1 As documented for the LA32R boards
`BUILD_NOTE.md:3-7` (Baixin) and `:18-22` (Loongson):
```sh
export ARCH=la32r
export CROSS_COMPILE=loongarch32r-linux-gnusf-
make la32rsoc_defconfig && make
loongarch32r-linux-gnusf-objdump -S u-boot > u-boot.S
loongarch32r-linux-gnusf-objcopy ./u-boot -O binary u-boot.bin
```
Scripted variant `build_meta.sh` (hard-codes a toolchain path and also emits `u-boot.s`):
```sh
export ARCH=la32r
export CROSS_COMPILE=../loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin/loongarch32r-linux-gnusf-
make -j8 && loongarch32r-linux-gnusf-objdump -lS u-boot > u-boot.S
loongarch32r-linux-gnusf-objcopy ./u-boot -O binary u-boot.bin
```
`run-qemu.sh` runs the result under `qemu-system-loongarch32 -M ls3a5k32 -bios ./u-boot.bin -nographic …`.
Other Linux-side commands (SD/TFTP boot) are in `BUILD_NOTE.md:31-49`.

**No `scripts/` helper is specific to this board.** The only board-specific host tool is `tools/la32r-relocs.c`, invoked automatically through `arch/la32r/Makefile.postlink` (see §4.3).

### 9.2 Toolchain reality check for RV32-GC
* The LA32R toolchain `loongarch32r-linux-gnusf-` is **not installed in this environment** (`which` fails; `/opt` contains only `riscv`; `chiplab/toolchains/` ships empty per its README). So **this tree cannot be built end-to-end here today** — that is a blocker to validate any change, not just to write it.
* Installed RISC-V toolchain: `/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc` (gcc **16.1.0**, glibc/`--print-multi-lib` → single multilib). U-Boot's RISC-V build forces `-march=rv32imac -mabi=ilp32` (`arch/riscv/Makefile:6-31`), i.e. **soft-float ilp32**, while a `rv32gc/ilp32d` Linux toolchain's `libgcc.a` is built for ilp32d — linking may fail with float-ABI mismatch. **Build/install a bare-metal `riscv32-unknown-elf` toolchain** (the workspace contains `riscv-gnu-toolchain` sources and existing build dirs, including `build-glibc-linux-rv32gc-ilp32d`), or confirm the Linux toolchain works with `CROSS_COMPILE=riscv32-unknown-linux-gnu-`.
* Expected build commands for the new board (mirroring `configs/qemu-riscv32_defconfig`):
```sh
export ARCH=riscv
export CROSS_COMPILE=riscv32-unknown-elf-
make <board>_defconfig && make -j$(nproc)
# produces u-boot.bin / u-boot-dtb.bin (OF_EMBED) plus u-boot (ELF, prelinked by tools/prelink-riscv)
```

---

## 10. `doc/` / `README*` mentions of chiplab, Loongson and NAND

* **No mention** of `la32r`, `loongson`, `nscscc`, `chiplab`, `la32rsoc` or `la32rmega` anywhere in `doc/`, `Documentation/` or the top-level `README` (greps return nothing). The vendor documentation is only `BUILD_NOTE.md`, `run-qemu.sh`, `build_meta.sh` and the (deleted) `README.md`/`README.en.md`.
* Generic NAND documentation that *is* present and applicable: `doc/README.nand`, `doc/README.JFFS2_NAND`, `doc/README.ubi`, `doc/README.ubispl`, `doc/README.nand-boot-ppc440`, `doc/README.davinci.nand_spl`.
* **In the platform repo** (outside this tree) the capability is documented: `chiplab/docs/FPGA_run_linux/linux_run.md:98-133` describes a **128 MB NandFlash used as a disk by PMON**, with `mtd_erase /dev/mtd0r`, `devcp tftp://…/vmlinux /dev/mtd0`, `set mtdparts nand-flash:50M@0(kernel)ro,-(rootfs)`, `set al /dev/mtd0`, and automatic boot of the kernel from NAND after reset. `chiplab/docs/Quick-Start.md:144-147` only documents booting U-Boot/PMON from SPI flash and loading the kernel over TFTP. **The U-Boot fork never implemented any of the NAND functionality that PMON has.**

---

## 11. Porting surface — file-by-file

Legend: **[new]** create, **[mod]** edit, **[keep]** reuse unchanged, **[drop]** not used by the RV32 build (leave in tree, excluded by config), **[ref]** reference only.

| Path | What it is now | What must change for RV32-GC |
|---|---|---|
| `arch/la32r/**` (38 files, esp. `cpu/start.S`, `cpu/u-boot.lds`, `config.mk`, `cpu/{time,dram,interrupts,cpu}.c`, `lib/{reloc,bootm,cache}.c`, `include/asm/**`, `Kconfig`) | complete LA32R port, incl. LA32R relocation table + `csr_dmw*`, `cacop`, `rdcntv*`, `eentry` | **[drop]/[ref]** — not selected once `CONFIG_RISCV=y`. Keep as the authoritative source of the platform's *addresses* and NS16550 register offsets. Delete `PLATFORM_ELFENTRY` trap only if you keep it. |
| `arch/la32r/dts/la32rsoc_demo.dts` | built-in DT for the chiplab SoC (memory, ns16550a serial, dmfe gmac, disabled nand) | **[ref]** → port into a new `arch/riscv/dts/<board>.dts` with **physical** addresses (`0x1fe001e0`, `0x1fe78000`, `0x1ff00000`) |
| `arch/riscv/**` | complete RV32/RV64 port (M/S-mode, CLINT/PLIC, SBI IPI, `cpu/generic`, PIE) | **[keep]** — the RV32-GC core plugs into this. Optional edits: add `dtb-$(CONFIG_TARGET_…)` in `arch/riscv/dts/Makefile:3`; add `source "board/<vendor>/<board>/Kconfig"` next to `arch/riscv/Kconfig:51-55`; add the target to the choice at `arch/riscv/Kconfig:7-23` |
| `arch/riscv/cpu/generic/{Kconfig,dram.c,cpu.c}` | generic core; RAM size/banks from DT | **[keep]**; if the chiplab DRAM is fixed, override `dram_init()`/`dram_init_banksize()` in the new board file instead of relying on the DT |
| `board/nscscc/**` | legacy MIPS board dir reused as `SYS_BOARD=2019`; **not built** for LA32R (§2.3) | **[new]** a fresh `board/<vendor>/chiplab/` (or `board/loongson/chiplab/`): `Kconfig` (`SYS_CPU="generic"`, `SYS_VENDOR`, `SYS_BOARD`, `SYS_CONFIG_NAME`, `SYS_TEXT_BASE`, `select GENERIC_RISCV`), `Makefile`, `<board>.c` (`board_init()`, optional `dram_init()`, `ft_board_setup()`), `MAINTAINERS` |
| `configs/la32rsoc_defconfig` | LA32R/chiplab config | **[new]** `configs/<board>_defconfig`, seeded from `configs/qemu-riscv32_defconfig` + `configs/ae350_rv32_defconfig`; add `CONFIG_RISCV=y`, `CONFIG_ARCH_RV32I=y`, `CONFIG_RISCV_ISA_C=y`, `CONFIG_TARGET_<BOARD>=y`, `CONFIG_SYS_TEXT_BASE`, `CONFIG_OF_EMBED=y`+`CONFIG_DEFAULT_DEVICE_TREE`, `CONFIG_SYS_NS16550=y`, `CONFIG_DM_SERIAL=y`, `CONFIG_TIMER=y`+`RISCV_TIMER=y`, and (new) `CONFIG_NAND=y`, `CONFIG_CMD_NAND=y`, `CONFIG_MTD_DEVICE=y`, `CONFIG_MTD_PARTITIONS=y`, `CONFIG_CMD_MTDPARTS=y`, `CONFIG_ENV_IS_IN_NAND=y` (+`ENV_OFFSET`/`ENV_SIZE`), optionally `CONFIG_CMD_UBI=y`/`CONFIG_MTD_UBI=y`. **Drop** `MMC*`, `FAT`, `USB*`, `LOONGSON_SPI`-only, `DMFE_MAC`/`ETHOC` (keep at most one), and the LA32R `DEBUG_UART_*` values |
| `include/configs/la32rsoc_demo.h` | board header: SDRAM/SP/load addr, UART, env, bootcmd | **[new]** `<board>.h`: `CONFIG_SYS_SDRAM_BASE/SIZE`, `CONFIG_SYS_INIT_SP_ADDR`, `CONFIG_SYS_LOAD_ADDR`, `CONFIG_SYS_MALLOC_LEN`, `CONFIG_SYS_NS16550_COM1/CLK`, `CONFIG_ENV_SIZE`, `CONFIG_EXTRA_ENV_SETTINGS` (**without** the stray `bootcmd=`), NAND sizes (`CONFIG_SYS_NAND_BASE`, `CONFIG_SYS_MAX_NAND_DEVICE`, `CONFIG_SYS_NAND_MAX_CHIPS`) |
| `board/nscscc/2019/trivialmips_nscscc_2019.c` | dead legacy board file with duplicate `dram_init`/`get_timer`/`__udelay` | **[ref]** — do not reuse; do not point `SYS_BOARD`/`SYS_VENDOR` at it |
| `tools/la32r-relocs.c`, `arch/la32r/Makefile.postlink`, `config.mk:38-41` | LA32R relocation table generator | **[drop]** for RV32 (`arch/riscv` uses `-static -pie` + `.rela.dyn` + `tools/prelink-riscv`, already wired at `Makefile:1573-1574`) |
| `cmd/elf.c` | vendor-patched (removed a `printf`, commit `7b9b6ad3`) | **[ref]** — RV32 should boot via `booti`/`bootm` (`CONFIG_CMD_BOOTI`, `arch/riscv/lib/image.c`) instead of `bootelf` |
| `drivers/serial/ns16550.c` + `Kconfig:599` | DM NS16550 driver, usable as-is | **[keep]** |
| `drivers/net/{dmfe.c,ethoc.c}` | two MAC drivers, both enabled today | **[keep one]** (the chiplab MAC is at `0x1ff00000`, DTS says `ls,ls-dmfe`) |
| `drivers/mmc/ls_mmc.c`, `drivers/usb/host/dwc2.c`, `drivers/spi/loongson_spi.c` | enabled drivers for hardware that the chiplab SoC does not have (MMC/USB) or does not expose to U-Boot (SPI flash) | **[ref]** |
| `drivers/mtd/**` (framework) | complete upstream NAND/MTD/UBI stack | **[keep]** |
| `drivers/mtd/nand/raw/<new>.c` | — | **[new]** NAND controller driver for the chiplab/LS1A controller (port of `la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c`, see §12) |
| `drivers/mtd/nand/raw/Kconfig` + `Makefile` | driver registry (`Kconfig:1-2 menuconfig NAND`) | **[mod]** add `config NAND_<SOC>` and `obj-$(CONFIG_NAND_<SOC>) += <soc>_nand.o` |
| `cmd/Kconfig`, `cmd/Makefile` | command registry (`CMD_NAND` at `cmd/Kconfig:896`, `cmd/Makefile:99`) | no change needed once `CONFIG_CMD_NAND=y` (add `CMD_MTDPARTS`/`CMD_UBI` if you want them) |
| `env/Kconfig:204`, `env/nand.c` | `ENV_IS_IN_NAND` backend | **[config only]** set `CONFIG_ENV_IS_IN_NAND=y`, `CONFIG_ENV_OFFSET`, `CONFIG_ENV_SIZE`, `CONFIG_ENV_RANGE`; remove `CONFIG_ENV_IS_NOWHERE` |
| `common/board_f.c`, `common/board_r.c`, `common/main.c`, `env/*`, `net/*`, `fs/*` | generic U-Boot 2019.07-era core | **[keep]** (only the vendor `printf` in `setup_reloc` at `:723-726` is non-standard) |
| `MAINTAINERS` | no entry for this board; RISC-V entry at `:683-689` | **[mod]** add your board stanza |
| `Makefile` | declares 2019.07; `-Ttext $(CONFIG_SYS_TEXT_BASE)` `:891`; board dir `:751`; `prelink-riscv` `:1573-1574` | **[keep]**, but do not trust the version string (§1.4) |

---

## 12. NAND: what exists vs what must be written

### 12.1 What exists
| Piece | Status | Evidence |
|---|---|---|
| Platform NAND **hardware** in the FPGA SoC | **Yes.** Soft NAND controller IP (`NAND_top`, Loongson 2016) with a DMA request/ack handshake, 8-bit data bus, 4 chip enables, R/B lines, interrupt | `chiplab/IP/APB_DEV/NAND/nand.v` (1430 lines), `chiplab/IP/APB_DEV/nand_module.v:34-93,115-121`, wired in `chiplab/IP/APB_DEV/apb_dev_top_with_nand.v` (module `axi2apb_misc`, uart0 + `nand_module`), alternative `apb_dev_top_no_nand.v` |
| Address / decode | **Yes.** `0x1fe7_xxxx` is "APB: uart and nand"; NAND base `0x1fe78000`, register window ≤ 2 KiB (`paddr = apb_addr[10:0]`), DMA descriptor window at `+0x40`, confreg "order" register at `0x1fd01160` | `chiplab/IP/AMBA/axi_mux_syn.v:857,948`; `chiplab/IP/APB_DEV/nand_module.v:71,97`; `arch/la32r/dts/la32rsoc_demo.dts:70-90` (disabled `#if 0`); `la32r-Linux/arch/loongarch/boot/dts/loongson/loongson32_ls.dts:79-99`; `ls1a_nand.c:18-19,84-88` |
| Platform capability / boot-from-NAND precedent | **Yes** — PMON (the original firmware) formats, writes and autoboots the kernel from a 128 MB NAND | `chiplab/docs/FPGA_run_linux/linux_run.md:98-133` |
| A driver to port | **Yes** — Linux 5.14 driver with register map, DMA descriptor layout, timing values, ECC and partition handling | `la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c` (1173 lines), DTS node `la32r-Linux/arch/loongarch/boot/dts/loongson/loongson32_{ls,bx}.dts` |
| U-Boot NAND/MTD/UBI **framework** | **Yes** — `nand_base.c`, `nand_ids.c`, `nand_bbt.c`, `nand_ecc.c`, `nand_util.c`, `nand_plat.c`, `drivers/mtd/ubi/`, `env/nand.c`, `cmd/nand.c` | `drivers/mtd/nand/raw/*`, `cmd/Makefile:99` |
| U-Boot NAND **controller driver for this SoC** | **No** | `find drivers -iname "*nand*"` has no Loongson/LS1A entry |
| U-Boot **config** for NAND | **No** — `CONFIG_NAND`, `CONFIG_MTD`, `CONFIG_MTD_DEVICE`, `CONFIG_ENV_IS_IN_NAND`, `CONFIG_CMD_NAND`, `CONFIG_MTD_UBI` all off; `CONFIG_MTD_PARTITIONS=y` only (a `select` of `CMD_MTD`) | effective `.config:294-295, 402-404, 679-683, 688-689, 695` |
| U-Boot **env in NAND** | **No** (`ENV_IS_NOWHERE`) | `.config:448` |
| U-Boot **boot from NAND** | **No** bootcmd / boot script references NAND at all | `configs/la32rsoc_defconfig`, `include/configs/la32rsoc_demo.h` |

### 12.2 What must be written (NAND work items)
1. **Controller driver** `drivers/mtd/nand/raw/<soc>_nand.c` for the LS1A-style controller, ported from `la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c`. Register map to reproduce (offsets from the controller base, per that driver):
   * command `0x1`, address-low `0x2`, address-high `0x4`, timing `0x8` (write `0x205` for both read and write), ID low/high `0x10`/`0x14`, status `0x20`, param `0x40`, op-count `0x80`, CS/RDY map `0x100`;
   * DMA block at base+`0x40`: order-address `0x1`, source address `0x2`, dest address `0x4`, length `0x8`, step length `0x10`, step times `0x20`, command `0x40`;
   * `_NAND_TIMING_TO_READ/WRITE = 0x205`; ECC on/off and RAM-op on/off bits; `PAGE_SHIFT 12` for the LS232 configuration (verify against the actual chip/PMON partition layout).
   In U-Boot terms this becomes a `struct nand_chip` with `cmd_ctrl`/`dev_ready`/`read_buf`/`write_buf` (and page-level hooks for the DMA path), `nand->ecc.mode = NAND_ECC_HW` (the controller does ECC via DMA) or `NAND_ECC_SOFT` as a first bring-up step, plus `nand_scan()`/`nand_register()`.
2. **Board/Kconfig wiring**: `board_nand_init()` (or `CONFIG_SYS_NAND_SELF_INIT` style probe), `CONFIG_SYS_NAND_BASE=0x1fe78000`, `CONFIG_SYS_MAX_NAND_DEVICE`, `CONFIG_SYS_NAND_MAX_CHIPS`, `CONFIG_NAND=y`, `CONFIG_MTD_DEVICE=y` (needed for `mtdparts`/UBI), `CONFIG_CMD_NAND=y`, `CONFIG_MTD_PARTITIONS=y`, `CONFIG_CMD_MTDPARTS=y` + `CONFIG_MTDPARTS_DEFAULT="nand0:50M@0(kernel)ro,-(rootfs)"` (mirroring PMON's `nand-flash:50M@0(kernel)ro,-(rootfs)`), and `CONFIG_CMD_UBI`/`CONFIG_MTD_UBI` if the rootfs is UBI.
3. **Persistent environment**: replace `CONFIG_ENV_IS_NOWHERE` with `CONFIG_ENV_IS_IN_NAND=y` + `CONFIG_ENV_OFFSET` (erase-block aligned) + `CONFIG_ENV_SIZE` + `CONFIG_ENV_RANGE`, keeping the env region **outside** the kernel/rootfs partitions.
4. **Boot-from-NAND flow**: a `bootcmd` such as `nand read ${kernel_addr_r} <kernel_offset> <kernel_size}; booti ${kernel_addr_r} - ${fdt_addr_r}` (or `mtd read`/`ubi` variants), `CONFIG_BOOTCOMMAND` in the defconfig, and **no** stray `bootcmd=` in `CONFIG_EXTRA_ENV_SETTINGS`.
5. **NAND write path**: `nand erase`/`nand write` (and `env save`) give you write-back to NAND; verify bad-block handling (`nand bad`, BBT in NAND via `CONFIG_SYS_NAND_USE_FLASH_BBT`) and the 4-byte alignment/cache-coherency that the DMA path needs (`ALIGN_DMA()`, `flush_dcache_range()` around DMA buffers — on RISC-V remember `arch/riscv/lib/cache.c` has **weak no-op** `flush_dcache_range` until you implement it for your core).
6. **Not needed but worth noting**: the same controller is what PMON uses, so PMON's partition layout is the compatibility target if you want existing images to remain usable.

### 12.3 Hardware caveat
The NAND controller may or may not be instantiated in the bitstream you load (`apb_dev_top_with_nand.v` vs `apb_dev_top_no_nand.v`, plus a `nand_type` strap in `nand_module.v:65,106-113`), and the FPGA NAND chip/board wiring (`NAND_CLE/ALE/RDY/DATA/RD/CE/WR` pins, `chip/soc_demo/loongson/soc_top.v:101-108`) must be present. Confirm with the bitstream/top-level you will actually use **before** writing the driver.

---

## 13. Concrete work plan (recommended order)

1. **Build a bare-metal RV32 toolchain** (`riscv32-unknown-elf`, ilp32) or verify the Linux one; nothing can be validated before this. *(blocker today)*
2. **Bring up `arch/riscv` + `cpu/generic` on QEMU first**: `make qemu-riscv32_defconfig && make && qemu-system-riscv32 -M virt -bios u-boot.bin -nographic`. This validates the RISC-V flow (start.S, relocation, NS16550, timer, traps) with zero board work.
3. **Create the chiplab board**: `board/<vendor>/chiplab/{Kconfig,Makefile,chiplab.c,MAINTAINERS}`, `configs/chiplab_rv32_defconfig`, `include/configs/chiplab_rv32.h`, `arch/riscv/dts/chiplab_rv32.dts` (+ `arch/riscv/dts/Makefile` entry), `arch/riscv/Kconfig` source + target choice. Use **physical** addresses: UART `0x1fe001e0`, MAC `0x1ff00000`, NAND `0x1fe78000`, confreg `0x1fd00000`, DDR `0x0`, `CONFIG_SYS_TEXT_BASE` = where your core's reset vector expects U-Boot (chiplab convention is SPI XIP at `0x1c000000`, while the LA32R U-Boot relocates itself to `0xa0200000` = phys `0x00200000`; decide XIP-from-SPI vs copy-to-DDR early — this determines `CONFIG_SYS_TEXT_BASE`, `CONFIG_XIP` and the link script).
4. **Decide the privilege model**: U-Boot in **M-mode** (`RISCV_MMODE`, simplest, needs a CLINT/`mtime` for `RISCV_TIMER`) or in **S-mode** behind an M-mode firmware (`RISCV_SMODE`, `RISCV_RDTIME`, SBI). If you intend to boot RISC-V Linux you need an SBI implementation (OpenSBI/BBL) in the chain — U-Boot in M-mode alone is not enough for Linux.
5. **Validate console + timer + traps** on the FPGA (`md`, `mw`, `sleep`, `bootdelay`), then network (`tftpboot`) or whatever load path you keep.
6. **Write the NAND driver** (§12.2 items 1–2), bring it up read-only first (`nand info`, `nand dump`), then erase/write/read-back (`nand erase`, `nand write`, `nand read` + `cmp`).
7. **Make env persistent** in NAND (§12.2 item 3).
8. **Autoboot from NAND**: partitions + `bootcmd` + `CONFIG_BOOTCOMMAND` (§12.2 item 4), then a full power-cycle test.
9. **Write the docs** the tree is missing: a `doc/board/<vendor>/chiplab.rst`-style note (this tree uses `doc/README.*`, so `doc/README.chiplab`) plus a `board/.../README` or `BUILD_NOTE`-style section for the RV32 build, and a `MAINTAINERS` stanza.

---

## 14. Uncertainties / things to verify

1. **U-Boot vintage is inconsistent** (§1.4): declared 2019.07, contains ~v2020.10 subsystems. Only `Makefile:3-4` claims 2019.07. Verify against the exact upstream tag you intend to track before porting/reviewing patches.
2. **No build was performed** (read-only survey, and the LA32R toolchain is absent). Everything about the current build was derived from Kconfig regeneration (`make O=/tmp/… la32rsoc_defconfig`) plus source reading; linker-level outcomes (e.g. section ordering, relocation table size `CONFIG_LA32R_RELOCATION_TABLE_SIZE=0x4000` sufficiency) were not executed.
3. **`CONFIG_SYS_BOARD`/`CONFIG_SYS_VENDOR` are unset in the effective config** even though `board/nscscc/Kconfig` declares defaults. If a future Kconfig/Kconfig-fragment change makes them visible, `board/nscscc/2019/trivialmips_nscscc_2019.c` enters the build and collides with `arch/la32r/cpu/{dram.c,time.c}` (duplicate `dram_init`/`get_timer`/`__udelay`; no `-z muldefs`). Re-verify after any Kconfig edit.
4. **Effective `bootcmd` is the one in `CONFIG_EXTRA_ENV_SETTINGS`, not `CONFIG_BOOTCOMMAND`** (§6.2, verified via `include/env_default.h:34,110` + `lib/hashtable.c:234-263`). Verify by printing `bootcmd` on a real boot once you can build.
5. **LA32R virtual-vs-physical addresses**: `0x9fe0_xxxx`/`0x9ff0_xxxx` in the tree are uncached aliases (mask `0x1fffffff`); RISC-V has no such windows. Confirm what the RV32-GC core issues for device accesses (physical, or a PMA/non-cacheable region) and use the *physical* numbers from `axi_mux_syn.v` unless your core maps them differently.
6. **`CONFIG_PRE_CON_BUF_ADDR = 0x9fe001e0` equals the UART base** — 8 KiB of pre-console log is written into the UART/APB device region. Looks like a copy/paste bug; verify (or just fix) when writing the new board header.
7. **RAM size inconsistencies**: `CONFIG_SYS_SDRAM_SIZE=0x08000000` (128 MB) is commented "256 Mbytes", `CONFIG_SYS_MEMTEST_END=0xb0000000` spans 256 MB, the DTS memory node says 128 MB, and the Baixin header uses `0x10000000`. Confirm the real DDR size of your FPGA board.
8. **NAND details are not fully pinned down**: page size (`PAGE_SHIFT 12` in `ls1a_nand.c` vs 2 KiB pages typical for 128 MB SLC), OOB/spare size, ECC strength, timing value `0x205`, chip count/`nand_type` strap, and whether the NAND IP is present in your bitstream (`apb_dev_top_with_nand.v` vs `apb_dev_top_no_nand.v`). Read the actual chip ID/params on hardware and cross-check with PMON's partition layout (`nand-flash:50M@0(kernel)ro,-(rootfs)`).
9. **`ls1a_nand.c` uses uncached aliases and a polling DMA** (`USE_POLL`, `_NAND_BASE 0x9fe78000`, `ORDER_REG_ADDR 0x9fd01160`). On RISC-V you must handle cache maintenance and DMA coherency explicitly (RISC-V U-Boot's `flush_dcache_range()`/`invalidate_dcache_range()` are **weak empty stubs**: `arch/riscv/lib/cache.c:18-33`).
10. **Boot-chain privilege model** (item 4 of §13): if the kernel is RISC-V Linux, an SBI implementation must exist in M-mode; `arch/riscv` in this tree supports both M-mode and S-mode U-Boot but ships no SBI *implementation* (only SBI client code: `arch/riscv/include/asm/sbi.h`, `arch/riscv/lib/sbi_ipi.c`).
11. **Toolchain ABI**: `/opt/riscv` provides only a `riscv32-unknown-linux-gnu` (glibc, single multilib) toolchain; U-Boot wants `-mabi=ilp32`. Verify linking (libgcc multilib) or build `riscv32-unknown-elf`.
12. **Drivers enabled but not present on the platform** (`MMC_LSMMC`, `USB_DWC2`, `DM_GPIO`, `CLK`, and both `ETHOC` + `DMFE_MAC`): enabling them may probe nothing, but they cost image size and can mask real errors (e.g. the default `bootcmd` uses MMC/FAT, which cannot work on chiplab). Decide per driver.
13. **SPI NOR is unreachable from U-Boot** (`SPI_FLASH`/`DM_SPI_FLASH` off): today you cannot read/erase/rewrite the boot flash from U-Boot — only via the XIP read window at `0x1c000000` (and only reads). If you want to update U-Boot/PMON in place from U-Boot, that is an additional work item.
14. **Unverified**: whether `arch/riscv`'s `-fpic` + `-static -pie` + `tools/prelink-riscv` flow interacts cleanly with the chiplab AXI/XIP window at `0x1c000000` for `CONFIG_XIP` boots (LA32R does XIP by copying at runtime; RISC-V XIP is supported via `CONFIG_XIP` but `XIP` + `-pie` semantics differ — test early if you plan to execute from SPI).
15. **`MAINTAINERS`** has no entry for this board; if you upstream anything, add one.

---

### Appendix A — exact commands used for the effective-config check (tree-safe)
```sh
cp -a /home/shorthair/dsh/rv32-cpu/la32r-uboot /tmp/ubcfg/src          # copy, tree untouched
mkdir -p /tmp/ubcfg/out3 && cd /tmp/ubcfg/src
make O=/tmp/ubcfg/out3 la32rsoc_defconfig                              # writes only under /tmp
grep -E 'SYS_BOARD|SYS_VENDOR|SYS_CPU' /tmp/ubcfg/out3/.config          # -> (unset)
grep -E 'CONFIG_(NAND|MTD|CMD_NAND|ENV_IS|SPI_FLASH)' /tmp/ubcfg/out3/.config
```
### Appendix B — the same map for a Baixin (BX100E) target, for contrast
`configs/la32rmega_defconfig`: UART `0x9fe40000`, `CONFIG_SYS_VENDOR/SYS_BOARD` **also inert in the effective config**, DTS `la32rmega_demo.dts`, bootcmd identical (MMC/FAT + bootelf).
