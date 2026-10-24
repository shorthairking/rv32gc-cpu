    .section .text.init,"ax",@progbits
    .globl _start
    .option norvc
    .equ EXT_ID,  0x8001F000
    .equ DENY_M,  0x80011000
    .equ DATA_VA, 0x00401200
    .equ RESULT,  0x1FE01100
_start:
    li    s1, 0
    li    s2, 0
    li    s3, 0
    la    t0, m_trap
    csrw  mtvec, t0
    li    t0, 0x0000A0A0     # delegate S load/store AF and page-fault causes
    csrw  0x302, t0
    li    s0, EXT_ID
    lw    s0, 0(s0)
    la    t0, s_trap
    csrw  stvec, t0
    li    t0, 0x8008001b
    csrw  satp, t0
    sfence.vma x0, x0
    li    t0, 1
    beq   s0, t0, pmp_fast_setup
    li    t0, 4
    beq   s0, t0, pmp_pte_setup
    li    t0, 5
    bne   s0, t0, pmp_allow_setup
pmp_pte_setup:
    # Locked deny exactly the lower-level PTE line; catch-all permits everything else.
    li    t0, 0x20007003
    csrw  0x3b0, t0
    li    t0, -1
    csrw  0x3b1, t0
    li    t0, 0x00001f98
    csrw  0x3a0, t0
    j     pmp_setup_done
pmp_fast_setup:
    # Locked 16-byte deny with satp already active; cause-7 fast store fault precedes S slow walk.
    li    t0, 0x20004403
    csrw  0x3b0, t0
    li    t0, -1
    csrw  0x3b1, t0
    li    t0, 0x00001f98
    csrw  0x3a0, t0
    li    t0, DENY_M
    li    t1, 0xD00D0001
    sw    t1, 0(t0)
    j     pmp_setup_done
pmp_allow_setup:
    # S-mode report/data windows require an explicit catch-all permission entry.
    li    t0, -1
    csrw  0x3b1, t0
    li    t0, 0x00001f00
    csrw  0x3a0, t0
    j     pmp_setup_done
pmp_setup_done:
    li    t0, 11
    beq   s0, t0, pmp_bdelay_scenario
    li    t0, 15
    bne   s0, t0, pmp_setup_continue
    li    t0, 0x8001B004
    lw    t1, 0(t0)          # naturally prewarm root[1] for the later AD_PTE hit
pmp_setup_continue:
    csrr  t0, mstatus
    li    t1, 0xffffe7ff
    and   t0, t0, t1
    li    t1, 0x800
    or    t0, t0, t1
    csrw  mstatus, t0
    la    t0, s_start
    csrw  mepc, t0
    mret

m_trap:
    csrr  s1, mcause
    csrr  s2, mtval
    li    s3, 1
    csrr  t0, mepc
    addi  t0, t0, 4
    csrw  mepc, t0
    mret

pmp_bdelay_scenario:
    li    t0, 0x1FE01200
    li    t1, 0x1234ABCD
    sw    t1, 0(t0)         # accepted older store; external B delayed 12 cycles
    li    t0, 0x00001B00
    csrw  0x3a0, t0         # real pmpcfg0 update must refetch at PC+4
    .globl pmp_after_csr
pmp_after_csr:
    addi  s6, s6, 1
    li    t2, 0x5A5A2222
    j     extension_done

s_start:
    # Scenario 1 must make the first post-fault data op a slow Sv32 store.
    li    t0, 1
    beq   s0, t0, fast_after_fault
    # Keep the private ID17 window free of the generic I/O warm-store request.
    li    t0, 17
    beq   s0, t0, .Lskip_io_warm
    li    t0, RESULT+16
    sw    x0, 0(t0)
.Lskip_io_warm:
    li    t0, 2
    beq   s0, t0, pte_load_error
    li    t0, 3
    beq   s0, t0, pte_store_error
    li    t0, 4
    beq   s0, t0, pte_load_pmp
    li    t0, 5
    beq   s0, t0, pte_store_pmp
    li    t0, 6
    beq   s0, t0, pte_root_high
    li    t0, 7
    beq   s0, t0, pte_leaf_high
    li    t0, 8
    beq   s0, t0, invalid_leaf_load
    li    t0, 9
    beq   s0, t0, invalid_leaf_store
    li    t0, 10
    beq   s0, t0, branch_kill_scenario
    li    t0, 14
    beq   s0, t0, high_leaf_store
    li    t0, 15
    beq   s0, t0, branch_kill_scenario
    li    t0, 16
    beq   s0, t0, branch_kill_scenario
    li    t0, 17
    beq   s0, t0, branch_kill_mul_scenario
    li    t0, 12
    beq   s0, t0, cached_load_error_early
    li    t0, 13
    beq   s0, t0, cached_load_error_late
    j     extension_bad

fast_after_fault:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # first S-mode data op: slow Sv32 store, no intervening success
    lw    t2, 0(t0)
    j     extension_done

pte_load_error:
    li    t0, DATA_VA
    lw    t2, 0(t0)         # first walk sees one RRESP error; trap skips this op
    lw    t2, 0(t0)         # same VA retries and must complete after one-shot error
    j     extension_done

pte_store_error:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # first PTE read error => store/AMO access fault 7
    sw    t2, 0(t0)         # one-shot response consumed; retry must commit
    lw    t2, 0(t0)
    j     extension_done

