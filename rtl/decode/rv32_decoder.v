//=============================================================================
// rv32_decoder.v —— RV32GC 指令译码器（含 RVC 展开）+ ctrl 打包
//
// 依据：docs/design/spec/02-uop-and-decode.md（译码表 §4、立即数 §5、控制位 §2）
//       docs/design/spec/03-pipeline-regs.md §2.1（uop_id_t）
//       rtl/pkg/rv32gc_defs.vh（宏为唯一真源）
//
//-----------------------------------------------------------------------------
// 1. 支持范围（本阶段）
//-----------------------------------------------------------------------------
//   * RV32I 全部：LUI/AUIPC/JAL/JALR/6 条分支/5 条 load/3 条 store/9 条 OP-IMM
//     （含 3 条移位）/10 条 OP/FENCE/FENCE.I/ECALL/EBREAK/MRET/SRET/WFI；
//   * M 全部：MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU；
//   * A 全部：LR.W / SC.W / AMOSWAP.W / AMOADD.W / AMOXOR.W / AMOOR.W / AMOAND.W /
//     AMOMIN.W / AMOMAX.W / AMOMINU.W / AMOMAXU.W（含 aq/rl 位）；
//   * Zicsr 全部：CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI；
//   * SYS：ECALL/EBREAK/MRET/SRET/WFI/FENCE/FENCE.I/SFENCE.VMA；
//   * Zicbom：CBO.INVAL/CBO.CLEAN/CBO.FLUSH/CBO.ZERO；
//   * Zca/RVC：RV32 全部 29 条压缩指令（整数 25 条 + 压缩浮点访存 4 条，
//     后者展开为 FLD/FSD/FLW/FSW/FLWSP/FSWSP 后按「F/D 未实现」判非法）。
//
//-----------------------------------------------------------------------------
// 2. 未实现清单（legal=0）
//-----------------------------------------------------------------------------
//   * OP-FP (1010011)、LOAD-FP (0000111)、STORE-FP (0100111)：F/D 扩展本阶段不实现，
//     遇到这三个操作码一律 legal=0（后续阶段补 FPU 译码）；
//   * FMA 操作码 FMADD/FMSUB/FNMSUB/FNMADD (1000011/1000111/1001011/1001111)；
//   * 所有 RV64 专有指令（OP-32、LD/SD/LWU、ADDIW/SLLIW/SRLIW/SRAIW、
//     C.LD/C.SD/C.LDSP/C.SDSP/C.ADDIW/C.SUBW/C.ADDW）；
//   * 其他未定义扩展（Zba/Zbb/Zbs、向量、hypervisor 专有指令等）按未定义编码判非法；
//   * 本模块不含 CSR 存在性/权限检查（spec/02 §6 的「非法 CSR 访问」由 csr_file 在
//     执行/提交级判定），本阶段只判「编码是否合法」。
//
//-----------------------------------------------------------------------------
// 3. 非法判定规则（legal=0 时 ctrl.excp_valid=1 且 excp_cause=DEXC_ILLEGAL(2)）
//-----------------------------------------------------------------------------
//   * 未定义操作码 / 保留 funct3 / 保留 funct7（含 OP 的 SUB 型 funct7 配 SLL 等）；
//   * LOAD/STORE 的 funct3=011/110/111（RV64 的 LD/SD/LWU 等）；OP-32 全部；
//   * JALR 的 funct3!=000、BRANCH 的 funct3=010/011；
//   * MISC-MEM 的 funct3 非 000/001/010（010 为 Zicbom）；SYSTEM 的 funct3=100；
//   * SYSTEM：funct12 非 ECALL/EBREAK/MRET/SRET/WFI/SFENCE.VMA、
//     SFENCE.VMA 的 rd!=0（FENCE.I 的 rs1/rd/funct12 是"必须忽略"的保留字段，不报非法）；
//   * Zicbom（MISC-MEM 操作码 funct3=010）：funct12 非 000/001/002/004 或 rd!=0（保留编码）；
//   * A 扩展：funct3!=010；funct5 非 LR/SC/9 种 AMO；LR.W 的 rs2!=0、SC.W 的 rs2=0（保留编码）；
//   * Zicsr：funct3=100（保留）；SYSTEM 的 funct3=000 仅在 funct7/funct12 精确匹配
//     ECALL/EBREAK/MRET/SRET/WFI/SFENCE.VMA 时合法（rd/rs1 必须为 0，funct7 为 0000000/
//     0011000/0001000/0001001），其余组合保留；
//   * RVC（保留/非法形式）：c.addi4spn nzuimm=0；c.lui imm=0；c.addi16sp nzimm=0；
//     c.lwsp rd=0；c.jr rs1=0；
//     c.srli/c.srai/c.slli 的 shamt[5]=1（XLEN=32 时 designated for custom，本核未实现 → 非法）；
//     C0 象限保留槽位 op=00/funct3=100（CL 保留）；
//     C1 象限 CA 组 inst[15:10]=100111（inst[12]=1，RV64 的 C.SUBW/C.ADDW）。
//     （C2 象限 8 个 funct3 全部有定义，无保留槽位；合法/非法边界见上面各条。）
//   * 按当前 ISA 手册（unpriv/zca.adoc §c-lui_hint 等）**保持合法**的 HINT 形式：
//     c.addi/c.li rd=x0、c.addi rd≠x0/imm=0、c.slli shamt=0 或 rd=x0、c.mv/c.add rd=x0、
//     c.lui rd=x0 且 imm≠0、c.srli/c.srai shamt=0、c.lwsp/c.swsp 的 uimm=0；
//     这些形式展开后的基础指令本身合法，不产生异常（任务描述里的 "c.lui rd=0" 按手册修正）。
//
//-----------------------------------------------------------------------------
// 4. RVC 展开对照表（16 位 → 等价 32 位；展开后与手写 32 位指令逐位一致）
//-----------------------------------------------------------------------------
//   c.addi4spn rd',nzuimm → addi   rd',x2,nzuimm      (nzuimm=0 非法)
//   c.fld      rd',uimm(rs1') → fld  rd',uimm(rs1')   (F/D 未实现 → 非法)
//   c.lw       rd',uimm(rs1') → lw   rd',uimm(rs1')
//   c.flw      rd',uimm(rs1') → flw  rd',uimm(rs1')   (F 未实现 → 非法)
//   c.fsd      rs2',uimm(rs1') → fsd  rs2',uimm(rs1') (F/D 未实现 → 非法)
//   c.sw       rs2',uimm(rs1') → sw   rs2',uimm(rs1')
//   c.fsw      rs2',uimm(rs1') → fsw  rs2',uimm(rs1') (F 未实现 → 非法)
//   c.nop / c.addi rd,imm  → addi   rd,rd,imm          (HINT 形式合法)
//   c.jal      offset      → jal    x1,offset          (RV32)
//   c.li       rd,imm      → addi   rd,x0,imm
//   c.addi16sp nzimm       → addi   x2,x2,nzimm        (nzimm=0 非法)
//   c.lui      rd,nzimm    → lui    rd,nzimm           (nzimm=0 非法；rd=0 是 HINT；rd=2 即 c.addi16sp)
//   c.srli/c.srai rd',sh   → srli/srai rd',rd',sh      (shamt[5]=1 非法)
//   c.andi     rd',imm     → andi   rd',rd',imm
//   c.sub/c.xor/c.or/c.and → sub/xor/or/and rd',rd',rs2'
//   c.j        offset      → jal    x0,offset
//   c.beqz/c.bnez rs1',off → beq/bne rs1',x0,off
//   c.slli     rd,sh       → slli   rd,rd,sh           (shamt[5]=1 非法)
//   c.fldsp    rd,uimm(x2) → fld    rd,uimm(x2)        (F/D 未实现 → 非法)
//   c.lwsp     rd,uimm(x2) → lw     rd,uimm(x2)        (rd=0 非法)
//   c.flwsp    rd,uimm(x2) → flw    rd,uimm(x2)        (F 未实现 → 非法)
//   c.jr       rs1         → jalr   x0,0(rs1)          (rs1=0 非法)
//   c.mv       rd,rs2      → add    rd,x0,rs2
//   c.ebreak               → ebreak
//   c.jalr     rs1         → jalr   x1,0(rs1)
//   c.add      rd,rs2      → add    rd,rd,rs2
//   c.fsdsp    rs2,uimm(x2) → fsd   rs2,uimm(x2)       (F/D 未实现 → 非法)
//   c.swsp     rs2,uimm(x2) → sw    rs2,uimm(x2)
//   c.fswsp    rs2,uimm(x2) → fsw   rs2,uimm(x2)       (F 未实现 → 非法)
//
//   RVC 展开不新增 uop 类型：展开结果 instr 与 32 位指令走**同一**译码路径，
//   因此 ctrl/寄存器号/立即数与等价 32 位指令逐位相同（仅 instr/ilen/pc 不同）。
//
//-----------------------------------------------------------------------------
// 5. 其他说明
//-----------------------------------------------------------------------------
//   * ctrl = uop_ctrl_t，73 位，字段位置完全按 rv32gc_defs.vh 的 `CTRL_*_H/_W` 宏打包，
//     源码中不出现字面量位号；位映射与 spec/02 §2 表格逐位核对过。
//   * ecall 的 excp_cause：本模块无特权级输入，按 M 模式取 DEXC_ECALL_M(11)；
//     trap_ctrl 在提交级按当前特权级改写为 8/9/11（见总结中的偏差说明）。
//   * pc 端口本阶段不参与译码（保留给后续取指边界/地址非对齐检查），显式引用避免悬空。
//   * cbo.* 的 op_class=SYS（spec/02 §4.5），地址来自 rs1，is_serial=1，
//     cbo_op 指示 cache 操作类型；后端的「走 LSU」路由由 ctrl 的 cbo_op/is_serial 决定。
//   * ilen 端口为 2 位，无法直接表示 4，故定义为 log2(字节长度)：
//     2'd1 = 2 字节（RVC）、2'd2 = 4 字节（非压缩）；下游 (1<<ilen) 得字节数。
//   * 纯组合逻辑，Verilog-2001 可综合子集，无 `initial`/`$display`。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_decoder (
  input  wire [31:0] instr_raw,   // 取指得到的 16 位或 32 位指令（低 16 位有效）
  input  wire [31:0] pc,
  output wire        legal,       // 0 = 非法/未实现指令
  output wire [31:0] instr,       // RVC 展开后的 32 位指令（非压缩指令原样输出）
  output wire [1:0]  ilen,        // 字节长度（log2 编码）：1=2 字节(RVC)，2=4 字节
  output wire [4:0]  rs1_arch,
  output wire [4:0]  rs2_arch,
  output wire [4:0]  rs3_arch,    // 仅 FMA 使用，否则 0
  output wire [4:0]  rd_arch,
  output wire [31:0] imm,
  output wire [11:0] csr_addr,
  output wire [72:0] ctrl         // 按 spec/02 §2 打包（含 use_rs3 位 [72]）
);

  //---------------------------------------------------------------------------
  // 0. 操作码（RV32I/M/A/Zicsr/SYS；Zicbom 复用 MISC-MEM 操作码 funct3=010）
  //    注：rv32gc_defs.vh 未定义指令操作码宏，按 spec/02 §4 在此定义一次性 localparam
  //---------------------------------------------------------------------------
  localparam [6:0] OP_LUI      = 7'b0110111;  // LUI
  localparam [6:0] OP_AUIPC    = 7'b0010111;  // AUIPC
  localparam [6:0] OP_JAL      = 7'b1101111;  // JAL
  localparam [6:0] OP_JALR     = 7'b1100111;  // JALR
  localparam [6:0] OP_BRANCH   = 7'b1100011;  // BEQ/BNE/BLT/BGE/BLTU/BGEU
  localparam [6:0] OP_LOAD     = 7'b0000011;  // LB/LH/LW/LBU/LHU
  localparam [6:0] OP_STORE    = 7'b0100011;  // SB/SH/SW
  localparam [6:0] OP_OPIMM    = 7'b0010011;  // ADDI..ANDI + 移位
  localparam [6:0] OP_OP       = 7'b0110011;  // ADD..AND
  localparam [6:0] OP_MISC     = 7'b0001111;  // FENCE / FENCE.I / Zicbom(cbo.*)
  localparam [6:0] OP_SYSTEM   = 7'b1110011;  // Zicsr + ECALL/EBREAK/MRET/SRET/WFI/SFENCE.VMA + CBO
  localparam [6:0] OP_AMO      = 7'b0101111;  // LR/SC/AMO
  localparam [6:0] OP_OP32     = 7'b0111011;  // RV64 专有 → 非法
  localparam [6:0] OP_LOADFP   = 7'b0000111;  // F/D 未实现 → 非法
  localparam [6:0] OP_STOREFP  = 7'b0100111;  // F/D 未实现 → 非法
  localparam [6:0] OP_OPFP     = 7'b1010011;  // F/D 未实现 → 非法
  localparam [6:0] OP_FMADD    = 7'b1000011;  // FMA 未实现 → 非法
  localparam [6:0] OP_FMSUB    = 7'b1000111;
  localparam [6:0] OP_FNMSUB   = 7'b1001011;
  localparam [6:0] OP_FNMADD   = 7'b1001111;

  //---------------------------------------------------------------------------
  // 1. RVC 展开：16 位压缩指令 → 等价 32 位指令（组合）
  //---------------------------------------------------------------------------
  wire [15:0] c       = instr_raw[15:0];
  wire [1:0]  c_op    = c[1:0];
  wire [2:0]  c_f3    = c[15:13];
  wire [4:0]  c_rd    = c[11:7];              // CI/CR/CSS 全 5 位 rd
  wire [4:0]  c_rs2   = c[6:2];               // CR/CSS 全 5 位 rs2
  wire [4:0]  c_rdp   = {2'b01, c[4:2]};      // rd'  = x8..x15（8 + 3 位域）
  wire [4:0]  c_rs1p  = {2'b01, c[9:7]};      // rs1' = x8..x15
  wire [4:0]  c_rs2p  = {2'b01, c[4:2]};      // rs2' = x8..x15
  wire [5:0]  c_imm6  = {c[12], c[6:2]};      // CI 有符号 6 位立即数
  wire [1:0]  c_f2cb  = c[11:10];             // CB 格式 funct2（c.srli/c.srai/c.andi）

  // 立即数域（各自已按位映射；使用时再补零到位）
  wire [7:0]  c_nz4spn   = {c[10:7], c[12:11], c[5], c[6]};        // >>2 的相对 x2 偏移
  wire [4:0]  c_uimm_lw  = {c[5], c[12:10], c[6]};                 // C.LW/C.SW   >>2
  wire [4:0]  c_uimm_ld  = {c[6:5], c[12:10]};                     // C.FLD/C.FSD >>3
  wire [5:0]  c_uimm_lwsp= {c[3:2], c[12], c[6:4]};                // C.LWSP      >>2
  wire [5:0]  c_uimm_ldsp= {c[4:2], c[12], c[6:5]};                // C.FLDSP     >>3
  wire [5:0]  c_uimm_swsp= {c[8:7], c[12:9]};                      // C.SWSP      >>2
  wire [5:0]  c_uimm_sdsp= {c[9:7], c[12:10]};                     // C.FSDSP     >>3

  reg  [31:0] ex_instr;      // 展开后的 32 位指令
  reg         ex_ill;        // RVC 保留/非法编码

  always @(*) begin
    ex_instr = instr_raw;    // 缺省：非压缩指令原样透传
    ex_ill   = 1'b0;
    if (c_op != 2'b11) begin  // 低 2 位 != 11 → 16 位压缩指令
      case ({c_op, c_f3})
        //---------------- op=00（C0 格式）----------------
        5'b00_000: begin  // C.ADDI4SPN rd', nzuimm  →  addi rd',x2,nzuimm
          ex_instr = {2'b00, c_nz4spn, 2'b00, 5'd2, 3'b000, c_rdp, 7'b0010011};
          if (c_nz4spn == 8'd0) ex_ill = 1'b1;   // nzuimm=0 保留
        end
        5'b00_001: begin  // C.FLD rd', uimm(rs1')  →  fld  (F/D 未实现)
          ex_instr = {4'b0000, c_uimm_ld, 3'b000, c_rs1p, 3'b011, c_rdp, 7'b0000111};
        end
        5'b00_010: begin  // C.LW rd', uimm(rs1')   →  lw
          ex_instr = {5'b00000, c_uimm_lw, 2'b00, c_rs1p, 3'b010, c_rdp, 7'b0000011};
        end
        5'b00_011: begin  // C.FLW rd', uimm(rs1')  →  flw  (RV32；F 未实现)
          ex_instr = {5'b00000, c_uimm_lw, 2'b00, c_rs1p, 3'b010, c_rdp, 7'b0000111};
        end
        5'b00_100: ex_ill = 1'b1;                  // 保留
        5'b00_101: begin  // C.FSD rs2', uimm(rs1') →  fsd  (F/D 未实现)
          ex_instr = {4'b0000, c_uimm_ld[4:2], c_rs2p, c_rs1p, 3'b011,
                      c_uimm_ld[1:0], 3'b000, 7'b0100111};
        end
        5'b00_110: begin  // C.SW rs2', uimm(rs1')  →  sw
          ex_instr = {5'b00000, c_uimm_lw[4:3], c_rs2p, c_rs1p, 3'b010,
                      c_uimm_lw[2:0], 2'b00, 7'b0100011};
        end
        5'b00_111: begin  // C.FSW rs2', uimm(rs1') →  fsw  (RV32；F 未实现)
          ex_instr = {5'b00000, c_uimm_lw[4:3], c_rs2p, c_rs1p, 3'b010,
                      c_uimm_lw[2:0], 2'b00, 7'b0100111};
        end
        //---------------- op=01（C1 格式）----------------
        5'b01_000: begin  // C.NOP / C.ADDI rd, imm  →  addi rd,rd,imm
          ex_instr = {{6{c[12]}}, c_imm6, c_rd, 3'b000, c_rd, 7'b0010011};
        end
        5'b01_001: begin  // C.JAL offset（RV32）    →  jal x1,offset
          ex_instr = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3],
                      c[12], {8{c[12]}}, 5'd1, 7'b1101111};
        end
        5'b01_010: begin  // C.LI rd, imm            →  addi rd,x0,imm
          ex_instr = {{6{c[12]}}, c_imm6, 5'd0, 3'b000, c_rd, 7'b0010011};
        end
        5'b01_011: begin  // C.ADDI16SP（rd=2）/ C.LUI rd,nzimm
          if (c_rd == 5'd2) begin
            ex_instr = {{2{c[12]}}, c[12], c[4], c[3], c[5], c[2], c[6], 4'b0000,
                        5'd2, 3'b000, 5'd2, 7'b0010011};
            if (c_imm6 == 6'd0) ex_ill = 1'b1;       // nzimm=0 保留
          end else begin
            ex_instr = {{14{c[12]}}, c[12], c[6:2], c_rd, 7'b0110111};
            // imm=0 保留；rd=x0 且 imm!=0 是 HINT（合法，展开为 lui x0,imm）
            if (c_imm6 == 6'd0) ex_ill = 1'b1;
          end
        end
        5'b01_100: begin  // CB 格式（c.srli/c.srai/c.andi）/ CA 格式（c.sub/c.xor/c.or/c.and）
          // 注意：CB 的 funct2 = inst[11:10]；CA 用 inst[11:10]=11 作标记，
          //       funct2 = inst[6:5]、rs2' = inst[4:2]，inst[15:10]=100011（inst[12]=0）。
          if (c[11:10] == 2'b11) begin
            if (c[12] == 1'b0) begin
              case (c[6:5])
                2'b00: ex_instr = {7'b0100000, c_rs2p, c_rs1p, 3'b000, c_rs1p, 7'b0110011}; // C.SUB
                2'b01: ex_instr = {7'b0000000, c_rs2p, c_rs1p, 3'b100, c_rs1p, 7'b0110011}; // C.XOR
                2'b10: ex_instr = {7'b0000000, c_rs2p, c_rs1p, 3'b110, c_rs1p, 7'b0110011}; // C.OR
                default: ex_instr= {7'b0000000, c_rs2p, c_rs1p, 3'b111, c_rs1p, 7'b0110011}; // C.AND
              endcase
            end else begin
              ex_ill = 1'b1;   // inst[15:10]=100111：RV64 的 C.SUBW/C.ADDW，RV32 非法
            end
          end else begin
            case (c_f2cb)
              2'b00: begin  // C.SRLI rd',shamt → srli rd',rd',shamt
                ex_instr = {6'b000000, c[12], c[6:2], c_rs1p, 3'b101, c_rs1p, 7'b0010011};
                if (c[12]) ex_ill = 1'b1;   // shamt[5]=1（XLEN=32 保留）→ 非法
              end
              2'b01: begin  // C.SRAI rd',shamt → srai rd',rd',shamt
                ex_instr = {6'b010000, c[12], c[6:2], c_rs1p, 3'b101, c_rs1p, 7'b0010011};
                if (c[12]) ex_ill = 1'b1;
              end
              default: begin  // C.ANDI rd',imm → andi rd',rd',imm
                ex_instr = {{6{c[12]}}, c_imm6, c_rs1p, 3'b111, c_rs1p, 7'b0010011};
              end
            endcase
          end
        end
        5'b01_101: begin  // C.J offset              →  jal x0,offset
          ex_instr = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3],
                      c[12], {8{c[12]}}, 5'd0, 7'b1101111};
        end
        5'b01_110: begin  // C.BEQZ rs1', offset     →  beq rs1',x0,offset
          ex_instr = {c[12], {3{c[12]}}, c[6], c[5], c[2], 5'd0, c_rs1p, 3'b000,
                      c[11:10], c[4:3], c[12], 7'b1100011};
        end
        5'b01_111: begin  // C.BNEZ rs1', offset     →  bne rs1',x0,offset
          ex_instr = {c[12], {3{c[12]}}, c[6], c[5], c[2], 5'd0, c_rs1p, 3'b001,
                      c[11:10], c[4:3], c[12], 7'b1100011};
        end
        //---------------- op=10（C2 格式）----------------
        5'b10_000: begin  // C.SLLI rd, shamt        →  slli rd,rd,shamt
          ex_instr = {6'b000000, c[12], c[6:2], c_rd, 3'b001, c_rd, 7'b0010011};
          if (c[12]) ex_ill = 1'b1;                  // shamt[5]=1：XLEN=32 保留（custom）
        end
        5'b10_001: begin  // C.FLDSP rd, uimm(x2)    →  fld  (F/D 未实现)
          ex_instr = {3'b000, c_uimm_ldsp, 3'b000, 5'd2, 3'b011, c_rd, 7'b0000111};
        end
        5'b10_010: begin  // C.LWSP rd, uimm(x2)     →  lw
          ex_instr = {4'b0000, c_uimm_lwsp, 2'b00, 5'd2, 3'b010, c_rd, 7'b0000011};
          if (c_rd == 5'd0) ex_ill = 1'b1;   // rd=x0 保留（uimm=0 合法）
        end
        5'b10_011: begin  // C.FLWSP rd, uimm(x2)    →  flw  (RV32；F 未实现)
          ex_instr = {4'b0000, c_uimm_lwsp, 2'b00, 5'd2, 3'b010, c_rd, 7'b0000111};
        end
        5'b10_100: begin  // C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
          if ((c[12] == 1'b0) && (c_rs2 == 5'd0)) begin        // C.JR rs1
            ex_instr = {12'b0, c_rd, 3'b000, 5'd0, 7'b1100111};
            if (c_rd == 5'd0) ex_ill = 1'b1;                   // rs1=0 保留
          end else if ((c[12] == 1'b0) && (c_rd != 5'd0)) begin // C.MV rd,rs2
            ex_instr = {7'b0000000, c_rs2, 5'd0, 3'b000, c_rd, 7'b0110011};
          end else if ((c[12] == 1'b1) && (c_rd == 5'd0) && (c_rs2 == 5'd0)) begin
            ex_instr = 32'h00100073;                           // C.EBREAK
          end else if ((c[12] == 1'b1) && (c_rs2 == 5'd0)) begin // C.JALR rs1（rs1=0 即 c.ebreak，已在上支处理）
            ex_instr = {12'b0, c_rd, 3'b000, 5'd1, 7'b1100111};
          end else begin                                       // C.ADD rd,rs2
            ex_instr = {7'b0000000, c_rs2, c_rd, 3'b000, c_rd, 7'b0110011};
          end
        end
        5'b10_101: begin  // C.FSDSP rs2, uimm(x2)   →  fsd  (F/D 未实现)
          ex_instr = {3'b000, c_uimm_sdsp[5:2], c_rs2, 5'd2, 3'b011,
                      c_uimm_sdsp[1:0], 3'b000, 7'b0100111};
        end
        5'b10_110: begin  // C.SWSP rs2, uimm(x2)    →  sw
          ex_instr = {4'b0000, c_uimm_swsp[5:3], c_rs2, 5'd2, 3'b010,
                      c_uimm_swsp[2:0], 2'b00, 7'b0100011};
        end
        5'b10_111: begin  // C.FSWSP rs2, uimm(x2)   →  fsw  (RV32；F 未实现)
          ex_instr = {4'b0000, c_uimm_swsp[5:3], c_rs2, 5'd2, 3'b010,
                      c_uimm_swsp[2:0], 2'b00, 7'b0100111};
        end
        default: ex_ill = 1'b1;   // 10_100 之外的 op=10 保留（10_100 已在上面处理）
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // 2. 32 位译码（对展开后的指令；与手写 32 位指令完全同路径）
  //---------------------------------------------------------------------------
  wire [6:0]  opcode  = ex_instr[6:0];
  wire [4:0]  rd_i    = ex_instr[11:7];
  wire [2:0]  funct3  = ex_instr[14:12];
  wire [4:0]  rs1_i   = ex_instr[19:15];
  wire [4:0]  rs2_i   = ex_instr[24:20];
  wire [6:0]  funct7  = ex_instr[31:25];
  wire [11:0] funct12 = ex_instr[31:20];
  wire [4:0]  funct5  = ex_instr[31:27];
  wire        aq_bit  = ex_instr[26];
  wire        rl_bit  = ex_instr[25];

  // 立即数类型（与 rv32_imm_gen.v 的 imm_type 编码一致）
  localparam [2:0] IMM_I     = 3'd0;
  localparam [2:0] IMM_S     = 3'd1;
  localparam [2:0] IMM_B     = 3'd2;
  localparam [2:0] IMM_U     = 3'd3;
  localparam [2:0] IMM_J     = 3'd4;
  localparam [2:0] IMM_SHAMT = 3'd5;
  localparam [2:0] IMM_CSR   = 3'd6;
  // 无立即数字段的指令（FENCE/ECALL/CBO/SFENCE 等）用 imm_gen 的保留输入 7 → imm=0，
  // 使 uop 的 imm 字段保持全 0（spec/02 §4「未列出的字段取 0」）
  localparam [2:0] IMM_NONE  = 3'd7;

  // 译码字段（全部在 always @(*) 中先给缺省值）
  reg        legal32;
  reg [4:0]  rs1_d, rs2_d, rs3_d, rd_d;
  reg [11:0] csr_addr_d;
  reg [2:0]  imm_type_d;
  reg [2:0]  op_class_d;
  reg [4:0]  alu_op_d;
  reg [1:0]  alu_a_sel_d;
  reg [2:0]  alu_b_sel_d;
  reg [2:0]  br_type_d;
  reg [3:0]  br_flags_d;
  reg [2:0]  mdu_op_d;
  reg [2:0]  mem_op_d;
  reg [1:0]  mem_size_d;
  reg [1:0]  mem_flags_d;
  reg [1:0]  amo_flags_d;
  reg [4:0]  amo_op_d;
  reg [5:0]  fp_op_d;
  reg [1:0]  fp_fmt_d;
  reg [2:0]  fp_rm_d;
  reg [1:0]  csr_op_d;
  reg [2:0]  sys_op_d;
  reg        csr_imm_d;
  reg [1:0]  cbo_op_d;
  reg [2:0]  wb_sel_d;
  reg        rd_wen_d;
  reg        rd_is_fp_d;
  reg        use_rs1_d, use_rs2_d, use_rs3_d;
  reg        excp_valid_d;
  reg [3:0]  excp_cause_d;
  reg        is_fence_d, is_fencei_d, is_sfence_d, is_serial_d;

  always @(*) begin
    //------------------------- 缺省值（全 0，符合 spec/02 §4「未列出的字段取 0」）----
    legal32      = 1'b0;
    rs1_d        = 5'd0;
    rs2_d        = 5'd0;
    rs3_d        = 5'd0;               // 非 FMA 恒 0
    rd_d         = 5'd0;
    csr_addr_d   = 12'd0;
    imm_type_d   = IMM_I;
    op_class_d   = {`CTRL_OP_CLASS_W{1'b0}};
    alu_op_d     = {`CTRL_ALU_OP_W{1'b0}};
    alu_a_sel_d  = {`CTRL_ALU_A_SEL_W{1'b0}};
    alu_b_sel_d  = {`CTRL_ALU_B_SEL_W{1'b0}};
    br_type_d    = {`CTRL_BR_TYPE_W{1'b0}};
    br_flags_d   = {`CTRL_BR_FLAGS_W{1'b0}};
    mdu_op_d     = {`CTRL_MDU_OP_W{1'b0}};
    mem_op_d     = {`CTRL_MEM_OP_W{1'b0}};
    mem_size_d   = {`CTRL_MEM_SIZE_W{1'b0}};
    mem_flags_d  = {`CTRL_MEM_FLAGS_W{1'b0}};
    amo_flags_d  = {`CTRL_AMO_FLAGS_W{1'b0}};
    amo_op_d     = {`CTRL_AMO_OP_W{1'b0}};
    fp_op_d      = {`CTRL_FP_OP_W{1'b0}};
    fp_fmt_d     = {`CTRL_FP_FMT_W{1'b0}};
    fp_rm_d      = {`CTRL_FP_RM_W{1'b0}};
    csr_op_d     = {`CTRL_CSR_OP_W{1'b0}};
    sys_op_d     = {`CTRL_SYS_OP_W{1'b0}};
    csr_imm_d    = 1'b0;
    cbo_op_d     = {`CTRL_CBO_OP_W{1'b0}};
    wb_sel_d     = {`CTRL_WB_SEL_W{1'b0}};
    rd_wen_d     = 1'b0;
    rd_is_fp_d   = 1'b0;
    use_rs1_d    = 1'b0;
    use_rs2_d    = 1'b0;
    use_rs3_d    = 1'b0;
    excp_valid_d = 1'b0;
    excp_cause_d = `DEXC_NONE;
    is_fence_d   = 1'b0;
    is_fencei_d  = 1'b0;
    is_sfence_d  = 1'b0;
    is_serial_d  = 1'b0;

    case (opcode)
      //------------------------- LUI / AUIPC --------------------------------
      OP_LUI: begin
        legal32    = 1'b1;
        op_class_d = `OP_ALU;
        alu_op_d   = `ALU_ADD;
        alu_a_sel_d= `ALU_A_ZERO;
        alu_b_sel_d= `ALU_B_IMM;
        imm_type_d = IMM_U;
        wb_sel_d   = `WB_ALU;
        rd_d       = rd_i;
        rd_wen_d   = (rd_i != 5'd0);
      end
      OP_AUIPC: begin
        legal32    = 1'b1;
        op_class_d = `OP_ALU;
        alu_op_d   = `ALU_ADD;
        alu_a_sel_d= `ALU_A_PC;
        alu_b_sel_d= `ALU_B_IMM;
        imm_type_d = IMM_U;
        wb_sel_d   = `WB_ALU;
        rd_d       = rd_i;
        rd_wen_d   = (rd_i != 5'd0);
      end
      //------------------------- JAL / JALR --------------------------------
      OP_JAL: begin
        legal32    = 1'b1;
        op_class_d = `OP_BRU;
        br_flags_d = {1'b0, (rd_i == 5'd1), 1'b0, 1'b1};  // {ret,call,jalr,jal}
        imm_type_d = IMM_J;
        wb_sel_d   = `WB_PC4;
        rd_d       = rd_i;
        rd_wen_d   = (rd_i != 5'd0);
      end
      OP_JALR: begin
        if (funct3 == 3'b000) begin
          legal32    = 1'b1;
          op_class_d = `OP_BRU;
          // ret = (rs1==ra && rd==x0)；call = (rd==ra)
          br_flags_d = {((rs1_i == 5'd1) && (rd_i == 5'd0)), (rd_i == 5'd1), 1'b1, 1'b0};
          imm_type_d = IMM_I;
          wb_sel_d   = `WB_PC4;
          rs1_d      = rs1_i;
          rd_d       = rd_i;
          rd_wen_d   = (rd_i != 5'd0);
          use_rs1_d  = 1'b1;
        end
      end
      //------------------------- BRANCH ------------------------------------
      OP_BRANCH: begin
        case (funct3)
          3'b000: begin legal32=1'b1; br_type_d=`BR_EQ;  end
          3'b001: begin legal32=1'b1; br_type_d=`BR_NE;  end
          3'b100: begin legal32=1'b1; br_type_d=`BR_LT;  end
          3'b101: begin legal32=1'b1; br_type_d=`BR_GE;  end
          3'b110: begin legal32=1'b1; br_type_d=`BR_LTU; end
          3'b111: begin legal32=1'b1; br_type_d=`BR_GEU; end
          default: legal32 = 1'b0;                       // 010/011 保留
        endcase
        if (legal32) begin
          op_class_d = `OP_BRU;
          imm_type_d = IMM_B;
          rs1_d      = rs1_i;
          rs2_d      = rs2_i;
          use_rs1_d  = 1'b1;
          use_rs2_d  = 1'b1;
        end
      end
      //------------------------- LOAD --------------------------------------
      OP_LOAD: begin
        op_class_d = `OP_LSU;
        mem_op_d   = `MEM_LOAD;
        imm_type_d = IMM_I;
        wb_sel_d   = `WB_MEM;
        rs1_d      = rs1_i;
        rd_d       = rd_i;
        rd_wen_d   = (rd_i != 5'd0);
        use_rs1_d  = 1'b1;
        case (funct3)
          3'b000: begin legal32=1'b1; mem_size_d=`MSZ_BYTE; mem_flags_d={1'b0,1'b0}; end // LB
          3'b001: begin legal32=1'b1; mem_size_d=`MSZ_HALF; mem_flags_d={1'b0,1'b0}; end // LH
          3'b010: begin legal32=1'b1; mem_size_d=`MSZ_WORD; mem_flags_d={1'b0,1'b0}; end // LW
          3'b100: begin legal32=1'b1; mem_size_d=`MSZ_BYTE; mem_flags_d={1'b0,1'b1}; end // LBU
          3'b101: begin legal32=1'b1; mem_size_d=`MSZ_HALF; mem_flags_d={1'b0,1'b1}; end // LHU
          default: legal32 = 1'b0;   // 011/110/111 保留（RV64 LD/LWU 等）
        endcase
      end
      //------------------------- STORE -------------------------------------
      OP_STORE: begin
        op_class_d = `OP_LSU;
        mem_op_d   = `MEM_STORE;
        imm_type_d = IMM_S;
        rs1_d      = rs1_i;
        rs2_d      = rs2_i;
        use_rs1_d  = 1'b1;
        use_rs2_d  = 1'b1;
        case (funct3)
          3'b000: begin legal32=1'b1; mem_size_d=`MSZ_BYTE; end // SB
          3'b001: begin legal32=1'b1; mem_size_d=`MSZ_HALF; end // SH
          3'b010: begin legal32=1'b1; mem_size_d=`MSZ_WORD; end // SW
          default: legal32 = 1'b0;   // 011/100..111 保留（RV64 SD 等）
        endcase
      end
      //------------------------- OP-IMM ------------------------------------
      OP_OPIMM: begin
        imm_type_d = IMM_I;
        op_class_d = `OP_ALU;
        alu_a_sel_d= `ALU_A_RS1;
        alu_b_sel_d= `ALU_B_IMM;
        wb_sel_d   = `WB_ALU;
        rs1_d      = rs1_i;
        rd_d       = rd_i;
        rd_wen_d   = (rd_i != 5'd0);
        use_rs1_d  = 1'b1;
        case (funct3)
          3'b000: begin legal32=1'b1; alu_op_d=`ALU_ADD;  end // ADDI
          3'b010: begin legal32=1'b1; alu_op_d=`ALU_SLT;  end // SLTI
          3'b011: begin legal32=1'b1; alu_op_d=`ALU_SLTU; end // SLTIU
          3'b100: begin legal32=1'b1; alu_op_d=`ALU_XOR;  end // XORI
          3'b110: begin legal32=1'b1; alu_op_d=`ALU_OR;   end // ORI
          3'b111: begin legal32=1'b1; alu_op_d=`ALU_AND;  end // ANDI
          3'b001: begin                                       // SLLI
            if (funct7 == 7'b0000000) begin
              legal32=1'b1; alu_op_d=`ALU_SLL; alu_b_sel_d=`ALU_B_SHAMT; imm_type_d=IMM_SHAMT;
            end
          end
          3'b101: begin                                       // SRLI / SRAI
            if (funct7 == 7'b0000000) begin
              legal32=1'b1; alu_op_d=`ALU_SRL; alu_b_sel_d=`ALU_B_SHAMT; imm_type_d=IMM_SHAMT;
            end else if (funct7 == 7'b0100000) begin
              legal32=1'b1; alu_op_d=`ALU_SRA; alu_b_sel_d=`ALU_B_SHAMT; imm_type_d=IMM_SHAMT;
            end
          end
          default: legal32 = 1'b0;   // 101 保留
        endcase
      end
      //------------------------- OP（R 型） --------------------------------
      OP_OP: begin
        op_class_d = `OP_ALU;
        alu_a_sel_d= `ALU_A_RS1;
        alu_b_sel_d= `ALU_B_RS2;
        wb_sel_d   = `WB_ALU;
        rs1_d      = rs1_i;
        rs2_d      = rs2_i;
        rd_d       = rd_i;
        rd_wen_d   = (rd_i != 5'd0);
        use_rs1_d  = 1'b1;
        use_rs2_d  = 1'b1;
        case (funct3)
          3'b000: begin  // ADD / SUB
            if (funct7 == 7'b0000000)      begin legal32=1'b1; alu_op_d=`ALU_ADD; end
            else if (funct7 == 7'b0100000) begin legal32=1'b1; alu_op_d=`ALU_SUB; end
          end
          3'b001: if (funct7 == 7'b0000000) begin legal32=1'b1; alu_op_d=`ALU_SLL;  end // SLL
          3'b010: if (funct7 == 7'b0000000) begin legal32=1'b1; alu_op_d=`ALU_SLT;  end // SLT
          3'b011: if (funct7 == 7'b0000000) begin legal32=1'b1; alu_op_d=`ALU_SLTU; end // SLTU
          3'b100: if (funct7 == 7'b0000000) begin legal32=1'b1; alu_op_d=`ALU_XOR;  end // XOR
          3'b101: begin  // SRL / SRA
            if (funct7 == 7'b0000000)      begin legal32=1'b1; alu_op_d=`ALU_SRL; end
            else if (funct7 == 7'b0100000) begin legal32=1'b1; alu_op_d=`ALU_SRA; end
          end
          3'b110: if (funct7 == 7'b0000000) begin legal32=1'b1; alu_op_d=`ALU_OR;   end // OR
          3'b111: if (funct7 == 7'b0000000) begin legal32=1'b1; alu_op_d=`ALU_AND;  end // AND
          default: legal32 = 1'b0;
        endcase
      end
      //------------------------- MISC-MEM：FENCE / FENCE.I ------------------
      // 注：M 扩展与 OP 共用操作码 0110011，用 funct7=0000001 区分，
      //     在下面「M 扩展 / A 扩展」段中单独译码（避免 case 重复标签）。
      OP_MISC: begin
        case (funct3)
          3'b000: begin  // FENCE（fm/pred/succ 由后端使用，此处不译）
            legal32    = 1'b1;
            op_class_d = `OP_SYS;
            sys_op_d   = `SYS_FENCE;
            is_fence_d = 1'b1;
            is_serial_d= 1'b1;
            imm_type_d = IMM_NONE;
          end
          3'b001: begin  // FENCE.I：rs1/rd/funct12 是保留字段，实现必须**忽略**，不得报非法
            // riscv-isa-manual/src/unpriv/zifencei.adoc："…funct12, rs1, and rd, are reserved
            // for finer-grain fences in future extensions. For forward compatibility, base
            // implementations shall ignore these fields".
            // 历史缺陷：曾要求 rd==0 && rs1==0，导致 `fence.i` 带非零 rs1（arch-test 用例
            // 0x0001100f）被判非法指令（cause=2），Zifencei 用例失败。
            legal32    = 1'b1;
            op_class_d = `OP_SYS;
            sys_op_d   = `SYS_FENCE_I;
            is_fencei_d= 1'b1;
            is_serial_d= 1'b1;
            imm_type_d = IMM_NONE;
          end
          3'b010: begin  // Zicbom：cbo.inval/clean/flush/zero（编码固定 rd=0）
            if (rd_i == 5'd0) begin
              case (funct12)
                12'h000: begin legal32=1'b1; cbo_op_d=`CBO_INVAL; end
                12'h001: begin legal32=1'b1; cbo_op_d=`CBO_CLEAN; end
                12'h002: begin legal32=1'b1; cbo_op_d=`CBO_FLUSH; end
                12'h004: begin legal32=1'b1; cbo_op_d=`CBO_ZERO;  end
                default: legal32 = 1'b0;   // 其余 funct12 保留
              endcase
              if (legal32) begin
                op_class_d = `OP_SYS;
                is_serial_d= 1'b1;
                imm_type_d = IMM_NONE;
                rs1_d      = rs1_i;
                use_rs1_d  = 1'b1;
              end
            end
          end
          default: legal32 = 1'b0;
        endcase
      end
      //------------------------- SYSTEM：Zicsr + SYS -------------------------
      OP_SYSTEM: begin
        case (funct3)
          3'b000: begin
            if (funct7 == 7'b0000000) begin          // ECALL / EBREAK（rd=rs1=0，其余保留）
              case (funct12)
                12'h000: begin  // ECALL
                  if ((rd_i == 5'd0) && (rs1_i == 5'd0)) begin
                    legal32     = 1'b1;
                    op_class_d  = `OP_SYS;
                    sys_op_d    = `SYS_ECALL;
                    imm_type_d  = IMM_NONE;
                    excp_valid_d= 1'b1;
                    // 本模块无特权级输入：按 M 模式取 11；tract_ctrl 提交级按特权级改写为 8/9/11
                    excp_cause_d= `DEXC_ECALL_M;
                    is_serial_d = 1'b1;
                  end
                end
                12'h001: begin  // EBREAK
                  if ((rd_i == 5'd0) && (rs1_i == 5'd0)) begin
                    legal32     = 1'b1;
                    op_class_d  = `OP_SYS;
                    sys_op_d    = `SYS_EBREAK;
                    imm_type_d  = IMM_NONE;
                    excp_valid_d= 1'b1;
                    excp_cause_d= `DEXC_BREAK;
                    is_serial_d = 1'b1;
                  end
                end
                default: legal32 = 1'b0;  // 其余 funct12 保留（FENCE 在 MISC-MEM 操作码）
              endcase
            end else if (funct7 == 7'b0011000) begin // MRET（funct12=0x302；rd=rs1=0）
              if ((funct12 == 12'h302) && (rd_i == 5'd0) && (rs1_i == 5'd0)) begin
                legal32    = 1'b1;
                op_class_d = `OP_SYS;
                sys_op_d   = `SYS_MRET;
                imm_type_d = IMM_NONE;
                is_serial_d= 1'b1;
              end
            end else if (funct7 == 7'b0001000) begin // SRET（0x102）/ WFI（0x105），rd=rs1=0
              if ((funct12 == 12'h102) && (rd_i == 5'd0) && (rs1_i == 5'd0)) begin
                legal32    = 1'b1;
                op_class_d = `OP_SYS;
                sys_op_d   = `SYS_SRET;
                imm_type_d = IMM_NONE;
                is_serial_d= 1'b1;
              end else if ((funct12 == 12'h105) && (rd_i == 5'd0) && (rs1_i == 5'd0)) begin
                legal32    = 1'b1;
                op_class_d = `OP_SYS;
                sys_op_d   = `SYS_WFI;
                imm_type_d = IMM_NONE;
                is_serial_d= 1'b1;
              end
            end else if (funct7 == 7'b0001001) begin // SFENCE.VMA（rs2=ASID，rs1=VA，rd=0）
              if (rd_i == 5'd0) begin
                legal32    = 1'b1;
                op_class_d = `OP_SYS;
                sys_op_d   = `SYS_SFENCE_VMA;
                imm_type_d = IMM_NONE;
                is_sfence_d= 1'b1;
                is_serial_d= 1'b1;
                rs1_d      = rs1_i;
                rs2_d      = rs2_i;
                use_rs1_d  = 1'b1;
                use_rs2_d  = 1'b1;
              end
            end
            // 其余 funct7 组合：保留 → legal32 保持 0
          end
          3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: begin // Zicsr
            legal32    = 1'b1;
            op_class_d = `OP_CSR;
            imm_type_d = IMM_I;
            wb_sel_d   = `WB_CSR;
            csr_addr_d = funct12;
            csr_imm_d  = funct3[2];
            rd_d       = rd_i;
            rd_wen_d   = (rd_i != 5'd0);
            is_serial_d= 1'b1;
            case (funct3[1:0])
              2'b01: csr_op_d = `CSR_RW;
              2'b10: csr_op_d = `CSR_RS;
              default: csr_op_d = `CSR_RC;
            endcase
            if (csr_imm_d) begin
              // csrrwi/si/ci：rs1 域为 zimm，不读寄存器（imm 输出即零扩展 zimm）
              rs1_d      = rs1_i;
              imm_type_d = IMM_CSR;
              use_rs1_d  = 1'b0;
            end else begin
              rs1_d      = rs1_i;
              imm_type_d = IMM_I;
              use_rs1_d  = 1'b1;
            end
          end
          3'b100: legal32 = 1'b0;   // 保留
          default: legal32 = 1'b0;
        endcase
      end
      //------------------------- 保留操作码 ---------------------------------
      default: legal32 = 1'b0;
    endcase

    //------------------------- M 扩展 / A 扩展 ---------------------------------
    // （OP 操作码同时承载 RV32I 的 OP 与 M 扩展，用 funct7 区分）
    if (opcode == OP_OP && funct7 == 7'b0000001) begin
      legal32    = 1'b1;
      op_class_d = `OP_MDU;
      mem_op_d   = `MEM_NONE;
      wb_sel_d   = `WB_ALU;
      rs1_d      = rs1_i;
      rs2_d      = rs2_i;
      rd_d       = rd_i;
      rd_wen_d   = (rd_i != 5'd0);
      use_rs1_d  = 1'b1;
      use_rs2_d  = 1'b1;
      case (funct3)
        3'b000: mdu_op_d = `MDU_MUL;
        3'b001: mdu_op_d = `MDU_MULH;
        3'b010: mdu_op_d = `MDU_MULHSU;
        3'b011: mdu_op_d = `MDU_MULHU;
        3'b100: mdu_op_d = `MDU_DIV;
        3'b101: mdu_op_d = `MDU_DIVU;
        3'b110: mdu_op_d = `MDU_REM;
        3'b111: mdu_op_d = `MDU_REMU;
        default: legal32 = 1'b0;
      endcase
    end

    if (opcode == OP_AMO) begin
      legal32    = 1'b0;
      op_class_d = `OP_LSU;
      amo_flags_d= {rl_bit, aq_bit};    // {amo_rl, amo_aq}
      rs1_d      = rs1_i;
      rd_d       = rd_i;
      rd_wen_d   = (rd_i != 5'd0);
      use_rs1_d  = 1'b1;
      imm_type_d = IMM_NONE;           // A 类指令无立即数：必须用保留输入，否则地址被加上 [31:20]
      if (funct3 == 3'b010) begin       // 仅 .W（RV32）
        case (funct5)
          5'b00010: begin               // LR.W（rs2 必须为 0）
            if (rs2_i == 5'd0) begin
              legal32   = 1'b1;
              mem_op_d  = `MEM_LR;
              mem_size_d= `MSZ_WORD;
              wb_sel_d  = `WB_MEM;
            end
          end
          5'b00011: begin               // SC.W（rs2 为写入数据，不得为 0）
            if (rs2_i != 5'd0) begin
              legal32   = 1'b1;
              mem_op_d  = `MEM_SC;
              mem_size_d= `MSZ_WORD;
              rs2_d     = rs2_i;
              use_rs2_d = 1'b1;
              wb_sel_d  = `WB_MEM;
            end
          end
          5'b00001, 5'b00000, 5'b00100, 5'b01100, 5'b01000,
          5'b10000, 5'b10100, 5'b11000, 5'b11100: begin  // 9 种 AMO*.W
            legal32   = 1'b1;
            mem_op_d  = `MEM_AMO;
            mem_size_d= `MSZ_WORD;
            amo_op_d  = funct5;
            rs2_d     = rs2_i;
            use_rs2_d = 1'b1;
            wb_sel_d  = `WB_MEM;
          end
          default: legal32 = 1'b0;
        endcase
      end
    end

    //------------------------- F/D 未实现（显式列出，便于后续阶段替换）----------
    if ((opcode == OP_OPFP) || (opcode == OP_LOADFP) || (opcode == OP_STOREFP) ||
        (opcode == OP_FMADD) || (opcode == OP_FMSUB) ||
        (opcode == OP_FNMSUB) || (opcode == OP_FNMADD) ||
        (opcode == OP_OP32)) begin
      legal32 = 1'b0;
    end

    //------------------------- RVC 保留编码 → 非法 ---------------------------
    if (ex_ill) begin
      legal32      = 1'b0;
      op_class_d   = `OP_NOP;      // 非法 uop 不进入执行单元，仅携带异常到 RT
      rd_wen_d     = 1'b0;
      use_rs1_d    = 1'b0;
      use_rs2_d    = 1'b0;
      use_rs3_d    = 1'b0;
      excp_valid_d = 1'b1;
      excp_cause_d = `DEXC_ILLEGAL;
    end

    //------------------------- 非法统一出口 ---------------------------------
    if (!legal32) begin
      op_class_d   = `OP_NOP;
      rd_wen_d     = 1'b0;
      use_rs1_d    = 1'b0;
      use_rs2_d    = 1'b0;
      use_rs3_d    = 1'b0;
      excp_valid_d = 1'b1;
      excp_cause_d = `DEXC_ILLEGAL;
    end
  end

  //---------------------------------------------------------------------------
  // 3. 立即数生成（独立模块，便于单元验证）
  //---------------------------------------------------------------------------
  wire [31:0] imm_d;

  rv32_imm_gen u_imm_gen (
    .instr    (ex_instr),
    .imm_type (imm_type_d),
    .imm      (imm_d)
  );

  //---------------------------------------------------------------------------
  // 4. ctrl 打包（73 位；位域全部用 rv32gc_defs.vh 的 CTRL_*_H/_W 宏，无字面量位号）
  //---------------------------------------------------------------------------
  assign ctrl[`CTRL_OP_CLASS_H    -: `CTRL_OP_CLASS_W]    = op_class_d;
  assign ctrl[`CTRL_ALU_OP_H      -: `CTRL_ALU_OP_W]      = alu_op_d;
  assign ctrl[`CTRL_ALU_A_SEL_H   -: `CTRL_ALU_A_SEL_W]   = alu_a_sel_d;
  assign ctrl[`CTRL_ALU_B_SEL_H   -: `CTRL_ALU_B_SEL_W]   = alu_b_sel_d;
  assign ctrl[`CTRL_BR_TYPE_H     -: `CTRL_BR_TYPE_W]     = br_type_d;
  assign ctrl[`CTRL_BR_FLAGS_H    -: `CTRL_BR_FLAGS_W]    = br_flags_d;
  assign ctrl[`CTRL_MDU_OP_H      -: `CTRL_MDU_OP_W]      = mdu_op_d;
  assign ctrl[`CTRL_MEM_OP_H      -: `CTRL_MEM_OP_W]      = mem_op_d;
  assign ctrl[`CTRL_MEM_SIZE_H    -: `CTRL_MEM_SIZE_W]    = mem_size_d;
  assign ctrl[`CTRL_MEM_FLAGS_H   -: `CTRL_MEM_FLAGS_W]   = mem_flags_d;
  assign ctrl[`CTRL_AMO_FLAGS_H   -: `CTRL_AMO_FLAGS_W]   = amo_flags_d;
  assign ctrl[`CTRL_AMO_OP_H      -: `CTRL_AMO_OP_W]      = amo_op_d;
  assign ctrl[`CTRL_FP_OP_H       -: `CTRL_FP_OP_W]       = fp_op_d;
  assign ctrl[`CTRL_FP_FMT_H      -: `CTRL_FP_FMT_W]      = fp_fmt_d;
  assign ctrl[`CTRL_FP_RM_H       -: `CTRL_FP_RM_W]       = fp_rm_d;
  assign ctrl[`CTRL_CSR_OP_H      -: `CTRL_CSR_OP_W]      = csr_op_d;
  assign ctrl[`CTRL_SYS_OP_H      -: `CTRL_SYS_OP_W]      = sys_op_d;
  assign ctrl[`CTRL_CSR_IMM_H     -: `CTRL_CSR_IMM_W]     = csr_imm_d;
  assign ctrl[`CTRL_CBO_OP_H      -: `CTRL_CBO_OP_W]      = cbo_op_d;
  assign ctrl[`CTRL_WB_SEL_H      -: `CTRL_WB_SEL_W]      = wb_sel_d;
  assign ctrl[`CTRL_RD_WEN_H      -: `CTRL_RD_WEN_W]      = rd_wen_d;
  assign ctrl[`CTRL_RD_IS_FP_H    -: `CTRL_RD_IS_FP_W]    = rd_is_fp_d;
  assign ctrl[`CTRL_USE_RS1_H     -: `CTRL_USE_RS1_W]     = use_rs1_d;
  assign ctrl[`CTRL_USE_RS2_H     -: `CTRL_USE_RS2_W]     = use_rs2_d;
  assign ctrl[`CTRL_EXCP_VALID_H  -: `CTRL_EXCP_VALID_W]  = excp_valid_d;
  assign ctrl[`CTRL_EXCP_CAUSE_H  -: `CTRL_EXCP_CAUSE_W]  = excp_cause_d;
  assign ctrl[`CTRL_IS_FENCE_H    -: `CTRL_IS_FENCE_W]    = is_fence_d;
  assign ctrl[`CTRL_IS_FENCEI_H   -: `CTRL_IS_FENCEI_W]   = is_fencei_d;
  assign ctrl[`CTRL_IS_SFENCE_H   -: `CTRL_IS_SFENCE_W]   = is_sfence_d;
  assign ctrl[`CTRL_IS_SERIAL_H   -: `CTRL_IS_SERIAL_W]   = is_serial_d;
  assign ctrl[`CTRL_USE_RS3_H     -: `CTRL_USE_RS3_W]     = use_rs3_d;

  //---------------------------------------------------------------------------
  // 5. 其余输出
  //---------------------------------------------------------------------------
  assign legal    = legal32;
  assign instr    = ex_instr;
  // ilen：端口仅 2 位（[1:0]），无法直接表示 4，故采用 log2(字节长度) 编码：
  //   2'd1 = 2 字节（RVC），2'd2 = 4 字节（32 位）；下游用 (1<<ilen) 还原字节数。
  assign ilen     = (instr_raw[1:0] == 2'b11) ? 2'd2 : 2'd1;
  assign rs1_arch = rs1_d;
  assign rs2_arch = rs2_d;
  assign rs3_arch = rs3_d;    // 非 FMA 恒 0（use_rs3=0 门控）
  assign rd_arch  = rd_d;
  assign csr_addr = csr_addr_d;
  assign imm      = imm_d;

  // pc 本阶段不参与译码；显式引用避免悬空输入告警
  wire unused_pc;
  assign unused_pc = ^pc;

endmodule
