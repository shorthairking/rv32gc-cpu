# ISA 强制项与注意项（RV32IMAFDC + Zicsr/Zifencei/Zicntr/Zicbom，M/S/U + Sv32 + PMP16）

> **本文性质**：RV32-GC 实现与验证时**必须遵守**的 ISA 语义条目，每条附知识库 `path:line` 引用，可独立复核。
> **引用来源**：常驻 riscv-kb（`riscv-isa-manual`、`riscv-arch-test`），通过 `kb_search` + `kb_get` 取得；行号为 kb 返回的源文件行号。
> **强度约定**：本文只写**有引用**的条目；无引用的实现建议一律标注 **[工程约定]**，与 ISA 强制项区分。

---

## 1. Zicbom（Cache Block Management Operations）

### 1.1 扩展强制项

- **Zicbom 为 menvcfg 增加 CBCFE 字段**（Cache Block Clean and Flush instruction Enable）。置 1 时允许在**低于 M 的模式**执行 `CBO.CLEAN` 与 `CBO.FLUSH`；否则这些指令在低于 M 的模式下**抛非法指令异常**。
  → `riscv-isa-manual/src/priv/machine.adoc`，Machine Environment Configuration (menvcfg) Register（kb chunk 10571，lines 2132-2325）
- **Zicbom 为 menvcfg 增加 CBIE 字段**（Cache Block Invalidate instruction Enable），为 WARL，控制 `CBO.INVAL` 在低于 M 模式下的执行。CBIE = `00b` 时，该指令在低于 M 的模式下抛非法指令异常。
  → `riscv-arch-test/coverpoints/norm/Sm.yaml`（kb chunk 9081，lines 835-838）
- **senvcfg 侧同理**：CBCFE 控制 U 模式下 `CBO.CLEAN`/`CBO.FLUSH` 的执行，且**只有在 S 模式已允许执行时才可能对 U 模式放开**。
  → `riscv-arch-test/coverpoints/norm/ExceptionsZicboS.yaml`（kb chunk 8341，lines 13-16）
- **门控依赖链**：`senvcfg_cbcfe` 覆盖点说明 U 模式的放开依赖 S 模式先放开。
  → `riscv-arch-test/coverpoints/norm/ExceptionsZicboS.yaml`（kb chunk 8342，lines 17-22）
- **未实现 Zicbom 时，CBCFE 为只读 0**；同理 CBZE（Zicboz 的 zero 使能）未实现时也是只读 0。
  → `riscv-isa-manual/src/priv/machine.adoc`（kb chunk 10571）；`riscv-arch-test/coverpoints/norm/ExceptionsZicboS.yaml`（kb chunk 8342）

### 1.2 Cache block size 必须由软件发现，不得硬编码

- CMO 扩展要求软件可发现三项信息：
  1. **管理/prefetch 指令的 cache block 大小**；
  2. **zero 指令的 cache block 大小**；
  3. **各级特权级的 cbie 支持情况**。
  → `riscv-isa-manual/src/unpriv/cmo.adoc`，Cache Management Operations (CMOs) › Coherent Agents and Caches › Software Discovery（kb chunk 10976，lines 527-539）
- **实现含义**：核不得假定 block size = 64 B；必须提供发现机制（本项目为自研核，按 [工程约定] 可用只读 CSR 字段或平台约定常量，但**软件侧必须走发现路径**）。

### 1.3 CBO 指令地址**不必对齐**

- **Zicbom 的 CMO 指令 `rs1` 不要求块对齐**：`cbo.flush` 的 `rs1` 只要求是有效地址，**不要求**按 cache block 对齐。→ `riscv-isa-manual/src/unpriv/cmo.adoc:882-884` `norm:cbo-flush_unaligned`（"`rs1` is not required to be aligned to the cache block size"）。
- `cbo.inval` 同口径：→ `riscv-isa-manual/src/unpriv/cmo.adoc:915-917` `norm:cbo-inval_unaligned`。
- `cbo.zero` 同口径：→ `riscv-isa-manual/src/unpriv/cmo.adoc:960-961`（摘录同上：`rs1` 不要求块对齐）。
- **CMO 不产生 address-misaligned 异常**：→ `riscv-isa-manual/src/unpriv/cmo.adoc:409-410` `norm:no_addr_misaligned_excep`（CMO 指令不抛地址非对齐异常）。
- **`cbo.clean` 无独立条文**，共用 `cbo.flush` 口径（规范未为 `clean` 单列一条，按 flush 同族语义处理，**注明为共用口径**）。
- **实现含义**：实现必须接受任意 `rs1`，按 block 边界向下对齐操作，且**不得**因未对齐抛异常。

