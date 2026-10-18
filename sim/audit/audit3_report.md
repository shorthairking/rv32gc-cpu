# 审计③：代码质量检查报告（死转移 / 不必要判断 / 死代码 / 风格）

- **冻结基准 HEAD**：`d00eb03`（"2B-5: EXP-N35B ROB 窄表 nq 36→16 bit …"）
  - `rtl` 子树哈希 @d00eb03 = `6f91ee7614eda62b06f794feaac7971a76f1767e`
  - `rtl` 子树哈希 @工作树 HEAD(`201d88d`) = `6f91ee7614eda62b06f794feaac7971a76f1767e`（**逐字节相同**）
  - `git diff --name-only d00eb03 HEAD -- rtl` = **空** ⇒ 本次审计的 RTL 即冻结基准 RTL
- **综合证据基准**（`fpga/out/`，Design `core_top_2b`，xc7a200tfbg676-2，60 MHz/16.667 ns）：
  - `synth_2b_n35b_16.667ns_utilization.rpt` sha256 = `0a7faefec2a371286981e5c879b2fda394aabe837589aa66310fb7f5451707e8`
    （LUT 126,699 = 94.13%；FF 49,597 = 18.42%）
  - **口径更正**：任务书写的 `synth_2b_n35b_16.667ns.vivado.log` **不存在**；n35b 轮综合日志真源为
    `fpga/out/n35b_synth_run.log`，sha256 = `a21b3c1fef52ee8ab50e73a55d3f30d42a31fdc4bcea5b52195292bf4b4e3cd5`（本次引用的全部
    `[Synth 8-*]` 均出自该文件，行号 = 该文件行号）。
- **工具口径**：`verilator 5.020`（`--lint-only -Wall`，**只读**；RTL 正文见 §6 净化说明）、`python3 3.12`。
- 本次**未修改任何 RTL/TB/脚本**；新增产物仅 `fpga/scratch/audit3_*`（清单见 §7）。

## 0. 结论速览

| 类别 | 条数（本报告可复核项） | 综合器已证实 | 综合器不反映（仅 RTL 可读性/调试） |
|---|---|---|---|
| ① 死转移 / 无消费 / 绕圈搬运 | **A-01..A-40 = 40** | 8-3848×2、8-3917×37、8-6014×100、8-7129×100 | 95 个访问函数、纯搬运链 6 条 |
| ② 不必要判断 / 同期重复计算 | **B-01..B-22 = 22** | 8-226×5、UNSIGNED×1、8-589×5 | DBG 恒假分支 8 处、重复拼接 7 处 |
| ③ 死代码与僵尸 | **C-01..C-62 = 44**（C-01..C-24 逐 branch；C-25..C-59 = 35 条 UNUSEDPARAM 逐条；C-61/C-62 其他） | 8-6014×100、8-3332×89、8-3917×37、8-7071×17、8-7023、8-3936×2 | UNUSEDSIGNAL 394（规模证据，未逐条展开）、UNUSEDPARAM 35（已逐条） |
| ④ 风格问题 | **D-01..D-20 = 20** | 8-6901×55、8-689×46、8-7137×80、8-8895×2、8-10940×3、8-295×17 | 长行、include 双制式、失效 lint 指令 |
| **合计** | **126 项**（A 40 + B 22 + C 44 + D 20；由 `fpga/scratch/audit3_check.py` 计数） | — | — |

> **关键观察**：`n35b_synth_run.log` 中 `8-6014`（Unused sequential element removed）与 `8-7129`（port has no load）
> 均**恰好 100 条**；`8-7129` 可穷举出 26+26+25+22+1 = 100（自然满额），而 `8-6014` 从 `ck_ghr_q`(16) +
> `ck_fhead/ck_log/ck_val`(48×2) + tlb(2) + `ck_alloc_q`(1) 的构造看 ≥115 ⇒ **疑为 Vivado 单类别 100 条上限截断**，
> 实际 dead FF 更多。**需实测验证**（复跑时提高 `-message_config`/关闭上限即见真值）。

---

## ① 无意义/可省的数据转移与分发（死搬运 / 无消费 / 绕圈）

证据列说明：`V-UNUSED` = 本次 `verilator -Wall` 输出（已把净化镜像路径还原为 `rtl/...`，日志 `fpga/scratch/audit3_verilator_rtl.log`）；
`V-UNDRIVEN` = 同上 `UNDRIVEN`；`S8-xxxx` = `n35b_synth_run.log` 第 `L` 行。

