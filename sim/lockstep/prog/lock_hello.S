#==============================================================================
# sim/lockstep/prog/lock_hello.S —— Spike 锁步定向测试程序
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A）；依据 docs/design/08-baseline-5stage.md §8.3
#        （"Spike 锁步"：以指令提交为单位逐条比对 PC 与 rd 写值）
#
# 一、跑法（由 sim/lockstep/run.sh 驱动，此处只记口径）
#------------------------------------------------------------------------------
#   as   : riscv32-unknown-linux-gnu-as -march=rv32im_zicsr -o lock_hello.o lock_hello.S
#   ld   : riscv32-unknown-linux-gnu-ld -T prog/link.ld -o lock_hello.elf lock_hello.o
#   hex  : riscv32-unknown-linux-gnu-objcopy -O verilog --verilog-data-width=4 \
#              lock_hello.elf lock_hello.hex        # 两个 @ 段：@07000000 / @20000000
#   DUT  : iverilog/vvp 跑 sim/lockstep/tb_lockstep.sv（core_top + sim_mem_model）
#   REF  : /opt/riscv/bin/spike --pc=0x1C000000 --log-commits --log=spike.trace \
#              --isa=rv32imafdc_zicsr_zifencei_zicntr_zicbom \
#              -m0x1C000000:0x1000000,0x80000000:0x10000000 lock_hello.elf
#
# 二、地址布局（与 prog/link.ld 一致）
#------------------------------------------------------------------------------
#   0x1C00_0000  .boot 复位跳转桩：lui t0,0x80000 / jalr x0,0(t0) → 0x8000_0000
#               （本核 RESET_PC 固定为 XIP 主窗口，生产 RTL 禁止 0x8000_0000 别名）
#   0x8000_0000  _start 程序主体（仿真布局，Spike 与 DUT 在此 1:1 对齐）
#   0x8000_1000  scratch 数据区（循环内 sw/lw 往返回读，供 rd 比对覆盖访存数据）
#   0x8000_2000  魔数结束标记（MAGIC = 0x600D_5EED，任务口径）
#   0x1FE0_01E0  UART 数据寄存器：写 1 字节 0x5A 作"结束铃"。该地址属平台外设窗口
#               （PA[31:16]==0x1FE0），本核按 **非缓存** 走 AXI（PMA 见
#               rtl/mem/mmio_route.v §2.3/§4，AxCACHE=4'b0000），因此结束铃在
#               AXI 上可见，sim_mem_model 会捕获（uart_tx_count/uart_char），
#               TB 用它作为"程序真的跑到结尾"的独立证据（不依赖缓存回写时序）。
#   0x8000_00xx  lockstep_spin 末尾死循环（TB 以该 PC 的提交为终止点，见下）
#
# 三、内容（任务要求：整数算术/分支/访存混合 + 少量 M/CSR，≥60 条指令）
#------------------------------------------------------------------------------
#   ① 4 轮循环：addi/slli/add/mul/addi/sw/lw/xor/or/srli/sltu/bne（含访存往返）
#   ② M 扩展：mul/mulh/mulhu/div/divu/rem/remu + sub/srai/slt
#   ③ 半字/字节访存：sh/lhu/lh/sb/lbu/lb（全部自然对齐，避免触发非对齐异常）
#   ④ 分支与跳转：beq/blt/bgeu/bge 双向 + jal(link)/jalr 子程序调用返回
#   ⑤ CSR（M 模式，少量）：csrrw/csrrs/csrrc/csrr × mscratch、csrr mhartid/mcause
#   ⑥ 结束：sw MAGIC→0x8000_2000；sw 0x5A→UART 结束铃；lockstep_spin 死循环
#
#   ④ 指令数：本文件主体约 100 条（不含 2 条跳转桩），远超 N≥60 的下限。
#
# 四、纪律（为什么这么写）
#------------------------------------------------------------------------------
#   · `.option norvc`：全程 32 bit 指令。TB 的提交 trace 逐条记 debug0_wb_pc，
#     压缩指令会让"每提交一条一行 vs PC"的对齐口径复杂化，锁步底座不引入该变量
#     （C 扩展的锁步留给 arch-test L2 层的专用用例）。
#   · **不读任何计数器**（mcycle/minstret/mtime）：DUT 与 Spike 的周期数不同，
#     读它必然产生"伪分歧"。锁步程序只读架构确定的 CSR。
#   · **不用浮点指令**：2A 的提交探针 debug0_wb_rf_wen 对 FP 写回也置位 [0]
#     （core_top.v:2755 的 `mw_fp_we` 分支），而 rd 号是浮点寄存器号，与整数
#     写无法区分 ⇒ 会把 FP 写当整数写比对而假失败。浮点比对不在本任务判据内
#     （任务口径："浮点先不比对"），故本程序不出现 F/D 指令。
#   · **不打桩/不夹带**：程序不写 mtvec、不执行 ecall/ebreak、不做非对齐访问，
#     保证"提交序列 = 程序文本顺序"这一锁步前提成立。
#==============================================================================

    .option norvc