### 1.4 Zicbom 相关测试

- arch-test 中 Zicbom 用例位于 `riscv-arch-test/tests/rv32i/Zicbom/`，共 **3 个**：[环境实测]
  - `Zicbom-cbo.clean-00.S`
  - `Zicbom-cbo.flush-00.S`
  - `Zicbom-cbo.inval-00.S`
- **三个文件的 `MARCH` 均为 `rv32i_zicbom_zicsr_zifencei`**。[环境实测] 例如 `riscv-arch-test/tests/rv32i/Zicbom/Zicbom-cbo.clean-00.S:15`
  → 编译这些用例时 MARCH 必须写全（含 `_zicsr_zifencei`），否则 CSRRW/FENCE.I 侧会缺扩展。
- 用例内含按 word/offset 展开的覆盖点字符串（如 `"test: 128; cg: Zicbom_cbo.clean_cg; cp: cp_custom_cbo; bin: word 31 offset 255"`）。[环境实测] `riscv-arch-test/tests/rv32i/Zicbom/Zicbom-cbo.clean-00.S:1551`

---

## 2. Sv32 两级页表

### 2.1 翻译算法（逐步强制语义）

引自 `riscv-isa-manual/src/priv/supervisor.adoc`，Sv32 › Virtual Address Translation Process（kb chunk 10790，lines 1723-1854）：

1. 令 `a = satp.ppn × PAGESIZE`，`i = LEVELS-1`。**Sv32 的 `PAGESIZE = 2^12`、`LEVELS = 2`**。satp 必须处于活动状态（有效特权级为 S 或 U）。
2. 取 `pte = Mem[a + va.vpn[i] × PTESIZE]`。**Sv32 的 `PTESIZE = 4`**。**若访问该 PTE 违反 PMA 或 PMP 检查，抛对应访问类型的 access-fault 异常**（见 §3.3）。
3. 若 `pte.v=0`，或 `pte.r=0 && pte.w=1`，或 PTE 中置了保留位/保留编码，则停止并抛页错误。
4. PTE 有效：若 `pte.r=1 || pte.x=1` 则转到步骤 5；否则该 PTE 是**指向下一级页表的指针**，`i = i-1`；若 `i<0` 则抛页错误；否则 `a = pte.ppn × PAGESIZE` 回到步骤 2。
5. 到达叶子 PTE：**若 `i>0` 且 `pte.ppn[i-1:0] ≠ 0`，为 misaligned superpage，抛页错误**。
6. 按 `pte.u` 与当前特权级、`mstatus.SUM`/`MXR` 判定是否允许；不允许则抛页错误。
7. 按 `pte.r/w/x` 结合 Shadow Stack 规则判定；不允许则抛 access-fault。
8. 再按 `pte.r/w/x` 判定；不允许则抛页错误。
9. 若 `pte.a=0`，或原访问是 store 且 `pte.d=0`，按规范更新 A/D。

- **实现要点**：Sv32 只有**两级**，超级页只有 4 MiB 一档（`i=1` 时检查 `ppn[0]`）；`satp.MODE = 1` 时活动。

### 2.2 TLB 与 SFENCE.VMA

- 规范明确讨论 **`SFENCE.VMA` 与隐含读的竞态**：hart 可能已有投机/推测执行开始地址翻译、读到第 2 级页表、暂停，等 hart 执行 `rs1=rs2=x0` 的 `SFENCE.VMA` 后**用已过期的第 2 级 PTE 继续**，从而把**过期 PTE 灌进地址翻译缓存**。
  → `riscv-isa-manual/src/priv/supervisor.adoc`（kb chunk 10793，lines 1723-1854）
- **实现含义**：TLB 失效逻辑必须处理该顺序；`rs1=x0` 的全局 `SFENCE.VMA` 需能终结上述竞态。

### 2.3 PTE 的物理地址编码

- PTE 中物理地址的编码**与 PMP 地址寄存器、以及页表项中的物理地址编码一致**。
  → `riscv-isa-manual/src/priv/hypervisor.adoc`，htval Register（kb chunk 10448，lines 903-966）
- **实现含义**：本项目 PMP 地址编码与 PTE PPN 字段必须用**同一套物理地址口径**；`mtval`/`stval` 写入的出错地址也需与该编码一致。

---

## 3. PMP（16 项）

### 3.1 条目数量与实现顺序

- **最多 64 项；实现可以是 0、16 或 64 项。低编号项必须先实现。** 本项目取 **16 项**。
  → `riscv-isa-manual/src/priv/machine.adoc`，Physical Memory Protection CSRs（kb chunk 10609，lines 3342-3426）；同一强制项的覆盖点见 `riscv-arch-test/coverpoints/norm/PMPSm.yaml`（kb chunk 8647，lines 155-160）
