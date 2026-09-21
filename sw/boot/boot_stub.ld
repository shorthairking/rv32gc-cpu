/*==============================================================================
 * rv32gc-cpu/sw/boot/boot_stub.ld —— 引导桩链接脚本
 *==============================================================================
 * 项目 : rv32gc-cpu（阶段三 B-3.5 引导链）
 * 依据 : docs/porting/01-overview.md §2.2（复位取指 0x1C00_0000、纯 PC 相对、不开 MMU）
 *        docs/kb/platform-facts.md §2.3（XIP 主窗口 1 MiB）
 *
 * 职责（三条硬口径）：
 *   ① **链接地址 = 0x1C00_0000**（= 复位取指 PC / XIP 主窗口基址）⇒ 镜像偏移 0 就是入口；
 *   ② 全部内容只放进 .text（桩无 .data/.bss/栈需求）⇒ `objcopy -O binary` 出来的
 *      boot_stub.bin 与"从 0x1C00_0000 起的连续字"逐字节一致（打包脚本据此按偏移切片）；
 *   ③ 桩自身 ≤ 16 KiB 槽位（BOOT_SLOT_BYTES）—— 由 ASSERT 在**链接期**兜底：
 *      超了直接链接失败（fail-closed），不会产出一个会踩到 OpenSBI 段的镜像。
 *==============================================================================*/

OUTPUT_ARCH(riscv)
ENTRY(_stub_start)

BOOT_BASE      = 0x1C000000;
BOOT_SLOT_BYTES = 0x4000;       /* 16 KiB：桩区槽位（下一段 OpenSBI 在 0x004000） */

SECTIONS
{
    . = BOOT_BASE;

    /* 代码在前（.text.init 内的 _stub_start 位于偏移 0 = 复位入口），段表紧随其后 */
    .text : {
        *(.text.init)
        *(.text .text.*)
    }

    /* 桩不应有可写数据；若将来有人加 .data/.rodata，一并放进同一连续区间，
       保证 objcopy -O binary 的偏移 = 物理地址 - BOOT_BASE */
    .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) }
    .data   : { *(.data .data.*) *(.sdata .sdata.*) }

    _stub_image_end = .;

    /* 链接期 fail-closed：桩超出槽位即链接失败 */
    ASSERT(. <= BOOT_BASE + BOOT_SLOT_BYTES,
           "boot_stub exceeds its 16 KiB slot (check sw/boot/boot_stub.ld)")

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.riscv.attributes)
        *(.bss .bss.*)
        *(.sbss .sbss.*)
    }
}
