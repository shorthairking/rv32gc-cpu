//==============================================================================
// sim/unit/tb_decoder.sv —— D 级译码四模块单元测试（覆盖抽样 + 非法 + C 展开）
//==============================================================================
// 目的 : 验证 rtl/decode/{decoder.v, dec_imm.v, dec_csr.v, compressed_expand.v}
//        对 2A 指令集合的译码正确性。**这是单元测试，不承担架构验证职责**；
//        架构级正确性由后续 arch-test/锁步覆盖。
//
// 测什么（对应验收判据③）：
//   1. 抽样指令**各 1 例**并断言**具体数值**：
//      addi / lw / sw / beq / jal / lui / auipc / fence / fence.i / ecall /
//      ebreak / csrrw / mul / fadd.s / c.flwsp / c.addi4spn / cbo.clean /
//      cbo.flush / cbo.inval
//      —— 期望编码由 riscv32-unknown-linux-gnu-as/-objdump 实测取得（见每条注释）。
//   2. **非法编码 3 例**：断言 ill_instr=1 且 tval = 原始指令位。
//   3. **压缩指令展开 3 例**：断言展开出的 32 位等效编码与手算一致。
//   4. dec_imm 的立即数 function 与 C 展开的立即数一致性对拍（等价性约束）。
//   5. dec_csr 的 CSR 权限矩阵与 cbo.* 门控预判（M/S/U × CBIE/CBCFE 组合）。
//
// 怎么判 : 任一断言不成立 ⇒ 立即 $fatal（非零退出码）并打印该例的 FAIL 详情；
//          **全程不得出现 PASS 字样**，只有跑完全部检查才在最后一行打印
//          `TB_DECODER_UNIT: PASS`（唯一 PASS）。调用方须以「末行含该串」且
//          「退出码 0」双条件判定（08 §8.1 fail-closed 纪律）。
// 顶层   : tb_decoder_top（验收命令用 -s tb_decoder_top）
// 风格   : 本体不含时序逻辑；用 task 逐例调用（task 内为过程赋值，**不是**被测
//          RTL 的组合逻辑风格问题——红线 3 约束的是可综合 RTL，TB 不受此限）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_decoder_top;

    //--------------------------------------------------------------------------
    // DUT 端口镜像
    //--------------------------------------------------------------------------
    reg  [31:0] insn_i;
    reg  [1:0]  priv_i;
    reg  [1:0]  menvcfg_cbie_i;
    reg         menvcfg_cbcfe_i;
    reg  [1:0]  senvcfg_cbie_i;
    reg         senvcfg_cbcfe_i;

    wire [31:0] insn32_o, tval_o, imm_o;
    wire        ill_instr_o, is_compressed_o, is_hint_o, ctl_xfer_o;
    wire [4:0]  rs1_o, rs2_o, rs3_o, rd_o, cbo_kind_o;
    wire [3:0]  op_type_o, alu_op_o, mem_op_o;
    wire [2:0]  mem_size_o, wb_sel_o, csr_op_o, rm_o;
    wire        mem_unsign_o, fp_we_o, fp_ldst_o, csr_ill_o, csr_zimm_o;
    wire        cbo_valid_o, cbo_gate_ill_o, cbo_downgrade_o;
    wire        fence_i_o, fence_o, ebreak_o, ecall_o, mret_o, sret_o, wfi_o;
    wire [5:0]  fp_op_o;
    wire        rv32_is_amo_o;
    wire [11:0] csr_addr_o;

    decoder u_dec (
        .insn_i           (insn_i),
        .priv_i           (priv_i),
        .menvcfg_cbie_i   (menvcfg_cbie_i),
        .menvcfg_cbcfe_i  (menvcfg_cbcfe_i),
        .senvcfg_cbie_i   (senvcfg_cbie_i),
        .senvcfg_cbcfe_i  (senvcfg_cbcfe_i),
        .insn32_o         (insn32_o),
        .tval_o           (tval_o),
        .ill_instr_o      (ill_instr_o),
        .is_compressed_o  (is_compressed_o),
        .is_hint_o        (is_hint_o),
        .ctl_xfer_o       (ctl_xfer_o),
        .rs1_o            (rs1_o),
        .rs2_o            (rs2_o),
        .rs3_o            (rs3_o),
        .rd_o             (rd_o),
        .imm_o            (imm_o),
        .op_type_o        (op_type_o),
        .alu_op_o         (alu_op_o),
        .mem_op_o         (mem_op_o),
        .mem_size_o       (mem_size_o),
        .mem_unsign_o     (mem_unsign_o),
        .wb_sel_o         (wb_sel_o),
        .csr_op_o         (csr_op_o),
        .fp_op_o          (fp_op_o),
        .fp_we_o          (fp_we_o),
        .fp_ldst_o        (fp_ldst_o),
        .rm_o             (rm_o),
        .rv32_is_amo_o    (rv32_is_amo_o),
        .csr_addr_o       (csr_addr_o),
        .csr_ill_o        (csr_ill_o),
        .csr_zimm_o       (csr_zimm_o),
        .cbo_valid_o      (cbo_valid_o),
        .cbo_kind_o       (cbo_kind_o),
        .cbo_gate_ill_o   (cbo_gate_ill_o),
        .cbo_downgrade_o  (cbo_downgrade_o),
        .fence_i_o        (fence_i_o),
        .fence_o          (fence_o),
        .ebreak_o         (ebreak_o),
        .ecall_o          (ecall_o),
        .mret_o           (mret_o),
        .sret_o           (sret_o),
        .wfi_o            (wfi_o)
    );

    //--------------------------------------------------------------------------
    // 独立参照：dec_imm 模块（用于与 decoder 内部例化对拍）
    //--------------------------------------------------------------------------
    reg  [31:0] dimm_insn;
    reg         dimm_i, dimm_s, dimm_b, dimm_u, dimm_j, dimm_sh;
    wire [31:0] dimm_o;
    dec_imm u_dimref (
        .insn      (dimm_insn),
        .sel_i     (dimm_i),
        .sel_s     (dimm_s),
        .sel_b     (dimm_b),
        .sel_u     (dimm_u),
        .sel_j     (dimm_j),
        .sel_ishift(dimm_sh),
        .imm_o     (dimm_o)
    );

    //--------------------------------------------------------------------------
    // 独立参照：compressed_expand（供"展开结果"直接断言）
    //--------------------------------------------------------------------------
    reg  [15:0] cexp_in;
    wire [31:0] cexp_insn32;
    wire        cexp_ill, cexp_hint, cexp_ctl;
    compressed_expand u_cexp_ref (
        .c_insn     (cexp_in),
        .insn32_o   (cexp_insn32),
        .ill16_o    (cexp_ill),
        .is_hint_o  (cexp_hint),
        .ctl_xfer_o (cexp_ctl)
    );

    //--------------------------------------------------------------------------
    // 检查计数器（fail-closed：必须 捕获数>0 且 失败数==0）
    //--------------------------------------------------------------------------
    integer n_checks;
    integer n_fail;

    `define CHK(cond, msg) \
        begin \
            n_checks = n_checks + 1; \
            if (!(cond)) begin \
                n_fail = n_fail + 1; \
                $display("FAIL: %s", msg); \
            end \
        end

    // ---- 统一驱动的 task：设激励 ----
    // 默认：M 模式、envcfg 全关（复位默认值，08 §6.5）
    task drv;
        input [31:0] insn;
        input [1:0]  priv;
        input [1:0]  m_cbie;
        input        m_cbcfe;
        input [1:0]  s_cbie;
        input        s_cbcfe;
        begin
            insn_i          = insn;
            priv_i          = priv;
            menvcfg_cbie_i  = m_cbie;
            menvcfg_cbcfe_i = m_cbcfe;
            senvcfg_cbie_i  = s_cbie;
            senvcfg_cbcfe_i = s_cbcfe;
            // 组合逻辑建立时间：纯 initial 流程必须给一步时间推进，否则 DUT 的
            // 组合输出尚未求值（读到 X）。这是 TB 驱动纪律，不是被测逻辑问题。
            #1;
        end
    endtask

    // ---- 简化驱动：M 模式 + envcfg 全关 ----
    task drv_m;
        input [31:0] insn;
        begin
            drv(insn, `RV32GC_PRIV_M, 2'b00, 1'b0, 2'b00, 1'b0);
        end
    endtask

    //==========================================================================
    // 主检查流程
    //==========================================================================
    initial begin
        n_checks = 0;
        n_fail   = 0;

        $display("---- D 级译码四模块单元测试 ----");

        //======================================================================
        // 1. 抽样指令各 1 例（期望编码 = 交叉汇编器实测，见注释）
        //======================================================================
        // 编码全部由 riscv32-unknown-linux-gnu-as/-objdump 实测（见本文件头说明）。

        // ---- addi x5, x6, 100  ⇒ 0x06430293 ----
        drv_m(32'h06430293);
        `CHK(ill_instr_o === 1'b0,       "addi 不应非法")
        `CHK(op_type_o  === 4'd0,        "addi op_type 应为 OPT_ALU")
        `CHK(rd_o === 5'd5,              "addi rd 应为 x5")
        `CHK(rs1_o === 5'd6,             "addi rs1 应为 x6")
        `CHK(imm_o === 32'd100,          "addi imm 应为 100")

        // ---- lw x7, 8(x8)  ⇒ 0x00842383 ----
        drv_m(32'h00842383);
        `CHK(ill_instr_o === 1'b0,       "lw 不应非法")
        `CHK(op_type_o === 4'd4,         "lw op_type 应为 OPT_LSU")
        `CHK(mem_op_o === 4'd1,          "lw mem_op 应为 MEM_LOAD")
        `CHK(mem_size_o === 3'd2,        "lw 宽度应为 4B")
        `CHK(mem_unsign_o === 1'b0,      "lw 应符号扩展")
        `CHK(imm_o === 32'd8,            "lw imm 应为 8")
        `CHK(rs1_o === 5'd8,             "lw rs1 应为 x8")
        `CHK(rd_o === 5'd7,              "lw rd 应为 x7")

        // ---- sw x9, 12(x10)  ⇒ 0x00952623（S 型，imm=12）----
        drv_m(32'h00952623);
        `CHK(ill_instr_o === 1'b0,       "sw 不应非法")
        `CHK(mem_op_o === 4'd2,          "sw mem_op 应为 MEM_STORE")
        `CHK(mem_size_o === 3'd2,        "sw 宽度应为 4B")
        `CHK(imm_o === 32'd12,           "sw imm 应为 12")
        `CHK(rs2_o === 5'd9,             "sw rs2 应为 x9")
        `CHK(rs1_o === 5'd10,            "sw rs1 应为 x10")

        // ---- beq x1, x2, +20  ⇒ 0x00208a63（B 型，imm=20）----
        drv_m(32'h00208a63);
        `CHK(ill_instr_o === 1'b0,       "beq 不应非法")
        `CHK(op_type_o === 4'd1,         "beq op_type 应为 OPT_BRU")
        `CHK(imm_o === 32'd20,           "beq imm 应为 20")
        `CHK(ctl_xfer_o === 1'b1,        "beq 应为控制转移")

        // ---- 交叉汇编器全表交叉验证（103 条真实编码）的**回归锚点** ----
        //   下 6 条是「用 riscv32-unknown-linux-gnu-as 实测、且在开发期确实暴露过
        //   译码缺陷」的编码，作为回归锚点固化在本 TB 中（完整 103 条见开发期
        //   交叉验证脚本；此处只收会回归的关键用例）。
        //   (1) fcvt.s.d f9,f10 ⇒ 0x401574d3（funct5=01000，F↔D 互转）
        //       ★ 该例曾因真源宏 RV32GC_FP_F5_FCVT('h8>>3)=5'b00001 被误判非法。
        //         真源已于 2026-09-14 修复为 5'b01000、pkg_check.v 已补取值断言，
        //         decoder.v 的 localparam 绕行已回收（改为直接用真源宏）。
        //         此例作为**回归锚点**保留，断言语义不变：仍要求该编码判合法，
        //         防止真源宏再被改错或译码路径回退。
        drv_m(32'h401574d3);
        `CHK(ill_instr_o === 1'b0,       "fcvt.s.d 不应非法（真源宏 5'b01000 回归锚点）")
        `CHK(op_type_o === 4'd11,        "fcvt.s.d op_type 应为 OPT_FP")
        `CHK(fp_op_o === 6'd9,           "fcvt.s.d fp_op 应为 FP_CVT")

        //   (2) fcvt.d.s f11,f12 ⇒ 0x420605d3
        drv_m(32'h420605d3);
        `CHK(ill_instr_o === 1'b0,       "fcvt.d.s 不应非法（真源宏 5'b01000 回归锚点）")
        `CHK(op_type_o === 4'd11,        "fcvt.d.s op_type 应为 OPT_FP")

        //   (3) fcvt.w.s x1,f2,rtz ⇒ 0xc00110d3（funct5=11000，出口写整数；rm=rtz 在 funct3）
        drv_m(32'hc00110d3);
        `CHK(ill_instr_o === 1'b0,       "fcvt.w.s 不应非法")
        `CHK(op_type_o === 4'd11,        "fcvt.w.s op_type 应为 OPT_FP")
        `CHK(fp_we_o === 1'b0,           "fcvt.w.s 写整数，不应写 FP 寄存器")
        `CHK(wb_sel_o === 3'd5,          "fcvt.w.s 写回应为 WB_FP")

        //   (4) fcvt.s.w f3,x4 ⇒ 0xd00271d3（funct5=11010，入口写 FP）
        drv_m(32'hd00271d3);
        `CHK(ill_instr_o === 1'b0,       "fcvt.s.w 不应非法")
        `CHK(fp_we_o === 1'b1,           "fcvt.s.w 应写 FP 寄存器")

        //   (5) flw f28,4(x29) ⇒ 0x004eae07（浮点 load）
        drv_m(32'h004eae07);
        `CHK(ill_instr_o === 1'b0,       "flw 不应非法")
        `CHK(op_type_o === 4'd12,        "flw op_type 应为 OPT_FPLD")
        `CHK(mem_op_o === 4'd7,          "flw mem_op 应为 MEM_FLOAD")
        `CHK(fp_we_o === 1'b1,           "flw 应写 FP 寄存器")

        //   (6) fmadd.s f1,f2,f3,f4 ⇒ 0x203170c3（FMA 族，rs3 在 insn[31:27]）
        drv_m(32'h203170c3);
        `CHK(ill_instr_o === 1'b0,       "fmadd.s 不应非法")
        `CHK(op_type_o === 4'd11,        "fmadd.s op_type 应为 OPT_FP")
        `CHK(fp_op_o === 6'd13,          "fmadd.s fp_op 应为 FP_FMA")
        `CHK(rs3_o === 5'd4,             "fmadd.s rs3 应为 f4")

        //   (7) amoadd.w x6,x7,(x8) ⇒ 0x0074232f（AMO funct5 在 insn[31:27]）
        drv_m(32'h0074232f);
        `CHK(ill_instr_o === 1'b0,       "amoadd.w 不应非法")
        `CHK(op_type_o === 4'd5,         "amoadd.w op_type 应为 OPT_AMO")
        `CHK(mem_op_o === 4'd3,          "amoadd.w mem_op 应为 MEM_AMO")
        `CHK(mem_size_o === 3'd2,        "amoadd.w 宽度应为 4B")

        //   (8) lr.w x1,(x2) ⇒ 0x100120af；sc.w x3,x4,(x5) ⇒ 0x1842a1af
        drv_m(32'h100120af);
        `CHK(ill_instr_o === 1'b0,       "lr.w 不应非法")
        `CHK(mem_op_o === 4'd4,          "lr.w mem_op 应为 MEM_LR")
        drv_m(32'h1842a1af);
        `CHK(ill_instr_o === 1'b0,       "sc.w 不应非法")
        `CHK(mem_op_o === 4'd5,          "sc.w mem_op 应为 MEM_SC")

        //   (9) lr.w 的 rs2!=0 ⇒ 非法（[ENC:LR_W=0x1000202f 要求 rs2=0]）
        //       构造 rs2=1：0x101120af
        drv_m(32'h101120af);
        `CHK(ill_instr_o === 1'b1,       "lr.w 的 rs2!=0 应判非法")

        // ---- jal x1, +36  ⇒ 0x024000ef（J 型，imm=36）----
        drv_m(32'h024000ef);
        `CHK(ill_instr_o === 1'b0,       "jal 不应非法")
        `CHK(op_type_o === 4'd2,         "jal op_type 应为 OPT_JAL")
        `CHK(imm_o === 32'd36,           "jal imm 应为 36")
        `CHK(rd_o === 5'd1,              "jal rd 应为 x1")

        // ---- lui x5, 0x12345  ⇒ 0x123452b7（U 型）----
        drv_m(32'h123452b7);
        `CHK(ill_instr_o === 1'b0,       "lui 不应非法")
        `CHK(imm_o === 32'h12345000,     "lui imm 应为 0x12345000")
        `CHK(rd_o === 5'd5,              "lui rd 应为 x5")

        // ---- auipc x5, 0x12345  ⇒ 0x12345297 ----
        drv_m(32'h12345297);
        `CHK(ill_instr_o === 1'b0,       "auipc 不应非法")
        `CHK(imm_o === 32'h12345000,     "auipc imm 应为 0x12345000")

        // ---- fence  ⇒ 0x0ff0000f ----
        drv_m(32'h0ff0000f);
        `CHK(ill_instr_o === 1'b0,       "fence 不应非法")
        `CHK(fence_o === 1'b1,           "fence 标志应为 1")
        `CHK(fence_i_o === 1'b0,         "fence 不应置 fence.i")

        // ---- fence.i  ⇒ 0x0000100f ----
        drv_m(32'h0000100f);
        `CHK(ill_instr_o === 1'b0,       "fence.i 不应非法")
        `CHK(fence_i_o === 1'b1,         "fence.i 标志应为 1")

        // ---- ecall  ⇒ 0x00000073 ----
        drv_m(32'h00000073);
        `CHK(ill_instr_o === 1'b0,       "ecall 不应非法")
        `CHK(ecall_o === 1'b1,           "ecall 标志应为 1")

        // ---- ebreak ⇒ 0x00100073 ----
        drv_m(32'h00100073);
        `CHK(ill_instr_o === 1'b0,       "ebreak 不应非法")
        `CHK(ebreak_o === 1'b1,          "ebreak 标志应为 1")

        // ---- csrrw x5, mstatus, x6  ⇒ 0x300312f3 ----
        drv_m(32'h300312f3);
        `CHK(ill_instr_o === 1'b0,       "csrrw mstatus 不应非法")
        `CHK(csr_addr_o === `RV32GC_CSR_MSTATUS, "csr 地址应为 mstatus(0x300)")
        `CHK(csr_op_o === 3'd1,          "csrrw csr_op 应为 CSRN_W")
        `CHK(rd_o === 5'd5,              "csrrw rd 应为 x5")
        `CHK(csr_ill_o === 1'b0,         "csrrw mstatus 权限应通过")

        // ---- mul x5, x6, x7 ⇒ 0x027302b3 ----
        drv_m(32'h027302b3);
        `CHK(ill_instr_o === 1'b0,       "mul 不应非法")
        `CHK(op_type_o === 4'd6,         "mul op_type 应为 OPT_MDU")

        // ---- fadd.s f1, f2, f3 ⇒ 0x003170d3 ----
        drv_m(32'h003170d3);
        `CHK(ill_instr_o === 1'b0,       "fadd.s 不应非法")
        `CHK(op_type_o === 4'd11,        "fadd.s op_type 应为 OPT_FP")
        `CHK(fp_op_o === 6'd1,           "fadd.s fp_op 应为 FP_ADD")
        `CHK(fp_we_o === 1'b1,           "fadd.s 应写 FP 寄存器")
        `CHK(rd_o === 5'd1,              "fadd.s rd 应为 f1")

        // ---- c.flwsp f1, 8(sp) ⇒ 0x60a2 ----
        //   ★ 2A **不实现 Zcf**（压缩浮点）⇒ 该编码**按保留处理、应判非法**。
        //     依据：core_params.vh §10 的 ISA 字符串 = RV32IMAFDC+Zicsr/Zifencei/
        //     Zicntr/Zicbom，不含 Zcf；08 §5.2「不支持的扩展编码 ⇒ ill_instr」。
        //     ⇒ 此例断言 ill_instr=1 且 tval=0x0000_60a2（T1 口径）。
        drv_m(32'h000060a2);
        `CHK(ill_instr_o === 1'b1,       "c.flwsp（Zcf 未实现）应判非法")
        `CHK(tval_o === 32'h0000_60a2,   "c.flwsp tval 应为原始 16 位编码")

        // ---- c.addi4spn x8, sp, 8 ⇒ 0x0020 ----
        drv_m(32'h00000020);
        `CHK(ill_instr_o === 1'b0,       "c.addi4spn 不应非法")
        `CHK(is_compressed_o === 1'b1,   "c.addi4spn 应标记为压缩指令")
        `CHK(insn32_o === 32'h00810413,  "c.addi4spn 应展开为 addi x8,x2,8")
        `CHK(rd_o === 5'd8,              "c.addi4spn rd 应为 x8")
        `CHK(imm_o === 32'd8,            "c.addi4spn imm 应为 8")

        // ---- cbo.clean (x8) ⇒ 0x0014200f ----
        drv(32'h0014200f, `RV32GC_PRIV_M, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(ill_instr_o === 1'b0,       "cbo.clean 在 M 模式应合法")
        `CHK(cbo_valid_o === 1'b1,       "cbo.clean 应标记 cbo_valid")
        `CHK(cbo_kind_o === `RV32GC_CBO_CLEAN, "cbo.clean 动作码应为 CLEAN")
        `CHK(rs1_o === 5'd8,             "cbo.clean rs1 应为 x8（地址）")

        // ---- cbo.flush (x8) ⇒ 0x0024200f ----
        //   ★ clean 与 flush 的 funct7 相同，**只靠 rs2 区分**（真源 §3.11「★ 关键」）
        drv(32'h0024200f, `RV32GC_PRIV_M, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(ill_instr_o === 1'b0,       "cbo.flush 在 M 模式应合法")
        `CHK(cbo_kind_o === `RV32GC_CBO_FLUSH, "cbo.flush 动作码应为 FLUSH（靠 rs2 区分）")

        // ---- cbo.inval (x8) ⇒ 0x0004200f ----
        drv(32'h0004200f, `RV32GC_PRIV_M, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(ill_instr_o === 1'b0,       "cbo.inval 在 M 模式应合法")
        `CHK(cbo_kind_o === `RV32GC_CBO_INVAL, "cbo.inval 动作码应为 INVAL")

        //======================================================================
        // 2. 非法编码 3 例（断言 ill_instr=1 且 tval=原始指令位）
        //======================================================================
        // ---- (a) 未定义 opcode：0x0000007f（opcode=1111111，不在 2A 集合）----
        drv_m(32'h0000007f);
        `CHK(ill_instr_o === 1'b1,       "非法例 a：未定义 opcode 应判非法")
        `CHK(tval_o === 32'h0000007f,    "非法例 a：tval 应为原始指令位")

        // ---- (b) OP-IMM 移位非法：slli 的 shamt[5]=1（insn[25]=1）----
        //   0x02031293 = slli x5,x6,32 的编码形态（RV32 下 insn[25]=1 属保留）
        drv_m(32'h02031293);
        `CHK(ill_instr_o === 1'b1,       "非法例 b：slli shamt[5]=1 应判非法")
        `CHK(tval_o === 32'h02031293,    "非法例 b：tval 应为原始指令位")

        // ---- (c) MISC-MEM 的 cbo.zero（Zicboz 未实现）----
        //   cbo.zero 的 rs2=00100（真源 §3.11 注释：2A 不定义、禁止启用）
        drv_m(32'h0044200f);
        `CHK(ill_instr_o === 1'b1,       "非法例 c：cbo.zero 应判非法（2A 无 Zicboz）")
        `CHK(tval_o === 32'h0044200f,    "非法例 c：tval 应为原始指令位")

        // ---- 额外（非验收要求，但强化 fail-closed）：全零 16 位指令恒非法 ----
        drv_m(32'h00000000);
        `CHK(ill_instr_o === 1'b1,       "全零指令应为非法")
        `CHK(tval_o === 32'h00000000,    "全零指令 tval 应为 0")

        //======================================================================
        // 3. 压缩指令展开 3 例（直接断言 compressed_expand 的输出）
        //======================================================================
        // ---- (1) c.lwsp x7, 8(sp) ⇒ 0x43a2  ⇒ lw x7, 8(x2) = 0x00812383 ----
        cexp_in = 16'h43a2;
        #1;
        `CHK(cexp_ill === 1'b0,          "C 展开例 1：c.lwsp 应可展开")
        `CHK(cexp_insn32 === 32'h00812383, "C 展开例 1：c.lwsp 应展开为 lw x7,8(x2)")

        // ---- (2) c.li x5, 5 ⇒ 0x4295 ⇒ addi x5, x0, 5 = 0x00500293 ----
        cexp_in = 16'h4295;
        #1;
        `CHK(cexp_ill === 1'b0,          "C 展开例 2：c.li 应可展开")
        `CHK(cexp_insn32 === 32'h00500293, "C 展开例 2：c.li 应展开为 addi x5,x0,5")

        // ---- (3) c.addi4spn x8, sp, 8 ⇒ 0x0020 ⇒ addi x8, x2, 8 = 0x00810413 ----
        cexp_in = 16'h0020;
        #1;
        `CHK(cexp_ill === 1'b0,          "C 展开例 3：c.addi4spn 应可展开")
        `CHK(cexp_insn32 === 32'h00810413, "C 展开例 3：c.addi4spn 应展开为 addi x8,x2,8")

        // ---- 额外：c.addi x5, 3 ⇒ 0x028d ⇒ addi x5, x5, 3 = 0x00328293 ----
        cexp_in = 16'h028d;
        #1;
        `CHK(cexp_ill === 1'b0,          "C 展开附加：c.addi 应可展开")
        `CHK(cexp_insn32 === 32'h00328293, "C 展开附加：c.addi 应展开为 addi x5,x5,3")

        // ---- 附加反证：c.lwsp x0, 8(sp)（rd=0）为保留 ⇒ 应判非法 ----
        //   c.lwsp x0, 8(sp) = 0x4002 的 rd 域=0 ⇒ 保留（norm:c-lwsp_rsv）
        cexp_in = 16'h4002;
        #1;
        `CHK(cexp_ill === 1'b1,          "c.lwsp rd=x0 应判保留（非法）")

        // ---- 附加反证：c.addi4spn nzuimm=0 ⇒ 保留 ----
        cexp_in = 16'h0000;
        #1;
        `CHK(cexp_ill === 1'b1,          "全零 16 位应判保留（非法）")
        cexp_in = 16'h0001;              // c.nop（c.addi x0,x0,0）：合法指令
        #1;
        `CHK(cexp_ill === 1'b0,          "c.nop 应合法")
        `CHK(cexp_insn32 === 32'h00000013, "c.nop 应展开为 addi x0,x0,0")

        //======================================================================
        // 4. dec_imm 与 C 展开的立即数一致性（等价性约束；覆盖 I/S/B/U/J）
        //======================================================================
        // ---- I 型：insn[31:20] 符号扩展（负值）----
        dimm_insn = 32'hfff00293;        // addi x5,x0,-1
        dimm_i=1'b1; dimm_s=0; dimm_b=0; dimm_u=0; dimm_j=0; dimm_sh=0;
        #1;
        `CHK(dimm_o === 32'hffffffff,    "dec_imm：I 型应立即数符号扩展为 -1")

        // ---- S 型：imm = 12 ----
        dimm_insn = 32'h00952623;
        dimm_i=0; dimm_s=1; dimm_b=0; dimm_u=0; dimm_j=0; dimm_sh=0;
        #1;
        `CHK(dimm_o === 32'd12,          "dec_imm：S 型立即数应为 12")

        // ---- B 型：imm = -20（0xfe2086e3，由交叉汇编器实测）----
        dimm_insn = 32'h00000000;
        dimm_i=0; dimm_s=0; dimm_b=1; dimm_u=0; dimm_j=0; dimm_sh=0;
        //   直接构造：读一个已知 B 型负立即数
        dimm_insn = 32'hfe2086e3;        // beq x1,x2,-20
        #1;
        `CHK(dimm_o === 32'hffffffec,    "dec_imm：B 型应立即数符号扩展为 -20")

        // ---- U 型：imm = 0x12345000 ----
        dimm_insn = 32'h123452b7;
        dimm_i=0; dimm_s=0; dimm_b=0; dimm_u=1; dimm_j=0; dimm_sh=0;
        #1;
        `CHK(dimm_o === 32'h12345000,    "dec_imm：U 型立即数应为 0x12345000")

        // ---- J 型：imm = 36 ----
        dimm_insn = 32'h024000ef;
        dimm_i=0; dimm_s=0; dimm_b=0; dimm_u=0; dimm_j=1; dimm_sh=0;
        #1;
        `CHK(dimm_o === 32'd36,          "dec_imm：J 型立即数应为 36")

        // ---- I 型移位：shamt = 5 ----
        dimm_insn = 32'h00531293;        // slli x5,x6,5
        dimm_i=0; dimm_s=0; dimm_b=0; dimm_u=0; dimm_j=0; dimm_sh=1;
        #1;
        `CHK(dimm_o === 32'd5,           "dec_imm：I 型移位 shamt 应为 5")

        // ---- 等价性：decoder 的 imm 与 dec_imm 独立例化必须一致 ----
        //   （同一指令经两条路径取立即数）
        dimm_insn = 32'h024000ef;
        dimm_i=0; dimm_s=0; dimm_b=0; dimm_u=0; dimm_j=1; dimm_sh=0;
        drv_m(32'h024000ef);
        `CHK(dimm_o === imm_o,           "一致性：dec_imm 与 decoder 的 J 型立即数应一致")

        //======================================================================
        // 5. CSR 权限矩阵 + cbo.* 门控预判（dec_csr）
        //======================================================================
        // ---- (1) U 模式读 cycle（0xC00，只读、U 可访问）⇒ 合法 ----
        //      csrr x5, cycle ⇒ 0xc00022f3
        drv(32'hc00022f3, `RV32GC_PRIV_U, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(csr_ill_o === 1'b0,         "U 读 cycle 应合法")
        `CHK(ill_instr_o === 1'b0,       "U 读 cycle 不应整体非法")

        // ---- (2) U 模式**写** cycle（只读 CSR）⇒ 非法指令 ----
        //      csrrw x5, cycle, x6 ⇒ 0xc00312f3
        drv(32'hc00312f3, `RV32GC_PRIV_U, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(csr_ill_o === 1'b1,         "U 写只读 CSR(cycle) 应判非法")
        `CHK(ill_instr_o === 1'b1,       "U 写只读 CSR 应整体非法")

        // ---- (3) U 模式访问 M 专属 CSR（mstatus）⇒ 非法 ----
        drv(32'h300022f3, `RV32GC_PRIV_U, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(csr_ill_o === 1'b1,         "U 访问 mstatus 应判非法")

        // ---- (4) S 模式访问 M 专属 CSR（mstatus）⇒ 非法 ----
        drv(32'h300022f3, `RV32GC_PRIV_S, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(csr_ill_o === 1'b1,         "S 访问 mstatus 应判非法")

        // ---- (5) S 模式访问 satp（0x180，S 专属）⇒ 合法 ----
        //      csrr x5, satp ⇒ 0x180022f3
        drv(32'h180022f3, `RV32GC_PRIV_S, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(csr_ill_o === 1'b0,         "S 访问 satp 应合法")

        // ---- (6) 未实现 CSR 地址（如 0x7C0 自定义区）⇒ 非法 ----
        //      csrr x5, 0x7c0 ⇒ 0x7c0022f3
        drv(32'h7c0022f3, `RV32GC_PRIV_M, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(csr_ill_o === 1'b1,         "未实现 CSR 地址应判非法")

        // ---- (7) M 模式访问 cbo.* 不受 envcfg 门控（复位默认全 0 仍合法）----
        drv(32'h0024200f, `RV32GC_PRIV_M, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(cbo_gate_ill_o === 1'b0,    "M 模式 cbo.flush 不应被门控")

        // ---- (8) S 模式 cbo.flush 且 menvcfg.CBCFE=0 ⇒ 非法 ----
        drv(32'h0024200f, `RV32GC_PRIV_S, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(cbo_gate_ill_o === 1'b1,    "S 模式 CBCFE=0 时 cbo.flush 应判非法")
        `CHK(ill_instr_o === 1'b1,       "S 模式 CBCFE=0 时 cbo.flush 应整体非法")

        // ---- (9) S 模式 cbo.flush 且 menvcfg.CBCFE=1 ⇒ 合法 ----
        drv(32'h0024200f, `RV32GC_PRIV_S, 2'b00, 1'b1, 2'b00, 1'b0);
        `CHK(cbo_gate_ill_o === 1'b0,    "S 模式 CBCFE=1 时 cbo.flush 应合法")

        // ---- (10) S 模式 cbo.inval 且 menvcfg.CBIE=00 ⇒ 非法 ----
        drv(32'h0004200f, `RV32GC_PRIV_S, 2'b00, 1'b0, 2'b00, 1'b0);
        `CHK(cbo_gate_ill_o === 1'b1,    "S 模式 CBIE=00 时 cbo.inval 应判非法")

        // ---- (11) S 模式 cbo.inval 且 menvcfg.CBIE=01 ⇒ 执行但降级为 FLUSH ----
        drv(32'h0004200f, `RV32GC_PRIV_S, 2'b01, 1'b0, 2'b00, 1'b0);
        `CHK(cbo_gate_ill_o === 1'b0,    "S 模式 CBIE=01 时 cbo.inval 不应非法")
        `CHK(cbo_downgrade_o === 1'b1,   "S 模式 CBIE=01 时 cbo.inval 应降级")
        `CHK(cbo_kind_o === `RV32GC_CBO_FLUSH, "降级后动作码应为 FLUSH")

        // ---- (12) S 模式 cbo.inval 且 menvcfg.CBIE=11 ⇒ 按 INVAL 执行 ----
        drv(32'h0004200f, `RV32GC_PRIV_S, 2'b11, 1'b0, 2'b00, 1'b0);
        `CHK(cbo_gate_ill_o === 1'b0,    "S 模式 CBIE=11 时 cbo.inval 不应非法")
        `CHK(cbo_kind_o === `RV32GC_CBO_INVAL, "CBIE=11 时动作码应为 INVAL")

        // ---- (13) U 模式门控**叠加**：menvcfg.CBCFE=1 但 senvcfg.CBCFE=0 ⇒ 非法 ----
        drv(32'h0024200f, `RV32GC_PRIV_U, 2'b00, 1'b1, 2'b00, 1'b0);
        `CHK(cbo_gate_ill_o === 1'b1,    "U 模式 senvcfg.CBCFE=0 时 cbo.flush 应判非法")

        // ---- (14) U 模式门控叠加：menvcfg.CBCFE=1 且 senvcfg.CBCFE=1 ⇒ 合法 ----
        drv(32'h0024200f, `RV32GC_PRIV_U, 2'b00, 1'b1, 2'b00, 1'b1);
        `CHK(cbo_gate_ill_o === 1'b0,    "U 模式两级 CBCFE 均=1 时 cbo.flush 应合法")

        // ---- (15) U 模式 CBIE 叠加：menvcfg=11 且 senvcfg=01 ⇒ 降级为 FLUSH ----
        //      （叠加取 AND：11 & 01 = 01 ⇒ 降级）
        drv(32'h0004200f, `RV32GC_PRIV_U, 2'b11, 1'b0, 2'b01, 1'b0);
        `CHK(cbo_gate_ill_o === 1'b0,    "U 模式叠加后 CBIE=01 时不应非法")
        `CHK(cbo_downgrade_o === 1'b1,   "U 模式叠加后应降级")

        //======================================================================
        // 6. 汇总判定（fail-closed）
        //======================================================================
        $display("checks = %0d, fails = %0d", n_checks, n_fail);
        if (n_checks == 0) begin
            $display("FAIL: 未执行任何检查（捕获数必须 > 0）");
            $fatal(1, "TB_DECODER_UNIT FAIL: no checks executed");
        end
        if (n_fail != 0) begin
            $fatal(1, "TB_DECODER_UNIT FAIL: %0d 项检查未通过", n_fail);
        end
        $display("TB_DECODER_UNIT: PASS");
        $finish;
    end

endmodule
