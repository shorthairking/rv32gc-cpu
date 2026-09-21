# sw/boot —— SPI Flash XIP 引导链（B-3.5）

> **阶段**：阶段三 B-3.5（打通"复位 → SPI XIP 引导桩 → DDR3 → OpenSBI → U-Boot"这条链）。
> **真源**：`docs/porting/01-overview.md` §2（启动流程与 DDR 布局）、`docs/porting/02-uboot.md` §8.6（U-Boot `CONFIG_TEXT_BASE`）、
> `docs/porting/03-linux-opensbi.md` §4（FW_JUMP 路线）、`docs/kb/platform-facts.md` §2.3（XIP 主窗口/别名）、§5（33 MHz 同域）。
> **上板烧写步骤**：见 `sw/M5-board-runbook.md` §9（引导链节）。

## 1. 交付物一览

| 文件 | 作用 |
|---|---|
| `boot_stub.S` | **引导桩**（链接 0x1C00_0000 = 复位取指 PC；纯 PC 相对；只用 `lw/sw`；不开 MMU、不碰任何 CSR） |
| `boot_stub.ld` | 桩链接脚本（入口 0x1C00_0000；**链接期 ASSERT** 桩 ≤ 16 KiB 槽位；无 .bss/栈） |
| `build_opensbi_rv32.sh` | OpenSBI RV32 `FW_JUMP` 可复现构建（外部构建目录 `O=`，**不改 opensbi 源码**；产版本/大小/md5 证据） |
| `build_spi_image.sh` | **打包脚本**：汇编桩 + 按布局写 `spi_flash.img`（fail-closed 十项判据 + 逐段 md5 + 布局表） |
| `check_stub_layout.sh` | **布局机器一致性核对**（桩 `.equ` ⇄ 打包脚本 `LAYOUT_*` ⇄ 真实 payload ⇄ 已打包镜像切片）+ 仿真字表生成 |
| `sim/unit/prog/boot_stub_probe.S` | 仿真用"迷你 OpenSBI"占位程序（把入口寄存器写进 DDR 邮箱后停机） |
| `sim/unit/prog/boot_stub_words.svh`、`boot_stub_sim.hex` | **自动生成**的仿真字表（TB `include`；从汇编后桩 ELF 符号表生成，勿手改） |
| `sim/unit/tb_boot_stub.sv` | core_top 级自包含 TB（`scripts/regress.sh` 自动发现） |

产物（`sw/boot/out/`，已被 `.gitignore` 的 `sw/**/out/` 忽略）：
`boot_stub.elf/.bin`、`spi_flash.img`、`spi_flash_img_info.txt`、`opensbi-build/**`、`opensbi_build_info.txt`。

## 2. 镜像布局（唯一真源 = `boot_stub.S` 的 `.equ` 块 + `build_spi_image.sh` 的 `LAYOUT_*`）

```
SPI Flash（S25FL128S，16 MiB）        核看到的地址                DDR3 运行地址
┌──────────────────────────┐ 0x000000  ← RESET_PC = 0x1C00_0000（XIP 主窗口，1 MiB）
│ 引导桩 boot_stub.bin     │ 128 B     就地执行（取指绕过 I-Cache）
├──────────────────────────┤ 0x004000
│ OpenSBI fw_jump.bin      │ 272 080 B 读出 → 拷到 ────────────▶ 0x0100_0000（FW_TEXT_START，入口）
├──────────────────────────┤ 0x080000
│ U-Boot u-boot.bin        │ 398 332 B（源 398 330 B 零补齐到 4）─▶ 0x0200_0000（CONFIG_TEXT_BASE）
├──────────────────────────┤ 0x0E8000
│ U-Boot DTB u-boot.dtb    │ 6 004 B（源 6 002 B）─────────────▶ 0x0300_0000（FW_JUMP_FDT_ADDR）
├──────────────────────────┤ 0x0E9774 = 镜像末尾（956 276 B ≤ 1 MiB XIP 窗口）
│ （未用，写 0）            │
└──────────────────────────┘ 0x100000（= XIP 主窗口上界；再往上是 DDR3 默认从设备窗口）
```

