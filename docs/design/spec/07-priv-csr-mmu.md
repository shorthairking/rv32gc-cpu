# SPEC-07 特权级、CSR、异常/中断与 MMU 微架构规格

> 上游：`00-conventions.md`（编码/复位/握手）、`02-uop-and-decode.md`（uop 控制位）、`03-pipeline-regs.md`（§2.6 MMU 接口、§2.7 CSR 接口）、`../04-csr-mmu.md`。
> 规范依据：RISC-V Privileged Architecture v1.13；所有 ISA 结论来自常驻知识库检索，出处标为 `riscv-isa-manual/src/priv/<file>.adoc:行号`（相对工作区根 `/home/shorthair/dsh/rv32-cpu`）。
> 落地模块：`rtl/csr/csr_file.v`、`csr/trap_ctrl.v`、`csr/counter.v`、`csr/clint.v`、`csr/plic.v`、`mmu/tlb.v`、`mmu/ptw.v`、`mmu/pmp.v`。

## 1. 常量、复位与接口

**1.1 参数（`rtl/pkg/rv32gc_defs.vh`）**：`XLEN=32`（`misa.MXL=1`，`machine.adoc:37-46`）；`PADDR_W=32`（Sv32 规范允许 34，本设计 32 位，`pmpaddr` 高位镜像 0，`supervisor.adoc:1466-1470`）；`PMP_ENTRIES=16`（允许 0/16/64，低位先实现，`machine.adoc:3346-3349`）；`PMP_G=0`（4 B 颗粒，NA4 可用，`machine.adoc:3489-3497`）；`ITLB/DTLB/L2TLB=32/64/256`（`03-pipeline-regs.md:170`）；`L2TLB` 4 路；`ASID_MAX=9`（`supervisor.adoc:1055-1064`）；`PTESIZE=4`（`supervisor.adoc:1725-1730`）；`IALIGN=16`（`xepc[1:0]` 可写、`[0]` 恒 0，`machine.adoc:1690-1696`）；`N_CTX=2`（hart0-M=ctx0 / hart0-S=ctx1）。
**1.2 复位值**（`00-conventions.md:29-30`）：`priv_mode=2'b11`(M)、`mstatus=32'h0000_1800`（MPP=11、MIE=0）、`misa=32'h4014_1105`、`mstatush=0`、`medeleg=mideleg=mie=mip=0`、`mtvec=stvec=0`、`mcountinhibit=32'd8`（IR=1 抑制 `minstret`）、`satp=0`(Bare)、`pmpcfg0-3=pmpaddr0-15=0`、`mtime=0`、`mtimecmp=64'hFFFF_FFFF_FFFF_FFFF`、PLIC 优先级/使能/阈值=0、TLB valid=0。
**1.3 `csr_file` 端口**（遵守 `03-pipeline-regs.md` §2.7；命名/复位遵守 `00-conventions.md:14-18`）：输入 `clk, rst_n`；组合读 `csr_raddr[11:0] → csr_rdata[31:0]`；提交级写 `csr_waddr[11:0], csr_wdata[31:0], csr_wmask[31:0], csr_wen, csr_op[1:0]`（0=NONE 1=RW 2=RS 3=RC，**仅 RT 级生效**）；陷阱入口 `trap_valid, trap_cause[3:0], trap_is_intr, trap_tval[31:0], trap_priv[1:0], trap_epc[31:0] → trap_vector[31:0], trap_deleg, trap_target_priv[1:0]`；中断与外部源 `intr_pending[5:0], mtime[63:0], msip_i, meip_i, seip_i → intr_taken[5:0]`；合法性 `→ csr_illegal, csr_illegal_tval_en`；状态 `→ priv_mode[1:0], eff_priv[1:0]`（含 MPRV 修正）、`sum_eff, mxr_eff, mprv_eff, satp_ppn[21:0], satp_asid[8:0], satp_bare`。
**1.4 `mmu` 端口**：完全采用 `03-pipeline-regs.md` §2.6 的信号定义（`mmu_req_va/asid/priv/type/is_fp`、`mmu_resp_pa/fault/cause/tval`、`mmu_busy`、`sfence_valid/va/asid/all`），本文件不再重复。

## 2. 机器级 CSR 逐寄存器字段表

### 2.1 `mstatus` @0x300（RV32 全字段；布局 `machine.adoc:330-352`、`images/wavedrom/mstatusreg-rv321.edn`）

| 位段 | 字段 | 属性 | WARL / 语义 | 复位 | 备注 |
|---|---|---|---|---|---|
| `31` | `SD` | RO | `FS==3 \|\| XS==3`→1（`machine.adoc:883-887`） | 0 | 只读汇总 |
| `30:23` | WPRI | RO 0 | 保留，写忽略 | 0 | — |
| `22` | `TSR` | RW WARL | S 存在即可写（`machine.adoc:779-786`） | 0 | `TSR=1` 时 S 模式 `sret` 非法 |
| `21` | `TW` | RW WARL | 同上（`machine.adoc:753-769`） | 0 | `TW=1` 时低特权 `wfi` 可非法；U 模式 `wfi` 恒非法（`machine.adoc:771-774`） |
| `20` | `TVM` | RW WARL | 同上（`machine.adoc:732-742`） | 0 | `TVM=1` 时 S 模式读/写 `satp`、`sfence.vma` 非法 |
| `19` | `MXR` | RW | load 可读 `X=1` 页（`machine.adoc:2810-2818`） | 0 | 只影响 PTE 权限解释，不影响 PMA/PMP |
| `18` | `SUM` | RW | `SUM=0` 时 S 访问 `U=1` 页出错；`MPRV=1&&MPP=S` 时仍生效（`machine.adoc:2813-2820`） | 0 | — |
| `17` | `MPRV` | RW | 1 时 load/store 用 `MPP` 做翻译与权限检查（`machine.adoc:586-635`） | 0 | 不影响取指 |
| `16:15` | `XS` | RO 0 | 无额外用户态扩展（`machine.adoc:869-874`） | 0 | 写忽略 |
| `14:13` | `FS` | RW | Off/Initial/Clean/Dirty（`machine.adoc:831-843`）；`FS=0` 执行 FP→非法指令（`machine.adoc:889-892`） | 0 | FP 写寄存器→Dirty |
| `12:11` | `MPP` | RW WARL | 只存 M 及更低已实现模式；实现 00/01/11，写 `10`→`11`（`machine.adoc:3371-3385`） | `2'b11` | 陷阱入口写源模式 |
| `10:9` | `VS` | RO 0 | 无 V 扩展（`machine.adoc:861-868`） | 0 | — |
| `8` | `SPP` | RW 1 bit | 陷阱入口写源特权级（U→0，S→1）；`sret` 后清 0（`machine.adoc:352-445`、`supervisor.adoc:103-111`） | 0 | — |
| `7` | `MPIE` | RW | 陷阱入口←`MIE`；`mret` 后置 1 | 0 | — |
| `6` | `UBE` | RO 0 | 不支持大端 | 0 | — |
| `5` | `SPIE` | RW | 陷阱入口←`SIE`；`sret` 后置 1（`supervisor.adoc:119-126`） | 0 | — |
| `4`,`2`,`0` | WPRI | RO 0 | — | 0 | — |
| `3` | `MIE` | RW | M 全局中断使能（`machine.adoc:353-370`） | 0 | — |
| `1` | `SIE` | RW | S 全局中断使能（`supervisor.adoc:112-118`） | 0 | — |

**`sstatus` @0x100 视图**：仅 `SD/SPP/SPIE/SIE/SUM/MXR/FS/XS`；`MIE/MPIE/MPP/MPRV/TVM/TW/TSR` 读 0 写忽略；`UXL/SXL` 只在 RV64 存在（`machine.adoc:337-341`、`supervisor.adoc:134-160`）。

### 2.2 `mstatush` @0x310 / `misa` @0x301 / ID 类 CSR