#------------------------------------------------------------------------------
# 复位跳转桩（0x1C00_0000）：本核复位取指地址，跳到仿真布局主体
#------------------------------------------------------------------------------
    .section .boot, "ax"
    .globl  _boot
    .align  2
_boot:
    lui     t0, 0x80000             # t0 = 0x8000_0000
    jalr    x0, 0(t0)               # 跳转（不写链接寄存器）

#------------------------------------------------------------------------------
# 程序主体（0x8000_0000）
#------------------------------------------------------------------------------
    .section .text, "ax"
    .globl  _start
    .align  2
_start:
    # ---- ① 整数算术 + 4 轮循环（访存往返）----------------------------------
    lui     s0, 0x80001             # s0 = 0x8000_1000（scratch 基址）
    addi    t1, x0, 0               # i = 0
    addi    t2, x0, 4               # N = 4
1:  addi    t1, t1, 1               # i++
    slli    t3, t1, 2               # i*4
    add     t3, s0, t3              # &scratch[i]
    mul     t4, t1, t1              # i*i          （M 扩展）
    addi    t4, t4, 291             # +0x123
    sw      t4, 0(t3)               # 存
    lw      t5, 0(t3)               # 取回
    xor     t5, t5, t4              # 必为 0
    or      t6, t5, t1
    srli    t6, t6, 1
    sltu    a0, t6, t2
    bne     t1, t2, 1b              # 前 3 轮 taken，第 4 轮不 taken

    # ---- ② M 扩展逐条覆盖 --------------------------------------------------
    addi    a1, x0, 7
    addi    a2, x0, 3
    mul     a3, a1, a2              # 21
    mulh    a4, a1, a2              # 0
    mulhu   s1, a1, a2              # 0
    div     a5, a1, a2              # 2
    divu    a6, a1, a2              # 2
    rem     a7, a1, a2              # 1
    remu    s2, a1, a2              # 1
    sub     s3, a2, a1              # -4
    srai    s4, s3, 1               # -2
    slt     s5, s3, a1              # 1

    # ---- ③ 半字/字节访存（自然对齐）----------------------------------------
    lui     t0, 0x80001             # 0x8000_1000
    addi    t0, t0, 16              # → 0x8000_1010
    lui     t1, 0x1
    addi    t1, t1, 564             # t1 = 0x1234
    sh      t1, 0(t0)               # 半字存
    lhu     t2, 0(t0)               # 零扩展取回 → 0x1234
    lh      t3, 0(t0)               # 符号扩展取回 → 0x1234
    sb      t1, 4(t0)               # 字节存（低字节 0x34）
    lbu     t4, 4(t0)               # 零扩展 → 0x34
    lb      t5, 4(t0)               # 符号扩展 → 0x34
    add     t6, t2, t3              # 0x2468

    # ---- ④ 分支与跳转 ------------------------------------------------------
    addi    t0, x0, 5
    addi    t1, x0, 5
    beq     t0, t1, 2f              # taken
    addi    t0, t0, 100             # （不执行）