pte_load_pmp:
    li    t0, DATA_VA
    li    t2, 0
    lw    t2, 0(t0)         # PMP rejects the implicit PTE read => load AF 5
    j     extension_done

pte_store_pmp:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # same PTE PMP rejection => store AF 7
    j     extension_done

pte_root_high:
    li    t0, DATA_VA
    li    t2, 0
    lw    t2, 0(t0)         # high PPN in root's next-level pointer => AF5, no alias
    j     extension_done

pte_leaf_high:
    li    t0, DATA_VA
    li    t2, 0
    lw    t2, 0(t0)         # high PPN in leaf => AF5, no truncated data read
    j     extension_done

invalid_leaf_load:
    li    t0, DATA_VA
    li    t2, 0
    lw    t2, 0(t0)         # V=0 control must be load page-fault 13
    j     extension_done

invalid_leaf_store:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # V=0 control must be store page-fault 15, no W
    j     extension_done

high_leaf_store:
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # high PA store must access-fault 7 without truncation/W
    j     extension_done

cached_load_error_early:
    li    t0, DATA_VA
    lw    t2, 0(t0)         # cached DATA RRESP SLVERR beat 0 => one load AF5
    lw    t2, 0(t0)         # one-shot error consumed; retry must return data
    j     extension_done

cached_load_error_late:
    li    t0, DATA_VA
    lw    t2, 0(t0)         # cached DATA RRESP SLVERR beat 7 => one load AF5
    lw    t2, 0(t0)         # one-shot error consumed; retry must return data
    j     extension_done

branch_kill_mul_scenario:
    li    s6, 0
    li    s7, 1
    li    s8, 0x00400000
    li    t0, 0x803FF100
    jr    t0                 # enter a fresh VPN1=512 code alias near its boundary

branch_kill_scenario:
    li    s6, 4
    li    s7, 1
    li    s8, 0x00400000
branch_mdu_loop:
    div   t6, s6, s7         # older iterative MDU dependency
    beq   t6, x0, branch_redirect_target
    bnez  s6, branch_mdu_skipload
    lw    t5, 0(s8)          # only final predicted fall-through: cold invalid PTE0 load
branch_mdu_skipload:
    addi  s6, s6, -1
    j     branch_mdu_loop

    .globl branch_redirect_target
branch_redirect_target:
    li    t0, RESULT+24
    li    t1, 0x0000B101
    sw    t1, 0(t0)         # evidence that the real taken target retired
    la    t0, fresh_vpn_target
    li    t1, 0x00400000
    add   t0, t0, t1        # jump to same physical code through a fresh VPN1=513
    jr    t0

    .globl fresh_vpn_target
fresh_vpn_target:
    li    t0, RESULT+28
    li    t1, 0x0000B202
    sw    t1, 0(t0)         # evidence that the new ITLB VPN was reached
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)         # correct post-kill slow store reuses canceled tag safely
    lw    t2, 0(t0)
    j     extension_done

s_trap:
    mv    s4, t0            # preserve the faulting program's address operands
    mv    s5, t1
    csrr  t0, scause
    li    t1, RESULT
    sw    t0, 4(t1)
    lw    t0, 8(t1)
    addi  t0, t0, 1
    sw    t0, 8(t1)
    csrr  t0, sepc
    addi  t0, t0, 4
    csrw  sepc, t0
    mv    t0, s4
    mv    t1, s5
    sret

extension_bad:
    li    t2, 0xBAD00000
extension_done:
    li    t0, 1
    bne   s0, t0, 1f
    li    t0, RESULT
    sw    s1, 4(t0)         # fast M-mode store AF7 captured only in registers
    sw    s3, 8(t0)
1:  li    t0, RESULT+20
    sw    s2, 0(t0)
    li    t0, RESULT+12
    sw    t2, 0(t0)
    li    t0, 0x4558544F
    li    t1, RESULT
    sw    t0, 0(t1)
1:  j     1b

    # ID17: map the last page of VPN1=512 and first page of VPN1=513 to
    # two physical code pages. The fall-through fetch naturally starts an IF walk
    # while the older DIV branch and its younger invalid-VPN load are live.
    .org 0x2100
branch17_skipload:
    j     branch17_mdu_window
    .org 0x2fd8
branch17_mdu_window:
    mul   t6, s6, s7
    beq   t6, x0, branch17_redirect_target
    addi  t1, x0, 1           # shift the wrong-path D request by one cycle
    lw    t5, 0(s8)
    .org 0x3020
    .globl branch17_redirect_target
branch17_redirect_target:
    li    t0, RESULT+24
    li    t1, 0x0000B101
    sw    t1, 0(t0)
    j     branch17_fresh_vpn_target
    .org 0x3040
    .globl branch17_fresh_vpn_target
branch17_fresh_vpn_target:
    li    t0, RESULT+28
    li    t1, 0x0000B202
    sw    t1, 0(t0)
    li    t0, DATA_VA
    li    t2, 0xA5A5B6B6
    sw    t2, 0(t0)
    addi  t2, x0, 0           # fail-closed sentinel if load WB is missing
    lw    t2, 0(t0)
    lui   t0, %hi(extension_done)
    addi  t0, t0, %lo(extension_done)
    jr    t0