| CSR | 位段 | 字段 | 属性 | 语义 / 复位 |
|---|---|---|---|---|
| `mstatush` | `4`/`5` | `SBE`/`MBE` | RO 0 | 不支持大端，写忽略（`machine.adoc:344-351,636-729`）；其余位 WPRI |
| `misa` | `31:30` | `MXL` | RO | `2'b01`=32（`machine.adoc:29-46`）；复位值 `32'h4014_1105` |
| `misa` | `25:0` | `Extensions` | WARL | 复位 `A(0) C(2) D(3) F(5) I(8) M(12) S(18) U(20)`；**仅 bit2(C) 可写**，写 0 后 `c.*` 一律非法；其余位写忽略（`machine.adoc:50-63,88-90`）；`E(4)=0`（`machine.adoc:48-49,175-179`） |
| `mvendorid`/`marchid`/`mimpid`/`mhartid`/`mconfigptr` @0xF11-0xF15 | `31:0` | — | RO | `0`/自定义/`32'h0001_0000`/`0`/`0`（`machine.adoc:216-329,2098-2131`） |

### 2.3 陷阱委托与中断 CSR：`medeleg` @0x302、`mideleg` @0x303、`mie` @0x304、`mip` @0x344

| 寄存器 | 位 | 属性 | 语义 |
|---|---|---|---|
| `medeleg` | `0,1,2,3,4,5,6,7,8,9,12,13,15` | RW | 不允许任何位只读 1（`machine.adoc:1305-1312`）；bit11（M `ecall`）永不可委托 |
| `mideleg` | `1(SSI),5(STI),9(SEI)` | RW | M 级位（3/7/11）不得只读 1，本设计写 0 忽略 |
| `mie` | `1/3/5/7/9/11` = `SSIE/MSIE/STIE/MTIE/SEIE/MEIE` | RW | 未实现位只读 0（`machine.adoc:1372-1375`） |
| `mip` | `1`/`5` `SSIP`/`STIP` | RW | 软件写或 PLIC/CLINT 置位；`mip[9]=seip_sw\|plic_s_out`（SEIP 为**软件位与控制器 OR**，`machine.adoc:1433-1447`） |
| `mip` | `3` `MSIP` / `7` `MTIP` / `11` `MEIP` | **RO** | 分别由 CLINT `msip`、`mtime>=mtimecmp`、PLIC M 上下文驱动（`machine.adoc:1401-1414`） |
| `mip` | 其余 | RO 0 | 每位只能"只读 0"或"可写"（`machine.adoc:1363-1371,1425-1431`） |

**S 级影子规则**：`sip/sie` 只可见 `{SSIP,STIP,SEIP}`，`mideleg=0` 的位只读 0（`supervisor.adoc:366-489`）。
**`seip` 读改写特例**：`csrrs/csrrc` 读回 `B|E`，写回只改软件位 `B`，`E` 不参与 RMW（`machine.adoc:1441-1460`）；RTL 中 `csr_rdata[9]=seip_sw|seip_i`，写掩码只作用于 `seip_sw`。

### 2.4 陷阱向量：`mtvec` @0x305 / `stvec` @0x105

| 寄存器 | 位段 | 字段 | 属性 | 语义 | 出处 |
|---|---|---|---|---|---|
| `mtvec`/`stvec` | `1:0` | `MODE` | WARL | 0=Direct（全跳 BASE）；1=Vectored（同步异常跳 BASE，中断跳 `BASE+4×cause`）；≥2 保留，写归一到 0 | `machine.adoc:1195-1210`、`supervisor.adoc:344-365` |
| `mtvec` | `31:2` | `BASE` | WARL | 必须 4 B 对齐；Vectored 可更严 → 本设计要求 **64 B 对齐**（丢弃写入的 `[5:0]`） | `machine.adoc:1211-1219` |
| `stvec` | `31:2` | `BASE` | WARL | 同（本设计同样取 64 B 对齐） | `supervisor.adoc:329-341` |
| 偏移例 | — | — | — | M 定时器中断→`BASE+0x1C`；S 定时器→`BASE+0x14` | `machine.adoc:1220-1222`、`supervisor.adoc:361-364` |

### 2.5 暂存与 EPC：`mscratch`/`sscratch` @0x340/0x140、`mepc`/`sepc` @0x341/0x141

| 寄存器 | 位段 | 属性 | 复位 | 备注 |
|---|---|---|---|---|
| `mscratch`/`sscratch` | `31:0` | RW | 0 | 纯暂存（`machine.adoc:1657-1685`、`supervisor.adoc:532-545`） |
| `mepc`/`sepc` | `31:2` | RW WARL | 0 | 写时 `[1:0]` 可写；**读时 `[0]` 恒 0**，IALIGN=32 时 `[1]` 读掩码为 0（含 `mret` 隐式读）（`machine.adoc:1690-1705`、`supervisor.adoc:546-576`） |

### 2.6 `mcause`/`scause` @0x342/0x142、`mtval`/`stval` @0x343/0x143

| 位段 | 字段 | 属性 | 语义 |
|---|---|---|---|
| `31` | `Interrupt` | WLRL 可写 | 中断陷阱置 1（`machine.adoc:1725-1736`） |
| `30:4` | 保留 | RO 0 | — |
| `3:0` | `Exception Code` | WLRL | 只保证保存已实现编码（`machine.adoc:1737-1739`、`supervisor.adoc:588-593`），`scause` 必须可存 0-31 |

异常码（`machine.adoc:1769-1810`）：`0` 取指非对齐 / `1` 取指访问错误 / `2` 非法指令 / `3` 断点 / `4` load 非对齐 / `5` load 访问错误 / `6` store-AMO 非对齐 / `7` store-AMO 访问错误 / `8,9,11` U/S/M `ecall` / `12,13,15` 取指/load/store 页错误；中断码 `1/5/9`=S 软/定时/外部，`3/7/11`=M 软/定时/外部。

| `xtval` 场景 | 写入值 | 出处 |
|---|---|---|
| 断点 / 地址非对齐 / 访问错误 / 页错误 | 出错**虚拟地址**（`machine.adoc:2010-2021`、`supervisor.adoc:718-729`） |
| 非法指令 | 出错指令编码，右对齐、高位清 0（本设计写 RVC 展开后的 32 位，`machine.adoc:2027-2040`） |
| 非对齐访存引起的访问/页错误 | 引起错误那部分访问的 VA（`machine.adoc:2023-2026`） |
| `ecall`(8/9/11) / 中断 / 其余陷阱 | `0`（`machine.adoc:2065-2066`、`supervisor.adoc:762-763`） |
| 属性 | WARL，必须能保存全部合法 VA 与 0（`machine.adoc:2067-2074`） |

### 2.7 计数器与配置 CSR

| CSR | 地址 | 位段 | 属性 | 语义 |
|---|---|---|---|---|
| `mcounteren` | 0x306 | `0/1/2`=`CY/TM/IR`；`31:3` RO 0 | RW | 为 0 时 **S/U** 读 `cycle/time/instret`→非法指令（`machine.adoc:1560-1585`） |
| `scounteren` | 0x106 | 同 | RW | 为 0 时 **U** 读对应计数器→非法指令；U 可读需 `mcounteren` 与 `scounteren` 同时置位（`supervisor.adoc:501-531`） |
| `mcountinhibit` | 0x320 | `0/2`=`CY/IR` | RW WARL | 置 1 停 `mcycle`/`minstret` 计数，不影响可访问性（`machine.adoc:1622-1640`）；`TM` 与 HPM 位 RO 0 |
| `menvcfg` | 0x30A | `0`=`FIOM`，`3:2`=`CBIE`，`4`=`CBCFE`，`7`=`CBZE` | RW | `CBIE=00/01/11`：`cbo.inval` 非法/仅非脏行/总允许（`machine.adoc:2144-2158,2236-2267`，布局 `images/wavedrom/menvcfgreg.edn`）；`PBMTE/ADUE/STCE/CDE/DTE/PMM/SSE/LPE` RO 0 |
| `menvcfgh` | 0x31A | `31:0` | RO 0 | RV32 高半无字段（`machine.adoc:2315-2318`） |
| `satp` | 0x180 | `31`=`MODE`，`30:22`=`ASID`，`21:0`=`PPN` | WARL | MODE 0=Bare、1=Sv32，写其它值**整个写无效**（`supervisor.adoc:1035-1037`）；ASIDLEN=9；Bare 时其余位必须写 0（`supervisor.adoc:1013-1018`）；本设计 PA=32 位 → 实际用 `PPN[19:0]`，`PPN[21:20]` 可存但翻译时忽略；**写 `satp` 不隐含 TLB 失效**（`supervisor.adoc:1131-1137`） |