- **所有 PMP CSR 字段都是 WARL，且可为只读 0**；**PMP CSR 仅 M 模式可访问**。
  → 同上（kb chunk 10609）
- RV32 下 `pmpcfg0–pmpcfg15` **每 4 项打包进一个 CSR**：`pmpcfg0 = cfg3..cfg0`，`pmpcfg1 = cfg7..cfg4`，依此类推；`pmpcfg2` 对应 `pmp8–pmp11`。
  → 同上（kb chunk 10609，lines 3342-3426）

### 3.2 优先级与匹配逻辑（三条强制项）

引自 `riscv-isa-manual/src/priv/machine.adoc`，Physical Memory Protection CSRs › Priority and Matching Logic（kb chunk 10614，lines 3564-3610）：

- **[norm:pmpentrypriority] 静态优先级**：**PMP 项静态地按优先级排序；编号最低的、能匹配该访存操作任意字节的 PMP 项，决定该操作成功或失败。**
- **[norm:pmpfullmatch_required] 整笔匹配**：**匹配的 PMP 项必须匹配该访存操作的全部字节，否则操作失败，与 L/R/W/X 位无关。**
  - 例：若某项匹配 `0xC–0xF` 四字节范围，则对该范围做 8 字节访问 `0x8–0xF` **失败**（假定该项是匹配这些地址的最高优先级项）。
- **[norm:pmprwxcheck] L/R/W/X 判定**：
  - 若 `L=0` 且访问特权级为 **M**，操作成功；
  - 否则（`L=1`，或访问特权级为 **S/U**），**仅当**与访问类型对应的 R/W/X 位为 1 时操作成功。
- **[norm:pmpnoentry_match] 无匹配项时**：
  - M 模式访存 → **成功**；
  - S/U 模式访存 → **若至少实现了一项 PMP 则失败**，否则成功。
- **NOTE**：若实现了至少一项 PMP 但所有项的 A 字段都是 OFF，则**所有 S/U 模式访存都会失败**。

### 3.3 每笔独立检查 & PTE 取指也过 PMP

- **[norm:pmpmisalignedaccess_behavior] 每笔独立**：某些实现会把非对齐 load/store/取指拆成多笔；**PMP 检查对每一笔访存独立进行**。因此非对齐 store 的一部分可能已通过 PMP 检查并**可见**，而另一部分失败。对宽于 XLEN 的 store 同理。
  → `riscv-isa-manual/src/priv/machine.adoc`（kb chunk 10614，lines 3564-3610）
- **PTE 取指走 PMP**：Sv32 翻译算法步骤 2 明确规定，**若访问 PTE 违反 PMA/PMP，抛 access-fault 异常**（不是页错误）。
  → `riscv-isa-manual/src/priv/supervisor.adoc`（kb chunk 10790，lines 1723-1854）
- **实现含义**：页表遍历的**每一次隐式访存**都必须过 PMP；且该项的异常 cause 是**访问类型对应的 access-fault**，与页错误区分。

### 3.4 A 字段编码提醒（**地址口径已按 ISA 修正**，2026-09-14）

- **`pmpaddr` 的地址口径（ISA 口径，勿再按字节地址理解）**：RV32 下每个 `pmpaddr` 编码
  **34 位物理地址的 [33:2]**，即 **`pmpaddr = PA >> 2`**（G=0 ⇒ 32 位全部有效、不做低位掩码）。
  → `riscv-isa-manual/src/priv/machine.adoc:3379-3383` `[norm:pmp_addr_encoding]`
  （摘录：“Each PMP address register encodes bits 33-2 of a 34-bit physical address for RV32,
  as shown in Figure…”，NOTE 见 :3387-3396：Sv32 支持 34 位物理地址，故 PMP 必须支持宽于 XLEN 的地址）
  - **实现含义**：匹配比较在**字地址空间**进行 —— 访存物理地址要换到同尺度（`PA>>2`）后与
    `pmpaddr` 比较；TOR 的边界、NA4 的单元、NAPOT 的块基址/掩码全部是同尺度量。
- **NAPOT 尺寸编码**：块大小 = **2^(n+3) 字节**，`n` = `pmpaddr` 低位**连续 1** 的个数
  （`n=0` ⇒ 8 B，低位模式 `…yyy0`；全 1 ⇒ 最大块）。低位是**尺寸编码**，不是基址位。
  → machine.adoc:3458-3493 `[norm:pmp_napot_encoding_low_bits]` + NAPOT 编码表；
  G≥1 时低位“读作全 1 / 全 0”的掩码见 machine.adoc:3519-3528（本设计 **G=0**，不适用）。