桩跳转前设置入口寄存器：`a0 = hartid(0)`、`a1 = 0x0300_0000`（DTB 物理地址）、`a2 = 0`；随后 `jalr x0, 0(t0)` 跳到 `0x0100_0000`。

- **为什么偏移必须是这些值**：核只有 1 MiB 的 XIP 主窗口（`PA[31:20]==0x1C0`），镜像整体必须塞进 1 MiB；
  桩必须落在偏移 0（`RESET_PC` 是硬事实，平台无 boot ROM）；OpenSBI 的运行地址 = `FW_TEXT_START`，
  U-Boot 的运行地址 = `CONFIG_TEXT_BASE`（两侧**逐字一致**，由打包脚本判据⑤与 `build_opensbi_rv32.sh` 判据⑤ 交叉核对）。
- **16 KiB 对齐 + 余量**：偏移全部 4 KiB 对齐；当前余量：OpenSBI→U-Boot 235 824 B、U-Boot→DTB 27 652 B、
  镜像末尾→窗口上界 92 300 B。**payload 长大到压段 ⇒ 打包脚本判据⑥ 直接报红**，并提示要改哪两处。

## 3. 三步构建（可复现命令）

```sh
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu

# ① OpenSBI（RV32 / PLATFORM=generic / FW_JUMP；不改 opensbi 源码，构建目录在 sw/boot/out/）
./sw/boot/build_opensbi_rv32.sh                       # ⇒ OPENSBI_BUILD: OK（size/md5/版本证据）
#   等价手写命令：
#   make -C ../opensbi O=$PWD/sw/boot/out/opensbi-build PLATFORM=generic \
#        CROSS_COMPILE=riscv32-unknown-linux-gnu- FW_JUMP=y \
#        FW_TEXT_START=0x01000000 FW_JUMP_ADDR=0x02000000 FW_JUMP_FDT_ADDR=0x03000000 -j16

# ② 打包镜像（桩 + 三段 payload + 双源核对 + 逐段切片核对）
./sw/boot/build_spi_image.sh                          # ⇒ SPI_IMAGE: OK（布局表 + 逐段 md5）
./sw/boot/check_stub_layout.sh                        # ⇒ STUB_LAYOUT: OK（机器一致性核对）

# ③ 仿真（引导桩 + 迷你 OpenSBI 占位程序的完整拷贝→跳转链）
./scripts/regress.sh                                  # 含 tb_boot_stub
```

**改了桩源码之后**（改布局/指令都算）：`./sw/boot/check_stub_layout.sh --update-sim-words` 刷新仿真字表，
否则 `check_stub_layout.sh` 判据⑥ 会报"字表过期"，`regress` 里的 `tb_boot_stub` 用的就是旧桩（防"测的不是真桩"）。

### 3.1 改布局时要同步的两处（**必须都改**）

1. `boot_stub.S` 顶部 `.equ` 常量块（桩运行时用的值）；
2. `build_spi_image.sh` 顶部 `LAYOUT_*` 声明（打包脚本用的值）。

只改一边 ⇒ `build_spi_image.sh` 判据③/⑤ 与 `check_stub_layout.sh` 判据② 同时报红（这就是"防双源漂移"）。
payload 大小变化时，`.equ BOOT_LEN_*` 也要跟着改（打包/核对脚本会打印"实际应为 0x…"）。

## 4. 引导桩做了什么（逐段）

