#==============================================================================
# rv32gc-cpu/sw/boot/boot_stub.S —— SPI Flash XIP 引导桩（复位入口 0x1C00_0000）
#==============================================================================
# 项目  : rv32gc-cpu（阶段二 2A 基线核 M1–M5 已收官；本文件为阶段三 B-3.5 引导链）
# 规格  : docs/porting/01-overview.md §2.2/§2.3/§2.4（阶段 A/B/C 启动流程与 DDR 布局）
#         docs/kb/platform-facts.md §2.3（XIP 主窗口/别名）、§5（33 MHz 同域）
#         AGENT.md §3.1（平台硬事实：RESET_PC=0x1C000000、无 boot ROM、XIP 取指绕 I-Cache）
# 任务  : B-3.5 —— 从 SPI Flash XIP 启动 → 把 OpenSBI/U-Boot/DTB 拷进 DDR3 → 跳 OpenSBI
#
#------------------------------------------------------------------------------
# 一、这个桩做什么（唯一职责）
#------------------------------------------------------------------------------
#   复位时 PC = 0x1C00_0000（平台无 boot ROM ⇒ 取指必须落在 SPI XIP 窗口）。
#   本桩在这片窗口里就地执行，按**段表**把三段 payload 从 SPI Flash 拷到 DDR3：
#
#       OpenSBI fw_jump.bin  Flash @0x004000  → DDR3 @0x0100_0000   （M 模式，入口）
#       U-Boot u-boot.bin    Flash @0x080000  → DDR3 @0x0200_0000   （S 模式，OpenSBI 跳它）
#       U-Boot DTB           Flash @0x0E8000  → DDR3 @0x0300_0000   （= FW_JUMP_FDT_ADDR）
#
#   拷完置入口寄存器（RISC-V 惯例）后跳 OpenSBI 入口：
#       a0 = hart id（本平台单核 ⇒ 0）
#       a1 = DTB 物理地址（0x0300_0000）
#       a2 = 平台私有信息（0；OpenSBI 不使用）
#
#------------------------------------------------------------------------------
# 二、硬约束（逐条对应验收判据，改本文件前先读）
#------------------------------------------------------------------------------
#   ① **纯 PC 相对**：段表指针用 `auipc + addi`（汇编期解析标签差 ⇒ 无重定位）；
#      取指/取数都在 XIP 窗口内，不依赖任何绝对地址假设（sw/boot/README.md §2）。
#   ② **不开 MMU**：全程序**不执行任何 CSR 指令**（无 satp/mstatus/mtvec），
#      复位后 satp.MODE=Bare ⇒ 取指与数据全走物理地址。
#      机器核对：build_spi_image.sh 判据⑧d（反汇编里 csrr* / sfence/fence.i/ecall 等必须 0 条）。
#   ③ **只用 lw / sw**：拷贝按 4 字节整字进行（段长一律 4 的倍数，由打包脚本补齐并
#      机器核对 ⇒ 见 build_spi_image.sh 判据④）；不使用 lb/lh/sb/sh，避免字节道/非对齐口径混入。
#   ④ **不写 Flash**：XIP 窗口写必须走 0x1FE8_0000 别名（平台口径，见 AGENT.md §3.1）；
#      本桩只读 Flash（读主窗口 0x1C00_0000 直读 OK），因此不涉及别名写通路。
#   ⑤ **不用栈、不用 ra**：无 call/ret、无 sp 访存（判据⑧f 机器核对 x2 基址访存 = 0）。
#   ⑥ **失败即停**：跳转指令之后是不可达的原地循环（异常/意外返回时不会跑飞）。
#
#------------------------------------------------------------------------------
# 三、段表（**布局唯一真源**）
#------------------------------------------------------------------------------
#   下面的 .equ 常量块就是镜像布局的真源：
#     · sw/boot/build_spi_image.sh 解析本块，并与脚本自己的 LAYOUT_* 声明**逐项比对**
#       （不一致 ⇒ rc=1，不许双源漂移）；同时核对各段长度与 payload 实际大小一致。
#     · sw/boot/check_stub_layout.sh 做独立的机器一致性核对（源码 .equ ↔ 脚本布局 ↔
#       **已打包镜像的分段切片**三方对账）。
#   因此：**任何**布局改动都必须同时改本块与 build_spi_image.sh 的 LAYOUT_* 声明，
#   然后重跑两个脚本；只改一边一定报红。
#
#   ★ 段长 = payload 实际字节数**向上补齐到 4 的倍数**（打包脚本按此裁切/补齐；
#     u-boot.bin 398 330 B 不是 4 的倍数 ⇒ 段长 398 332）。
#   ★ 偏移一律 16 KiB 对齐（除桩自身 @0）；各段互不重叠；全镜像 ≤ 1 MiB
#     （XIP 主窗口只有 1 MiB，超出部分在 0x1C10_0000 之上会落 DDR3 默认从设备）。
#
#------------------------------------------------------------------------------
# 四、寄存器用途（全部直进直出，不遵守 ABI 调用约定）
#------------------------------------------------------------------------------
#   a4(x14) = 段表游标（XIP 窗口内地址，auipc 建立）
#   a5(x15) = 剩余段数
#   t0(x5)  = 段内源地址（= 0x1C00_0000 + 段偏移）
#   t1(x6)  = 段内目的地址（DDR3 物理地址）
#   t2(x7)  = 段内剩余字节数（每轮 -4）
#   t3(x28) = 常量 BOOT_FLASH_BASE
#   t4(x29) = 当前搬运的字
#   进入 OpenSBI 前重写 a0/a1/a2（见 §一）。
#
#------------------------------------------------------------------------------
# 五、编译（见 sw/boot/build_spi_image.sh，工具链 /opt/riscv/bin/riscv32-unknown-linux-gnu-）
#------------------------------------------------------------------------------
#   -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -nostartfiles -ffreestanding
#   -Wl,-T,sw/boot/boot_stub.ld -Wl,-e,_stub_start -Wl,--build-id=none
#   产物：boot_stub.elf / boot_stub.bin（≤ 16 KiB 槽位，boot_stub.ld 内有 ASSERT 兜底）
#==============================================================================