- **L 位与 M 模式**：**L=0 时任何匹配该项的 M 模式访问一律成功**（R/W/X 只约束 S/U）；
  **L=1** 时 R/W/X 才**对所有特权级（含 M）**生效。
  → machine.adoc:3557-3563 `[norm:pmp_l_bit_m_mode_enforcement]`；
  R/W/X 判定总则见 machine.adoc:3584-3590 `[norm:pmp_rwx_check]`。
- `pmpaddr` 的 TOR 匹配语义：项 *i* 匹配任何地址 *y* 满足 `pmpaddr[i-1] <= y < pmpaddr[i]`
  （上界**不含**；项 0 的下界为 0）；`pmpaddr[i-1] >= pmpaddr[i]` ⇒ 该项**无任何匹配地址**。
  → machine.adoc:3496-3504 `[norm:pmp_a_field_tor]` + NOTE
- `A=TOR` 相关的覆盖点集合：`PMPSmcg/{cpcfgAtorall, cpcfgAtor, cpcfgAtor0, cpcfgAtorbot, cpcfgAtor_nonoverlap}`。
  → `riscv-arch-test/coverpoints/norm/PMPSm.yaml`（kb chunk 8639，lines 95-102）

---

## 4. 陷阱与中断口径

> 本节全部条目已补规范出处（`riscv-isa-manual/src/...adoc:行号` + tag 名），并逐条区分**规范强制**、**实现可选/规范未明说**与**本设计选择**三档强度。

| # | 口径 | 规范强度与出处 |
|---|---|---|
| T1 | **`mtval` 写 faulting instruction bits** | **可选**（`can optionally`）。`riscv-isa-manual/src/priv/machine.adoc:2039-2050` `norm:mtval_instr_bits_lead-in`；:2052-2053 `norm:mtval_ill_instr_exc_in_low_bits`（写指令位时须右对齐、高位清零）；:2071-2074 零值语义（**0 = 该特性未实现，或取到的指令全零**）；:2094 `norm:mtval_instr_bits_sz`（**若实现**，须至少容纳 `min(ILEN, MXLEN)` 位）。⇒ 未实现该特性时 `mtval` 合法读 0，**不得写成"必须写原始指令位"** |
| T2 | **取指 PMP 检查粒度** | **规范强制**部分：取指无执行权限 ⇒ **instruction access-fault**（`machine.adoc:3418-3419` `norm:pmp_exec_fault`）；**PMP 检查对每一笔访存独立进行**（:3564-3569 `norm:pmpmisalignedaccess_behavior`）；PMP 粒度由平台定义（:3315 `norm:pmp_granularity`）。**"按 2 B parcel 检查"规范未明说** —— 如保留须注明是**本设计选择** |
| T3 | **非对齐 vs page/access fault 优先级** | **实现可选**（`either higher or lower`）。`machine.adoc:1937-1938` `norm:mcause_exccodepri2`。⇒ 非对齐优先或 page/access fault 优先**都可实现**，本设计选非对齐优先 |
| T4 | **AMO/SC/`cbo.zero` 被 PMP 拒（无 W 权限）** | **恒 store access-fault（cause 7）**。`machine.adoc:3422-3425` `norm:pmp_store_fault`（对照 :3419-3422 `norm:pmp_load_fault` 为 cause 5） |
| T5 | **陷阱不从高特权级委托到低特权级** | **规范强制**。`machine.adoc:1281-1288` `norm:trap_never_trans_lower`；`medeleg` 为 **64-bit** 寄存器（:1234），XLEN=32 时高 32 位经 `medelegh` **别名**访问（:1305-1309） |
| T6 | **中断取点（在"副作用已落地"的指令之后取）** | **规范未明说**"指令边界/副作用之后"这一时机。最接近条文：中断条件须在**有界时间内**评估（`machine.adoc:1346-1358` `norm:intr_mip_mie_bounded_time`）、且在 `xRET`/相关 CSR 写后**立即**评估（`norm:intr_mip_mie_xret_csrwr`）；WFI 侧 `machine.adoc:2697-2698`（中断在下一指令处取，`mepc = pc + 4`）。⇒ **"副作用已落地之后取"为本设计纪律**，须标注"规范未明说" |
| T7 | **`MPRV=1` 时的访存翻译与保护** | **按 `MPP` 语义**：`MPRV=1` 时按 `MPP` 做地址翻译与保护（`MPP=M` 时等效当前 M 权限）——`machine.adoc:588-597` `norm:mstatus_mprv_ldst_op`；**`mret`/`sret` 转到低于 M 的模式时清零 `MPRV`**——:599-600 `norm:mstatus_mprv_clr_mret_sret_less_priv`、:413。`SUM` 在 `mprv=1` 且 `mpp=S` 时生效（:627-628）。**注意**：规范**未写**"MPRV only takes effect if MPP≠M"字样，按"**按 MPP 语义**"表述更精确 |
| T8 | **Zicbom 的 `cbo.*` `rs1` 不要求块对齐** | **CMO 指令不产生 address-misaligned 异常**。`cmo.adoc:882-884` `norm:cbo-flush_unaligned`（`cbo.flush`）、:915-917 `norm:cbo-inval_unaligned`（`cbo.inval`）、:960-961（`cbo.zero`）；:409-410 `norm:no_addr_misaligned_excep`。`cbo.clean` **无独立条文**，共用 flush 口径（注明） |
| T9 | **CSR/MPRV/SUM/MXR 需同拍旁路** | **[工程约定]**（实现风格，非 ISA 条目） |

