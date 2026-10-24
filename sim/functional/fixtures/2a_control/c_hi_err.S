#==============================================================================
# sim/functional/fixtures/2a_control/c_hi_err.S
#   取指通道**总线错误**（AXI SLVERR/DECERR）的 mepc/tval 精确性（08-06/10-22）
#------------------------------------------------------------------------------
# 编译期变体（-D 其一）：
#   ERR_FIRST  4 对齐 32 bit 指令所在行取指错（合法正常/首字错误对照）
#   ERR_HI16   2 mod 4 的**16 bit** 指令所在行取指错（高半 16 bit 对照）
#   ERR_HI32   2 mod 4 的**32 bit** 指令在 32 B 行尾 ⇒ 第二 parcel 在下一行（跨字）
#   ERR_HI32PG 同上但指令在 4 KiB 页尾 ⇒ 第二 parcel 在**下一页**首行（跨页）
#   ERR_LATE   同 HI32 + 外中断在 hi32 在途时取消旧 carry；**迟到的总线错误**
#              不得污染中断处理流；mret 回来重取时再真报 AF
# 布局约束：OK/BAD/FINISH/handler 全部放在**所有错误行之前**（错误行只含填充与
#   永不执行的字节），否则处理程序自身会落在中毒行上。
# 期望：
#   所有 AF：mcause=1；mepc = **指令起始** t_insn；tval = **故障 parcel**
#     （首字错 = t_insn；第二字错 = t_insn+2）；故障指令零提交；恰 1 次陷阱
#   0x2000 主标记 0x600D；0x2010/14/18/1C mcause/mepc/mtval/总陷阱数
#   0x202C/30/34/38/3C（仅 LATE）int 次数/AF 次数/AF cause/AF mepc/AF tval
#   0x2FFC DONE
#==============================================================================
    .option norvc
    .section .text
    .globl _start
_start:
    li   t0, 4
1:  addi t0, t0, -1
    bnez t0, 1b
    la   t0, handler
    csrw mtvec, t0
    csrw mie, x0
    li   t4, 0x600d

#ifdef ERR_LATE
    # PLIC 源 1 → MEIP；MIE=1
    li   s0, 0x1f100000
    li   t1, 1
    sw   t1, 4(s0)
    li   t3, 0x1f102000
    li   t1, 2
    sw   t1, 0(t3)
    li   t3, 0x1f300000
    sw   x0, 0(t3)
    li   t1, 0x800
    csrw mie, t1
    li   t2, 8
    csrs mstatus, t2
    la   t0, nop_start
    jalr x0, 0(t0)
#else
    la   t0, t_insn
    jalr x0, 0(t0)
#endif
    j    bad

#------------------------------------------------------------------------------
# 退出/恢复/处理程序（必须在所有"中毒行"之前）
#------------------------------------------------------------------------------
bad:
    li   t3, 0x2000
    li   t4, 0xbad
    sw   t4, 0(t3)
    j    finish

ok:
    li   t3, 0x2000
    li   t4, 0x600d
    sw   t4, 0(t3)
    j    finish

finish:
    li   t4, 0x2ffc
    li   t5, 0xdeadbeef
    sw   t5, 0(t4)
2:  j 2b

    .balign 4
handler:
    csrr s2, mcause
    li   s3, 0x2010
    sw   s2, 0(s3)
    csrr s2, mepc
    li   s3, 0x2014
    sw   s2, 0(s3)
    csrr s2, mtval
    li   s3, 0x2018
    sw   s2, 0(s3)
    li   s3, 0x201c
    lw   s2, 0(s3)
    addi s2, s2, 1
    sw   s2, 0(s3)
    csrr s2, mcause
    blt  s2, x0, h_int
    # ---- AF 路径 ----
    li   s3, 0x2030
    lw   s2, 0(s3)
    addi s2, s2, 1
    sw   s2, 0(s3)
    csrr s2, mcause
    li   s3, 0x2034
    sw   s2, 0(s3)
    csrr s2, mepc
    li   s3, 0x2038
    sw   s2, 0(s3)
    csrr s2, mtval
    li   s3, 0x203c
    sw   s2, 0(s3)
    la   s2, ok
    csrw mepc, s2
    mret
h_int:
    li   s3, 0x202c
    lw   s2, 0(s3)
    addi s2, s2, 1
    sw   s2, 0(s3)
    li   s3, 0x1f302004
    lw   s2, 0(s3)
    li   s3, 0x1f302004
    sw   s2, 0(s3)
    csrw mie, x0
    mret

#------------------------------------------------------------------------------
# 变体代码（中毒行只在这里；上面的处理程序不在任何中毒行内）
#------------------------------------------------------------------------------
#ifdef ERR_FIRST
    .balign 32
t_insn:
    lui  t3, 0x2
    sw   t4, 0(t3)
    j    ok
#endif

#ifdef ERR_HI16
    .balign 32
    .space 2
t_insn:
    .option push
    .option rvc
    c.j  ok
    .option pop
    j    bad
#endif

#ifdef ERR_HI32
    .balign 32
    .space 30
t_insn:
    lui  t3, 0x2
    sw   t4, 0(t3)
    j    ok
#endif

#ifdef ERR_HI32PG
    .balign 4096
    .space 4094
t_insn:
    lui  t3, 0x2
    sw   t4, 0(t3)
    j    ok
#endif

#ifdef ERR_LATE
    .balign 32
nop_start:
    .rept 7
    nop
    .endr
    .option push
    .option rvc
    c.nop
    .option pop
t_insn:
    lui  t3, 0x2
    sw   t4, 0(t3)
    j    ok
#endif
