# SPEC-02 微指令（uop）格式与译码表

> 上游：`00-conventions.md`。本文件定义**指令译码的输出格式**，是前端/后端所有模块的公共接口。

---

## 1. 三条数据通路（不同流水段携带不同 bundle）

| Bundle | 产生于 | 消费于 | 内容 |
|---|---|---|---|
| `uop_id_t` | ID | RN | 架构信息 + 控制位（未重命名） |
| `uop_rn_t` | RN | DP → IQ/LSQ | 物理寄存器号 + ROB/LSQ 索引 + 控制位 + 操作数 |
| `rob_entry_t` | RN 写入，EX/MEM/WB 更新，RT 读取 | RT | 提交所需信息（见 `03-pipeline-regs.md` §4） |

---

## 2. 控制位定义（`uop_ctrl_t`，共 73 bit）

> 所有位在 ID 级一次译出，随 uop 流动；`reserved` 位写 0。
> 常量定义放在 `rtl/pkg/rv32gc_defs.vh`，RTL 中只使用宏名，不写字面量。

| 位段 | 字段 | 宽度 | 取值 |
|---|---|---|---|
| `[2:0]` | `op_class` | 3 | 0=ALU 1=BRU 2=MDU 3=LSU 4=FPU 5=CSR 6=SYS 7=NOP |
| `[7:3]` | `alu_op` | 5 | 0=ADD 1=SUB 2=SLL 3=SLT 4=SLTU 5=XOR 6=SRL 7=SRA 8=OR 9=AND |
| `[9:8]` | `alu_a_sel` | 2 | 0=rs1 1=pc 2=zero |
| `[12:10]` | `alu_b_sel` | 3 | 0=rs2 1=imm 2=const4（PC+4） 3=zero 4=imm_shamt（imm[4:0] 零扩展） |
| `[15:13]` | `br_type` | 3 | 0=none 1=BEQ 2=BNE 3=BLT 4=BGE 5=BLTU 6=BGEU |
| `[19:16]` | `br_flags` | 4 | `{is_ret, is_call, is_jalr, is_jal}` |
| `[22:20]` | `mdu_op` | 3 | 0=MUL 1=MULH 2=MULHSU 3=MULHU 4=DIV 5=DIVU 6=REM 7=REMU |
| `[25:23]` | `mem_op` | 3 | 0=NONE 1=LOAD 2=STORE 3=LR 4=SC 5=AMO |
| `[27:26]` | `mem_size` | 2 | 0=BYTE 1=HALF 2=WORD |
| `[29:28]` | `mem_flags` | 2 | `{mem_fp, mem_unsigned}` |
| `[31:30]` | `amo_flags` | 2 | `{amo_rl, amo_aq}` |
| `[36:32]` | `amo_op` | 5 | funct5：0x00=ADD 0x01=SWAP 0x04=XOR 0x08=OR 0x0C=AND 0x10=MIN 0x14=MAX 0x18=MINU 0x1C=MAXU |
| `[42:37]` | `fp_op` | 6 | 见 §2.1 |
| `[44:43]` | `fp_fmt` | 2 | 0=S 1=D（2/3 保留） |
| `[47:45]` | `fp_rm` | 3 | 0=RNE 1=RTZ 2=RDN 3=RUP 4=RMM 7=DYN（用 `frm`） |
| `[49:48]` | `csr_op` | 2 | 0=NONE 1=RW 2=RS 3=RC |
| `[52:50]` | `sys_op` | 3 | 0=ECALL 1=EBREAK 2=MRET 3=SRET 4=WFI 5=FENCE 6=FENCE_I 7=SFENCE_VMA |
| `[53]` | `csr_imm` | 1 | csrrwi/si/ci 的立即数形式（rs1 字段即 zimm） |
| `[55:54]` | `cbo_op` | 2 | 0=INVAL 1=CLEAN 2=FLUSH 3=ZERO（`cbo.*` 指令） |
| `[58:56]` | `wb_sel` | 3 | 0=ALU 1=MEM 2=PC4 3=CSR 4=FP 5=zero |
| `[59]` | `rd_wen` | 1 | 目标寄存器写使能（rd≠x0 且指令确实写寄存器） |
| `[60]` | `rd_is_fp` | 1 | 目标是浮点寄存器 |
| `[61]` | `use_rs1` | 1 | 需要读 rs1 |
| `[62]` | `use_rs2` | 1 | 需要读 rs2 |
| `use_rs3` | 1 | 需要读 rs3（仅 FMA 类） |
| `[63]` | `excp_valid` | 1 | 译码期已发现异常 |
| `[67:64]` | `excp_cause` | 4 | 0=none 1=illegal_instr 2=ecall_U 3=ecall_S 4=ecall_M 5=ebreak 6=instr_misaligned 7=illegal_csr 8=instr_access_fault |

> **编码说明**：`excp_cause` 采用**架构 `mcause` 的异常码**（4 bit 足以覆盖 RV32 的全部同步异常码：0~9、11~13、15），因此 `trap_ctrl.v` 在进入 trap 时可**直接使用**（无需翻译表）；中断码（`mcause[31]=1`）不经过 uop，由 RT 级采样后单独编码。若后续实现需要区分"译码期发现"与"执行期发现"的同一架构码，另设一位 `excp_stage`，**不得**改变该字段的架构语义。
| `[68]` | `is_fence` | 1 | FENCE（提交时作为屏障） |
| `[69]` | `is_fencei` | 1 | FENCE.I（提交时清 I-Cache） |
| `[70]` | `is_sfence` | 1 | SFENCE.VMA（提交时清 TLB） |
| `[71]` | `is_serial` | 1 | 串行化指令（CSR/SYS/FENCE 类，RT 级单条提交） |
| `[72]` | `use_rs3` | 1 | 需要读第三源（仅 FMA 类，`rs3_arch = instr[31:27]`） |

### 2.1 `fp_op` 编码

| 值 | 指令 | 值 | 指令 |
|---|---|---|---|
| 0 | FADD | 10 | FCVT_S_D / FCVT_D_S |
| 1 | FSUB | 11 | FCVT_W_S / FCVT_WU_S / FCVT_W_D / FCVT_WU_D |
| 2 | FMUL | 12 | FCVT_S_W / FCVT_S_WU / FCVT_D_W / FCVT_D_WU |
| 3 | FDIV | 13 | FMV_X_W（FP→整数） |
| 4 | FSQRT | 14 | FMV_W_X（整数→FP） |
| 5 | FSGNJ | 15 | FEQ |
| 6 | FSGNJN | 16 | FLT |
| 7 | FSGNJX | 17 | FLE |
| 8 | FMIN | 18 | FCLASS |
| 9 | FMAX | 19~23 | FMADD / FMSUB / FNMSUB / FNMADD（FMA 融合乘加） |

## 3. uop 数据字段

| 字段 | 宽度 | 说明 |
|---|---|---|
| `pc` | 32 | 指令 PC（分支目标、`mepc`、调试、`auipc`） |
| `instr` | 32 | 原始指令（RVC 已展开为 32 位）；仅用于 `mtval`（非法指令）与调试 |
| `imm` | 32 | 立即数（已按指令类型生成并符号/零扩展） |
| `rs1_arch` / `rs2_arch` | 5 / 5 | 架构源寄存器号（`csr_imm` 时 `rs1_arch` = zimm） |
| `rs3_arch` | 5 | **FMA 第三源**（`instr[31:27]`）；非 FMA 指令填 0，由 `use_rs3` 门控 |
| `rd_arch` | 5 | 架构目标寄存器号 |
| `csr_addr` | 12 | CSR 地址 |
| `predicted` | 2 | `{pred_taken, btb_hit}`（供 RT 更新预测器；BTB 目标不随 uop 携带） |
| `ghr_snapshot` | 12 | 分支预测时的 GHR（checkpoint 恢复与提交更新用） |

## 4. 译码表（RV32IMAFDC + Zicsr/Zifencei/Zicntr/Zicbom）

> 约定：`op_class` 决定发往哪个发射队列与执行单元；未列出的字段取 0。
> `rs1/rs2/rd` 为指令中的寄存器字段；`imm` 由 `imm_gen` 按 `imm_type` 生成。

### 4.1 RV32I 基础