#==============================================================================
# 段表常量块（唯一真源；build_spi_image.sh / check_stub_layout.sh 解析本块）
#==============================================================================
    .equ BOOT_FLASH_BASE,   0x1C000000     # XIP 主窗口基址（读直通；PA[31:20]==0x1C0）
    .equ BOOT_FLASH_ALIAS,  0x1FE80000     # XIP 别名窗口（本桩不用：只读不必绕别名）
    .equ BOOT_XIP_SIZE,     0x00100000     # XIP 主窗口大小 = 1 MiB（镜像总长上界）

    .equ BOOT_SEG_COUNT,    3              # 段数（必须 == 下面 .word 表项数 == 脚本段数）

    # ---- 段 1：OpenSBI fw_jump.bin（M 模式固件，跳转目标 = 其入口）----
    .equ BOOT_SRC_OPENSBI,  0x004000       # Flash 内偏移
    .equ BOOT_DST_OPENSBI,  0x01000000     # DDR3 目的地址（FW_TEXT_START）
    #   ★ 段长度允许**仿真构型覆盖**：`.ifndef` 守卫使 `-Wa,--defsym,BOOT_LEN_*=小值`
    #     生效 —— sim/unit/tb_boot_stub.sv 用"小 payload"跑**同一份桩源码**（避免仿真里
    #     真拷 900 KB），偏移/目的地址与真实构型完全一致，只有长度不同。
    #     未覆盖时用下面的默认值 = **真实 payload 大小**（打包镜像口径）。
    .ifndef BOOT_LEN_OPENSBI
    .equ BOOT_LEN_OPENSBI,  0x000426D0     # 272 080 B（fw_jump.bin，已是 4 的倍数）
    .endif

    # ---- 段 2：U-Boot u-boot.bin（S 模式，CONFIG_TEXT_BASE=0x0200_0000）----
    .equ BOOT_SRC_UBOOT,    0x080000
    .equ BOOT_DST_UBOOT,    0x02000000
    .ifndef BOOT_LEN_UBOOT
    .equ BOOT_LEN_UBOOT,    0x000620AC     # 401 580 B（u-boot.bin 401 578 B 补齐到 4，E6-E8 修复后重编）
    .endif

    # ---- 段 3：U-Boot 设备树（OpenSBI 按 FW_JUMP_FDT_ADDR 传给下一级）----
    .equ BOOT_SRC_DTB,      0x0E8000
    .equ BOOT_DST_DTB,      0x03000000
    .ifndef BOOT_LEN_DTB
    .equ BOOT_LEN_DTB,      0x00001774     # 6 004 B（u-boot.dtb 6 002 B 补齐到 4）
    .endif

    # ---- 跳转与入口寄存器口径 ----
    .equ BOOT_NEXT_ENTRY,   0x01000000     # OpenSBI 入口（= BOOT_DST_OPENSBI）
    .equ BOOT_FDT_DST,      0x03000000     # 传给 OpenSBI 的 a1（= BOOT_DST_DTB）
    .equ BOOT_HARTID,       0              # 本平台单核 ⇒ a0 = 0