**`mcycle`/`minstret`（0xB00/0xB80、0xB02/0xB82）与只读影子 `cycle/time/instret`（0xC00-0xC02、0xC80-0xC82）**：
影子恒只读（`machine.adoc:1600-1605`），`time/timeh` 直接来自 CLINT `mtime[63:0]`（`machine.adoc:1601-1604`）。RV32 高低半读序（本设计约定，规范只要求最终一致，`machine.adoc:2600-2603`）：
1) 读低半返回 `cnt_q[31:0]` 并把 `cnt_q[63:32]` 锁入 `hi_latch`；2) 紧随读高半时返回 `hi_latch`，否则返回 `cnt_q[63:32]`（防进位撕裂）；
3) 写低/高半分别更新 `cnt_q[31:0]`/`[63:32]`；4) 自增与 CSR 写同拍冲突时**写优先**（`ctx_wen ? wdata : cnt_q+inc`）。

**`mhpmcounter3..31`/`mhpmevent3..31`（0xB03-0xB1F/0x323-0x33F）**：合法实现为**读 0、写忽略**（`machine.adoc:1425-1431,1616-1619`），故 `hpmcounter3..31(+h)`（0xC03-0xC1F/0xC83-0xC9F）同样读 0、写忽略且**不报非法指令**；三处 `HPMn` 位一律 RO 0。

### 2.8 PMP CSR 地址与 `pmpcfg` 位段

| CSR | 地址 | 本设计实现 | 说明 |
|---|---|---|---|
| `pmpcfg0-3` | 0x3A0-0x3A3 | ✅ 全部 16 项 | RV32 共 16 个 cfg CSR，每 32 位装 4 项（`machine.adoc:3353-3357`） |
| `pmpcfg4-15` | 0x3A4-0x3AF | ❌ 不存在 | 访问须触发非法指令 |
| `pmpaddr0-15` | 0x3B0-0x3BF | ✅ | 每项编码 PA`[33:2]`（`machine.adoc:3379-3390`） |

`pmpcfgN` 内第 `i` 项占 `[8i+7:8i]`：`[7]=L`、`[6:5]` 保留（读 0 写忽略）、`[4:3]=A`、`[2]=X`、`[1]=W`、`[0]=R`（`machine.adoc:3406-3416`）；`A`：`00`=OFF、`01`=TOR、`10`=NA4、`11`=NAPOT（`machine.adoc:3429-3440`）；`R=0,W=1` 为保留组合，`R/W/X` 是联合 WARL 域（`machine.adoc:3410-3412`）。

### 2.9 监管级 / 用户级 CSR

| 地址 | 名称 | 可访问位 | 说明 |
|---|---|---|---|
| 0x100 | `sstatus` | `SD/SPP/SPIE/SIE/SUM/MXR/FS/XS` | 写有效位等价写 `mstatus` 同名位（`supervisor.adoc:39-133`） |
| 0x104/0x144 | `sie`/`sip` | `{SEIE(9),STIE(5),SSIE(1)}` | 仅 `mideleg` 已置位者可写，其余 RO 0（`supervisor.adoc:408-410`） |
| 0x105 | `stvec` | 见 §2.4 | — |
| 0x106 | `scounteren` | `CY/TM/IR` | 见 §2.7 |
| 0x10A | `senvcfg` | `CBZE(7)/CBCFE(4)/CBIE(3:2)` | S 执行 `cbo.*` 用 `senvcfg`；`FIOM` RO 0（`supervisor.adoc:786-970`） |
| 0x140/0x141/0x142/0x143 | `sscratch`/`sepc`/`scause`/`stval` | 见 §2.5/§2.6 | `scause[4:0]` 必须可存 0-31（`supervisor.adoc:591-593`） |
| 0x180 | `satp` | 见 §2.7 | — |
| 0xC00-0xC02 / 0xC80-0xC82 | `cycle/time/instret`(+h) | RO | 受 §4.3 门控 |

### 2.10 `satp` 地址转换与裸模式判据（供 MMU 使用）

`translate_en = (satp.MODE==1) && (eff_priv∈{S,U})`；`eff_priv` 由 `mstatus.MPRV && priv_mode==M ? mstatus.MPP : priv_mode` 得到（`machine.adoc:586-635`）。Bare 模式下 VA=PA，但**仍须过 PMP**（`supervisor.adoc:1011-1012`）。

## 3. CSR 访问合法性判定（自上而下，命中即停）

| # | 条件 | 结果 | 出处 |
|---|---|---|---|
| 1 | `csr_addr[11:10]!=2'b11` 且为写（`csr_op!=0`） | 非法指令（写只读 CSR） | `csrs.adoc:56-58` |
| 2 | `csr_addr[9:8] > priv_mode` | 非法指令（特权级不足） | `csrs.adoc:53-55` |
| 3 | 地址不在实现清单（含 `pmpcfg4-15`、`0x7B0-0x7BF`、未实现 HPM 之外的空洞） | 非法指令（不存在） | `csrs.adoc:59-63` |
| 4 | `TVM=1 && priv_mode==S && (csr_addr==0x180 \|\| sys_op==SFENCE_VMA)` | 非法指令 | `machine.adoc:732-742` |
| 5 | `TSR=1 && priv_mode==S && sys_op==SRET`；或 `TW=1 && priv_mode<S && sys_op==WFI`（允许恒非法） | 非法指令 | `machine.adoc:779-786,753-769` |
| 6 | `priv_mode==U && sys_op==WFI`；或 `MRET && priv_mode<M`；或 `SRET && priv_mode<S` | 非法指令（与 TW 无关） | `machine.adoc:771-774,2660-2668` |
| 7 | 计数器门控（见下表） | 非法指令 | 见下表 |
| 8 | `FS==0` 且指令为 FP | 非法指令 | `machine.adoc:889-892` |
| 9 | 皆不命中 | 正常执行 | — |

**统一报告**：`xcause=2`、`xtval=`出错指令编码（32 位右对齐，RVC 已展开）、`xepc=`该指令 PC、无任何副作用（`csr_wen` 屏蔽、rd 不写）。

| 计数器门控 | 当前模式 | 条件 | 结果 |
|---|---|---|---|
| `cycle/instret/hpmcounter*` | S | `mcounteren.{CY,IR,HPMn}=0` | 非法指令（`machine.adoc:1574-1578`） |
| `cycle/instret/hpmcounter*` | U | `mcounteren` 或 `scounteren` 对应位为 0 | 非法指令（`supervisor.adoc:511-520`） |
| `time/timeh` | S / U | S：`mcounteren.TM=0`；U：`mcounteren.TM` 或 `scounteren.TM` 为 0 | 非法指令 |
| `cycle/instret` / `mcountinhibit` | M / 任意 | M 不受 `mcounteren` 约束；`mcountinhibit` 只影响计数不影响可访问性 | 恒可访问（`csrs.adoc:53-55`、`machine.adoc:1630-1632`） |

## 4. 同步异常优先级

### 4.1 本设计判定顺序（自高到低，取第一个命中者）

| 优先级 | 阶段 | `xcause` | 条件 | 出处 |
|---|---|---|---|---|
| 1 | 取指 | `3` | 取指地址断点（未实现触发器，保留）；其后依次为 `12`/`1`（翻译先遇页错误/访问错误）、`1`（物理地址取指访问错误） | `machine.adoc:1904-1909` |
| 4 | 执行 | `2` | 非法指令（含 CSR 非法、`FS=0` 的 FP） | `machine.adoc:1910-1914` |
| 5 | 执行 | `0` | 指令地址非对齐：**本设计实现 Zca（IALIGN=16），规范明确任何指令都不会产生该异常**（`zca.adoc` norm:Zcanomisaligned）→ 不实现（保留优先级表位置仅为完整性）；其后为 `8/9/11`（`ecall`）、`3`（`ebreak`） | `machine.adoc:1910-1914,1941-1944`；`zca.adoc` |
| 8 | 访存 | `4`/`6` | load/store/AMO 地址非对齐（**本设计不分解非对齐访问**→取高优先级；规范允许两选一） | `machine.adoc:1916-1934` |
| 9 | 访存 | `13/15/5/7` | 显式访存翻译：先遇到的页错误或访问错误；之后为 `5`/`7`（已有物理地址的 load/store 访问错误） | `machine.adoc:1918-1921` |

