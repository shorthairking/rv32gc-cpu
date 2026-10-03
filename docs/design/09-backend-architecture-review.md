# 09 — 后端（乱序执行引擎）架构评审

> **文档性质**：只读评审报告（纯文档任务，未改任何 RTL / 脚本 / 测试 / 其它文档）。
> **评审对象**：`rtl/back2/*`（乱序后端）+ `rtl/exec/*`（执行部件）+ `rtl/front4/front4_top.v`（派发接口）+ `rtl/top/core_top_2b.v`（顶层接线）。
> **面积基线**：`fpga/out/synth_2b_iqdep_16.667ns_utilization*.rpt` / `..._timing_summary.rpt`
> （工作区 `HEAD=408e5da`；同 RTL 的另一次综合 `synth_2b_selfchk_16.667ns_utilization.rpt` 得到**逐位相同**的 230,998 / 76,281，仅头注日期不同 ⇒ 该基线可代表当前 RTL）。
> **综合配方**：`synth_design -top core_top_2b -part xc7a200tfbg676-2 -directive RuntimeOptimized`（**非默认配方**；见 `fpga/out/synth.vivado.log:43-44`）。
> **器件**：`xc7a200tfbg676-2` = 134,600 Slice LUT / 269,200 FF / 365 Block RAM Tile（RAMB36）/ 740 DSP。
>
> **事实 / 估算分界（全文遵守）**
> - **事实**：所有带 `文件:行号` 的参数值、位宽、深度、端口数；`synth_2b_iqdep_*` 报告的原值；分析报告中被标注为"实测"的数字。
> - **估算（非事实）**：所有写作"估算 / 推算"的 LUT 收益与占比，**均未经"改后重综合"验证**。
> - **建议（非事实）**：§3 的全部解决方向。
> - **未核实**：凡未在本报告取证链内出现的数字，一律在 §5 登记，不写进结论。

---

## 0. 摘要：一句话 + 数字速览

**一句话**：这是一个**4 宽派发 / 4 宽提交、6 个分布式发射队列（总 50 槽）、6 个执行部件、整数 96 / 浮点 64 物理寄存器、ROB 64 项**的乱序后端；功能验证已全绿，但综合面积 **230,998 LUT = 器件容量的 171.62%**（超器件 71.6%），且当前 LUT 构成 **79.2% 是"宽多路选择"**（多写源写 mux / 多读口读 mux / 相等比较矩阵），不是算术也不是 FSM。

| 项 | 数值 | 出处 |
|---|---|---|
| 派发宽度 / 提交宽度 | **4 / 4** | `back2_params.vh:43-44` |
| 分布式发射队列 | **6 个**（ALU0/ALU1/BRU/MDU/LSU/FPU） | `back2_params.vh:74-79`、`backend_top.v:1109/1122/1135/1148/1181/1194` |
| 队列深度合计 | **12+12+6+6+8+6 = 50** | `back2_params.vh:74-79` |
| 每队列写口 | **4** | `back2_params.vh:81` |
| uop 载荷宽度 | **304 bit** | `back2_params.vh:231` |
| 执行部件数 | **6**（+ store 完成单独 1 个 ROB 写回口，共 **7** 个 WB 口） | `backend_top.v:1265/1272/1280/1335/1346/1381`、`:228-229`、`:1456-1462` |
| 整数 PRF | **96×32 bit，16 读口 / 6 写口** | `prf.v:26-31`、`backend_top.v:1839` |
| 浮点 PRF | **64×64 bit，8 读口 / 2 写口** | `prf.v:26-31`、`backend_top.v:1865` |
| ROB | **64 项**，项载荷 **416 bit**，窄表 `nq` **49 bit**，可更新表 `updq` **102 bit**，宽载荷 **4 bank SDP BRAM** | `back2_params.vh:29/271/281/306`、`rob.v:154/172/178/274` |
| 重命名 | RAT **32**、变更日志 **64**（每 4 条一组）、检查点 **16**、free list 数组 **128 深**、回滚快照 **64 份** | `back2_params.vh:37/51/47`、`rename.v:141-142/144-148/157/164-165` |
| LSQ | SQ **32** / LQ **16** / CDQ **8** | `back2_params.vh:93-95/107` |
| 全核 | **230,998 LUT = 171.62%**、**76,281 FF = 28.34%**、36 RAMB36 + 6 RAMB18、34 DSP | `synth_2b_iqdep_16.667ns_utilization.rpt`（Slice Logic / Memory / DSP 表） |
| 功能判据 | tb_core_top_2b **219/219**、tb_back2_iq **151/151**、锁步 **57/57**、regress **33/33**、IPC **2.0000** | `NEXT_SESSION.md:42/24` |
| 本报告列出问题数 | **7 条**（§3.1） | — |

---

## 1. 后端架构（逐项 RTL 文件:行号 + 参数值）

### 1.1 前端 → 后端接口与 D1/D2/D3 派发流水

**（a）派发块接口（前端交付 4 宽块）**

| 信号 | 含义 | 出处 |
|---|---|---|
| `blk_valid` / `blk_ready` | 块握手（块 = 4 lane） | `front4_top.v:74-75`、`backend_top.v:48-49` |
| `blk_mask[3:0]` | **4 bit 前缀掩码**（分支截断块 ⇒ 有效 lane 是 0..n−1 的前缀） | `front4_top.v:76`、`backend_top.v:50` |
| 4 lane 明细 | `lane_pc_i` / `lane_pa_i` / `lane_insn_i`（128 bit = 4×32） | `backend_top.v:53-55` |
| lane 元数据 | `lane_len32_i`、`lane_cls_i[11:0]`（每 lane 3 bit 分支类别）、`lane_ckpt_i[15:0]`、`lane_ckpt_valid_i` | `backend_top.v:56/57/72/73` |
| 预测快照（训练必须携带） | `lane_pred_taken/selg/gdir/ldir_i`、`lane_pred_target_i`、`lane_btb_hit/way/cond/call/ret_i`、`lane_btb_target_i` | `backend_top.v:58-68` |
| 前端故障 | `lane_fault_i` / `lane_fault_cause_i[19:0]` / `lane_fault_tval_i` / `fe_fetch_fault_i` | `backend_top.v:69-71/74` |
| 后端 → 前端 | `redirect_*`（类别 A 误判 / 类别 C 异常）、`train_*`、`ckpt_free_*`、RAS/D2 推送弹出 | `backend_top.v:76-104` |

**（b）流水级划分（**实测口径**：D2/D3 已塌缩为一级）**

RTL 头注如实登记：`docs/design/02-pipeline.md` §3.5–§3.7 定义 D1/D2/D3 三级，但本里程碑把 **D1（译码）单独成级，D2（重命名）+D3（派发）塌为一个派发周期**（两者停顿集合完全相同，差别只在组合深度）——见 `backend_top.v:16-18`。

| 级 | 内容 | 出处 |
|---|---|---|
| **D1** | 4 × `rtl/decode/decoder.v`（2A 既有器件只读复用）+ uop 打包 | `backend_top.v:534-575`（`generate g_d1` + `decoder u_dec`）、`:676-722`（打包）、`:410` `d1_lat_v` |
| **D1 寄存器** | `d1_v_q`（= `blk_mask_i`）+ `d1_uop_q[0:3]` | `backend_top.v:727-748`（冲刷拍清 `:733-741`、装载 `:742-744`、派发后清 `:745-746`） |
| **D2** | 整数域 `u_ren_i`（NSRC=2）+ 浮点域 `u_ren_f`（NSRC=3，第 3 源给 FMA 的 rs3） | `backend_top.v:804-820`、`:822-838` |
| **D2/D3 同拍** | `lane_fire = disp_fire_w`（整块 fire；`lane_valid` 只表示 D1 里放着这一块） | `backend_top.v:807/825`、`rename.v:70-76` |
| **D3 派发许可** | `disp_ok = 有块 & ~rn_i_busy & ~rn_f_busy & ~squash & ~flush_all & rob_alloc_ready & free_i_ok & free_f_ok & iq_room_ok & st_alloc_ok & ld_alloc_ok & ~csr_serial_w` | `backend_top.v:888-892` |
| **整块停顿** | 4 路整体停顿、不做部分派发（S3/S4/S5） | `backend_top.v:840-851`（`iq_free_ok[q] = q_wr_n[q] <= iq_cnt[q]`） |
| **I1 选择 → I2 读 PRF** | 6 个队列各自组合选择，选中项整条 304 bit 进 `x_i2_*` | `iq.v:194-211`、`backend_top.v:1235-1259` |
| **E1 / W1** | E1 执行（操作数全在 E1 读 PRF）、W1 写回/提交 | `backend_top.v:1262-1450`、`:1456-1479`、`:1480-1530` |

**（c）D3 的 6 路写口分配（每队列 ≤4 写口）**：`lane_q` 从 uop 的 `AUX_Q[2:0]` 取（`backend_top.v:758-761`），`q_wr_n[q]` 统计本块写入各队列的条数、`q_ord[lane]` 给出 lane 在该队列里的写口序号（`:763-774`），IQ 写使能必须与 `disp_fire_w` 相与（`:974`，否则同一块被反复压入）。

**（d）D1 期预译码**：每 lane 5 bit `{mret, sret, maint_kind[2:0]}` 存入 ROB 的 `nq`（`backend_top.v:893-906`、`rob.v:191-212`），提交侧因此不再读 4×32 bit 指令字。

### 1.2 发射队列 IQ（6 个分布式队列）

| 项 | 值 | 出处 |
|---|---|---|
| 数量 | **6** | `backend_top.v:1109`（ALU0）/`:1122`（ALU1）/`:1135`（BRU）/`:1148`（MDU）/`:1181`（LSU）/`:1194`（FPU） |
| 归属 | ALU0=3'd0、ALU1=3'd1、BRU=3'd2、MDU=3'd3、LSU=3'd4、FPU=3'd5、NONE=7 | `back2_params.vh:333-339` |
| **深度** | **ALU0=12、ALU1=12、BRU=6、MDU=6、LSU=8、FPU=6（合计 50）** | `back2_params.vh:74-79`（实例化覆盖 `iq` 默认值 `:38`） |
| 深度上限（参数化上界） | `BACK2_IQ_MAX_D = 12` | `back2_params.vh:80` |
| **每队列写口** | **4**（= 派发宽度） | `back2_params.vh:81`、`iq.v:43/67-69` |
| uop 载荷宽度 | **304 bit**（`UOPW = BACK2_UOP_W`） | `back2_params.vh:231`、`iq.v:39` |
| 唤醒源口数 | `WK_N = 6`（= 写回口数） | `back2_params.vh:84`、`iq.v:44` |
| 源口数 | `SRC_N = 5`（{s1i,s2i,s1f,s2f,s3f}） | `iq.v:45` |
| 出队 | **每队列每拍 1 条**（单端口，不设超发射） | `iq.v:204`（`iss_fire = sel_valid & iss_ready`） |
| 空位输出 | `free_cnt`（5 bit，深度 ≤16） | `iq.v:71/221-233` |

**（a）uop 载荷 304 bit 逐段含义（唯一真源 `back2_params.vh:112-231`）**