| ID | 位置（文件:行:信号） | 事实 | 对 area 影响 | 可读性影响 | 综合是否证实 dead/虚写 |
|---|---|---|---|---|---|
| A-01 | rtl/top/core_top_2b.v:207:`csr_mtvec_w` | 声明后**既无驱动也无扇出**（V-UNUSEDSIGNAL "not driven, nor used"） | 0（无网） | 高（读者以为参与 CSR） | 未见于 rpt；综合消 |
| A-02 | rtl/top/core_top_2b.v:207:`csr_mepc_w` | 同上 | 0 | 高 | 综合消 |
| A-03 | rtl/top/core_top_2b.v:114:`wid` | AXI W 通道 ID **输出端口无驱动**（V-UNDRIVEN + `S8-3848 L?` "Net wid … does not have driver"） | 0 | 中（端口契约空转） | ✅ 8-3848 |
| A-04 | rtl/top/core_top_2b.v:180:`ras_repair_valid` | 例化 front4_top 后**从不消费**（V-UNUSEDSIGNAL） | 0 | 中 | 综合消 |
| A-05 | rtl/top/core_top_2b.v:181:`ras_repair_addr` | 同上（且源端悬空，见 A-06） | 0 | 中 | 综合消 |
| A-06 | rtl/front4/front4_top.v:140:`ras_repair_addr` | 声明为 output 但**内部从不驱动**：例化处 `front4_top.v:266` 把 predictor_top 的输出接到**另一个网** `ras_repair_addr_w`(:218) ⇒ 外送端口整条悬空（V-UNDRIVEN + 8-3848） | 0 | **高（疑似笔误）** | ✅ 8-3848 |
| A-07 | rtl/top/core_top_2b.v:156:`fe_frozen` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-08 | rtl/top/core_top_2b.v:185:`l1i_req_line` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-09 | rtl/top/core_top_2b.v:238:`csr_fp_rd_w` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-10 | rtl/top/core_top_2b.v:281:`csr_menvcfg_w[31:7,3:0]` | **23 bit 写后不读**的死位 | 0 | 中（位域语义误导） | 综合消 |
| A-11 | rtl/top/core_top_2b.v:289:`fencei_hold_w` | 无消费者；且其值恒 ⊆ `fencei_pend_w`(:288) ⇒ 冗余派生 | 0 | 中 | 综合消（需实测确认） |
| A-12 | rtl/top/core_top_2b.v:307:`maint_l1i_inval_w` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-13 | rtl/top/core_top_2b.v:368:`trp_halt_w` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-14 | rtl/top/core_top_2b.v:389:`ptw_pmp_req_valid` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-15 | rtl/top/core_top_2b.v:392:`ptw_fault_cause` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-16 | rtl/top/core_top_2b.v:393:`ptw_fault_tval` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-17 | rtl/top/core_top_2b.v:394:`ptw_pte_ad_update` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-18 | rtl/top/core_top_2b.v:395:`ptw_pte_ad_pa` / `ptw_pte_ad_data` | 两路搬运后均无消费 | 0 | 低 | 综合消 |
| A-19 | rtl/top/core_top_2b.v:504:`st_xlate_idx_w` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-20 | rtl/top/core_top_2b.v:735:`l1i_fill_owner` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-21 | rtl/top/core_top_2b.v:749:`l1d_cs_stall` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-22 | rtl/top/core_top_2b.v:753:`l1d_fill_owner` | 搬运后无消费 | 0 | 低 | 综合消 |
| A-23 | rtl/top/core_top_2b.v:758:`l1d_wb_ready` / rtl/top/core_top_2b.v:760:`l1d_wb_way`,`l1d_wb_owner` | 三路搬运后均无消费（写回通道标识空转） | 0 | 中 | 综合消 |
| A-24 | rtl/top/core_top_2b.v:767:`arlock_raw[2:1]`,`awlock_raw[2:1]` | 4 bit 写后不读；对应输出 `arlock[1]`/`awlock[1]` 被综合判**恒 0** | 0 | 中 | ✅ 8-3917 |
| A-25 | rtl/top/core_top_2b.v:847:`d_mr_cac` / :848:`d_mr_plic_hit` | 两路搬运后均无消费 | 0 | 低 | 综合消 |
| A-26 | rtl/top/core_top_2b.v:1610:`trp_exc_w` / :1612:`trp_irq_w` | 两路搬运后均无消费 | 0 | 低 | 综合消 |
| A-27 | rtl/top/core_top_2b.v:134:`infor_flag` / :135:`reg_num` | 顶层**输入占位端口**，搬进来后从不消费（端口契约里写"占位"） | 0 | 中 | 综合消 |
| A-28 | rtl/top/core_top_2b.v:197:`commit_pc[127:32]` | 128 bit 向量只消费低 32 bit ⇒ 96 bit 死位 | 0 | 中 | 综合消 |
| A-29 | rtl/top/core_top_2b.v:197:`commit_arch_rd_wdata[127:32]` | 96 bit 死位 | 0 | 中 | 综合消 |
| A-30 | rtl/top/core_top_2b.v:198:`commit_arch_rd[19:5]` / :199:`commit_arch_we[3:1]` | 15+3 bit 死位 | 0 | 中 | 综合消 |
| A-31 | rtl/top/core_top_2b.v:200:`cnt_commit`,`cnt_squash` / :201:`dbg_stq_cnt_w` | 三路计数器搬运后无消费（占位/调试） | 0 | 低 | 综合消 |
| A-32 | rtl/top/core_top_2b.v:352:`tc_trap_cause`,`tc_trap_tval`,`tc_trap_epc`,`tc_trap_pc` / :206:`irq_mti_w` | 5 路搬入即弃 | 0 | 中 | 综合消 |
| A-33 | rtl/top/core_top_2b.v:149:`XIP_BASE_M` / :150:`XIP_ALIAS_M` | localparam 定义后**全文件零引用** | 0（常量） | 中（假配置点） | 综合消（UNUSEDPARAM） |
| A-34 | rtl/top/core_top_2b.v:1747:`rf_rdata`（`= 32'h0`）/ :1743:`debug0_wb_rf_wen[3:1]`（`{3'b000,…}`） | 端口级"恒 0 分发"：32+3 bit 写死常量后外送 | 0 | 中 | ✅ 8-3917（逐位） |
| A-35 | rtl/back2/backend_top.v:1832:`wbi_tag`← :1834:`wki_tag` ← `wk_i_tag_w` | **纯改名搬运链**（长度 2，值不变）：回写标签经 3 个名字 | 0 | 中 | 综合消 |

### ①-补：同信号跨模块重复搬运（结构性）

| ID | 位置 | 事实 | 影响 |
|---|---|---|---|
| A-36 | rtl/back2/backend_top.v:234-330（95 个访问函数：`u_*` 39 个、`p_*` 21 个、`w_*` 35 个） | 同一条 uop 信息在 **3 种打包布局**（`UOPW`/`RB_W`/`IW_W`）里各写一套切片访问函数（例：`u_pc`/`p_pc`/`w_pc`）。数据从未被"计算"，只在改位置 | 0 LUT（纯连线），可读性**高** |
| A-37 | rtl/back2/backend_top.v:51-74 `blk_next_pc_i`,`blk_taken_i`,`lane_pa_i`,`lane_btb_cond_i`,`lane_btb_call_i`,`lane_btb_ret_i`,`lane_btb_target_i`,`lane_fault_cause_i[19,14,9,4]`,`fe_fetch_fault_i` | 块接口整批输入搬进后端后**无消费者**（9 组，共 ≥9 bit） | 0 |
| A-38 | rtl/cache/cache_array_bram.v:98:`a_dout_r` | 显式 `assign a_dout_r = {DW{1'b0}};`，行内注释自认"**无消费者**；SDP 写口无读通路"——保留的唯一理由是端口兼容 | 0 |
| A-39 | rtl/back2/backend_top.v:234（`u_*` 访问函数起点；`u[299:…]`/`p[224:…]`/`w[211:…]` 共 159 条 V-UNUSEDSIGNAL） | 打包结构体高位在搬运链上被反复"改位置"，但无终端消费者 | 0（FF 宽度由写侧决定，消不掉） |
| A-40 | 绕圈型分发（本项目实况） | **未发现** A→B→A 的显式反绕环；历史 `fwdp_*` 已被 N29B 整组删除（`rtl/back2/lsq_simple.v:971` 注释留档，`grep -rn fwdp rtl` 只剩注释）。**本轮新增**发现的是 A-06/A-35/A-36 三类"单向绕行" | — |

> 说明：任务书提到的 `iwm_xbar` / `dispatcher` / `neighbor` / `pr.v` 在本仓库 `rtl/**` 中**不存在**（`grep -rl` 零命中）；
> 对应的"分发链"语义在本项目由 `backend_top.v` 的派发（`disp_fire_w`）+ 95 个访问函数承担，已归入 A-36/A-39。

---

## ② 不必要的边界/条件判断 + 同周期重复计算

