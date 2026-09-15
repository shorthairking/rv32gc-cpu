/*==============================================================================
 * sim/arch_test/link.ld —— ACT4（riscv-arch-test）专用链接脚本
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A 基线核；docs/design/08-baseline-5stage.md §8.2）
 * 用途 : `sim/arch_test/run.sh` 编译 arch-test 用例时使用（-T link.ld）。
 *        链接进 ELF 的内容 = 用例 .S 编译产物 + boot_stub.S + libgcc 必要件，
 *        由 rvtest_entry_point（.text.init 首址）开始执行。
 *
 * 一、段布局（**两份**，理由见二）
 *------------------------------------------------------------------------------
 *   .boot        @ 0x1C00_0000 —— 复位跳转桩（2 条指令，见 boot_stub.S）。
 *                                 本核复位取指地址由 rtl/pkg/core_params.vh 的
 *                                 `RV32GC_RESET_PC 固定为 0x1C00_0000（SPI XIP 主窗口，
 *                                 平台无 boot ROM），且 07-verification.md §4.3 明令
 *                                 禁止在生产 RTL 里放 0x8000_0000 别名逻辑 ⇒ 必须在
 *                                 复位向量处放一条跳到仿真内存布局（0x8000_0000）的桩。
 *                                 DUT 与 Spike 跑同一份 ELF、同一入口 ⇒ 两侧行为对称。
 *   .text.init   @ 0x8000_0000 —— 用例入口 rvtest_entry_point（TEST_BASE）。
 *   其余段       —— 顺序沿用 riscv-arch-test 官方 link.ld（config/spike/spike-rv64-max/
 *                   link.ld）：.text.rvtest → .rodata → .data → .bss → 栈 →
 *                   .text.rvmodel（**必须**排在 .data 之后，否则 DUT 与参考模型的
 *                   数据地址可能不一致，见 riscv-arch-test/AGENTS.md "Linker scripts"）。
 *   .tohost      @ RAM_ORIGIN+0x000F_F000 —— tohost/fromhost（RVMODEL_DATA_SECTION）。
 *                                 固定地址：TB 用它做终止探测（写 1 = PASS、写 3 = FAIL）。
 *                                 run.sh 会用 nm 复核 tohost == 该常量（fail-closed）。
 *
 * 二、为什么用「自写链接脚本 + 复位桩」而不是让 TB 注入跳转
 *------------------------------------------------------------------------------
 *   ① 同一份 ELF 同时喂给 DUT 仿真与 Spike（参考签名由 Spike 跑同一份 ELF 得出），
 *      复位桩写进镜像 ⇒ 两侧入口、内存内容逐字节一致，不存在"TB 补丁 vs Spike 无补丁"
 *      的不对称（对称性 = 签名可比性的前提）。
 *   ② 复位桩放在 .boot 段而不是改 RTL 常量：rtl/** 是只读件（本任务范围外）。
 *
 * 三、内存口径
 *------------------------------------------------------------------------------
 *   RAM_ORIGIN = 0x8000_0000（仿真布局；**不是**平台 DDR3 的 0x0 —— 平台编址见
 *   docs/kb/platform-facts.md §2，此处只在仿真内存模型里映射，生产 RTL 无别名）。
 *   RAM_LENGTH = 1 MiB，与 sim/tb/tb_arch_test.sv 的从设备存储体同尺寸；
 *   Spike 侧用 `-m0x80000000:0x100000,0x1c000000:0x1000` 对齐同一布局。
 *============================================================================*/
RAM_ORIGIN  = 0x80000000;
RAM_LENGTH  = 0x00100000;              /* 1 MiB（TB 存储体同尺寸）*/
TEST_BASE   = RAM_ORIGIN;
NUM_HARTS   = 1;

BOOT_ORIGIN = 0x1C000000;              /* 复位向量（= `RV32GC_RESET_PC）*/
BOOT_LENGTH = 0x00000100;
TOHOST_BASE = RAM_ORIGIN + 0x000FF000; /* tohost/fromhost 固定地址（TB 终止探测点）*/

/* 官方 link.ld 默认值（勿随意改：改栈大小会改变数据地址） */
STACK_SIZE = 0x20000;

OUTPUT_ARCH( "riscv" )
ENTRY(_boot)

MEMORY
{
  ram  (rwx) : ORIGIN = RAM_ORIGIN,  LENGTH = RAM_LENGTH
  boot (rwx) : ORIGIN = BOOT_ORIGIN, LENGTH = BOOT_LENGTH
}

PROVIDE(__stack_size = STACK_SIZE);
PROVIDE(__num_harts = NUM_HARTS);

SECTIONS
{
  /* ---- ① 复位向量桩（必须在 0x1C00_0000 精确落位）---- */
  .boot BOOT_ORIGIN : { KEEP(*(.boot)) } > boot

  /* ---- ② 用例镜像 ---- */
  ASSERT(TEST_BASE >= ORIGIN(ram) && TEST_BASE < ORIGIN(ram) + LENGTH(ram),
         "TEST_BASE is outside RAM; update TEST_BASE/RAM_ORIGIN/RAM_LENGTH in link.ld")

  .text.init   TEST_BASE : { *(.text.init) } > ram
  .text.rvtest . : { *(.text.rvtest) *(.text.rvtest.*) } > ram

  . = ALIGN(0x4000);
  .rodata . : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > ram
  .data   . : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) } > ram

  . = ALIGN(16);
  .bss . : {
    __bss_start = .;
    *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > ram

  . = ALIGN(16);
  __stack_bottom = .;
  . += __stack_size * __num_harts;
  __stack_top = .;

  . = ALIGN(0x1000);
  .text.rvmodel . : { *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) } > ram

  /* ---- ③ tohost/fromhost：固定地址（TB 终止探测点；run.sh 用 nm 复核）---- */
  .tohost TOHOST_BASE : { KEEP(*(.tohost)) } > ram

  . = ALIGN(0x1000);
  _end = .;

  ASSERT(_end <= ORIGIN(ram) + LENGTH(ram),
         "ACT ELF exceeds RAM; increase RAM_LENGTH in link.ld")
  ASSERT(ADDR(.tohost) == TOHOST_BASE,
         "tohost section not placed at TOHOST_BASE")

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