#==============================================================================
# 代码
#==============================================================================
    .section .text.init, "ax", @progbits
    .globl   _stub_start
    .align   2
    .option  norvc                 # 全程 32 bit 指令（与冻结核取指口径一致）

_stub_start:
    # ---- 段表指针（PC 相对）：auipc %pcrel_hi + addi %pcrel_lo ----
    #   就地取"当前 PC + 段表相对偏移"⇒ 汇编/链接期解析成 auipc+addi 常量对，
    #   链接后的可执行文件**零重定位**（判据⑧c readelf -r）；运行期不假设代码被
    #   放在某个绝对地址。%pcrel_lo 必须引用其配对的 auipc 处的**局部标签**。
.Lstub_pcrel_hi0:
    auipc   a4, %pcrel_hi(stub_seg_table)
    addi    a4, a4, %pcrel_lo(.Lstub_pcrel_hi0)

    li      t3, BOOT_FLASH_BASE    # Flash 读地址基址（循环内复用）
    li      a5, BOOT_SEG_COUNT     # 剩余段数

#------------------------------------------------------------------------------
# 段循环：a4 指向 12 B 表项 {src 偏移, dst 物理地址, 字节长度}
#------------------------------------------------------------------------------
seg_next:
    lw      t0, 0(a4)              # 段源偏移（Flash 内）
    lw      t1, 4(a4)              # 段目的地址（DDR3）
    lw      t2, 8(a4)              # 段长度（4 的倍数，非 0）
    addi    a4, a4, 12             # 游标推进到下一表项
    add     t0, t0, t3             # 源地址 = 0x1C00_0000 + 偏移（XIP 主窗口）

#------------------------------------------------------------------------------
# 字拷贝循环：lw / sw 各一笔（本核 DDR 写走 MDTA 单 beat AXI 且在提交前等 B 响应
#   —— core_top.v §13 M_S_AXI ⇒ 循环结束即数据已落到 DDR3，无需 fence/刷缓存）
#------------------------------------------------------------------------------
word_copy:
    lw      t4, 0(t0)              # 读 Flash（XIP 直读）
    sw      t4, 0(t1)              # 写 DDR3
    addi    t0, t0, 4
    addi    t1, t1, 4
    addi    t2, t2, -4
    bne     t2, zero, word_copy

    addi    a5, a5, -1             # 下一段
    bne     a5, zero, seg_next

#------------------------------------------------------------------------------
# 进入 OpenSBI：a0=hartid、a1=DTB 物理地址、a2=平台私有信息；跨窗口跳转用显式地址
#------------------------------------------------------------------------------
    li      a0, BOOT_HARTID
    li      a1, BOOT_FDT_DST
    li      a2, 0
    li      t0, BOOT_NEXT_ENTRY
    jalr    x0, 0(t0)              # rd=x0 ⇒ 不写 ra，纯跳转（跨窗口：目标在 DDR3）

# 不可达（防御）：若 OpenSBI 意外返回/跳转未生效，停在这里而不是跑飞
_stub_halt:
    j       _stub_halt

#==============================================================================
# 段表（12 B/项，顺序即拷贝顺序；src/dst/len 全部由上面的 .equ 生成）
#   打包脚本会用 nm + 镜像切片机器核对本表的字面值（判据⑨）。
#==============================================================================
    .align   2
    .globl   stub_seg_table
stub_seg_table:
    .word   BOOT_SRC_OPENSBI, BOOT_DST_OPENSBI, BOOT_LEN_OPENSBI
    .word   BOOT_SRC_UBOOT,   BOOT_DST_UBOOT,   BOOT_LEN_UBOOT
    .word   BOOT_SRC_DTB,     BOOT_DST_DTB,     BOOT_LEN_DTB
    .globl   stub_seg_table_end
stub_seg_table_end:
