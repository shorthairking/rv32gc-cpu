/*==============================================================================
 * sim/lockstep/prog/link.ld —— Spike 锁步测试程序的链接脚本
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A，docs/design/08-baseline-5stage.md §8.3）
 *
 * 段布局（**两份**，理由见下）：
 *   .boot @ 0x1C00_0000 —— 复位跳转桩（2 条指令）。本核复位取指地址由
 *                           rtl/pkg/core_params.vh 的 `RV32GC_RESET_PC 固定为
 *                           0x1C00_0000（SPI XIP 主窗口），生产 RTL 不提供
 *                           0x8000_0000 别名（07-verification.md §4.3 明令禁止），
 *                           故必须在复位向量处放一条跳转到仿真布局的桩。
 *   .text @ 0x8000_0000 —— 测试程序主体（仿真布局；Spike 侧 `-m0x80000000:...`）。
 *
 * 为什么用自写链接脚本（不用 `-Ttext=`）：实测本机 ld（GCC 16.1.0）对
 *   `-Ttext=0x80000000` 会按 4 KiB 页对齐把 LOAD 段起点回退到 0x7FFF_F000
 *   （段内含 ELF 头），Spike 加载时因 0x7FFF_F000 不在 `-m` 映射内而报
 *   "Access exception occurred while loading payload"（已实测复现）。
 *   显式 SECTIONS 布局可让两个 LOAD 段分别精确落在 0x1C00_0000 / 0x8000_0000。
 *
 * 入口点 = `_boot`（0x1C00_0000）：
 *   · DUT 侧：core_top 复位后本来就取指 0x1C00_0000，与入口一致；
 *   · Spike 侧：跑锁步时传 `--pc=0x1C000000`，使 Spike 不执行其内置 boot ROM
 *     （否则轨迹里会多出 0x1000 起的 5 条 ROM 指令），两条轨迹从第 0 条起
 *     就能 1:1 对齐（见 sim/lockstep/run.sh 的 SPIKE_PC）。
 *============================================================================*/
OUTPUT_ARCH(riscv)
ENTRY(_boot)

SECTIONS
{
    /* ---- ① 复位跳转桩（SPI XIP 主窗口）---- */
    . = 0x1C000000;
    .boot : { *(.boot) }

    /* ---- ② 测试程序主体（仿真布局）---- */
    . = 0x80000000;
    .text : { *(.text) }

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