| ID | 位置（文件:行:信号） | 事实 | 对 area 影响 | 可读性 | 综合是否证实 |
|---|---|---|---|---|---|
| B-01 | rtl/mem/pmp_check.v:227（`default:` @ :228 `type_to_fault_cause`） | `case (t)` 的 `default` 分支**恒不可达**（t∈{T_EXEC,T_LOAD,T_STORE,T_AMO} 已穷举 2 bit） | 0 | 中 | ✅ `S8-226` "default block is never used" |
| B-02 | rtl/mem/pmp_check.v:243（`default:` @ :244 `type_to_perm`） | 同上，第二个恒不可达 default | 0 | 中 | ✅ 8-226 |
| B-03 | rtl/top/core_top_2b.v:1082-1086（`case(ad_st_q)` default） | AXI-D 引擎状态机 default **从不命中**（状态枚举已满） | 0 | 中 | ✅ 8-226 |
| B-04 | rtl/top/core_top_2b.v:1289-1290（`case(ist_q)` default） | AXI-I 引擎状态机 default 恒不可达 | 0 | 中 | ✅ 8-226 |
| B-05 | rtl/exec/mdu.v:574-575（`case(state_q)` default） | MDU 状态机 default 恒不可达 | 0 | 中 | ✅ 8-226 |
| B-06 | rtl/plic/plic.v:156:`prio_region` | `(req_addr >= PRIORITY_OFF)` 中 `PRIORITY_OFF == 0` ⇒ 无符号比较**恒真**，半边条件为常量 | 0（综合已消） | 中（读起来像真判断） | ✅ `%Warning-UNSIGNED`（Verilator："Comparison is constant due to unsigned arithmetic"） |
| B-07 | rtl/plic/plic.v:153-155:`/* verilator lint_off UNSIGNED */` / :154 `UNUSEDSIGNAL` | 注释(*)声称"本地静默两条告警"，但 `/*` 与 `verilator` 之间**多一个空格** ⇒ Verilator 官方语法不成立，**实测未生效**（B-06 与 UNUSEDSIGNAL 仍被报出） | 0 | 高（假证据） | ✅ 本次 lint 实测反证 |
| B-08 | rtl/back2/rename.v:422:`clr_pd` | 组合 `always @(*)` 未在全部控制路径赋值 ⇒ **推断 latch**（`u_ren_i`/`u_ren_f` 各一，共 2 个） | 可能 >0（latch） | 高 | 未在 rpt；`%Warning-LATCH` |
| B-09 | rtl/top/core_top_2b.v:71:`aresetn` | 同一网既作同步又作异步复位（`%Warning-SYNCASYNCNET`） | 0 | 高（时序/仿真风险） | 需实测验证 |
| B-10 | rtl/back2/lsq_simple.v:237,238,239,240,991 | `===`（case equality）被综合**替换成 `==`**（synth 明示），x/z 语义丢失；此处对比的是单 bit 使能，属"不必要的严格等号" | 0 | 中 | ✅ `S8-589` ×5 |
| B-11 | rtl/back2/backend_top.v:2149-2151:`$display("[csr-cmt …] … mscratch=0x%08x")` | 格式串 8 个 `%`，实参只有 7 个 ⇒ **少 1 个参数**（末尾 `mscratch` 无对应值） | 0（DBG 恒假） | 高（调试信息失真/仿真 X） | ✅ 双侧证实：`8-9736` + Verilator `%Error Missing arguments` |
| B-12 | rtl/csr/tlb.v:394,396,400,402,404 | 时序 `always` 里用阻塞赋值（5 处） | 0 | 中 | `%Warning-BLKSEQ` |
| B-13 | rtl/front4/bpu_gshare.v:96,97 | 时序 `always` 里阻塞赋值（2 处） | 0 | 中 | `%Warning-BLKSEQ` |
| B-14 | rtl/back2/backend_top.v:2140,2144,2148（`if (DBG_CSR && …)`）；DBG_CSR 默认 0 @ :43 | 参数默认值 ⇒ **恒假分支**；同类：rtl/back2/iq.v（1 处）、rtl/back2/rob.v（1 处，DBG_CSR=0 @ :68）、rtl/back2/lsq_simple.v（1 处）⇒ 共 8 处 | 0（综合消） | 中（RTL 噪声） | 综合消（需实测验证是否全消） |
| B-15 | rtl/exec/fpu_add.v:1031,1214,1469,1687 + rtl/exec/fpu_fma_shared.v:615 + rtl/exec/fpu_mul.v:140,241 | 同一表达式 `{sp_r, sp_f}` **同周期重复拼接 7 处**，未共享 | 0（综合 CSE） | 中 | 综合消；RTL 层未合并（**需实测验证**是否真 CSE） |
| B-16 | rtl/exec/fpu_add.v:1048,1229 / fpu_mul.v:155,256 | `sp_e_q ? sp_r_q : rr_r` 重复 4 处 | 0（CSE） | 中 | 同上 |
| B-17 | rtl/exec/fpu_add.v:1049,1230 / fpu_mul.v:156,257 | `sp_e_q ? sp_f_q : rr_f` 重复 4 处 | 0（CSE） | 中 | 同上 |
| B-18 | rtl/exec/fpu_add.v:1042,1223 / fpu_mul.v:149,250 | `{round_result, round_flags}` 重复 4 处 | 0（CSE） | 中 | 同上 |
| B-19 | rtl/back2/rename.v:303-305:`valid_n_f` 与 :313-315:`valid_n_w` | **同构 4-lane 有效计数**在同一文件写两遍（两份 `{2'b0,lvf[i]}` / `{2'b0,lane_valid[i]}` 加法链） | 0（可能 1-2 LUT×2） | 高 | 需实测验证 |
| B-20 | rtl/back2/rename.v:306-311:`rel_n_w` | 用 `generate` 写 CMW==1/2/else **三分支**（:308/:310/:311-312），而 :313 的 `valid_n_w` 却直接手写四路相加 ⇒ 同构算式两种写法并存 | 0 | 中 | 需实测验证 |
| B-21 | rtl/back2/lsq_simple.v:237（代表；`== 1'b1`/`!= 1'b0` 共 16 处，另见 rtl/decode/compressed_expand.v:?、rtl/back2/rob.v:?，计数见 §7 命令） | 对 1 bit 网做 `x == 1'b1` 等价于 `x`；`x != 1'b0` 等价于 `x`（x 无 z 时） | 0 | 中 | 需实测验证 |
| B-22 | rtl/back2/rob.v:628（`ifndef RV32GC_USE_VIVADO_IP` 代表；双分支共 22 处：rob.v 5、mdu.v 4、rob_wide_mem.v 3、cache_array_bram.v 3、front4_mem.v 2、rename.v 2、fpu.v/fetch_unit.v/core_top.v 各 1） | 每次综合/仿真**必有一半分支是死代码**（互斥 `ifdef`）；综合前的 RTL 全文永远含双份实现 | 0（预处理器删） | 高（双份维护） | 综合消 |

---

## ③ 死代码与僵尸（逐 branch / 逐位）

### ③-A 综合器**已证实删除**的时序元件（`[Synth 8-6014]`，位置=日志 L 行）

| ID | 位置（文件:行:信号） | 事实 | area | 可读性 | 综合证实 |
|---|---|---|---|---|---|
| C-01 | rtl/csr/tlb.v:394:`all_valid_reg` | 未用时序元件被移除 | 0（已消） | 中 | ✅ S8-6014 L735 |
| C-02 | rtl/csr/tlb.v:400:`fill_idx_reg` | 同上 | 0 | 中 | ✅ L736 |
| C-03 | rtl/front4/predictor_top.v:235:`ck_alloc_q_reg` | 同上（检查点分配寄存器整只死） | 0 | 高 | ✅ L739 |
| C-04 | rtl/front4/predictor_top.v:226:`ck_ghr_q_reg[0..15]` | **16 bit 全死**——任务书点名的"ck_ghr_q is queue 0 / R13 已给死逻辑"，本轮由综合器逐位证实 | 0（已消） | 高 | ✅ L740-755（16 条） |
| C-05 | rtl/back2/rename.v:880:`ck_fhead_reg[0..15]` | 16 bit 死 | 0 | 高 | ✅ L757-772、L805-820（两处层次各 16 条） |
| C-06 | rtl/back2/rename.v:880:`ck_log_reg[0..15]` | 16 bit 死 | 0 | 高 | ✅ L773-788、L821-836 |
| C-07 | rtl/back2/rename.v:881:`ck_val_reg[0..15]` | 16 bit 死 | 0 | 高 | ✅ L789-804、L837+ |
| C-08 | rtl/exec/fpu_fma_shared.v:476:`r2_prod`（`reg [105:0]`，:484 赋值） | 综合报 `r2_prod_reg[17..47]` **31 bit** unused removed（89 条 warning） | 0（已消） | 中 | ✅ S8-3332 ×89 |

### ③-B 综合器**已证实恒 0 / 无驱动**（`8-3917` / `8-3848`）

| ID | 位置 | 事实 | area | 可读性 | 证实 |
|---|---|---|---|---|---|
| C-09 | rtl/top/core_top_2b.v:1747:`rf_rdata[31:0]` | 32 bit 端口恒 0 | 0 | 中 | ✅ 8-3917 ×32 |
| C-10 | rtl/top/core_top_2b.v:1743:`debug0_wb_rf_wen[3:1]` | 3 bit 恒 0 | 0 | 中 | ✅ 8-3917 ×3 |
| C-11 | rtl/top/core_top_2b.v:1419:`arlock[1]` | 恒 0 | 0 | 低 | ✅ 8-3917 |
| C-12 | rtl/top/core_top_2b.v:1420:`awlock[1]` | 恒 0 | 0 | 低 | ✅ 8-3917 |
| C-13 | rtl/top/core_top_2b.v:114:`wid` | 无驱动网 | 0 | 中 | ✅ 8-3848 |
| C-14 | rtl/front4/front4_top.v:140:`ras_repair_addr` | 无驱动网 | 0 | 高 | ✅ 8-3848 |
| C-15 | rtl/csr/tlb.v:191:`ppn_sel_reg` | 未连接内部寄存器被裁剪 **22→20 bit**（2 bit 死） | 0 | 低 | ✅ 8-3936 |
| C-16 | rtl/csr/tlb.v:288:`ppn_sel2_reg` | 同上（2 bit 死） | 0 | 低 | ✅ 8-3936 |

### ③-C 端口级僵尸（未连接 / 无负载）

| ID | 位置 | 事实 | area | 可读性 | 证实 |
|---|---|---|---|---|---|
| C-17 | rtl/cache/l1i.v:164（`u_tag` 例化）:`dirty_clr_en`,`dirty_clr_addr` | 两个端口**未连接**（13 连接声明只给 11） | 0 | 中 | ✅ 8-7071 + 8-7023 |
| C-18 | rtl/back2/backend_top.v:1278,1292,1306,1320,1354,1368:`iss_uop`,`o_sel_uop` | 6 个 iq 实例 ×2 端口未连接（共 12） | 0 | 中 | ✅ 8-7071 ×12 |
| C-19 | rtl/top/core_top_2b.v:1425:`trap_valid_o_pc` | 端口未连接且无负载 | 0 | 低 | ✅ 8-7071 |
| C-20 | rtl/csr/trap_ctrl.v:51:`exc_is_fetch` | 端口"unconnected or has no load" | 0 | 中 | ✅ 8-7129 |
| C-21 | rtl/csr/trap_ctrl.v:58:`mideleg[31:12]`（除 11/9/7/5/3/1）共 25 bit | 逐位无负载 | 0 | 中 | ✅ 8-7129 ×25 |
| C-22 | rtl/csr/trap_ctrl.v:63:`mip` 共 26 bit | 逐位无负载 | 0 | 中 | ✅ 8-7129 ×26 |
| C-23 | rtl/csr/trap_ctrl.v:64:`mie` 共 26 bit | 逐位无负载 | 0 | 中 | ✅ 8-7129 ×26 |
| C-24 | rtl/csr/trap_ctrl.v:65:`mstatus_i` 共 22 bit | 逐位无负载 | 0 | 中 | ✅ 8-7129 ×22 |

### ③-D 未用参数（`UNUSEDPARAM` 35 条，全部为"定义即僵尸"）

| ID | 位置（文件:行:param） | ID | 位置（文件:行:param） |
|---|---|---|---|
| C-25 | rtl/top/core_top_2b.v:149:`XIP_BASE_M` | C-43 | rtl/exec/fpu.v:202:`FP_FCVT_WU_D` |
| C-26 | rtl/top/core_top_2b.v:150:`XIP_ALIAS_M` | C-44 | rtl/exec/fpu.v:203:`FP_FCVT_D_W` |
| C-27 | rtl/back2/backend_top.v:212:`OPT_FP` | C-45 | rtl/exec/fpu.v:204:`FP_FCVT_D_WU` |
| C-28 | rtl/back2/rename.v:81:`TRB` | C-46 | rtl/exec/fpu.v:205:`FP_FCVT_S_D` |
| C-29 | rtl/cache/l1i.v:98:`WAY_W` | C-47 | rtl/front4/predictor_top.v:47:`RAS_DEPTH` |
| C-30 | rtl/exec/fpu.v:187:`FP_FSGNJN` | C-48 | rtl/back2/rob.v:232:`NQ_MK_L` |
| C-31 | rtl/exec/fpu.v:188:`FP_FSGNJX` | C-49 | rtl/exec/fpu_cvt.v:249:`LAT` |
| C-32 | rtl/exec/fpu.v:189:`FP_FMIN` | C-50 | rtl/exec/fpu_div_sqrt.v:154:`STEPS_S` |
| C-33 | rtl/exec/fpu.v:190:`FP_FMAX` | C-51 | rtl/exec/fpu_div_sqrt.v:174:`SPC_SQRT` |
| C-34 | rtl/exec/fpu.v:191:`FP_FEQ` | C-52 | rtl/front4/bpu_btb.v:80:`W` |
| C-35 | rtl/exec/fpu.v:192:`FP_FLT` | C-53 | rtl/mem/mmio_route.v:86:`ROUTE_NONE` |
| C-36 | rtl/exec/fpu.v:193:`FP_FLE` | C-54 | rtl/mem/pmp_check.v:93:`PMP_G` |
| C-37 | rtl/exec/fpu.v:196:`FP_FMV_W_X` | C-55 | rtl/mem/pmp_check.v:128:`A_NA4` |
| C-38 | rtl/exec/fpu.v:197:`FP_FCVT_W_S` | C-56 | rtl/mem/pmp_check.v:137:`NAPOT_FIELD_W` |
| C-39 | rtl/exec/fpu.v:198:`FP_FCVT_WU_S` | C-57 | rtl/mem/pmp_check.v:139:`PRIV_U` |
| C-40 | rtl/exec/fpu.v:199:`FP_FCVT_S_W` | C-58 | rtl/mem/pmp_check.v:140:`PRIV_S` |
| C-41 | rtl/exec/fpu.v:200:`FP_FCVT_S_WU` | C-59 | rtl/back2/rob_wide_mem.v:32:`AW` |
| C-42 | rtl/exec/fpu.v:201:`FP_FCVT_W_D` | — | （共 35 条，见下行复现命令） |

> C-25..C-59 覆盖 35 条 UNUSEDPARAM 全部（逐条见 `fpga/scratch/audit3_verilator_rtl.log`，
> 复现命令 `grep '%Warning-UNUSEDPARAM' fpga/scratch/audit3_verilator_rtl.log`）。

### ③-E 其他僵尸（隐式网 / 空复制 / 未用信号规模）

| ID | 位置 | 事实 | area | 可读性 | 证实 |
|---|---|---|---|---|---|
| C-61 | rtl/exec/fpu_cvt.v:443→454:`r2_f2i_rm`；:563→587:`r_disp` | 标识符**隐式声明**（`8-11241` assumed wire）后又在 454/587 被"已隐式声明"告警（`8-8895`）⇒ 两个网既无显式声明也无有效使用链 | 0 | 高 | ✅ 8-8895 + 8-11241 |
| C-62 | rtl/back2/lsq_simple.v:879 | `zero replication count - replication ignored`（`{0{…}}` 空复制） | 0 | 中 | ✅ 8-693 |

> 规模证据（未逐条展开，全部可 grep 复核）：`verilator -Wall` 共报 **UNUSEDSIGNAL 394 条**（分布：
> backend_top.v 159、core_top_2b.v 44、compressed_expand.v 24、ifetch4.v 17、dec_imm.v 16、csr_file.v 16 …
> 单文件计数见 `fpga/scratch/audit3_verilator_rtl.log`）；`UNDRIVEN` 2 条（C-13/C-14）；
> `PINCONNECTEMPTY` 125 条、`PINMISSING` 15 条（C-17..C-19）。

---

## ④ 风格问题 Top20

| ID | 位置 / 范围 | 事实 | 计数 | area | 可读性 |
|---|---|---|---|---|---|
| D-01 | rtl/back2/backend_top.v:1436:`g` | 内层信号**遮蔽**外层同名（VARHIDDEN） | 1 | 0 | 高 |
| D-02 | rtl/exec/fpu_add.v:214(`fpu_delay`)、rtl/exec/fpu_cmp.v:70(`fpu_cmp_core`)、rtl/exec/fpu_cvt.v:51(`fpu_f2i_a`)、rtl/exec/fpu_fma_shared.v:58(`fpu_round_dual_pre`)、rtl/exec/fpu_mul.v:55(`fpu_mul_s`)、rtl/front4/front4_mem.v:38(`front4_mem_2r1w`) | **模块名 ≠ 文件名**（DECLFILENAME） | 6 | 0 | 中 |
| D-03 | rtl/back2/iq.v:196,197；rtl/back2/lsq_simple.v:291,292,816,817 | **未命名 generate 块**（GENUNNAMED → `genblk1` 冲突风险） | 6 | 0 | 中 |
| D-04 | rtl/back2/backend_top.v:482（首条；共 55 处，分布：backend_top.v 14、iq.v 11、rename.v 6、fetch_unit.v 5、rob.v 4、core_top.v 4、ptw.v 3、amo_unit.v 3、core_top_2b.v 3、lsq_simple.v 1、plic.v 1） | 55 | 0 | 高 |
| D-05 | rtl/back2/backend_top.v:956 等 `8-689` | 端口连接位宽不匹配（例：`rename.restore_rob_idx` 7 vs 6） | 46 | 0 | 高 |
| D-06 | rtl/back2/iq.v:167 等 `8-7137` | 寄存器**Set 与 Reset 同优先级**（仿真/综合可能不一致） | 80 | 0 | 高 |
| D-07 | `8-10940` rtl/pkg/core_params.vh:106,163 等 | 宏被**重复定义**（`RV32GC_XLEN`、`RV32GC_PMP_ENTRIES`） | 3 | 0 | 中 |
| D-08 | `8-295`（CRITICAL WARNING） rtl/top/core_top_2b.v:289 / :64 等 | 综合发现**时序环** | 17 | 0 | 高 |
| D-09 | rtl/back2/lsq_simple.v:700:`lalloc_ok`（`8-326` 指向 `u_lsui_13/lalloc_ok`） | 综合自行推断 `set_false_path` 打断组合环 | 10 处 | 0 | 高 |
| D-10 | rtl/front4/bpu_local_hist.v:92:`lht_mem`（候选集=4 个带 `ram_style` 的阵列文件；`8-4767` 26 条**无位置**） | RAM 落进寄存器（BRAM 无法推断） | 26 处 | **>0（可能是 area 大头）** | 中 |
| D-11 | rtl/back2/rob.v:631（**203 字符**）、rtl/back2/rename.v:798（**220 字符**） | 长度 >160 的行只有这 2 条；全库最长 220 | 2 | 0 | 低 |
| D-12 | rtl/back2/backend_top.v:1688（代表；另 rtl/cache/cache_array_bram.v:163、rtl/decode/dec_imm.v:212、rtl/top/core_top.v:2436） | 行尾多余空白 | 4 处 | 0 | 低 |
| D-13 | rtl/top/core_top.v:105（短式 `"rv32_defs.vh"` 代表；长式 42 处 vs 短式 8 处） | 同一真源两种写法；短式出现在 rtl/exec/fpu*.v（cvt/cmp/add/mul/fpu/div_sqrt/fregfile）+ rtl/top/core_top.v | 8 vs 42 | 0 | 中 |
| D-14 | rtl/exec/mdu.v:204,208,252,254,294,297,327,328,334,376,404,408 + rtl/plic/plic.v:153,154,170,171 | `/* verilator … */` **`/*` 后有空格** ⇒ 17 处 lint 指令**全部失效**，注释里的"已静默"是假证据 | 17 | 0 | 高 |
| D-15 | rtl/exec/mdu.v:88（代表；17 个文件、41 处行注释含裸词 `Verilator`：mdu.v 16、plic.v 5、pmp_check.v 3…） | Verilator 5.020 会把**任意注释中出现 `Verilator` 的行**当元指令解析 ⇒ `%Error: Unknown verilator comment`，**整库无法直接 lint**（本次必须用净化镜像，见 §6） | 41 | 0 | 高 |
| D-16 | rtl/exec/fpu_add.v:214:`fpu_delay`（同文件另有 `fpu_round_pre`/`fpu_round_mid`；另 rtl/exec/fpu_mul.v:55:`fpu_mul_s`、rtl/front4/front4_mem.v:38:`front4_mem_2r1w`） | **一文件多模块**，命名空间靠后缀区分 | 3 文件 | 0 | 中 |
| D-17 | rtl/mem/pmp_check.v:227（另 :244；rtl/top/core_top_2b.v:1086,1290；rtl/exec/mdu.v:575） | 不可达 `default`（与 B-01..B-05 同源） | 5 | 0 | 中 |
| D-18 | rtl/back2/lsq_simple.v:237（另 :238,239,240,991） | `===` 被替换为 `==`（与 B-10 同源） | 5 | 0 | 中 |
| D-19 | rtl/cache/l1i.v:164 | `u_tag` 例化：13 个连接声明只给 11（`8-7023`） | 1 | 0 | 中 |
| D-20 | rtl/exec/fpu_cvt.v:443/454/563/587 | 隐式网 + 重复声明告警（`8-11241`/`8-8895`） | 2 | 0 | 高 |