**RTL 落地**：非对齐检查在 EX/AGU 完成并置 `excp_valid=1, cause=4/6`，同拍关闭该 uop 的 MMU 请求（`mmu_req_valid &= !misaligned`），组合上排除第 9/10 级——这就是"取高优先级"的实现方式。

### 4.2 中断优先级

| 目的模式 | 顺序（高→低） | 出处 |
|---|---|---|
| M（未委托） | `MEI(11)`→`MSI(3)`→`MTI(7)`→`SEI(9)`→`SSI(1)`→`STI(5)` | `machine.adoc:1484-1486` |
| S（已委托） | `SEI(9)`→`SSI(1)`→`STI(5)` | `supervisor.adoc:486-489` |
| 跨模式 | M 级中断优先于任何低特权中断；同拍多源只取 1 个 | `machine.adoc:1360-1361` |

## 5. 陷阱进入、委托与返回

### 5.1 进入条件与委托判定

进入输入：`trap_valid/trap_cause[3:0]/trap_tval[31:0]`（ROB 头部 uop）、`trap_is_intr`（中断采样器）、`trap_epc`（异常=ROB 头部 `pc`；中断=被中断的下一条指令 PC，见 §5.3）。

| 陷阱类型 | 条件 | 目标 | 写入的 CSR |
|---|---|---|---|
| 同步异常 | `priv_mode<=S` 且 `medeleg[cause]=1` | S | `scause/sepc/stval/sstatus.{SPP,SPIE,SIE}` |
| 同步异常 | 其余（含 `priv_mode==M`、`medeleg=0`、`cause==11`） | M | `mcause/mepc/mtval/mstatus.{MPP,MPIE,MIE}` |
| 中断 | `priv_mode<S` 且 `mideleg[cause]=1` | S | 同上 S 组 |
| 中断 | 其余 | M | 同上 M 组 |

约束（`machine.adoc:1246-1268`）：① 陷阱永不从高特权降到低特权（M 模式执行的非法指令即使已委托也在 M 处理）；② 可水平触发（S 执行的非法指令在 `medeleg[2]=1` 时在 S 处理）；③ 委托后中断在委托者级别被屏蔽（`mideleg[5]=1` 时 M 模式不取 STI）；④ **委托到 S 时绝不写** `mcause/mepc/mtval/mstatus.{MPP,MPIE}`（`machine.adoc:1276-1278`）。

### 5.2 陷阱进入的 CSR 更新顺序（单拍内并发赋值，S 目标把 `m*`→`s*`、`MPP/MPIE/MIE`→`SPP/SPIE/SIE`）

| 步 | 寄存器 | 新值 | 说明 |
|---|---|---|---|
| 1 | `mepc` | `trap_epc`（`[0]`恒 0；IALIGN=32 时 `[1]`亦 0） | 先锁存现场 |
| 2 | `mcause` | `{trap_is_intr, 27'b0, cause[3:0]}`；`mtval`：中断→0，异常→按 §2.6 | 中断位置 1 |
| 3 | `mstatus.MPP` | `priv_mode`（WARL：`2'b10`→`2'b11`） | 用**旧**特权级 |
| 4 | `mstatus.MPIE` | 旧 `mstatus.MIE` | 必须读旧值 |
| 5 | `mstatus.MIE` | `0` | 最后清使能 |
| 6 | `priv_mode` | `trap_target_priv`；并置 `flush_all=1`、`redirect_pc=trap_vector` | `00-conventions.md:40-45` |

**关键点**：① 步骤 4/5 必须用旧 `priv_mode`/`MIE`（`trap_ctrl.v` 内用组合 `_d` 信号）；② **M 目标陷阱不改 `SPP/SPIE`**，S 目标陷阱不改 M 组；③ **`MPRV` 在陷阱入口不清零**（规范只在 `xRET` 且目标≠M 时清，`machine.adoc:3405-3412`）；④ 被打断的指令无任何架构副作用：`csr_wen`/`rd_wen`/store 落盘在 RT 级统一屏蔽。

### 5.3 向量地址、中断采样与 `mret/sret`

```
trap_deleg = (priv_mode != M) && (is_intr ? mideleg[cause] : medeleg[cause]);
vec_base   = trap_deleg ? {stvec[31:6],6'b0} : {mtvec[31:6],6'b0};
vec_mode   = trap_deleg ? stvec[1:0] : mtvec[1:0];
trap_vector = (vec_mode==2'b01 && is_intr) ? vec_base + {22'b0,cause[3:0],2'b00} : vec_base;
```
出处：`machine.adoc:1195-1210`（mtvec）、`supervisor.adoc:344-365`（stvec）。

| 中断采样项 | 规则 | 出处 |
|---|---|---|
| 采样点 | **RT 级 ROB 头部**，每拍重算 `intr_taken[5:0]` | 本项目实现 |
| M 级条件 | `priv_mode==M ? mstatus.MIE : 1'b1`，且 `mip[i]&mie[i]`，且 `!mideleg[i]` | `machine.adoc:1346-1352` |
| S 级条件 | `priv_mode<S` 且 `mideleg[i]` 且 (`priv_mode==U` \| `sstatus.SIE`) 且 `sip[i]&sie[i]` | `supervisor.adoc:383-396` |
| WFI 唤醒 | 用**局部使能**判定，不看 `MIE/SIE` 与 `mideleg` | `machine.adoc:2718-2731` |
| 有界时间 | 中断从挂起到取走必须有界；**`xRET` 或写 `mip/mie/mstatus/mideleg` 后必须立即重新评估** | `machine.adoc:1353-1358` |
| `xepc`（中断） | 写"被中断指令"地址；若头部 uop 已可提交则 `mepc=头部PC+4`（WFI 同，`machine.adoc:2716`） | `machine.adoc:1707-1712` |
| 精确插入 | `intr_taken` 仅在 `rob_head_valid && rob_head_done` 时被接收；同拍 `flush_all` 丢弃全部年轻 uop，故中断只插在两条指令之间 | `00-conventions.md:40-45` |
| `xRET` 后立即生效 | `mret/sret` 提交后下一拍用新 `priv_mode`/`xIE` 重采样（`ret_just_committed` 抑制同拍重入） | `machine.adoc:1353-1358` |

| `mret`/`sret` 恢复步 | `mret` | `sret` |
|---|---|---|
| 合法性 | `priv_mode==M` | `priv_mode>=S`；`TSR=1 && priv_mode==S`→非法指令 |
| 目标模式 `y` / `xIE←xPIE` / `xPIE←1` | `y=MPP`；`MIE←MPIE`，`MPIE←1` | `y=SPP?S:U`；`SIE←SPIE`，`SPIE←1` |
| `xPP←`最不特权 / `MPRV` | `MPP←U`；`y!=M` 时 `MPRV←0`，`y==M` 时不变 | `SPP←0`；返回 U 时 `MPRV←0` |
| PC/特权级 | `pc←mepc`（读时按 IALIGN 掩码 `[1]`），`priv_mode←y` | `pc←sepc`，`priv_mode←y` |
| 其他 | 允许清 LR 保留集（本设计 `lr_resv_valid<=0`）；提交级单条串行 + `flush_all` | 同 |

出处：`machine.adoc:2645-2681,3371-3412`、`supervisor.adoc:103-126`。**嵌套 trap 正确性**：`mret` 只写 M 组栈、`sret` 只写 S 组栈，互不破坏；`xPP←最不特权模式`使栈位误用可被软件检出（`machine.adoc:3400-3404`）。在 S 处理程序中再次陷入 M 会覆盖 M 组 `MPP/MPIE`，这是**规范预期**行为，M 处理程序必须自行保存 S 组现场。