2:  addi    t2, x0, -1
    blt     t2, t1, 3f              # taken（-1 < 5）
    addi    t2, t2, 100             # （不执行）
3:  addi    t3, x0, 3
    bgeu    t3, t0, 4f              # 3 >=u 5 ? 否 ⇒ 不跳
    addi    t3, t3, 16              # 执行 → 0x13
4:  addi    t4, x0, -3
    bge     t4, t3, 5f              # -3 >= 0x13 ? 否 ⇒ 不跳
    addi    t4, t4, 32              # 执行 → 0x1D
5:  jal     ra, sub1                # 调用（ra = 下一条指令地址）
    jal     x0, 7f                  # 子程序返回后落到这里 ⇒ 跳到 7f
sub1:
    addi    t5, x0, 85              # 被调用体（jal 与 jalr(link) 都需覆盖）
    jalr    x0, 0(ra)               # 返回
7:  addi    t5, t5, 1               # 0x56

    # ---- ⑤ CSR（M 模式；只碰架构确定的 CSR，不读计数器）--------------------
    # ★ 口径说明（2026-09-15 实测发现，**不是**本程序的口味问题）：
    #   2A 当前 RTL 存在 **CSR 写→紧邻读读到旧值** 的缺陷（k=0：写指令的下一条
    #   就读同一 CSR）。根因：core_top.v:1104 的 CSR 读旁路只覆盖"W 阶段写"，
    #   缺 **M 阶段写 → E 阶段读（k=0）** 那一级（详见 prog/csr_hazard.S 与
    #   docs 侧报告）。k>=1 已被 W→E 旁路覆盖 ⇒ 本程序在 CSR 写与读回之间**保留
    #   至少 2 条无关指令**，使锁步比对在 RTL 修复前也能全绿；k=0 的用例由
    #   `prog/csr_hazard.S` 独立复现（run.sh --prog csr_hazard 必 FAIL）。
    #   **RTL 修复后**应把 k=0 的紧邻读回加回本程序（回归保护）。
    lui     s6, 0xABCDE             # s6 = 0xABCD_E000
    csrrw   s7, mscratch, s6        # 写 mscratch；s7 ← 旧值（复位值 0）
    csrr    t0, mhartid             # 间隔指令①（单核 ⇒ 0）
    csrr    s8, mscratch            # k=2 读回 ⇒ 0xABCD_E000
    csrrs   s9, mscratch, x0        # 只读形式（rs1=x0 不写）；k=3
    csrrc   s10, mscratch, s6       # 清位 ⇒ mscratch = 0；s10 ← 0xABCD_E000
    csrr    t1, mcause              # 间隔指令②（未发生陷阱 ⇒ 0）
    csrr    s11, mscratch           # k=2 读回 ⇒ 0

    # ---- ⑥ 结束：魔数标记 + UART 结束铃 + 死循环 ---------------------------
    lui     t0, 0x80002             # 0x8000_2000
    li      t1, 0x600D5EED          # MAGIC（lui+addi 两条，架构确定）
    sw      t1, 0(t0)               # 魔数落 0x8000_2000
    lui     t2, 0x1FE00
    addi    t2, t2, 480             # t2 = 0x1FE0_01E0（UART 数据寄存器）
    addi    t3, x0, 90              # 0x5A 结束铃
    sw      t3, 0(t2)               # 非缓存 ⇒ AXI 可见（TB/Spike 双方都能验证）

    .globl  lockstep_spin
lockstep_spin:
1:  j       1b                      # TB 以该 PC 的提交为终止点（此后不再记 trace）