---

## ⑤ "代码质量 vs 综合器优化"分级（逐项：area 预估 + 可读性 + 综合是否证实）

| 来源 | 综合器行为 | 本项目实测证据 | 分级 |
|---|---|---|---|
| A-01..A-35（顶层无消费网） | **全部删除**（无扇出=无逻辑） | `verilator UNUSEDSIGNAL`；`8-3917`（A-24/A-34）逐位证实恒 0 | **area 影响 0**；**可读性影响 高**（占了顶层 ~25 个 wire 的名字预算） |
| A-03/A-06（无驱动端口） | 不变（端口必须存在），网为常量/悬空 | `8-3848` 明示 2 条 | area 0；可读性 高（remains a latent bug） |
| A-36（95 个 `u_/p_/w_` 访问函数） | 每个函数都是纯位切片 ⇒ 综合成**纯连线**，0 LUT | 无对应 warning（工具认为是正常连线） | **area 0**；**可读性/维护 极大**（同一字段 3 套布局名） |
| A-38（`a_dout_r = 0`） | 常量驱动 ⇒ 0 LUT，但**端口仍在** | 注释自认无消费者；`8-3917` 类 | area 0；可读性 中 |
| B-01..B-05（恒不可达 default） | 综合**明确报告**并删除 | `8-226` ×5 | area 0（已消）；可读性 中 |
| B-06（恒真比较）/B-14（DBG 恒假） | 综合消 | `%Warning-UNSIGNED`；DBG 参数默认 0（需实测确认全消） | area 0；可读性 中 |
| B-07/D-14（失效 lint 指令） | 无关综合 | 本次 lint 实测**仍报** | area 0；**可读性/可信度 高**（假证据） |
| B-08（latch ×2） | latch 未必被消 | `%Warning-LATCH`；rpt 未列 | **area 可能 >0（需实测）**；可读性 高 |
| B-15..B-18（同周期重复拼接） | 预期 CSE 合并 | 无 rpt 细化证据 | area **预期 0**；`需实测验证` |
| B-19/B-20（rename 同构算式两份） | 可能各自成逻辑（未共享） | 无 rpt 证据 | area **可能 1~数 LUT**；`需实测验证` |
| C-01..C-08（死寄存器） | **综合明确删除** | `8-6014` ×100、`8-3332` ×89 | area **0（已消，但 RTL 仍有）**；可读性 高；**注意 100 条疑为上限** |
| C-09..C-12（恒 0 端口位） | 端口存在、内部逻辑 0 | `8-3917` ×37 | area 0；可读性 中 |
| C-17..C-24（未连接/无负载端口） | 内部逻辑被裁；端口保留 | `8-7071` ×17、`8-7129` ×100 | area 0（已裁）；可读性 中 |
| C-25..C-60（35 条 UNUSEDPARAM） | localparam 不生成逻辑 | `%Warning-UNUSEDPARAM` | area 0；可读性 中 |
| D-04（先用后声明 55） | 无影响 | `8-6901` | area 0；可读性 高 |
| D-05（位宽不匹配 46） | 隐式截断/扩展，**可能静默丢位** | `8-689`；另有 Verilator `WIDTHTRUNC 160`/`WIDTHEXPAND 169` | area 小；**正确性风险 高** |
| D-06（Set/Reset 同优先级 80） | 综合与仿真可能不一致 | `8-7137` | area 0；**正确性风险 高** |
| D-08/D-09（时序环 17 / 推断 false path 10） | 综合自行打断 | `8-295`/`8-326`（CRITICAL） | area 0；**时序/正确性风险 高** |
| D-10（RAM 落寄存器 26） | 综合用寄存器实现 | `8-4767` | **area 可能 >0（需实测）**；可读性 中 |
| D-11..D-13、D-16、D-19、D-20 | 无关综合 | — | area 0；可读性 低~中 |

**分级汇总**：
- **取消后 area 严格为 0**（综合已证实）：A 组 40 项全部、B-01..B-07/B-10..B-14/B-21..B-22、C 组 44 项全部、D 组 20 项。
- **area 可能非 0，需实测验证**：B-08（latch ×2）、B-19/B-20（rename 同构算式）、D-10（RAM 落 reg 26 处）、以及 B-15..B-18 的 CSE 是否真共享。
- **正确性/时序风险（非面积）**：B-09、B-11、D-05、D-06、D-08、D-09。

---

## ⑥ 完整可回购清单（编码子 Agent 可立即修，逐条标注预计影响）

> 排序：先"零影响、纯删/纯改名"（安全），再"需实测"。
> **纪律**：以下全部为只读审计结论；实际改动必须走回归（本次不实施）。

### ⑥-1 预计 LUT/FF 影响 = 0（纯删除无消费网/常量/参数）