```asm
_stub_start:                       # 0x1C00_0000：复位后第一条指令
    auipc a4, %pcrel_hi(stub_seg_table)   # PC 相对取段表地址（汇编/链接期解析 ⇒ 零重定位）
    addi  a4, a4, %pcrel_lo(.Lstub_pcrel_hi0)
    li    t3, BOOT_FLASH_BASE     # 0x1C00_0000（Flash 读基址；只读不写 ⇒ 不涉及别名写通路）
    li    a5, BOOT_SEG_COUNT      # 3 段
seg_next:                          # 表项 {src 偏移, dst 物理地址, len 字节}
    lw    t0, 0(a4) ; lw t1, 4(a4) ; lw t2, 8(a4)   # 取一段的三元组
    addi  a4, a4, 12
    add  t0, t0, t3               # 源地址 = 0x1C00_0000 + 偏移（XIP 主窗口直读）
word_copy:
    lw    t4, 0(t0)               # 读 Flash（4 B 整字）
    sw    t4, 0(t1)               # 写 DDR3（MDTA 单 beat AXI，提交前等 B 响应）
    addi  t0, t0, 4 ; addi t1, t1, 4 ; addi t2, t2, -4
    bne   t2, zero, word_copy
    addi  a5, a5, -1 ; bne a5, zero, seg_next
    li    a0, BOOT_HARTID         # a0 = 0
    li    a1, BOOT_FDT_DST        # a1 = 0x0300_0000
    li    a2, 0
    li    t0, BOOT_NEXT_ENTRY     # 0x0100_0000
    jalr  x0, 0(t0)               # 跳 OpenSBI（跨窗口：显式物理地址）
_stub_halt: j _stub_halt          # 不可达（防御）
```

静态口径由 `build_spi_image.sh` 判据⑧ 机器核对：入口 = 0x1C000000、`readelf -r` 零重定位、
无 CSR 指令 / 无 `sfence`/`fence.i`/`ecall`/`mret`、无压缩指令、无 sp 基址访存、访存只有 `lw/sw`。
判据⑨ 再把**已链接镜像里段表的 9 个字面值**与 `.equ`/布局逐字比对（防"源码对了但编出来的不是那个"）。

## 5. 仿真怎么验（`sim/unit/tb_boot_stub.sv`）

真 OpenSBI 跑不进 iverilog（要 5 分钟以上、且要 DDR 模型撑到 0x0300_0000），所以 TB 用**小 payload**：

| 环节 | 做法 |
|---|---|
| 桩 | **同一份 `boot_stub.S`**，只把三个 `BOOT_LEN_*` 用 `-Wa,--defsym` 换成小值（4 KiB / 8 KiB / 1 KiB）；偏移与目的地址与真实镜像**完全一致** |
| OpenSBI 段 | `boot_stub_probe.S` 占位程序（11 条指令：把 a0/a1/a2/magic/sig 写进 DDR3 邮箱后停机）+ 地址相关模式字节 |
| U-Boot / DTB 段 | 纯模式字节（末段首字是 FDT magic） |
| 判据 | C0 布局交叉核对 → C1 首笔取指 0x1C000000 → C2 邮箱 MAGIC（超时即红）→ C3 入口寄存器 → **C4 三段逐字节比对** → C5 各段写入字数 → C6 总 W 拍数 → C7 Flash 读分类（源偏移错 ⇒ 读落在界外）→ C8 未建模 DDR 访问 = 0 |

**TB 侧布局是独立的**（`TB_SRC_*`/`TB_DST_*`/`TB_LEN_*` 写死在 TB 里，**不读桩的常量**）——否则"桩把源偏移写错"会自我一致地通过。
桩的常量（`boot_stub_words.svh`）只用于：装桩镜像 + **交叉核对**。

## 6. 反证（"未捕获即失败"的自证；三条都实测过）

| # | 变异 | 期望 | 实测 |
|---|---|---|---|
| ① | 桩源码 `BOOT_SRC_UBOOT` 0x080000 → **0x080100**（错 256 B）→ 刷新字表 → 跑 TB | 判红 | **C0 常量不符 + C4 U-Boot 段逐字节不符 + C7 未登记 Flash 读**（三层同时报） |
| ② | TB 侧 `+MUT_FLASH_SHIFT=1`（Flash 内容整体后移 4 B，桩不动） | 判红 | **C2 超时**（占位程序取不到 ⇒ 邮箱无 MAGIC）+ C8 出现 1 笔未建模读 |
| ③ | 打包脚本：`--dtb` 指向 2 MiB / 20 MiB 假 payload 或缺失路径 | 判红 | 判据①（缺段）/ 判据⑥（超 1 MiB 窗口、超 16 MiB 器件容量）分别报红并拒绝出镜像 |
| ④ | 只改桩 `.equ` 不改打包脚本（双源漂移） | 判红 | `build_spi_image.sh` 判据③a / `check_stub_layout.sh` 判据②a 报红 |

