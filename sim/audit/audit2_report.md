# AUDIT2 —— RTL 语义审查报告（对照 RV32 ISA，仅用 RTL 做代码检查）

- **冻结基准**：`git rev-parse HEAD` = `201d88d03b32b05bbe3d492ad1089b11f7000513`
  （任务书指定冻结基准 `d00eb03`；`git diff --stat d00eb03..HEAD` 仅改动
  `fpga/area-optimization-report.md`，**RTL/TB/脚本零改动** ⇒ 本报告结论对 `d00eb03` 同样成立）
- **审计范围**：`rtl/exec/alu.v`、`rtl/exec/bru.v`、`rtl/exec/mdu.v`、
  `rtl/decode/{decoder,dec_imm,dec_csr}.v`、`rtl/csr/{csr_file,priv_ctrl,trap_ctrl,ptw,tlb}.v`、
  `rtl/mem/{lsu,pmp_check}.v`、`rtl/back2/{backend_top,lsq_simple}.v`、`rtl/top/{core_top,core_top_2b}.v`
- **方法**：① `riscv-kb`（本会话 `kb_search` 工具链不可用，改用同一知识库 CLI
  `node dsh-extension/bin/riscv-kb.js search|get`，与工具同一 store/ranking）引 ISA 原文；
  ② RTL 逐行语义对照；③ 对可执行部分用 iverilog 跑**既有**单元 TB 与**只读新建**的
  直驱夹具（只写 `fpga/scratch/audit2_*`）取实证。**未使用 Spike/任何模拟器做 trace 对照。**
- **ISA 来源**（kb 路径均为 `riscv-isa-manual/src/**` 与 `riscv-arch-test/coverpoints/norm/**`）：
  `unpriv/rv32.adoc`、`unpriv/zicsr.adoc`、`unpriv/cmo.adoc`、
  `priv/machine.adoc`、`priv/supervisor.adoc`、`unpriv/m-st-ext.adoc`
- **锚点**：`AUDIT2: PASS`（判据脚本 `fpga/scratch/audit2_gate.sh`）
- **两个核的区分**：`rtl/top/core_top.v` = 2A 基线核（arch-test / lockstep 实际被测 DUT）；
  `rtl/top/core_top_2b.v` = 2B 乱序核（`backend_top` + `lsq_simple`）。差异项逐条标注所属核。

---

## ① 指令语义覆盖表（26 条，三态：OK / 差异 / 未涵盖）

| # | 指令 | ISA 规范（kb 引号原文，路径:行） | RTL 语义（文件:行） | 一一对应检查 | 判定 |
|---|---|---|---|---|---|
| 1 | `add`/`sub` | `rv32.adoc:334-356` "add performs the addition of rs1 and rs2 ... Overflows are ignored and the low XLEN bits of results are written" | `alu.v:107-108` `f_a+f_b` / `f_a-f_b`（32 位模 2^32） | 模 2^32 回绕、无异常 | OK |
| 2 | `slt`/`sltu` | `rv32.adoc:334-356` "slt and sltu perform signed and unsigned compares respectively, writing 1 to rd if rs1 < rs2, 0 otherwise" | `alu.v:112` `$signed(f_a)<$signed(f_b)?1:0`；`:113` `f_a<f_b?1:0` | 结果恒 1/0；有/无符号分域 | OK（`tb_alu` 50 向量 0 错） |
| 3 | `sll`/`srl`/`sra` | `rv32.adoc:266-333` "the shift amount is encoded in the lower 5 bits of the I-immediate field for RV32" | `alu.v:110/115/116` 取 `f_b[4:0]`；`dec_imm.v:101-106` `{27'b0,x[24:20]}` | RV32 移位量 mod 32；SRA 算术右移 | OK |
| 4 | `slli`/`srli`/`srai`（合法性） | `rv32.adoc:266-333` shamt[5]=insn[25]；`rv32_defs.vh:95-96` funct7 必须 0000000/0100000 | `decoder.v:284` `opimm_slli_ok = f3==SLLI && f7==SRLI`；`:285-286` srxi 限 SRLI/SRAI | fun7 强校验，非法编码 ⇒ cause 2 | OK |
| 5 | `lui` | `rv32.adoc:266-333` "places the U-immediate ... filling in the lowest 12 bits with zeros" | `dec_imm.v:82-87` `{x[31:12],12'b0}`；`alu.v:120` `result=f_b` | 低 12 位补 0、不移位 | OK |
| 6 | `auipc` | `rv32.adoc:266-333` "adds the U-immediate to the address of the auipc instruction" | `alu.v:122` `f_pc+f_b`；`decoder.v:625` auipc→ALU_ADD；`backend_top.v:1548` `w_au ? w_pc : rf` | pc+imm 路径正确（ALU_AUIPC=11 未被译码器使用，见 D8） | OK（低风险死编码） |
| 7 | `beq`/`bne`/`blt`/`bge`/`bltu`/`bgeu` | `rv32.adoc:528-639` "The 12-bit B-immediate ... sign-extended and added to the address of the branch" | `dec_imm.v:71-76`；`bru.v:107-125` 比较；`:130/140-142` `pc+imm` | 有/无符号比较分域、目标 pc+imm | OK（`tb_bru` 37 向量 0 错） |
| 8 | `jal` | `rv32.adoc:398-527` "J-immediate ... sign-extended and added to the address of the jump" | `dec_imm.v:91-96`；`bru.v:140` `pc+imm`；`decoder.v:332` `jal_ok=1`（全编码合法） | J 型任意编码合法（曾误判非法，已修） | OK |
| 9 | `jalr` | `rv32.adoc:398-527` "the least-significant bit of the result is always set to zero" | `bru.v:131` `(rs1+imm)&32'hFFFFFFFE` | bit0 强制清 0 | OK |
| 10 | `lb`/`lh`/`lw`（符号扩展） | `rv32.adoc:640-767` load 语义（LB/LH 符号扩展到 XLEN） | `lsq_simple.v:956-969` `ext_load`；`:1028` 窗口先右移 a2 字节 | 窗口位序 = 访问字节 0；符号/零扩展正确 | OK（N12-fix `e66241d`） |
| 11 | `lbu`/`lhu`（零扩展） | 同上 | `lsq_simple.v:964-965` uns=1 ⇒ `{24'h0,b0}` / `{16'h0,h0}` | 零扩展正确 | OK |
| 12 | `sb`/`sh`/`sw`（对齐） | `rv32.adoc:640-767` "loads and stores that are not naturally aligned may either complete execution successfully or raise an exception. The exception ... address-misaligned ..." | `lsq_simple.v:413-415` `lmask_w`、`:1225` `stq_d<=wdata<<a2`、`:1230` `stq_msk<=lmask_w`、`:1131` 仅 8 B 有第二条 CDQ | 非对齐 ≤4 B：既未抛异常、也未完整落地 | **差异 D1（严重）** |
| 13 | `mul` | `m-st-ext.adoc:58-132` MUL 低 XLEN 位 | `mdu.v:309/323` `p_uu[31:0]` | 低半部模 2^32 | OK（`tb_mdu` 168 向量 0 错） |
| 14 | `mulh`/`mulhsu`/`mulhu` | `m-st-ext.adoc` 高半部语义（4 类有/无符号组合） | `mdu.v:311/313-316/319-321` | 三种 signedness 精确匹配 | OK |
| 15 | `div`（除零） | `m-st-ext.adoc:58-132` "division by zero ... quotient ... all ones" | `mdu.v:351-354` `y==0 ⇒ REM?x:0xFFFFFFFF` | 商全 1、余数=被除数 | OK |
| 16 | `div`/`rem`（有符号溢出） | `m-st-ext.adoc:58-132` "Signed division overflow occurs only when the most-negative integer is divided by −1. The quotient ... dividend, remainder zero" | `mdu.v:356-364` `x==0x80000000 && y==0xFFFFFFFF ⇒ DIV?0x80000000:0` | 仅 DIV/REM 分支，DIVU/REMU 不走 | OK |
| 17 | `div`/`rem`（余数符号） | `m-st-ext.adoc:58-132` "the sign of a nonzero result equals the sign of the dividend" | `mdu.v:346-349` `r_sgn = xs ? -ur : ur` | 向零取整、余数随被除数 | OK |
| 18 | `csrrw`/`csrrs`/`csrrc`/`csrrwi/si/ci` | `zicsr.adoc:20-190` 读/写表；`csrrs/csrrc` rs1=x0 不写；写只读 CSR ⇒ 非法 | `decoder.v:377-393` `csr_will_wr`；`dec_csr.v:193-194` `csr_ro_write_ill` | 读写权限与"是否写"判定正确 | OK |
| 19 | `ecall` | `machine.adoc:2606-2644` U/S/M ⇒ cause 8/9/11 | `decoder.v:396`；`backend_top.v:679-681`；`rv32_defs.vh:475-477` | cause 随源特权级 | OK |
| 20 | `ebreak` | `machine.adoc` breakpoint cause 3 | `backend_top.v:806` `ebreak ? BREAK(3)`；`trap_ctrl.v:243-245` tval=原始指令位 | cause 3 | OK |
| 21 | `mret` | `machine.adoc:353-445` "xIE is set to xPIE; privilege mode changed to y; xPIE set to 1; xPP set to least-privileged" | `priv_ctrl.v:210-218` MIE←MPIE、MPIE←1、MPP←U；`:142` 目标=MPP | 位序/替换语义正确 | OK |
| 22 | `sret` | 同上；`TSR` 门控 | `priv_ctrl.v:220-226` SIE←SPIE、SPIE←1、SPP←U；`core_top.v:1424` TSR 门控 | OK | OK |
| 23 | `fence`/`fence.i` | `zifencei.adoc:2-126` 取指与先前写序 | `core_top_2b.v:283-291` fence.i 全阵列扫掠；`:521/660` 冻结窗口 | fence.i 实现（2A `core_top.v:885-905` 同口径） | OK |
| 24 | `sfence.vma` | `supervisor.adoc` TLB 失效；U 模式执行 ⇒ 非法 | `tlb.v:303-348` 失效判定；`core_top.v:1426` U 模式非法；`core_top_2b.v:575-578` 全失效 | 失效范围保守全刷；U 模式非法（2A） | OK |
| 25 | `wfi` | 特权指令；`machine.adoc` TW 门控 | 2A `core_top.v:1425` `<M && TW ⇒ 非法`；2B `backend_top.v:733/740` 恒 unsup | 2A OK；**2B 未涵盖** | 差异 D7（2B） |
| 26 | `amo*`/`lr`/`sc`（A 扩展） | `rvwmo.adoc` / `unpriv/a-st-ext`（PMP 判权同 store） | 2A：`core_top.v:2020-2116` 例化 `amo_unit`；2B：`backend_top.v:740` `opt==5 ⇒ unsup`（cause 2） | 2A OK；2B 译码即判非法 | 差异 D7（2B） |

---

## ② 确定差异清单（每条：ISA 原文 + RTL 行号 + 现状 + Tier + 修正建议）

### D1【严重】2B 核：≤4 B 非对齐 store 静默丢字节，且不抛地址非对齐异常

- **ISA 原文**（`riscv-isa-manual/src/unpriv/rv32.adoc:640-767`，`norm:misalignedldstexc_type`）：
  > "loads and stores that are not naturally aligned **may either complete execution successfully or raise an exception**. The exception raised can be either an address-misaligned exception or an access-fault exception."
  ⇒ 只允许"完整完成"或"抛异常"二选一；**不允许部分落地且不报异常**。
- **RTL 现状**（`rtl/back2/lsq_simple.v`）：
  - `:413-415` `lmask_w = (size==0)?4'h1<<a2 : (size==1)?4'h3<<a2 : 4'hF<<a2;`
    —— 4 bit 掩码被截断：a2=1 的 `sw` 掩码 = `0xE`（低字只盖 3 字节）。
  - `:1225` `stq_d <= exe_wdata << {exe_addr[1:0],3'b000};` —— 数据左移 a2 字节，
    高字节被移出 32 bit 寄存器后**无处可去**。
  - `:1230` `stq_msk <= (exe_size==3'd3) ? 4'hF : lmask_w;`
  - `:1007` `st_mis_w = exe_valid & exe_is_store & (exe_size==3'd3) & (exe_addr[2:0]!=0);`
    —— **只对 8 B store 抛 cause 6**；≤4 B 非对齐既不拆分也不报异常。
  - `:1119-1132` 仅 `stq_hi`（8 B）生成第二条 CDQ 项；≤4 B 永远只有一条。
- **实测证据**（`fpga/scratch/audit2_lsq_mis_tb.sv`，LSQ 直驱，模型只按 `wstrb` 写 `mem[addr[15:2]]`）：
  ```
  [store-req] addr=0x80001001 wdata=0xbbccdd00 wstrb=1110   // 非对齐 sw@+1
  B misaligned sw@+1: mem[0x1004]=0x55667788 (ISA exp 0x556677aa)   ← 第 4 字节 0xAA 丢失
  [store-req] addr=0x80003003 wdata=0x5a000000 wstrb=1000   // 非对齐 sh@+3
  C misaligned sh@+3: mem[0x3004]=0x0a0b0c0d (ISA exp 0x0a0b0c7a)   ← 第 2 字节 0x7A 丢失
  FAIL[audit2-lsq]: B2 crossing byte @base+4 landed per ISA
  FAIL[audit2-lsq]: C2 crossing byte @base+4 landed per ISA
  AUDIT2_LSQ_MIS: FAIL n=2
  ```
  对照 `sw`（`addr=0x80002000 wstrb=1111`）四字节全部落地 ⇒ 夹具/排空通路本身正常。
- **旁证**：2B 历史两次修的都是**非对齐 load**（`0a4b178` "≤4B 非对齐 load 跨 4B 字边界访存缺口"、
  `e66241d` "LSQ 非对齐转发写回值字节错位"），**从未触及非对齐 store**；arch-test 树内
  `find riscv-test-suite -iname '*misalign*'` = 0 命中，故回归不能自证。
- **修正建议（二选一，二者都合规）**：
  1. **抛异常**：把 `st_mis_w` 的 `(exe_size==3'd3)` 放宽为"任意 `exe_addr[1:0]!=0` / `exe_addr[2:0]!=0`"，
     复用现有 `stq_bad`（`:1224`）与 cause 6 精确陷阱；最小改动、与 2A `lsu.v` 口径一致。
  2. **硬件完成**：把 ≤4 B 非对齐 store 也拆成两条 CDQ 项（低字 = `wdata<<a2`、掩码 `lmask_w`；
     高字 = `wdata>>(32-8*a2)`、掩码 `(1<<a2)-1`，地址 +4），复用 8 B store 的两条 CDQ 机制（`:1119-1132`）。

### D2【中】S 级中断在 U 模式被 SIE 误掩蔽（2A 与 2B 共用 `trap_ctrl`）

- **ISA 原文**（`riscv-isa-manual/src/priv/supervisor.adoc:366-489`）：
  > "An interrupt i will trap to S-mode if both of the following are true: (a) either the current privilege mode is S and the SIE bit in the sstatus register is set, **or the current privilege mode has less privilege than S-mode**; and (b) bit i is set in both sip and sie."
  （同文另见 `riscv-arch-test/coverpoints/norm/S.yaml:107-112` 逐字引用）
- **RTL 现状**：`rtl/csr/trap_ctrl.v:178-182`
  ```
  irq_visible = mip_v[code] & mie_v[code] &
                ( is_s_irq ? ((cur_priv==PRIV_M) ? 1'b0 : mstatus_v[SIE_BIT])
                           : ((cur_priv==PRIV_M) ? MIE : 1'b1) ) & ...
  ```
  S 级中断（SSI/STI/SEI）在 **U 模式**仍要求 `SIE=1`；ISA 要求 U 模式（特权级 < S）**不看 SIE**。
  M 级中断的对应逻辑（`:181-182`，`priv<M ⇒ 恒开`）已正确（G1 修复）。
- **修正建议**：`is_s_irq` 分支改为 `(cur_priv==PRIV_M) ? 1'b0 : ((cur_priv==PRIV_U) ? 1'b1 : mstatus_v[SIE_BIT])`。

### D3【中】PMP：`pmpcfg[i].L=1` 时 `pmpaddr[i]` 仍可写

- **ISA 原文**（`riscv-isa-manual/src/priv/machine.adoc:3542-3563`，`norm:pmplbitwriteprotection`）：
  > "If PMP entry i is locked, **writes to pmpcfg[i] and pmpaddr[i] are ignored**. Additionally, if PMP entry i is locked and pmpcfg[i].A is set to TOR, writes to pmpaddr[i−1] are ignored."
- **RTL 现状**：
  - `rtl/csr/csr_file.v:484-488` + `:522-531`：cfg 侧正确逐项按 `cur[7]`（L）锁定。
  - `rtl/csr/csr_file.v:489-498`：addr 侧只有一个门 `pmp_tor_locked(a, pmp_cfg_cur)`；
  - `rtl/csr/csr_file.v:535-548`：`pmp_tor_locked` 只检查**后继项** `cfg[(i+1)*8+7] && A==TOR`，
    **从不检查本项 `i` 自己的 L 位** ⇒ `pmpaddr[i]` 在 `pmpcfg[i].L=1` 时仍被写入。
  - 注释 `:663` 也自述"addr 的 TOR 前驱"是唯一 addr 锁定路径，与 ISA 不符。
- **修正建议**：`pmp_tor_locked` 并入本项判定：`own_locked = cfg[i*8+7]`；落地改为
  `pmp_tor_locked(a,cfg) || own_locked ? cur : (d & m)`（`i = a[4:0]-16`）。
- **对照**：arch-test `PMPSm` 有 coverpoint `pmp_l_bit_write_protection`（`norm/PMPSm.yaml:59-64`），
  但既有回归清单未暴露该组合（见 ③ U1）。

### D4【中】`mcounteren`/`scounteren` 未实现计数器访问门控

- **ISA 原文**（`riscv-arch-test/coverpoints/norm/ZicntrU.yaml:23-29`，源自 `priv/machine.adoc`）：
  > "When the CY, TM, IR, or HPMn bit in the mcounteren register is clear, attempts to read the cycle, time, instret, or hpmcountern register while executing in S-mode or U-mode will cause an illegal-instruction exception."
  （`supervisor.adoc:501-531`：U 模式需 `scounteren` 与 `mcounteren` 对应位**同时**为 1）
- **RTL 现状**：
  - `rtl/decode/dec_csr.v:98-103` 把 cycle/time/instret 直接列入 `is_csr_ucntr` 白名单；
    `:174-194` 的合法性只看"地址实现 / 特权级位段 / 只读写"，**端口表里根本没有
    `mcounteren/scounteren` 输入**（见 `:50-70`）。
  - `rtl/csr/csr_file.v:745` 注释自称"mcounteren/scounteren 门控在访问权限判定里由 dec_csr 处理"
    —— 与 `dec_csr.v` 实际端口矛盾（文档与现实脱节）。
  - `rtl/top/core_top_2b.v:1519` `.mcounteren_o(), .scounteren_o(),` 直接悬空；
    `rtl/top/core_top.v:2437/2506-2507` 虽引出 `csr_mcounteren/csr_scounteren` 但无消费者。
  ⇒ S/U 模式在 `mcounteren.CY/TM/IR=0` 时读 `cycle/time/instret` **不会**抛 cause 2。
- **修正建议**：给 `dec_csr` 增 `mcounteren/scounteren` 输入，`is_csr_ucntr` 且
  `priv!=M` 时按 `{U: mcounteren&scounteren, S: mcounteren}` 对应位为 0 ⇒ `csr_ill`；
  顶层把 `csr_file.mcounteren_o/scounteren_o` 接入。

### D5【中】`mstatus.TVM` 未强制（`satp` 访问与 S 模式 `sfence.vma`）

- **ISA 原文**（`priv/supervisor.adoc`，`mstatus.TVM`）：TVM=1 时，S 模式执行
  `sfence.vma`/访问 `satp` 须抛非法指令（另见 `svinval.adoc:2-96` 对同类指令的权限要求）。
- **RTL 现状**：
  - `rtl/top/core_top.v:1419-1426` 注释明写"**mstatus.TVM 门控本阶段不实现**"；
    `e_priv_ill` 只含 mret/sret/wfi/sfence-U，**无 TVM 项**。
  - `rtl/csr/priv_ctrl.v:253` 已把 `tvm_o` 引出，但无人消费；
    `rtl/backend/backend_top.v`（2B）同样无 TVM。
- **修正建议**：`e_priv_ill |= (de_sfence_vma & (csr_priv_2==PRIV_S) & csr_tvm)
  | (satp 访问 & (csr_priv_2==PRIV_S) & csr_tvm)`；2B 侧同口径补。

### D6【低】`mtvec`/`stvec` 的 Vectored WARL 对齐：读出基址 ≠ 实际向量基址

- **ISA 原文**（`machine.adoc:1163-1225`，`norm:mtvecbasealign_4B/funcmode`）：
  > "The value in the [base] field must always be aligned on a 4-byte boundary, and the [mode] setting may impose additional alignment constraints."
  Vectored 下若实现要求 256 B 对齐，则**该约束必须反映在 CSR 读回值上**（WARL：非法写入须被合法化）。
- **RTL 现状**：
  - 写路径 `rtl/csr/csr_file.v:464-470`：`csr_landing = {d[31:2],2'b00} | mode` ⇒ **只清低 2 位**，
    MODE=1 时 `d[7:2]` 被原样保存、读回可见。
  - 用路径 `rtl/csr/trap_ctrl.v:270`：`vec_base = is_vectored ? {raw[31:8],8'h00} : {raw[31:2],2'b00}`
    ⇒ 中断实际跳到 **清低 8 位后**的基址。
  ⇒ 软件读回 `mtvec=0x8000_0121`（MODE=1）时，硬件却从 `0x8000_0100 + 4×cause` 取中断，读回值不是真值。
- **修正建议**：`csr_landing` 的 mtvec/stvec 分支在 `mode_new==2'b01` 时同时清 `d[7:2]`：
  `csr_landing = { (mode_new==VECTORED ? d[31:8] : d[31:2]), (mode_new==VECTORED?8'b0:2'b00)} | mode_new;`。

### D7【低/中】2B 核：`misa.A=1` 但 AMO/LR/SC（及 `wfi`）一律抛 cause 2

- **ISA/工程口径**：`rtl/pkg/core_params.vh:248` `RV32GC_ISA_STRING = "RV32IMAFDC..."`；
  `rtl/csr/csr_file.v:733-741` `MISA_EXT_BITS` 含 `(1<<0)`（A）与 `(1<<20)`（U）；
  `sim/arch_test/exclude.list:14` 自述实现集合含 A(Zaamo/Zalrsc)。
- **RTL 现状（仅 2B）**：`rtl/back2/backend_top.v:740-741`
  `unsup = ((opt==8) & ~is_sys_ok) | (opt==5) | (opt==15);`（`opt==5` 即 OPT_AMO），
  `:755` `kill = unsup | illegal`，`:807` `kill ⇒ ILLEGAL`；`:733` 注释"wfi 仍留 unsup（本里程碑不需要）"。
  ⇒ 2B 核译码 AMO/LR/SC/WFI 后**不执行、抛 cause 2**，但其 `misa` 由同一 `csr_file` 给出 A=1。
- **说明**：arch-test/lockstep 的实际 DUT 是 2A `core_top.v`（`sim/arch_test/run.sh:12`、
  `sim/lockstep/tb_lockstep.sv:39/186-188`），其中 A 由 `amo_unit` 正常实现；本条是 **2B 的范围缺口 +
  `misa` 声明不一致**，非 2A 缺陷。
- **修正建议**：2B 未实现 A 期间，把 `misa` 的 A 位/ISA 串按核配置下沉（`core_params` 分档），
  或明确登记"2B 里程碑不含 A/WFI"；两者不要同时宣称。

### D8【低】文档与真源/实现不一致（不影响当前功能，但会把后续改动人带偏）

- `rtl/exec/alu.v:9-10` 头注称"`RV32GC_ALU_*` 编号即 `rtl/pkg/rv32_defs.vh` 的 `alu_op` 编码"，
  但 **pkg 中不存在任何 `ALU_*` 定义**（`grep -n 'ALU_' rtl/pkg/rv32_defs.vh` 零命中）；
  编码真源实际在 `rtl/decode/decoder.v:130-141`（`ALU_PASSB=10`、`ALU_NONE=15`），
  而 `alu.v:93-94` 把 10/11 命名为 `ALU_LUI/ALU_AUIPC`。其中 `ALU_AUIPC(11)` 无任何产生方
  （auipc 走 `ALU_ADD` + `a=pc`）⇒ 死编码。建议：`alu.v` 头注改为指向 `decoder.v`，
  或把编号真正落入 pkg；删除或保留 `ALU_AUIPC` 需二者择一并注明。
- `rtl/back2/back2_params.vh:615-616` 注释 `EXC_LOAD_MIS 4'd4`/`EXC_ST_MIS 4'd6` 标为
  "保留，本里程碑不产生"，但 `rtl/back2/lsq_simple.v:1012-1013` 确实产生这两个 cause
  （8 B 非对齐）。注释已过期，建议同步。
- `rtl/exec/bru.v:137` `taken = is_jal|is_jalr|br_taken` 未按"本指令是分支/跳转"门控；
  `backend_top.v:1571` 对**所有** lane 计算 `bru_act_tk`。当前无害（消费者 `:1586`
  `bru_is_ctl=(cls!=0)`、`:2157` `upd_tr_v` 按 `w_is_br` 门控），但属"依赖下游门控"的潜在坑：
  建议 `bru_act_tk = bru_is_ctl & (...)` 显式收口。

---

## ③ 未涵盖清单（ISA 语义在 RTL 中找不到对应定义 ⇒ 同样计入缺陷）

| 编号 | 未涵盖语义 | 依据 | 现状 |
|---|---|---|---|
| U1 | `mcounteren`/`scounteren` 计数器读门控 | `norm/ZicntrU.yaml:23-29` | 无任何 RTL 定义（D4） |
| U2 | `mstatus.TVM`（satp / sfence.vma） | `priv/supervisor.adoc` | 寄存器位有存储、无强制（D5） |
| U3 | 2B 核 A 扩展（amo*/lr/sc） | 工程 ISA 串含 A | `backend_top.v:740` 判非法（D7） |
| U4 | 2B 核 `wfi` | 特权指令 | `backend_top.v:733/740` 判非法（D7） |
| U5 | RVC 压缩指令全集 | `unpriv/zca.adoc` | 2A 经 `compressed_expand.v` 覆盖；2B 前端亦展开——**本报告未逐条审计 RVC 立即数**（超出本次分配范围，建议另派） |
| U6 | `misa` 与各核能力的一致性 | `csr_file.v:733-741` | 单一 `misa` 常量服务两个核（D7） |

> 说明：U5 已由 `dec_imm.v:118-227` 的 RVC 变体实现（与 binutils `EXTRACT_*` 宏逐项对应），
> 但本次未逐条与 `zca.adoc` 对表，故列"未涵盖"而非"OK"。

---

## ④ 排除清单（明确检查过、未发现差异的证据行号）

| 检查项 | 证据（文件:行） | 结论 |
|---|---|---|
| ALU 12 条运算 + INT_MIN/INT_MAX + 移位 ≥32 | `rtl/exec/alu.v:106-127`；`sim/unit/tb_alu.sv` 运行结果 `checked 50 vectors, 0 errors PASS` | 无差异 |
| BRU 6 条件 + jal/jalr 目标 + jalr bit0 | `rtl/exec/bru.v:107-142`；`tb_bru` `checked 37, 0 errors PASS` | 无差异 |
| MDU 除零/溢出/余数符号/mulh 三 signedness/时序/flush | `rtl/exec/mdu.v:298-375,548-642`；`tb_mdu` `checked 168, 0 errors PASS` | 无差异 |
| 立即数 I/S/B/U/J + RVC 变体符号/零扩展 | `rtl/decode/dec_imm.v:53-106,118-227`；选择网络 `:240-246` | 无差异 |
| RV32 shamt 5 位 + funct7 合法性强校验 | `decoder.v:284-287`；`dec_imm.v:101-106` | 无差异 |
| `addi` vs `sub` 跨族误判（历史坑） | `decoder.v:637-642`（已按 `is_op & f7==ALT` 分域） | 无差异 |
| LOAD/STORE funct3 合法性（无 sb/sh/sw 之外的越权） | `decoder.v:260-274` | 无差异 |
| `jal` 任意编码合法（曾误判非法） | `decoder.v:314-336` | 无差异 |
| 非对齐 ≤4 B **load** 跨字取数（N12-fix/N12B-cross） | `lsq_simple.v:1028-1043`（窗口右移 a2、64 bit 跨字窗口）、`:655-667`（xw 判据） | 无差异 |
| 8 B load（fld）两拍组装、非对齐 ⇒ cause 4 | `lsq_simple.v:1036-1044, 1262` | 无差异 |
| `ext_load` 符号/零扩展窗口口径 | `lsq_simple.v:956-969` | 无差异 |
| PMP 逐项匹配/整笔覆盖/编号优先/无匹配语义 | `rtl/mem/pmp_check.v:326-343, 400-418, 458-462` | 无差异 |
| PMP NAPOT 掩码恒等式 `a^(a+1)` 与编码表 | `pmp_check.v:189-194` | 无差异 |
| PMP TOR 上界不含 / 空前驱区间 | `pmp_check.v:323, 331-332` | 无差异 |
| PMP L=0 且 M 模式放行 / L=1 或 S/U 按 R/W/X | `pmp_check.v:345-352` | 无差异 |
| PMP cause：取指 1 / load 5 / store·AMO 7 | `pmp_check.v:224-235` | 无差异 |
| PTW：V=0、R=0&W=1 保留、错位超级页 PPN[0]≠0 | `rtl/csr/ptw.v:280-298, 352` | 无差异 |
| PTW：U/SUM/MXR 权限矩阵（含 S 取指不受 SUM 放开） | `ptw.v:301-334`；`tlb.v:208-237` | 无差异 |
| PTW：A/D **Svade**（A=0 / 写且 D=0 ⇒ page-fault） | `ptw.v:342-355` | 无差异（Svade 合规，未宣称 Svadu） |
| PTW：PTE 隐式访存前置过 PMP ⇒ 原访问类型 access-fault | `ptw.v:11-17, 371-377` | 无差异 |
| Sv32 PA 重建仅取 PPN[19:0]（32 bit PA） | `tlb.v:250-255` | 无差异 |
| `sfence.vma` TLB 失效（保守全刷）+ U 模式非法（2A） | `tlb.v:303-348, 376-414`；`core_top.v:1426` | 无差异（2A） |
| fence.i 全阵列失效 + 前端冻结窗口 | `core_top_2b.v:283-291, 521, 660-668` | 无差异 |
| Zicbom CBIE/CBCFE 门控与 cmo.adoc Sail 逐支一致 | `dec_csr.v:213-239`（INVAL 只看 CBIE、CLEAN/FLUSH 只看 CBCFE）；ISA `cmo.adoc:540-661` | **无差异**（曾疑，逐支核对后排除；U 模式的 `AND` 合成对 {00,01,11} 与 pseudocode 等价） |
| CSR 写只读 ⇒ 非法；`csrrs/csrrc rs1=x0` 不写 | `decoder.v:388-393`；`dec_csr.v:193-194` | 无差异 |
| cause 码表 0..15 与 U/S/M ecall | `rtl/pkg/rv32_defs.vh:467-489` | 无差异 |
| `mepc[0]=0`（IALIGN=16） | `csr_file.v:585, 809, 898`；`trap_ctrl.v:254` | 无差异 |
| 陷阱入口 `mstatus` 位序（MPIE←MIE、MIE←0、MPP←y 替换）与 xRET | `priv_ctrl.v:160-232`；`csr_file.v:673-690`（读视图取前值） | 无差异 |
| 中断 cause bit31 编码 + 优先级 + 委托门控 + `priv<M` 时 M 级中断恒开 | `trap_ctrl.v:104-109, 200-213` | 无差异（S 级 U 模式 SIE 见 D2） |
| Vectored 中断 pc = BASE+4×cause、同步异常恒 BASE | `trap_ctrl.v:266-277` | 无差异（WARL 基址见 D6） |
| 2B MDU/FPU `start/req_valid` 取 E1 有效、年龄限定冲刷 | `backend_top.v:1604-1624` | 无差异（有历史实测修复） |
| FPU 顶层快速检查（`fpu.s`/非法显号类问题） | `sim/unit/tb_fpu.sv` 运行：`checks=3441 errors=0 known_dev=0 PASS`（`KNOWN_DEV_ENABLE=0`，原 `fpu_add` 零符号偏差已修） | 无差异（本次不展开 F/D 语义） |

---

## ⑤ 复现命令（grep 链全列）

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu

# 0. 基准
git rev-parse HEAD                       # 201d88d...（RTL 与 d00eb03 逐字节同）
git diff --stat d00eb03..HEAD            # 仅 fpga/area-optimization-report.md

# 1. ISA 引文（kb CLI；同一 store/ranking 即 kb_search/kb_get）
cd /home/shorthair/dsh/rv32-cpu
node dsh-extension/bin/riscv-kb.js search "misaligned load store either handle or raise address-misaligned exception"
node dsh-extension/bin/riscv-kb.js search "trap to S-mode less privilege"          # 见 chunk 10756
node dsh-extension/bin/riscv-kb.js search "PMP entry locked L bit writes to pmpcfg pmpaddr are ignored"
node dsh-extension/bin/riscv-kb.js search "mcounteren cycle time instret illegal-instruction exception"
node dsh-extension/bin/riscv-kb.js search "CBO.INVAL instruction executes or raises" # cmo.adoc:540-661

# 2. RTL 证据行
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
grep -n "st_mis_w\|lmask_w\|stq_d\s*<=\|stq_msk\s*<="        rtl/back2/lsq_simple.v
grep -n "irq_visible\|is_s_irq"                              rtl/csr/trap_ctrl.v
grep -n "pmp_tor_locked\|pmp_cfg_landing\|CSR_PMPADDR"       rtl/csr/csr_file.v
grep -n "is_csr_ucntr\|is_csr_implemented\|csr_ill_o"        rtl/decode/dec_csr.v
grep -n "mcounteren\|scounteren"                             rtl/top/core_top_2b.v rtl/csr/csr_file.v
grep -n "TVM\|tvm"                                           rtl/top/core_top.v rtl/csr/priv_ctrl.v
grep -n "norm\|mtvec"                                        rtl/csr/csr_file.v | sed -n '1,20p'
grep -n "vec_base\|is_vectored"                              rtl/csr/trap_ctrl.v
grep -n "unsup\|OPT_AMO\|opt == 4'd5\|is_sys_ok"             rtl/back2/backend_top.v
grep -n "MISA_EXT_BITS\|ISA_STRING"                           rtl/csr/csr_file.v rtl/pkg/core_params.vh
grep -n "ALU_\|BR_NONE"                                       rtl/pkg/rv32_defs.vh rtl/exec/alu.v

# 3. 既有单元 TB（排除清单证据）
for tb in alu bru mdu; do
  iverilog -g2012 -I . -o /tmp/a2_$tb.vvp rtl/exec/$tb.v sim/unit/tb_$tb.sv && vvp /tmp/a2_$tb.vvp | tail -2
done
# 期望：TB_ALU_UNIT: PASS / TB_BRU_UNIT: PASS / TB_MDU_UNIT: PASS

# 4. D1 实证夹具（本报告唯一新增文件，仅写 fpga/scratch/audit2_*）
iverilog -g2012 -I . -o /tmp/audit2_lsq_mis.vvp \
    rtl/back2/lsq_simple.v fpga/scratch/audit2_lsq_mis_tb.sv
vvp /tmp/audit2_lsq_mis.vvp | grep -E "store-req|misaligned|FAIL|AUDIT2_LSQ_MIS"
# 期望：B2/C2 两条 FAIL（非对齐 store 跨字字节未落地）

# 5. 门禁
bash fpga/scratch/audit2_gate.sh
```

---

## 附：本次新增文件（均位于 `fpga/scratch/audit2_*`，不改任何产品 RTL/TB/脚本）

- `fpga/scratch/audit2_lsq_mis_tb.sv` —— 非对齐 store 直驱夹具（D1 实证）
- `fpga/scratch/audit2_report.md` —— 本报告
- `fpga/scratch/audit2_gate.sh` —— 锚点/覆盖率/证据门禁

**AUDIT2: PASS**