| 段 | bit 区间 | 宽 | 含义 |
|---|---|---:|---|
| `EXC` | [3:0] | 4 | 异常码（mcause 低位映射，2=非法） |
| `FLAGS` | [19:4] | 16 | fl0 rd_i_wen / fl1 rd_f_wen / fl2 s1_i_use / fl3 s2_i_use / fl4 s1_f_use / fl5 s2_f_use / fl6 s3_f_use / fl7 is_load / fl8 is_store / fl9 is_branch / fl10 is_csr / fl11 is_fp / fl12 is_illegal / fl13 ckpt_valid / fl14 is_unsup / fl15 is_fpls |
| `CKPT` | [23:20] | 4 | 前端检查点 id |
| `CLS` | [26:24] | 3 | 前端分支类别 |
| `BROP` | [31:27] | 5 | {is_jalr, is_jal, insn[14:12]} |
| `RM` | [34:32] | 3 | 浮点舍入模式（funct3） |
| `FPOP` | [40:35] | 6 | 归一化浮点操作码 |
| `CSRADDR` | [52:41] | 12 | CSR 地址 |
| `CSROP` | [55:53] | 3 | CSR 操作（W/S/C） |
| `WBSEL` | [58:56] | 3 | 写回来源（`WB_NONE=0`、`WB_PC4=3`，`backend_top.v:213`） |
| `MUNSIGN` | [59] | 1 | load 零扩展（lbu/lhu） |
| `MSIZE` | [62:60] | 3 | 访存宽度（**编码是 log2(字节数)**：0/1/2/3 ⇒ 1/2/4/8 B，`lsq_simple.v:376-380`） |
| `MEMOP` | [66:63] | 4 | 访存类别 |
| `ALUOP` | [70:67] | 4 | ALU 微操作（alu.v 端口口径） |
| `OPTYPE` | [74:71] | 4 | 执行部件类型 |
| `PS3F` | [80:75] | 6 | 源 3 浮点物理号（FMA） |
| `PS2F` | [86:81] | 6 | 源 2 浮点物理号 |
| `PS1F` | [92:87] | 6 | 源 1 浮点物理号 |
| `PS2I` | [99:93] | 7 | 源 2 整数物理号 |
| `PS1I` | [106:100] | 7 | 源 1 整数物理号 |
| `PDFOLD` | [112:107] | 6 | 浮点旧映射（提交时释放） |
| `PDFDST` | [118:113] | 6 | 浮点新映射 |
| `PDIOLD` | [125:119] | 7 | 整数旧映射 |
| `PDIDST` | [132:126] | 7 | 整数新映射 |
| `ARND` | [137:133] | 5 | 目的架构寄存器号 |
| `IMM` | [169:138] | 32 | 立即数 |
| `PREDTGT` | [201:170] | 32 | 预测目标（训练必须携带） |
| `TVAL` | [233:202] | 32 | 原始指令位（非法指令 mtval） |
| `PC` | [265:234] | 32 | 指令虚拟地址 |
| `PRED` | [269:266] | 4 | {pred_taken, pred_selg, pred_gdir, pred_ldir} |
| `BTB` | [271:270] | 2 | {btb_hit, btb_way} |
| `AUX` | [279:272] | 8 | [272] R 型 / [273] auipc / [275:274] fp fmt / [276] 指令 32 bit / [279:277] **目标发射队列 q** |
| `SRC` | [303:280] | 24 | {9'b0, rs3(5), rs2(5), rs1(5)} **架构号**（PSPD 段 [132:75] 是派发期重命名覆写区，`back2_params.vh:233-234`） |

> **口径提醒（本报告实测发现）**：`iq.v:24` 的注释写"载荷（uop，272 bit）"是**过期注释**；真源是 `BACK2_UOP_W = 304`（`back2_params.vh:231`）。以参数文件为准。

**（b）唤醒 / 选择 / 出队逻辑（全部组合，`iq.v`）**

1. **两代唤醒**：写回是**单拍脉冲**，队列项可能在入队当拍就被唤醒，故"当拍广播"与"上一拍广播"各自独立参与匹配（`iq.v:120-140` 寄存 `wki_v_q/wkf_v_q/wki_tag_q/wkf_tag_q`）。
2. **源级唤醒命中**：对每个 (表项 × 6 写回口 × 5 源口) 做物理号相等比较，且当拍/上一拍各做一遍（`iq.v:154-191`）。命中结果 `wk_hit` 与入队时记录的 `rdy_q` 逐位或 ⇒ `e_rdy`（`:181-189`），并**单调置位**（`:309`，无活锁）。
3. **最老优先选择**：年龄原点 = ROB 头，`e_age = rob_q[gi] − rob_head`（`:157`），选 `e_age` 最小者（`:194-202`）；`iss_fire = sel_valid & iss_ready`，出队与发射严格同一条件（`:203-211`）。
4. **窗口外永久作废**：`out_window[ge] = valid & ({1'b0,age_e} >= rob_cnt)`（`:292`），否则已提交项会占槽并被"最老优先"误判成最年轻项。
5. **冲刷作废**：`squash_kill[ge] = squash & valid & (age_e > age_sq)`（`:283-293`，年龄以 ROB 头为原点取模）；`iss_dead` **恒 0**（`:109`，错路径项已在冲刷拍作废）。
6. **入队**：`free_n = popcount(~valid_q)`，`wr_ok = free_n >= wr_need`，贪心扫描分配空闲槽（`:221-248`）；冲刷拍**不接受**新项（`:312`）。
7. **发射门控（在 `backend_top.v` 侧）**：ALU0 的 CSR 项必须已到 ROB 头（`:1051-1053`）；MDU/FPU 各自 `free`（`:1056/1103`）；LSU 的 load 需 `~lsu_iss_ok_w | csr_ld_block_w`（`:1081/1189`）；FPU 的 DYN 舍入项必须到 ROB 头（`:1101-1103`）。

### 1.3 执行部件 FU（6 个）

| # | 部件 | 功能 | 是否走 IP | 实例 | 面积（LUT/FF/DSP） |
|---|---|---|---|---|---|
| 0 | **ALU0** | 整数算术 / 逻辑 / CSR（CSR 只在 ALU0） | 否（纯 RTL） | `backend_top.v:1265` | 归入 `(u_back)` 自耗行 |
| 1 | **ALU1** | 整数算术 / 逻辑 | 否 | `backend_top.v:1272` | 同上 |
| 2 | **BRU** | 分支/JAL/JALR 判定、链接值、误判检测 | 否 | `backend_top.v:1280` | 同上 |
| 3 | **MDU** | 乘/除/取余（mul/mulh/mulhsu/mulhu/div/divu/rem/remu） | **是**：3 个乘法 IP（`rv32_mult_signed` / `rv32_mult_su` / `rv32_mult_unsigned`，各 4 DSP=12）+ 1 个除法 IP（`rv32_div`，div_gen，**LUT 实现、0 DSP**） | `backend_top.v:1335`、`mdu.v:410/416/422/487` | `u_mdu` 2,403 / 3,469 / **12 DSP**；其中 `u_div` 1,186 / 3,302 / 0 |
| 4 | **LSU** | AGU + STQ/LQ + 字节转发 + CDQ 排空 + 执行期地址翻译口 | 否（纯 RTL） | `backend_top.v:1381` | `u_lsu` 40,488 / 8,584 / 0 |
| 5 | **FPU** | FP 算术 / FMA / 转换 / 比较 / 除 / 开方（含 64 bit 访存数据源） | **是**：乘/FMA 走乘法 IP（DSP）；除/开方综合分支走 Vivado **Floating-Point Operator v7.1 (PG060)** IP（`fpu_div_sqrt.v:44-55`，实测 0 DSP） | `backend_top.v:1346` | `u_fpu` 23,265 / 7,421 / **22 DSP**（`u_mul_d` 9、`u_mul_s` 2、`u_fma_d` 9、`u_fma_s` 2） |

**写回口**：`WBP_ALU0=0 … WBP_FPU=5, WBP_STD=6`（7 个口，`backend_top.v:228-229`），`rob` 例化 `.WB_N(7)`（`:1784`）。第 7 口 `WBP_STD` 是 **store 完成口**（`lsu_st_done_v`，`:1462`），只置 ROB `done`、不写 PRF（`wbi_v` 只含 6 位，`:1478-1479`）。

- **PRF 写口** 只有 6 个（`iprf_we = wbi_v & wbi_keep`，`:1834`）；浮点写口 2 个（`:1855-1856`）。
- **写回 tag = 目的物理号**（PDIDST/PDFDST），供 ① PRF 写 ② busy 位清零 ③ 唤醒广播三处共用（`:1497-1500`）。
- **写口有效判据**是"该写回所属 ROB 项仍在窗口内"（`wbi_keep`，`:1487-1495`），**不是** epoch 比较（`prf.v:42-48` 记录了旧口径的实测缺陷）。
- 各部件另有执行期字段回写 ROB：`upd_tr`（BRU，`:1794-1795`）、`upd_ff`（FPU fflags，`:1796`）、`upd_exc`（LSU 精确异常，`:1797-1798`）；`upd_csr_valid` 因 B29 改为提交级现算而被**硬接 `1'b0`（死口）**（`:1793`）。

### 1.4 物理寄存器堆 PRF

| 域 | NREG | 读口 NRD | 写口 NW | DW | 物理号宽 | 例化参数 |
|---|---:|---:|---:|---:|---:|---|
| **整数** | **96** | **16** | **6** | **32** | 7（`BACK2_PREG_I_W`） | `prf #(.NW(6), .NRD(16), .NREG(96), .PDW(PW_I), .DW(32)) u_prf_i`（`backend_top.v:1839`） |
| **浮点** | **64** | **8** | **2** | **64** | 6（`BACK2_PREG_F_W`） | `prf #(.NW(2), .NRD(8), .NREG(64), .PDW(PW_F), .DW(64)) u_prf_f`（`backend_top.v:1865`） |

- 参数宏真源：`back2_params.vh:33-36`（`PRF_I_N=96` / `PREG_I_W=7` / `PRF_F_N=64` / `PREG_F_W=6`）。
- **模块默认值 ≠ 实例参数**：`prf.v:26-31` 的默认是 `NW=8, NRD=18, NREG=96, PDW=7, DW=32`，浮点域靠例化覆盖 ⇒ 引用时必须看例化点。
- **读口分配（事实）**：
  - 整数 16 读口 = `iprf_ra[0..10]` **11 个执行期操作数口**（uop0 ps1/ps2、uop1 ps1/ps2、uop2 ps1/ps2、uop3 ps1/ps2、uop4 ps1/ps2、uop5 ps1）+ `[11..14]` **4 个提交读口**（`cmt_narrow` 的 `PDIDST`）+ `[15]` **1 个 CSR 源口**（CSR 指令自己的 PS1I）——`backend_top.v:1817-1827`、`:1828-1831`、`:1739`。
  - 浮点 8 读口 = `[0..2]` uop5 的 ps1f/ps2f/ps3f（FMA）+ `[3]` uop4 的 ps2f（store 数据）+ `[4..7]` 4 个提交读口（`PDFDST`）——`backend_top.v:1847-1854`。
  - **全部读口恒使能**（`iprf_re = 16'hFFFF`、`fprf_re = 8'hFF`，`:1816/1846`）⇒ 读 mux 无读使能门控。
- **读口实现（事实）**：寄存器阵列 + 组合读（`prf.v:56` `reg [DW-1:0] mem [0:NREG-1]`；`:79-80` `assign rdata[gr*DW+:DW] = mem[raddr[gr*PDW+:PDW]]`）。
- **写优先旁路已删除**（`prf.v:61-76`）：原因是旁路把 `wdata` 与 `rdata` 直接连通形成**真实组合环**（Vivado 实测 101 条 `[Synth 8-326] inferred exception to break timing loop`，全部穿 `u_prf_ii_142/rdata[*]` 与 `u_backi_163/wbi_data[*]`）；结构论证是"所有操作数都在 E1 读、生产者最早 N 拍写回 ⇒ 消费者最早 N+1 拍执行"，同拍直通不需要。

### 1.5 ROB

| 项 | 值 | 出处 |
|---|---|---|
| 深度 | **`BACK2_ROB_N = 64`** | `back2_params.vh:29` |
| 索引宽 | `BACK2_ROB_IDX_W = 6`（必须 == log2(ROB_N)） | `back2_params.vh:30` |
| 提交宽度 | **4**（`BACK2_COMMIT_W`） | `back2_params.vh:44` |
| 项载荷 `RB_W` | **416 bit** | `back2_params.vh:271` |
| 窄控制字 `nq` | **49 bit**（FF 阵列，组合读） | `back2_params.vh:281`；`rob.v:154/172` |
| 可更新表 `updq` | **102 bit** | `back2_params.vh:306`；`rob.v:178` |
| 宽载荷存储 | **4 bank × SDP BRAM**（`rob_wide_mem`） | `rob.v:274-277`、`rob_wide_mem.v:28-34` |
| CSR 提交合成读口 | `BACK2_CMT_CSR_W = **79** bit` | `back2_params.vh:302` |
| 例化 | `rob #(.WB_N(7), .DBG_CSR(...)) u_rob` | `backend_top.v:1784` |

**（a）项载荷 416 bit 字段构成（`back2_params.vh:236-271`；组装点 `backend_top.v:999-1011`，**右对齐 + 高位零扩展**拼接）**

| 字段 | bit 区间 | 宽 | 备注 |
|---|---|---:|---|
| `uop` | [303:0] | 304 | 与 IQ 同一载荷 |
| `{25'b0, PS1I}` | [335:304] | 32 | 仅低 7 bit 有效（B29：提交级 CSR 源解析用） |
| `TVAL`（异常附加值） | [367:336] | 32 | |
| `TRTGT` | [399:368] | 32 | 分支实际目标（训练用） |
| `TRTAKEN` | [400] | 1 | 分支实际方向 |
| `FFLAGS` | [405:401] | 5 | FPU flags 累积 |
| `STQ idx` | [410:406] | 5 | ≤32 项 |
| `LQ idx` | [414:411] | 4 | ≤16 项（2B-5 L5 收窄） |
| 保留 | [415] | 1 | 保留位 |

- **项内 epoch 不占载荷位**：由独立 2 bit 小数组承载（原因见 `rob.v:213-216`：塞进 416 bit 载荷会让"时钟块内 7 端口读"展开成组合读森林，仿真慢 ~12×）。**注意**：`reg [1:0] rep_q [0:ROB_N-1]`（`rob.v:216`）实测**已被综合完全裁除（0 LUT / 0 FF）**，是"仅声明+注释、无读写"的死代码（`redundancy_audit.md:54-55`、`rob_tables_step1_4.md:53`）。
- **可更新字段独立成 FF 表 `updq`**：`{CSRW[31:0], TVAL[31:0], TRTGT[31:0], TRTAKEN, FFLAGS[4:0]}` = 载荷连续区间 **[405:304] = 102 bit**（`back2_params.vh:303-312`）；读取用 `merge_upd()`（`rob.v:181-188`）拼回原坐标 ⇒ 对外接口逐位不变。动机：BRAM 分 bank 后每 bank 只有 1 个写口，4 条派发写已占满（`rob.v:173-177`）。
- **`pl_q` 已删除**（`rob.v:132`），宽载荷改由 BRAM 承担。

**（b）窄表 `nq`（49 bit）字段构成**（真源 `back2_params.vh:272-300`，打包函数 `rob.v:191-212`）

| 段 | bit | 宽 | 段 | bit | 宽 |
|---|---|---:|---|---|---:|
| `done` | 0 | 1 | `arn[4:0]` | [17:13] | 5 |
| `epoch[1:0]` | [2:1] | 2 | `pdidst[6:0]` | [24:18] | 7 |
| `exc[3:0]` | [6:3] | 4 | `pdfdst[5:0]` | [30:25] | 6 |
| `is_store` | 7 | 1 | `csrop[2:0]` | [33:31] | 3 |
| `is_branch` | 8 | 1 | `trtaken` | 34 | 1 |
| `ckpt_valid` | 9 | 1 | `stq[4:0]` | [39:35] | 5 |
| `rd_i_wen` | 10 | 1 | `lq[3:0]` | [43:40] | 4 |
| `rd_f_wen` | 11 | 1 | `maint_kind[2:0]` | [46:44] | 3 |
| `is_csr` | 12 | 1 | `sret` | 47 | 1 |
| `—` | — | — | `mret` | 48 | 1 |

**（c）`rob_wide_mem`（4 bank SDP BRAM）理由（`rob_wide_mem.v:7-23`）**

- 派发每拍最多 4 条、ROB 索引**连续** ⇒ `bank = idx[1:0]` 恰好把 4 条写分散到 4 个不同 bank，**每 bank 每拍至多 1 次写，无仲裁**；头部窗口预取每拍最多 4 个新项读，索引同样连续 ⇒ 每 bank 至多 1 次读。
- 单实例 BRAM/XPM 最多 2 写口 ⇒ 4 写/拍**必须** bank 化；bank 化后每 bank 天然 1W1R，与 Simple Dual Port 一一对应（省一半端口资源）。
- 参数：`NW=4, BW=32, DW=416, AW=7, OW=5`（`rob.v:274` + `rob_wide_mem.v:28-34`）⇒ 每 bank 深度 32 × 宽 416 = 13.3 kbit。综合分支例化 **Vivado XPM `xpm_memory_sdpram`**（`rob_wide_mem.v:62-109`，`WRITE_MODE_B="read_first"`、`READ_LATENCY_B=1`），仿真分支走逐拍等价行为模型（`:117-135`）。
- **同拍写+读口径**：`read_first` ⇒ 同址读回**旧值**；本设计满足前提（窗口预取读的是"已写入 ≥1 拍"的旧项），并且对"刚分配项被预取"另加了危险判定（`rob.v:136-142`、`:453-473`）。

**（d）提交逻辑（4-wide 组提交 `cmt_chain`）**

1. 4 个槽索引 = `head + 0..3`（模 64，`rob.v:287-295`）。
2. 每槽可提交判据 `slot_ok[gi] = in_range & done & ~exc & st_ok & win_lane_ok`（`rob.v:300-307`）——其中 `win_lane_ok` 要求**头部窗口命中**（窗口未命中 ⇒ 本 lane 插气泡，**绝不交付错误 PC/tval**，`rob.v:246-255/305`）。
3. **前缀链**：`cmt_chain[0] = slot_ok[0]`；`cmt_chain[gi] = cmt_chain[gi-1] & slot_ok[gi]`；`cmt_valid = cmt_chain`（`rob.v:312-319`）。提交条数 `cmt_n_w` = popcount（`:322-329`）。
4. 提交输出：`cmt_payload`（`merge_upd(win_rd, updq)`，`:350`）、`cmt_narrow`（`nq`，`:351`）、`cmt_st_drain` / `cmt_st_ckpt` / `cmt_st_branch`（`:352-354`）。
5. **余量（提交与派发同拍：先释放再分配）**：`cnt_after_cmt = cnt − cmt_n_w`，`room_free = ROB_N − cnt_after_cmt`，`alloc_ready = room_free >= alloc_n`（`:339-342`）。★`alloc_ready` **不得**含 `alloc_valid`（会与 `disp_ok` 形成组合环，`:334-338`）。
6. 头部窗口（8 槽 `win_q`/`win_idx`/`win_val`，`rob.v:133-135`）：把 BRAM 同步读的宽载荷预取到 FF 阵列，使提交路径仍是**组合读**（零延迟）；填充与危险判定见 `:451-473`。
7. 提交侧的窄字段全部改吃 `cmt_narrow`（`nq` 组合读），宽载荷的这些位不再被读（`backend_top.v:1560` 起逐 lane `wire [BACK2_NQ_W-1:0] pn = cmt_narrow[...]`）。

### 1.6 重命名 rename（一个实例 = 一个重命名域，整数/浮点各一份）

| 结构 | 容量 | 出处（`back2_params.vh` / `rename.v`） |
|---|---|---|
| 架构 RAT `rat_q` | **32 项**（× PDW） | `back2_params.vh:37`；`rename.v:144` |
| 架构影子表 `arat_q` | 32 项 | `rename.v:145` |
| 架构引用位图 `ar_used_q` | `NREG` 位（96 / 64） | `rename.v:146`、`:501`（复位时低 32 位置 1） |
| **变更日志** `lg_arn/lg_old/lg_val` | **`RATLOG_N = 64` 条** | `back2_params.vh:51`；`rename.v:152-154` |
| 日志"每拍一组" | **`RATLOG_G = 4`**（每拍 4 条一组） | `back2_params.vh:55` |
| 日志指针宽 | `RATLOG_PTR_W = 8`（**模 256 指针**：距离 ≤64 无歧义） | `back2_params.vh:54`、`:52-53` 注释 |
| **检查点** | **`CKPT_N = 16`**（id 4 bit） | `back2_params.vh:47-48`；`rename.v:157-159`（`ck_fhead`/`ck_log`/`ck_val`） |
| **free list 数组** `flist_q` | **FL_DEPTH = 128**（FREE_I_N=64 / FREE_F_N=32 个物理号） | `rename.v:141-142/147`；`back2_params.vh:39-40` |
| free list 指针 | `FL_PTR_W = 8`（模 256），只有**数组下标**截 7 bit | `back2_params.vh:58`；`rename.v:138-141/226` |
| **按 ROB 索引的回滚快照** `rb_fhead` / `rb_log` | **各 64 项**（`[0:LOG_N-1]`） | `rename.v:164-165` |
| 例化 | `rename #(.W(4), .NSRC(2), .PDW(7), .NREG(96), .FREE_N(64)) u_ren_i`；`.NSRC(3), .PDW(6), .NREG(64), .FREE_N(32)` 浮点 | `backend_top.v:804-820`、`:822-838` |

**关键机制（事实 + 出处）**

1. **同块 RAW/WAW 前递**：目的旧映射 `ev_pd_old` 取**最近的前驱 lane**（优先级 s2>s1>s0，`rename.v:249-261`）；源物理号 `ev_pd_s` 同样取最近前驱（p2>p1>p0，`:266-281`）。RTL 注释登记了"优先级写反 ⇒ 同一物理号被释放 3 次 ⇒ free list 重复项 ⇒ 自环停顿"的实测缺陷（`:243-248/264-265`）。
2. **free list 余量（S3）**：`free_ok = free_cnt >= alloc_n`，且**不允许**把"本拍提交释放的物理号"计入可分配额度（`rename.v:293-303`）。
3. **回滚两条入口 + 共用 FSM**：① 检查点 id（`restore_valid/restore_id`）；② **任意 ROB 索引**（`restore_rob_valid/restore_rob_idx`，因前端只在"块尾预测跳转"分配检查点，块中其它条件分支误判时没有检查点）——`rename.v:20-26`、`:386-387`。
4. **回滚口径**：free list **只回退 head**（`fhead_q <= undo_fhead_w`，`:581`）；日志按绝对位置**逆序、每拍 4 条窗口**回放，窗口内"最早写入者胜"（`:386-414`、`:587-597`）。B27 试验记录（"跟随逐条递减"会 preg 泄漏）已登记并回退（`:575-580`）。
5. **全冲刷重建 FSM**：`rat_q <= arat_next`（用**含本拍提交**的架构映射，2B-5 第 2 轮修正）⇒ 逐拍扫描 `NREG` 项把未被架构 RAT 引用者压回 free list（`:547-570`）。
6. **日志条数 = 有效 lane 数**（非"消耗目的寄存器的 lane 数"），写指针按 **valid-lane rank** 推进（`rename.v:204-215/319-339/627`）。
7. **自检（CHK=1 默认开）**：分配一致性（新分配的 preg 不得仍被任何架构寄存器引用）+ 自环检查（源不得映射到自身新目的）——`rename.v:420-479`。

### 1.7 LSQ（SQ 32 / LQ 16 / CDQ 8 + 字节转发网络）

**（a）参数与例化**：`lsq_simple #(.DBG(DBG_LSU)) u_lsu`（`backend_top.v:1381-1430`）；参数真源 `back2_params.vh:93-107`：

| 参数 | 值 | 出处 |
|---|---|---|
| `STQ_N` / `STQ_IDX_W` | **32** / **5** | `back2_params.vh:93-94` |
| `LQ_N` / `LQ_IDX_W` | **16** / **4** | `back2_params.vh:95-96` |
| `MEM_TAG_W` | **5**（槽标签取 `0..LQ_N-1`，**store 排空标签取全 1** ⇒ 必须 ≥ LQ_IW+1） | `back2_params.vh:97-101` |
| `MEM_OUT_N` | = `LQ_N` = 16（MSHR 口径） | `back2_params.vh:102` |
| `CDQ_N` | **8**（= 2×W：提交口 ≤4/拍、排空口 1/拍） | `back2_params.vh:103-107` |
| 模块参数 | `W = 4`、`CDQ_PW = 3`、`ROB_IDX_W = 6`、`PDW_I = 7`、`PDW_F = 6` | `lsq_simple.v:39-50` |

**（b）STQ 字段（32 项，`lsq_simple.v:187-215`）**

`stq_v`（有效）、`stq_av`（**地址已生成**，只写一次）、`stq_dv`（数据已生成）、`stq_a[31:0]`（**虚拟地址** —— 转发比较与翻译请求的 VA 来源）、`stq_d[31:0]`（已对位到字内字节道）、`stq_dh[31:0]`（8 B store 高 4 B）、`stq_hi`（本项是 8 B）、`stq_msk[3:0]`、**`stq_rob[5:0]`（ROB 索引，★ 分配期写入）**、`stq_ret`、`stq_head_q/stq_tail_q`、`stq_pa[31:0]`（E1 预翻译 PA）、`stq_pv`（PA 有效）、`stq_ctx[3:0]`（预翻译上下文 {priv,SUM,MXR}）、`stq_bad`（提交拍口径的翻译故障）。

- 分配在 **D3 派发期**（`backend_top.v:1384-1385` `.alloc_valid(st_alloc_v & {4{disp_fire_w}})`），释放点在提交排空（`stq_ret`）。
- 提交窗"翻译定妥"门：`stq_win_w = stq_v & stq_av & ~stq_ret & (age < W)`；`stq_blk_w = stq_win & ~stq_bad & ~(~stx_en | (stq_pv & stq_ctx == ctx))`（`lsq_simple.v:240-256`）。

**（c）LQ 字段（16 项，`lsq_simple.v:494-524`）**

`ld_v`（已分配，**提交点释放**）、`ld_req`（请求已发）、**`ld_dn`（数据已齐，与 `ld_v` 分离）**、`ld_ex`（已完成 E1）、`ld_rob`、`ld_ep`、`ld_di/ld_df`、`ld_pi[6:0]/ld_pf[5:0]`、`ld_addr[31:0]`、`ld_size[2:0]`、`ld_uns`、`ld_hm[7:0]`（8 字节道转发掩码）、**`ld_hd[63:0]`（转发/响应数据）**、`ld_tag`、`ld_hi`（8 B 访问）、`ld_beat`、`ld_lo[31:0]`、`ld_mis`（8 B 非对齐 ⇒ cause 4）。

- LQ 分配器（D3 派发期）用"空闲前缀和 + 候选或归约"，语义 = 最低序号空闲槽优先（`lsq_simple.v:526-557`）；`lq_free_w = lai_fr[OUT_N]` 是**空闲总数**（注释登记了"当成占用数写反 ⇒ 挂死"的实测缺陷，`:551-553`）。
- 发射许可是"**无更老未定址 store**"：`unk_v[gv] = stq_v & ~stq_av & (age(stq_rob) < age_iss)`；`iss_ok = ~|unk_v`（`lsq_simple.v:366-373`、`:748`）。年龄基准用 **I1 候选** `i4_sel_rob`（`backend_top.v:1401`），不是"正在 E1 的那条"。

**（d）提交排空队列 CDQ（8 项，`lsq_simple.v:601-624`）**

字段：`cdq_idx[4:0]`、`cdq_a[31:0]`（VA）、**`cdq_pa[31:0]`（PA = 排空口唯一地址来源）**、`cdq_d[31:0]`、`cdq_m[3:0]`（掩码）、`cdq_v`、`cdq_pv`、`cdq_bad`、`cdq_ctx[3:0]`、`cdq_cnt`、`cdq_head/cdq_tail`。

- 动机（2B-4 修复）：`rob.v` 允许**同拍最多 4 条 store 提交**，而排空口每拍只发一笔 ⇒ 必须把"提交组内的其余 store"暂存；深度取 2×W=8 可吸收"连续两拍满组提交"的突发而无需背压（`back2_params.vh:103-107`）。
- 地址/数据/掩码**随提交拷贝进队列**：`flush_all` 清 STQ 时已提交的 store 仍能落地（架构上必须可见）（`lsq_simple.v:611-612`）。
- 8 B store 会拆成**两条** CDQ 项（`:628-629`）；余量门回送 ROB 的 `mem_wr_ready`（`backend_top.v:1802`）。

**（e）字节转发网络（`lsq_simple.v:375-477`）**

- 布局：**8 字节道 × 32 个 store 候选**（`fw_match[8*32]`）。
- 每个字节用**自己的地址**定位"哪个 4 B 字的哪一道"（`ba_w = exe_addr + gb`，`:409-411`），8 B 访问的后 4 字节落在下一个字。
- 匹配判据含 `stq_v & stq_av & (字地址相同 | 8B store 的高字) & 字节掩码 & 年龄 < age_rob`（`:416-427`）。
- **胜者 = 字内最年轻的更老匹配者**：先算每个字节的 `best_age = max over 32`（两级归约：8 组 × 组内 8 项串行链 + 组间两级，`:434-441`），再取 `age == best` 者（`:450-456`），数据用或归约（唯一胜者 ⇒ 等价于选择，`:445-447`）。
- 全转发判据按 **8 字节道掩码**：`fwd_all == lmask_w8`（`:477`）。
- 掩码编码：`exe_size` 是 **log2(字节数)**（`:376-388`）。

### 1.8 其它：训练队列 trq、epoch、CSR 提交合成、精确异常/中断通路

**（a）BPU 训练队列 `trq`（32 × 107 bit）**

| 项 | 值 | 出处 |
|---|---|---|
| 深度 | `localparam TRQ_D = 32` | `backend_top.v:2033` |
| 项宽 | `reg [106:0] trq` = **107 bit** | `backend_top.v:2034` |
| 内容 | pc[31:0] + pred_target[31:0] + target[31:0] + 11 个标志（btb_way/hit、pred_ldir/gdir/sel_global/taken/valid、is_cond/indirect/call/return、taken） | `backend_top.v:2079-2093`（★ `train_pred_valid_o` 硬接 `1'b0`，`:2093`） |
| 写/读指针与满判据 | `trq_w`/`trq_r`/`trq_cnt`；`trq_full = (trq_cnt > TRQ_D-4)` | `backend_top.v:2035-2037` |
| 入队 | 提交拍逐 lane 收集（`cmt_st_branch & cmt_ok & ~hold`），最多 4/拍 | `backend_top.v:2043-2047` |
| 出队 | `train_valid_o = (trq_cnt != 0) & train_ready_i`（**1 条/拍**） | `backend_top.v:2078` |

**（b）epoch（2 bit，冲刷递增）**

- 宽度宏：`BACK2_EPOCH_W = 2`（`back2_params.vh:61`）；ROB 侧 `epoch_q <= epoch_q + 1` 于 `flush_all` 与 `squash_valid`（`rob.v:482/484`）。
- **写回置 done 必须比"项内记录的分配时 epoch"**，不能比全局当前 epoch（否则被保留的更老在飞项永不 done ⇒ 头卡死；`rob.v:418-425`）。
- IQ 侧每项存 `ep_q`（`iq.v:118/316`）并输出 `iss_epoch`；`iss_dead` 恒 0（错路径项已在冲刷拍一次性作废，`iq.v:104-109`）。
- busy 位清零用 `wb_ep == epoch_w` 门控（`backend_top.v:1525-1530`）。
- ★ **epoch 有两份实现**：IQ 的 `ep_q`/`iss_epoch` 与 ROB 的 `nq[2:1]` 各存一份（IQ 那份是为满足 `x_i2_ep` 的**组合读**而保留的，`iss_epoch` 经 `x_i2_ep → wb_ep` 参与 ROB 置 done 的 epoch 过滤与 busy 位清零）⇒ 冗余但**有功能消费者**；`redundancy_audit.md:341` 建议用 ROB 广播的 age/epoch 位图替代（估算 −0.3k，低优先）。
- ★ **注意区分**：`iq.v:109` 的 `iss_dead` 确实恒 0，而 `backend_top.v:1251` 仍把它当 AND 项 ⇒ 那是**死与项**（可删，0 LUT），不是"epoch 没人用"。

**（c）CSR 提交合成（B29 定案口径：提交级现算）**

1. **谁在提交**：4 lane 扫描 `cmt_narrow` 找 CSR lane；`csr_dyn_idx_w = rob_head + csr_cmt_lane`（模 64）（`backend_top.v:1613-1641`）。
2. **读什么**：ROB 的单 lane 动态读口 `csr_pay = {updq.TVAL(32), updq.CSRW(32), win_q.CSRADDR(12), win_q.CSROP(3)}`（**79 bit**，`rob.v:368-371`）——注意 `CSRW` 段里装的其实是该 CSR 指令的 **PS1I**（`rob.v:1009` + `backend_top.v:1732-1736`）。
3. **源操作数**：提交拍 `iprf_rd[15]`（端口 15 的读地址 = 该 CSR 指令自己的 `ps1i`，`backend_top.v:1739`）；立即数形式（`funct3[2]` = `insn[14]`）改取 `insn[19:15]` 零扩展（`:1704-1711`）。
4. **新值合成**：`W → src`；`S → old|src`；`C → old&~src`（`:1712-1715`）。
5. **fcsr 特例**：地址 `12'h001` 用"读改写"并**并路**累积 `fflags`（`:1716-1718`）。
6. **可见性互锁**：`csr_pend_q` 跟踪"最老未提交 CSR"的 ROB 索引（无条件登记、取块内**最年轻**者、只有被跟踪那条提交才清——`:1648-1693`），据此挡住①更年轻的 load（`:1077-1081`）②更年轻的 FP（`:1090-1093`）；另加"DYN 舍入 FP 项只在 ROB 头发射"（`:1094-1103`）。
7. **CSR 串行化**：含 CSR 的块在有未提交 CSR 期间不得派发（`csr_serial_w`，`:873-891`）。

**（d）精确异常 / 中断通路**

| 环节 | 实现 | 出处 |
|---|---|---|
| 异常在头部精确抛出 | `trap_valid = slot_in_range[0] & slot_done[0] & slot_exc[0] & win_lane_ok[0]` | `rob.v:359-362` |
| 异常项**不提交** | `slot_ok` 含 `~slot_exc`（`rob.v:306`） | `rob.v:299-307` |
| 陷阱退役（弹出头部） | `trap_retire` = `trap_v_rob & trp_flush_v_i` ⇒ head 前移 1、cnt 保持 0（否则重取后又立刻再陷阱，死循环） | `rob.v:111-115`、`:479-481`；`backend_top.v:1808` |
| 整机冲刷 | `flush_all_w = trap_v_rob \| trp_flush_v_i`（`trap_halt_q` 只作观测，不再参与 flush） | `backend_top.v:1882-1891` |
| 分支误判冲刷 | `squash_v_w = x_i2_v[2] & bru_mis`；`squash_idx_w = x_i2_rob[2]` | `backend_top.v:1876-1877` |
| 回滚入口选择 | 带检查点 ⇒ `restore_ck_*`；否则 `restore_rob_*`（任意 ROB 索引） | `backend_top.v:1878-1881` |
| 重定向优先级 | 外部（陷阱/xRET）**优先于**内部分支误判 | `backend_top.v:1894-1900` |
| 冲刷拍同拍发射作废 | I2 装载要求 `~flush_all_w & ~i2_sq_kill_f(rob)`（否则错路径控制转移在 I2 复活并二次重定向，盖掉陷阱的 mtvec 重定向） | `backend_top.v:1216-1259` |
| MDU/FPU 年龄限定冲刷 | `mdu_kill`/`fpu_kill` 只杀"比 squash 点更年轻"的在飞项（否则被保留的更老项执行被冲掉 ⇒ 永无 done） | `backend_top.v:1319-1333` |
| 中断 | `int_*` 由 PLIC/CLINT 经顶层 `trap_ctrl`/`csr_file` 处理；后端只做"冲刷 + 重定向"两件事 | `backend_top.v:1770/1882-1908`（`b2_csr` 已外移到 `core_top_2b`） |

---

## 2. 各模块资源占用与占用率

**数据源**：`fpga/out/synth_2b_iqdep_16.667ns_utilization_hier.rpt`（Design State = Synthesized；表内数字为该报告原值）。
**器件容量**：Slice LUT **134,600**、Slice Register **269,200**、Block RAM Tile **365**、DSP **740**（同报告 Slice Logic / Memory / DSP 表）。
**全核**：**230,998 LUT（171.62%）/ 76,281 FF（28.34%）/ 36 RAMB36 + 6 RAMB18 / 34 DSP（4.59%）**。

### 2.1 逐模块资源表

> 列含义：`LUT` = 报告 "Total LUTs"；`占器件` = LUT/134,600；`占全核` = LUT/230,998；`FF` = 报告 FFs；
> 缩进表示层次归属（`├`/`└` 为父实例的直接子实例）。

| 实例 | 模块 | Slice LUTs | 占器件% | 占全核% | FF | RAMB36 | RAMB18 | DSP |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `core_top_2b` | `(top)` | **230,998** | 171.62% | 100.00% | **76,281** | 36 | 6 | 34 |
| ├ `u_back` | `backend_top` | **201,981** | 150.06% | 87.44% | 53,774 | **20** | 0 | **34** |
| │ ├ `u_rob` | `rob` | **42,114** | 31.29% | 18.23% | 8,001 | **20** | 0 | 0 |
| │ │ └ `u_wmem` | `rob_wide_mem` | 2,197 | 1.63% | 0.95% | 0 | 20 | 0 | 0 |
| │ ├ `u_lsu` | `lsq_simple` | **40,488** | 30.08% | 17.53% | 8,584 | 0 | 0 | 0 |
| │ ├ `u_ren_f` | `rename`（浮点域） | **24,967** | 18.55% | 10.81% | 3,345 | 0 | 0 | 0 |
| │ ├ `u_ren_i` | `rename`（整数域） | **21,204** | 15.75% | 9.18% | 3,633 | 0 | 0 | 0 |
| │ ├ `u_fpu` | `fpu` | **23,265** | 17.28% | 10.07% | 7,421 | 0 | 0 | **22** |
| │ ├ `u_prf_i` | `prf` | 15,653 | 11.63% | 6.78% | 3,072 | 0 | 0 | 0 |
| │ ├ `u_iq0` | `iq`（ALU0，深度 12） | 5,364 | 3.99% | 2.32% | 1,802 | 0 | 0 | 0 |
| │ ├ `u_iq1` | `iq`（ALU1，深度 12） | 5,380 | 4.00% | 2.33% | 1,802 | 0 | 0 | 0 |
| │ ├ `u_iq2` | `iq`（BRU，深度 6） | 4,276 | 3.18% | 1.85% | 1,220 | 0 | 0 | 0 |
| │ ├ `u_iq3` | `iq`（MDU，深度 6） | 2,302 | 1.71% | 1.00% | 524 | 0 | 0 | 0 |
| │ ├ `u_iq4` | `iq`（LSU，深度 8） | 4,801 | 3.57% | 2.08% | 1,030 | 0 | 0 | 0 |
| │ ├ `u_iq5` | `iq`（FPU，深度 6） | 2,679 | 1.99% | 1.16% | 620 | 0 | 0 | 0 |
| │ ├ **IQ×6 合计** | `iq` ×6 | **24,802** | 18.43% | **10.74%** | 6,998 | 0 | 0 | 0 |
| │ ├ `u_prf_f` | `prf` | 6,589 | 4.90% | 2.85% | 4,096 | 0 | 0 | 0 |
| │ ├ `u_mdu` | `mdu` | 2,403 | 1.79% | 1.04% | 3,469 | 0 | 0 | **12** |
| │ └ `(u_back)` **自耗** | `backend_top` 本体（含 ALU0/ALU1/BRU 与全部后端胶合） | **915** | 0.68% | 0.40% | **5,155** | 0 | 0 | 0 |
| ├ `u_front` | `front4_top` | **18,563** | 13.79% | 8.04% | 15,766 | 4 | 6 | 0 |
| │ ├ `u_bpu` | `predictor_top` | 10,124 | 7.52% | 4.38% | 12,586 | 4 | 6 | 0 |
| │ ├ `u_ifetch4` | `ifetch4` | 8,409 | 6.25% | 3.64% | 3,117 | 0 | 0 | 0 |
| │ └ `u_pc_gen4` | `pc_gen4` | 30 | 0.02% | 0.01% | 63 | 0 | 0 | 0 |
| ├ `u_tlb` | `tlb` | 3,011 | 2.24% | 1.30% | 2,886 | 0 | 0 | 0 |
| ├ `u_csr_file` | `csr_file`（`b2_csr` 已外移到此层） | 2,733 | 2.03% | 1.18% | 1,228 | 0 | 0 | 0 |
| ├ `u_l1d` | `l1d` | 2,491 | 1.85% | 1.08% | 1,265 | 8 | 0 | 0 |
| ├ `u_ptw` | `ptw` | 619 | 0.46% | 0.27% | 146 | 0 | 0 | 0 |
| ├ `u_l1i` | `l1i` | 463 | 0.34% | 0.20% | 386 | 4 | 0 | 0 |
| ├ `u_plic` | `plic` | 213 | 0.16% | 0.09% | 93 | 0 | 0 | 0 |
| ├ `u_clint` | `clint` | 137 | 0.10% | 0.06% | 129 | 0 | 0 | 0 |
| ├ `u_axi` | `axi_master_ctrl` | 35 | 0.03% | 0.02% | 59 | 0 | 0 | 0 |
| ├ `u_priv_ctrl` | `priv_ctrl` | 12 | 0.01% | 0.01% | 2 | 0 | 0 | 0 |
| └ `(core_top_2b)` **自耗** | `(top)` 本体（全部为 LUTRAM 736 + 少量胶合） | 740 | 0.55% | 0.32% | 547 | 0 | 0 | 0 |

**对账与口径说明（逐条核过）**

1. **`u_back` 直接子实例之和 = 202,400，与报告值 201,981 差 +419（+0.21%）**，属 Vivado 层次归属舍入；本表一律引用报告原值。
2. **`u_rob` 容器 ≠ ROB 本体**：容器内还挂着 `trq`、`mem`、`g_bank.u_sdp`（BRAM 包装）、`rat_q`、`cdq_a`、`mtvec_r` 等改挂逻辑（`area_analysis_2b_l1.md:186-197`、`redundancy_audit.md:84-92`）。**ALU0 / ALU1 / BRU 在层次报告里没有独立行**（被综合合并进 `(u_back)` 自耗行 915 LUT / 5,155 FF）——这正是"实例容器不可作 RTL 归因"的直接证据。
3. **`u_fpu` 是 SRL 的唯一来源**：全核 541 个 SRL 全部计在 `u_fpu` 行内（来自各乘/FMA/比较/对齐/转换管道的移位延迟，如 `u_fma_d` 92、`u_mul_d` 76、`u_cmp` 65、`u_mvd` 64、`u_fma_s` 58、`u_mul_s` 41、`u_add_d` 27、`u_add_s` 24…；注意 `u_div_sqrt` 本身 SRL=0）。
4. **`u_mdu` 的 12 个 DSP** 全部来自 3 个乘法 IP（各 4 个）；`u_div`（div_gen）1186 LUT / 3302 FF / **0 DSP**。
5. **`u_fpu` 的 22 个 DSP** 全部来自乘/FMA：`u_mul_d` 9 + `u_mul_s` 2 + `u_fma_d` 9 + `u_fma_s` 2；`u_div_sqrt`（FP Operator IP）9,009 LUT / 1,500 FF / **0 DSP**。
6. **BRAM 归属**：`u_rob` 的 20 个 RAMB36 全部来自 `u_wmem`——`rob_wide_mem` 的 `NW=4, BW=32, DW=416` ⇒ 每 bank 一字 416 bit × 深度 32 = 13.3 kbit，报告实测 **每 bank 5 个 RAMB36**（`g_bank[i].u_sdp` 各 5）⇒ **4×5=20**；`u_front` 的 4+6 来自 BPU 表（BTB 2 路共 4×RAMB36、GPHT/LPHT/选择器共 6×RAMB18）；`u_l1d` 8×RAMB36、`u_l1i` 4×RAMB36。
7. **与任务的枚举对照**：`u_back`（含 `u_rob`/`u_lsu`/`u_ren_i`/`u_ren_f`/`u_fpu`/`u_prf_i`/`u_prf_f`/IQ×6/`u_mdu`）、`u_front`（含 `u_bpu`/`u_ifetch4`）、`u_tlb`/`u_csr_file`/`u_l1d`/`u_ptw`/`u_l1i`/`u_plic`/`u_clint`/`u_axi` **全部覆盖**；额外补 `u_pc_gen4`/`u_priv_ctrl` 与两行自耗行。**`u_bru`（以及 ALU0/ALU1）在本报告中没有独立层次行**（见第 2 条）。

### 2.2 全核功能构成（事实：不是算术主导）

来自 `synth_2b_iqdep_16.667ns_utilization.rpt` 的 Slice Logic 表：

| 项 | 值 | 占比 / 说明 |
|---|---:|---|
| LUT as Logic | 229,721 | 99.4% 的 LUT 是组合逻辑 |
| LUT as Memory | 1,277 | 736 Distributed RAM + 541 Shift Register |
| Slice Registers | 76,281（28.34%） | — |
| F7 Muxes | 22,822（33.91%） | LUT 之上的 mux 级；**宽多路选择的直接指纹** |
| F8 Muxes | 6,785（20.16%） | 同上 |
| Block RAM Tile | 39 / 365（10.68%） | 36 RAMB36 + 6 RAMB18 |
| DSPs | 34 / 740（4.59%） | MDU 12 + FPU 22 |

**读法**：F7/F8 mux 合计 29,607 个，配合"Top-20 结构 18 项是多写源写 mux / 多读口读 mux / 相等比较矩阵"（`area_analysis_2b_l1.md:306-307`），说明面积主体是**宽度 × 端口数**，而非条目数或算术。

### 2.3 信号级大头（补充；**必须按时点/口径引用**）

`area_analysis_2b_l1.md` §5 的 Top-20 是 **L1 后（318,933 原始 LUT 桶）** 的口径；`rob_tables_step1_4.md` §1 给出的是**当前基线（`post_synth_2b_iqdep`）**的少数实测探针值。两者**不可混用**（`area_analysis_2b_l1.md:316-318`）。

| # | 结构（信号名） | LUT（原始桶） | 时点 / 口径 | 类型 | 出处 |
|---|---|---:|---|---|---|
| 1 | `uop_q` 家族 | **46,007**（14.4%） | L1 后（ΣDEPTH=68） | 多写源写 mux + 出队读 mux | `area_analysis_2b_l1.md:284` |
| 2 | `mem`（通用名，混 PRF 与 FPU 阵列） | 35,332（11.1%） | L1 后 | 多读口读 mux | `area_analysis_2b_l1.md:285` |
| 3 | `updq` | 21,501（L1）→ **11,055（实测）** | L1 后 / **当前基线探针** | 多写源写 mux | `area_analysis_2b_l1.md:286`；`rob_tables_step1_4.md:44-65` |
| 4 | `ld_hd` | 17,888（5.6%） | L1 后 | 32:1 读/写 mux（64 bit） | `area_analysis_2b_l1.md:287` |
| 5 | `flist_q` | 17,043（L1）→ 自身约 3k（L8 后） | L1 后 / L8 后 | 256:1 → 128:1 读 mux | `area_analysis_2b_l1.md:288`；`NEXT_SESSION.md:37` |
| 6 | `cdq_pa/cdq_d/cdq_a/cdq_m` | 14,042（4.4%） | L1 后 | 多写源写 mux（**深度仅 8**） | `area_analysis_2b_l1.md:289` |
| 7 | `nq` | 13,035（L1）→ **7,246（实测）** | L1 后 / **当前基线探针** | 多写源写 mux + 读 mux | `area_analysis_2b_l1.md:290`；`rob_tables_step1_4.md:44-65` |
| 8 | `lg_old`+`lg_arn`+`lg_val` | 11,195（3.5%） | L1 后 | 128 深多口阵列 | `area_analysis_2b_l1.md:291` |
| 9 | `rdy_q` | 11,035（3.5%） | L1 后（三点 11,035/11,246/11,548，**与深度无关**，FF 340） | 相等比较矩阵 | `area_analysis_2b_l1.md:292`；`redundancy_audit.md:145-153` |
| 10 | `rat_q`+`arat_q` | 10,956（3.4%） | L1 后 | 多写源写 mux + 读 mux | `area_analysis_2b_l1.md:293` |
| 11 | `trq` | 9,775（3.1%） | L1 后 | 32×107 bit 队列多读写 mux | `area_analysis_2b_l1.md:294` |
| 12 | `stq_d/dh/pa/a/rob` | 8,532（2.7%） | L1 后 | 多写口 + 转发读 mux | `area_analysis_2b_l1.md:295` |
| 13 | `d1_uop_q` | 8,025（2.5%） | L1 后 | uop 寄存器写 mux（4×304 bit） | `area_analysis_2b_l1.md:296` |
| 14 | `rb_log` | 6,383（2.0%） | L1 后 | 阵列 mux（L1 前 76,749 ⇒ 见 §4.2） | `area_analysis_2b_l1.md:297` |
| 15 | `rb_fhead` | 5,372（1.7%） | L1 后 | 写 4 口 + 动态读 | `area_analysis_2b_l1.md:298` |
| 16 | `FSM_sequential_st` | 4,100（1.3%） | L1 后 | FSM 组合锥（**未定位到模块**） | `area_analysis_2b_l1.md:299`、`:337` |
| 17 | `lht_mem` | 3,855（1.2%） | L1 后 | 1024:1 读 mux（本应落 RAMD64E） | `area_analysis_2b_l1.md:300` |
| 18 | `c_q0` | 3,339（1.0%） | L1 后 | FPU 转换/舍入 mux | `area_analysis_2b_l1.md:301` |
| 19 | `u_xpm` | 2,745（0.9%） | L1 后 | 未映射 BRAM 的读 mux（`u_mem1`/`u_mem0` 170× 异常） | `area_analysis_2b_l1.md:302`、`:251-252` |
| 20 | `lru_q` | 2,464（0.8%） | L1 后 | BTB LRU 位读写 mux | `area_analysis_2b_l1.md:303` |
| — | **Top-20 合计** | **252,624（79.2%）** | L1 后 | — | `area_analysis_2b_l1.md:304` |
| 补 | `win_q`（8 槽头部窗口） | **822 / FF 608** | **当前基线探针** | 名义 8×416 bit；综合已裁未读位 | `rob_tables_step1_4.md:44-53` |
| 补 | `pl_q` / `rep_q` | **0 / 0** | **当前基线探针** | `pl_q` 已进 BRAM；`rep_q` 无读写被裁 | `rob_tables_step1_4.md:53` |

---

## 3. 当前问题与成因 + 解决思路

### 3.1 问题清单（7 条，每条带证据行号）

#### ① uop 304 bit 逐级只消费一部分：≈89 bit 属"单级消费"却全程携带；RB 416 bit 仅 ≈126 bit 被读

- **事实（uop 304 bit 消费表）**：只在单级消费却全程携带的字段合计 **≈89 bit**——`ARND(5)`+`SRC1/2/3(15)` 只用 D2；`TVAL(32)` 只用 D3；`CSROP(3)`+`CSRADDR(12)`+`CKPT(4)`+`CKPT_VALID(1)` 只用 W1；`PDIOLD(7)`+`PDFOLD(6)`+`EXC(4)` 在 uop 路径 **0 读**（`redundancy_audit.md:220-263`）。
- **事实（零引用死字段）**：`BTB(2)`、`IS_FP/IS_ILLEGAL/IS_UNSUP(3)`（宏存在但全仓库 0 引用）⇒ ≈5 bit（`redundancy_audit.md:248/257/264`）。
- **事实（RB 416 bit）**：被读出的位合计 **≈126 bit**（PC32 + PDIOLD7 + PDFOLD6 + CKPT4 + CLS3 + STQ5 + FFLAGS5 + TRTGT32 + TVAL32），且 **[405:304] 这 102 bit 结构上永不参与输出**（`merge_upd()` 只取 `pl[415:406]`+`updq`+`pl[303:0]`）⇒ 416 bit 里约 70% 不被消费（`rob.v:181-188`、`redundancy_audit.md:291-295`）。
- **成因**：IQ 与 ROB 在派发期各自整条存 304 bit（`iq.v:115-116`、`rob.v:999-1011`），4 写口 × 304 bit × 深度 ⇒ `uop_q` 家族是**全核信号名口径第一名**（46,007，`area_analysis_2b_l1.md:284`）。
- **★但必须同时记住的反证（事实）**：综合**已经**把"存了不读"的位裁掉了——IQ `uop_q` 名义 68×304=20,672 FF，**实测只有 9,043 FF（44%）**；ROB `win_q` 名义 8×416=3,328 FF，**实测只有 608 FF（18%）**（`redundancy_audit.md:63-67`）。因此"按名义位宽算收益"会系统性高估（L1 之前的教训）。

#### ② 唤醒矩阵是纯组合的相等比较器阵列（LUT 大头之一，FF 极少）

- **事实**：`iq.v:154-191` 对**每个表项 × 每个写回口 × 每个源口**做物理号相等比较，且当拍广播与上一拍广播**各做一遍**（`:159-173` 的 `||`）。比较器数量 = ΣDEPTH × WK_N(6) × SRC_N(5) × 2：
  - LQ16 时点 ΣDEPTH=68 ⇒ **4,080 个比较器**（`redundancy_audit.md:145-153`；`group_rob_feasibility.md:51`）。
  - **C2 后 ΣDEPTH=50 ⇒ 同式推算 3,000 个**（推算，非实测；深度宏见 `back2_params.vh:74-79`）。
- **事实（量级与"与深度无关"）**：`rdy_q` 家族在 L1→ROB64→LQ16 三个检查点实测 11,035 / 11,246 / 11,548 LUT，**完全不动**；FF 仅 **340**（`redundancy_audit.md:152-153`）⇒ 纯组合、比较器阵列约 8k（估算），写入 mux 约 1k。
- **成因**：设计选了"唤醒当拍即可选"（`iq.v:22-23` 头注），代价是把 tag 比较全部展开成组合比较器。

#### ③ PRF 16 读口 × 96:1 组合读 mux（整数）+ 8 读口 × 64:1（浮点）

- **事实（读口数）**：整数 16（11 执行期 + 4 提交 + 1 CSR，`backend_top.v:1817-1831`/`:1739`）、浮点 8（4 执行期 + 4 提交，`:1847-1854`），且**全读口恒使能**（`:1816/1846`）。
- **事实（实现与量级）**：`prf.v:56/79-80` 是触发器阵列 + 组合读 ⇒ 整数侧 **512 个 96:1 组合读 mux**（16 口 × 32 bit），浮点侧 **512 个 64:1**（8 口 × 64 bit）；`u_prf_i` 容器 MUXF7+MUXF8 = **7,072（占其 raw LUT 19,094 的 37%）**、LUT6 13,606（71%）；`u_prf_f` MUXF = 3,461（raw 7,905 的 44%）（`area_analysis_2b_l1.md:257-268`）。
- **成因**：`NREG` 深 × 读口多 × 组合读（无读使能门控、无打拍共享）⇒ 面积由"宽度 × 口数"决定。

#### ④ LSQ 字节转发网络：全展开的比较/加法/max 树

- **事实**：`lsq_simple.v:404-474` 是 **8 字节道 × 32 store 候选**的全展开网络：
  - `:416` 30 bit 等值比较 + `:417-418` **32 bit 高字地址加法（8×32 = 256 份源码重复）**；
  - `:422-424` 年龄表达式**每对算 2 次（8×32×2 = 512 份）**（`redundancy_audit.md:121`）；
  - `:434-441` "32 项取 age 最大者"：**256 个 8 bit 比较 + 256 个 8 bit mux**；
  - `:450-456` `fw_sel` **256 × 8 bit 等值比较**（`redundancy_audit.md:174-186`）。
- **量级（估算）**：`u_lsu` 容器 raw 48,324 减去已命名阵列（`fwdp_data` 15,085 + `cdq_*` 14,376 + `ld_hm` 3,367 + `stq_pa` 1,222 + `stq_rob` 507 + `mem` 2,750 + `updq` 1,941 + `ld_lo` 708 + `nq` 444 + `lq_of_rob` 490）⇒ **≈5.5k LUT 属于转发选择树 + 分配候选 + 年龄链**（`redundancy_audit.md:184-186`）。
- **成因**：转发语义要求"同字节取**最年轻的更老匹配者**"，实现选择了"逐字节 × 逐 store 全展开 + max 归约 + 相等回选"，而非优先编码器扫描。

#### ⑤ ROB `nq` + `updq` ≈18.3k 是"写口结构死重量"

- **事实（量级）**：**当前基线实测** `nq` = 7,246 LUT / 2,368 FF，`updq` = 11,055 LUT / 4,864 FF ⇒ **合计 18,301 LUT = `u_rob` 的 43.5%、全核的 7.9%**（`rob_tables_step1_4.md:44-65`）。
- **成因（写口不可合并）**：三个"执行期回写"口 `upd_tr`（BRU/I2 级）、`upd_ff`（FPU 完成级）、`upd_exc`（LSU 完成级）**可以同拍有效且命中互不相同的 ROB 索引**，写的是互不重叠的位域 ⇒ 冲突只在**端口/地址**层，**合并成 1 个写口物理上不可行**（单写口存储一拍只能接受一个写地址）（`rob_tables_step1_4.md:21/71-100`；写源与端口见 `rob.v:434-449`、`backend_top.v:1773/1779/1796-1797`）。对照 `rob_wide_mem` 能 bank 化，是因为 **alloc 的 4 个索引连续**（`bank = idx[1:0]`，`rob_wide_mem.v:7-14`）——`upd` 三口**不具备这个性质**，这正是它们当初落在 FF 表 `updq` 的根本原因（`rob.v:173-177`）。
- **事实（两个已试过的"更差"路线）**：
  - `done` 位独立成 bitmap：**实测净回归 +1,187 LUT**（全核 230,998→232,185，对照运行噪声底 = 0）——`done` 原本与另外 48 bit 共用同一份"端口×条目"地址译码，拆出后 bitmap 必须**复制**该译码（7 置位口 × 64 条目比较 + 4 清零口），新增 `done_bitmap` 单元 **882 LUT / 64 FF / 307 MUXF**（`rob_tables_step1_4.md:22/122-130/169/192-196`）。已回退（`299216e` 仅保留自检 `ifdef` 化，面积中性）。
  - `updq`→BRAM **不可取**：102 bit 里**只有 TVAL(32) 与 PS1I(7) 在派发期有真值，其余 63 bit 是常量占位**（`backend_top.v:1000-1008`），真值全靠 3 个稀疏写口 ⇒ 迁 BRAM 立刻撞上"三任意索引写口"（`rob_tables_step1_4.md:250-270`）。
- **`upd_csr` 是死口**：`backend_top.v:1793` 硬接 `.upd_csr_valid(1'b0)`（`upd_csr_v` 在 `:1774` 算出但未接出）（`rob_tables_step1_4.md:80`）。

#### ⑥ RB 载荷 416 bit 仅 ≈126 bit 被消费（≈70% 不读），其中 102 bit 结构上永不读

- 见 ① 的 RB 部分。**BRAM 侧的特殊性（事实）**：`win_q` 的 FF 被综合裁到 608（≈76 bit/槽），但 **`rob_wide_mem` 的 `DW=416` 是 XPM 参数、不会被裁** ⇒ 4 bank × 416 bit 占 **20 个 RAMB36**（`rob_tables_step1_4.md:50`、`rob_wide_mem.v:31`）。⇒ 此处**LUT 收益小、BRAM 收益明确**（`redundancy_audit.md:298-301`）。

#### ⑦ 组合环与超长组合锥（时序）

- **事实（组合环）**：L1 前基线轮综合日志 `fpga/out/synth.vivado.log` 有 **22 条** `CRITICAL WARNING [Synth 8-295] found timing loop`（均报在 `rtl/top/core_top_2b.v:64` 模块头），随后 **13 条** `[Synth 8-326] inferred exception to break timing loop`：其中 8 条穿 `alloc_valid0[0..3]`/`lalloc_valid0[0..3]`（**派发/分配握手**）、4 条穿 `u_robi/cmt_chain_3[0]`、1 条穿 `ptw_req_ready_w`（`area_analysis_2b.md:224`）。
  - **当前工作区最新一次综合日志**（`2b_selfchk` 轮，**与 iqdep 基线不同轮**）实测 **27 条 timing loop / 7 条推断假路径**，推断例外点为 `u_lsu/lalloc_ok`、`u_lsu/alloc_ok`、`u_robi/cmt_chain_3[0]`（`fpga/out/synth.vivado.log:1968+`、`:2538-2544`；`fpga/scratch/synth_2b_selfchk.stdout.txt` 记 27 Critical Warning）。**iqdep 基线轮**的 loop 计数本报告**未单独取证**。
- **事实（超长组合锥）**：
  - L1 前基线：PLIC→E1 使能锥 **138 级**，源 `u_plic/threshold_r_reg[1][1]/C` → 目标 `u_back/x_i2_ep_reg[1][0]/CE`，WNS **−62.876 ns**，**167,410 个 setup 失败端点**（`area_analysis_2b.md:225`；`fpga/out/synth_2b_16.667ns_timing_summary.rpt:195-212`）。
  - **当前基线**：WNS **−55.107 ns**、失败端点 **70,956**、最差路径 **125 级**（`CARRY4=14 LUT2=20 LUT3=12 LUT4=18 LUT5=24 LUT6=36 MUXF7=1`），源/目标仍是**同一类 PLIC→E1**：`u_plic/threshold_r_reg[1][1]/C` → `u_back/x_i2_ep_reg[0][0]/CE`（`fpga/out/synth_2b_iqdep_16.667ns_timing_summary.rpt:195/203/212-213`）。
- **成因（结构）**：`x_i2_*` 的时钟使能来自"6 个队列的组合选择结果"（`iq.v:194-211` → `backend_top.v:1235-1259`），而选择就绪又依赖写回唤醒（比较器阵列）与大量外部门控（CSR 可见性、STQ 闸门、CDU 余量）⇒ 从 PLIC 阈值寄存器一路组合穿到 I2 装载使能。

### 3.2 解决思路（**建议，非事实**）——主推方向 A

> **本节全部为"建议（非事实）"**：收益均为估算、**未经改后重综合验证**；风险等级按"改动面 × 验证重标定成本"给出。
> **边界**：以下方向都在既有 **4 宽派发 / 4 宽提交 / 6 执行部件 / 4 写口每队列** 的指标上做面积与时序优化，**不改动任何宽度类指标**。

#### 方向 A：IQ 只存"唤醒 + 发射所需窄字段"，执行期宽字段改由 ROB 宽存储按 rob 索引提供

**针对问题**：①（uop 304 bit 全程携带）、部分 ⑥。

**事实依据**
- IQ 每项真正参与"唤醒 + 发射判定 + I2/E1 取数"的字段只有：`PS1I/PS2I`(14) + `PS1F/PS2F/PS3F`(18) + 5 个 `*_USE` + `IS_LOAD`/`IS_CSR` + `AUX_Q`(3) + `rob_idx`(6) + 就绪位 = **约 45 bit**（字段定义 `back2_params.vh:87-106/142-157/224-225`；消费点 `iq.v:159-188`、`backend_top.v:1051/1081/1101/1262-1379`）。
- 宽字段（IMM/PC/PREDTGT/ALUOP/OPTYPE/MEMOP/MSIZE/MUNSIGN/WBSEL/FPOP/RM/BROP/CLS/FLAGS/PRED）只在 **E1** 被读（`redundancy_audit.md:220-258` 的消费表），而 ROB 已经存着**同一批位的完整副本**（`rob.v:999-1011` 组装的 RB 载荷含整个 uop）。
- 供给侧已有可复用结构：`rob_wide_mem`（4 bank SDP BRAM，同步读 1 拍）或 `win_q` 的 FF 窗口模式（`rob_wide_mem.v:7-23`、`rob.v:246-255`）。

**方案骨架（建议）**
1. IQ 槽收窄为 {`ps1i`,`ps2i`,`ps1f`,`ps2f`,`ps3f`, `s1i/s2i/s1f/s2f/s3f_use`, `is_load`, `is_csr`, `rob_idx`, `rdy_q`, `valid`}（≈45 bit）。
2. 发射（I1 选中）后，用该 `rob_idx` 从 ROB 宽存储**同步读**出宽字段（+1 拍）⇒ I2 拆为 **I2a（读 PRF + 读宽字段）/ I2b（组装执行输入）**，或在 IQ 与 E1 之间插入一级流水。
3. 窄字段仍需**在 IQ 内**（唤醒与发射门控不能等 ROB 读）。

**收益量级（估算，非事实）**
- `uop_q` 家族是全核信号名口径第一名（46,007，L1 口径 ΣDEPTH=68，`area_analysis_2b_l1.md:284`）；`redundancy_audit.md` C1 估 **−15~25k LUT**（该估算按 68 项算）。按 C2 后 ΣDEPTH=50/68 = 0.735 线性折算 ⇒ **本人推算 ≈ −11~18k LUT**（**推算，非实测**；综合已裁未读位，实际折扣可能更大）。
- 附带：IQ 写口 mux（4 × 304 bit × 深度）同步变窄。

**风险（高）**
- **时序/流水**：I2 多一级或读口追加同步读，会改变 `x_i2_*` 的装载时刻 ⇒ §3.1⑦ 的 PLIC→E1 锥可能反而变长或需要重排；60 MHz（16.667 ns）约束下 WNS 当前 −55.107 ns，任何一级流水都要重新做 STA。
- **接口面**：`iq.v` + `rob.v` + `backend_top.v` 三处接口/时序同时改；唤醒-选择-读寄存器二级拆分（`02-pipeline.md` §3.9 的 I1/I2 口径）需重写。
- **验证重标定**：四套判据（219/219 + iq 151 + 锁步 57 + regress 33）与 IPC=2.0000 全部需重跑；`iq` 单测的 6 个实例参数钉法（`NEXT_SESSION.md:35` 记录过 `ROB_IDX_W` 钉法）需同步。

### 3.3 解决思路（**建议，非事实**）——主推方向 B

#### 方向 B：唤醒矩阵去冗余（注册一拍 `wk_hit` + 写回侧位图查询）

**针对问题**：②。

**事实依据**
- 现在"当拍广播"与"上一拍广播"各比一遍（`iq.v:159-173` 的 `||`）⇒ 比较器数**翻倍**。
- `rdy_q` 家族实测 11,035→11,548 LUT（三点完全不动）、**FF 仅 340** ⇒ 阵列纯组合，而 FF 余量充足（76,281 / 269,200 = 28.34%）。

**方案骨架（两条可独立、也可叠加；建议）**
1. **去掉 `_q` 半份**：把 `wk_hit` 结果**注册一拍**（ΣDEPTH × SRC_N = 50×5 = **250 FF**，与现有 `rdy_q` 同量级），让"上一拍唤醒"通过寄存器命中结果生效，而不是再比一遍 tag（`redundancy_audit.md:156-158` 的同一思路）。
2. **共享写口位图**：写回侧每拍生成 `wr_mask[5:0][95:0]`（6×96 = **576 FF**），IQ 每项直接查 `wr_mask[k][psX]`（96:1 mux ≈ 7 LUT）——估算 50×5×7 ≈ 1.8k LUT，替代原 ~8k 比较器阵列（`redundancy_audit.md:159-161` 给出 68 项下的 ~2.5k + 0.6k 口径）。
3. （可选）**按队列裁剪 `WK_N`**：LSU/FPU 队列实际只需其写回子集，按队列参数化可再按比例减排（`redundancy_audit.md:162-163`）。

**收益量级（估算，非事实）**：`redundancy_audit.md` 综合估 **−3~6k LUT**（68 项口径）；按 C2 后 50 项的线性折算 ≈ **−2.2~4.4k LUT**（**推算，非实测**）。

**风险（中）**
- **正确性 = 功能正确性**：唤醒漏一拍会让队列项永不就绪（`iq.v:124-127` 记录了"只比当拍广播 ⇒ 漏唤醒 ⇒ IQ 抽空、后端停摆"的实测缺陷）。必须 iq 151 + 锁步 57 + 219 全绿。
- **时序**：位图必须在**与 tag 同拍**可用（`redundancy_audit.md:161` 的注意事项）；位图生成在写回侧，可能把锥从 IQ 搬到写回侧，需 STA 复核。
- **改动面**：仅 `iq.v`（+ 可选 `backend_top.v` 的写回侧）⇒ 比方向 A 小一个数量级。

### 3.4 备选方向（简表，**建议，非事实**；未列为本报告主推）

| # | 方向 | 针对问题 | 估算收益（原文口径） | 风险 | 出处 |
|---|---|---|---|---|---|
| C6 | LSQ 转发网络重写：优先编码器替代 max-age 树 + per-entry 年龄向量 + 高字加法器移出字节循环 | ④ | −1.5~3k LUT | 中低（fwd 用例 + 锁步） | `redundancy_audit.md:188-196/355` |
| C9 | 源码级 uop 字段裁剪（单级/死字段移出 IQ/ROB 载荷） | ① | −1~3k LUT（**不是** 89/304×46k） | 低中（接口重排 + 回归） | `redundancy_audit.md:266-269/358` |
| C7 | `trq` 32→16（提交 4/拍，需训练侧 ≥2/拍排空） | 其它 | −1.5~2k LUT / −1.1k FF | 低中（BPU 准确率回归） | `redundancy_audit.md:340/356` |
| C4 | RB 载荷裁剪到"被消费的位"（`RB_W` 416→~200） | ⑥ | BRAM36 20→8~10；LUT −0.4~0.9k | 中（位域四处同步） | `redundancy_audit.md:298-301/353` |
| C8 | 年龄比较收敛到 ROB 单点 + `in_win` 位图广播 | ⑦（缺陷预防） | −0.5~1.5k LUT | 低 | `redundancy_audit.md:132-143/357` |
| — | `updq` 读口按"实际消费"裁剪（不动存储介质） | ⑤ | −1.1~2.1k LUT | 低中 | `rob_tables_step1_4.md:260-270` |
| — | 回滚快照 `rb_fhead`/`rb_log` 按 4-lane 边界压缩 | ①（间接） | −3~4k LUT / −1.5k FF | 中低 | `group_rob_feasibility.md:81/128-133` |
| C10 | 死代码清理（`iq.v` `sel_blk` O(DEPTH²)、`iss_dead`、`rob.v` `rep_q`） | 维护性 | **0 LUT**（实测已剪除） | 极低 | `redundancy_audit.md:50-57/359` |

> **注**：上表收益全部为**估算**；`group_rob_feasibility.md:48-49` 明确"剩余全部杠杆合计估 −28~51k LUT ⇒ 落地约 134~151% 占用"，即**仅靠消冗余 + 降宽/降口，无法到 ≤100%**。该结论是事实层面的量化，供用户做下一步决策（本报告不评估任何改变宽度类指标的路线）。

---

## 4. 补充说明

### 4.1 已验证的等价性 / 性能基线

**功能判据（"深"口径，`NEXT_SESSION.md:42`）**

| 判据 | 结果 | 规模 / 备注 | 出处 |
|---|---|---|---|
| `tb_core_top_2b` | **219/219** | 整核定向用例 | `NEXT_SESSION.md:24/42` |
| `tb_back2_iq` | **151/151** | 发射队列单测（6 个实例） | 同上 |
| `tb_back2_lockstep` | **57/57**（821 条提交，top = `tb_back2_lockstep_top`） | 与 Spike/2A 黄金轨迹逐条锁步 | 同上 |
| regress | **33/33 PASS** | RTL 全量 = `scripts/env.sh` 的 `rv32_rtl_sources`（58 文件） | 同上 |
| LSQ 转发专测 | `fwd 10/10` | 2B-3 起 | `NEXT_SESSION.md:17` |

**性能基线**

| 项 | 值 | 出处 |
|---|---|---|
| IPC | **2.0000**（6000 条 / 3000 拍） | `tb_back2_ipc`；`NEXT_SESSION.md:17/24` |
| 三程序锁步拍数 | C1–C5 全绿：161/178/126 条、**443/721/913 拍**，CHK 零违规、无停顿 | `NEXT_SESSION.md:17` |
| C5 分档阈值（下限） | 源记 **0.30 / 0.19 / 0.1094**（带 **≥26% 裕量**；台账只登记了这三个下限值） | `NEXT_SESSION.md:17` |
| 每次面积杠杆后的复测 | L3 / L5 / L8 / C2 后均"IPC=2.0000、C5 无阈值跌破"（C2 仅 p3_fpu +1 拍） | `NEXT_SESSION.md:35-38` |

**综合口径**：统一经 `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667`，2B 用 `RV32_SYNTH_TOP=core_top_2b RV32_SYNTH_DIRECTIVE=RuntimeOptimized`（`NEXT_SESSION.md:42`）；宏 `RV32GC_USE_VIVADO_IP` 只由综合脚本定义（`fpga/out/synth.vivado.log:43/2933`）。

### 4.2 面积演进史（7 个已落地杠杆，全部四套判据绿 + 母 Agent 复跑）

| # | 杠杆 | commit | LUT | ΔLUT | FF | 占用率 | 出处 |
|---|---|---|---:|---:|---:|---:|---|
| 起点 | 2B-4.45（ROB BRAM 化后） | `b13e4cc` 一带 | 366,483 | — | 129,899 | 272.28% | `NEXT_SESSION.md:24/46` |
| **L1** | `rename.v` 的 `LOG_PTR_W` 由 `RATLOG_N`(128) 改 `RATLOG_PTR_W`(8)（**1 行参数错绑**：`rb_log`/`ck_log` 位宽 128→8） | `ee99f84` | **292,397** | −74,086（−20.22%） | 95,150 | 217.23% | `NEXT_SESSION.md:34`；细节 `area_analysis_2b_l1.md:22-26` |
| **L3** | ROB_N/RATLOG_N 128→64、ROB_IDX_W 7→6 + 全部年龄算术改"模 N 精确年龄序" | `5b2e35e` | **256,345** | −36,052（−12.33%） | 83,303 | 190.45% | `NEXT_SESSION.md:35` |
| **L5** | LQ_N 32→16（索引 5→4、`MEM_TAG_W` 6→5、`RB_LQ_MSB` 415→414）+ `nq` 4 宏同步 | `b8a2675` | **253,748** | −2,597（−1.01%） | 80,408 | 188.52% | `NEXT_SESSION.md:36` |
| **L8** | `flist_q` 数组深度 256→128（`FL_PTR_W` 恒 8、下标截 7 bit） | `0acdb01` | **239,418** | −14,330（−5.65%） | 78,667 | 177.87% | `NEXT_SESSION.md:37` |
| **C2** | 6 个 IQ 深度 16/16/8/8/12/8（**68 > ROB_N=64 有死容量**）→ **12/12/6/6/8/6 = 50** | `1df7252` | **230,998** | −8,420（−3.52%） | 76,281 | **171.62%** | `NEXT_SESSION.md:38` |
| — | ROB 控制表 `done` bitmap（**实测净回归，已回退**）+ 自检 `ifdef` 化（面积中性） | `299216e` | 230,998 | ±0 | 76,281 | 171.62% | `NEXT_SESSION.md:46`；`rob_tables_step1_4.md:22/169` |
| **合计** | — | — | **−135,485** | **−36.96%** | −53,618 | 272.28%→171.62% | 上列相加 |

**每条杠杆学到的可推广口径（事实，均来自项目自记）**
1. **L1**：收益 100% 来自一处位宽错绑的完整偿还（`rb_log` −70,366 + 回滚锥 −8,949），**其余结构一个都没变小**（`area_analysis_2b_l1.md:162-164`）。
2. **L5**：**小 mux 降深只省 FF**（LQ 32:1 只 −1.0% LUT），因为 LUT 大头在宽度/端口而非条目数（`NEXT_SESSION.md:36`）。
3. **L8**：**大 mux（256:1）降深给超线性收益**（`flist_q` 自身 ~17k→~3k）；"降深换 LUT"只在 mux fan-in 大时有效（`NEXT_SESSION.md:37`）。
4. **C2**：先把 IQ 总容量从 68 收到 ≤ROB_N=64（超出的槽结构性不可能填满）⇒ 纯容量缩减、零语义变化（`back2_params.vh:63-73`）。
5. **贯穿三条**：实例容器数字**不能**作 RTL 归因（`u_rob` −33.3k、`u_prf_i` −5.4k、新出现 `u_bru` 2,658 都不是对应 RTL 的改动）（`area_analysis_2b_l1.md:331-333`）。

### 4.3 口径提醒（引用任何面积数字前必读）

1. **综合配方非默认**：`-directive RuntimeOptimized`（运行时优先），**不是** Vivado 默认配方 ⇒ 与其它工程/默认配方的面积数字不可直接比（`fpga/out/synth.vivado.log:43-44`）。
2. **实例容器不可作 RTL 归因**：Vivado 会把逻辑"改挂"到相邻容器。已量化的例子：`u_rob` 容器里约 22k 非 ROB 逻辑（含 `trq` 7,375、`mem` 10,481、`g_bank.u_sdp` 2,095 等，`redundancy_audit.md:84-92`）；`u_rob` 在 L1 轮的 −33,262 全部来自 `rb_log` 改挂（`area_analysis_2b_l1.md:166-177`）。**本报告 §2.1 的 `u_rob = 42,114` 中，ROB 本体阵列（`nq`+`updq`+`win_q`）实测只占 `u_rob` 的约 43.5%**（`rob_tables_step1_4.md:65`）。
3. **"名义位宽 ≠ 网表位宽"**：综合会把"存了但不读"的位与其写 mux 裁掉 ⇒ 按名义位宽估算收益会系统性高估。两个已量化的对照：IQ `uop_q` 名义 20,672 FF / 实测 9,043 FF（44%）；ROB `win_q` 名义 3,328 FF / 实测 608 FF（18%）（`redundancy_audit.md:63-67`）。**外部按名义宽度给的 `win_q ~17K` 估计与实测 822 LUT 相差 20×**（`rob_tables_step1_4.md:67`）。
4. **信号名口径 vs 报告口径不可混用**：`report_utilization -hierarchical` 的 "Total LUTs"（折算后）比 `get_cells` 原始 LUT 桶低 6~10%（`area_analysis_2b_l1.md:183/316-318`）；信号名探针的"家族总量"也受网表改名影响（LQ16 后 `ld_hd` 的 LUT 全部改名 `fwdp_data`，`redundancy_audit.md:383`）。
5. **规则/参数是活的，注释/文档标题可能是旧的**：本报告已实测到三处——`iq.v:24` 的"uop 272 bit"注释过期（真值 304）；`docs/design/03-out-of-order.md:65` 的小节标题仍是"ROB（128 项）"（真值 64，`back2_params.vh:29`）；`rename.v` / `rob.v` / `lsq_simple.v` 里大量保留"阶段号 + 已废弃写法"的历史注释。**引用数字一律以 `rtl/pkg/*.vh` 与 `rtl/back2/back2_params.vh` 为准。**
6. **本报告基线与工作区的关系**：面积基线报告 `synth_2b_iqdep` 对应 commit `1df7252`；工作区 `HEAD=408e5da` 比它多两个提交（台账 + `rob.v` 自检 `ifdef` 化，**面积中性**）。**同 RTL 的 `synth_2b_selfchk` 轮重新综合得到逐位相同 230,998 / 76,281 ⇒ 综合零抖动**（`rob_tables_step1_4.md:169`）。

---

## 5. 未核实 / 待查

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| 1 | **iqdep 基线轮的 timing loop 条数** | **未取证** | 22 条/13 条是 L1 前基线轮（`area_analysis_2b.md:224`）；工作区最新日志（selfchk 轮）是 27/7，但**与基线不同轮**。要精确对齐基线须按 `fpga/run_vivado_batch.sh` 重跑一次 `RV32_SYNTH_TAG=2b_iqdep` 并 `grep` 日志。 |
| 2 | **C2 后 `rdy_q` 家族与比较器数的实测值** | **未核实** | 11,035~11,548 LUT / 340 FF 是 ΣDEPTH=68 时点；C2 后（ΣDEPTH=50）本报告只给出"3,000 个比较器"的**同式推算**，无探针实测。 |
| 3 | **C2 后 `uop_q` 家族 LUT / FF 的实测值** | **未核实** | 46,007 LUT 是 L1 口径（68 项）；FF 9,043/20,672 是 LQ16 口径。当前基线未做 `uop_q` 家族探针。 |
| 4 | `FSM_sequential_st`（4,100 LUT，1.3%，与深度 100% 无关） | **未定位** | `area_analysis_2b_l1.md:299/337` 登记为"固定冗余里最大的一条未归因项"，本报告未再追。 |
| 5 | `mem`（通用名 35,332）的 PRF / FPU 拆分 | **未拆分** | 通用名混了 `prf.v` 与 `fpu_*` 内部阵列（`area_analysis_2b_l1.md:334`）。 |
| 6 | `u_mem0` / `u_mem1` 的 170× 映射异常（2,732 vs 16） | **未定因** | `front4_table_2lu_1upd.v:76-90` 双副本存储封装（`area_analysis_2b_l1.md:251-252`）。 |
| 7 | `rb_fhead`/`rb_log` 当前基线（C2/L8 后）实测 | **未核实** | `group_rob_feasibility.md:81` 的 5,284 LUT 是 LQ16 口径；L8 已把 `flist_q` 改小但未重测这两项。 |
| 8 | 方向 A / 方向 B 的**任何收益数字** | **未验证** | 全部为估算/推算，**没有一条做过"改后重综合"**，也没有做过 IPC 仿真或 STA。 |

---

## 6. 证据清单（可复现）

| 证据 | 路径 / 位置 | 复现命令（只读） |
|---|---|---|
| 基线面积（全核 + 层次 + 器件） | `fpga/out/synth_2b_iqdep_16.667ns_utilization.rpt`、`..._utilization_hier.rpt` | `grep -E "Slice LUTs\|Slice Registers\|DSPs" fpga/out/synth_2b_iqdep_16.667ns_utilization.rpt` |
| 基线时序 | `fpga/out/synth_2b_iqdep_16.667ns_timing_summary.rpt:195/203/212-213` | `sed -n '195,215p' fpga/out/synth_2b_iqdep_16.667ns_timing_summary.rpt` |
| 同 RTL 复现（零抖动对照） | `fpga/out/synth_2b_selfchk_16.667ns_utilization.rpt` | `diff <(...iqdep_...utilization.rpt) <(...selfchk_...utilization.rpt)` |
| 综合配方 / 宏 / 时序环 | `fpga/out/synth.vivado.log:43-45`、`:1968+`、`:2538-2544` | `grep -n "directive RuntimeOptimized\|found timing loop\|inferred exception" fpga/out/synth.vivado.log` |
| 信号级探针（当前基线） | `fpga/scratch/rob_tables_step1_4.md` §1（含**原始命令与输出锚点**） | `grep 'RDAUDIT_SIG\|' fpga/scratch/step1_probe_iqdep.log` |
| 冗余审计（消费表 / 杠杆清单） | `fpga/scratch/redundancy_audit.md`（§2 A-A1..A-A5、§3 B-B1..B-B4、§4 C1..C12） | — |
| L1 面积去向（逐模块表 / 原语分布 / Top-20） | `fpga/scratch/area_analysis_2b_l1.md`（§1/§2/§4/§5） | — |
| L1 前缺陷核实（组合环 / 138 级锥） | `fpga/scratch/area_analysis_2b.md:224-225` | — |
| 组级 ROB 可行性（收益上限 / "已是组语义"） | `fpga/scratch/group_rob_feasibility.md`（§0/§1/§3） | — |
| ROB 控制表实测 + done bitmap 回归 | `fpga/scratch/rob_tables_step1_4.md`（§1/§2/§3/§5） | — |
| RTL 行号（本报告全部引用） | `rtl/back2/{back2_params.vh,iq.v,prf.v,rob.v,rob_wide_mem.v,rename.v,lsq_simple.v,backend_top.v}`、`rtl/exec/{alu.v,bru.v,mdu.v,fpu.v,fpu_div_sqrt.v}`、`rtl/front4/front4_top.v` | `git show 408e5da:<file>`（工作区已与之逐位一致，`git status` 干净） |
| 规格文档 | `docs/design/02-pipeline.md`、`docs/design/03-out-of-order.md` | — |
| 项目状态与判据口径 | `AGENT.md`、`NEXT_SESSION.md:17/24/34-42/46-49` | — |

**文档自检**

- `wc -l docs/design/09-backend-architecture-review.md` ⇒ 见交付回复（已落盘并核过行数）。
- 来源写入纪律：本任务**只新增本文档**，未改任何 RTL / 脚本 / 测试 / 其它文档（`git status` 仅显示该 `??` 新增文件）。
- §3 的全部方案均为"建议（非事实）"并标注收益/风险；全部方案以**保持既有位宽类指标为前提**（边界声明见 §3.2）。
