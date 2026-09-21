/*==============================================================================
 * sim/unit/prog/front4_int.S —— 2B-1 前端集成验证用程序（黄金轨迹来源）
 *==============================================================================
 * 用途：给 sim/unit/tb_front4_integration.sv 提供"真实指令流"：
 *   ① 用 /opt/riscv 工具链汇编/链接（链接脚本 sim/unit/prog/front4_int.ld，
 *      起始 0x8000_0000，Spike 习惯布局）；
 *   ② 用 Spike（--log-commits）跑出**架构提交 PC 序列** = 黄金轨迹；
 *   ③ TB 内嵌"程序映像 + 黄金 PC 轨迹"（脚本生成的 .svh，见 README §5），
 *      前端交付的指令流必须与黄金轨迹逐条一致（分歧由 TB 的"后端参照模型"
 *      在检测到分歧时发重定向纠正，分歧计数必须是 0 以外的可解释数——见 TB 判据）。
 *
 * 程序特征（覆盖 02/04 关心的分支场景）：
 *   · 两层嵌套循环 + 数据相关的交替方向分支（c.addi / bne 交替）
 *   · 二级调用-返回（jal / c.jalr 压栈、c.jr 返回 ⇒ RAS 有内容、有深度变化）
 *   · 直接跳转（j）/ 无条件跳转、RVC 与 32 bit 指令混排（跨字/跨行拼接）
 *   · 结尾 ebreak（Spike 停住；黄金轨迹截到 ebreak 之前）
 *
 * 生成命令（**真源，可重跑**）：
 *   cd rv32gc-cpu
 *   /opt/riscv/bin/riscv32-unknown-linux-gnu-gcc -march=rv32imac_zicsr -mabi=ilp32 \
 *       -nostdlib -nostartfiles -Wl,-T,sim/unit/prog/front4_int.ld \
 *       -o /tmp/front4_int.elf sim/unit/prog/front4_int.S
 *   /opt/riscv/bin/spike --isa=rv32imac_zicsr --pc=0x80000000 \
 *       -m0x80000000:0x100000,0x1FE00000:0x1000 \
 *       --log-commits --log=/tmp/front4_int.pc.log /tmp/front4_int.elf
 *   python3 sim/unit/prog/gen_front4_int_data.py /tmp/front4_int.elf /tmp/front4_int.pc.log \
 *       > sim/unit/prog/front4_int_data.svh
 *==============================================================================*/

    .section .text
    .globl _start

_start:
    li      sp, 0x80002000          /* 栈（TB 里是普通内存；不写外设） */
    li      x5, 0                   /* 累计计数（数据相关分支用） */
    li      x6, 4                   /* 外层循环 4 次 */

outer:
    li      x7, 6                   /* 内层循环 6 次 */

inner:
    c.addi  x5, 1                   /* RVC 16 bit */
    andi    x8, x5, 1               /* x8 = x5 & 1（交替 0/1） */
    beq     x8, x0, inner_even      /* 数据相关：奇偶交替 ⇒ 方向交替 */
inner_even:
    c.addi  x5, 1                   /* RVC */
    addi    x7, x7, -1
    bne     x7, x0, inner           /* 内层回边（taken 多、最后不跳） */
    jal     x1, sub1                /* 一级调用（压 RAS） */
    addi    x6, x6, -1
    bne     x6, x0, outer           /* 外层回边 */
    j       done                    /* 直接跳转 */

/* ---- 一级子函数：二级调用（先保存 x1 到栈上）---- */
sub1:
    addi    sp, sp, -8
    sw      x1, 0(sp)               /* 保存返回地址 */
    li      x9, 3
sub1_loop:
    c.addi  x9, -1                  /* RVC */
    bne     x9, x0, sub1_loop
    jal     x1, sub2                /* 二级调用（RAS 变深） */
    lw      x1, 0(sp)               /* 恢复返回地址 */
    addi    sp, sp, 8
    c.jr    x1                      /* c.jr ra ⇒ ret（RAS 弹出） */

/* ---- 二级子函数 ---- */
sub2:
    li      x10, 2
sub2_loop:
    addi    x10, x10, -1
    beq     x10, x0, sub2_done
    j       sub2_loop               /* 直接跳转回边 */
sub2_done:
    c.jr    x1                      /* ret */

done:
    /* 结束哨兵：写 UART 数据寄存器（平台窗口），随后 ebreak 让 Spike 停住 */
    li      x11, 0x1FE001E0
    li      x12, 0x5A
    sw      x12, 0(x11)
    ebreak