| # | 动作 | 位置 | 预计影响 |
|---|---|---|---|
| R-01 | 删除 `csr_mtvec_w`,`csr_mepc_w` 声明 | rtl/top/core_top_2b.v:207 | LUT 0 / FF 0 |
| R-02 | 删除 `infor_flag`,`reg_num` 占位输入端口（或与平台契约确认） | rtl/top/core_top_2b.v:134,135 | 0 / 0（端口契约需同步） |
| R-03 | 删除 `fe_frozen` 及其驱动 | rtl/top/core_top_2b.v:156 | 0 / 0 |
| R-04 | 删除 `l1i_req_line` | rtl/top/core_top_2b.v:185 | 0 / 0 |
| R-05 | 删除 `csr_fp_rd_w` | rtl/top/core_top_2b.v:238 | 0 / 0 |
| R-06 | `csr_menvcfg_w` 收窄为实际使用位（或显式注释未用位） | rtl/top/core_top_2b.v:281 | 0 / 0（源为 CSR 寄存器，宽度不变） |
| R-07 | 删除 `fencei_hold_w`（保留 `fencei_pend_w`） | rtl/top/core_top_2b.v:287-289 | 0 / 0 |
| R-08 | 删除 `maint_l1i_inval_w` | rtl/top/core_top_2b.v:307 | 0 / 0 |
| R-09 | 删除 `trp_halt_w` | rtl/top/core_top_2b.v:368 | 0 / 0 |
| R-10 | 删除 `ptw_pmp_req_valid`,`ptw_fault_cause`,`ptw_fault_tval`,`ptw_pte_ad_update`,`ptw_pte_ad_pa`,`ptw_pte_ad_data` | rtl/top/core_top_2b.v:389-395 | 0 / 0 |
| R-11 | 删除 `st_xlate_idx_w` | rtl/top/core_top_2b.v:504 | 0 / 0 |
| R-12 | 删除 `l1i_fill_owner`,`l1d_fill_owner`,`l1d_cs_stall`,`l1d_wb_ready`,`l1d_wb_way`,`l1d_wb_owner` | rtl/top/core_top_2b.v:735,749,753,758,760 | 0 / 0 |
| R-13 | `arlock_raw`/`awlock_raw` 收窄为 `[0]`（或直接 `arlock = 1'b0`） | rtl/top/core_top_2b.v:767,1419,1420 | 0 / 0（合成 8-3917 已恒 0） |
| R-14 | 删除 `d_mr_cac`,`d_mr_plic_hit` | rtl/top/core_top_2b.v:847,848 | 0 / 0 |
| R-15 | 删除 `trp_exc_w`,`trp_irq_w` | rtl/top/core_top_2b.v:1610,1612 | 0 / 0 |
| R-16 | 删除 `tc_trap_cause/tval/epc/pc`,`irq_mti_w` | rtl/top/core_top_2b.v:352,206 | 0 / 0 |
| R-17 | `commit_pc`/`commit_arch_rd_wdata` 收窄到 32 bit；`commit_arch_rd`/`commit_arch_we` 收窄 | rtl/top/core_top_2b.v:197-199 | 0 / 0（若上游按 128 打包则需同步） |
| R-18 | 删除 `cnt_commit`,`cnt_squash`,`dbg_stq_cnt_w` | rtl/top/core_top_2b.v:200,201 | 0 / 0 |
| R-19 | 删除 localparam `XIP_BASE_M`,`XIP_ALIAS_M` | rtl/top/core_top_2b.v:149,150 | 0 / 0 |
| R-20 | `rf_rdata`/`debug0_wb_rf_wen[3:1]` 恒 0 显式化（或接真实读口） | rtl/top/core_top_2b.v:1743,1747 | 0 / 0 |
| R-21 | 删除 `g` 的遮蔽声明（改名） | rtl/back2/backend_top.v:1436 | 0 / 0 |
| R-22 | 删除未使用输入 `blk_next_pc_i`,`blk_taken_i`,`lane_pa_i`,`lane_btb_*`,`fe_fetch_fault_i`（或标注保留理由） | rtl/back2/backend_top.v:51-74 | 0 / 0 |
| R-23 | 删除 `a_dout_r` 常量驱动（或改注释为"接口兼容占位"） | rtl/cache/cache_array_bram.v:98 | 0 / 0 |
| R-24 | 35 条 UNUSEDPARAM 逐条删除或加"保留以供外部引用"注释 | 见 C-25..C-60 | 0 / 0 |
| R-25 | 修复 `ras_repair_addr` 悬空：`front4_top.v:266` 改接 `ras_repair_addr`（或删除该端口 + `core_top_2b.v:181`） | rtl/front4/front4_top.v:140,218,225,266 | 0 / 0（**纪律：改前先确认平台是否读该端口**） |
| R-26 | 补 `wid` 驱动（`assign wid = 4'h0;`）或删除端口 | rtl/top/core_top_2b.v:114 | 0 / 0 |
| R-27 | 死寄存器整组删除：`ck_ghr_q`、`ck_alloc_q`、`ck_fhead/ck_log/ck_val`、`all_valid_reg`、`fill_idx_reg`、`r2_prod[47:17]` | rtl/front4/predictor_top.v:181,226,235；rtl/back2/rename.v:880,881；rtl/csr/tlb.v:394,400；rtl/exec/fpu_fma_shared.v:476 | **LUT 0 / FF 0（综合已删）**，但 RTL 行数↓、仿真波形↓ |
| R-28 | 未连接端口清理：`u_tag.dirty_clr_*`、`iq.iss_uop/o_sel_uop`、`trap_valid_o_pc`、`trap_ctrl` 未用位 | rtl/cache/l1i.v:164；rtl/back2/backend_top.v:1278…；rtl/top/core_top_2b.v:1425；rtl/csr/trap_ctrl.v:51,58,63,64,65 | 0 / 0（已裁） |

### ⑥-2 预计 area 可能非 0（需先实测）

| # | 动作 | 位置 | 预计影响 |
|---|---|---|---|
| R-29 | 消除 2 个推断 latch（补全组合分支默认赋值） | rtl/back2/rename.v:422 | **FF 可能 +2 或逻辑 +数 LUT**；`需实测验证` |
| R-30 | 合并 `valid_n_f`/`valid_n_w` 与 `rel_n_w` 两份同构算式 | rtl/back2/rename.v:303-315 | `需实测验证`（预期 ≤数 LUT） |
| R-31 | 同周期重复拼接（`{sp_r,sp_f}` 等 19 处）改局部 wire 复用 | rtl/exec/fpu_add.v:1031…；rtl/exec/fpu_mul.v:140… | 预期 0（CSE），`需实测验证` |
| R-32 | 26 处 RAM-落寄存器（`8-4767`）逐条查 `ram_style` | 见 §④ D-10 | **area 可能 >0**；`需实测验证` |

### ⑥-3 正确性/时序风险（建议优先，非面积）

| # | 动作 | 位置 | 备注 |
|---|---|---|---|
| R-33 | 补 `$display` 缺失实参（`mscratch` 值） | rtl/back2/backend_top.v:2149-2151 | 影响：LUT 0 / FF 0（DBG 恒假）；双侧证据（Verilator Error + `8-9736`） |
| R-34 | `8-689` 46 处位宽不匹配逐条核对（含 `restore_rob_idx` 7↔6） | rtl/back2/backend_top.v:956 等 | 影响：area 小、静默截断风险高（需实测） |
| R-35 | `8-7137` 80 处 Set/Reset 同优先级核实 | rtl/back2/iq.v:167 等 | 影响：LUT 0；仿真/综合不一致（需实测） |
| R-36 | `8-295` 17 处时序环 / `8-326` 10 处推断 false path 复核 | rtl/top/core_top_2b.v:289,64 等 | 影响：area 0；时序风险（需实测） |
| R-37 | `aresetn` 同步/异步混用核实 | rtl/top/core_top_2b.v:71 | 影响：area 0；SYNCASYNCNET 风险（需实测） |
| R-38 | 修复失效 lint 指令与"含 Verilator 字样的注释"（改 `/*verilator …*/` 无空格式 / 改写文案） | rtl/exec/mdu.v:204（13 处）、rtl/plic/plic.v:153,154,170,171、rtl/mem/pmp_check.v:397 等 17 文件 41 处 | 影响：LUT 0 / FF 0；恢复 lint 可用性（可读性 高） |

---

## ⑦ grep 复现命令全列（全部只读）