- **处置纪律**：上表 T1–T8 为已核实结论，**引用行号与 tag 名不得再自行改动或另查**；新增条目按 §7 追加到本节表格，不新建平行文档。

---

## 5. arch-test 覆盖要求

### 5.1 rv32i 侧

| 测试组 | 路径 | 状态 |
|---|---|---|
| Zicbom | `riscv-arch-test/tests/rv32i/Zicbom/`（3 个 `.S`） | [环境实测] 存在；MARCH 见 §1.4 |

- 覆盖点规范：`riscv-arch-test/coverpoints/norm/Sm.yaml`（menvcfg），`riscv-arch-test/coverpoints/norm/ExceptionsZicboS.yaml`（senvcfg 与 Zicbo 异常），`riscv-arch-test/coverpoints/norm/PMPSm.yaml`（PMP）。
- **测试配置节**：用例内 `##### STARTTESTCONFIG #####` / `##### ENDTESTCONFIG #####` 用于声明参数约束（如 PMP 需求）；MARCH 不含 S/Sm 扩展，因为**编译器不需要**这些扩展。
  → `riscv-arch-test/docs/DeveloperGuide.md`（kb chunk 10207，lines 223-231）

### 5.2 priv 侧

- `riscv-arch-test/tests/priv/SvPMP/` 共 **16 个** 用例。[环境实测] 目录列表：`sv32_pmp_on_pa_Smode.S`、`sv32_pmp_on_pa_Umode.S`、`sv32_pmp_on_pte_Smode.S`、`sv32_pmp_on_pte_Umode.S`，以及 Sv39/Sv48/Sv57 的对应 12 个。
- **Sv32 相关 4 个**正是 §2.1 步骤 2 与 §3.3 的联合验证：`pmp_on_pa`（对物理地址的 PMP 检查）与 `pmp_on_pte`（**对页表项访存的 PMP 检查**）。
- **实现含义**：`sv32_pmp_on_pte_*` 必须能通过 —— 即页表遍历的隐式访存要真的过 PMP，且异常类型合规（§3.3）。

---

## 6. CSR 与特权级基线（作为实现清单）

- **Zicsr**：CSRRW/CSRRS/CSRRC 及其立即数形式；写只读 CSR 抛非法指令。
- **Zifencei**：`FENCE.I`（arch-test 的 Zicbom MARCH 强制带 `_zifencei`，见 §1.4）。
- **Zicntr**：`cycle`/`time`/`instret` 及其高半部。
- **Sv32**：`satp`（MODE=1 表示 Sv32）、`stvec`/`sepc`/`scause`/`stval`/`sstatus`/`sip`/`sie`。
- **PMP 16 项**：`pmpcfg0–pmpcfg3`（RV32 下 16 项占 4 个 CSR）、`pmpaddr0–pmpaddr15`。
- **M 模式**：`mstatus`/`misa`/`mie`/`mtvec`/`mscratch`/`mepc`/`mcause`/`mtval`/`mip`/`menvcfg`（含 CBIE/CBCFE，见 §1.1）。

---

## 7. 本文维护纪律

1. 每条 ISA 语义**必须带 `path:line`** 才算成立；无法引用的降级为 [工程约定] 或 [旧项目转述]。
2. §4 的 T1–T8 引用缺口**已补齐**（每条带 `path:行号` + tag 名）；后续新增口径同样必须先补出处再上升为条目。
3. 新增条目追加到对应小节；**不新建平行文档**。
4. 引用 kb 时用 `kb_search` 复核，**不要**直接 `read` 规范大文件。