反证流程一律 **`cp` 备份 → 变异 → 判红 → `cp` 恢复 → md5 逐文件确认一致**（**严禁** `git checkout/stash/reset`）。

## 7. 遗留 / 风险（交给母 Agent 与上板环节）

1. **上板未验**：本机无 qemu（`qemu-system-riscv32` 缺失），B-3.5 只到"构建 + 仿真桩"。
   上电期望（U-Boot 提示符）见 `sw/M5-board-runbook.md` §9；失败时按该节 10 项清单回报。
2. **DDR3 写是否"写直达"是隐藏前提**：当前基线 2A 核**数据侧全部走 ROUTE_AXI（MDTA 单 beat）**，
   L1D 只服务 XIP 与 PTE 读（`rtl/top/core_top.v` §9.3/§11.7 注释），因此桩 `sw` 完数据已在 DDR3、
   跳转后 OpenSBI 取指必然看到新内容。**若后续把 DDR3 数据通路接入 L1D 写回**，桩必须在跳转前
   把脏行推出去（`cbo.flush`/`cbo.clean` 或核侧保证写直达），否则 OpenSBI 会取到陈旧内容。
   `tb_boot_stub` 的 C6（W 拍数 == payload 字数 + 邮箱字数）就是这个前提的**看门狗**：一旦 DDR 写
   不再逐笔落总线，TB 立刻报红。
3. **XIP 别名窗口的真实语义与台账口径不一致（新发现，建议登记）**：按
   `chiplab/IP/SPI/godson_sbridge_spi.v:191-194`，`buf_addr_t = {8'h0, buf_addr[23:0]}`
   （仅当 `addr[31:20]==0x1FC` 时取 `[19:0]`）⇒
   · 主窗口 `0x1C00_0000+N` ⇒ Flash 偏移 **N**（`N < 1 MiB`，由 `axi_mux_syn.v` 的 `addr[31:20]==0x1C0` 命中）；
   · 别名 `0x1FE8_0000+N` ⇒ Flash 偏移 **0x00E8_0000+N**（不是"N"），且 `axi_mux_syn.v` 只按 `addr[31:16]==0x1FE8` 命中 ⇒ 别名窗口只有 64 KiB；
   · `addr[31:4]==0x1FE8_000`（16 B）另被 `io_hit` 判为 SPI **寄存器**窗口。
   本桩只走主窗口**读**，不受影响；但 `AGENT.md` §9 待办"XIP 写只能走 0x1FE8 别名"若按"N"理解会写错位置，
   建议母 Agent 复核后更新 `docs/kb/platform-facts.md` §2.3。
4. **Flash 里 bitstream 与引导镜像的共存**是**上板操作问题**（不是本任务范围）：核的 XIP 窗口只映射 Flash 偏移 0 起的 1 MiB，
   而桩必须落在偏移 0；若同时要把 FPGA 配置位流固化在 Flash 偏移 0，两者会冲突。
   当前 bring-up 口径：**bitstream 走 JTAG 下载（runbook §3 方式 A），Flash 只放引导镜像（偏移 0 起）**。
5. **`fw_jump.bin` 是 PIE（含 `.rela.dyn`/GOT，自搬移）**：本桩按 `FW_TEXT_START` 原样加载，
   与 OpenSBI 自身重定位逻辑不冲突（`firmware/fw_base.S` 的 relocate 用 PC 相对计算）。若换 OpenSBI 版本需重跑 `build_opensbi_rv32.sh` 的七项核对。
6. **无 ELF 校验上板路径**：镜像只做 md5 记录，不做签名/校验和自检；引导桩不做任何 payload 完整性校验
   （OpenSBI/U-Boot 自身也不做）。若需要"坏镜像不许起"的语义，属后续增强项。