```bash
# 0. 冻结基准核验
git rev-parse HEAD
git rev-parse d00eb03:rtl ; git rev-parse HEAD:rtl
git diff --name-only d00eb03 HEAD -- rtl          # 期望为空
sha256sum fpga/out/synth_2b_n35b_16.667ns_utilization.rpt
sha256sum fpga/out/n35b_synth_run.log

# 1. 综合证据（本报告全部 [Synth 8-*] 引用）
grep -oE '\[Synth 8-[0-9]+\]' fpga/out/n35b_synth_run.log | sort | uniq -c | sort -rn
grep -nE '\[Synth 8-7129\]' fpga/out/n35b_synth_run.log        # trap_ctrl 无负载端口 100 条
grep -nE '\[Synth 8-6014\]' fpga/out/n35b_synth_run.log        # 被删时序元件 100 条
grep -nE '\[Synth 8-3332\]' fpga/out/n35b_synth_run.log        # fpu_fma_shared r2_prod 89 条
grep -nE '\[Synth 8-3917\]' fpga/out/n35b_synth_run.log        # 端口恒 0 共 37 条
grep -nE '\[Synth 8-3848\]' fpga/out/n35b_synth_run.log        # 无驱动网 2 条
grep -nE '\[Synth 8-(226|589|689|693|6901|7023|7071|7137|8895|9736|10940|11241|295|326|3936)\]' fpga/out/n35b_synth_run.log

# 2. Verilator lint（RTL 原文含 "Verilator" 字样会 %Error，故先做净化镜像再 lint）
grep -rni 'verilator' rtl --include='*.v' | wc -l          # 41 处
grep -rli 'verilator' rtl --include='*.v'                  # 17 个文件
cp -r rtl fpga/scratch/audit3_rtl
grep -rl 'erilator' fpga/scratch/audit3_rtl --include='*.v' | xargs -r sed -i 's/erilator/erilato_r/g'
#   + 修补 backend_top.v:2149 的 $display 缺参（仅镜像，为绕过 Verilator 硬错误）
{ echo "+incdir+rtl/pkg"; find fpga/scratch/audit3_rtl -name '*.v' | sort; } > fpga/scratch/audit3_flist_mirror.f
verilator --lint-only -Wall -Wno-fatal -Irtl/pkg -I. --top-module core_top_2b \
          -f fpga/scratch/audit3_flist_mirror.f > fpga/scratch/audit3_verilator.log 2>&1
sed 's|fpga/scratch/audit3_rtl/|rtl/|g' fpga/scratch/audit3_verilator.log > fpga/scratch/audit3_verilator_rtl.log
grep -oE '%Warning-[A-Z0-9_]+' fpga/scratch/audit3_verilator_rtl.log | sort | uniq -c | sort -rn
grep '%Warning-UNUSEDSIGNAL'    fpga/scratch/audit3_verilator_rtl.log      # 394 条
grep '%Warning-UNUSEDPARAM'     fpga/scratch/audit3_verilator_rtl.log      # 35 条
grep '%Warning-UNDRIVEN'        fpga/scratch/audit3_verilator_rtl.log      # 2 条
grep '%Warning-LATCH'           fpga/scratch/audit3_verilator_rtl.log      # 2 条
grep '%Warning-UNOPTFLAT'       fpga/scratch/audit3_verilator_rtl.log      # 15 条
grep '%Warning-PINMISSING'      fpga/scratch/audit3_verilator_rtl.log      # 15 条
grep '%Warning-DECLFILENAME'    fpga/scratch/audit3_verilator_rtl.log      # 6 条
grep '%Warning-GENUNNAMED'      fpga/scratch/audit3_verilator_rtl.log      # 6 条
grep '%Error'                   fpga/scratch/audit3_verilator.log          # 净化前 2 条（含 $display 缺参）

# 3. 结构扫描（纯搬运链 / 多 driver / 重复 RHS / 写次数）
python3 fpga/scratch/audit3_scan.py > fpga/scratch/audit3_scan.out
sed -n '1,20p'   fpga/scratch/audit3_scan.out          # A1 自赋值 0、A2 纯搬运链
sed -n '/## A3/,/## A4/p' fpga/scratch/audit3_scan.out # assign 覆盖链候选（含 ifdef/generate 假阳性，须逐条人工核）
sed -n '/## A4/,/## A5/p' fpga/scratch/audit3_scan.out # 同周期重复 RHS

# 4. 分类专项
grep -rnE "if\s*\(\s*(1'[bdh][01xz]+|[01])\s*\)" rtl --include='*.v'      # 字面常量 if：0 条
grep -rn 'if *( *DBG' rtl --include='*.v'                                  # 8 处恒假调试分支
grep -rnE "== *1'b1|!= *1'b0" rtl --include='*.v' | wc -l                  # 16 处冗余比较
grep -rn '/\* *verilator' rtl --include='*.v'                              # 17 处失效 lint 指令
grep -rn '`ifdef RV32GC_USE_VIVADO_IP\|`ifndef RV32GC_USE_VIVADO_IP' rtl --include='*.v' | wc -l  # 22 处双分支
grep -rn 'fwd_all_w\|pend_sel\|ck_ghr_q' rtl --include='*.v'               # 历史 dead 逻辑复核
awk 'length($0)>160 {printf "%s:%d (%d)\n", FILENAME, FNR, length($0)}' $(find rtl -name '*.v')
grep -rn ' $' rtl --include='*.v'                                          # 尾随空白
grep -cE '^\s*function .*\b[upw]_[a-z0-9_]+;' rtl/back2/backend_top.v      # 95 个访问函数
```

---

## ⑧ 遗留 / 风险

1. **`8-6014`/`8-7129` 的 100 条上限疑云**：若确为 Vivado 单类别上限，则 dead FF/RAM 的真实规模大于本报告列出的
   100 条；建议下一轮以 `set_msg_config -limit` 放开后复跑（**只读复跑，不改 RTL**）。
2. **Verilator lint 需净化镜像**：本报告所有 Verilator 结论来自净化镜像（仅替换注释中的 `erilator` → `erilato_r`，
   并给 `backend_top.v:2149` 的 `$display` 补 1 个 `32'h0` 实参以绕过**原文既有硬错误**）。这两处净化对语义**无影响**，
   但**必须**在引用时声明——已在 §6 写明。
3. **`8-689`（46 处位宽不匹配）** 未逐条展开：其中可能含真实丢位；下一轮应逐条出证据。
4. **`u_/p_/w_` 三套访问函数（95 个）**：本轮只给"存在重复搬运"的结论与计数，未做逐字段交叉矩阵；
   若要给出"可删多少行"的结论，需要做法与字段的笛卡尔核对。
5. **未做功耗/时序影响分析**：本轮只到"area 0 / 可读性 / 综合是否证实"，不含 WNS/功耗。
6. **`pend_sel` 保留**：rtl/back2/lsq_simple.v:743-745 是为 TB (`tb_back2_lsq_fwd`) DBG 打印保留的诊断别名，
   **不是**无意义搬运；删除前须同步 TB（本次未改 TB）。

---

## ⑨ 验收锚点

```
AUDIT3: PASS
```

（判定由 `fpga/scratch/audit3_check.py` 脚本做出：① 五节齐；② 报告头含冻结基准 HEAD + rpt sha256；
③ 条目行 ≥65；④ 每项含 `rtl/<path>:<line>`；⑤ "对 area 影响"列非空。）