## 6. MMU：TLB 与 PTW（`rtl/mmu/tlb.v`、`rtl/mmu/ptw.v`）

### 6.1 TLB 组织与表项位域

| 结构 | 容量 | 相联 | 端口 | 说明 |
|---|---|---|---|---|
| ITLB | 32 | 全相联 | 1 读 + 1 填 | 与 I-Cache 并行查询，命中判定在 IF2（`03-pipeline-regs.md:12`） |
| DTLB | 64 | 全相联 | 1 读 + 1 填 | 与 D-Cache 并行查询 |
| L2TLB | 256 | 4 路（64 组） | 1 读 + 1 填 | ITLB/DTLB 共享，PTW 缺失时回填，LRU 替换 |
| PTW | 1（可参数化 2） | — | — | 逐级读 PTE |

| 位段 | 字段 | 宽度 | 语义 |
|---|---|---|---|
| `VPN_TAG` / `IS_4M` | VA 标签 / 级别 | 20 / 1 | 4 K 页比较 `va[31:12]` 全 20 位；`IS_4M`=0 为 4 K、1 为 4 M |
| `ASID` / `G` | ASID / 全局 | 9 / 1 | 来自 `satp.ASID`；`G=1` 时忽略 ASID 比较（`supervisor.adoc:1843-1845`） |
| `PERM` | R/W/X/U | 4 | 叶子 PTE 权限位 |
| `PPN` | PPN | 22 | 4 K 用全 22 位；4 M 只用 `[21:10]`，低 10 位由 VA 提供 |
| `VALID` / `PMP_OK` | 有效 / PMP 通过标记 | 1 / 1 | 复位清 0；`PMP_OK` 表示该页物理区间通过 PMP（见 §7.4） |

命中判定（组合 1 拍）：`hit = VALID & (G | (ASID==satp_asid)) & (IS_4M ? VPN_TAG[19:10]==va[31:22] : VPN_TAG[19:0]==va[31:12])`；
`pa = IS_4M ? {PPN[21:10],va[21:12],va[11:0]} : {PPN[21:0],va[11:0]}`。

### 6.2 Sv32 页表遍历的完整判定伪代码（`supervisor.adoc:1723-1785`）

```
// 前置: translate_en; PAGESIZE=2^12, LEVELS=2, PTESIZE=4
1  a = satp.ppn << 12;  i = 1;
2  pte_addr = a + (va.vpn[i] << 2);
   if (pmp_check(pte_addr,4,LOAD,S) != OK)      -> ACCESS_FAULT(req_type, va)   // 页表访问按 S 检查
3  pte = mem_read32(pte_addr);
   if (pte.v == 0)                              -> PAGE_FAULT(req_type, va)
   if (pte.r == 0 && pte.w == 1)                -> PAGE_FAULT(req_type, va)
   if (pte[31:10] 保留位非零)                    -> PAGE_FAULT(req_type, va)   // 仅 pte[9:8](RSW) 可自由使用
4  if (pte.r || pte.x) goto 5;                                  // 叶子
   if (i == 0)                                  -> PAGE_FAULT(req_type, va)   // 第二级仍非叶
   i = 0; a = pte.ppn << 12; goto 2;                            // 非叶: 不检查 A/D/U 组合
5  if (i > 0 && pte.ppn[i-1:0] != 0)             -> PAGE_FAULT(req_type, va)   // 超级页未对齐(4M 要求 ppn[9:0]=0)
6  if (!perm_u_ok(pte.u, mode, sum))             -> PAGE_FAULT(req_type, va)
7  if (!perm_rwx_ok(pte, req_type, mxr))         -> PAGE_FAULT(req_type, va)
8  if (pte.a == 0 || (is_store && pte.d == 0)) begin
       if (Svade)                               -> PAGE_FAULT(req_type, va)
       if (pmp_check(pte_addr,4,STORE,S)!=OK)   -> ACCESS_FAULT(req_type, va)
       atomic_CAS(pte_addr, pte, pte | A | (is_store?D:0));     // PTE 整体原子更新
       if (CAS 失败) goto 2;                                    // 重新遍历
   end
9  pa.pgoff = va.pgoff;
   pa.ppn[19:10] = pte.ppn[19:10];
   pa.ppn[9:0]   = (i>0) ? pte.ppn[9:0] : va.vpn[9:0];          // 4M 大页补 VA 低位
```

| 判定项 | 规则 | 出处 |
|---|---|---|
| `V=0`、`R=0&&W=1`、保留位/编码非零 | 页错误 | `supervisor.adoc:1732-1734` |
| 非叶 PTE | `R=0&&W=0&&X=0`，`i←i-1` 继续；`i<0` 则页错误 | `supervisor.adoc:1736-1740` |
| 超级页对齐 | `i>0 && pte.ppn[i-1:0]!=0`→页错误 | `supervisor.adoc:1742-1744` |
| `U` 位 | `mode==U` 需 `U=1`；`mode==S&&SUM=0` 需 `U=0`；`SUM=1` 允许 `U=1` | `supervisor.adoc:1746-1747`、`machine.adoc:2813-2820` |
| `R/W/X` | 取指需 `X`；load 需 `R`（`MXR=1` 时 `X` 亦可）；store/AMO 需 `W` | `supervisor.adoc:1750-1752` |
| A/D 更新 / A/D 缓存 | `Svade`→页错误；否则原子 CAS 写回，**PTE 整体原子更新**，CAS 失败回步骤 2；**地址翻译缓存不得用于 A/D 更新**，只能直接改内存 | `supervisor.adoc:1754-1766,1849-1854` |
| 页表访问权限 / `MPRV` | 隐式页表访问的有效特权级为 **S**（PMP 检查同）；`MPRV=1` 时用 `MPP` 作为有效特权级 | `machine.adoc:3331-3333,3627-3629,586-635` |
| 推测翻译 | 允许推测；推测时不得置 D、不得报异常、不得建立会被已执行 `sfence.vma` 作废的表项 | `supervisor.adoc:1800-1807` |
| 异常优先级 | 页表读访问错误 > `V`/`R=0,W=1`/保留位页错误 > 超级页对齐 > `U` 位 > `R/W/X` > A/D 页错误；A/D 写回 PMP 违例报**访问错误** | `supervisor.adoc:1732-1766` |

### 6.3 PTW 状态机（逐拍动作）

| 状态 | 编码 | 本拍动作 | 次态 |
|---|---|---|---|
| `IDLE` | 3'd0 | 等 `ptw_req_valid` | 有请求→锁存 `va/asid/req_type`→`LEVEL1` |
| `LEVEL1` | 3'd1 | 发 `pte_addr={satp_ppn,va[31:22],2'b00}`；PMP 检查(LOAD,S)；AXI 读 | 读回：非法→`FAULT`；非叶→`LEVEL2`；叶子→判对齐/权限后 `UPDATE_AD` 或直接回填 |
| `LEVEL2` | 3'd2 | 发 `pte_addr={l1_ppn,va[21:12],2'b00}`；同样 PMP；AXI 读 | 读回：非法→`FAULT`；需更新 A/D→`UPDATE_AD`；否则回填 |
| `UPDATE_AD` | 3'd3 | 原子读改写 `pte'=pte\|A\|(store?D:0)`，经 D-Cache 通路保证原子性 | 写回完成→复查原值：成功→回填；失败→回 `LEVEL1` |
| `FAULT` | 3'd4 | 置 `mmu_resp_fault=1`、`cause∈{12,13,15}` 或 `{1,5,7}`、`tval=va`；**不建立表项** | →`IDLE` |
| 回填 | — | 写 L2TLB（4 路 LRU）→再写请求方 ITLB/DTLB | →`IDLE` |

参数：一次遍历 = 2 拍页表读 + 1 拍 A/D 写（L2 命中时 AXI 读约 3~6 拍）；`mmu_busy=1` 时反压 IF/LSU（`03-pipeline-regs.md:101`）；`sfence_all` 期间用 **epoch 计数**丢弃在途 PTW 结果（`supervisor.adoc:1811-1828`）。

### 6.4 `sfence.vma` 失效粒度矩阵（`supervisor.adoc:1255-1285`）

| `rs1` | `rs2` | 失效范围 | ITLB | DTLB | L2TLB |
|---|---|---|---|---|---|
| `x0` | `x0` | 全部 ASID、全部地址（含 global） | 全清 | 全清 | 全清 |
| `x0` | ≠`x0` | 匹配 `rs2[8:0]` 的 ASID，**不含 global 表项** | ASID 匹配项 | ASID 匹配项 | ASID 匹配项 |
| ≠`x0` | `x0` | 含 `rs1` 的叶子映射（含 4 M 大页），**全部 ASID** | VA 匹配项 | VA 匹配项 | VA 匹配项 |
| ≠`x0` | ≠`x0` | `rs1` VA 且 `rs2` ASID，**不含 global 表项** | 双条件项 | 双条件项 | 双条件项 |

VA 匹配实现（一次比较覆盖 4 K/4 M）：`va_hit(e,rs1) = e.IS_4M ? (e.VPN_TAG[19:10]==rs1[31:22]) : (e.VPN_TAG[19:0]==rs1[31:12])`。

| 附加规则 | 说明 | 出处 |
|---|---|---|
| `rs1` 非法 VA / 过度失效 / `rs2[31:9]` | 非法 VA 无副作用不报异常；允许把任意 `sfence.vma` 当作 `rs1=rs2=x0`（本设计不采用）；`rs2[31:9]` 保留、忽略 | `supervisor.adoc:1287-1304` |
| `TVM=1 && S` | 非法指令 | `machine.adoc:732-742` |
| PMP 改写后 / `satp` 写入 | PMP 改写后软件须执行 `sfence.vma x0,x0` 同步；写 `satp` **不隐含失效**，软件须自行 `sfence.vma` | `machine.adoc:3631-3636`、`supervisor.adoc:1131-1137` |

## 7. PMP：物理内存保护（`csr/rv32_pmp.v` + `csr/rv32_csr.v`）

### 7.1 结构与规模（**阶段 2A 已落地，取代本节原先的"单状态模块"方案**）

| 部分 | 位置 | 职责 |
|---|---|---|
| PMP CSR 状态与写路径 | `rtl/csr/rv32_csr.v` | `pmpcfg0-3`@0x3A0-0x3A3、`pmpaddr0-15`@0x3B0-0x3BF（`0x3A4-0x3AF` **不存在** ⇒ 非法指令）；锁定合并、写归一、WB→ID 读旁通；输出 `pmpcfg_o[127:0]` / `pmpaddr_o[511:0]` |
| 匹配与权限判定 | `rtl/csr/rv32_pmp.v` | **纯组合、无状态**：`pmpcfg/pmpaddr + addr + acc_size + eff_priv + need_r/w/x`（两组）→ `permit`/`permit2`/`match_any`/`match_all` |

**为什么不用原方案的单状态模块**：PMP CSR 必须与其它 CSR 共用同一条读写与**旁通**路径（"写锁定项之后
紧跟的那条读"必须返回**锁定/归一后的有效值**，是 arch-test 最容易挂的点），状态放在 `rv32_csr.v` 才能复用
既有结构；检查器保持纯组合则便于独立单测（`sim/tests/unit/tb_unit_pmp.v`，443 checks）。

```verilog
module rv32_pmp #(parameter integer PMP_ENTRIES = 16) (
  input  wire [PMP_ENTRIES*8-1:0]  pmpcfg,   input wire [PMP_ENTRIES*32-1:0] pmpaddr,
  input  wire [31:0] addr,  input wire [1:0] acc_size,  input wire [1:0] eff_priv,
  input  wire need_r, need_w, need_x,        // 第一组权限需求（取指：need_x）
  input  wire need_r2, need_w2, need_x2,     // 第二组（与第一组**共享同一次匹配**）
  output wire permit, permit2,  output wire [PMP_ENTRIES-1:0] match_any, match_all
);
```

* `addr` 为 32 位：基线核 VA=PA，Sv32 的 34 位物理地址在 2A-4 接入 MMU 时加宽。
* **访存侧只实例化一个匹配引擎**：`permit` 供读相位、`permit2` 供写相位（AMO 先读后写 ⇒ 缺 R 报
  cause 5、缺 W 报 cause 7，与 Spike 的 mmu 调用顺序一致）。实测复制匹配树会让 iverilog 仿真慢 3 倍以上，
  且 NAPOT 掩码必须**无循环**实现（原 for 循环版本同样拖慢 10 倍）。
* `cfg_changed` **不再需要**：本核不缓存 PMP 判定（取指每拍、访存每次都在组合逻辑上现算）。

### 7.2 匹配算法伪代码（`machine.adoc:3427-3540`）

```
// y = chk_addr[33:2]; 按最低编号优先
case (cfg[i].A)
  2'b00: match = 0;                                                  // OFF
  2'b01: match = (i==0) ? (y < addr[0]) : (addr[i-1] <= y && y < addr[i]);   // TOR, 项0下界为0
  2'b10: match = (addr[i] == y);                                     // NA4
  2'b11: begin j = trailing_ones_or_zero(addr[i]);                   // NAPOT: 从 bit0 起连续 1 的个数
              mask = ~((34'd1 << j) - 1);
              match = ((y & mask) == (addr[i] & mask)); end
endcase
hit = 第一个 match==1 的 i;   // 最低编号优先, 忽略更高编号
```

| 规则 | 说明 | 出处 |
|---|---|---|
| 优先级 | 最低编号匹配项决定结果 | `machine.adoc:3568-3570` |
| 全匹配要求 | 匹配项必须覆盖访存**所有字节**，否则失败（与 L/R/W/X 无关） | `machine.adoc:3571-3576` |
| 非对齐/宽访存 | 每个访存操作独立检查；部分字节通过并可见是允许的 | `machine.adoc:3566-3567,3594-3600` |
| TOR 空集 / 颗粒度 | `pmpaddr[i-1]>=pmpaddr[i]` 时项 `i` 不匹配任何地址；`G=0` 时 NA4 可选且 `pmpaddr` 无掩码位 | `machine.adoc:3512-3516,3489-3497` |

### 7.3 权限与锁定语义

| 条件 | 结果 | 出处 |
|---|---|---|
| 匹配且 `L=0` 且 `mode==M` | 成功（R/W/X 只约束 S/U） | `machine.adoc:3546-3551,3580-3584` |
| 匹配且（`L=1` 或 `mode∈{S,U}`） | 仅当对应 `R/W/X=1` 才成功 | `machine.adoc:3580-3584` |
| `L=1` | 写 `pmpcfg[i]`/`pmpaddr[i]` 被忽略直到复位；`A=OFF` 也锁 | `machine.adoc:3546-3552` |
| `L=1 && A=TOR` | 额外忽略对 `pmpaddr[i-1]` 的写 | `machine.adoc:3552-3555` |
| 无匹配，`mode==M` | 成功 | `machine.adoc:3585-3588` |
| 无匹配，`mode∈{S,U}` | **失败**（只要实现了 ≥1 项）；若全部 `A=OFF` 则所有 S/U 访存失败 | `machine.adoc:3585-3593` |
| 取指无 X / load 无 R / store 无 W | `cause=1` / `5` / `7` 访问错误 | `machine.adoc:3418-3425` |
| 精确性 | PMP 违例始终精确陷阱 | `machine.adoc:3335-3336` |

### 7.4 与 TLB / CSR 的交互

| 事件 | 动作 |
|---|---|
| 写 `pmpcfg0-3`/`pmpaddr0-15`（未被锁定） | `cfg_changed=1` → 清 ITLB/DTLB/L2TLB **全部 `VALID`**，`ptw_epoch++`（丢弃在途 PTW 结果） |
| 规范要求 | 软件写 PMP 后必须执行 `sfence.vma x0,x0` 同步；本设计**额外**硬件自清（超规范，允许） |
| `PMP_OK` 标记 | 翻译完成时对 `{PPN,IS_4M}` 覆盖的物理区间做一次 PMP 检查并随表项缓存；`PMP_OK=0` 的表项不建立 |
| 页表自身访问 | PTW 每次 PTE 读都用 **S + LOAD** 做 PMP 检查 |
| 兜底 | 跨页/非对齐访存由 §7.2 逐次检查兜底 |

出处：`machine.adoc:3631-3636`（PMP 与 VM 同步、须 `sfence.vma`）、`machine.adoc:3621-3625`（PMP 结果可被缓存，检查点可在翻译与访存之间任意位置）、`machine.adoc:3331-3333`（页表访问的 PMP 检查）。

## 8. `clint.v` 与 `plic.v`

### 8.1 CLINT @0x1F00_0000（`machine.adoc:2510-2603`）

| 偏移 | 名称 | 宽度 | 读写 | 语义 |
|---|---|---|---|---|
| `0x0000` | `msip`(hart0) | 32 | RW | 仅 bit0：写 1 置 `mip.MSIP`，写 0 清；`[31:1]` 读 0（`machine.adoc:1416-1418`） |
| `0x4000`/`0x4004`、`0xBFF8`/`0xBFFC` | `mtimecmp`、`mtime`（低/高 32 位各一） | 32+32 | RW | 64 位比较值与自由运行计数，**频率 = `cpu_clk`**（`machine.adoc:2524-2536`） |

```
mtip = (mtime >= mtimecmp) && !suppress;     // 无符号比较; 挂起直到 mtimecmp > mtime 撤销
// 写 mtimecmp[63:32] 时: 若 {new_hi, mtimecmp_lo} < mtime 则 suppress<=1, 直到写低半时清 suppress
```
| 规则 | 说明 | 出处 |
|---|---|---|
| 置位/撤销 | `mtime>=mtimecmp` 挂起；`mtimecmp>mtime` 撤销 | `machine.adoc:2531-2536` |
| 可见延迟 | 比较结果变化"最终但不立即"反映到 `mip.MTIP`，允许毛刺 | `machine.adoc:2593-2596` |
| RV32 写序 | 规范示例：先写 `-1` 到低半、再写高半、最后写低半，避免中间值抖动 | `machine.adoc:2598-2612` |
| 实现要求 | 为兼容上述序列，**写高半若会导致 `mtimecmp<mtime`，须抑制一次中断**（`suppress` 触发器） | `04-csr-mmu.md:96` + 本项目约定 |
| 回绕 | `mtime` 溢出回绕 | `machine.adoc:2525-2527` |
| 连接 | `mip.MTIP=mtip`（RO）、`mip.MSIP=msip[0]`（RO） | `machine.adoc:1406-1414` |

### 8.2 PLIC @0x1F10_0000 寄存器映射（SiFive 兼容，2 上下文）

| 偏移 | 名称 | 读写 | 语义 |
|---|---|---|---|
| `0x0000+4×N`（N=1..7） | `priority[N]` | RW | 源 N 优先级；0=禁止；复位 0 |
| `0x1000+4×0` | `pending[0]` | RO | bit N=源 N 挂起（源 0 保留） |
| `0x2000+4×0` | `enable[ctx0]` | RW | hart0-M 使能位 |
| `0x2080+4×0` | `enable[ctx1]` | RW | hart0-S 使能位 |
| `0x200000+4×ctx` | `threshold[ctx]` | RW | 仅 `priority>threshold` 可触发 |
| `0x200000+4×ctx+0x1000` | `claim/complete[ctx]` | RW | 读=claim 返回最高优先级挂起源号；写=complete（源号） |

| 源号 | 平台信号 | 设备 | 源号 | 平台信号 | 设备 |
|---|---|---|---|---|---|
| 1 / 2 / 3 | `intrpt[0]` / `intrpt[1]` / `intrpt[2]` | MAC (dmfe) / UART0 / SPI | 4 / 5 / 6-7 | `intrpt[3]` / `intrpt[4]` / `intrpt[6:5]` | NAND / DMA / 预留 |

`NDEV=8`，源 0 保留；设备树 `interrupts=<1..5>` 与上表一致（`04-csr-mmu.md:138-148`）。**到核内的连接**：`meip_i=plic_ctx0_out → mip.MEIP`（`mip[11]` RO，`machine.adoc:1401-1405`）；`seip_i=plic_ctx1_out → mip[9]=seip_sw|seip_i`（`machine.adoc:1439-1441`）；`mtip → mip[7]`；`msip → mip[3]`。

### 8.3 PLIC 内部状态机与 claim/complete 流程

| 状态 | 编码 | 动作 | 次态 |
|---|---|---|---|
| `IDLE` | 2'd0 | 每拍算 `best[ctx]` | `best!=0 && best_pri>threshold[ctx]`→`ASSERT` |
| `ASSERT` | 2'd1 | 拉高 `ctx_out`（→`mip.MEIP`/`SEIP`），保持到 claim | 被 claim→`CLAIMED` |
| `CLAIMED` | 2'd2 | 记录 `claimed[ctx]=src`；清 `pending[src]`；`gateway[src]=BUSY` | `gateway[src]==DONE`→`COMPLETE` |
| `COMPLETE` | 2'd3 | 写 `claim/complete[ctx]=src`：清 `gateway[src]=IDLE`；若源线仍高则重挂 `pending[src]` | →`IDLE` |

```
best[ctx] = argmax_{N: pending[N] && enable[ctx][N] && priority[N] > threshold[ctx]} priority[N]  // 同级取最小编号
```
| 规则 | 说明 |
|---|---|
| 门控 | `enable=0`、`priority=0` 或 `priority<=threshold` 的源不产生中断 |
| claim | 读返回 `best[ctx]` 并**硬件自动清 `pending[src]`**；complete 前该源被 `gateway=BUSY` 屏蔽，防重入 |
| complete | 写回同一源号解除屏蔽；平台中断为电平敏感，若线仍为高则立即重新挂起 |
| 上下文 | ctx0=hart0-M（→MEIP），ctx1=hart0-S（→SEIP），二者完全独立 |
| 复位 | 全部优先级/使能/阈值=0，`pending/gateway` 归 IDLE |

**与 `mip` 的关系**：M 外部中断 bit11 不可委托；`mideleg[9]=1` 时 S 外部中断走 S 陷阱（`machine.adoc:1305-1312`）。

## 9. 验证要点

参考 `../reports/arch-test-report.md`。该报告 §5 明确指出：`tests/priv/**` 中**尚无** `Sm/S/U/InterruptsSm/ExceptionsSm` 等已生成 `.S` 测试，仅有 generator 与 coverpoints，故下表中"可用组"限于已存在的目录，其余项须按 coverpoint 手写定向测试。

| # | 验证项 | 判据 | 可用组（`riscv-arch-test/tests/priv/`） |
|---|---|---|---|
| 1 | 每个 CSR 读写 + WARL | 写全 1/全 0/随机后读回等于预期掩码；`misa` 仅 bit2 可改；`MPP` 写 `10` 读回 `11`；`mtvec` MODE≥2 归一 0；`satp` 非法 MODE 整写无效 | `Sv/sv32_satp_access_test.S`；`coverpoints/norm/Sm.yaml` |
| 2 | CSR 访问合法性 | §3 每行 1 正例 + 1 反例；反例判 `mcause=2`、`mtval=`指令编码、无副作用 | `Svbare/`；`Sm_mcsr_cg/cp_mcsr_access` coverpoint |
| 3 | 异常优先级矩阵 | "非对齐+页错误""页错误+访问错误""非法指令+ecall"等组合与 §4.1 顺序一致 | `ExceptionsSv/`、`ExceptionsSvZaamo/`、`ExceptionsSvZalrsc/` |
| 4 | 委托判定 | `medeleg/mideleg` 全位扫描；S/U 源且已委托→S 组 CSR；M 源或未委托→M 组；委托到 S 时 M 组不变 | `InterruptsS/InterruptsSSm` coverpoint；`norm/Sm.yaml:713-735` |
| 5 | `mret/sret` 状态恢复 | `MPP/MPIE/MIE`、`SPP/SPIE/SIE` 全组合；返回 M 时 `MPRV` 保持、返回 S/U 时清 0；`xPP` 复位为 U | `InterruptsSm/cp_priority`、`ExceptionsSm` coverpoint |
| 6 | Sv32 权限矩阵 | U/S/M × R/W/X × `SUM/MXR/MPRV`；S 访问 `U=1` 且 `SUM=0`→`cause=13/15`；`MXR=1` 时 X 页可读 | `Sv/`（31 个 `sv32*`，含 `mstatus.MPRV/MXR/SUM`） |
| 7 | 4 M 大页 | `ppn[9:0]!=0`→页错误；合法大页 PA 拼接正确 | `Sv/`（misaligned superpage 用例） |
| 8 | A/D 位更新 | Svadu：首访置 A、store 置 D、PTE 整体原子写回；Svade：`A=0` 或 `store&&D=0`→页错误 | `Svade/`、`Svadu/`、`SvaduPMP/`（各 2 个 `sv32*`） |
| 9 | `sfence.vma` 粒度 | §6.4 四种组合 × {ITLB,DTLB,L2TLB}；失效后必须重新遍历；`rs2≠x0` 时 global 表项保留 | `Sv/`、`Svbare/` |
| 10 | PMP 三模式边界 | OFF/TOR/NA4/NAPOT 首末地址 ±1；TOR 项 0 下界 0；`pmpaddr[i-1]>=pmpaddr[i]` 匹配空集；NA4 精确 4 B | `PMPSm/`（38 个） |
| 11 | PMP 锁定语义 | `L=1` 后写 cfg/addr 被忽略；`L=1&&A=TOR` 时写 `pmpaddr[i-1]` 被忽略；`L=1` 时 M 也受限 | `PMPSm/`（`cp_cfg_L_modify_TOR`） |
| 12 | PMP × 特权级 × MPRV | M 无匹配可访问、S/U 无匹配拒绝、`MPRV=1&&MPP∈{S,U}` 时 M 访存受限；页表访问按 S 检查 | `PMPS/`、`PMPU/`、`SvPMP/`（4 个 `sv32*`） |
| 13 | PMP × 访存类型 | 取指无 X→1；load 无 R→5；store/AMO 无 W→7；`cbo.*`、LR/SC 同样检查 | `PMPZicbo/`、`PMPZaamo/`、`PMPZalrsc/`、`PMPZca/`、`PMPF/` |
| 14 | CLINT 边界 | `mtime` 与 `mtimecmp` 相差 -1/0/+1 时 MTIP 翻转；写高半的抑制行为；`msip` 写 1/0 后 `mip.MSIP` 变化 | 无现成组 → `sim/tb/tb_clint` 定向 |
| 15 | PLIC claim-complete | 多源取最高优先级、同级取最小编号；`threshold` 边界；claim 清 `pending`；complete 前不可重入；complete 后线仍高则重挂 | 无现成组 → `sim/tb/tb_plic` 定向 |
| 16 | 中断精确插入 | WFI 唤醒后 `mepc=pc+4`；`xRET` 后立即重评估；中断不破坏"被打断指令无副作用" | `InterruptsSm/cp_priority` coverpoint |
| 17 | 端到端 | OpenSBI banner → U-Boot → Linux（见 `../reports/linux-porting-report.md`） | — |

建议单元测试（`sim/tb/`）：`tb_csr_file`（表驱动全 CSR 读写）、`tb_trap_ctrl`（优先级+委托+返回）、`tb_ptw`（12 种非法 PTE 组合 + A/D CAS 竞争）、`tb_pmp`（三模式边界扫描）、`tb_clint`、`tb_plic`。

## 10. 与 `../04-csr-mmu.md` 的不一致（以本文为准）

| # | `04-csr-mmu.md` 写法 | 规范 / 本文写法 | 依据 |
|---|---|---|---|
| 1 | §2.1 把 `mip` 列在 `0x304` | `mie`=0x304，`mip`=**0x344** | `csrs.adoc:375-527` |
| 2 | §2.1 写 `mhpmcounter3..31` 从 "`0x320`+" 起 | `mcountinhibit`=0x320；`mhpmcounter3` 从 **0xB03** 起 | `machine.adoc:1521-1656` |
| 3 | §2.1 写 `pmpcfg0–pmpcfg15` | RV32 只有 0x3A0–0x3A3 存在，`pmpcfg4-15` 不存在（访问须报非法指令） | `machine.adoc:3353-3362` |
| 4 | §2.1 写 `mtvec` BASE "4 字节对齐" | 4 B 是最低要求；**Vectored 可更严**，本设计取 64 B | `machine.adoc:1211-1219` |
| 5 | §2.3 的 `mstatus` 位表与规范不符（`SPP`/`MPP`/`MPRV`/`SUM`/`MXR`/`FS`/`XS`/`SD` 行存在重复与错位，`VS` 未列） | 准确位：`SD`=31、`TSR`=22、`TW`=21、`TVM`=20、`MXR`=19、`SUM`=18、`MPRV`=17、`XS`=16:15、`FS`=14:13、`MPP`=12:11、`VS`=10:9、`SPP`=8、`MPIE`=7、`UBE`=6、`SPIE`=5、`MIE`=3、`SIE`=1 | `machine.adoc:330-352`、`images/wavedrom/mstatusreg-rv321.edn` |
| 6 | §2.3 问"`UXL/SXL` 是否在 `mstatush`" | `UXL/SXL` 只在 RV64 存在；RV32 的 `mstatus`/`mstatush` 均无，读 0 | `machine.adoc:337-341`、`supervisor.adoc:134-160` |
| 7 | §4.4 写"`rs2=0` 失效所有 ASID，`rs1=0` 失效所有地址" | 还须补充：`rs2≠0` 时 **global 表项不失效**；`rs1≠0` 时按"包含该 VA 的叶子映射"（含 4 M 大页）失效 | `supervisor.adoc:1255-1285` |
| 8 | §4.4 写 `mret/sret` 恢复 `MPRV←0` | `MPRV` **仅在返回目标≠M 时清 0**；返回 M 时保持不变 | `machine.adoc:3405-3412` |
| 9 | §5.2 写"A/D 写回通过 D-Cache 保证原子性；若写回期间异常按规范先置位再报错" | 规范要求 A/D 更新是**对 PTE 的原子读改写（CAS）**且**不得使用地址翻译缓存**；A/D 写回若违反 PMP/PMA 报**访问错误** | `supervisor.adoc:1754-1766,1849-1854` |
| 10 | §5.2/§5.3 只写"TLB 表项携带 PMP 通过标记" | 还须规定：写 `pmpcfg`/`pmpaddr` 必须失效全部 TLB（规范要求软件执行 `sfence.vma x0,x0`） | `machine.adoc:3631-3636` |
| 11 | §5.1 写"非法 PTE（V=0 或保留位非零）" | 非法组合还包括 **`R=0&&W=1`**，以及第二级仍非叶（`i<0`） | `supervisor.adoc:1732-1740` |
| 12 | §3 未定义 `mtimecmp` 写高半的抑制判据 | 写高半后若 `{new_hi,lo} < mtime` 则抑制 MTIP 至写低半，配合规范的 `-1/高/低` 序列 | `machine.adoc:2598-2612` |
| 13 | §6 写"清空 ROB 中更年轻表项" | 还须**丢弃在途 PTW 结果**（epoch 计数），并作废本次翻译建立的 TLB 表项 | `supervisor.adoc:1811-1828` |
| 14 | §2.1 `mstatus` 复位"MPP 写 10 归一到 11"未给复位值 | 本设计 `mstatus` 复位 `32'h0000_1800`（MPP=11、MIE=0），与 `00-conventions.md:30` 一致 | `machine.adoc:3371-3385` |

> 补充说明（微架构编码，不是不一致但需注意）：`02-uop-and-decode.md:49` 的 `excp_cause[3:0]` 是**微架构编码**（0=none、1=illegal_instr、2=ecall_U … 8=instr_access_fault），与架构 `mcause` 编码（2/8/9/11/0/3/12/13/15）**不同**，`trap_ctrl.v` 必须显式翻译；`uop_ctrl_t` 总长 72 bit（`[71:0]`），`excp_cause[3:0]` 占 `[67:64]`、`[68:71]` 为 `is_fence/is_fencei/is_sfence/is_serial`。