| 指令 | funct3/funct7 | op_class | 控制位 | 写回 |
|---|---|---|---|---|
| LUI | — | ALU | `alu_op=ADD, alu_a_sel=zero, alu_b_sel=imm, imm_type=U` | `wb_sel=ALU`, rd_wen |
| AUIPC | — | ALU | `alu_op=ADD, alu_a_sel=pc, alu_b_sel=imm, imm_type=U` | `wb_sel=ALU` |
| JAL | — | BRU | `br_flags={ret=0,call=(rd==ra),jalr=0,jal=1}, is_jal, imm_type=J` | `wb_sel=PC4` |
| JALR | funct3=000 | BRU | `br_flags={ret=(rs1==ra && rd==x0),call=(rd==ra),jalr=1,jal=0}, imm_type=I` | `wb_sel=PC4` |
| BEQ/BNE/BLT/BGE/BLTU/BGEU | 000/001/100/101/110/111 | BRU | `br_type` 对应，`imm_type=B` | 不写 |
| LB/LH/LW/LBU/LHU | 000/001/010/100/101 | LSU | `mem_op=LOAD, mem_size, mem_unsigned=(funct3[2])` | `wb_sel=MEM` |
| SB/SH/SW | 000/001/010 | LSU | `mem_op=STORE, mem_size` | 不写 |
| ADDI/SLTI/SLTIU/XORI/ORI/ANDI | 000/010/011/100/110/111 | ALU | `alu_op` 对应，`alu_b_sel=imm, imm_type=I` | `wb_sel=ALU` |
| SLLI/SRLI/SRAI | 001/101 | ALU | `alu_op=SLL/SRL/SRA, alu_b_sel=imm_shamt, imm_type=SHAMT` | `wb_sel=ALU` |
| ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND | 011/000 | ALU | `alu_op` 对应，`alu_b_sel=rs2`；ADD(0000000)/(0100000)=SUB | `wb_sel=ALU` |
| FENCE | 000 | SYS | `sys_op=FENCE, is_fence=1, is_serial=1` | 不写 |
| FENCE.I | 001 | SYS | `sys_op=FENCE_I, is_fencei=1, is_serial=1` | 不写 |
| ECALL / EBREAK | 000/001 (priv) | SYS | `sys_op=ECALL/EBREAK, excp_valid=1, excp_cause=ecall_*, is_serial=1` | 不写 |
| MRET / SRET / WFI | 0001000/0001001/0000101 | SYS | `sys_op=MRET/SRET/WFI, is_serial=1` | 不写 |
| CSRRW/S/C + I 变体 | 001/010/011/101/110/111 | CSR | `csr_op=RW/RS/RC, csr_imm=(funct3[2]), is_serial=1, use_rs1=(csr_op!=RS_imm...)` | `wb_sel=CSR` |

### 4.2 M 扩展（`op_class=MDU`）

| 指令 | funct3 | `mdu_op` |
|---|---|---|
| MUL / MULH / MULHSU / MULHU | 000/001/010/011 | 0/1/2/3 |
| DIV / DIVU / REM / REMU | 100/101/110/111 | 4/5/6/7 |

### 4.3 A 扩展（`op_class=LSU`）

| 指令 | funct5 | `mem_op` | 其他 |
|---|---|---|---|
| LR.W | 00010 | LR | `amo_aq/rl` 来自指令位 |
| SC.W | 00011 | SC | 同上 |
| AMOSWAP/ADD/XOR/AND/OR/MIN/MAX/MINU/MAXU.W | 00001/00000/00100/01100/01000/10000/10100/11000/11100 | AMO | `amo_op` = funct5 |

### 4.4 F/D 扩展（`op_class=FPU`）

| 指令组 | funct7 / opcode | `fp_op` / 其他 |
|---|---|---|
| FADD.S/D, FSUB.S/D | 0000000/0000100 (OP-FP) | 0/1，`fp_fmt` 按 fmt 位 |
| FMUL.S/D, FDIV.S/D | 0001000/0001100 | 2/3 |
| FSQRT.S/D | 0101100 | 4 |
| FSGNJ/N/X.S/D | 0010000 | 5/6/7（funct3 区分） |
| FMIN/FMAX.S/D | 0010100 | 8/9（funct3 区分） |
| FCVT.S.D / FCVT.D.S | 0100000 / 0100001 | 10 |
| FCVT.W[U].S/D | 1100000/1100001 | 11（`rs2` 区分 W/WU，`fp_fmt` 区分 S/D） |
| FCVT.S/D.W[U] | 1101000/1101001 | 12 |
| FMV.X.W / FMV.W.X | 1110000 / 1111000 | 13 / 14（`rd_is_fp`/`wb_sel=FP` 相应设置） |
| FEQ/FLT/FLE.S/D | 1010000 | 15/16/17（funct3 区分） |
| FCLASS.S/D | 1110000 (rs2=0) | 18 |
| FMADD/FMSUB/FNMSUB/FNMADD.S/D | OP-FP opcode 1000011/1000111/1001011/1001111 | 19~22 |
| FLW/FLD | LOAD-FP 0000111 | `mem_op=LOAD, mem_fp=1`，width=funct3 |
| FSW/FSD | STORE-FP 0100111 | `mem_op=STORE, mem_fp=1` |

### 4.5 Zicbom（`op_class=SYS`）

| 指令 | funct12 | `cbo_op` | 其他 |
|---|---|---|---|
| CBO.INVAL | 000000000000 | 0 | `is_serial=1`，地址来自 rs1 |
| CBO.CLEAN | 000000000001 | 1 | 同上 |
| CBO.FLUSH | 000000000010 | 2 | 同上 |
| CBO.ZERO | 000000000100 | 3 | 同上（写 32 B 零，需独占） |

> `cbo.*` 在实现上作为"访存类串行指令"：走 LSU（地址生成、TLB 翻译、cache 操作），在 RT 级提交。

### 4.6 压缩指令（RVC）展开

RVC 在 ID 级由 `rvc_expand.v` 展开为等价的 32 位指令后进入同一译码路径，**不新增 uop 类型**。展开规则要点：

| RVC | 等价 32 位 | 备注 |
|---|---|---|
| C.ADDI4SPN | ADDI rd', x2, nzuimm | nzuimm=0 时非法 |
| C.LW/C.SW/C.FLD/C.FSD/C.FLW/C.FSW | LW/SW/FLD/FSD/FLW/FSW | 地址 = rs1'+uimm |
| C.ADDI/C.ADDIW(仅 RV64)/C.LI/C.LUI | ADDI/LI/LUI | `c.li` = ADDI rd,x0,imm |
| C.ADDI16SP/C.ADDIW | ADDI rd,x2/ADDI | — |
| C.SRLI/C.SRAI/C.ANDI/C.SUB/C.XOR/C.OR/C.AND/C.SUBW… | 对应算术/逻辑 | 使用 rd'/rs1'/rs2' |
| C.J/C.JAL | JAL（rd=x0/x1） | — |
| C.BEQZ/C.BNEZ | BEQ/BNE（rs2=x0） | — |
| C.JR/C.JALR | JALR（rd=x0/x1，imm=0） | `c.jr` rs1=x0 时保留（非法） |
| C.MV/C.ADD | ADD rd,x0,rs2 / ADD | — |
| C.LWSP/C.LDSP/C.FLDSP/C.FLWSP | LW/LD/FLD/FLW（rs1=x2） | rd=x0 时非法 |
| C.SWSP/C.SDSP/C.FSDSP/C.FSWSP | SW/SD/FSD/FSW（rs1=x2） | — |
| C.NOP / C.EBREAK | NOP / EBREAK | — |
| C.LD/C.SD（Zcd） | LD/SD | 本设计 FLEN=64，支持 Zcd |

**取指对齐**：ID 级每周期从取指队列取出最多 4 条**已展开**的 32 位指令；若 16 B 取指块中的 RVC 边界导致某条指令跨块，由 `fetch_queue` 负责拼接（见 `04-frontend.md`）。

## 5. 立即数生成（`imm_gen`）

| 类型 | 来源位 | 说明 |
|---|---|---|
| I | `instr[31:20]` | 符号扩展 |
| S | `{instr[31:25], instr[11:7]}` | 符号扩展 |
| B | `{instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}` | 符号扩展（13 位） |
| U | `{instr[31:12], 12'b0}` | 低 12 位补 0 |
| J | `{instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}` | 符号扩展（21 位） |
| SHAMT | `{27'b0, instr[24:20]}` | 零扩展（RV32 只用低 5 位） |
| CSR_ZIMM | `{27'b0, instr[19:15]}` | csrrwi 等的 5 位零扩展 |

## 6. 译码期异常检测（`excp_valid`/`excp_cause`）

| 检测项 | 条件 | cause |
|---|---|---|
| 非法指令 | 无匹配译码项；RVC 展开非法（nzuimm=0、rd=x0 的 c.lwsp 等） | 2（illegal_instr），`tval = instr` |
| 非法 CSR 访问 | CSR 地址不存在，或特权级不足，或只读 CSR 被写 | 2（按规范非法指令） |
| ECALL/EBREAK | 直接译码产生 | 8/9/11、3（按特权级） |
| 跳转目标非对齐 | JAL/JALR/Branch（在 EX 级检测，不在译码期） | 0/3（EX 级产生） |
| `mstatus.FS=Off` 执行浮点 | 译码期检查 `fs_off` | 2 |

> 译码期异常**不阻塞** uop 流动：uop 带 `excp_valid` 进入后端，在 RT 级（ROB 头部）精确触发。

## 7. 验证要点

1. **译码表逐条测试**：对每条指令用汇编器生成机器码（`riscv32-unknown-linux-gnu-as`），驱动 `decoder` + `imm_gen`，比对输出控制位与期望值（用一份表格驱动的 testbench 自动生成）；
2. **RVC 展开**：RVC 与其 32 位等价指令必须产生**完全相同的 uop**（逐位比对），对全部 26+ 条 Zca 指令覆盖；
3. **非法指令**：对每个未定义编码（含 `c.*` 保留编码）检查 `excp_valid=1` 且 `cause=2`；
4. **CSR 权限**：U/S 模式访问机器级 CSR、写只读 CSR、访问不存在的 CSR 都必须报非法指令。
